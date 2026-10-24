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
