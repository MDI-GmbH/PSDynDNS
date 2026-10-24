#requires -Version 5.1
<#
.SYNOPSIS
    PSDynDNS - minimal DynDNS2 updater for Windows PowerShell 5.1.
.NOTES
    Normal operation uses a JSON configuration and machine-protected DPAPI secret.
    No administrative operations are executed from this file.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ForceDnsUpdate,
    [switch]$ForceUpgrade,
    [ValidateSet('stable','beta','main')][string]$UpgradeChannel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Resolve the default only after PowerShell has initialized script-path variables.
# During parameter default evaluation, $PSScriptRoot may still be empty.
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'
}
$script:Version = '0.1.0-dev'
$script:UserAgent = 'PSDynDNS/' + $script:Version

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
    # Reject truthy JSON strings such as "false" instead of silently
    # enabling an address family or automatic updates.
    foreach ($name in @('IPv4Enabled','IPv6Enabled','AutoUpdate')) {
        $property = $Cfg.PSObject.Properties[$name]
        if ($null -eq $property) {
            if ($name -eq 'AutoUpdate') { continue }
            throw "$name must be a JSON boolean."
        }
        if ($property.Value -isnot [bool]) { throw "$name must be a JSON boolean." }
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

function Read-ClientConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration not found: $Path" }
    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PSDynDnsSettings $cfg
    return $cfg
}

# Future automatic edits to config.json must use this explicit opt-in guard.
# Missing, malformed, and false values deny automatic configuration changes.
function Test-AutomaticConfigUpdatesAllowed {
    param($Config)
    return (
        $null -ne $Config -and
        $null -ne $Config.PSObject.Properties['AllowAutomaticConfigUpdates'] -and
        $Config.AllowAutomaticConfigUpdates -is [bool] -and
        $Config.AllowAutomaticConfigUpdates -eq $true
    )
}

