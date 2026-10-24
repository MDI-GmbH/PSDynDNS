#requires -Version 5.1
# Real native child-process tests for update, replacement and rollback.
Describe 'PSDynDNS self-update integration' -Tag 'Integration' {
    It 'rejects invalid updates, atomically replaces valid code and restores on failure' {
$Runtime = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell7' } else { 'WindowsPowerShell' }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'PSDynDNS.ps1'
$source = [IO.File]::ReadAllText($sourceFile)
$marker = '# Dot-source is deliberately supported for tests; direct invocation runs the client.'
$end = $source.IndexOf($marker,[StringComparison]::Ordinal)
if ($end -lt 0) { throw 'Client execution footer not found.' }
$fixture = $source.Substring(0,$end) + @'
# Only the invocation footer of this temporary test copy is different.
try {
    $candidate = [pscustomobject]@{
        Channel='main'
        Content=[IO.File]::ReadAllBytes($env:PSDYNDNS_CI_PAYLOAD)
        Sha256=$env:PSDYNDNS_CI_DIGEST
    }
    Start-SelfUpdate $candidate
} catch {
    Write-Host ('CI-UPDATE-ERROR: ' + $_.Exception.Message)
    exit 20
}
'@

$exe = if ($Runtime -eq 'PowerShell7') {
    (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
} else {
    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
}
$utf8 = New-Object Text.UTF8Encoding($false)
$testRoot = Join-Path $env:TEMP ('PSDynDNS-SelfUpdate-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null

function Assert-Ci {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw ('SELF-UPDATE INTEGRATION FAILED: ' + $Message) }
    Write-Host ('PASS: ' + $Message)
}
function Hash-Ci {
    param([string]$File)
    return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Wait-CiHash {
    param([string]$File,[string]$Hash)
    for ($n=0;$n -lt 120;$n++) {
        if (Test-Path -LiteralPath $File -PathType Leaf) {
            try { if ((Hash-Ci $File) -eq $Hash) { return $true } } catch {}
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
function Invoke-CiUpdate {
    param([string]$Case,[string]$NewText,[bool]$BadDigest=$false)
    $dir = Join-Path $testRoot $Case
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $client = Join-Path $dir 'PSDynDNS.ps1'
    $payload = Join-Path $dir 'payload.txt'
    [IO.File]::WriteAllText($client,$fixture,$utf8)
    [IO.File]::WriteAllText($payload,$NewText,$utf8)
    $old = Hash-Ci $client
    $new = Hash-Ci $payload
    $env:PSDYNDNS_CI_PAYLOAD = $payload
    $env:PSDYNDNS_CI_DIGEST = if ($BadDigest) { '0000000000000000000000000000000000000000000000000000000000000000' } else { $new }
    try {
        # Native stdout must not become part of the function's return value.
        # PowerShell 7's strict mode otherwise sees a string instead of
        # the result object and reports missing properties like ExitCode.
        $output = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $client 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { $output | ForEach-Object { Write-Host ([string]$_) } }
    } finally {
        Remove-Item Env:PSDYNDNS_CI_PAYLOAD,Env:PSDYNDNS_CI_DIGEST -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Target=$client;OldHash=$old;NewHash=$new;ExitCode=$exitCode
        Stage=($client+'.new');Backup=($client+'.bak')
    }
}
function Get-RealHelper {
    # Extract the exact helper heredoc from the actual shipped updater.
    $needle = '$helper = @' + [char]39
    $begin = $source.IndexOf($needle,[StringComparison]::Ordinal)
    if ($begin -lt 0) { throw 'Self-update helper not found in client.' }
    $begin = $source.IndexOf([char]10,$begin) + 1
    $finish = $source.IndexOf(([string][char]10 + "'@"),$begin,[StringComparison]::Ordinal)
    if ($begin -le 0 -or $finish -lt 0) { throw 'Invalid helper heredoc delimiters.' }
    return $source.Substring($begin,$finish-$begin).TrimEnd([char]13)
}

try {
    Write-Host ('Testing self-update integration under ' + $Runtime)

    $bad = Invoke-CiUpdate -Case 'bad-digest' -NewText 'Write-Host "updated"' -BadDigest $true
    Assert-Ci ($bad.ExitCode -eq 20) 'Digest mismatch rejects update'
    Assert-Ci ((Hash-Ci $bad.Target) -eq $bad.OldHash) 'Digest mismatch preserves original'
    Assert-Ci (-not (Test-Path -LiteralPath $bad.Stage)) 'Digest mismatch cleans staged file'

    $syntax = Invoke-CiUpdate -Case 'bad-syntax' -NewText 'function Unclosed {'
    Assert-Ci ($syntax.ExitCode -eq 20) 'Invalid PowerShell syntax rejects update'
    Assert-Ci ((Hash-Ci $syntax.Target) -eq $syntax.OldHash) 'Invalid syntax preserves original'
    Assert-Ci (-not (Test-Path -LiteralPath $syntax.Stage)) 'Invalid syntax cleans staged file'

    $good = Invoke-CiUpdate -Case 'success' -NewText 'Write-Host "updated version"'
    Assert-Ci ($good.ExitCode -eq 0) 'Valid update starts asynchronous replacement'
    Assert-Ci (Wait-CiHash -File $good.Target -Hash $good.NewHash) 'Helper replaces client with new bytes'
    Assert-Ci (Wait-CiHash -File $good.Backup -Hash $good.OldHash) 'Helper backs up previous client'
    Assert-Ci (-not (Test-Path -LiteralPath $good.Stage)) 'Helper consumes staged update'

    # Inject a deterministic failure at the SECOND move operation.
    # Place the fault-injection function in the SAME script scope as the
    # extracted production helper. A wrapper script around the helper
    # can mask its exit code or fail to shadow Move-Item correctly.
    $dir = Join-Path $testRoot 'rollback'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $original = Join-Path $dir 'PSDynDNS.ps1'
    $stage = $original + '.new'
    $backup = $original + '.bak'
    $helper = Join-Path $dir 'swap.ps1'
    [IO.File]::WriteAllText($original,'Write-Host "original"',$utf8)
    [IO.File]::WriteAllText($stage,'Write-Host "new version"',$utf8)
    $originalHash = Hash-Ci $original
    $stageHash = Hash-Ci $stage
    $injection = @'
function Move-Item {
    [CmdletBinding()]
    param([string]$LiteralPath,[string]$Destination)
    if ($LiteralPath -eq $Staged -and $Destination -eq $Original) {
        throw 'Deliberately injected second move failure'
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
}
'@
    $actualHelper = Get-RealHelper
    $firstTry = $actualHelper.IndexOf('try {',[StringComparison]::Ordinal)
    if ($firstTry -lt 0) { throw 'Cannot locate helper fault injection point.' }
    $injectedHelper = $actualHelper.Insert($firstTry,($injection + [Environment]::NewLine))
    [IO.File]::WriteAllText($helper,$injectedHelper,$utf8)
    $rollbackOutput = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -ParentPid 0 -Original $original -Staged $stage -Backup $backup -Digest $stageHash 2>&1
    $exit = $LASTEXITCODE
    if ($rollbackOutput) { $rollbackOutput | ForEach-Object { Write-Host ('Rollback process: ' + [string]$_) } }
    Assert-Ci ($exit -ne 0) 'Injected second move forces helper failure'
    Assert-Ci (Test-Path -LiteralPath $original -PathType Leaf) 'Rollback restores original file'
    Assert-Ci ((Hash-Ci $original) -eq $originalHash) 'Rollback restores original bytes'
    Assert-Ci (-not (Test-Path -LiteralPath $backup)) 'Rollback consumes temporary backup'
    # The injected rollback failure is expected and already asserted above.
    # GitHub Actions' PowerShell wrappers exit using LASTEXITCODE when it exists,
    # even after every subsequent PowerShell assertion has passed. Clear only
    # after all negative and positive test scenarios have succeeded.
    $global:LASTEXITCODE = 0
    Write-Host ('SUCCESS: self-update checksum, syntax, replacement and rollback under ' + $Runtime)
}
finally {
    Remove-Item Env:PSDYNDNS_CI_PAYLOAD,Env:PSDYNDNS_CI_DIGEST -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

    }
}
