BeforeAll {
    . (Join-Path $PSScriptRoot '..\PSDynDNS.ps1')
}
Describe 'State, HTTP and configuration regression tests' {
    It 'accepts a state.json containing only an empty object' {
        $file = Join-Path $TestDrive 'state-empty.json'
        [IO.File]::WriteAllText($file,'{}')
        $state = Read-ClientState $file
        $state.LastIPv4 | Should -BeNullOrEmpty
        $state.BlockedReason | Should -BeNullOrEmpty
        $state.LastSuccessfulUpdateCheckUtc | Should -BeNullOrEmpty
    }
    It 'atomically replaces an existing state with an explicit backup' {
        $file = Join-Path $TestDrive 'state-replace.json'
        [IO.File]::WriteAllText($file,'{}')
        $state = Read-ClientState $file
        $state.LastIPv4 = '8.8.8.8'
        { Save-ClientState $file $state } | Should -Not -Throw
        (Read-ClientState $file).LastIPv4 | Should -Be '8.8.8.8'
        (Test-Path -LiteralPath ($file + '.bak')) | Should -BeTrue
    }
    It 'uses the common validator for FQDNs, DNS resolvers and enabled IP families' {
        $cfg = [pscustomobject]@{
            Hostname='bad..example.org'; UpdateUrl='https://example.org/nic/update'
            IPv4Enabled=$true; IPv6Enabled=$false; IPv4CheckUrl='https://example.org/ip4'
            IPv6CheckUrl='not-a-url'; DnsServers=@('8.8.8.8','8.8.4.4')
            UpdateCheckHours=24; UpdateChannel='stable'
        }
        { Assert-PSDynDnsSettings $cfg } | Should -Throw
        $cfg.Hostname = 'test.example.org'
        { Assert-PSDynDnsSettings $cfg } | Should -Not -Throw
        $cfg.DnsServers = @('invalid dns host')
        { Assert-PSDynDnsSettings $cfg } | Should -Throw
        $cfg.DnsServers = @('8.8.8.8')
        $cfg.IPv6Enabled = $true
        { Assert-PSDynDnsSettings $cfg } | Should -Throw
    }
    It 'rejects an invalid IP-check service response' {
        Mock Invoke-WebRequest { [pscustomobject]@{Content='invalid-ip'} }
        { Get-PublicAddress -Url 'https://example.org/myip' -Family ([Net.Sockets.AddressFamily]::InterNetwork) } |
            Should -Throw '*expected family*'
    }
    It 'rejects a redirected IP-check response' {
        Mock Invoke-WebRequest { throw 'simulated redirect rejected' }
        { Get-PublicAddress -Url 'https://example.org/myip' -Family ([Net.Sockets.AddressFamily]::InterNetwork) } |
            Should -Throw '*redirect*'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $MaximumRedirection -eq 0 }
    }
    It 'decodes binary public-IP response content' {
        Mock Invoke-WebRequest { [pscustomobject]@{Content=[Text.Encoding]::UTF8.GetBytes('8.8.8.8')} }
        Get-PublicAddress -Url 'https://example.org/myip' -Family ([Net.Sockets.AddressFamily]::InterNetwork) | Should -Be '8.8.8.8'
    }
}
Describe 'Shared semantic release selection' {
    It 'accepts an Invoke-RestMethod-style nested array and retains the full asset digest' {
        $oldDigest = ('a' * 64)
        $newDigest = ('b' * 64)
        $old = [pscustomobject]@{
            tag_name='v0.1.0-beta.1'; draft=$false; prerelease=$true
            assets=@([pscustomobject]@{
                name='PSDynDNS.ps1'; digest=('sha256:' + $oldDigest)
                browser_download_url='https://github.com/MDI-GmbH/PSDynDNS/releases/download/v0.1.0-beta.1/PSDynDNS.ps1'
            })
        }
        $new = [pscustomobject]@{
            tag_name='v0.1.0-beta.2'; draft=$false; prerelease=$true
            assets=@([pscustomobject]@{
                name='PSDynDNS.ps1'; digest=('sha256:' + $newDigest)
                browser_download_url='https://github.com/MDI-GmbH/PSDynDNS/releases/download/v0.1.0-beta.2/PSDynDNS.ps1'
            })
        }
        # Model the nested object[] returned by Invoke-RestMethod inside @(...).
        $nested = New-Object 'object[]' 1
        $nested[0] = @($new, $old)

        $candidate = Select-PSDynDnsRelease -Releases $nested -Channel beta
        $candidate.Tag | Should -Be 'v0.1.0-beta.2'
        $candidate.Sha256 | Should -Be $newDigest
        $candidate.Url | Should -Be $new.assets[0].browser_download_url

        # Also exercise the installer's own standalone selection function.
        $installer = Join-Path $PSScriptRoot '..\Install-PSDynDNS.ps1'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $installer, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        $definitions = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Select-PSDynDnsRelease'
        }, $true))
        $definitions.Count | Should -Be 1
        # Evaluate only this local function definition, without executing the installer.
        $function = [scriptblock]::Create($definitions[0].Extent.Text)
        . $function
        $candidate = Select-PSDynDnsRelease -Releases $nested -Channel beta
        $candidate.Tag | Should -Be 'v0.1.0-beta.2'
        $candidate.Sha256 | Should -Be $newDigest
    }
    It 'selects the highest version rather than the first GitHub API result' {
        $digest = 'sha256:' + ('a' * 64)
        $asset = [pscustomobject]@{
            name='PSDynDNS.ps1';digest=$digest
            browser_download_url='https://github.com/MDI-GmbH/PSDynDNS/releases/download/v0.2.0-beta.10/PSDynDNS.ps1'
        }
        $releases = @(
            [pscustomobject]@{tag_name='v0.2.0-beta.2';draft=$false;prerelease=$true;assets=@($asset)}
            [pscustomobject]@{tag_name='v0.2.0-beta.10';draft=$false;prerelease=$true;assets=@($asset)}
            [pscustomobject]@{tag_name='v0.1.9';draft=$false;prerelease=$false;assets=@($asset)}
        )
        (Select-PSDynDnsRelease -Releases $releases -Channel beta).Tag | Should -Be 'v0.2.0-beta.10'
        (Select-PSDynDnsRelease -Releases $releases -Channel stable).Tag | Should -Be 'v0.1.9'
    }
}
Describe 'DNS as source of truth' {
    It 'matches the public IP to the published DNS A record' {
        Mock Get-PublishedDnsAddresses { '82.149.168.179' }
        (Get-DnsComparison -Hostname 'test.example.org' -Servers @('8.8.8.8') -IPv4 '82.149.168.179' -IPv4Enabled $true -IPv6Enabled $false).Matches | Should -BeTrue
    }
    It 'identifies a manually changed DNS record as drift' {
        Mock Get-PublishedDnsAddresses { '203.0.113.2' }
        (Get-DnsComparison -Hostname 'test.example.org' -Servers @('8.8.8.8') -IPv4 '82.149.168.179' -IPv4Enabled $true -IPv6Enabled $false).Matches | Should -BeFalse
    }
    It 'fails closed when a DNS server times out' {
        Mock Resolve-DnsName { throw 'DNS server timeout' }
        { Get-PublishedDnsAddresses -Hostname 'test.example.org' -RecordType A -Servers @('8.8.8.8') } | Should -Throw '*DNS lookup*'
    }
    It 'treats an explicit DNS no-record answer as drift' {
        Mock Resolve-DnsName {
            $e = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('No record'),
                'DNS_INFO_NO_RECORDS',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                'test.example.org'
            )
            throw $e
        }
        @(Get-PublishedDnsAddresses -Hostname 'test.example.org' -RecordType A -Servers @('8.8.8.8')).Count | Should -Be 0
    }
}
Describe 'Provider errors and software-update retries' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'runtime'))
        $script:testConfig = Join-Path $root 'config.json'
        $cfg = [pscustomobject]@{
            Hostname='host.example.org';UpdateUrl='https://example.org/nic/update'
            IPv4Enabled=$true;IPv6Enabled=$false;IPv4CheckUrl='https://example.org/myip'
            IPv6CheckUrl='https://example.org/myipv6';AutoUpdate=$false
            UpdateCheckHours=24;UpdateChannel='stable'
        }
        $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:testConfig -Encoding UTF8
        $script:testState = Join-Path $root 'runtime\state.json'
        '{}' | Set-Content -LiteralPath $script:testState -Encoding UTF8
        Mock Get-PublicAddress { '82.149.168.179' }
        Mock Get-DnsComparison { [pscustomobject]@{Matches=$false;Observation='A=203.0.113.2;AAAA='} }
        Mock Read-MachineSecret { 'fake-ci-secret' }
    }
    It 'exits with error for badauth and persists a blocked reason' {
        Mock Invoke-DynDnsRequest { 'badauth' }
        { Invoke-Client -Path $script:testConfig -Force $false } | Should -Throw '*badauth*'
        (Read-ClientState $script:testState).BlockedReason | Should -Be 'badauth'
        { Invoke-Client -Path $script:testConfig -Force $false } | Should -Throw '*blocked*'
        Should -Invoke Invoke-DynDnsRequest -Times 1 -Exactly
    }
    It 'updates DNS drift even when LastIPv4 matches the public address' {
        $state = Read-ClientState $script:testState
        $state.LastIPv4 = '82.149.168.179'
        Save-ClientState $script:testState $state
        Mock Invoke-DynDnsRequest { 'good 82.149.168.179' }
        { Invoke-Client -Path $script:testConfig -Force $false } | Should -Not -Throw
        Should -Invoke Invoke-DynDnsRequest -Times 1 -Exactly
    }
    It 'skips the DynDNS provider when DNS already matches' {
        Mock Get-DnsComparison { [pscustomobject]@{Matches=$true;Observation='A=82.149.168.179;AAAA='} }
        Mock Invoke-DynDnsRequest { throw 'Provider must not be contacted' }
        { Invoke-Client -Path $script:testConfig -Force $false } | Should -Not -Throw
        Should -Invoke Invoke-DynDnsRequest -Times 0
    }
    It 'handles 911 as a temporary failure with persisted retry backoff' {
        Mock Invoke-DynDnsRequest { '911' }
        { Invoke-Client -Path $script:testConfig -Force $false } | Should -Throw '*911*'
        (Read-ClientState $script:testState).RetryAfterUtc | Should -Not -BeNullOrEmpty
        { Invoke-Client -Path $script:testConfig -Force $false } | Should -Throw '*backoff*'
        Should -Invoke Invoke-DynDnsRequest -Times 1 -Exactly
    }
    It 'accepts nochg without marking the provider as blocked' {
        Mock Invoke-DynDnsRequest { 'nochg 82.149.168.179' }
        { Invoke-Client -Path $script:testConfig -Force $false } | Should -Not -Throw
        (Read-ClientState $script:testState).BlockedReason | Should -BeNullOrEmpty
        (Read-ClientState $script:testState).LastIPv4 | Should -Be '82.149.168.179'
    }
    It 'does not repeat a successful provider update against stale DNS cache' {
        Mock Invoke-DynDnsRequest { 'good 82.149.168.179' }
        Invoke-Client -Path $script:testConfig -Force $false
        Invoke-Client -Path $script:testConfig -Force $false
        Should -Invoke Invoke-DynDnsRequest -Times 1 -Exactly
    }
    It 'does not persist a successful update after an unknown provider response' {
        Mock Invoke-DynDnsRequest { 'unsupported-provider-token' }
        { Invoke-Client -Path $script:testConfig -Force $false } | Should -Throw '*Unrecognized*'
        (Read-ClientState $script:testState).LastProviderUpdateUtc | Should -BeNullOrEmpty
    }
    It 'bypasses DNS comparison only for an explicit force update' {
        Mock Get-DnsComparison { throw 'DNS comparison must be skipped' }
        Mock Invoke-DynDnsRequest { 'good 82.149.168.179' }
        { Invoke-Client -Path $script:testConfig -Force $true } | Should -Not -Throw
        Should -Invoke Get-DnsComparison -Times 0
        Should -Invoke Invoke-DynDnsRequest -Times 1 -Exactly
    }
    It 'retries a failed download after 30 minutes instead of a full update interval' {
        $state = Read-ClientState $script:testState
        $cfg = [pscustomobject]@{AutoUpdate=$true;UpdateCheckHours=24;UpdateChannel='stable'}
        Mock Get-UpdateCandidate {
            [pscustomobject]@{Channel='stable';Version=[version]'99.0.0';Rank=4;PreNumber=0}
        }
        Mock Start-SelfUpdate { throw 'simulated download failure' }
        $logPath = Join-Path (Split-Path $script:testState) 'client.log'

        Invoke-SoftwareUpdate $cfg $state $script:testState $logPath
        $saved = Read-ClientState $script:testState
        $saved.LastUpdateAttemptUtc | Should -Not -BeNullOrEmpty
        $saved.LastSuccessfulUpdateCheckUtc | Should -BeNullOrEmpty
        Invoke-SoftwareUpdate $cfg $saved $script:testState $logPath
        Should -Invoke Start-SelfUpdate -Times 1 -Exactly

        $saved.LastUpdateAttemptUtc = [datetime]::UtcNow.AddMinutes(-31).ToString('o')
        Save-ClientState $script:testState $saved
        Invoke-SoftwareUpdate $cfg $saved $script:testState $logPath
        Should -Invoke Start-SelfUpdate -Times 2 -Exactly
    }
    It 'does not count staging an update as an installed version' {
        $state = Read-ClientState $script:testState
        $cfg = [pscustomobject]@{AutoUpdate=$true;UpdateCheckHours=24;UpdateChannel='stable'}
        Mock Get-UpdateCandidate {
            [pscustomobject]@{Channel='stable';Version=[version]'99.0.0';Rank=4;PreNumber=0}
        }
        Mock Start-SelfUpdate {}
        Invoke-SoftwareUpdate $cfg $state $script:testState (Join-Path (Split-Path $script:testState) 'client.log')
        (Read-ClientState $script:testState).LastSuccessfulUpdateCheckUtc | Should -BeNullOrEmpty
        Should -Invoke Start-SelfUpdate -Times 1 -Exactly
    }
    It 'records the normal interval after checking and finding no newer release' {
        $state = Read-ClientState $script:testState
        $cfg = [pscustomobject]@{AutoUpdate=$true;UpdateCheckHours=24;UpdateChannel='stable'}
        Mock Get-UpdateCandidate {
            [pscustomobject]@{Channel='stable';Version=[version]'0.0.1';Rank=4;PreNumber=0}
        }
        Mock Start-SelfUpdate { throw 'no update should be launched' }
        Invoke-SoftwareUpdate $cfg $state $script:testState (Join-Path (Split-Path $script:testState) 'client.log')
        (Read-ClientState $script:testState).LastSuccessfulUpdateCheckUtc | Should -Not -BeNullOrEmpty
        Should -Invoke Start-SelfUpdate -Times 0 -Exactly
    }
    It 'records attempted but not successful GitHub check on transient failure' {
        $state = Read-ClientState $script:testState
        $cfg = [pscustomobject]@{AutoUpdate=$true;UpdateCheckHours=24;UpdateChannel='stable'}
        Mock Get-UpdateCandidate { throw 'GitHub unavailable' }
        Invoke-SoftwareUpdate $cfg $state $script:testState (Join-Path (Split-Path $script:testState) 'client.log')
        $saved = Read-ClientState $script:testState
        $saved.LastUpdateAttemptUtc | Should -Not -BeNullOrEmpty
        $saved.LastSuccessfulUpdateCheckUtc | Should -BeNullOrEmpty
    }
}

