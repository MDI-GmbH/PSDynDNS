#requires -Version 5.1
# Destructive, isolated Windows integration. Run only on disposable CI runners.
Describe 'PSDynDNS installation, task isolation and lifecycle' -Tag 'Integration' {
    BeforeAll {
        if ($env:GITHUB_ACTIONS -ne 'true') {
            throw 'Destructive Windows integration tests are restricted to disposable GitHub Actions runners.'
        }
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $script:Runtime = if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell7' } else { 'WindowsPowerShell' }
        $script:Project = Split-Path -Parent $PSScriptRoot
        $script:Installer = Join-Path $script:Project 'Install-PSDynDNS.ps1'
        $script:Source = Join-Path $script:Project 'PSDynDNS.ps1'
        $script:InstallRoot = Join-Path $env:ProgramData 'PSDynDNS'
        $script:TaskName = 'PSDynDNS'
        $script:CiSecret = 'ci-test-first-secret-only'
        $script:Installed = $false

        function Assert-True {
            param([bool]$Condition, [string]$Message)
            if (-not $Condition) { throw "INTEGRATION ASSERT FAILED: $Message" }
            Write-Host "PASS: $Message"
        }
        function Assert-Equal {
            param($Actual,$Expected,[string]$Message)
            if ([string]$Actual -ne [string]$Expected) {
                throw "INTEGRATION ASSERT FAILED: $Message (actual '$Actual', expected '$Expected')"
            }
            Write-Host "PASS: $Message"
        }
        function Test-WindowsAdmin {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)
            return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }

        # The installer deliberately prompts for the secret. Override Read-Host in this
        # test runspace so it receives a SecureString without prompts or real credentials.
        function Read-Host {
            param([string]$Prompt, [switch]$AsSecureString)
            if (-not $AsSecureString) { throw 'Unexpected interactive prompt in CI.' }
            return ConvertTo-SecureString -String $script:CiSecret -AsPlainText -Force
        }

        function Invoke-Installer {
            param([string[]]$Arguments)
            # PowerShell string-array splatting treats '-Install' as a positional string.
            # Convert the test's name/value arguments into a true named-parameter hashtable.
            $switches = @('Install','Configure','Repair','UpdateClient','SetKey','ResetState','Uninstall','Purge')
            $params = @{}
            for ($i=0; $i -lt $Arguments.Count; $i++) {
                $token = $Arguments[$i]
                if (-not $token.StartsWith('-')) { throw "Expected installer parameter, got: $token" }
                $name = $token.Substring(1)
                if ($switches -contains $name) {
                    $params[$name] = $true
                } else {
                    if ($i + 1 -ge $Arguments.Count) { throw "Missing value for $token" }
                    $i++
                    $value = $Arguments[$i]
                    if ($name -in @('IPv4Enabled','IPv6Enabled','AutoUpdate','AllowAutomaticConfigUpdates')) {
                        $value = [bool]::Parse($value)
                    }
                    elseif ($name -in @('IntervalMinutes','UpdateCheckHours')) { $value = [int]::Parse($value) }
                    $params[$name] = $value
                }
            }
            if ($params.ContainsKey('Install') -or $params.ContainsKey('SetKey')) {
                $params['CredentialSecret'] = ConvertTo-SecureString -String $script:CiSecret -AsPlainText -Force
            }
            & $script:Installer @params
        }

        function Assert-TaskSchedule {
            param([int]$ExpectedMinutes,[string]$Phase)
            $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
            $triggers = @($task.Triggers)
            Assert-Equal $triggers.Count 2 "$Phase has exactly two scheduled task triggers"
            $interval = @($triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' })
            $startup = @($triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })
            Assert-Equal $interval.Count 1 "$Phase retains the repeating time trigger"
            Assert-Equal $startup.Count 1 "$Phase registers a system-start trigger"
            $actualMinutes = [int]([Xml.XmlConvert]::ToTimeSpan([string]$interval[0].Repetition.Interval).TotalMinutes)
            Assert-Equal $actualMinutes $ExpectedMinutes "$Phase preserves the interval in minutes"
            # Check the persisted Task Scheduler XML, not just the in-memory CIM object.
            [xml]$xml = Export-ScheduledTask -TaskName $script:TaskName
            $boot = $xml.SelectSingleNode('//*[local-name()="BootTrigger"]')
            Assert-True ($null -ne $boot) "$Phase exports a boot trigger"
            $delay = $boot.SelectSingleNode('*[local-name()="Delay"]')
            Assert-True ($null -ne $delay) "$Phase persists a boot delay"
            Assert-Equal $delay.InnerText 'PT1M' "$Phase delays startup by 60 seconds"
        }
        function Read-InstalledSecret {
            Add-Type -AssemblyName System.Security
            $secretPath = Join-Path $script:InstallRoot 'secret.dpapi'
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
                [IO.File]::ReadAllBytes($secretPath),
                $null,
                [Security.Cryptography.DataProtectionScope]::LocalMachine)
            try { return [Text.Encoding]::UTF8.GetString($bytes) }
            finally { [Array]::Clear($bytes,0,$bytes.Length) }
        }

        function Wait-File {
            param([string]$Path,[int]$Seconds=45)
            for ($i=0;$i -lt ($Seconds * 2);$i++) {
                if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
                Start-Sleep -Milliseconds 500
            }
            Write-Warning ("Missing task output: " + $Path)
            $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
            if ($task) {
                $info = Get-ScheduledTaskInfo -TaskName $script:TaskName -ErrorAction SilentlyContinue
                Write-Host ("Task state: " + $task.State)
                if ($info) { Write-Host ("Task last result: " + $info.LastTaskResult + "; last run: " + $info.LastRunTime.ToString('o')) }
                Write-Host ("Task principal: " + $task.Principal.UserId + "; SID type: " + $task.Principal.ProcessTokenSidType)
            }
            foreach ($event in @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TaskScheduler/Operational';StartTime=(Get-Date).AddMinutes(-4)} -MaxEvents 15 -ErrorAction SilentlyContinue)) {
                Write-Host ("TaskScheduler event " + $event.Id + ": " + ($event.Message -replace '[\r\n]+',' '))
            }
            foreach ($n in @('PSDynDNS-CI-TaskStarted.txt','PSDynDNS-CI-TaskError.txt')) {
                $p = Join-Path $env:windir ('Temp\' + $n)
                if (Test-Path -LiteralPath $p) { Write-Host ("Task launch log " + $n + ": " + (Get-Content -LiteralPath $p -Raw)) }
            }
            $runtime = Join-Path $script:InstallRoot 'runtime'
            foreach ($name in @('service-probe.error.txt','service-probe.start.txt')) {
                $diagnostic = Join-Path $runtime $name
                if (Test-Path -LiteralPath $diagnostic) {
                    Write-Host ("Task diagnostic " + $name + ": " + (Get-Content -LiteralPath $diagnostic -Raw))
                }
            }
            throw "Timed out waiting for Task Scheduler output: $Path"
        }
        function Wait-TaskStopped {
            param([int]$Seconds=35)
            for ($i=0;$i -lt ($Seconds * 2);$i++) {
                $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
                if (-not $task -or $task.State -ne 'Running') { return }
                Start-Sleep -Milliseconds 500
            }
            throw 'Task Scheduler did not finish before timeout.'
        }
        function Start-LocalServiceProbe {
            # Temporarily change only the ACTION of the real registered task.
            # We must keep the task identity/SID to test permissions correctly.
            # -Repair restores the original action afterwards.
            $sourceCode = @'
$ErrorActionPreference = 'Stop'
try {
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\service-probe.start.txt'),'started')
    . (Join-Path $PSScriptRoot 'PSDynDNS.ps1')
} catch {
    try {
        [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\service-probe.error.txt'), [string]$_.Exception.Message)
    } catch {}
    throw
}
$root = Split-Path -Parent $PSScriptRoot
$cfg = Read-ClientConfig (Join-Path $root 'config.json')
$key = Read-MachineSecret (Join-Path $root 'secret.dpapi')
$runtime = Join-Path $root 'runtime'
$canRead = ($cfg.Hostname -eq 'ci-changed.example.invalid' -and $key -eq 'ci-test-second-secret-only')
$canWriteRuntime = $false
$canWriteApp = $false
$canWriteConfig = $false
$canWriteSecret = $false
$canSwapProtectedClient = $false
$canRecoverStaleStage = $false
try {
    $path = Join-Path $runtime 'service-probe.tmp'
    [IO.File]::WriteAllText($path,'ok')
    Remove-Item -LiteralPath $path -Force
    $canWriteRuntime = $true
} catch {}
try {
    $path = Join-Path $PSScriptRoot 'service-probe.tmp'
    [IO.File]::WriteAllText($path,'ok')
    Remove-Item -LiteralPath $path -Force
    $canWriteApp = $true
} catch {}
try {
    $stream = [IO.File]::Open((Join-Path $root 'config.json'),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    $stream.Dispose()
    $canWriteConfig = $true
} catch {}
try {
    $stream = [IO.File]::Open((Join-Path $root 'secret.dpapi'),[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
    $stream.Dispose()
    $canWriteSecret = $true
} catch {}
# The app directory grants DELETE_CHILD even when the staged file is read-only.
$stale = Join-Path $PSScriptRoot 'PSDynDNS.ps1.new'
try {
    [IO.File]::WriteAllText($stale, 'stale')
    $acl = Get-Acl -LiteralPath $stale
    $clientAcl = Get-Acl -LiteralPath (Join-Path $PSScriptRoot 'PSDynDNS.ps1')
    $access = [Security.AccessControl.AccessControlSections]::Access
    $acl.SetSecurityDescriptorSddlForm($clientAcl.GetSecurityDescriptorSddlForm($access), $access)
    Set-Acl -LiteralPath $stale -AclObject $acl
    [IO.File]::Delete($stale)
    [IO.File]::WriteAllText($stale, 'replacement')
    $canRecoverStaleStage = ([IO.File]::ReadAllText($stale) -eq 'replacement')
} catch {
    Write-Host ('Protected stage cleanup failed: ' + $_.Exception.Message)
} finally {
    try { [IO.File]::Delete($stale) } catch {}
}
# Verify that Start-SelfUpdate itself cleans a protected abandoned stage.
$updaterCleanedProtectedStage = $false
try {
    [IO.File]::WriteAllText($stale,'old stage')
    $stageAcl = Get-Acl -LiteralPath $stale
    $sourceAcl = Get-Acl -LiteralPath (Join-Path $PSScriptRoot 'PSDynDNS.ps1')
    $section = [Security.AccessControl.AccessControlSections]::Access
    $stageAcl.SetSecurityDescriptorSddlForm($sourceAcl.GetSecurityDescriptorSddlForm($section),$section)
    Set-Acl -LiteralPath $stale -AclObject $stageAcl
    $payload = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'PSDynDNS.ps1'))
    $digest = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'PSDynDNS.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
    Start-SelfUpdate ([pscustomobject]@{Channel='main';Content=$payload;Sha256=$digest})
    $updaterCleanedProtectedStage = ((Get-FileHash -LiteralPath $stale -Algorithm SHA256).Hash.ToLowerInvariant() -eq $digest)
} catch {
    Write-Host ('Updater stage cleanup failed: ' + $_.Exception.Message)
}
# Verify the production replacement moves under the actual task identity.
$fixture = Join-Path $PSScriptRoot 'CI-ACL-Original.ps1'
$stage = $fixture + '.new'
$backup = $fixture + '.bak'
try {
    # The production staging file is created by LOCAL SERVICE, not admin.
    [IO.File]::WriteAllText($stage, 'Write-Host "staged"')
    $oldAcl = Get-Acl -LiteralPath $fixture
    $newAcl = Get-Acl -LiteralPath $stage
    $access = [Security.AccessControl.AccessControlSections]::Access
    $newAcl.SetSecurityDescriptorSddlForm($oldAcl.GetSecurityDescriptorSddlForm($access), $access)
    Set-Acl -LiteralPath $stage -AclObject $newAcl
    Move-Item -LiteralPath $fixture -Destination $backup -ErrorAction Stop
    Move-Item -LiteralPath $stage -Destination $fixture -ErrorAction Stop
    $finalAcl = Get-Acl -LiteralPath $fixture
    $canSwapProtectedClient = (
        $finalAcl.GetSecurityDescriptorSddlForm($access) -eq
        $oldAcl.GetSecurityDescriptorSddlForm($access)
    )
} catch {
    Write-Host ('ACL swap probe rejected: ' + $_.Exception.Message)
}
$result = [pscustomobject]@{
    CanSwapProtectedClient=$canSwapProtectedClient
    CanRecoverStaleStage=$canRecoverStaleStage
    CanReadConfigAndDpapi=$canRead
    CanWriteRuntime=$canWriteRuntime
    CanWriteApp=$canWriteApp
    CanWriteConfig=$canWriteConfig
    CanWriteSecret=$canWriteSecret
    Account=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
$result | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $runtime 'service-probe.json') -Encoding UTF8
'@
            $appRoot = Join-Path $script:InstallRoot 'app'
            $fixture = Join-Path $appRoot 'CI-ACL-Original.ps1'
            $stage = $fixture + '.new'
            Copy-Item -LiteralPath (Join-Path $appRoot 'PSDynDNS.ps1') -Destination $fixture -Force
            Set-Acl -LiteralPath $fixture -AclObject (Get-Acl -LiteralPath (Join-Path $appRoot 'PSDynDNS.ps1'))
            $probeFile = Join-Path $appRoot 'CI-LocalService-Probe.ps1'
            [IO.File]::WriteAllText($probeFile,$sourceCode,(New-Object Text.UTF8Encoding($false)))
            $powershell = (Get-ScheduledTask -TaskName $script:TaskName).Actions[0].Execute
            # An encoded launcher writes a marker outside PSDynDNS before touching app ACLs.
            # This distinguishes a task that never starts from an ACL failure loading the probe.
            $bootLog = Join-Path $env:windir 'Temp\PSDynDNS-CI-TaskStarted.txt'
            $errorLog = Join-Path $env:windir 'Temp\PSDynDNS-CI-TaskError.txt'
            Remove-Item -LiteralPath $bootLog,$errorLog -Force -ErrorAction SilentlyContinue
            $cmd = @'
try {
    [IO.File]::WriteAllText('__BOOT__','started')
    & '__PROBE__'
} catch {
    [IO.File]::WriteAllText('__ERR__',[string]$_.Exception.Message)
    exit 3
}
'@
            $cmd = $cmd.Replace('__BOOT__',$bootLog).Replace('__ERR__',$errorLog).Replace('__PROBE__',$probeFile)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
            $action = New-ScheduledTaskAction -Execute $powershell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded)
            Set-ScheduledTask -TaskName $script:TaskName -Action $action | Out-Null
            $outFile = Join-Path (Join-Path $script:InstallRoot 'runtime') 'service-probe.json'
            Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
            Start-ScheduledTask -TaskName $script:TaskName
            Wait-File -Path $outFile
            Wait-TaskStopped
            return Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }


    }

    It 'installs, configures, isolates and repairs the LOCAL SERVICE task, then uninstalls' {
        Write-Host 'Running isolated PSDynDNS Windows installation integration test.'
        Assert-True (Test-WindowsAdmin) 'GitHub Windows runner is elevated'
        Assert-True (-not (Test-Path -LiteralPath $script:InstallRoot)) 'No existing PSDynDNS installation on isolated CI runner'
        Assert-True (-not (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)) 'No existing PSDynDNS scheduled task'
        try {
            # LOCALHOST / port 1 cannot update DNS; we are only testing lifecycle and ACLs.
            Invoke-Installer -Arguments @(
                '-Install', '-Hostname','ci-initial.example.invalid',
                '-IPv4Enabled','True', '-IPv6Enabled','False',
                '-IPv4CheckUrl','https://127.0.0.1:1/myip',
                '-UpdateUrl','https://127.0.0.1:1/nic/update',
                '-AutoUpdate','False',
                '-LocalClientPath',$script:Source,
                '-Runtime',$Runtime
            )
            $script:Installed = $true
            $initialConfig = Get-Content -LiteralPath (Join-Path $script:InstallRoot 'config.json') -Raw | ConvertFrom-Json
            Assert-Equal $initialConfig.AllowAutomaticConfigUpdates $true 'New installations explicitly opt in to future config updates'
            Assert-True (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'app\PSDynDNS.ps1')) 'Client script installed'
            Assert-True (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'runtime\state.json')) 'Runtime state initialized'
            Assert-Equal (Read-InstalledSecret) $script:CiSecret 'Installer stores a decryptable machine DPAPI secret'
            Assert-Equal (Get-FileHash -LiteralPath (Join-Path $script:InstallRoot 'app\PSDynDNS.ps1') -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash 'Installed client matches repository script'

            $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
            Assert-Equal ([IO.Path]::GetFileName([string]$task.Actions[0].Execute)) $(if ($Runtime -eq 'PowerShell7') { 'pwsh.exe' } else { 'powershell.exe' }) 'Task uses requested PowerShell runtime'
            Assert-Equal ([string]$task.Principal.ProcessTokenSidType) 'Unrestricted' 'Scheduled task has an unrestricted task SID'
            $principalName = [string]$task.Principal.UserId
            $principalSid = if ($principalName -eq 'S-1-5-19') { $principalName } else {
                (New-Object Security.Principal.NTAccount($principalName)).Translate([Security.Principal.SecurityIdentifier]).Value
            }
            Assert-Equal $principalSid 'S-1-5-19' 'Scheduled task uses language-neutral LOCAL SERVICE SID'
            Assert-TaskSchedule -ExpectedMinutes 10 -Phase 'Install'

            # Explicit manual update of an already installed client. No
            # provider/network calls and no modification of config or DPAPI.
            $installedClient = Join-Path $script:InstallRoot 'app\PSDynDNS.ps1'
            $originalHash = (Get-FileHash -LiteralPath $installedClient -Algorithm SHA256).Hash
            $configHash = (Get-FileHash -LiteralPath (Join-Path $script:InstallRoot 'config.json') -Algorithm SHA256).Hash
            $secretHash = (Get-FileHash -LiteralPath (Join-Path $script:InstallRoot 'secret.dpapi') -Algorithm SHA256).Hash
            $badClient = Join-Path $env:TEMP ('PSDynDNS-CI-Bad-' + [guid]::NewGuid().ToString('N') + '.ps1')
            $candidate = Join-Path $env:TEMP ('PSDynDNS-CI-New-' + [guid]::NewGuid().ToString('N') + '.ps1')
            try {
                [IO.File]::WriteAllText($badClient, 'function NeverClosed {')
                $rejected = $false
                try {
                    Invoke-Installer -Arguments @('-UpdateClient','-LocalClientPath',$badClient)
                } catch { $rejected = $true }
                Assert-True $rejected 'Manual update rejects invalid PowerShell source'
                Assert-Equal (Get-FileHash -LiteralPath $installedClient -Algorithm SHA256).Hash $originalHash 'Rejected update retains old client'
                Assert-True ((Get-ScheduledTask -TaskName $script:TaskName).State -ne 'Disabled') 'Rejected update leaves task enabled'
                Assert-True (-not (Test-Path -LiteralPath ($installedClient + '.manual.new'))) 'Rejected update removes staging file'

                $candidateText = [IO.File]::ReadAllText($script:Source) + [Environment]::NewLine + '# CI manual update marker'
                [IO.File]::WriteAllText($candidate, $candidateText, (New-Object Text.UTF8Encoding($false)))
                Invoke-Installer -Arguments @('-UpdateClient','-LocalClientPath',$candidate)
                $candidateHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
                Assert-Equal (Get-FileHash -LiteralPath $installedClient -Algorithm SHA256).Hash $candidateHash 'Manual update replaces the client'
                $backups = @(Get-ChildItem -LiteralPath (Join-Path $script:InstallRoot 'app') -Filter 'PSDynDNS.ps1.manual-*.bak')
                Assert-True ($backups.Count -ge 1) 'Manual update retains a backup'
                Assert-Equal (Get-FileHash -LiteralPath $backups[-1].FullName -Algorithm SHA256).Hash $originalHash 'Manual backup contains the prior client'
                Assert-Equal (Get-FileHash -LiteralPath (Join-Path $script:InstallRoot 'config.json') -Algorithm SHA256).Hash $configHash 'Manual update leaves configuration unchanged'
                Assert-Equal (Get-FileHash -LiteralPath (Join-Path $script:InstallRoot 'secret.dpapi') -Algorithm SHA256).Hash $secretHash 'Manual update leaves secret unchanged'
                Assert-True ((Get-ScheduledTask -TaskName $script:TaskName).State -ne 'Disabled') 'Manual update re-enables task'

                # Restore source bytes, keeping subsequent lifecycle checks
                # independent of the test marker.
                Invoke-Installer -Arguments @('-UpdateClient','-LocalClientPath',$script:Source)
                Assert-Equal (Get-FileHash -LiteralPath $installedClient -Algorithm SHA256).Hash $originalHash 'Manual update can restore installed source'
            } finally {
                Remove-Item -LiteralPath $badClient,$candidate -Force -ErrorAction SilentlyContinue
            }

            $script:CiSecret = 'ci-test-second-secret-only'
            Invoke-Installer -Arguments @('-SetKey')
            Assert-Equal (Read-InstalledSecret) $script:CiSecret 'SetKey replaces encrypted credentials'

            # Reproduce a permanent bad-credentials block, then rotate the key.
            # SetKey must unblock badauth without deleting the entire state file.
            $authStatePath = Join-Path $script:InstallRoot 'runtime\state.json'
            '{"BlockedReason":"badauth","RetryAfterUtc":null,"Fingerprint":"old-fingerprint","LastIPv4":"9.9.9.9"}' |
                Set-Content -LiteralPath $authStatePath -Encoding UTF8
            Invoke-Installer -Arguments @('-SetKey')
            $afterKeyRotation = Get-Content -LiteralPath $authStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-True ($null -eq $afterKeyRotation.BlockedReason) 'SetKey unblocks previous badauth status'
            Assert-Equal $afterKeyRotation.LastIPv4 '9.9.9.9' 'SetKey retains last reported IP'


            Invoke-Installer -Arguments @(
                '-Hostname','ci-changed.example.invalid',
                '-IPv4Enabled','False', '-IPv6Enabled','True',
                '-IPv6CheckUrl','https://127.0.0.1:1/myipv6',
                '-UpdateChannel','beta',
                '-DnsServers','1.1.1.1',
                '-IntervalMinutes','15',
                '-UpdateCheckHours','12',
                '-AllowAutomaticConfigUpdates','False'
            )
            $config = Get-Content -LiteralPath (Join-Path $script:InstallRoot 'config.json') -Raw | ConvertFrom-Json
            Assert-Equal $config.Hostname 'ci-changed.example.invalid' 'Configure updates the host'
            Assert-Equal $config.IPv4Enabled $false 'Configure disables IPv4'
            Assert-Equal $config.IPv6Enabled $true 'Configure enables IPv6'
            Assert-Equal $config.UpdateChannel 'beta' 'Configure sets update channel'
            Assert-Equal $config.AllowAutomaticConfigUpdates $false 'Configure can explicitly disable future config updates'
            Assert-Equal @($config.DnsServers)[0] '1.1.1.1' 'Configure updates DNS server list'
            Assert-True (-not (@($config.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'IntervalMinutes')) 'Task interval is not stored in JSON'
            $task = Get-ScheduledTask -TaskName $script:TaskName
            Assert-TaskSchedule -ExpectedMinutes 15 -Phase 'Configure'

            $probe = Start-LocalServiceProbe
            Assert-Equal $probe.Account 'S-1-5-19' 'Probe actually runs as LOCAL SERVICE'
            Assert-True $probe.CanReadConfigAndDpapi 'LOCAL SERVICE task can read config and decrypt DPAPI secret'
            Assert-True $probe.CanWriteRuntime 'Task can modify runtime directory'
            Assert-True $probe.CanWriteApp 'Task can modify app directory for updates'
            Assert-True $probe.CanSwapProtectedClient 'LOCAL SERVICE can replace protected script under installed ACLs'
            Assert-True $probe.CanRecoverStaleStage 'LOCAL SERVICE can delete and recreate a protected staging file'
            Assert-True (-not $probe.CanWriteConfig) 'Task cannot modify configuration'
            Assert-True (-not $probe.CanWriteSecret) 'Task cannot modify secret'

            # Emulate a missing startup trigger; Repair must recreate both.
            $existingTask = Get-ScheduledTask -TaskName $script:TaskName
            $timeOnlyTrigger = @($existingTask.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskTimeTrigger' })
            Assert-Equal $timeOnlyTrigger.Count 1 'Fixture contains one repeating time trigger'
            Set-ScheduledTask -TaskName $script:TaskName -Trigger $timeOnlyTrigger[0] | Out-Null
            Assert-Equal @((Get-ScheduledTask -TaskName $script:TaskName).Triggers).Count 1 'Test fixture removes boot trigger before Repair'
            Invoke-Installer -Arguments @('-Repair')
            Assert-TaskSchedule -ExpectedMinutes 15 -Phase 'Repair'
            $repairedConfig = Get-Content -LiteralPath (Join-Path $script:InstallRoot 'config.json') -Raw | ConvertFrom-Json
            Assert-Equal $repairedConfig.AllowAutomaticConfigUpdates $false 'Repair retains explicit config update opt-out'
            $task = Get-ScheduledTask -TaskName $script:TaskName
            Assert-True (([string]$task.Actions[0].Arguments -match 'PSDynDNS[.]ps1')) 'Repair restores real client task action'
            Assert-Equal (Read-InstalledSecret) $script:CiSecret 'Repair preserves credentials'
            Assert-Equal ([IO.Path]::GetFileName([string]$task.Actions[0].Execute)) $(if ($Runtime -eq 'PowerShell7') { 'pwsh.exe' } else { 'powershell.exe' }) 'Repair preserves requested PowerShell runtime'

            $stateFile = Join-Path $script:InstallRoot 'runtime\state.json'
            '{"BlockedReason":"badauth"}' | Set-Content -LiteralPath $stateFile -Encoding UTF8
            Invoke-Installer -Arguments @('-ResetState')
            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            Assert-True (-not (@($state.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'BlockedReason')) 'ResetState clears blocked provider state'

            Invoke-Installer -Arguments @('-Uninstall')
            Assert-True (-not (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)) 'Uninstall removes the scheduled task'
            Assert-True (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'config.json')) 'Uninstall retains configuration'
            Assert-True (Test-Path -LiteralPath (Join-Path $script:InstallRoot 'secret.dpapi')) 'Uninstall retains DPAPI secret'
            Invoke-Installer -Arguments @('-Uninstall','-Purge')
            Assert-True (-not (Test-Path -LiteralPath $script:InstallRoot)) 'Purge removes remaining configuration and runtime data'
            $script:Installed = $false
            Write-Host 'SUCCESS: Installer, SetKey, Configure, task SID, DPAPI, Repair, ResetState, Uninstall and Purge verified.'
        }
        finally {
            if ($script:Installed -or (Test-Path -LiteralPath $script:InstallRoot)) {
                Write-Warning 'Cleaning up CI installation.'
                try {
                    $task = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
                    if ($task -and $task.State -eq 'Running') { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }
                    & $script:Installer -Uninstall -Purge
                } catch { Write-Warning 'Installer cleanup failed; deleting CI task and directory directly.' }
                Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $script:InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

    }
}
