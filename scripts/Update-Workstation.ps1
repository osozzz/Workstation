[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Plan,
    [switch]$FixWinGetDownloader,
    [string[]]$Action = @(),
    [ValidateSet('', 'low', 'medium')][string]$Risk = '',
    [switch]$Apply,
    [switch]$ConfirmAll,
    [switch]$SkipVerify,
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

$attempted = @($result.log.actions | Where-Object { $_.result -in @('succeeded', 'failed') }).Count
if (-not $Apply -or $attempted -eq 0) { return }
if ($SkipVerify) {
    Write-Host 'Verification skipped. Re-run the audit and the plan to see what remains.'
    return
}

# Verify: audit again, rebuild the plan, and compare it with what ran. The new plan replaces the old one
# so the next run starts from the machine's real state.
Write-Host ''
Write-Host 'Verifying: auditing the PC again (a few minutes)...'
Import-Module (Join-Path $PSScriptRoot 'Core\PolicyEvaluation.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Core\UpdatePlan.Core.psm1') -Force
$audit = & (Join-Path $PSScriptRoot 'Audit-Workstation.ps1') -IncludeWingetInventory -PassThru 6>$null
$policyObject = ConvertFrom-WorkstationJson -Json (Get-Content -LiteralPath $PolicyPath -Encoding UTF8 -Raw)
$newPlan = New-WorkstationUpdatePlan -Report $audit.Report -Policy $policyObject -PolicyDigest $policyDigest
$planOutputs = Write-WorkstationUpdatePlanOutputs -Plan $newPlan -OutputDirectory (Join-Path (Split-Path -Parent $LogDirectory) 'update-plan')

$verification = Get-ExecutionVerification -Log $result.log -NewPlan $newPlan
$result.log | Add-Member -NotePropertyName verification -NotePropertyValue $verification -Force
Write-ExecutionLog -Path $result.logPath -Log $result.log

Write-Host ''
Write-Host ("Verified: {0} updated and no longer pending. Still pending: {1}. Now resolved: {2}." -f $verification.verifiedCount, $verification.stillPendingCount, $verification.resolvedCount)
foreach ($item in @($verification.actions | Where-Object { $_.verification -eq 'still-pending' -and $_.runResult -eq 'succeeded' })) {
    Write-Host ("  ran but still pending {0}. {1} ({2} -> {3})" -f $item.order, $item.title, $item.currentVersion, $item.targetVersion)
}
Write-Host "New plan: $($planOutputs.humanReadablePath) ($($verification.remainingPlanCount) action(s) left)"

