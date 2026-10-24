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

# BEGIN GENERATED SHARED FUNCTIONS
# Canonical implementation embedded into both standalone PowerShell scripts.
# After editing, run: ./tools/Sync-Shared.ps1 -Update
function Assert-PSDynDnsSettings {
    param($Cfg)
    $hostName = [string]$Cfg.Hostname
    if ([string]::IsNullOrWhiteSpace($hostName) -or
        $hostName -notmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$') {
        throw 'Hostname must be a valid FQDN.'
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
    if ($null -ne $Cfg.PSObject.Properties['UpdateChannel'] -and $Cfg.UpdateChannel -notin @('stable','beta','main')) {
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
    if ($State.LastUpdateCheckUtc) {
        try { if ($now -lt (ConvertFrom-UtcTimestamp $State.LastUpdateCheckUtc).AddHours([int]$Config.UpdateCheckHours)) { return } } catch {}
    }
    if ($null -eq $State.PSObject.Properties['LastUpdateAttemptUtc']) { Add-Member -InputObject $State -NotePropertyName LastUpdateAttemptUtc -NotePropertyValue $null }
    if ($State.LastUpdateAttemptUtc) {
        try { if ($now -lt (ConvertFrom-UtcTimestamp $State.LastUpdateAttemptUtc).AddMinutes(30)) { return } } catch {}
    }
    $State.LastUpdateAttemptUtc = $now.ToString('o')
    Save-ClientState $StatePath $State
    try {
        $channel = if ($Config.PSObject.Properties['UpdateChannel'] -and $Config.UpdateChannel) { [string]$Config.UpdateChannel } else { 'stable' }
        if ($channel -notin @('stable','beta','main')) { throw 'Invalid UpdateChannel.' }
        $release = Get-UpdateCandidate $channel
        $State.LastUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
        Save-ClientState $StatePath $State
        if ($channel -eq 'main') {
            if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $release.Sha256) { return }
        } elseif (-not (Test-CandidateNewer $release)) { return }
        Start-SelfUpdate $release
        Write-ClientLog $LogPath INFO 'Verified software update staged; pending process exit.'
    } catch {
        Write-ClientLog $LogPath WARN ('Software update check failed; current script retained. ' + (Format-ClientFailure -ErrorRecord $_))
    }
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
        if ($state.BlockedReason -and $state.Fingerprint -eq $fingerprint -and -not $Force) {
            Write-Verbose ('DynDNS update suppressed: provider previously blocked the configuration (' + [string]$state.BlockedReason + ').')
            Invoke-SoftwareUpdate $config $state $statePath $logPath
            return
        }
        if ($state.RetryAfterUtc -and $state.Fingerprint -eq $fingerprint -and $now -lt (ConvertFrom-UtcTimestamp $state.RetryAfterUtc) -and -not $Force) { Invoke-SoftwareUpdate $config $state $statePath $logPath; return }
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
    if (-not $Force -and (Test-DnsMatchesPublicAddress -Hostname $config.Hostname -Servers $servers -IPv4 $ipv4 -IPv6 $ipv6 -IPv4Enabled $config.IPv4Enabled -IPv6Enabled $config.IPv6Enabled)) {
        Write-Verbose 'DNS records already match public IP; provider update skipped.'
        Invoke-SoftwareUpdate $config $state $statePath $logPath
        return
    }
    Write-Verbose 'DNS records differ from public IP; provider update required.'
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
        $phase = 'save state'
        Save-ClientState $statePath $newState
    if ($category -eq 'blocked') { throw ('Permanent DynDNS provider rejection: ' + $code) }
    if ($category -eq 'retry') { throw ('Temporary DynDNS provider failure: ' + $code) }
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
    try { Invoke-Client -Path $ConfigPath -Force ([bool]$ForceDnsUpdate.IsPresent) }
    catch {
        # Invoke-Client already logged the sanitized, phase-specific cause.
        # Preserve that cause on the console instead of hiding it.
        Write-Error $_.Exception.Message
        exit 1
    }
}
