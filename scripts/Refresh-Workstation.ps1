[CmdletBinding()]
param(
    [switch]$OfflineVersionIntelligence
)

# Audits this PC, then rebuilds the evaluation and the update plan from that report. Read-only:
# nothing is installed or changed. The desktop app's "Audit this PC" runs this script.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$reports = Join-Path $PSScriptRoot '..\reports'
$audit = & (Join-Path $PSScriptRoot 'Audit-Workstation.ps1') -IncludeWingetInventory -OfflineVersionIntelligence:$OfflineVersionIntelligence -PassThru 6>$null

& (Join-Path $PSScriptRoot 'Evaluate-Workstation.ps1') -Report $audit.JsonPath -OutputDirectory (Join-Path $reports 'evaluation') | Out-Null
& (Join-Path $PSScriptRoot 'Plan-WorkstationUpdate.ps1') -Report $audit.JsonPath -OutputDirectory (Join-Path $reports 'update-plan') | Out-Null

Write-Host "Refreshed from $($audit.JsonPath)"