function Get-ConfigurationFingerprint {
    param($Config)
    $username = if ($null -ne $Config.PSObject.Properties['Username']) { [string]$Config.Username } else { '' }
    $value = @([string]$Config.Hostname, $username, [string]$Config.UpdateUrl,
      [string]$Config.IPv4Enabled, [string]$Config.IPv6Enabled) -join '|'
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($value)))).Replace('-', '').ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Read-MachineSecret {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'DPAPI secret file is missing.' }
    Add-Type -AssemblyName System.Security
    $cipher = [IO.File]::ReadAllBytes($Path)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($cipher, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { return [Text.Encoding]::UTF8.GetString($plain) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Get-PublicAddress {
    param([string]$Url, [System.Net.Sockets.AddressFamily]$Family)
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 `
        -MaximumRedirection 0 -Headers @{ 'User-Agent' = $script:UserAgent }
    $result = if ($response.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($response.Content).Trim()
    } else {
        ([string]$response.Content).Trim()
    }
    $address = $null
    if (-not [Net.IPAddress]::TryParse($result, [ref]$address) -or $address.AddressFamily -ne $Family) { throw 'IP-check response is not an address of the expected family.' }
    if (-not (Test-PublicIp $address)) {
        throw 'IP-check returned a non-routable address.'
    }
    return $address.ToString()
}

function Get-PublishedDnsAddresses {
    param([string]$Hostname,[ValidateSet('A','AAAA')][string]$RecordType,[string[]]$Servers)
    if (-not $Servers -or $Servers.Count -eq 0) { $Servers = @('8.8.8.8','8.8.4.4') }
    $observations = @()
    foreach ($server in $Servers) {
        $records = @()
        try {
            $records = @(Resolve-DnsName -Name $Hostname -Type $RecordType -Server $server -DnsOnly -NoHostsFile -ErrorAction Stop)
        } catch {
            $errorId = [string]$_.FullyQualifiedErrorId
            if ($errorId -notmatch 'DNS_ERROR_RCODE_NAME_ERROR|DNS_INFO_NO_RECORDS|DNS_ERROR_RCODE_NXRRSET') {
                throw ("DNS lookup for $RecordType via $server failed: " + $_.Exception.Message)
            }
        }
        $values = @($records | Where-Object { [string]$_.Type -eq $RecordType -and $_.IPAddress } |
            ForEach-Object { ([Net.IPAddress]::Parse([string]$_.IPAddress)).ToString() } | Sort-Object -Unique)
        $observations += [pscustomobject]@{Server=$server;Addresses=$values}
    }
    $first = (@($observations[0].Addresses) -join ',')
    foreach ($observation in $observations) {
        if ((@($observation.Addresses) -join ',') -ne $first) { throw "DNS resolvers disagree about $RecordType records; retry after cache TTL." }
    }
    return @($observations[0].Addresses)
}
function Get-DnsComparison {
    param([string]$Hostname,[string[]]$Servers,[string]$IPv4,[string]$IPv6,[bool]$IPv4Enabled,[bool]$IPv6Enabled)
    $v4 = @(); $v6 = @()
    if ($IPv4Enabled) { $v4 = @(Get-PublishedDnsAddresses -Hostname $Hostname -RecordType A -Servers $Servers) }
    if ($IPv6Enabled) { $v6 = @(Get-PublishedDnsAddresses -Hostname $Hostname -RecordType AAAA -Servers $Servers) }
    $matches = (-not $IPv4Enabled -or ($v4.Count -eq 1 -and $v4[0] -eq $IPv4)) -and
               (-not $IPv6Enabled -or ($v6.Count -eq 1 -and $v6[0] -eq $IPv6))
    $observation = ('A=' + ($v4 -join ',') + ';AAAA=' + ($v6 -join ','))
    return [pscustomobject]@{ Matches=[bool]$matches; Observation=$observation }
}

function Invoke-DynDnsRequest {
    param($Config, [string]$Secret, [string]$AddressList)
    $username = [string]$Config.Hostname
    if ($null -ne $Config.PSObject.Properties['Username'] -and $Config.Username) {
        $username = [string]$Config.Username
    }
    $pair = '{0}:{1}' -f $username, $Secret
    $authorization = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $separator = if ([string]$Config.UpdateUrl -match '\?') { '&' } else { '?' }
    $uri = [string]$Config.UpdateUrl + $separator + 'hostname=' + [uri]::EscapeDataString([string]$Config.Hostname) + '&myip=' + [uri]::EscapeDataString($AddressList)
    try {
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 0 -Headers @{
            Authorization = 'Basic ' + $authorization
            'User-Agent' = $script:UserAgent
        }
        if ($response.Content -is [byte[]]) {
            return [Text.Encoding]::UTF8.GetString($response.Content).Trim()
        }
        return ([string]$response.Content).Trim()
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { return 'badauth' }
        throw
    }
}

function Get-ResponseCategory {
    param([string]$Response)
    $code = ($Response -split '\s+')[0].Trim()
    if ($code -in @('good','nochg')) { return 'success' }
    if ($code -in @('badauth','notfqdn','nohost','numhost','abuse','badagent','!donator','!yours')) { return 'blocked' }
    if ($code -in @('dnserr','911')) { return 'retry' }
    return 'unknown'
}

function Read-ClientState {
    param([string]$Path)
    $fields = @(
        'LastIPv4', 'LastIPv6', 'Fingerprint', 'BlockedReason', 'RetryAfterUtc',
        'LastUpdateAttemptUtc', 'LastSuccessfulUpdateCheckUtc',
        'LastProviderUpdateUtc', 'LastDnsObservation'
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $empty = [pscustomobject]@{}
        foreach ($field in $fields) { Add-Member -InputObject $empty -NotePropertyName $field -NotePropertyValue $null }
        return $empty
    }
    try { $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop }
    catch { throw ('Cannot read state.json: ' + $_.Exception.Message) }
    try { $state = ConvertFrom-Json -InputObject $json -ErrorAction Stop }
    catch { throw ('Invalid JSON in state.json; back up the file before using -ResetState: ' + $_.Exception.Message) }
    if ($null -eq $state -or $state -isnot [pscustomobject]) { throw 'state.json must contain a JSON object.' }
    foreach ($field in $fields) {
        if ($null -eq $state.PSObject.Properties[$field]) { Add-Member -InputObject $state -NotePropertyName $field -NotePropertyValue $null }
    }
    return $state
}
function Save-ClientState {
    param([string]$Path,$State)
    $target = [IO.Path]::GetFullPath($Path)
    $temporary = $target + '.tmp'
    $backup = $target + '.bak'
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        [IO.File]::Replace($temporary,$target,$backup)
    } else {
        [IO.File]::Move($temporary,$target)
    }
}

function Write-ClientLog {
    param([string]$Path, [string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToUniversalTime().ToString('o'), $Level, $Message
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge 1048576) {
        Move-Item -LiteralPath $Path -Destination ($Path + '.1') -Force
    }
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Format-ClientFailure {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord, [string]$Secret)
    # Include the exception type and message, but never an HTTP header,
    # URL (which could carry query credentials), or the actual DynDNS secret.
    $message = [string]$ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) { $message = 'No error details available.' }
    if (-not [string]::IsNullOrEmpty($Secret)) {
        $message = $message.Replace($Secret, '[REDACTED]')
        $escapedSecret = [uri]::EscapeDataString($Secret)
        if ($escapedSecret -ne $Secret) { $message = $message.Replace($escapedSecret, '[REDACTED]') }
    }
    $message = [regex]::Replace($message, '(?i)\bBasic\s+[A-Za-z0-9+/=]+', 'Basic [REDACTED]')
    $message = [regex]::Replace($message, '(?i)\b(authorization|password|secret|token|api[-_]?key)\s*[:=]\s*[^\s&,;]+', '$1=[REDACTED]')
    $message = [regex]::Replace($message, "(?i)https?://[^\s'""<>]+", '[URL REDACTED]')
    $message = [regex]::Replace($message, '[\r\n\t]+', ' ').Trim()
    if ($message.Length -gt 800) { $message = $message.Substring(0,800) + '...' }
    return ('{0}: {1}' -f $ErrorRecord.Exception.GetType().Name, $message)
}

function Test-PublicIp {
    param([Net.IPAddress]$Address)
    if ([Net.IPAddress]::IsLoopback($Address) -or $Address.Equals([Net.IPAddress]::Any) -or $Address.Equals([Net.IPAddress]::IPv6Any)) { return $false }
    $bytes = $Address.GetAddressBytes()
    if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        return ((($bytes[0] -band 0xE0) -eq 0x20) -and -not $Address.IsIPv6Multicast -and -not $Address.IsIPv6LinkLocal)
    }
    return ($bytes[0] -gt 0 -and $bytes[0] -lt 224 -and $bytes[0] -ne 10 -and $bytes[0] -ne 127 -and
        -not ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -and
        -not ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -and
        -not ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -and
        -not ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) -and
        -not ($bytes[0] -eq 192 -and $bytes[1] -eq 0 -and $bytes[2] -eq 2) -and
        -not ($bytes[0] -eq 198 -and $bytes[1] -eq 51 -and $bytes[2] -eq 100) -and
        -not ($bytes[0] -eq 203 -and $bytes[1] -eq 0 -and $bytes[2] -eq 113))
}


function Get-UpdateCandidate {
    param([ValidateSet('stable','beta','main')][string]$Channel)
    $headers = @{'User-Agent'=$script:UserAgent; Accept='application/vnd.github+json'}
    if ($Channel -eq 'main') {
        $commit = Invoke-RestMethod -Uri 'https://api.github.com/repos/MDI-GmbH/PSDynDNS/commits/main' -TimeoutSec 25 -Headers $headers
        if ([string]$commit.sha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Invalid main commit SHA.' }
        $file = Invoke-RestMethod -Uri ('https://api.github.com/repos/MDI-GmbH/PSDynDNS/contents/PSDynDNS.ps1?ref=' + $commit.sha) -TimeoutSec 25 -Headers $headers
        if ([string]$file.sha -notmatch '^[a-fA-F0-9]{40}$' -or $file.encoding -ne 'base64') { throw 'Invalid main source blob.' }
        $bytes = [Convert]::FromBase64String(([string]$file.content -replace '\s',''))
        $sha1 = [Security.Cryptography.SHA1]::Create()
        try {
            $prefix = [Text.Encoding]::ASCII.GetBytes(
                'blob ' + $bytes.Length + [char]0
            )
            $raw = New-Object byte[] ($prefix.Length + $bytes.Length)
            [Array]::Copy($prefix, 0, $raw, 0, $prefix.Length)
            [Array]::Copy($bytes, 0, $raw, $prefix.Length, $bytes.Length)
            $gitHash = [BitConverter]::ToString($sha1.ComputeHash($raw))
            $gitHash = $gitHash.Replace('-', '').ToLowerInvariant()
        } finally {
            $sha1.Dispose()
        }
        if ($gitHash -ne ([string]$file.sha).ToLowerInvariant()) { throw 'Git source blob digest mismatch.' }
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $digest = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha256.Dispose() }
        return [pscustomobject]@{Version=$null;Sha256=$digest;Content=$bytes;Commit=[string]$commit.sha;Channel='main'}
    }
    $url = if ($Channel -eq 'stable') { 'https://api.github.com/repos/MDI-GmbH/PSDynDNS/releases/latest' } else { 'https://api.github.com/repos/MDI-GmbH/PSDynDNS/releases?per_page=100' }
    $releases = @(Invoke-RestMethod -Uri $url -TimeoutSec 25 -Headers $headers)
    return Select-PSDynDnsRelease -Releases $releases -Channel $Channel
}
function Test-CandidateNewer {
    param($Candidate)
    if ($Candidate.Channel -eq 'main') { return $true }
    if ($script:Version -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?') { throw 'Invalid current script version.' }
    $currentCore = [version]($Matches[1] + '.' + $Matches[2] + '.' + $Matches[3])
    $currentKind = if ($Matches[4]) { [string]$Matches[4] } else { '' }
    $currentNumber = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
    $currentRank = if ($script:Version.EndsWith('-dev')) { 0 } else { switch ($currentKind) { 'alpha' {1} 'beta' {2} 'rc' {3} default {4} } }
    if ($Candidate.Version -gt $currentCore) { return $true }
    if ($Candidate.Version -lt $currentCore) { return $false }
    return ($Candidate.Rank -gt $currentRank -or ($Candidate.Rank -eq $currentRank -and $Candidate.PreNumber -gt $currentNumber))
}
function Start-SelfUpdate {
    param($Release)
    $target = $PSCommandPath
    if ([string]::IsNullOrEmpty($target)) { throw 'Self-update requires script execution from a file.' }
    $newFile = $target + '.new'
    $backup = $target + '.bak'
    try {
        if ($Release.Channel -eq 'main') { [IO.File]::WriteAllBytes($newFile,$Release.Content) }
        else { Invoke-WebRequest -Uri $Release.Url -OutFile $newFile -UseBasicParsing -TimeoutSec 60 }
        if ((Get-FileHash -LiteralPath $newFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Release.Sha256) { throw 'Update digest mismatch.' }
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($newFile,[ref]$tokens,[ref]$errors)
        if ($errors.Count -gt 0) { throw 'Updated script does not parse.' }
        # Isolated helper needs no admin rights: it can only replace the task-writable script.
        $helper = @'
param([int]$ParentPid,[string]$Original,[string]$Staged,[string]$Backup,[string]$Digest)
$ErrorActionPreference = 'Stop'
try {
    try { (Get-Process -Id $ParentPid -ErrorAction Stop).WaitForExit(60000) | Out-Null } catch {}
    if ((Get-FileHash -LiteralPath $Staged -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Digest) { throw 'Staging changed.' }
    # Preserve the installed client's restrictive DACL on the staged file
    # before moving either file. Do not attempt to change its owner.
    $installedAcl = Get-Acl -LiteralPath $Original
    $stagedAcl = Get-Acl -LiteralPath $Staged
    $access = [Security.AccessControl.AccessControlSections]::Access
    $stagedAcl.SetSecurityDescriptorSddlForm(
        $installedAcl.GetSecurityDescriptorSddlForm($access), $access)
    Set-Acl -LiteralPath $Staged -AclObject $stagedAcl
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Force }
    Move-Item -LiteralPath $Original -Destination $Backup -ErrorAction Stop
    try { Move-Item -LiteralPath $Staged -Destination $Original -ErrorAction Stop }
    catch { Move-Item -LiteralPath $Backup -Destination $Original -ErrorAction SilentlyContinue; throw }
} catch { exit 1 }
'@
        $helperPath = $target + '.swap.ps1'
        [IO.File]::WriteAllText($helperPath, $helper, (New-Object Text.UTF8Encoding($false)))
        # PowerShell 7 installs pwsh.exe, not powershell.exe, in $PSHOME.
        # The helper must run in the same edition as the client.
        $exeName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $exe = Join-Path $PSHOME $exeName
        # Build the entire template before applying -f. The formatting
        # operator binds more tightly than string concatenation in PowerShell.
        $argsTemplate = (
            '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
            '-File "{0}" -ParentPid {1} -Original "{2}" -Staged "{3}" ' +
            '-Backup "{4}" -Digest "{5}"'
        )
        $args = $argsTemplate -f (
            $helperPath, $PID, $target, $newFile, $backup, $Release.Sha256
        )
        Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden | Out-Null
    } catch {
        Remove-Item -LiteralPath $newFile -Force -ErrorAction SilentlyContinue
        throw
    }
}
function ConvertFrom-UtcTimestamp {
    param($Value)
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::ParseExact(
        [string]$Value,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}
function Invoke-SoftwareUpdate {
    param($Config,$State,[string]$StatePath,[string]$LogPath)
    if (-not $Config.AutoUpdate) { return }
    $now = [datetime]::UtcNow
    if ($State.LastSuccessfulUpdateCheckUtc) {
        try { if ($now -lt (ConvertFrom-UtcTimestamp $State.LastSuccessfulUpdateCheckUtc).AddHours([int]$Config.UpdateCheckHours)) { return } } catch {}
    }
    if ($State.LastUpdateAttemptUtc) {
        try { if ($now -lt (ConvertFrom-UtcTimestamp $State.LastUpdateAttemptUtc).AddMinutes(30)) { return } } catch {}
    }
    $State.LastUpdateAttemptUtc = $now.ToString('o')
    Save-ClientState $StatePath $State
    try {
        $channel = if ($null -ne $Config.PSObject.Properties['UpdateChannel'] -and $Config.UpdateChannel) { [string]$Config.UpdateChannel } else { 'stable' }
        if ($channel -notin @('stable','beta','main')) { throw 'Invalid UpdateChannel.' }
        $release = Get-UpdateCandidate $channel
        $needsUpdate = if ($channel -eq 'main') {
            (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.Sha256
        } else {
            Test-CandidateNewer $release
        }
        if (-not $needsUpdate) {
            $State.LastSuccessfulUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
            Save-ClientState $StatePath $State
            return
        }
        # Staging only starts a separate swap process; it is not confirmation
        # of installation. Leave the successful-check timestamp unchanged so
        # a failed download or swap can be retried after 30 minutes.
        Start-SelfUpdate $release
        Write-ClientLog $LogPath INFO 'Verified software update staged; pending process exit.'
    } catch {
        Write-ClientLog $LogPath WARN ('Software update check failed; retry possible after 30 minutes. ' + (Format-ClientFailure -ErrorRecord $_))
    }
}

function Invoke-ForcedUpgrade {
    param([string]$Path, [string]$ChannelOverride)

    $config = Read-ClientConfig $Path
    $channel = if ($ChannelOverride) {
        $ChannelOverride
    } elseif ($config.UpdateChannel) {
        [string]$config.UpdateChannel
    } else {
        'stable'
    }

    Write-Verbose "Retrieving latest available $channel version."
    $release = Get-UpdateCandidate -Channel $channel

    # ForceUpgrade intentionally reinstalls the selected channel's current
    # version, even if its version number is unchanged. It does not modify DNS.
    Start-SelfUpdate -Release $release
    Write-Host "Verified $channel update staged; replacement starts after exit."
}

function Invoke-Client {
    param([string]$Path, [bool]$Force)
    $phase = 'initialize'
    $secret = $null
    $logPath = $null
    try {
        $phase = 'resolve configuration path'
        $fullPath = [IO.Path]::GetFullPath($Path)
        $root = Split-Path -Parent $fullPath
        $runtime = Join-Path $root 'runtime'
        $logPath = Join-Path $runtime 'client.log'
        $phase = 'read configuration'
        Write-Verbose 'Reading DynDNS configuration.'
        $config = Read-ClientConfig $fullPath
        $statePath = Join-Path $runtime 'state.json'
        $phase = 'read state'
        $state = Read-ClientState $statePath
        $now = (Get-Date).ToUniversalTime()
        $fingerprint = Get-ConfigurationFingerprint $config
        $phase = 'check prior provider status'
        if ($state.BlockedReason -and $state.Fingerprint -eq $fingerprint -and -not $Force) {
            Invoke-SoftwareUpdate $config $state $statePath $logPath
            throw ('DynDNS remains blocked by provider: ' + [string]$state.BlockedReason + '. Correct the cause or use -SetKey/-ResetState.')
        }
        if ($state.RetryAfterUtc -and $state.Fingerprint -eq $fingerprint -and $now -lt (ConvertFrom-UtcTimestamp $state.RetryAfterUtc) -and -not $Force) {
            Invoke-SoftwareUpdate $config $state $statePath $logPath
            throw ('DynDNS provider requested backoff until ' + [string]$state.RetryAfterUtc)
        }
        $ipv4 = $null
        $ipv6 = $null
        if ($config.IPv4Enabled) {
            $phase = 'discover IPv4 address'
            Write-Verbose 'Checking public IPv4 address.'
            $ipv4 = Get-PublicAddress ([string]$config.IPv4CheckUrl) ([Net.Sockets.AddressFamily]::InterNetwork)
        }
        if ($config.IPv6Enabled) {
            $phase = 'discover IPv6 address'
            Write-Verbose 'Checking public IPv6 address.'
            $ipv6 = Get-PublicAddress ([string]$config.IPv6CheckUrl) ([Net.Sockets.AddressFamily]::InterNetworkV6)
        }
        $phase = 'compare public IP with DNS records'
        $servers = if ($null -ne $config.PSObject.Properties['DnsServers']) { [string[]]$config.DnsServers } else { @('8.8.8.8','8.8.4.4') }
        $dnsResult = $null
        if (-not $Force) {
            $dnsResult = Get-DnsComparison -Hostname $config.Hostname -Servers $servers `
                -IPv4 $ipv4 -IPv6 $ipv6 `
                -IPv4Enabled $config.IPv4Enabled -IPv6Enabled $config.IPv6Enabled
            if ($dnsResult.Matches) {
                Write-Verbose 'DNS records already match public IP; provider request skipped.'
                Write-ClientLog $logPath INFO 'DNS A/AAAA records match public IP; provider request skipped.'
                Invoke-SoftwareUpdate $config $state $statePath $logPath
                return
            }
            if ($state.LastProviderUpdateUtc -and $state.LastDnsObservation -eq $dnsResult.Observation -and
                $state.LastIPv4 -eq $ipv4 -and $state.LastIPv6 -eq $ipv6) {
                try {
                    if ($now -lt (ConvertFrom-UtcTimestamp $state.LastProviderUpdateUtc).AddMinutes(30)) {
                        Write-Verbose 'Resolver still reports the pre-update record; waiting for DNS cache expiry.'
                        Write-ClientLog $logPath INFO 'DNS cache still contains prior answer; provider retry postponed.'
                        Invoke-SoftwareUpdate $config $state $statePath $logPath
                        return
                    }
                } catch {}
            }
        }
        Write-Verbose 'DNS differs from public IP (or update forced); DynDNS provider request required.'
        $phase = 'read DPAPI credential'
        Write-Verbose 'Decrypting machine-protected DynDNS credential.'
        $secret = Read-MachineSecret (Join-Path $root 'secret.dpapi')
        $addresses = @($ipv4,$ipv6) | Where-Object { $_ }
        $phase = 'send DynDNS2 HTTPS request'
        Write-Verbose 'Sending authenticated DynDNS2 update.'
        $response = Invoke-DynDnsRequest $config $secret ($addresses -join ',')
        $code = ($response -split '\s+')[0]
        $category = Get-ResponseCategory $response
    Write-Verbose ('DynDNS provider response: ' + $code)
        $newState = [ordered]@{
            Fingerprint = $fingerprint
            LastIPv4 = $state.LastIPv4
            LastIPv6 = $state.LastIPv6
            BlockedReason = $null
            RetryAfterUtc = $null
            LastUpdateAttemptUtc = $state.LastUpdateAttemptUtc
            LastSuccessfulUpdateCheckUtc = $state.LastSuccessfulUpdateCheckUtc
            LastProviderUpdateUtc = $state.LastProviderUpdateUtc
            LastDnsObservation = $state.LastDnsObservation
        }
        switch ($category) {
            success {
                $newState.LastIPv4 = $ipv4
                $newState.LastIPv6 = $ipv6
                $newState.LastProviderUpdateUtc = $now.ToString('o')
                if ($dnsResult) { $newState.LastDnsObservation = $dnsResult.Observation }
                Write-ClientLog $logPath INFO "DynDNS update succeeded: $code"
            }
            blocked {
                $newState.BlockedReason = $code
                $newState.Fingerprint = $fingerprint
                Write-ClientLog $logPath ERROR "DynDNS update blocked: $code"
            }
            retry {
                $newState.Fingerprint = $fingerprint
                $newState.RetryAfterUtc = $now.AddMinutes(30).ToString('o')
                Write-ClientLog $logPath WARN "DynDNS provider requested retry: $code"
            }
        }
        if ($category -eq 'unknown') {
            throw 'Unrecognized DynDNS2 provider response.'
        }
        $phase = 'save state'
        Save-ClientState $statePath $newState
    if ($category -eq 'blocked') { throw ('DynDNS provider permanently rejected update: ' + $code) }
    if ($category -eq 'retry') { throw ('DynDNS provider requested retry: ' + $code) }
        $phase = 'check for software updates'
        Invoke-SoftwareUpdate $config $newState $statePath $logPath
    } catch {
        $diagnostic = 'DynDNS failed during ' + $phase + ': ' + (Format-ClientFailure -ErrorRecord $_ -Secret $secret)
        if ($logPath) {
            try { Write-ClientLog $logPath ERROR $diagnostic }
            catch { Write-Warning 'Could not write diagnostic details to client.log.' }
        }
        throw $diagnostic
    } finally {
        $secret = $null
    }
}
# Dot-source is deliberately supported for tests; direct invocation runs the client.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($UpgradeChannel -and -not $ForceUpgrade) {
            throw '-UpgradeChannel requires -ForceUpgrade.'
        }
        if ($ForceUpgrade -and $ForceDnsUpdate) {
            throw 'Use -ForceUpgrade or -ForceDnsUpdate, not both.'
        }
        if ($ForceUpgrade) {
            Invoke-ForcedUpgrade -Path $ConfigPath -ChannelOverride $UpgradeChannel
        } else {
            Invoke-Client -Path $ConfigPath -Force ([bool]$ForceDnsUpdate.IsPresent)
        }
    }
    catch {
        # Invoke-Client already logged the sanitized, phase-specific cause.
        # Preserve that cause on the console instead of hiding it.
        Write-Error $_.Exception.Message
        exit 1
    }
}
