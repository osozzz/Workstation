[CmdletBinding()]
param(
    [switch]$OfflineVersionIntelligence,
    [ValidateNotNullOrEmpty()][string]$DataDirectory
)

# Audits this PC, then rebuilds the evaluation and the update plan from that report. Read-only:
# nothing is installed or changed. The desktop app's "Audit this PC" runs this script.
# -DataDirectory holds reports\ and config\workstation.local.json. The installed app passes its user
# data folder, because every app update replaces the folder these scripts run from.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DataDirectory)) { $DataDirectory = Join-Path $PSScriptRoot '..' }
$reports = Join-Path $DataDirectory 'reports'
$audit = & (Join-Path $PSScriptRoot 'Audit-Workstation.ps1') -OutputDirectory $reports -LocalConfigurationPath (Join-Path $DataDirectory 'config\workstation.local.json') -IncludeWingetInventory -OfflineVersionIntelligence:$OfflineVersionIntelligence -PassThru 6>$null

& (Join-Path $PSScriptRoot 'Evaluate-Workstation.ps1') -Report $audit.JsonPath -OutputDirectory (Join-Path $reports 'evaluation') | Out-Null
& (Join-Path $PSScriptRoot 'Plan-WorkstationUpdate.ps1') -Report $audit.JsonPath -OutputDirectory (Join-Path $reports 'update-plan') | Out-Null

Write-Host "Refreshed from $($audit.JsonPath)"
