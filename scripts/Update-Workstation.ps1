[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Plan,
    [string[]]$Action = @(),
    [ValidateSet('', 'low', 'medium')][string]$Risk = '',
    [switch]$Apply,
    [ValidateNotNullOrEmpty()][string]$PolicyPath,
    [ValidateNotNullOrEmpty()][string]$LogDirectory
)

# Applies selected update-plan actions under docs/policies/update-execution-safety.md.
# Without -Apply it only previews. This is the only entry point that can change the workstation.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Core\Comparison.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Execution\Execution.Core.psm1') -Force

# Resolved here, not in param(): Windows PowerShell 5.1 leaves $PSScriptRoot empty in -File defaults.
if ([string]::IsNullOrWhiteSpace($PolicyPath)) { $PolicyPath = Join-Path $PSScriptRoot '..\config\workstation.policy.json' }
if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $LogDirectory = Join-Path $PSScriptRoot '..\reports\update-log' }

# powershell.exe -File passes "-Action 3,7" as one string.
$Action = @($Action | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not (Test-Path -LiteralPath $Plan -PathType Leaf)) { throw "Update plan was not found: $Plan" }
$planObject = ConvertFrom-WorkstationJson -Json (Get-Content -LiteralPath $Plan -Encoding UTF8 -Raw)
$policyDigest = Get-ExecutionFileDigest -Path ([IO.Path]::GetFullPath($PolicyPath))

$result = Invoke-WorkstationUpdate -Plan $planObject -PolicyDigest $policyDigest -Action $Action -Risk $Risk -Apply:$Apply -LogDirectory $LogDirectory

Write-Host ''
if (-not $Apply) { Write-Host 'Dry run: nothing was changed. Add -Apply to run the selected actions.' }
$result.log.actions | Group-Object result | ForEach-Object { Write-Host ("{0}: {1}" -f $_.Name, $_.Count) }
Write-Host "Log: $($result.logPath)"
Write-Host 'After applying updates, re-run the audit and the plan; the new plan shows what remains.'
