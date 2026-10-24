#requires -Version 5.1
[CmdletBinding()]
param([switch]$Update)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sharedFile = Join-Path $root 'src/PSDynDNS.Shared.ps1'
$newline = [string][char]10
$crlf = [string][char]13 + [char]10
$source = [IO.File]::ReadAllText($sharedFile).Replace($crlf,$newline).TrimEnd([char]10)
$startMarker = '# BEGIN GENERATED SHARED FUNCTIONS' + $newline
$endMarker = '# END GENERATED SHARED FUNCTIONS'
foreach ($relative in @('PSDynDNS.ps1','Install-PSDynDNS.ps1')) {
    $path = Join-Path $root $relative
    $file = [IO.File]::ReadAllText($path).Replace($crlf,$newline)
    $start = $file.IndexOf($startMarker,[StringComparison]::Ordinal)
    $end = $file.IndexOf($endMarker,[StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) { throw "Generated block markers missing in $relative" }
    $contentStart = $start + $startMarker.Length
    $current = $file.Substring($contentStart,$end-$contentStart).TrimEnd([char]10)
    if ($current -ne $source) {
        if (-not $Update) { throw "$relative shared functions differ from src/PSDynDNS.Shared.ps1. Run tools/Sync-Shared.ps1 -Update." }
        $file = $file.Substring(0,$contentStart) + $source + $newline + $file.Substring($end)
        [IO.File]::WriteAllText($path,$file,(New-Object Text.UTF8Encoding($false)))
        Write-Host "Synchronized $relative"
    } else {
        Write-Host "Shared code matches $relative"
    }
}
