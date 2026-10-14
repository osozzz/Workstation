[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Sprint 9 (v1.1.0 Policy Evaluation) release gate for parent issue #159.

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$expectedCriteria = @('policy-schema-validated', 'every-key-mapped', 'evaluation-deterministic-private', 'evaluation-without-mutation', 'real-report-rehearsal')
$manualCriteria = @('real-report-rehearsal')

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-CoverageMatrix {
    param(
        [Parameter(Mandatory)][psobject]$Matrix,
        [Parameter(Mandatory)][string[]]$JobIds
    )

    $problems = New-Object System.Collections.Generic.List[string]
    if ($Matrix.issue -ne 159) {
        $problems.Add('Coverage matrix must target parent issue #159.')
    }

    $ids = @($Matrix.criteria | ForEach-Object { $_.id })
    if ((@($ids | Sort-Object) -join ',') -ne (@($expectedCriteria | Sort-Object) -join ',')) {
        $problems.Add("Acceptance criteria drift. Found: $($ids -join ', ').")
    }

    foreach ($criterion in @($Matrix.criteria)) {
        foreach ($relativePath in @($criterion.evidence)) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath))) {
                $problems.Add("Criterion '$($criterion.id)' references missing evidence '$relativePath'.")
            }
        }

        if (@($criterion.evidence).Count -eq 0 -or @($criterion.checks).Count -eq 0) {
            $problems.Add("Criterion '$($criterion.id)' needs evidence and at least one CI check.")
        }

        foreach ($check in @($criterion.checks)) {
            if ($check -notin $JobIds) {
                $problems.Add("Criterion '$($criterion.id)' references missing CI check '$check'.")
            }
        }

        $isManual = $null -ne $criterion.PSObject.Properties['manual'] -and -not [string]::IsNullOrWhiteSpace([string]$criterion.manual)
        if (($criterion.id -in $manualCriteria) -ne $isManual) {
            $problems.Add("Criterion '$($criterion.id)' has the wrong manual-evidence marker.")
        }
    }

    return $problems.ToArray()
}

# 1. Every #159 phase-1 criterion maps to evidence; the real-report rehearsal is declared manual.
$workflowText = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\validate.yml'))
$jobIds = @([regex]::Matches($workflowText, '(?m)^  ([a-z0-9-]+):\s*$') | ForEach-Object { $_.Groups[1].Value })
$matrix = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'coverage-matrix.json') -Encoding UTF8 -Raw | ConvertFrom-Json
$problems = @(Test-CoverageMatrix -Matrix $matrix -JobIds $jobIds)
Assert-True ($problems.Count -eq 0) ("Coverage matrix is invalid:`n" + ($problems -join "`n"))

$broken = $matrix | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$broken.criteria[0].evidence = @('docs/missing.md')
$broken.criteria[1].checks = @('missing-check')
$broken.criteria[4].PSObject.Properties.Remove('manual')
Assert-True (@(Test-CoverageMatrix -Matrix $broken -JobIds $jobIds).Count -eq 3) 'Coverage matrix validation must reject missing evidence, unknown checks, and a dropped manual marker.'

# 2. The rule catalog and the policy agree in both directions.
Import-Module (Join-Path $root 'scripts\Core\Comparison.Core.psm1') -Force
Import-Module (Join-Path $root 'scripts\Core\PolicyEvaluation.Core.psm1') -Force
$policy = ConvertFrom-WorkstationJson -Json (Get-Content -LiteralPath (Join-Path $root 'config\workstation.policy.json') -Encoding UTF8 -Raw)
$ruleKeys = @(Get-PolicyEvaluationRuleKeys)
$drift = @(Compare-Object @(Get-PolicyLeafKeys -Policy $policy) $ruleKeys)
Assert-True ($drift.Count -eq 0) "Policy keys and evaluation rules differ: $(@($drift | ForEach-Object { $_.InputObject }) -join ', ')"

# 3. Operators can find the evaluator.
$runbook = [IO.File]::ReadAllText((Join-Path $root 'docs\audit\running-the-audit.md'))
Assert-True ($runbook.Contains('Run-Evaluate.cmd')) 'The operator runbook must cover Run-Evaluate.cmd.'
$docsIndex = [IO.File]::ReadAllText((Join-Path $root 'docs\README.md'))
Assert-True ($docsIndex.Contains('architecture/policy-evaluation-contract.md')) 'docs/README.md must index the policy evaluation contract.'

Write-Host "Sprint 9 Policy Evaluation gate passed: $($matrix.criteria.Count) criteria mapped; $($ruleKeys.Count) rules match the policy."
Write-Host 'Manual evidence still required:'
$matrix.criteria | Where-Object { $_.PSObject.Properties['manual'] } | ForEach-Object { Write-Host "  - $($_.id): $($_.manual)" }
