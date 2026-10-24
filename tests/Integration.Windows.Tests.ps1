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
            $switches = @('Install','Configure','Repair','SetKey','ResetState','Uninstall','Purge')
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
                    if ($name -in @('IPv4Enabled','IPv6Enabled','AutoUpdate')) { $value = [bool]::Parse($value) }
                    elseif ($name -in @('IntervalMinutes','UpdateCheckHours')) { $value = [int]::Parse($value) }
                    $params[$name] = $value
                }
            }
            if ($params.ContainsKey('Install') -or $params.ContainsKey('SetKey')) {
                $params['CredentialSecret'] = ConvertTo-SecureString -String $script:CiSecret -AsPlainText -Force
            }
            & $script:Installer @params
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
        $result = [pscustomobject]@{
            CanReadConfigAndDpapi=$canRead
            CanWriteRuntime=$canWriteRuntime
            CanWriteApp=$canWriteApp
            CanWriteConfig=$canWriteConfig
            CanWriteSecret=$canWriteSecret
            Account=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        }
        $result | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $runtime 'service-probe.json') -Encoding UTF8
        '@
            $probeFile = Join-Path (Join-Path $script:InstallRoot 'app') 'CI-LocalService-Probe.ps1'
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

            $script:CiSecret = 'ci-test-second-secret-only'
            Invoke-Installer -Arguments @('-SetKey')
            Assert-Equal (Read-InstalledSecret) $script:CiSecret 'SetKey replaces encrypted credentials'

            # Reproduce a permanent bad-credentials block, then rotate the key.
            # SetKey must unblock badauth without deleting the entire state file.
            $authStatePath = Join-Path $script:InstallRoot 'runtime\state.json'
            '{"BlockedReason":"badauth","RetryAfterUtc":null,"Fingerprint":"old-fingerprint","LastIPv4":"82.149.168.179"}' |
                Set-Content -LiteralPath $authStatePath -Encoding UTF8
            Invoke-Installer -Arguments @('-SetKey')
            $afterKeyRotation = Get-Content -LiteralPath $authStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Assert-True ($null -eq $afterKeyRotation.BlockedReason) 'SetKey unblocks previous badauth status'
            Assert-Equal $afterKeyRotation.LastIPv4 '82.149.168.179' 'SetKey retains last reported IP'


            Invoke-Installer -Arguments @(
                '-Hostname','ci-changed.example.invalid',
                '-IPv4Enabled','False', '-IPv6Enabled','True',
                '-IPv6CheckUrl','https://127.0.0.1:1/myipv6',
                '-UpdateChannel','beta',
                '-DnsServers','1.1.1.1',
                '-IntervalMinutes','15',
                '-UpdateCheckHours','12'
            )
            $config = Get-Content -LiteralPath (Join-Path $script:InstallRoot 'config.json') -Raw | ConvertFrom-Json
            Assert-Equal $config.Hostname 'ci-changed.example.invalid' 'Configure updates the host'
            Assert-Equal $config.IPv4Enabled $false 'Configure disables IPv4'
            Assert-Equal $config.IPv6Enabled $true 'Configure enables IPv6'
            Assert-Equal $config.UpdateChannel 'beta' 'Configure sets update channel'
            Assert-Equal @($config.DnsServers)[0] '1.1.1.1' 'Configure updates DNS server list'
            Assert-True (-not (@($config.PSObject.Properties | ForEach-Object { $_.Name }) -contains 'IntervalMinutes')) 'Task interval is not stored in JSON'
            $task = Get-ScheduledTask -TaskName $script:TaskName
            Assert-True (([string]$task.Triggers[0].Repetition.Interval -match '15M')) 'Setting parameter updates task repetition interval'

            $probe = Start-LocalServiceProbe
            Assert-Equal $probe.Account 'S-1-5-19' 'Probe actually runs as LOCAL SERVICE'
            Assert-True $probe.CanReadConfigAndDpapi 'LOCAL SERVICE task can read config and decrypt DPAPI secret'
            Assert-True $probe.CanWriteRuntime 'Task can modify runtime directory'
            Assert-True $probe.CanWriteApp 'Task can modify app directory for updates'
            Assert-True (-not $probe.CanWriteConfig) 'Task cannot modify configuration'
            Assert-True (-not $probe.CanWriteSecret) 'Task cannot modify secret'

            Invoke-Installer -Arguments @('-Repair')
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
