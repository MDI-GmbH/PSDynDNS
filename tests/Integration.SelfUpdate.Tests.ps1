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
    for ($n=0;$n -lt 320;$n++) {
        if (Test-Path -LiteralPath $File -PathType Leaf) {
            try { if ((Hash-Ci $File) -eq $Hash) { return $true } } catch {}
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}
function Invoke-CiUpdate {
    param([string]$Case,[string]$NewText,[bool]$BadDigest=$false,[bool]$StaleStage=$false,[bool]$OldBackup=$false)
    $dir = Join-Path $testRoot $Case
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $client = Join-Path $dir 'PSDynDNS.ps1'
    $payload = Join-Path $dir 'payload.txt'
    [IO.File]::WriteAllText($client,$fixture,$utf8)
    [IO.File]::WriteAllText($payload,$NewText,$utf8)
    if ($StaleStage) {
        [IO.File]::WriteAllText(($client + '.new'), 'orphaned staging',$utf8)
    }
    if ($OldBackup) {
        [IO.File]::WriteAllText(($client + '.bak'), 'prior backup',$utf8)
    }
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
    $replaced = Wait-CiHash -File $good.Target -Hash $good.NewHash
    if (-not $replaced) {
        foreach ($file in @($good.Target,$good.Stage,$good.Backup)) {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                Write-Host ('Self-update diagnostic: ' + $file +
                    ' SHA256=' + (Hash-Ci $file))
            } else {
                Write-Host ('Self-update diagnostic: missing ' + $file)
            }
        }
    }
    Assert-Ci $replaced 'Helper replaces client with new bytes'
    Assert-Ci (Wait-CiHash -File $good.Backup -Hash $good.OldHash) 'Helper backs up previous client'
    Assert-Ci (-not (Test-Path -LiteralPath $good.Stage)) 'Helper consumes staged update'

    $retry = Invoke-CiUpdate -Case 'stale-stage-and-backup' -NewText 'Write-Host "retry succeeded"' -StaleStage $true -OldBackup $true
    Assert-Ci ($retry.ExitCode -eq 0) 'Retry starts with existing staging and backup'
    Assert-Ci (Wait-CiHash -File $retry.Target -Hash $retry.NewHash) 'Retry replaces client despite stale stage'
    Assert-Ci (-not (Test-Path -LiteralPath $retry.Stage)) 'Retry consumes the stale stage'
    Assert-Ci ((Hash-Ci $retry.Backup) -eq $retry.OldHash) 'Retry replaces old backup with the previous installed client'
    Assert-Ci (@(Get-ChildItem -LiteralPath (Split-Path -Parent $retry.Target) -Filter 'PSDynDNS.ps1.bak*').Count -eq 1) 'Only one automatic backup is retained'
    Assert-Ci (@(Get-ChildItem -LiteralPath (Split-Path -Parent $retry.Target) -Filter 'PSDynDNS.ps1.new*').Count -eq 0) 'No staging files accumulate'

    # A backup in use must not be deleted or cause the installed client to move.
    $lockedDir = Join-Path $testRoot 'locked-backup'
    [IO.Directory]::CreateDirectory($lockedDir) | Out-Null
    $lockedOriginal = Join-Path $lockedDir 'PSDynDNS.ps1'
    $lockedStage = $lockedOriginal + '.new'
    $lockedBackup = $lockedOriginal + '.bak'
    $lockedHelper = Join-Path $lockedDir 'swap.ps1'
    $lockedResultPath = Join-Path $lockedDir 'update-result.json'
    [IO.File]::WriteAllText($lockedOriginal, 'Write-Host "installed"', $utf8)
    [IO.File]::WriteAllText($lockedStage, 'Write-Host "candidate"', $utf8)
    [IO.File]::WriteAllText($lockedBackup, 'Write-Host "previous backup"', $utf8)
    [IO.File]::WriteAllText($lockedHelper, (Get-RealHelper), $utf8)
    $installedHash = Hash-Ci $lockedOriginal
    $previousBackupHash = Hash-Ci $lockedBackup
    $lockedStream = [IO.File]::Open($lockedBackup, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $lockedOutput = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $lockedHelper -ParentPid 0 -Original $lockedOriginal -Staged $lockedStage -Backup $lockedBackup -Digest (Hash-Ci $lockedStage) -Result $lockedResultPath 2>&1
        $lockedExit = $LASTEXITCODE
    } finally {
        $lockedStream.Dispose()
    }
    Assert-Ci ($lockedExit -ne 0) 'Locked backup prevents helper replacement'
    $lockedResult = Get-Content -LiteralPath $lockedResultPath -Raw | ConvertFrom-Json
    Assert-Ci ($lockedResult.Result -eq 'failed') 'Backup deletion failure writes a failed result'
    Assert-Ci ([string]$lockedResult.Error -match 'IOException|UnauthorizedAccessException') 'Backup deletion failure records its exception type'
    Assert-Ci ([string]$lockedResult.Error -match 'PSDynDNS[.]ps1[.]bak') 'Backup deletion failure identifies the backup'
    Assert-Ci ((Hash-Ci $lockedOriginal) -eq $installedHash) 'Backup deletion failure preserves installed client bytes'
    Assert-Ci ((Hash-Ci $lockedBackup) -eq $previousBackupHash) 'Backup deletion failure preserves prior backup bytes'

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
    param([string]$LiteralPath,[string]$Destination,[switch]$Force)
    if ($LiteralPath -eq $Staged -and $Destination -eq $Original) {
        throw 'Deliberately injected second move failure'
    }
    if ($env:PSDYNDNS_CI_FAIL_ROLLBACK -eq '1' -and $LiteralPath -eq $Backup -and $Destination -eq $Original) {
        throw 'Deliberately injected rollback move failure'
    }
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
}
'@
    $actualHelper = Get-RealHelper
    $firstTry = $actualHelper.IndexOf('try {',[StringComparison]::Ordinal)
    if ($firstTry -lt 0) { throw 'Cannot locate helper fault injection point.' }
    $injectedHelper = $actualHelper.Insert($firstTry,($injection + [Environment]::NewLine))
    [IO.File]::WriteAllText($helper,$injectedHelper,$utf8)
    $rollbackOutput = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -ParentPid 0 -Original $original -Staged $stage -Backup $backup -Digest $stageHash -Result (Join-Path $dir 'update-result.json') 2>&1
    $exit = $LASTEXITCODE
    if ($rollbackOutput) { $rollbackOutput | ForEach-Object { Write-Host ('Rollback process: ' + [string]$_) } }
    Assert-Ci ($exit -ne 0) 'Injected second move forces helper failure'
    Assert-Ci (Test-Path -LiteralPath $original -PathType Leaf) 'Rollback restores original file'
    Assert-Ci ((Hash-Ci $original) -eq $originalHash) 'Rollback restores original bytes'
    Assert-Ci (-not (Test-Path -LiteralPath $backup)) 'Rollback consumes temporary backup'
    $errorRecord = Get-Content -LiteralPath (Join-Path $dir 'update-result.json') -Raw | ConvertFrom-Json
    Assert-Ci ($errorRecord.Result -eq 'failed') 'Failed replacement writes a failure result'
    Assert-Ci ([string]$errorRecord.Error -match 'Replacement failed; original restored') 'Failure result describes swap error and successful rollback'
    Assert-Ci ([string]$errorRecord.Error -match 'Deliberately injected second move failure') 'Failure result preserves the underlying replacement exception'
    # The helper deletes itself after each run, so recreate it for this separate failure scenario.
    [IO.File]::WriteAllText($helper, $injectedHelper, $utf8)
    [IO.File]::Delete((Join-Path $dir 'update-result.json'))
    [IO.File]::WriteAllText($stage, 'Write-Host "retry"', $utf8)
    $env:PSDYNDNS_CI_FAIL_ROLLBACK = '1'
    try {
        $rollbackOutput = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -ParentPid 0 -Original $original -Staged $stage -Backup $backup -Digest (Hash-Ci $stage) -Result (Join-Path $dir 'update-result.json') 2>&1
        $exit = $LASTEXITCODE
        Assert-Ci ($exit -ne 0) 'Simultaneous swap and rollback failures cause nonzero exit'
        $both = Get-Content -LiteralPath (Join-Path $dir 'update-result.json') -Raw | ConvertFrom-Json
        Assert-Ci ($both.Result -eq 'failed') 'Dual failure is reported'
        Assert-Ci ([string]$both.Error -match 'Deliberately injected second move failure') 'Dual failure preserves replacement error'
        Assert-Ci ([string]$both.Error -match 'Deliberately injected rollback move failure') 'Dual failure includes rollback error'
        Assert-Ci ((Hash-Ci $backup) -eq $originalHash) 'Failed rollback retains original bytes in backup'
    } finally {
        Remove-Item Env:PSDYNDNS_CI_FAIL_ROLLBACK -ErrorAction SilentlyContinue
    }
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
