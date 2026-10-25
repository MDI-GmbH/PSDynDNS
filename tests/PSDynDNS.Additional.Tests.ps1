#requires -Version 5.1
# Focused regression tests. All files and credentials are synthetic.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\PSDynDNS.ps1')
    $installerPath = Join-Path $PSScriptRoot '..\Install-PSDynDNS.ps1'
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $installerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Installer did not parse.' }
    foreach ($name in @('Save-Settings','Save-Secret','Apply-Settings','Read-Settings','Install-Task','Get-ExistingTaskInterval')) {
        $found = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true))
        if ($found.Count -ne 1) { throw "Installer function missing: $name" }
        . ([scriptblock]::Create($found[0].Extent.Text))
    }
    function Set-ProtectedAcl {
        param([string]$Path,[switch]$ClientRead)
        # ACL enforcement is covered separately under the real task SID.
    }
}

Describe 'Client HTTP, release and logging edge cases' {
    It 'sends the configured username, Basic credentials and existing query parameters' {
        $cfg = [pscustomobject]@{
            Hostname='host.example.org';Username='custom-user'
            UpdateUrl='https://example.org/nic/update?source=ci'
        }
        $script:requestUri = $null
        $script:requestHeaders = $null
        Mock Invoke-WebRequest {
            $script:requestUri = [string]$Uri
            $script:requestHeaders = $Headers
            [pscustomobject]@{Content='good 8.8.8.8'}
        }
        Invoke-DynDnsRequest -Config $cfg -Secret 'synthetic+key' -AddressList '8.8.8.8,2606:4700::1111' |
            Should -Be 'good 8.8.8.8'
        $script:requestUri | Should -Match '^https://example[.]org/nic/update[?]source=ci&hostname=host[.]example[.]org&myip='
        $myip = [regex]::Match(([uri]$script:requestUri).Query, '(?:[?&])myip=([^&]*)')
        $myip.Success | Should -BeTrue
        [uri]::UnescapeDataString($myip.Groups[1].Value) | Should -Be '8.8.8.8,2606:4700::1111'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
            $script:requestHeaders.Authorization.Substring(6))) | Should -Be 'custom-user:synthetic+key'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $MaximumRedirection -eq 0 }
    }
    It 'uses the hostname for authentication when Username is unspecified' {
        $cfg = [pscustomobject]@{Hostname='host.example.org';UpdateUrl='https://example.org/update'}
        $script:requestAuthorization = $null
        Mock Invoke-WebRequest {
            $script:requestAuthorization = [string]$Headers.Authorization
            [pscustomobject]@{Content='nochg 8.8.8.8'}
        }
        Invoke-DynDnsRequest $cfg 'synthetic' '8.8.8.8' | Should -Be 'nochg 8.8.8.8'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
            $script:requestAuthorization.Substring(6))) | Should -Be 'host.example.org:synthetic'
    }
    It 'maps a genuine HTTP 401 response to badauth' {
        $cfg = [pscustomobject]@{Hostname='host.example.org';UpdateUrl='https://example.org/update'}
        Mock Invoke-WebRequest {
            $exception = New-Object System.Net.WebException('Unauthorized')
            $response = [pscustomobject]@{StatusCode=401}
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response -Force
            throw $exception
        }
        Invoke-DynDnsRequest $cfg 'synthetic' '8.8.8.8' | Should -Be 'badauth'
    }
    It 'propagates HTTP 503 rather than treating it as bad credentials' {
        $cfg = [pscustomobject]@{Hostname='host.example.org';UpdateUrl='https://example.org/update'}
        Mock Invoke-WebRequest {
            $exception = New-Object System.Net.WebException('Simulated HTTP 503')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue (
                [pscustomobject]@{StatusCode=503}) -Force
            throw $exception
        }
        { Invoke-DynDnsRequest $cfg 'synthetic' '8.8.8.8' } | Should -Throw '*Simulated HTTP 503*'
    }
    It 'propagates a network exception without an HTTP response' {
        $cfg = [pscustomobject]@{Hostname='host.example.org';UpdateUrl='https://example.org/update'}
        Mock Invoke-WebRequest { throw 'Simulated connection failure' }
        { Invoke-DynDnsRequest $cfg 'synthetic' '8.8.8.8' } |
            Should -Throw '*Simulated connection failure*'
    }
    It 'rotates the log after one MiB without dropping the new line' {
        $path = Join-Path $TestDrive 'rotate-client.log'
        [IO.File]::WriteAllBytes($path, (New-Object byte[] 1048576))
        Write-ClientLog $path INFO 'After rotation'
        (Get-Item -LiteralPath ($path + '.1')).Length | Should -Be 1048576
        (Get-Content -LiteralPath $path -Raw) | Should -Match 'After rotation'
        Write-ClientLog $path INFO 'Second entry'
        (Get-Content -LiteralPath $path -Raw) | Should -Match 'Second entry'
    }
    It 'redacts URL-escaped secrets and truncates excessive error messages' {
        $secret = 'synthetic password+value'
        try { throw ('failure ' + [uri]::EscapeDataString($secret) + ' ' + ('x' * 1400)) }
        catch { $msg = Format-ClientFailure $_ $secret }
        $msg | Should -Not -Match ([regex]::Escape($secret))
        $msg | Should -Not -Match ([regex]::Escape([uri]::EscapeDataString($secret)))
        $msg | Should -Match '[.][.][.]$'
        $msg.Length | Should -BeLessThan 850
    }
    It 'rejects duplicate script assets and inconsistent release metadata' {
        $asset = [pscustomobject]@{
            name='PSDynDNS.ps1';digest=('sha256:' + ('a' * 64))
            browser_download_url='https://github.com/MDI-GmbH/PSDynDNS/releases/download/v1.2.0/PSDynDNS.ps1'
        }
        $release = [pscustomobject]@{
            tag_name='v1.2.0';draft=$false;prerelease=$false;assets=@($asset,$asset)
        }
        { Select-PSDynDnsRelease @($release) stable } | Should -Throw '*No usable*'
        $release.assets = @($asset)
        $release.prerelease = $true
        { Select-PSDynDnsRelease @($release) beta } | Should -Throw '*No usable*'
        $release.prerelease = $false
        $release.draft = $true
        { Select-PSDynDnsRelease @($release) beta } | Should -Throw '*No usable*'
    }
    It 'requires the exact case of the release tag while accepting repository casing' {
        $release = [pscustomobject]@{
            tag_name='v2.1.0';draft=$false;prerelease=$false
            assets=@([pscustomobject]@{
                name='PSDynDNS.ps1';digest=('sha256:' + ('a' * 64))
                browser_download_url='https://github.com/MDI-GmbH/PSDynDNS/releases/download/v2.0.0/PSDynDNS.ps1'
            })
        }
        $wrongTagUrl = 'https://github.com/MDI-GmbH/PSDynDNS/releases/download/V2.1.0/PSDynDNS.ps1'
        $matchingUrl = 'https://github.com/mdi-gmbh/psdyndns/releases/download/v2.1.0/PSDynDNS.ps1'
        # Client selector, including the existing different-version rejection.
        { Select-PSDynDnsRelease -Releases @($release) -Channel stable } |
            Should -Throw '*No usable*'
        $release.assets[0].browser_download_url = $wrongTagUrl
        { Select-PSDynDnsRelease -Releases @($release) -Channel stable } |
            Should -Throw '*No usable*'
        $release.assets[0].browser_download_url = $matchingUrl
        (Select-PSDynDnsRelease -Releases @($release) -Channel stable).Tag |
            Should -Be 'v2.1.0'

        # Installer selector must enforce the same contract.
        $installer = Join-Path $PSScriptRoot '..\Install-PSDynDNS.ps1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($installer,[ref]$tokens,[ref]$errors)
        $fn = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Select-PSDynDnsRelease'
        },$true))
        $fn.Count | Should -Be 1
        $installerSelector = [scriptblock]::Create($fn[0].Extent.Text)
        & {
            . $installerSelector
            $release.assets[0].browser_download_url = $wrongTagUrl
            { Select-PSDynDnsRelease -Releases @($release) -Channel stable } |
                Should -Throw '*No usable*'
            $release.assets[0].browser_download_url = $matchingUrl
            (Select-PSDynDnsRelease -Releases @($release) -Channel stable).Tag |
                Should -Be 'v2.1.0'
        }
    }

    It 'uses SHA256 comparison for main-channel automatic update decisions' {
        $root = Join-Path $TestDrive 'main-hash-comparison'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $statePath = Join-Path $root 'state.json'
        $logPath = Join-Path $root 'client.log'
        $cfg = [pscustomobject]@{AutoUpdate=$true;UpdateCheckHours=1;UpdateChannel='main'}
        # Dot-sourced functions and Pester blocks may have different
        # PSCommandPath values. Control the hash returned to the updater.
        Mock Get-FileHash { [pscustomobject]@{ Hash=('a' * 64) } }
        $script:mainCandidateHash = 'a' * 64
        Mock Get-UpdateCandidate {
            [pscustomobject]@{Channel='main';Sha256=$script:mainCandidateHash}
        }
        Mock Start-SelfUpdate {}
        $state = Read-ClientState $statePath
        Invoke-SoftwareUpdate $cfg $state $statePath $logPath
        Should -Invoke Start-SelfUpdate -Times 0 -Exactly
        Should -Invoke Get-FileHash -Times 1 -Exactly -ParameterFilter { $Algorithm -eq 'SHA256' }
        $state = Read-ClientState $statePath
        $state.LastSuccessfulUpdateCheckUtc = $null
        $state.LastUpdateAttemptUtc = [datetime]::UtcNow.AddMinutes(-31).ToString('o')
        Save-ClientState $statePath $state
        $script:mainCandidateHash = '0' * 64
        Invoke-SoftwareUpdate $cfg $state $statePath $logPath
        Should -Invoke Start-SelfUpdate -Times 1 -Exactly
        Should -Invoke Get-FileHash -Times 2 -Exactly -ParameterFilter { $Algorithm -eq 'SHA256' }
    }

    It 'respects the successful software-update-check interval' {
        $root = Join-Path $TestDrive 'update-interval'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $path = Join-Path $root 'state.json'
        $state = Read-ClientState $path
        $state.LastSuccessfulUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
        Save-ClientState $path $state
        $cfg = [pscustomobject]@{AutoUpdate=$true;UpdateCheckHours=24;UpdateChannel='beta'}
        Mock Get-UpdateCandidate { throw 'Should not query GitHub during successful-check window' }
        Invoke-SoftwareUpdate $cfg $state $path (Join-Path $root 'client.log')
        Should -Invoke Get-UpdateCandidate -Times 0 -Exactly
    }
    It 'does not treat an unreadable state file as empty state' {
        $path = Join-Path $TestDrive 'locked-state.json'
        [IO.File]::WriteAllText($path, '{}')
        $lock = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        try { { Read-ClientState $path } | Should -Throw '*Cannot read state.json*' }
        finally { $lock.Dispose() }
        (Get-Content -LiteralPath $path -Raw) | Should -Be '{}'
    }
    It 'preserves prior successful check time when an attempt is throttled' {
        $root = Join-Path $TestDrive 'attempt-window'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $path = Join-Path $root 'state.json'
        $state = Read-ClientState $path
        # Expired successful-check interval means only the recent attempt can throttle.
        $previousSuccess = [datetime]::UtcNow.AddHours(-25).ToString('o')
        $state.LastSuccessfulUpdateCheckUtc = $previousSuccess
        $state.LastUpdateAttemptUtc = [datetime]::UtcNow.ToString('o')
        Save-ClientState $path $state
        $cfg = [pscustomobject]@{AutoUpdate=$true;UpdateCheckHours=24;UpdateChannel='beta'}
        Mock Get-UpdateCandidate { throw 'GitHub must not be queried during retry window' }
        Invoke-SoftwareUpdate $cfg $state $path (Join-Path $root 'client.log')
        Should -Invoke Get-UpdateCandidate -Times 0 -Exactly
        $state.LastSuccessfulUpdateCheckUtc | Should -Be $previousSuccess
        (Read-ClientState $path).LastSuccessfulUpdateCheckUtc | Should -Be $previousSuccess
    }

    It 'compares alpha, beta, rc and final release ordering at the same version' {
        $previousVersion = $script:Version
        try {
            $script:Version = '1.2.3-beta.2'
            $candidate = [pscustomobject]@{Channel='beta';Version=[version]'1.2.3';Rank=2;PreNumber=3}
            Test-CandidateNewer $candidate | Should -BeTrue
            $candidate.PreNumber = 1
            Test-CandidateNewer $candidate | Should -BeFalse
            $candidate.Rank = 3
            Test-CandidateNewer $candidate | Should -BeTrue
            $candidate.Rank = 1
            Test-CandidateNewer $candidate | Should -BeFalse
            $candidate.Rank = 4
            Test-CandidateNewer $candidate | Should -BeTrue
        } finally { $script:Version = $previousVersion }
    }

    It 'updates only IPv6 when IPv4 is disabled' {
        $root = Join-Path $TestDrive 'ipv6-only'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'runtime')) | Out-Null
        $configPath = Join-Path $root 'config.json'
        [pscustomobject]@{
            Hostname='host.example.org';UpdateUrl='https://example.org/nic/update'
            IPv4Enabled=$false;IPv6Enabled=$true
            IPv6CheckUrl='https://example.org/ip6';AutoUpdate=$false
        } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        Mock Get-PublicAddress { '2606:4700:4700::1111' }
        Mock Get-DnsComparison { [pscustomobject]@{Matches=$false;Observation='A=;AAAA='} }
        Mock Read-MachineSecret { 'synthetic' }
        Mock Invoke-DynDnsRequest { 'good 2606:4700:4700::1111' }
        { Invoke-Client $configPath $false } | Should -Not -Throw
        Should -Invoke Get-PublicAddress -Times 1 -Exactly -ParameterFilter {
            $Family -eq [Net.Sockets.AddressFamily]::InterNetworkV6
        }
        Should -Invoke Invoke-DynDnsRequest -Times 1 -Exactly -ParameterFilter {
            $AddressList -eq '2606:4700:4700::1111'
        }
    }
    It 'sends both IPv4 and IPv6 when configured for dual stack' {
        $root = Join-Path $TestDrive 'dual-stack'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $root 'runtime')) | Out-Null
        $configPath = Join-Path $root 'config.json'
        [pscustomobject]@{
            Hostname='host.example.org';UpdateUrl='https://example.org/nic/update'
            IPv4Enabled=$true;IPv6Enabled=$true
            IPv4CheckUrl='https://example.org/ip4';IPv6CheckUrl='https://example.org/ip6'
            AutoUpdate=$false
        } | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        Mock Get-PublicAddress {
            if ($Family -eq [Net.Sockets.AddressFamily]::InterNetwork) { '8.8.8.8' }
            else { '2606:4700:4700::1111' }
        }
        Mock Get-DnsComparison { [pscustomobject]@{Matches=$false;Observation='A=1.1.1.1;AAAA='} }
        Mock Read-MachineSecret { 'synthetic' }
        Mock Invoke-DynDnsRequest { 'good 8.8.8.8' }
        { Invoke-Client $configPath $false } | Should -Not -Throw
        Should -Invoke Invoke-DynDnsRequest -Times 1 -Exactly -ParameterFilter {
            $AddressList -eq '8.8.8.8,2606:4700:4700::1111'
        }
        (Read-ClientState (Join-Path $root 'runtime\state.json')).LastIPv6 |
            Should -Be '2606:4700:4700::1111'
    }
}

