#requires -Version 5.1
Describe 'PSDynDNS self-update process integration' -Tag 'Integration' {
    It 'verifies checksum rejection, syntax rejection, replacement and rollback' {
        $runtime = if ($PSVersionTable.PSEdition -eq 'Core') {
            'PowerShell7'
        } else {
            'WindowsPowerShell'
        }
        & (Join-Path $PSScriptRoot 'Integration.SelfUpdate.Windows.ps1') -Runtime $runtime
        if ($LASTEXITCODE -ne 0) {
            throw "Self-update integration returned exit code $LASTEXITCODE."
        }
    }
}
