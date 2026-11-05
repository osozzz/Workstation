# The scripts run from a temporary copy with stubbed dependencies, so nothing here can audit or install.
BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))

    function New-StubbedScripts {
        param([string]$Script)
        $root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $scripts = Join-Path $root 'scripts'
        foreach ($folder in @('Core', 'Execution')) { [IO.Directory]::CreateDirectory((Join-Path $scripts $folder)) | Out-Null }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot "scripts\$Script") -Destination $scripts
        return $root
    }
}

Describe 'Refresh-Workstation' {
    BeforeEach {
        $script:root = New-StubbedScripts -Script 'Refresh-Workstation.ps1'
        $script:calls = Join-Path $script:root 'calls.txt'
        $scripts = Join-Path $script:root 'scripts'
        $record = "Add-Content -LiteralPath '$script:calls' -Value (`$MyInvocation.MyCommand.Name + ' ' + (`$PSBoundParameters.Keys -join ','))"
        Set-Content -LiteralPath (Join-Path $scripts 'Audit-Workstation.ps1') -Value "[CmdletBinding()] param([string]`$OutputDirectory, [string]`$LocalConfigurationPath, [switch]`$IncludeWingetInventory, [switch]`$OfflineVersionIntelligence, [switch]`$PassThru)`n$record`nAdd-Content -LiteralPath '$script:calls' -Value `"`$OutputDirectory|`$LocalConfigurationPath`"`n[pscustomobject]@{ JsonPath = 'report.json' }"
        foreach ($name in @('Evaluate-Workstation.ps1', 'Plan-WorkstationUpdate.ps1')) {
            Set-Content -LiteralPath (Join-Path $scripts $name) -Value "[CmdletBinding()] param([string]`$Report, [string]`$OutputDirectory)`n$record`nAdd-Content -LiteralPath '$script:calls' -Value `$Report"
        }
    }

    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force }

    It 'audits first, then builds the evaluation and the plan from that report' {
        & (Join-Path $script:root 'scripts\Refresh-Workstation.ps1') 6>$null

        $lines = @(Get-Content -LiteralPath $script:calls)
        $lines[0] | Should -Match '^Audit-Workstation\.ps1 .*IncludeWingetInventory'
        $lines[2] | Should -Match '^Evaluate-Workstation\.ps1'
        $lines[3] | Should -Be 'report.json'
        $lines[4] | Should -Match '^Plan-WorkstationUpdate\.ps1'
        $lines[5] | Should -Be 'report.json'
    }

    It 'keeps the reports and reads the project folders in the data directory the app passes' {
        $data = Join-Path $script:root 'data'
        & (Join-Path $script:root 'scripts\Refresh-Workstation.ps1') -DataDirectory $data 6>$null

        $lines = @(Get-Content -LiteralPath $script:calls)
        $lines[1] | Should -Be "$data\reports|$data\config\workstation.local.json"
        $lines[2] | Should -Match 'OutputDirectory'
    }
}

Describe 'Update-Workstation -ConfirmedCount' {
    BeforeEach {
        $script:root = New-StubbedScripts -Script 'Update-Workstation.ps1'
        $script:captured = Join-Path $script:root 'captured.txt'
        $scripts = Join-Path $script:root 'scripts'
        Set-Content -LiteralPath (Join-Path $scripts 'Core\Comparison.Core.psm1') -Value 'function ConvertFrom-WorkstationJson { param([string]$Json) $Json | ConvertFrom-Json }'
        Set-Content -LiteralPath (Join-Path $scripts 'Execution\Execution.Core.psm1') -Value @"
function Get-ExecutionFileDigest { param([string]`$Path) 'digest' }
function Invoke-WorkstationUpdate {
    param(`$Plan, `$PolicyDigest, `$Action, `$Risk, [switch]`$Apply, [switch]`$ConfirmAll, `$LogDirectory, [scriptblock]`$BatchConfirmer)
    `$typed = if (`$BatchConfirmer) { & `$BatchConfirmer 3 } else { 'none' }
    Set-Content -LiteralPath '$script:captured' -Value "`$(`$ConfirmAll.IsPresent)|`$typed"
    [pscustomobject]@{ logPath = 'log.json'; log = [pscustomobject]@{ actions = @() } }
}
"@
        $script:plan = Join-Path $script:root 'plan.json'
        Set-Content -LiteralPath $script:plan -Value '{}'
    }

    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force }

    It 'answers the batch check with the count the operator confirmed in the app' {
        & (Join-Path $script:root 'scripts\Update-Workstation.ps1') -Plan $script:plan -PolicyPath $script:plan -ConfirmedCount 3 6>$null

        Get-Content -LiteralPath $script:captured | Should -Be 'True|3'
    }

    # The executor compares this answer with its own count, so a wrong count must reach it unchanged.
    It 'does not adjust a count that differs from what would run' {
        & (Join-Path $script:root 'scripts\Update-Workstation.ps1') -Plan $script:plan -PolicyPath $script:plan -ConfirmedCount 5 6>$null

        Get-Content -LiteralPath $script:captured | Should -Be 'True|5'
    }

    It 'keeps the typed confirmation when no count is passed' {
        & (Join-Path $script:root 'scripts\Update-Workstation.ps1') -Plan $script:plan -PolicyPath $script:plan 6>$null

        Get-Content -LiteralPath $script:captured | Should -Be 'False|none'
    }
}

