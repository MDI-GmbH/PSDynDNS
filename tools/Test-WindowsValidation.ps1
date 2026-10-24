#requires -Version 5.1
<#
.SYNOPSIS
    Validate a PSDynDNS Windows installation. No changes by default.
.DESCRIPTION
    -ProbeLocalService temporarily substitutes the existing task action to
    verify its real LOCAL SERVICE token, task SID, ACLs and DPAPI access.
    The original task action is restored in a finally block. Run this only
    during a maintenance window when the scheduled task is not executing.
    -LiveDnsUpdate contacts the configured DynDNS provider and may change DNS.
    -TestUpdateRollback runs the isolated Pester self-update test in a temp folder.
#>
[CmdletBinding()]
param(
    [switch]$ProbeLocalService,
    [switch]$LiveDnsUpdate,
    [switch]$TestUpdateRollback
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'PSDynDNS'
$app = Join-Path $root 'app'
$runtime = Join-Path $root 'runtime'
$client = Join-Path $app 'PSDynDNS.ps1'
$configPath = Join-Path $root 'config.json'
$secretPath = Join-Path $root 'secret.dpapi'
$taskName = 'PSDynDNS'
$problems = New-Object System.Collections.Generic.List[string]

function Assert-Check {
    param([bool]$Condition, [string]$Description)
    if ($Condition) {
        Write-Host ("PASS: " + $Description) -ForegroundColor Green
    } else {
        Write-Host ("FAIL: " + $Description) -ForegroundColor Red
        $problems.Add($Description)
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw 'Windows is required.'
}
foreach ($path in @($root, $app, $runtime, $client, $configPath, $secretPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw ("Missing installed PSDynDNS path: " + $path)
    }
}
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Check (-not [string]::IsNullOrWhiteSpace([string]$config.Hostname)) 'Configuration has a hostname'
$tokens = $null
$parseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile($client, [ref]$tokens, [ref]$parseErrors)
Assert-Check ($parseErrors.Count -eq 0) 'Installed client parses without errors'

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
$account = [string]$task.Principal.UserId
try {
    if ($account -notmatch '^S-\d+-') {
        $account = (New-Object Security.Principal.NTAccount -ArgumentList $account).Translate(
            [Security.Principal.SecurityIdentifier]).Value
    }
} catch {
    throw ('Could not resolve Scheduled Task account: ' + $task.Principal.UserId)
}
Assert-Check ($account -eq 'S-1-5-19') 'Scheduled Task runs as LOCAL SERVICE'
Assert-Check ([string]$task.Principal.ProcessTokenSidType -eq 'Unrestricted') 'Task process receives a task SID'
$taskSidText = (& (Join-Path $env:SystemRoot 'System32\schtasks.exe') /ShowSid /TN $taskName 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'schtasks /ShowSid failed.' }
$taskSid = [regex]::Match($taskSidText, 'S-1-5-87-(?:\d+-){4}\d+').Value
Assert-Check (-not [string]::IsNullOrEmpty($taskSid)) 'Windows resolves the PSDynDNS task SID'

if ($ProbeLocalService) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this validation elevated to probe the Scheduled Task.'
    }
    if ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        throw 'Task is currently running. Repeat during a maintenance window.'
    }

    $id = [guid]::NewGuid().ToString('N')
    $probeFile = Join-Path $runtime ('.validation-' + $id + '.ps1')
    $resultFile = Join-Path $runtime ('.validation-' + $id + '.json')
    $probeCode = @'
