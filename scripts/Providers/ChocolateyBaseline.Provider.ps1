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
        providerId = 'chocolatey.baseline'
        category   = 'package-manager'
        order      = 41
    }
}

Import-Module (Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1') -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$components = New-Object System.Collections.Generic.List[object]
$hasPartial = $false
$checkedAt = [string]$Context.ObservedAt

$notApplicable = [pscustomobject][ordered]@{
    status        = 'not-applicable'
    latestStable  = $null
    latestLts     = $null
    latestCurrent = $null
    source        = $null
    checkedAt     = $null
    message       = $null
}

function ConvertFrom-ChocolateyLimitOutput {
    <#
    .SYNOPSIS
    Parses choco --limit-output lines ("id|version" or "id|current|available|pinned").
    #>
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $rows = foreach ($line in ($Text -split '\r?\n')) {
        $parts = $line.Trim().Split('|')
        if ($parts.Count -lt 2 -or $parts[0] -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]*$' -or [string]::IsNullOrWhiteSpace($parts[1])) { continue }
        , $parts
    }
    return @($rows)
}

$versionResult = Invoke-AuditCommand -Command 'choco' -Arguments @('--version') -TimeoutSeconds 30

if (-not $versionResult.Found) {
    $components.Add([pscustomobject][ordered]@{
        componentId         = 'chocolatey'
        name                = 'Chocolatey'
        state               = 'missing'
        installed           = $false
        activeVersion       = $null
        discoveredVersions  = @()
        installations       = @()
        commandResolutions  = @()
        versionIntelligence = $notApplicable
    })
}
else {
    $evidence.Add((New-AuditEvidence -EvidenceId 'chocolatey.version' -Type command -Source 'choco --version' -ExitCode $versionResult.ExitCode -Captured $versionResult.Captured -Redacted:$versionResult.Redacted -Attributes @{
        status    = $versionResult.Status
        truncated = $versionResult.Truncated
        timedOut  = $versionResult.TimedOut
    }))

    $rawVersion = (@(([string]$versionResult.Captured) -split '\r?\n') | Where-Object { $_ -match '^\s*\d+\.\d+' } | Select-Object -First 1)
    $activeVersion = $null
    if ($null -ne $rawVersion) {
        $activeVersion = New-AuditVersionRecord -Raw $rawVersion.Trim() -Normalized ([regex]::Match($rawVersion, '\d+(?:\.\d+){1,3}').Value) -Channel $null
    }

    $componentState = 'present'
    if ($versionResult.Status -ne 'success' -or $null -eq $activeVersion) {
        $componentState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'CHOCOLATEY_VERSION_UNKNOWN' -Message 'Chocolatey version detection was incomplete.' -Severity warning -ComponentId 'chocolatey' -EvidenceIds @('chocolatey.version')))
    }

    # Chocolatey 1.x "list" queries the remote feed unless --local-only is given; 2.x lists local packages only.
    $listArguments = @('list', '--limit-output')
    if ($null -ne $activeVersion -and [int]($activeVersion.normalized.Split('.')[0]) -lt 2) {
        $listArguments += '--local-only'
    }

    $list = Invoke-AuditCommand -Command 'choco' -Arguments $listArguments -TimeoutSeconds 60 -MaximumCaptureLength 262144
    $evidence.Add((New-AuditEvidence -EvidenceId 'chocolatey.inventory' -Type command -Source ('choco ' + ($listArguments -join ' ')) -ExitCode $list.ExitCode -Captured $list.Captured -Redacted:$list.Redacted -Attributes @{
        status    = $list.Status
        truncated = $list.Truncated
        timedOut  = $list.TimedOut
    }))

    $packages = @(
        if ($list.Status -eq 'success') {
            foreach ($row in ConvertFrom-ChocolateyLimitOutput -Text $list.Captured) {
                [pscustomobject][ordered]@{ packageId = $row[0]; installedVersion = $row[1] }
            }
        }
    )
    $evidence.Add((New-AuditEvidence -EvidenceId 'chocolatey.inventory.normalized' -Type derived -Source 'normalized choco list output' -Captured $null -Attributes @{
        status       = $(if ($list.Status -eq 'success') { 'known' } else { 'unavailable' })
        checkedAt    = $checkedAt
        packageCount = $packages.Count
        packages     = $packages
    }))
    if ($list.Status -ne 'success') {
        $componentState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'CHOCOLATEY_INVENTORY_QUERY_FAILED' -Message 'The Chocolatey package list did not complete successfully.' -Severity warning -ComponentId 'chocolatey' -EvidenceIds @('chocolatey.inventory')))
    }

    # Read-only: "outdated" compares local packages with the configured sources and changes nothing.
    $outdated = Invoke-AuditCommand -Command 'choco' -Arguments @('outdated', '--limit-output') -TimeoutSeconds 180 -MaximumCaptureLength 262144
    $evidence.Add((New-AuditEvidence -EvidenceId 'chocolatey.outdated' -Type command -Source 'choco outdated --limit-output' -ExitCode $outdated.ExitCode -Captured $outdated.Captured -Redacted:$outdated.Redacted -Attributes @{
        status    = $outdated.Status
        truncated = $outdated.Truncated
        timedOut  = $outdated.TimedOut
    }))

    # With enhanced exit codes, 2 means "outdated packages found".
    $outdatedOk = $outdated.Status -eq 'success' -or ($outdated.Status -eq 'non-zero' -and $outdated.ExitCode -eq 2)
    $upgrades = @(
        if ($outdatedOk) {
            foreach ($row in ConvertFrom-ChocolateyLimitOutput -Text $outdated.Captured) {
                if ($row.Count -lt 3) { continue }
                [pscustomobject][ordered]@{
                    packageId        = $row[0]
                    installedVersion = $row[1]
                    availableVersion = $row[2]
                    pinned           = ($row.Count -ge 4 -and $row[3] -eq 'true')
                }
            }
        }
    )
    $evidence.Add((New-AuditEvidence -EvidenceId 'chocolatey.outdated.normalized' -Type derived -Source 'normalized choco outdated output' -Captured $null -Attributes @{
        status       = $(if ($outdatedOk) { 'known' } else { 'unavailable' })
        checkedAt    = $checkedAt
        upgradeCount = $upgrades.Count
        upgrades     = $upgrades
        reviewOnly   = $true
    }))
    if (-not $outdatedOk) {
        $componentState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'CHOCOLATEY_OUTDATED_QUERY_FAILED' -Message 'The Chocolatey outdated-package lookup did not complete successfully; no package changes were attempted.' -Severity warning -ComponentId 'chocolatey' -EvidenceIds @('chocolatey.outdated')))
    }

    $components.Add([pscustomobject][ordered]@{
        componentId         = 'chocolatey'
        name                = 'Chocolatey'
        state               = $componentState
        installed           = $true
        activeVersion       = $activeVersion
        discoveredVersions  = @(if ($null -ne $activeVersion) { $activeVersion })
        installations       = @(foreach ($resolution in @($versionResult.Resolutions)) {
                [pscustomobject][ordered]@{ path = [string]$resolution.path; version = $activeVersion; active = [bool]$resolution.active; source = 'command' }
            })
        commandResolutions  = @($versionResult.Resolutions)
        versionIntelligence = $notApplicable
    })
}

$status = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial

return [pscustomobject][ordered]@{
    providerId = 'chocolatey.baseline'
    category   = 'package-manager'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
