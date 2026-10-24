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
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$ForceDnsUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
    if ([Net.IPAddress]::IsLoopback($address) -or $address.IsIPv6LinkLocal -or $address.IsIPv6Multicast -or $address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::IPv6Any)) {
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
    return 'retry'
}

function Read-ClientState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw 'State file is corrupted; manual recovery is required.' }
}

function Save-ClientState {
    param([string]$Path, $State)
    $temporary = $Path + '.tmp'
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-ClientLog {
    param([string]$Path, [string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date).ToUniversalTime().ToString('o'), $Level, $Message
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge 1048576) {
        Move-Item -LiteralPath $Path -Destination ($Path + '.1') -Force
    }
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Invoke-Client {
    param([string]$Path, [bool]$Force)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = Split-Path -Parent $fullPath
    $logPath = Join-Path $root 'client.log'
    $config = Read-ClientConfig $fullPath
    $statePath = Join-Path $root 'state.json'
    $state = Read-ClientState $statePath
    $now = (Get-Date).ToUniversalTime()
    $fingerprint = Get-ConfigurationFingerprint $config
    if ($state.BlockedReason -and -not $Force) {
        Write-ClientLog $logPath WARN 'Update blocked; administrator must correct issue and reset state.'
        return
    }
    if ($state.RetryAfterUtc -and $now -lt [datetime]$state.RetryAfterUtc -and -not $Force) { return }
    $ipv4 = $null
    $ipv6 = $null
    if ($config.IPv4Enabled) { $ipv4 = Get-PublicAddress ([string]$config.IPv4CheckUrl) ([Net.Sockets.AddressFamily]::InterNetwork) }
    if ($config.IPv6Enabled) { $ipv6 = Get-PublicAddress ([string]$config.IPv6CheckUrl) ([Net.Sockets.AddressFamily]::InterNetworkV6) }
    if (-not $Force -and $state.Fingerprint -eq $fingerprint -and $state.LastIPv4 -eq $ipv4 -and $state.LastIPv6 -eq $ipv6) { return }
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
    }
    switch ($category) {
        success {
            $newState.LastIPv4 = $ipv4
            $newState.LastIPv6 = $ipv6
            Write-ClientLog $logPath INFO "DynDNS update succeeded: $code"
        }
        blocked {
            $newState.BlockedReason = $code
            Write-ClientLog $logPath ERROR "DynDNS update blocked: $code"
        }
        retry {
            $newState.RetryAfterUtc = $now.AddMinutes(30).ToString('o')
            Write-ClientLog $logPath WARN "DynDNS provider requested retry: $code"
        }
    }
    Save-ClientState $statePath $newState
}

# Dot-source is deliberately supported for tests; direct invocation runs the client.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Client -Path $ConfigPath -Force ([bool]$ForceDnsUpdate.IsPresent) }
    catch {
        $message = $_.Exception.Message
        try {
            $root = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
            Write-ClientLog (Join-Path $root 'client.log') ERROR $message
        } catch { }
        Write-Error $message
        exit 1
    }
}
