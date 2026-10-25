#requires -Version 5.1
# Execute the real installer UpdateClient branch with isolated Task Scheduler dependencies.
# Only synthetic files under Pester TestDrive are modified.
BeforeAll {
    $installerFile = Join-Path $PSScriptRoot '..\Install-PSDynDNS.ps1'
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $installerFile, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Installer has syntax errors.' }
    $clauses = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.SwitchStatementAst]
    }, $true) | ForEach-Object { $_.Clauses } | Where-Object {
        $_.Item1.Extent.Text -eq 'UpdateClient'
    })
    if ($clauses.Count -ne 1) { throw 'Expected exactly one UpdateClient installer branch.' }
    $bodyText = $clauses[0].Item2.Extent.Text
    $script:UpdateClientBody = [scriptblock]::Create($bodyText.Substring(1, $bodyText.Length - 2))

    function Read-Settings { return $script:FakeConfig }
    function Install-ClientFile {
        param([string]$Source,[string]$Channel,[string]$Destination)
        # The normal input-validation and download paths are tested independently.
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
    }
    function Ensure-Directories {}
    function Set-ProtectedAcl {
        param([string]$Path,[switch]$ClientRead)
        $script:AclOperations++
        if ($script:InjectAclError -and $Path -eq $script:ClientPath) {
            $script:InjectAclError = $false
            throw 'Simulated post-swap ACL failure'
        }
    }
    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        if (-not $script:TaskExists) { return $null }
        return [pscustomobject]@{ State=$script:FakeTaskState }
    }
    function Disable-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        if ($script:FakeTaskState -ne 'Running') { $script:FakeTaskState = 'Disabled' }
    }
    function Enable-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        $script:FakeTaskState = 'Ready'
    }
    function Stop-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName)
        $script:StopCalls++
        if ($script:StopFailure) { throw 'Simulated task stop failure' }
        $script:FakeTaskState = 'Disabled'
    }
    function Copy-Item {
        [CmdletBinding()]
        param([string]$LiteralPath,[string]$Destination,[switch]$Force)
        if ($script:InjectRollbackCopyError -and $LiteralPath -like '*.manual-*.bak' -and
            $Destination -eq $script:ClientPath) {
            throw 'Simulated rollback copy failure'
        }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
}

Describe 'Manual installer update rollback and task recovery' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:App = Join-Path $script:Root 'app'
        [IO.Directory]::CreateDirectory($script:App) | Out-Null
        $script:ConfigPath = Join-Path $script:Root 'config.json'
        $script:TaskName = 'PSDynDNS-CI-Simulated'
        $script:InstallerBoundParameters = @{}
        $script:FakeConfig = [pscustomobject]@{UpdateChannel='beta'}
        $script:LocalClientPath = Join-Path $script:Root 'synthetic-candidate.ps1'
        $script:ClientPath = Join-Path $script:App 'PSDynDNS.ps1'
        [IO.File]::WriteAllText($script:ClientPath, 'Write-Host "installed version"')
        [IO.File]::WriteAllText($script:LocalClientPath, 'Write-Host "candidate version"')
        $script:OriginalHash = (Get-FileHash -LiteralPath $script:ClientPath -Algorithm SHA256).Hash
        $script:FakeTaskState = 'Ready'
        $script:InjectAclError = $false
        $script:InjectRollbackCopyError = $false
        $script:AclOperations = 0
        $script:StopCalls = 0
        $script:TaskExists = $true
        $script:StopFailure = $false
    }

    It 'restores original client bytes after failure immediately following replacement' {
        $script:InjectAclError = $true
        { & $script:UpdateClientBody } | Should -Throw '*Simulated post-swap ACL failure*'
        (Get-FileHash -LiteralPath $script:ClientPath -Algorithm SHA256).Hash |
            Should -Be $script:OriginalHash
        $backups = @(Get-ChildItem -LiteralPath $script:App -Filter '*.manual-*.bak')
        $backups.Count | Should -Be 1
        (Get-FileHash -LiteralPath $backups[0].FullName -Algorithm SHA256).Hash |
            Should -Be $script:OriginalHash
        $script:AclOperations | Should -Be 2
        $script:FakeTaskState | Should -Be 'Ready'
        (Test-Path -LiteralPath ($script:ClientPath + '.manual.new')) | Should -BeFalse
    }

    It 'reports rollback failure without losing the intact backup' {
        $script:InjectAclError = $true
        $script:InjectRollbackCopyError = $true
        $warnings = @()
        { & $script:UpdateClientBody } |
            Should -Throw '*Simulated post-swap ACL failure*'
        $backups = @(Get-ChildItem -LiteralPath $script:App -Filter '*.manual-*.bak')
        $backups.Count | Should -Be 1
        (Get-FileHash -LiteralPath $backups[0].FullName -Algorithm SHA256).Hash |
            Should -Be $script:OriginalHash
        $script:FakeTaskState | Should -Be 'Ready'
        (Test-Path -LiteralPath ($script:ClientPath + '.manual.new')) | Should -BeFalse
    }

    It 'rejects updating without a registered task before staging' {
        $script:TaskExists = $false
        { & $script:UpdateClientBody } | Should -Throw '*Scheduled task missing*'
        (Get-FileHash -LiteralPath $script:ClientPath -Algorithm SHA256).Hash |
            Should -Be $script:OriginalHash
        (Test-Path -LiteralPath ($script:ClientPath + '.manual.new')) | Should -BeFalse
    }

    It 'rejects updating a missing installed client without creating a staging file' {
        [IO.File]::Delete($script:ClientPath)
        { & $script:UpdateClientBody } | Should -Throw '*Installed client missing*'
        (Test-Path -LiteralPath ($script:ClientPath + '.manual.new')) | Should -BeFalse
        $script:FakeTaskState | Should -Be 'Ready'
    }

    It 'rejects using the installed script itself as the update source' {
        $script:LocalClientPath = $script:ClientPath
        { & $script:UpdateClientBody } | Should -Throw '*source must differ*'
        (Get-FileHash -LiteralPath $script:ClientPath -Algorithm SHA256).Hash |
            Should -Be $script:OriginalHash
        (Test-Path -LiteralPath ($script:ClientPath + '.manual.new')) | Should -BeFalse
    }

    It 'restores the task when stopping a running task fails' {
        $script:FakeTaskState = 'Running'
        $script:StopFailure = $true
        { & $script:UpdateClientBody } | Should -Throw '*Simulated task stop failure*'
        $script:StopCalls | Should -Be 1
        $script:FakeTaskState | Should -Be 'Ready'
        (Get-FileHash -LiteralPath $script:ClientPath -Algorithm SHA256).Hash |
            Should -Be $script:OriginalHash
        (Test-Path -LiteralPath ($script:ClientPath + '.manual.new')) | Should -BeFalse
    }

    It 'stops a running task before replacement and re-enables it after success' {
        $script:FakeTaskState = 'Running'
        { & $script:UpdateClientBody } | Should -Not -Throw
        $script:StopCalls | Should -Be 1
        $script:FakeTaskState | Should -Be 'Ready'
        (Get-FileHash -LiteralPath $script:ClientPath -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -LiteralPath $script:LocalClientPath -Algorithm SHA256).Hash
    }
}
