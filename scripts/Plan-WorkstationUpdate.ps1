[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Report,
    [ValidateNotNullOrEmpty()][string]$PolicyPath,
    [ValidateNotNullOrEmpty()][string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Core\Comparison.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Core\PolicyEvaluation.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Core\UpdatePlan.Core.psm1') -Force

# Resolved here, not in param(): Windows PowerShell 5.1 leaves $PSScriptRoot empty in -File defaults.
if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $PSScriptRoot '..\config\workstation.policy.json'
}

function Read-WorkstationJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label was not found: $Path"
    }

    try {
        return ConvertFrom-WorkstationJson -Json (Get-Content -LiteralPath $Path -Encoding UTF8 -Raw -ErrorAction Stop)
    }
    catch {
        throw "$Label is not valid JSON: $Path ($($_.Exception.Message))"
    }
}

$reportObject = Read-WorkstationJsonFile -Path $Report -Label 'Audit report'
$policyObject = Read-WorkstationJsonFile -Path $PolicyPath -Label 'Workstation policy'

# .NET directly: Get-FileHash may not autoload when Windows PowerShell inherits a PowerShell 7 module path.
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $policyDigest = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($PolicyPath)))).Replace('-', '').ToLowerInvariant()
}
finally {
    $sha.Dispose()
}

$plan = New-WorkstationUpdatePlan -Report $reportObject -Policy $policyObject -PolicyDigest $policyDigest

if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Write-WorkstationUpdatePlanOutputs -Plan $plan -OutputDirectory $OutputDirectory | Out-Null
}

$plan
