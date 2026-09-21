[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'winget.baseline'
        category   = 'package-manager'
        order      = 40
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$hasPartial = $false
$unavailable = $false

$upgrade = Invoke-AuditCommand -Command 'winget' -Arguments @(
    'upgrade',
    '--accept-source-agreements',
    '--disable-interactivity'
) -TimeoutSeconds 90

if (-not $upgrade.Found) {
    $unavailable = $true
    $warningArgs = @{
        Code = 'WINGET_NOT_FOUND'
        Message = 'WinGet is unavailable; upgrade and inventory diagnostics could not be collected.'
        Severity = 'warning'
    }
    $warnings.Add((New-AuditIssue @warningArgs))
}
else {
    $upgradeEvidenceArgs = @{
        EvidenceId = 'winget.upgrades'
        Type = 'command'
        Source = 'winget upgrade --accept-source-agreements --disable-interactivity'
        ExitCode = $upgrade.ExitCode
        Captured = $upgrade.Captured
        Redacted = $upgrade.Redacted
        Attributes = @{
            status = $upgrade.Status
            truncated = $upgrade.Truncated
            timedOut = $upgrade.TimedOut
        }
    }
    $evidence.Add((New-AuditEvidence @upgradeEvidenceArgs))

    if ($upgrade.Status -ne 'success') {
        $hasPartial = $true
        $warningArgs = @{
            Code = 'WINGET_UPGRADE_QUERY_FAILED'
            Message = 'WinGet upgrade diagnostics did not complete successfully.'
            Severity = 'warning'
            EvidenceIds = @('winget.upgrades')
        }
        $warnings.Add((New-AuditIssue @warningArgs))
    }

    if ($Context.IncludeWingetInventory) {
        $inventory = Invoke-AuditCommand -Command 'winget' -Arguments @(
            'list',
            '--accept-source-agreements',
            '--disable-interactivity'
        ) -TimeoutSeconds 90

        $inventoryEvidenceArgs = @{
            EvidenceId = 'winget.inventory'
            Type = 'command'
            Source = 'winget list --accept-source-agreements --disable-interactivity'
            ExitCode = $inventory.ExitCode
            Captured = $inventory.Captured
            Redacted = $inventory.Redacted
            Attributes = @{
                status = $inventory.Status
                truncated = $inventory.Truncated
                timedOut = $inventory.TimedOut
            }
        }
        $evidence.Add((New-AuditEvidence @inventoryEvidenceArgs))

        if ($inventory.Status -ne 'success') {
            $hasPartial = $true
            $warningArgs = @{
                Code = 'WINGET_INVENTORY_QUERY_FAILED'
                Message = 'WinGet inventory diagnostics did not complete successfully.'
                Severity = 'warning'
                EvidenceIds = @('winget.inventory')
            }
            $warnings.Add((New-AuditIssue @warningArgs))
        }
    }
}

$status = if ($unavailable) {
    'unavailable'
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial
}

return [pscustomobject][ordered]@{
    providerId = 'winget.baseline'
    category   = 'package-manager'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
