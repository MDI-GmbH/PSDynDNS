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
    [switch]$ForceDnsUpdate
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

function Assert-HttpsUrl {
    param([string]$Url)
    $parsed = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'https' -or -not $parsed.Host -or $parsed.UserInfo) {
        throw 'An absolute HTTPS URL without embedded credentials is required.'
    }
}

function Read-ClientConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration not found: $Path" }
    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$cfg.Hostname) -or $cfg.Hostname -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$') {
        throw 'Hostname must be a valid FQDN.'
    }
    if (-not $cfg.IPv4Enabled -and -not $cfg.IPv6Enabled) { throw 'Enable IPv4 and/or IPv6.' }
    Assert-HttpsUrl ([string]$cfg.UpdateUrl)
    if ($cfg.IPv4Enabled) { Assert-HttpsUrl ([string]$cfg.IPv4CheckUrl) }
    if ($cfg.IPv6Enabled) { Assert-HttpsUrl ([string]$cfg.IPv6CheckUrl) }
    return $cfg
}

function Get-ConfigurationFingerprint {
    param($Config)
    $value = @([string]$Config.Hostname, [string]$Config.Username, [string]$Config.UpdateUrl,
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
    $result = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0 -Headers @{ 'User-Agent' = $script:UserAgent }).Content.Trim()
    $address = $null
    if (-not [Net.IPAddress]::TryParse($result, [ref]$address) -or $address.AddressFamily -ne $Family) { throw 'IP-check response is not an address of the expected family.' }
    if (-not (Test-PublicIp $address)) {
        throw 'IP-check returned a non-routable address.'
    }
    return $address.ToString()
}

function Invoke-DynDnsRequest {
    param($Config, [string]$Secret, [string]$AddressList)
    $username = if ([string]::IsNullOrEmpty([string]$Config.Username)) { [string]$Config.Hostname } else { [string]$Config.Username }
    $pair = '{0}:{1}' -f $username, $Secret
    $authorization = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $separator = if ([string]$Config.UpdateUrl -match '\?') { '&' } else { '?' }
    $uri = [string]$Config.UpdateUrl + $separator + 'hostname=' + [uri]::EscapeDataString([string]$Config.Hostname) + '&myip=' + [uri]::EscapeDataString($AddressList)
    try {
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 0 -Headers @{
            Authorization = 'Basic ' + $authorization
            'User-Agent' = $script:UserAgent
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
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ LastIPv4=$null; LastIPv6=$null; Fingerprint=$null; BlockedReason=$null; RetryAfterUtc=$null; LastUpdateCheckUtc=$null } }
    try { $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in @('LastIPv4','LastIPv6','Fingerprint','BlockedReason','RetryAfterUtc','LastUpdateCheckUtc')) {
            if (-not ($state.PSObject.Properties.Name -contains $property)) { $state | Add-Member -NotePropertyName $property -NotePropertyValue $null }
        }
        return $state }
    catch { throw 'State file is corrupted; manual recovery is required.' }
}

function Save-ClientState {
    param([string]$Path, $State)
    $temporary = $Path + '.tmp'
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
    if (Test-Path -LiteralPath $Path) {
        [IO.File]::Replace($temporary, $Path, $null)
    } else {
        [IO.File]::Move($temporary, $Path)
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
        try { $prefix = [Text.Encoding]::ASCII.GetBytes(('blob ' + $bytes.Length + [char]0)); $raw = New-Object byte[] ($prefix.Length + $bytes.Length); [Array]::Copy($prefix,0,$raw,0,$prefix.Length); [Array]::Copy($bytes,0,$raw,$prefix.Length,$bytes.Length); $gitHash = ([BitConverter]::ToString($sha1.ComputeHash($raw))).Replace('-','').ToLowerInvariant() } finally { $sha1.Dispose() }
        if ($gitHash -ne ([string]$file.sha).ToLowerInvariant()) { throw 'Git source blob digest mismatch.' }
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $digest = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha256.Dispose() }
        return [pscustomobject]@{Version=$null;Sha256=$digest;Content=$bytes;Commit=[string]$commit.sha;Channel='main'}
    }
    $url = if ($Channel -eq 'stable') { 'https://api.github.com/repos/MDI-GmbH/PSDynDNS/releases/latest' } else { 'https://api.github.com/repos/MDI-GmbH/PSDynDNS/releases?per_page=100' }
    $releases = @(Invoke-RestMethod -Uri $url -TimeoutSec 25 -Headers $headers)
    $candidates = @()
    foreach ($release in $releases) {
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
        $u = [uri]$assets[0].browser_download_url
        if ($u.Scheme -ne 'https' -or $u.Host -ne 'github.com' -or -not $u.AbsolutePath.StartsWith('/MDI-GmbH/PSDynDNS/releases/download/',[StringComparison]::OrdinalIgnoreCase)) { continue }
        $candidates += [pscustomobject]@{ Version=$core;Rank=$rank;PreNumber=$number;Tag=$tag;Url=$u.AbsoluteUri;Sha256=$digest;Content=$null;Commit=$null;Channel=$Channel }
    }
    if ($candidates.Count -eq 0) { throw 'No usable published release.' }
    return $candidates | Sort-Object -Property @{Expression='Version';Descending=$true},@{Expression='Rank';Descending=$true},@{Expression='PreNumber';Descending=$true} | Select-Object -First 1
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
        $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ParentPid {1} -Original "{2}" -Staged "{3}" -Backup "{4}" -Digest "{5}"' -f $helperPath,$PID,$target,$newFile,$backup,$Release.Sha256
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
    return [datetimeoffset]::ParseExact(
        [string]$Value,
        'o',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
}
function Invoke-SoftwareUpdate {
    param($Config,$State,[string]$StatePath,[string]$LogPath)
    if (-not $Config.AutoUpdate) { return }
    $now = [datetime]::UtcNow
    if ($State.LastUpdateCheckUtc) {
        try { if ($now -lt (ConvertFrom-UtcTimestamp $State.LastUpdateCheckUtc).AddHours([int]$Config.UpdateCheckHours)) { return } } catch {}
    }
    $State.LastUpdateCheckUtc = $now.ToString('o')
    Save-ClientState $StatePath $State
    try {
        $channel = if ($Config.PSObject.Properties['UpdateChannel'] -and $Config.UpdateChannel) { [string]$Config.UpdateChannel } else { 'stable' }
        if ($channel -notin @('stable','beta','main')) { throw 'Invalid UpdateChannel.' }
        $release = Get-UpdateCandidate $channel
        if ($channel -eq 'main') {
            if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $release.Sha256) { return }
        } elseif (-not (Test-CandidateNewer $release)) { return }
        Start-SelfUpdate $release
        Write-ClientLog $LogPath INFO 'Verified software update staged; pending process exit.'
    } catch {
        Write-ClientLog $LogPath WARN 'Software update check or installation failed; current script retained.'
    }
}

