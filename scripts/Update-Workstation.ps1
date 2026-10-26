[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Plan,
    [switch]$FixWinGetDownloader,
    [string[]]$Action = @(),
    [ValidateSet('', 'low', 'medium')][string]$Risk = '',
    [switch]$Apply,
    [switch]$ConfirmAll,
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

# -FixWinGetDownloader: the documented fix for stalled WinGet downloads, applied only after a yes.
if ($FixWinGetDownloader) {
    Write-Host 'This sets "network": { "downloader": "wininet" } in WinGet settings, so WinGet stops using Delivery Optimization.'
    Write-Host 'The current settings file is backed up first; other settings are kept.'
    if ((Read-Host 'Apply it? [y/N]') -match '^(y|yes|s|si)$') {
        $backup = Set-WinGetDownloader
        Write-Host $(if ($backup) { "Done. Backup: $backup" } else { 'Done. WinGet had no settings file; one was created.' })
    }
    else {
        Write-Host 'Not changed.'
    }
    if ([string]::IsNullOrWhiteSpace($Plan)) { return }
}
if ([string]::IsNullOrWhiteSpace($Plan)) { throw 'Pass -Plan <update-plan.json>, or -FixWinGetDownloader on its own.' }

# powershell.exe -File passes "-Action 3,7" as one string.
$Action = @($Action | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not (Test-Path -LiteralPath $Plan -PathType Leaf)) { throw "Update plan was not found: $Plan" }
$planObject = ConvertFrom-WorkstationJson -Json (Get-Content -LiteralPath $Plan -Encoding UTF8 -Raw)
$policyDigest = Get-ExecutionFileDigest -Path ([IO.Path]::GetFullPath($PolicyPath))

$result = Invoke-WorkstationUpdate -Plan $planObject -PolicyDigest $policyDigest -Action $Action -Risk $Risk -Apply:$Apply -ConfirmAll:$ConfirmAll -LogDirectory $LogDirectory

Write-Host ''
if (-not $Apply) { Write-Host 'Dry run: nothing was changed. Add -Apply to run the selected actions.' }
$result.log.actions | Group-Object result | ForEach-Object { Write-Host ("{0}: {1}" -f $_.Name, $_.Count) }
$failures = @($result.log.actions | Where-Object result -eq 'failed')
foreach ($failure in $failures) { Write-Host ("  failed {0}. {1}: {2}" -f $failure.order, $failure.title, $failure.reason) }
Write-Host "Log: $($result.logPath)"
Write-Host 'After applying updates, re-run the audit and the plan; the new plan shows what remains.'