param([string]$Root, [string]$TaskSid, [string]$ResultPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security

function Can-OpenWrite {
    param([string]$Path)
    try {
        $handle = [IO.File]::Open($Path, [IO.FileMode]::Open,
            [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $handle.Dispose()
        return $true
    } catch { return $false }
}
function Can-CreateFile {
    param([string]$Directory)
    $file = Join-Path $Directory ('.access-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($file, 'test')
        return $true
    } catch { return $false }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$groups = @($identity.Groups | ForEach-Object { $_.Value })
$cfgPath = Join-Path $Root 'config.json'
$keyPath = Join-Path $Root 'secret.dpapi'
$configReadable = $false
$dpapiReadable = $false
try {
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $configReadable = [bool]$cfg.Hostname
} catch {}
try {
    $cipher = [IO.File]::ReadAllBytes($keyPath)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
        $cipher, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { $dpapiReadable = ($plain.Length -gt 0) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
} catch {}

$report = [pscustomobject]@{
    AccountSid = $identity.User.Value
    TaskSidInToken = ($groups -contains $TaskSid)
    CanReadConfig = $configReadable
    CanDecryptDpapi = $dpapiReadable
    CanWriteConfig = (Can-OpenWrite $cfgPath)
    CanWriteSecret = (Can-OpenWrite $keyPath)
    CanWriteApp = (Can-CreateFile (Join-Path $Root 'app'))
    CanWriteRuntime = (Can-CreateFile (Join-Path $Root 'runtime'))
}
[IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Compress),
    (New-Object Text.UTF8Encoding($false)))
'@
    [IO.File]::WriteAllText($probeFile, $probeCode, (New-Object Text.UTF8Encoding($false)))
    $task = Get-ScheduledTask -TaskName $taskName
    $originalActions = @($task.Actions)
    $execute = [string]$originalActions[0].Execute
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
        $probeFile + '" -Root "' + $root + '" -TaskSid "' +
        $taskSid + '" -ResultPath "' + $resultFile + '"'
    $probeAction = New-ScheduledTaskAction -Execute $execute -Argument $arguments
    $actionChanged = $false
    try {
        Set-ScheduledTask -TaskName $taskName -Action $probeAction -ErrorAction Stop | Out-Null
        $actionChanged = $true
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        for ($n=0; $n -lt 120; $n++) {
            if (Test-Path -LiteralPath $resultFile -PathType Leaf) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
            throw 'No probe result from LOCAL SERVICE after 60 seconds.'
        }
        $probe = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        Assert-Check ($probe.AccountSid -eq 'S-1-5-19') 'Probe actually ran as LOCAL SERVICE'
        Assert-Check ([bool]$probe.TaskSidInToken) 'Original task SID is present in process token'
        Assert-Check ([bool]$probe.CanReadConfig) 'LOCAL SERVICE reads config.json'
        Assert-Check ([bool]$probe.CanDecryptDpapi) 'LOCAL SERVICE decrypts DPAPI secret'
        Assert-Check (-not [bool]$probe.CanWriteConfig) 'LOCAL SERVICE cannot modify config.json'
        Assert-Check (-not [bool]$probe.CanWriteSecret) 'LOCAL SERVICE cannot modify secret.dpapi'
        Assert-Check ([bool]$probe.CanWriteApp) 'LOCAL SERVICE can write app directory'
        Assert-Check ([bool]$probe.CanWriteRuntime) 'LOCAL SERVICE can write runtime directory'
    } finally {
        if ($actionChanged) {
            for ($n=0; $n -lt 20; $n++) {
                if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') { break }
                Start-Sleep -Milliseconds 500
            }
            Set-ScheduledTask -TaskName $taskName -Action $originalActions -ErrorAction Stop | Out-Null
        }
        Remove-Item -LiteralPath $probeFile, $resultFile -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host 'INFO: Actual LOCAL SERVICE access/DPAPI probe not run; use -ProbeLocalService.'
}

if ($TestUpdateRollback) {
    $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\Integration.SelfUpdate.Tests.ps1'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Run this script from the PSDynDNS repository to test rollback.' }
    Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
    $settings = New-PesterConfiguration
    $settings.Run.Path = @($path)
    $settings.Run.PassThru = $true
    $settings.Output.Verbosity = 'Detailed'
    $result = Invoke-Pester -Configuration $settings
    Assert-Check ($result.PassedCount -gt 0 -and $result.FailedCount -eq 0) 'Isolated self-update and rollback test'
}

if ($LiveDnsUpdate) {
    if ($config.AutoUpdate) {
        throw 'Disable AutoUpdate before a live DNS test to prevent an unintended software upgrade.'
    }
    Write-Warning 'LIVE ACTION: This calls the DynDNS provider and can change DNS records.'
    & $client -ConfigPath $configPath -ForceDnsUpdate
    Assert-Check ($LASTEXITCODE -eq 0) 'Live DynDNS2 provider request'
} else {
    Write-Host 'INFO: Live provider update not run; use -LiveDnsUpdate only when ready.'
}
if ($problems.Count -gt 0) { throw ($problems.Count.ToString() + ' validation checks failed.') }
Write-Host 'PSDynDNS validation completed successfully.' -ForegroundColor Green