function Invoke-Client {
    param([string]$Path, [bool]$Force)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = Split-Path -Parent $fullPath
    $runtime = Join-Path $root 'runtime'
    $logPath = Join-Path $runtime 'client.log'
    $config = Read-ClientConfig $fullPath
    $statePath = Join-Path $runtime 'state.json'
    $state = Read-ClientState $statePath
    $now = (Get-Date).ToUniversalTime()
    $fingerprint = Get-ConfigurationFingerprint $config
    if ($state.BlockedReason -and $state.Fingerprint -eq $fingerprint -and -not $Force) {
        Invoke-SoftwareUpdate $config $state $statePath $logPath
        return
    }
    if ($state.RetryAfterUtc -and $state.Fingerprint -eq $fingerprint -and $now -lt (ConvertFrom-UtcTimestamp $state.RetryAfterUtc) -and -not $Force) { Invoke-SoftwareUpdate $config $state $statePath $logPath; return }
    $ipv4 = $null
    $ipv6 = $null
    if ($config.IPv4Enabled) { $ipv4 = Get-PublicAddress ([string]$config.IPv4CheckUrl) ([Net.Sockets.AddressFamily]::InterNetwork) }
    if ($config.IPv6Enabled) { $ipv6 = Get-PublicAddress ([string]$config.IPv6CheckUrl) ([Net.Sockets.AddressFamily]::InterNetworkV6) }
    if (-not $Force -and $state.Fingerprint -eq $fingerprint -and $state.LastIPv4 -eq $ipv4 -and $state.LastIPv6 -eq $ipv6) { Invoke-SoftwareUpdate $config $state $statePath $logPath; return }
    $secret = Read-MachineSecret (Join-Path $root 'secret.dpapi')
    $addresses = @($ipv4,$ipv6) | Where-Object { $_ }
    $response = Invoke-DynDnsRequest $config $secret ($addresses -join ',')
    $code = ($response -split '\s+')[0]
    $category = Get-ResponseCategory $response
    $newState = [ordered]@{
        Fingerprint = $fingerprint
        LastIPv4 = $state.LastIPv4
        LastIPv6 = $state.LastIPv6
        BlockedReason = $null
        RetryAfterUtc = $null
        LastUpdateCheckUtc = $state.LastUpdateCheckUtc
    }
    switch ($category) {
        success {
            $newState.LastIPv4 = $ipv4
            $newState.LastIPv6 = $ipv6
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
    Save-ClientState $statePath $newState
    Invoke-SoftwareUpdate $config $newState $statePath $logPath
}

# Dot-source is deliberately supported for tests; direct invocation runs the client.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Client -Path $ConfigPath -Force ([bool]$ForceDnsUpdate.IsPresent) }
    catch {
        try {
            $root = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
            Write-ClientLog (Join-Path (Join-Path $root 'runtime') 'client.log') ERROR 'DynDNS run failed. See configuration and network.'
        } catch { }
        Write-Error 'DynDNS run failed; see client.log.'
        exit 1
    }
}
