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
