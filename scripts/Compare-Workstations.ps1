[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reference,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Target,
    [ValidateNotNullOrEmpty()][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$corePath = Join-Path $PSScriptRoot 'Core\Comparison.Core.psm1'
$outputPath = Join-Path $PSScriptRoot 'Core\Comparison.Output.psm1'
Import-Module $corePath -Force
Import-Module $outputPath -Force

function Read-NormalizedAuditReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Role report was not found: $Path"
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop |
            ConvertFrom-Json -Depth 100 -ErrorAction Stop
    }
    catch {
        throw "$Role report is not valid JSON: $Path"
    }
}

$referenceReport = Read-NormalizedAuditReport -Path $Reference -Role reference
$targetReport = Read-NormalizedAuditReport -Path $Target -Role target

$comparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport

if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Write-WorkstationComparisonOutputs -Comparison $comparison -OutputDirectory $OutputDirectory | Out-Null
}

$comparison