Describe 'Update-Workstation -DataDirectory' {
    BeforeEach {
        $script:root = New-StubbedScripts -Script 'Update-Workstation.ps1'
        $script:captured = Join-Path $script:root 'captured.txt'
        $scripts = Join-Path $script:root 'scripts'
        Set-Content -LiteralPath (Join-Path $scripts 'Core\Comparison.Core.psm1') -Value 'function ConvertFrom-WorkstationJson { param([string]$Json) $Json | ConvertFrom-Json }'
        Set-Content -LiteralPath (Join-Path $scripts 'Core\PolicyEvaluation.Core.psm1') -Value ''
        Set-Content -LiteralPath (Join-Path $scripts 'Core\UpdatePlan.Core.psm1') -Value @"
function New-WorkstationUpdatePlan { param(`$Report, `$Policy, `$PolicyDigest) [pscustomobject]@{} }
function Write-WorkstationUpdatePlanOutputs {
    param(`$Plan, `$OutputDirectory)
    Add-Content -LiteralPath '$script:captured' -Value "plan `$OutputDirectory"
    [pscustomobject]@{ humanReadablePath = 'plan.md' }
}
"@
        Set-Content -LiteralPath (Join-Path $scripts 'Execution\Execution.Core.psm1') -Value @"
function Get-ExecutionFileDigest { param([string]`$Path) 'digest' }
function Invoke-WorkstationUpdate {
    param(`$Plan, `$PolicyDigest, `$Action, `$Risk, [switch]`$Apply, [switch]`$ConfirmAll, `$LogDirectory, [scriptblock]`$BatchConfirmer)
    Add-Content -LiteralPath '$script:captured' -Value "log `$LogDirectory"
    [pscustomobject]@{ logPath = 'log.json'; log = [pscustomobject]@{ actions = @([pscustomobject]@{ result = 'succeeded' }) } }
}
function Get-ExecutionVerification { param(`$Log, `$NewPlan) [pscustomobject]@{ verifiedCount = 1; stillPendingCount = 0; resolvedCount = 0; remainingPlanCount = 0; actions = @() } }
function Write-ExecutionLog { param(`$Path, `$Log) }
"@
        Set-Content -LiteralPath (Join-Path $scripts 'Audit-Workstation.ps1') -Value @"
[CmdletBinding()] param([string]`$OutputDirectory, [string]`$LocalConfigurationPath, [switch]`$IncludeWingetInventory, [switch]`$PassThru)
Add-Content -LiteralPath '$script:captured' -Value "audit `$OutputDirectory|`$LocalConfigurationPath"
[pscustomobject]@{ Report = [pscustomobject]@{} }
"@
        $script:plan = Join-Path $script:root 'plan.json'
        Set-Content -LiteralPath $script:plan -Value '{}'
    }

    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force }

    # Otherwise the audit after an update would drop the projects and leave its report elsewhere.
    It 'logs, verifies and rebuilds the plan in the data directory the app passes' {
        $data = Join-Path $script:root 'data'
        & (Join-Path $script:root 'scripts\Update-Workstation.ps1') -Plan $script:plan -PolicyPath $script:plan -DataDirectory $data -Apply 6>$null

        Get-Content -LiteralPath $script:captured | Should -Be @(
            "log $data\reports\update-log"
            "audit $data\reports|$data\config\workstation.local.json"
            "plan $data\reports\update-plan"
        )
    }
}
