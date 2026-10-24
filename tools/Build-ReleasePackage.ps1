#requires -Version 5.1
<#
.SYNOPSIS
    Build and verify release assets without publishing a release.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Version,
    [switch]$VerifyOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta|rc)\.([1-9][0-9]*))?$') {
    throw 'Invalid release version.'
}

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$tag = 'v' + $Version
$client = Join-Path $dist 'PSDynDNS.ps1'
$zipPath = Join-Path $dist ('PSDynDNS-' + $tag + '.zip')
$names = @('PSDynDNS.ps1', 'Install-PSDynDNS.ps1', ('PSDynDNS-' + $tag + '.zip'))
$zipNames = @('PSDynDNS.ps1', 'Install-PSDynDNS.ps1', 'config.example.json', 'README.md', 'LICENSE')

if (-not $VerifyOnly) {
    $path = Join-Path $root 'PSDynDNS.ps1'
    $source = [IO.File]::ReadAllText($path)
    $placeholder = '$script:Version = ' + [char]39 + '0.1.0-dev' + [char]39
    if ([regex]::Matches($source, [regex]::Escape($placeholder)).Count -ne 1) {
        throw 'Expected exactly one source version placeholder.'
    }
    $stamped = '$script:Version = ' + [char]39 + $Version + [char]39
    [IO.File]::WriteAllText($path, $source.Replace($placeholder, $stamped),
        (New-Object Text.UTF8Encoding($false)))

    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Version-stamped release script failed PowerShell parsing.' }

    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    Copy-Item -LiteralPath $path -Destination $client
    Copy-Item -LiteralPath (Join-Path $root 'Install-PSDynDNS.ps1') -Destination $dist
    Push-Location $root
    try {
        Compress-Archive -Path $zipNames -DestinationPath $zipPath -Force
    } finally {
        Pop-Location
    }

    $lines = @($names | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath (Join-Path $dist $_) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $_"
    })
    [IO.File]::WriteAllLines((Join-Path $dist 'SHA256SUMS.txt'), $lines,
        (New-Object Text.UTF8Encoding($false)))
}

# Verify the exact stamped version, all checksums and all ZIP entries.
if (-not (Test-Path -LiteralPath $client -PathType Leaf)) { throw 'Client asset missing.' }
$actualLines = @([IO.File]::ReadAllLines($client) | Where-Object { $_ -match '^\$script:Version\s*=' })
$expectedLine = '$script:Version = ' + [char]39 + $Version + [char]39
if ($actualLines.Count -ne 1 -or $actualLines[0] -cne $expectedLine) {
    throw "Release asset version must be exactly $Version."
}

$manifest = @([IO.File]::ReadAllLines((Join-Path $dist 'SHA256SUMS.txt')))
if ($manifest.Count -ne $names.Count) { throw 'Unexpected checksum manifest entry count.' }
foreach ($name in $names) {
    $hash = (Get-FileHash -LiteralPath (Join-Path $dist $name) -Algorithm SHA256).Hash.ToLowerInvariant()
    if (@($manifest | Where-Object { $_ -ceq "$hash  $name" }).Count -ne 1) {
        throw "SHA256SUMS.txt verification failed: $name."
    }
}

Add-Type -AssemblyName System.IO.Compression
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    if ($zip.Entries.Count -ne $zipNames.Count) { throw 'Unexpected release ZIP entries.' }
    foreach ($name in $zipNames) {
        $entries = @($zip.Entries | Where-Object { $_.FullName -ceq $name })
        if ($entries.Count -ne 1) { throw "ZIP entry missing or duplicated: $name." }
        $reference = if ($name -in @('PSDynDNS.ps1', 'Install-PSDynDNS.ps1')) {
            Join-Path $dist $name
        } else {
            Join-Path $root $name
        }
        $expectedHash = (Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash.ToLowerInvariant()
        $stream = $entries[0].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
            $stream.Dispose()
        }
        if ($expectedHash -cne $actualHash) { throw "ZIP content differs from asset: $name." }
    }
} finally {
    $zip.Dispose()
}
Write-Host "Release package verified (not published): $tag"