Describe 'Asynchronous update helper results' {
    BeforeEach {
        $script:statusRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($script:statusRoot) | Out-Null
        $script:resultState = Join-Path $script:statusRoot 'state.json'
        $script:resultLog = Join-Path $script:statusRoot 'client.log'
        $script:resultPath = Join-Path $script:statusRoot 'update-result.json'
    }
    It 'records helper success once and deletes the consumed result' {
        $state = Read-ClientState $script:resultState
        '{"Result":"success"}' | Set-Content -LiteralPath $script:resultPath -Encoding UTF8
        Read-UpdateResult $script:resultState $state $script:resultLog
        (Read-ClientState $script:resultState).LastSuccessfulUpdateCheckUtc | Should -Not -BeNullOrEmpty
        (Test-Path -LiteralPath $script:resultPath) | Should -BeFalse
    }
    It 'retains the retry window on helper failure' {
        $state = Read-ClientState $script:resultState
        $state.LastUpdateAttemptUtc = [datetime]::UtcNow.ToString('o')
        Save-ClientState $script:resultState $state
        '{"Result":"failed"}' | Set-Content -LiteralPath $script:resultPath -Encoding UTF8
        Read-UpdateResult $script:resultState $state $script:resultLog
        (Read-ClientState $script:resultState).LastSuccessfulUpdateCheckUtc | Should -BeNullOrEmpty
        (Test-Path -LiteralPath $script:resultPath) | Should -BeFalse
    }
    It 'ignores and removes an invalid helper result' {
        $state = Read-ClientState $script:resultState
        '{"Result":"other"}' | Set-Content -LiteralPath $script:resultPath -Encoding UTF8
        { Read-UpdateResult $script:resultState $state $script:resultLog } | Should -Not -Throw
        (Test-Path -LiteralPath $script:resultPath) | Should -BeFalse
    }
}
Describe 'Manual channel-based ForceUpgrade' {
    BeforeEach {
        $path = Join-Path $TestDrive ('force-upgrade-' + [guid]::NewGuid().ToString('N') + '.json')
        $config = [pscustomobject]@{
            Hostname='test.example.org';UpdateUrl='https://example.org/nic/update'
            IPv4Enabled=$true;IPv6Enabled=$false;IPv4CheckUrl='https://example.org/myip'
            AutoUpdate=$false;UpdateChannel='beta';UpdateCheckHours=24
        }
        $config | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
        $script:forceConfig = $path
        Mock Get-UpdateCandidate {
            [pscustomobject]@{Channel=$Channel;Sha256=('a' * 64)}
        }
        Mock Start-SelfUpdate {}
    }
    It 'uses beta from config even when automatic updates are disabled' {
        Invoke-ForcedUpgrade -Path $script:forceConfig
        Should -Invoke Get-UpdateCandidate -Times 1 -Exactly -ParameterFilter { $Channel -eq 'beta' }
        Should -Invoke Start-SelfUpdate -Times 1 -Exactly
    }
    It 'allows a one-time stable override without changing config' {
        Invoke-ForcedUpgrade -Path $script:forceConfig -ChannelOverride stable
        Should -Invoke Get-UpdateCandidate -Times 1 -Exactly -ParameterFilter { $Channel -eq 'stable' }
        (Get-Content $script:forceConfig -Raw | ConvertFrom-Json).UpdateChannel | Should -Be 'beta'
    }
    It 'allows explicit main source selection' {
        Invoke-ForcedUpgrade -Path $script:forceConfig -ChannelOverride main
        Should -Invoke Get-UpdateCandidate -Times 1 -Exactly -ParameterFilter { $Channel -eq 'main' }
    }
    It 'does not perform DNS update or discovery while installing software' {
        Mock Invoke-DynDnsRequest { throw 'Must not contact provider' }
        Mock Get-PublicAddress { throw 'Must not discover IP' }
        Invoke-ForcedUpgrade -Path $script:forceConfig
        Should -Invoke Invoke-DynDnsRequest -Times 0
        Should -Invoke Get-PublicAddress -Times 0
    }
}

