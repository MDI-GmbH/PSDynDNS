#requires -Version 5.1
[CmdletBinding(DefaultParameterSetName='Install')]
param(
    [Parameter(ParameterSetName='Install')][switch]$Install,
    [Parameter(ParameterSetName='Configure',Mandatory=$true)][switch]$Configure,
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
    [Nullable[bool]]$AutoUpdate,
    [Nullable[int]]$UpdateCheckHours,
    [string]$LocalClientPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Root = Join-Path $env:ProgramData 'PSDynDNS'
$script:App = Join-Path $script:Root 'app'
$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:TaskName = 'PSDynDNS'
$script:AdministratorsSid = 'S-1-5-32-544'
$script:SystemSid = 'S-1-5-18'
$script:ServiceSid = 'S-1-5-19'
$script:TaskPrincipalSid = $null

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this installer from an elevated Windows PowerShell console.'
    }
}
function Assert-Url {
    param([string]$Value)
    $uri = $null
    if (-not [uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo) {
        throw 'URLs must use HTTPS without embedded credentials.'
    }
}
function Set-ProtectedAcl {
    param([string]$Path, [switch]$ClientRead, [switch]$ClientModify, [switch]$Directory)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
    $inherit = if ($Directory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($sid in @($script:SystemSid,$script:AdministratorsSid)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    if ($ClientRead -or $ClientModify) {
        $sid = New-Object Security.Principal.SecurityIdentifier($script:TaskPrincipalSid)
        $rights = if ($ClientModify) { [Security.AccessControl.FileSystemRights]::Modify } else { [Security.AccessControl.FileSystemRights]::ReadAndExecute }
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid,$rights,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-TaskSid {
    # Task SIDs are derived from the uppercased full task path using SHA-1.
    $taskPath = '\' + $script:TaskName.ToUpperInvariant()
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($taskPath)) }
    finally { $sha.Dispose() }
    $sub = 1..5 | ForEach-Object { [BitConverter]::ToUInt32($hash,(($_ - 1) * 4)) }
    return 'S-1-5-87-' + ($sub -join '-')
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
    if (-not $Cfg.Hostname -or [string]$Cfg.Hostname -notmatch '^[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+
    if (-not $Cfg.IPv4Enabled -and -not $Cfg.IPv6Enabled) { throw 'Enable at least one IP family.' }
    foreach ($entry in @('UpdateUrl','IPv4CheckUrl','IPv6CheckUrl')) { Assert-Url ([string]$Cfg.$entry) }
    if ($Cfg.IntervalMinutes -lt 1 -or $Cfg.IntervalMinutes -gt 1440) { throw 'IntervalMinutes must be 1..1440.' }
    if ($Cfg.UpdateCheckHours -lt 1) { throw 'UpdateCheckHours must be positive.' }
    $Cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    Set-ProtectedAcl $script:ConfigPath -ClientRead
}
function Apply-Settings {
    param($Cfg)
    foreach ($name in @('Hostname','Username','UpdateUrl','IPv4Enabled','IPv6Enabled','IPv4CheckUrl','IPv6CheckUrl','IntervalMinutes','AutoUpdate','UpdateCheckHours')) {
        $value = Get-Variable -Name $name -ValueOnly
        if ($null -ne $value) { $Cfg.$name = $value }
    }
    return $Cfg
}
function Save-Secret {
    Add-Type -AssemblyName System.Security
    $secure = Read-Host -Prompt 'DynDNS update secret' -AsSecureString
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
    param([int]$Minutes)
    $path = Join-Path $script:App 'PSDynDNS.ps1'
    $args = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $path + '" -ConfigPath "' + $script:ConfigPath + '"'
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $args
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount -RunLevel Limited -ProcessTokenSidType Unrestricted
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}
function Install-ClientFile {
    param([string]$Source)
    $destination = Join-Path $script:App 'PSDynDNS.ps1'
    if ($Source) {
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'Local client file not found.' }
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Source).Path,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw 'Local client script has syntax errors.' }
        Copy-Item -LiteralPath $Source -Destination $destination -Force
    } else {
        # Only official release assets are accepted. Development can use -LocalClientPath.
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/MDI-GmbH/PSDynDNS/releases/latest' -Headers @{'User-Agent'='PSDynDNS-Installer'} -TimeoutSec 20
        if ($release.prerelease -or $release.draft) { throw 'Expected a stable release.' }
        $asset = @($release.assets | Where-Object { $_.name -eq 'PSDynDNS.ps1' }) | Select-Object -First 1
        if (-not $asset -or -not $asset.digest -or $asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw 'Release asset digest unavailable.' }
        $expected = $Matches[1]
        $temp = Join-Path $env:TEMP ('PSDynDNS-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $temp -UseBasicParsing -TimeoutSec 60
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
if (-not $PSVersionTable.PSVersion -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 is required.' }
$script:TaskPrincipalSid = Get-TaskSid
switch ($PSCmdlet.ParameterSetName) {
    Install {
        if (Test-Path -LiteralPath $script:ConfigPath) { throw 'Already installed. Use -Configure or -Repair.' }
        if (-not $Hostname) { throw 'Supply -Hostname for installation.' }
        Ensure-Directories
        $cfg = [pscustomobject]@{
            Hostname=$Hostname; Username=$null; UpdateUrl='https://nsupdate.info/nic/update'
            IPv4Enabled=$true; IPv6Enabled=$false
            IPv4CheckUrl='https://ipv4.nsupdate.info/myip'
            IPv6CheckUrl='https://ipv6.nsupdate.info/myip'
            IntervalMinutes=10; AutoUpdate=$false; UpdateCheckHours=24
        }
        $cfg = Apply-Settings $cfg
        Install-ClientFile $LocalClientPath
        Save-Settings $cfg
        Save-Secret
        Install-Task ([int]$cfg.IntervalMinutes)
        Write-Host 'PSDynDNS installed.'
    }
    Configure {
        $cfg = Apply-Settings (Read-Settings)
        Save-Settings $cfg
        if ($PSBoundParameters.ContainsKey('IntervalMinutes')) { Install-Task ([int]$cfg.IntervalMinutes) }
        Write-Host 'Configuration saved.'
    }
    Repair {
        $cfg = Read-Settings
        Ensure-Directories
        foreach ($name in @('config.json','secret.dpapi')) {
            $p = Join-Path $script:Root $name
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing $name; cannot repair without reinstalling/setting secret." }
            Set-ProtectedAcl $p -ClientRead
        }
        $client = Join-Path $script:App 'PSDynDNS.ps1'
        if (-not (Test-Path -LiteralPath $client)) { Install-ClientFile $LocalClientPath }
        else { Set-ProtectedAcl $client -ClientRead }
        Install-Task ([int]$cfg.IntervalMinutes)
        Write-Host 'PSDynDNS repaired.'
    }
    SetKey {
        if (-not (Test-Path -LiteralPath $script:ConfigPath)) { throw 'Install first.' }
        Save-Secret
        Write-Host 'Secret updated.'
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
) { throw 'A valid FQDN is required.' }
    if (-not $Cfg.IPv4Enabled -and -not $Cfg.IPv6Enabled) { throw 'Enable at least one IP family.' }
    foreach ($entry in @('UpdateUrl','IPv4CheckUrl','IPv6CheckUrl')) { Assert-Url ([string]$Cfg.$entry) }
    if ($Cfg.IntervalMinutes -lt 1 -or $Cfg.IntervalMinutes -gt 1440) { throw 'IntervalMinutes must be 1..1440.' }
    if ($Cfg.UpdateCheckHours -lt 1) { throw 'UpdateCheckHours must be positive.' }
    $Cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
    Set-ProtectedAcl $script:ConfigPath -ClientRead
}
function Apply-Settings {
    param($Cfg)
    foreach ($name in @('Hostname','Username','UpdateUrl','IPv4Enabled','IPv6Enabled','IPv4CheckUrl','IPv6CheckUrl','IntervalMinutes','AutoUpdate','UpdateCheckHours')) {
        $value = Get-Variable -Name $name -ValueOnly
        if ($null -ne $value) { $Cfg.$name = $value }
    }
    return $Cfg
}
function Save-Secret {
    Add-Type -AssemblyName System.Security
    $secure = Read-Host -Prompt 'DynDNS update secret' -AsSecureString
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
    param([int]$Minutes)
    $path = Join-Path $script:App 'PSDynDNS.ps1'
    $args = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $path + '" -ConfigPath "' + $script:ConfigPath + '"'
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $args
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\LOCAL SERVICE' -LogonType ServiceAccount -RunLevel Limited -ProcessTokenSidType Unrestricted
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}
function Install-ClientFile {
    param([string]$Source)
    $destination = Join-Path $script:App 'PSDynDNS.ps1'
    if ($Source) {
        Copy-Item -LiteralPath $Source -Destination $destination -Force
    } else {
        # Only official release assets are accepted. Development can use -LocalClientPath.
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/MDI-GmbH/PSDynDNS/releases/latest' -Headers @{'User-Agent'='PSDynDNS-Installer'} -TimeoutSec 20
        if ($release.prerelease -or $release.draft) { throw 'Expected a stable release.' }
        $asset = @($release.assets | Where-Object { $_.name -eq 'PSDynDNS.ps1' }) | Select-Object -First 1
        if (-not $asset -or -not $asset.digest -or $asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw 'Release asset digest unavailable.' }
        $expected = $Matches[1]
        $temp = Join-Path $env:TEMP ('PSDynDNS-' + [guid]::NewGuid().ToString('N') + '.ps1')
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $temp -UseBasicParsing -TimeoutSec 60
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
if (-not $PSVersionTable.PSVersion -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 is required.' }
$script:TaskPrincipalSid = Get-TaskSid
switch ($PSCmdlet.ParameterSetName) {
    Install {
        if (Test-Path -LiteralPath $script:ConfigPath) { throw 'Already installed. Use -Configure or -Repair.' }
        if (-not $Hostname) { throw 'Supply -Hostname for installation.' }
        Ensure-Directories
        $cfg = [pscustomobject]@{
            Hostname=$Hostname; Username=$null; UpdateUrl='https://nsupdate.info/nic/update'
            IPv4Enabled=$true; IPv6Enabled=$false
            IPv4CheckUrl='https://ipv4.nsupdate.info/myip'
            IPv6CheckUrl='https://ipv6.nsupdate.info/myip'
            IntervalMinutes=10; AutoUpdate=$false; UpdateCheckHours=24
        }
        $cfg = Apply-Settings $cfg
        Install-ClientFile $LocalClientPath
        Save-Settings $cfg
        Save-Secret
        Install-Task ([int]$cfg.IntervalMinutes)
        Write-Host 'PSDynDNS installed.'
    }
    Configure {
        $cfg = Apply-Settings (Read-Settings)
        Save-Settings $cfg
        Write-Host 'Configuration saved. If interval changed, run -Repair to update the Task.'
    }
    Repair {
        $cfg = Read-Settings
        Ensure-Directories
        foreach ($name in @('config.json','secret.dpapi')) {
            $p = Join-Path $script:Root $name
            if (-not (Test-Path -LiteralPath $p)) { throw "Missing $name; cannot repair without reinstalling/setting secret." }
            Set-ProtectedAcl $p -ClientRead
        }
        if (-not (Test-Path -LiteralPath (Join-Path $script:App 'PSDynDNS.ps1'))) { Install-ClientFile $LocalClientPath }
        Install-Task ([int]$cfg.IntervalMinutes)
        Write-Host 'PSDynDNS repaired.'
    }
    SetKey {
        if (-not (Test-Path -LiteralPath $script:ConfigPath)) { throw 'Install first.' }
        Save-Secret
        Write-Host 'Secret updated.'
    }
    Uninstall {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:App) { Remove-Item -LiteralPath $script:App -Recurse -Force }
        if ($Purge -and (Test-Path -LiteralPath $script:Root)) { Remove-Item -LiteralPath $script:Root -Recurse -Force }
        Write-Host 'PSDynDNS uninstalled.'
    }
}