Describe 'Client CLI conflicting parameter validation' {
    It 'rejects incompatible update switches before reading configuration' {
        $client = Join-Path $PSScriptRoot '..\PSDynDNS.ps1'
        $exe = if ($PSVersionTable.PSEdition -eq 'Core') {
            (Get-Command pwsh.exe -CommandType Application).Source
        } else {
            Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        # Windows PowerShell 5.1 promotes native stderr redirected with 2>&1
        # to a PowerShell error. Read separate process streams instead.
        $stdout = Join-Path $TestDrive 'cli-stdout.txt'
        $stderr = Join-Path $TestDrive 'cli-stderr.txt'
        foreach ($switches in @(
            [pscustomobject]@{Args=@('-UpgradeChannel','beta');Error='requires -ForceUpgrade'},
            [pscustomobject]@{Args=@('-ForceUpgrade','-ForceDnsUpdate');Error='not both'}
        )) {
            $arguments = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
                '-File',('"' + $client + '"')) + $switches.Args
            $process = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow `
                -RedirectStandardOutput $stdout -RedirectStandardError $stderr
            $process.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath $stderr -Raw) | Should -Match $switches.Error
        }
    }
}

Describe 'Installer schedule defaults and validation' {
    It 'rejects unsupported task intervals before registering any task' {
        { Install-Task -Minutes 0 } | Should -Throw '*IntervalMinutes*'
        { Install-Task -Minutes 1441 } | Should -Throw '*IntervalMinutes*'
    }
    It 'uses a ten-minute fallback for missing or invalid scheduled-task intervals' {
        $script:TaskName = 'PSDynDNS-CI-NoTask'
        Mock Get-ScheduledTask { $null }
        Get-ExistingTaskInterval | Should -Be 10
        Mock Get-ScheduledTask {
            [pscustomobject]@{
                Triggers=@([pscustomobject]@{
                    Repetition=[pscustomobject]@{ Interval='invalid-interval' }
                })
            }
        }
        Get-ExistingTaskInterval | Should -Be 10
    }
}

Describe 'Installer atomic configuration and secret preservation' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($script:Root) | Out-Null
        $script:ConfigPath = Join-Path $script:Root 'config.json'
        $script:CredentialSecret = $null
        $script:InstallerBoundParameters = @{}
    }
    It 'preserves the previous configuration when replacement is blocked' {
        $cfg = [pscustomobject]@{
            Hostname='host.example.org';UpdateUrl='https://example.org/update'
            IPv4Enabled=$true;IPv6Enabled=$false
            IPv4CheckUrl='https://example.org/ip4'
        }
        Save-Settings $cfg
        $before = (Get-FileHash -LiteralPath $script:ConfigPath -Algorithm SHA256).Hash
        $cfg.Hostname = 'changed.example.org'
        $lock = [IO.File]::Open($script:ConfigPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { { Save-Settings $cfg } | Should -Throw }
        finally { $lock.Dispose() }
        (Get-FileHash -LiteralPath $script:ConfigPath -Algorithm SHA256).Hash | Should -Be $before
        (Test-Path -LiteralPath ($script:ConfigPath + '.new')) | Should -BeFalse
    }
    It 'rejects invalid configuration without modifying the installed file' {
        $cfg = [pscustomobject]@{
            Hostname='host.example.org';UpdateUrl='https://example.org/update'
            IPv4Enabled=$true;IPv6Enabled=$false
            IPv4CheckUrl='https://example.org/ip4'
        }
        Save-Settings $cfg
        $hash = (Get-FileHash -LiteralPath $script:ConfigPath -Algorithm SHA256).Hash
        $cfg.UpdateUrl = 'http://insecure.example.org/update'
        { Save-Settings $cfg } | Should -Throw '*Invalid HTTPS*'
        (Get-FileHash -LiteralPath $script:ConfigPath -Algorithm SHA256).Hash | Should -Be $hash
        (Test-Path -LiteralPath ($script:ConfigPath + '.new')) | Should -BeFalse
    }
    It 'preserves the previous machine DPAPI secret when replacement is blocked' {
        $path = Join-Path $script:Root 'secret.dpapi'
        $script:CredentialSecret = ConvertTo-SecureString 'synthetic-first' -AsPlainText -Force
        Save-Secret
        $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $script:CredentialSecret = ConvertTo-SecureString 'synthetic-second' -AsPlainText -Force
        $lock = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { { Save-Secret } | Should -Throw }
        finally { $lock.Dispose() }
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $before
        (Test-Path -LiteralPath ($path + '.new')) | Should -BeFalse
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
            [IO.File]::ReadAllBytes($path),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        try { [Text.Encoding]::UTF8.GetString($bytes) | Should -Be 'synthetic-first' }
        finally { [Array]::Clear($bytes,0,$bytes.Length) }
    }
}