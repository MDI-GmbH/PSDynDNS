BeforeAll {
    . (Join-Path $PSScriptRoot '..\PSDynDNS.ps1')
}
Describe 'PSDynDNS DynDNS2 protocol' {
    It 'accepts successful good and nochg responses' {
        Get-ResponseCategory 'good 203.0.113.1' | Should -Be 'success'
        Get-ResponseCategory 'nochg 203.0.113.1' | Should -Be 'success'
    }
    It 'blocks permanent errors' {
        foreach ($code in @('badauth','notfqdn','nohost','numhost','abuse','badagent','!donator','!yours')) {
            Get-ResponseCategory $code | Should -Be 'blocked'
        }
    }
    It 'backs off on provider errors' {
        Get-ResponseCategory '911' | Should -Be 'retry'
        Get-ResponseCategory 'dnserr' | Should -Be 'retry'
    }
    It 'rejects HTTP endpoints and URL credentials' {
        { Assert-HttpsUrl 'http://example.org/nic/update' } | Should -Throw
        { Assert-HttpsUrl 'https://user:pass@example.org/nic/update' } | Should -Throw
        { Assert-HttpsUrl 'https://example.org/nic/update' } | Should -Not -Throw
    }
    It 'changes configuration fingerprint when target changes' {
        $a = [pscustomobject]@{ Hostname='one.example.org'; Username=$null; UpdateUrl='https://example.org/nic/update'; IPv4Enabled=$true; IPv6Enabled=$false }
        $b = [pscustomobject]@{ Hostname='two.example.org'; Username=$null; UpdateUrl='https://example.org/nic/update'; IPv4Enabled=$true; IPv6Enabled=$false }
        Get-ConfigurationFingerprint $a | Should -Not -Be (Get-ConfigurationFingerprint $b)
    }
    It 'accepts minimal config and rejects disabled IP families' {
        $path = Join-Path $TestDrive 'config.json'
        @{
            Hostname='test.example.org'; UpdateUrl='https://example.org/nic/update'
            IPv4Enabled=$true; IPv6Enabled=$false; IPv4CheckUrl='https://example.org/ip4'
            IPv6CheckUrl='https://example.org/ip6'
        } | ConvertTo-Json | Set-Content -LiteralPath $path
        { Read-ClientConfig $path } | Should -Not -Throw
        (Get-Content $path -Raw | ConvertFrom-Json) | ForEach-Object {
            $_.IPv4Enabled = $false
            $_ | ConvertTo-Json | Set-Content $path
        }
        { Read-ClientConfig $path } | Should -Throw
    }
}

Describe 'IP address validation' {
    It 'accepts global IPv4 and IPv6 candidates' {
        Test-PublicIp ([Net.IPAddress]::Parse('8.8.8.8')) | Should -BeTrue
        Test-PublicIp ([Net.IPAddress]::Parse('2606:4700:4700::1111')) | Should -BeTrue
    }
    It 'rejects non-public IP addresses' {
        foreach ($address in @('10.0.0.1','172.16.0.1','192.168.1.1','127.0.0.1','169.254.1.1','100.64.0.1','192.0.2.1','198.51.100.1','203.0.113.1','fe80::1','fc00::1','::1')) {
            Test-PublicIp ([Net.IPAddress]::Parse($address)) | Should -BeFalse
        }
    }
}
Describe 'State persistence' {
    It 'creates a state with optional update timestamp' {
        $state = Read-ClientState (Join-Path $TestDrive 'missing.json')
        $state.LastUpdateCheckUtc | Should -BeNullOrEmpty
    }
    It 'round-trips state in runtime' {
        $path = Join-Path $TestDrive 'state.json'
        $state = Read-ClientState $path
        $state.LastIPv4 = '8.8.8.8'
        Save-ClientState $path $state
        (Read-ClientState $path).LastIPv4 | Should -Be '8.8.8.8'
    }
    It 'rejects invalid state instead of silently updating' {
        $path = Join-Path $TestDrive 'invalid.json'
        '{corrupt' | Set-Content $path
        { Read-ClientState $path } | Should -Throw
    }
}
Describe 'Release response handling' {
    It 'never reports unknown tokens as success' {
        Get-ResponseCategory 'mystery 8.8.8.8' | Should -Be 'unknown'
    }
    It 'does not schedule an update when disabled' {
        $state = New-Object psobject -Property @{ LastUpdateCheckUtc = $null }
        $config = New-Object psobject -Property @{ AutoUpdate = $false; UpdateCheckHours = 24 }
        Mock Get-UpdateCandidate { throw 'Should not be called' }
        Invoke-SoftwareUpdate $config $state (Join-Path $TestDrive 's.json') (Join-Path $TestDrive 'x.log')
        Should -Invoke Get-UpdateCandidate -Times 0
    }
}

Describe 'Update channels and release ordering' {
    It 'compares releases using semantic ordering' {
        $candidate = [pscustomobject]@{ Channel='beta';Version=[version]'0.1.0';Rank=4;PreNumber=0 }
        Test-CandidateNewer $candidate | Should -BeTrue
        $candidate = [pscustomobject]@{ Channel='stable';Version=[version]'0.0.9';Rank=4;PreNumber=0 }
        Test-CandidateNewer $candidate | Should -BeFalse
    }
    It 'treats main as a source comparison rather than a SemVer comparison' {
        Test-CandidateNewer ([pscustomobject]@{ Channel='main' }) | Should -BeTrue
    }
    It 'uses stable by default if config predates update channels' {
        $config = [pscustomobject]@{AutoUpdate=$false;UpdateCheckHours=24}
        $state = [pscustomobject]@{LastUpdateCheckUtc=$null}
        { Invoke-SoftwareUpdate $config $state (Join-Path $TestDrive 'state.json') (Join-Path $TestDrive 'log.txt') } | Should -Not -Throw
    }
}

Describe 'Locale-independent persisted timestamps and fingerprints' {
    It 'parses roundtrip timestamps identically under multiple cultures' {
        $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        $originalUi = [Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            $utc = [datetime]::SpecifyKind([datetime]'2026-10-24T16:07:08', [DateTimeKind]::Utc)
            $roundtrip = $utc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            foreach ($name in @('en-US','de-DE','fr-FR','tr-TR')) {
                $culture = [Globalization.CultureInfo]::GetCultureInfo($name)
                [Threading.Thread]::CurrentThread.CurrentCulture = $culture
                [Threading.Thread]::CurrentThread.CurrentUICulture = $culture
                (ConvertFrom-UtcTimestamp $roundtrip).Ticks | Should -Be $utc.Ticks
                (ConvertFrom-UtcTimestamp $utc).Ticks | Should -Be $utc.Ticks
                $cfg = [pscustomobject]@{
                    Hostname = 'test.example.org'; Username = $null
                    UpdateUrl = 'https://example.org/nic/update'
                    IPv4Enabled = $true; IPv6Enabled = $false
                }
                $fingerprint = Get-ConfigurationFingerprint $cfg
                $fingerprint | Should -Match '^[a-f0-9]{64}$'
                if ($name -eq 'en-US') { $expected = $fingerprint }
                else { $fingerprint | Should -Be $expected }
            }
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
            [Threading.Thread]::CurrentThread.CurrentUICulture = $originalUi
        }
    }
}