Describe 'Additional mock-based network paths' {
    It 'rejects an IPv6 reply when requesting IPv4' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content='2606:4700:4700::1111' } }
        { Get-PublicAddress -Url 'https://example.org/ip4' -Family ([Net.Sockets.AddressFamily]::InterNetwork) } | Should -Throw '*expected family*'
    }
    It 'rejects non-public IP response content' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content='192.168.2.1' } }
        { Get-PublicAddress -Url 'https://example.org/ip4' -Family ([Net.Sockets.AddressFamily]::InterNetwork) } | Should -Throw '*non-routable*'
    }
    It 'decodes binary DynDNS provider responses' {
        $cfg = [pscustomobject]@{ Hostname='test.example.org';UpdateUrl='https://example.org/nic/update' }
        Mock Invoke-WebRequest { [pscustomobject]@{ Content=[Text.Encoding]::UTF8.GetBytes('nochg 8.8.8.8') } }
        Invoke-DynDnsRequest -Config $cfg -Secret 'synthetic-key' -AddressList '8.8.8.8' | Should -Be 'nochg 8.8.8.8'
    }
    It 'parses text DynDNS provider responses' {
        $cfg = [pscustomobject]@{ Hostname='test.example.org';UpdateUrl='https://example.org/nic/update' }
        Mock Invoke-WebRequest { [pscustomobject]@{ Content='good 8.8.8.8' } }
        Invoke-DynDnsRequest -Config $cfg -Secret 'synthetic-key' -AddressList '8.8.8.8' | Should -Be 'good 8.8.8.8'
    }
    It 'fails closed when two DNS resolvers disagree' {
        Mock Resolve-DnsName {
            if ($Server -eq '8.8.8.8') {
                [pscustomobject]@{ Type='A';IPAddress='82.149.168.179' }
            } else {
                [pscustomobject]@{ Type='A';IPAddress='82.149.168.178' }
            }
        }
        { Get-PublishedDnsAddresses -Hostname 'host.example.org' -RecordType A -Servers @('8.8.8.8','8.8.4.4') } | Should -Throw '*disagree*'
    }
    It 'matches configured IPv6 AAAA to public IPv6' {
        Mock Get-PublishedDnsAddresses { '2606:4700:4700::1111' }
        $result = Get-DnsComparison -Hostname 'host.example.org' -Servers @('8.8.8.8') -IPv6 '2606:4700:4700::1111' -IPv4Enabled $false -IPv6Enabled $true
        $result.Matches | Should -BeTrue
    }
    It 'detects mismatched IPv6 AAAA records' {
        Mock Get-PublishedDnsAddresses { '2606:4700:4700::1001' }
        $result = Get-DnsComparison -Hostname 'host.example.org' -Servers @('8.8.8.8') -IPv6 '2606:4700:4700::1111' -IPv4Enabled $false -IPv6Enabled $true
        $result.Matches | Should -BeFalse
    }
}

