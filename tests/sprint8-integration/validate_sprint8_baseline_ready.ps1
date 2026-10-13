[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Sprint 8 (v1.0.0 Baseline Ready) release gate for parent issue #12. Automated criteria must map
# to existing evidence and CI checks; criteria that need real workstations must say so explicitly.

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$matrixPath = Join-Path $PSScriptRoot 'coverage-matrix.json'
$coverageDocPath = Join-Path $root 'docs\architecture\audit-system-roadmap.md'

$expectedCriteria = @(
    'required-categories-covered'
    'audit-without-mutation'
    'normalized-json-output'
    'human-readable-output'
    'outputs-ignored-by-git'
    'version-intelligence-explicit'
    'projects-and-git-health'
    'comparison-on-final-schema'
    'ci-suite-passes'
    'documentation-coverage-limitations-safety'
    'pc1-audit'
    'pc2-comparison'
)
$manualCriteria = @('pc1-audit', 'pc2-comparison')

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

    if ($Matrix.issue -ne 12) {
        $problems.Add('Coverage matrix must target parent issue #12.')
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

        # Real-workstation criteria must stay explicitly manual; automated ones must not hide behind it.
        $isManual = $null -ne $criterion.PSObject.Properties['manual'] -and -not [string]::IsNullOrWhiteSpace([string]$criterion.manual)
        if (($criterion.id -in $manualCriteria) -ne $isManual) {
            $problems.Add("Criterion '$($criterion.id)' has the wrong manual-evidence marker.")
        }
    }

    return $problems.ToArray()
}

# 1. Every #12 criterion maps to evidence; real-PC criteria are declared manual.
$workflowText = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\validate.yml'))
$jobIds = @([regex]::Matches($workflowText, '(?m)^  ([a-z0-9-]+):\s*$') | ForEach-Object { $_.Groups[1].Value })
$matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
$problems = @(Test-CoverageMatrix -Matrix $matrix -JobIds $jobIds)
Assert-True ($problems.Count -eq 0) ("Coverage matrix is invalid:`n" + ($problems -join "`n"))

$broken = $matrix | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$broken.criteria[0].evidence = @('docs/missing.md')
$broken.criteria[1].checks = @('missing-check')
$broken.criteria[10].PSObject.Properties.Remove('manual')
Assert-True (@(Test-CoverageMatrix -Matrix $broken -JobIds $jobIds).Count -eq 3) 'Coverage matrix validation must reject missing evidence, unknown checks, and a dropped manual marker.'

# 2. The coverage statement names every built-in provider, so new providers cannot ship undocumented.
$coverageDoc = [IO.File]::ReadAllText($coverageDocPath)
$providerIds = foreach ($provider in Get-ChildItem -LiteralPath (Join-Path $root 'scripts\Providers') -Filter '*.Provider.ps1' -File) {
    (& $provider.FullName -Describe).providerId
}
Assert-True (@($providerIds).Count -ge 20) 'Expected the built-in provider set to be discoverable.'
$undocumented = @($providerIds | Where-Object { -not $coverageDoc.Contains("``$_``") })
Assert-True ($undocumented.Count -eq 0) "docs/architecture/audit-system-roadmap.md must cover providers: $($undocumented -join ', ')"

# 3. The documents an operator needs exist and point at each other.
$runbook = [IO.File]::ReadAllText((Join-Path $root 'docs\audit\running-the-audit.md'))
foreach ($marker in @('Run-Audit.cmd', 'Run-Compare.cmd', 'workstation.local.json', 'audit-safety.md', 'audit-system-roadmap.md')) {
    Assert-True ($runbook.Contains($marker)) "The operator runbook must mention '$marker'."
}
$readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
Assert-True ($readme.Contains('docs/audit/running-the-audit.md')) 'README must link the operator runbook.'

$pending = @($matrix.criteria | Where-Object { $_.PSObject.Properties['manual'] } | ForEach-Object { "$($_.id): $($_.manual)" })
Write-Host "Sprint 8 Baseline Ready gate passed: $($matrix.criteria.Count) criteria mapped; $($providerIds.Count) providers documented."
Write-Host "Manual evidence still required after release:"
$pending | ForEach-Object { Write-Host "  - $_" }
