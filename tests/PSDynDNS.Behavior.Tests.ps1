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
    It 'decodes binary public-IP response content' {
        Mock Invoke-WebRequest { [pscustomobject]@{Content=[Text.Encoding]::UTF8.GetBytes('8.8.8.8')} }
        Get-PublicAddress -Url 'https://example.org/myip' -Family ([Net.Sockets.AddressFamily]::InterNetwork) | Should -Be '8.8.8.8'
    }
}
Describe 'Shared semantic release selection' {
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