Describe 'GitHub update trust and API failure paths' {
    BeforeEach {
        $script:gitBlobContent = [Text.Encoding]::UTF8.GetBytes("Write-Output 'test'")
        $sha1 = [Security.Cryptography.SHA1]::Create()
        try {
            $prefix = [Text.Encoding]::ASCII.GetBytes('blob ' + $script:gitBlobContent.Length + [char]0)
            $raw = New-Object byte[] ($prefix.Length + $script:gitBlobContent.Length)
            [Array]::Copy($prefix,0,$raw,0,$prefix.Length)
            [Array]::Copy($script:gitBlobContent,0,$raw,$prefix.Length,$script:gitBlobContent.Length)
            $script:gitBlobSha = ([BitConverter]::ToString($sha1.ComputeHash($raw))).Replace('-','').ToLowerInvariant()
        } finally { $sha1.Dispose() }
        $script:commitSha = 'a' * 40
    }
    It 'rejects a forged GitHub main commit identifier' {
        Mock Invoke-RestMethod { [pscustomobject]@{sha='not-a-commit'} }
        { Get-UpdateCandidate main } | Should -Throw '*commit SHA*'
    }
    It 'rejects a GitHub source blob with unsupported encoding' {
        Mock Invoke-RestMethod {
            if ($Uri -match '/commits/main$') { return [pscustomobject]@{sha=$script:commitSha} }
            return [pscustomobject]@{sha=$script:gitBlobSha;encoding='utf-8';content='hello'}
        }
        { Get-UpdateCandidate main } | Should -Throw '*source blob*'
    }
    It 'rejects a GitHub source blob with a manipulated content hash' {
        Mock Invoke-RestMethod {
            if ($Uri -match '/commits/main$') { return [pscustomobject]@{sha=$script:commitSha} }
            return [pscustomobject]@{
                sha=('f' * 40);encoding='base64'
                content=[Convert]::ToBase64String($script:gitBlobContent)
            }
        }
        { Get-UpdateCandidate main } | Should -Throw '*digest mismatch*'
    }
    It 'calculates Git blob and SHA256 hashes for a valid main response' {
        Mock Invoke-RestMethod {
            if ($Uri -match '/commits/main$') { return [pscustomobject]@{sha=$script:commitSha} }
            return [pscustomobject]@{
                sha=$script:gitBlobSha;encoding='base64'
                content=[Convert]::ToBase64String($script:gitBlobContent)
            }
        }
        $candidate = Get-UpdateCandidate main
        $candidate.Channel | Should -Be 'main'
        $candidate.Commit | Should -Be $script:commitSha
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $expectedHash = ([BitConverter]::ToString(
                $sha256.ComputeHash($script:gitBlobContent)
            )).Replace('-', '').ToLowerInvariant()
        } finally { $sha256.Dispose() }
        $candidate.Sha256 | Should -Be $expectedHash
    }
    It 'rejects published releases lacking verifiable assets' {
        $release = [pscustomobject]@{
            tag_name='v2.0.0';draft=$false;prerelease=$false
            assets=@([pscustomobject]@{
                name='PSDynDNS.ps1';digest='sha256:invalid'
                browser_download_url='https://github.com/MDI-GmbH/PSDynDNS/releases/download/v2.0.0/PSDynDNS.ps1'
            })
        }
        { Select-PSDynDnsRelease @($release) stable } | Should -Throw '*No usable*'
    }
    It 'rejects release assets served from a different host' {
        $release = [pscustomobject]@{
            tag_name='v2.0.0';draft=$false;prerelease=$false
            assets=@([pscustomobject]@{
                name='PSDynDNS.ps1';digest=('sha256:' + ('a' * 64))
                browser_download_url='https://evil.example/releases/download/PSDynDNS.ps1'
            })
        }
        { Select-PSDynDnsRelease @($release) stable } | Should -Throw '*No usable*'
    }
    It 'uses the release API instead of network calls for a fabricated stable response' {
        Mock Invoke-RestMethod { throw 'simulated GitHub outage' }
        { Get-UpdateCandidate stable } | Should -Throw '*GitHub outage*'
    }
}
Describe 'Config, DPAPI and local state fault handling' {
    It 'rejects a missing client configuration' {
        { Read-ClientConfig (Join-Path $TestDrive 'missing.json') } | Should -Throw '*not found*'
    }
    It 'rejects invalid updater interval and channel' {
        $cfg = [pscustomobject]@{
            Hostname='host.example.org'; UpdateUrl='https://example.org/update'
            IPv4Enabled=$true; IPv6Enabled=$false
            IPv4CheckUrl='https://example.org/myip'
            UpdateCheckHours=0; UpdateChannel='stable'
        }
        { Assert-PSDynDnsSettings $cfg } | Should -Throw '*UpdateCheckHours*'
        $cfg.UpdateCheckHours=24
        $cfg.UpdateChannel='preview'
        { Assert-PSDynDnsSettings $cfg } | Should -Throw '*UpdateChannel*'
    }
    It 'rejects an empty DNS resolver list' {
        $cfg = [pscustomobject]@{
            Hostname='host.example.org'; UpdateUrl='https://example.org/update'
            IPv4Enabled=$true; IPv6Enabled=$false
            IPv4CheckUrl='https://example.org/myip';DnsServers=@()
        }
        { Assert-PSDynDnsSettings $cfg } | Should -Throw '*DnsServers*'
    }
    It 'fails closed if the encrypted DPAPI key is absent' {
        { Read-MachineSecret (Join-Path $TestDrive 'missing.dpapi') } | Should -Throw '*missing*'
    }
    It 'fails closed if encrypted DPAPI ciphertext is corrupt' {
        $secretFile = Join-Path $TestDrive 'corrupt.dpapi'
        [IO.File]::WriteAllBytes($secretFile,[byte[]](4,9,1,5,4))
        { Read-MachineSecret $secretFile } | Should -Throw
    }
    It 'rejects non-object JSON as runtime state' {
        $stateFile = Join-Path $TestDrive 'scalar.json'
        'null' | Set-Content -LiteralPath $stateFile
        { Read-ClientState $stateFile } | Should -Throw '*JSON object*'
    }
}
