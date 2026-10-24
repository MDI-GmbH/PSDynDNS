#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Configure')]
param(
    [Parameter(ParameterSetName='Install')][switch]$Install,
    [Parameter(ParameterSetName='Configure')][switch]$Configure,
    [Parameter(ParameterSetName='Repair',Mandatory=$true)][switch]$Repair,
    [Parameter(ParameterSetName='SetKey',Mandatory=$true)][switch]$SetKey,
    [Parameter(ParameterSetName='Uninstall',Mandatory=$true)][switch]$Uninstall,
    [Parameter(ParameterSetName='Uninstall')][switch]$Purge,
    [Parameter(ParameterSetName='ResetState',Mandatory=$true)][switch]$ResetState,
    [string]$Hostname,
    [string]$Username,
    [string]$UpdateUrl,
    [Nullable[bool]]$IPv4Enabled,
    [Nullable[bool]]$IPv6Enabled,
    [string]$IPv4CheckUrl,
    [string]$IPv6CheckUrl,
    [Nullable[int]]$IntervalMinutes,
    [ValidateSet('WindowsPowerShell','PowerShell7')][string]$Runtime,
    [Nullable[bool]]$AutoUpdate,
    [Nullable[bool]]$AllowAutomaticConfigUpdates,
    [ValidateSet('stable','beta','main')][string]$UpdateChannel,
    [Nullable[int]]$UpdateCheckHours,
    [string]$LocalClientPath,
    [string[]]$DnsServers,
    [SecureString]$CredentialSecret
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InstallerBoundParameters = @{} + $PSBoundParameters
$script:Root = Join-Path $env:ProgramData 'PSDynDNS'
$script:App = Join-Path $script:Root 'app'
$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:TaskName = 'PSDynDNS'
$script:AdministratorsSid = 'S-1-5-32-544'
$script:SystemSid = 'S-1-5-18'
$script:ServiceSid = 'S-1-5-19'
$script:TaskPrincipalSid = $null

function Assert-PSDynDnsSettings {
    param($Cfg)
    $hostName = [string]$Cfg.Hostname
    # DNS labels: 1-63 characters, no leading/trailing hyphens.
    $labels = $hostName.Split('.')
    if ($hostName.Length -gt 253 -or $labels.Count -lt 2) {
        throw 'Hostname must be a valid FQDN.'
    }
    foreach ($label in $labels) {
        if ($label -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') {
            throw 'Hostname must be a valid FQDN.'
        }
    }
    if (-not $Cfg.IPv4Enabled -and -not $Cfg.IPv6Enabled) { throw 'Enable IPv4 and/or IPv6.' }
    $urls = @('UpdateUrl')
    if ($Cfg.IPv4Enabled) { $urls += 'IPv4CheckUrl' }
    if ($Cfg.IPv6Enabled) { $urls += 'IPv6CheckUrl' }
    foreach ($name in $urls) {
        $value = [string]$Cfg.$name
        $parsed = $null
        if (-not [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$parsed) -or
            $parsed.Scheme -ne 'https' -or -not $parsed.Host -or $parsed.UserInfo) {
            throw ('Invalid HTTPS setting: ' + $name)
        }
    }
    if ($null -ne $Cfg.PSObject.Properties['UpdateCheckHours']) {
        if ([int]$Cfg.UpdateCheckHours -lt 1 -or [int]$Cfg.UpdateCheckHours -gt 720) {
            throw 'UpdateCheckHours must be 1..720.'
        }
    }
    if ($null -ne $Cfg.PSObject.Properties['UpdateChannel'] -and
        $Cfg.UpdateChannel -notin @('stable','beta','main')) {
        throw 'Invalid UpdateChannel.'
    }
    if ($null -ne $Cfg.PSObject.Properties['DnsServers']) {
        $servers = @($Cfg.DnsServers)
        if ($servers.Count -eq 0) { throw 'DnsServers must contain at least one DNS server IP address.' }
        foreach ($server in $servers) {
            $address = $null
            if (-not [Net.IPAddress]::TryParse([string]$server, [ref]$address) -or
                [Net.IPAddress]::IsLoopback($address) -or
                $address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::IPv6Any)) {
                throw 'DnsServers must contain valid, non-loopback IP addresses.'
            }
        }
    }
}
function Select-PSDynDnsRelease {
    param([object[]]$Releases, [ValidateSet('stable','beta')][string]$Channel)
    $candidates = @()
    foreach ($release in $Releases) {
        if ($release.draft -or ($Channel -eq 'stable' -and $release.prerelease)) { continue }
        $tag = [string]$release.tag_name
        if ($tag -notmatch '^v?(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?$') { continue }
        $core = [version]($Matches[1] + '.' + $Matches[2] + '.' + $Matches[3])
        $kind = if ($Matches[4]) { [string]$Matches[4] } else { '' }
        $number = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
        $rank = switch ($kind) { 'alpha' {1} 'beta' {2} 'rc' {3} default {4} }
        if (($kind -ne '') -ne [bool]$release.prerelease) { continue }
        $assets = @($release.assets | Where-Object { $_.name -eq 'PSDynDNS.ps1' })
        if ($assets.Count -ne 1 -or [string]$assets[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { continue }
        $digest = $Matches[1].ToLowerInvariant()
        $url = [uri]$assets[0].browser_download_url
        if ($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or
            -not $url.AbsolutePath.StartsWith('/MDI-GmbH/PSDynDNS/releases/download/', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $candidates += [pscustomobject]@{
            Version=$core; Rank=$rank; PreNumber=$number; Tag=$tag
            Url=$url.AbsoluteUri; Sha256=$digest; Content=$null; Commit=$null; Channel=$Channel
        }
    }
    if ($candidates.Count -eq 0) { throw 'No usable published release.' }
    return $candidates |
        Sort-Object -Property @{Expression='Version';Descending=$true},@{Expression='Rank';Descending=$true},@{Expression='PreNumber';Descending=$true} |
        Select-Object -First 1
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this installer from an elevated Windows PowerShell console.'
    }
}
function Set-ProtectedAcl {
    param([string]$Path, [switch]$ClientRead, [switch]$ClientModify, [switch]$Directory)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    $inherit = if ($Directory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($sid in @($script:SystemSid,$script:AdministratorsSid)) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $identity,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inherit,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    if ($ClientRead -or $ClientModify) {
        $sid = New-Object Security.Principal.SecurityIdentifier($script:TaskPrincipalSid)
        $rights = if ($ClientModify) { [Security.AccessControl.FileSystemRights]::Modify } else { [Security.AccessControl.FileSystemRights]::ReadAndExecute }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            $rights,
            $inherit,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
        if ($ClientModify -and $Directory -and $Path -eq $script:App) {
            # Permit replacement of the protected client file without giving
            # the task write access to config.json, secret.dpapi or file ACLs.
            $deleteChild = New-Object Security.AccessControl.FileSystemAccessRule(
                $sid, [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
                [Security.AccessControl.InheritanceFlags]::None,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($deleteChild)
        }
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-TaskSid {
    # Windows Task Scheduler is the authority for task SIDs. /ShowSid
    # calculates this SID even before registration. Parse only the stable
    # numeric SID so the localized command output cannot affect the result.
    $tool = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $output = (& $tool /ShowSid /TN $script:TaskName 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Windows could not calculate the scheduled task SID.' }
    $match = [regex]::Match($output,'S-1-5-87-(?:[0-9]+-){4}[0-9]+')
    if (-not $match.Success) { throw 'Windows did not return a valid scheduled task SID.' }
    return $match.Value
}

function Ensure-Directories {
    if (-not (Test-Path -LiteralPath $script:Root)) { [void](New-Item -Path $script:Root -ItemType Directory) }
    if (-not (Test-Path -LiteralPath $script:App)) { [void](New-Item -Path $script:App -ItemType Directory) }
    $script:TaskPrincipalSid = Get-TaskSid
    Set-ProtectedAcl $script:Root -ClientRead -Directory
    Set-ProtectedAcl $script:App -ClientModify -Directory
    $runtime = Join-Path $script:Root 'runtime'
    if (-not (Test-Path -LiteralPath $runtime)) { [void](New-Item -Path $runtime -ItemType Directory) }
    Set-ProtectedAcl $runtime -ClientModify -Directory
    foreach ($name in @('state.json', 'client.log')) {
        $target = Join-Path $runtime $name
        if (-not (Test-Path -LiteralPath $target)) {
            if ($name -eq 'state.json') { '{}' | Set-Content -LiteralPath $target -Encoding UTF8 }
            else { [IO.File]::WriteAllText($target, '') }
        }
        Set-ProtectedAcl $target -ClientModify
    }
}
function Read-Settings {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { throw 'Configuration not installed.' }
    return Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Save-Settings {
    param($Cfg)
    if ($null -eq $Cfg.PSObject.Properties['UpdateChannel']) {
        Add-Member -InputObject $Cfg -NotePropertyName UpdateChannel -NotePropertyValue 'stable'
    }
    if ($null -eq $Cfg.PSObject.Properties['DnsServers']) {
        Add-Member -InputObject $Cfg -NotePropertyName DnsServers -NotePropertyValue @('8.8.8.8','8.8.4.4')
    }
    Assert-PSDynDnsSettings $Cfg
    # Keep scheduled task repetition interval outside of config.json.
    if ($null -ne $Cfg.PSObject.Properties['IntervalMinutes']) { $Cfg.PSObject.Properties.Remove('IntervalMinutes') }
    $Cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    Set-ProtectedAcl $script:ConfigPath -ClientRead
}

function Apply-Settings {
    param($Cfg)
    foreach ($name in @(
        'Hostname', 'Username', 'UpdateUrl', 'IPv4Enabled', 'IPv6Enabled',
        'IPv4CheckUrl', 'IPv6CheckUrl', 'AutoUpdate', 'AllowAutomaticConfigUpdates',
        'UpdateCheckHours', 'UpdateChannel', 'DnsServers'
    )) {
        # Use only explicitly supplied script arguments. An unspecified typed
        # [string] parameter can otherwise appear as an empty string and
        # erase defaults such as the DynDNS HTTPS endpoint.
        if ($script:InstallerBoundParameters.ContainsKey($name)) {
            $value = $script:InstallerBoundParameters[$name]
            if ($null -eq $Cfg.PSObject.Properties[$name]) {
                Add-Member -InputObject $Cfg -NotePropertyName $name -NotePropertyValue $value
            } else {
                $Cfg.$name = $value
            }
        }
    }
    return $Cfg
}
function Save-Secret {
    Add-Type -AssemblyName System.Security
    $secure = if ($null -ne $CredentialSecret) { $CredentialSecret } else { Read-Host -Prompt 'DynDNS update secret' -AsSecureString }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
        try {
            $cipher = [Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
            [IO.File]::WriteAllBytes((Join-Path $script:Root 'secret.dpapi'),$cipher)
        } finally { [Array]::Clear($bytes,0,$bytes.Length); $plain = $null }
    } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    Set-ProtectedAcl (Join-Path $script:Root 'secret.dpapi') -ClientRead
}
function Install-Task {
    param([int]$Minutes, [ValidateSet('WindowsPowerShell','PowerShell7')][string]$Runtime='WindowsPowerShell')
    if ($Minutes -lt 1 -or $Minutes -gt 1440) { throw 'IntervalMinutes must be between 1 and 1440.' }
    $path = Join-Path $script:App 'PSDynDNS.ps1'
    $args = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $path + '" -ConfigPath "' + $script:ConfigPath + '"'
    $exe = if ($Runtime -eq 'PowerShell7') {
        $command = Get-Command 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { throw 'PowerShell 7 (pwsh.exe) was requested but is not installed.' }
        $command.Source
    } else {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    $action = New-ScheduledTaskAction -Execute $exe -Argument $args
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
    # Use the well-known LocalService SID so registration works on all Windows UI languages.
    $principal = New-ScheduledTaskPrincipal -UserId $script:ServiceSid -LogonType ServiceAccount -RunLevel Limited -ProcessTokenSidType Unrestricted
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}
function Get-ExistingTaskRuntime {
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return 'WindowsPowerShell' }
    $execute = [string]$task.Actions[0].Execute
    if ([IO.Path]::GetFileName($execute) -ieq 'pwsh.exe') { return 'PowerShell7' }
    return 'WindowsPowerShell'
}
function Get-ExistingTaskInterval {
    # The Scheduled Task is the only authoritative source for the interval.
    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return 10 }
    foreach ($trigger in @($task.Triggers)) {
        $raw = [string]$trigger.Repetition.Interval
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        try {
            $minutes = [int]([Xml.XmlConvert]::ToTimeSpan($raw).TotalMinutes)
            if ($minutes -ge 1 -and $minutes -le 1440) { return $minutes }
        } catch { }
    }
    return 10
}
function Install-ClientFile {
    param([string]$Source,[ValidateSet('stable','beta','main')][string]$Channel='stable')
    $destination = Join-Path $script:App 'PSDynDNS.ps1'
    if ($Source) {
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'Local client file not found.' }
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Source).Path,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw 'Local client script has syntax errors.' }
        Copy-Item -LiteralPath $Source -Destination $destination -Force
    } else {
        # Only official release assets are accepted. Development can use -LocalClientPath.
        if ($Channel -eq 'main') { throw 'Installing main directly requires -LocalClientPath; stable or beta needs a published GitHub Release.' }
        $url = if ($Channel -eq 'beta') {
            'https://api.github.com/repos/MDI-GmbH/PSDynDNS/releases?per_page=100'
        } else { 'https://api.github.com/repos/MDI-GmbH/PSDynDNS/releases/latest' }
        $releases = @(Invoke-RestMethod -Uri $url -Headers @{'User-Agent'='PSDynDNS-Installer'} -TimeoutSec 20)
        $release = Select-PSDynDnsRelease -Releases $releases -Channel $Channel
        $expected = $release.Sha256
        $temp = Join-Path $env:TEMP ('PSDynDNS-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Invoke-WebRequest -Uri $release.Url -OutFile $temp -UseBasicParsing -TimeoutSec 60
            if ((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ne $expected) { throw 'Downloaded release failed SHA-256 verification.' }
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($temp,[ref]$null,[ref]$errors)
            if ($errors.Count) { throw 'Downloaded PowerShell file contains syntax errors.' }
            Copy-Item -LiteralPath $temp -Destination $destination -Force
        } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    Set-ProtectedAcl $destination -ClientRead
}
Assert-Admin
if (-not $PSVersionTable.PSVersion -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw 'PowerShell 5.1 or 7+ is required.' }
$script:TaskPrincipalSid = Get-TaskSid
switch ($PSCmdlet.ParameterSetName) {
    Install {
        if (Test-Path -LiteralPath $script:ConfigPath) { throw 'Already installed. Pass setting parameters to reconfigure, or use -Repair.' }
        if (-not $Hostname) { throw 'Supply -Hostname for installation.' }
        Ensure-Directories
        $cfg = [pscustomobject]@{
            Hostname=$Hostname; Username=$null; UpdateUrl='https://nsupdate.info/nic/update'
            IPv4Enabled=$true; IPv6Enabled=$false
            IPv4CheckUrl='https://ipv4.nsupdate.info/myip'
            IPv6CheckUrl='https://ipv6.nsupdate.info/myip'
            AutoUpdate=$false; AllowAutomaticConfigUpdates=$true
            UpdateCheckHours=24; UpdateChannel='stable'; DnsServers=@('8.8.8.8','8.8.4.4')
        }
        $cfg = Apply-Settings $cfg
        Install-ClientFile -Source $LocalClientPath -Channel $cfg.UpdateChannel
        Save-Settings $cfg
        Save-Secret
        $minutes = if ($script:InstallerBoundParameters.ContainsKey('IntervalMinutes')) { [int]$IntervalMinutes } else { 10 }
        $runtime = if ($Runtime) { $Runtime } else { 'WindowsPowerShell' }
        Install-Task -Minutes $minutes -Runtime $runtime
        # Reapply permissions using Windows' registered NT TASK SID, not just the pre-registration hash.
        Ensure-Directories
        Set-ProtectedAcl (Join-Path $script:App 'PSDynDNS.ps1') -ClientRead
        Set-ProtectedAcl $script:ConfigPath -ClientRead
        Set-ProtectedAcl (Join-Path $script:Root 'secret.dpapi') -ClientRead
        Write-Host 'PSDynDNS installed.'
    }
    Configure {
        $settings = @(
            'Hostname', 'Username', 'UpdateUrl', 'IPv4Enabled', 'IPv6Enabled',
            'IPv4CheckUrl', 'IPv6CheckUrl', 'AutoUpdate', 'AllowAutomaticConfigUpdates',
            'UpdateCheckHours', 'UpdateChannel', 'DnsServers', 'IntervalMinutes', 'Runtime'
        )
        if (@($settings | Where-Object { $script:InstallerBoundParameters.ContainsKey($_) }).Count -eq 0) {
            throw 'No settings supplied. Pass the settings to change or use -Help.'
        }
        $cfg = Apply-Settings (Read-Settings)
        Save-Settings $cfg
        if ($script:InstallerBoundParameters.ContainsKey('IntervalMinutes') -or $script:InstallerBoundParameters.ContainsKey('Runtime')) {
            $minutes = if ($script:InstallerBoundParameters.ContainsKey('IntervalMinutes')) { [int]$IntervalMinutes } else { Get-ExistingTaskInterval }
            $runtime = if ($Runtime) { $Runtime } else { Get-ExistingTaskRuntime }
            Install-Task -Minutes $minutes -Runtime $runtime
        }
        Write-Host 'Configuration saved.'
    }
    Repair {
        $cfg = Read-Settings
        $channel = if ($cfg.PSObject.Properties['UpdateChannel']) { [string]$cfg.UpdateChannel } else { 'stable' }
        $minutes = if ($script:InstallerBoundParameters.ContainsKey('IntervalMinutes')) { [int]$IntervalMinutes } else { Get-ExistingTaskInterval }
        $runtime = if ($Runtime) { $Runtime } else { Get-ExistingTaskRuntime }
        Ensure-Directories
        foreach ($name in @('config.json','secret.dpapi')) {
            $p = Join-Path $script:Root $name
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing $name; cannot repair without reinstalling/setting secret." }
            Set-ProtectedAcl $p -ClientRead
        }
        $client = Join-Path $script:App 'PSDynDNS.ps1'
        if (-not (Test-Path -LiteralPath $client)) { Install-ClientFile -Source $LocalClientPath -Channel $channel }
        else { Set-ProtectedAcl $client -ClientRead }
        Install-Task -Minutes $minutes -Runtime $runtime
        Ensure-Directories
        Set-ProtectedAcl $client -ClientRead
        Set-ProtectedAcl $script:ConfigPath -ClientRead
        Set-ProtectedAcl (Join-Path $script:Root 'secret.dpapi') -ClientRead
        Write-Host 'PSDynDNS repaired.'
    }
    SetKey {
        if (-not (Test-Path -LiteralPath $script:ConfigPath)) { throw 'Install first.' }
        Save-Secret
        # Re-try with new credentials. Preserve address/check metadata while
        # clearing only the previous authentication failure.
        $stateFile = Join-Path (Join-Path $script:Root 'runtime') 'state.json'
        if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
            $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $state -and $null -ne $state.PSObject.Properties['BlockedReason'] -and
                [string]$state.BlockedReason -eq 'badauth') {
                $state.BlockedReason = $null
                if ($null -ne $state.PSObject.Properties['RetryAfterUtc']) { $state.RetryAfterUtc = $null }
                $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $stateFile -Encoding UTF8
                Set-ProtectedAcl $stateFile -ClientModify
            }
        }
        Write-Host 'Secret updated; a previous badauth block, if any, has been cleared.'
    }
    ResetState {
        $state = Join-Path (Join-Path $script:Root 'runtime') 'state.json'
        if (-not (Test-Path -LiteralPath $script:ConfigPath)) { throw 'PSDynDNS is not installed.' }
        if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Force }
        '{}' | Set-Content -LiteralPath $state -Encoding UTF8
        Set-ProtectedAcl $state -ClientModify
        Write-Host 'DynDNS state cleared; next scheduled run will refresh DNS.'
    }
    Uninstall {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:App) { Remove-Item -LiteralPath $script:App -Recurse -Force }
        if ($Purge -and (Test-Path -LiteralPath $script:Root)) { Remove-Item -LiteralPath $script:Root -Recurse -Force }
        Write-Host 'PSDynDNS uninstalled.'
    }
}
