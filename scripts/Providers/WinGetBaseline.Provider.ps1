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
$wingetUpgradeCorePath = Join-Path $PSScriptRoot '..\Core\WinGetUpgradeIntelligence.Core.psm1'
Import-Module $corePath -Force
Import-Module $wingetUpgradeCorePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$components = New-Object System.Collections.Generic.List[object]
$hasPartial = $false
$unavailable = $false
$wingetCheckedAt = [string]$Context.ObservedAt

function New-NotApplicableVersionIntelligence {
    return [pscustomobject][ordered]@{
        status        = 'not-applicable'
        latestStable  = $null
        latestLts     = $null
        latestCurrent = $null
        source        = $null
        checkedAt     = $null
        message       = $null
    }
}

function Get-FirstOutputLine {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    return (($Text -split '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
}

function Get-NormalizedVersion {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $match = [regex]::Match($Value, '\d+(?:\.\d+){1,3}')
    if ($match.Success) {
        return $match.Value
    }

    return $null
}

$versionResult = Invoke-AuditCommand -Command 'winget' -Arguments @('--version') -TimeoutSeconds 15

if (-not $versionResult.Found) {
    $unavailable = $true

    $components.Add([pscustomobject][ordered]@{
        componentId         = 'winget'
        name                = 'WinGet'
        state               = 'missing'
        installed           = $false
        activeVersion       = $null
        discoveredVersions  = @()
        installations       = @()
        commandResolutions  = @()
        versionIntelligence = New-NotApplicableVersionIntelligence
    })

    $warnings.Add((New-AuditIssue -Code 'WINGET_NOT_FOUND' -Message 'WinGet is unavailable; package-manager diagnostics were not collected.' -Severity warning -ComponentId 'winget'))
}
else {
    $versionEvidenceId = 'winget.version'
    $evidence.Add((New-AuditEvidence -EvidenceId $versionEvidenceId -Type command -Source 'winget --version' -ExitCode $versionResult.ExitCode -Captured $versionResult.Captured -Redacted:$versionResult.Redacted -Attributes @{
        status    = $versionResult.Status
        truncated = $versionResult.Truncated
        timedOut  = $versionResult.TimedOut
    }))

    $rawVersion = Get-FirstOutputLine -Text $versionResult.Captured
    $activeVersion = $null
    if (-not [string]::IsNullOrWhiteSpace($rawVersion)) {
        $activeVersion = New-AuditVersionRecord -Raw $rawVersion -Normalized (Get-NormalizedVersion -Value $rawVersion) -Channel $null
    }

    $componentState = 'present'
    if ($versionResult.Status -ne 'success' -or $null -eq $activeVersion) {
        $componentState = 'partial'
        $hasPartial = $true

        $warningCode = if ($versionResult.Status -eq 'timed-out') {
            'WINGET_VERSION_TIMEOUT'
        }
        elseif ($versionResult.Status -eq 'non-zero') {
            'WINGET_VERSION_NONZERO'
        }
        elseif ($versionResult.Status -eq 'failed') {
            'WINGET_VERSION_FAILED'
        }
        else {
            'WINGET_VERSION_UNKNOWN'
        }

        $warnings.Add((New-AuditIssue -Code $warningCode -Message 'WinGet version detection was incomplete.' -Severity warning -ComponentId 'winget' -EvidenceIds @($versionEvidenceId)))
    }

    $installations = New-Object System.Collections.Generic.List[object]
    foreach ($resolution in @($versionResult.Resolutions)) {
        $installations.Add([pscustomobject][ordered]@{
            path    = [string]$resolution.path
            version = $(if ($resolution.active) { $activeVersion } else { $resolution.version })
            active  = [bool]$resolution.active
            source  = 'command'
        })
    }

    $sourceResult = Invoke-AuditCommand -Command 'winget' -Arguments @(
        'source',
        'list',
        '--disable-interactivity'
    ) -TimeoutSeconds 30 -SensitiveOutput

    $sourceEvidenceId = 'winget.sources'
    $evidence.Add((New-AuditEvidence -EvidenceId $sourceEvidenceId -Type command -Source 'winget source list --disable-interactivity' -ExitCode $sourceResult.ExitCode -Captured $sourceResult.Captured -Sensitive -Attributes @{
        status    = $sourceResult.Status
        truncated = $sourceResult.Truncated
        timedOut  = $sourceResult.TimedOut
    }))

    if ($sourceResult.Status -ne 'success') {
        $componentState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'WINGET_SOURCE_QUERY_FAILED' -Message 'WinGet source diagnostics did not complete successfully.' -Severity warning -ComponentId 'winget' -EvidenceIds @($sourceEvidenceId)))
    }

    if ($Context.IncludeWingetInventory) {
        $inventory = Invoke-AuditCommand -Command 'winget' -Arguments @(
            'list',
            '--disable-interactivity'
        ) -TimeoutSeconds 90

        $inventoryEvidenceId = 'winget.inventory'
        $evidence.Add((New-AuditEvidence -EvidenceId $inventoryEvidenceId -Type command -Source 'winget list --disable-interactivity' -ExitCode $inventory.ExitCode -Captured $inventory.Captured -Redacted:$inventory.Redacted -Attributes @{
            status    = $inventory.Status
            truncated = $inventory.Truncated
            timedOut  = $inventory.TimedOut
        }))

        $inventoryTable = ConvertFrom-WinGetTable -Text $inventory.Captured
        $inventoryRecords = if ($inventory.Status -eq 'success') {
            @(ConvertTo-WinGetPackageRecords -Table $inventoryTable -Mode inventory -CheckedAt $wingetCheckedAt)
        }
        else {
            @()
        }

        $inventoryState = if ($inventory.Status -ne 'success') {
            'unavailable'
        }
        elseif ($inventoryTable.tableFound) {
            'known'
        }
        else {
            'unknown'
        }

        $evidence.Add((New-AuditEvidence -EvidenceId 'winget.inventory.normalized' -Type derived -Source 'normalized winget list output' -Captured $null -Attributes @{
            status       = $inventoryState
            checkedAt    = $wingetCheckedAt
            packageCount = $inventoryRecords.Count
            packages     = $inventoryRecords
        }))

        if ($inventory.Status -ne 'success') {
            $componentState = 'partial'
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'WINGET_INVENTORY_QUERY_FAILED' -Message 'WinGet inventory diagnostics did not complete successfully without accepting source agreements.' -Severity warning -ComponentId 'winget' -EvidenceIds @($inventoryEvidenceId, 'winget.inventory.normalized')))
        }
        elseif (-not $inventoryTable.tableFound) {
            $componentState = 'partial'
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'WINGET_INVENTORY_PARSE_UNKNOWN' -Message 'WinGet inventory completed, but its table output could not be normalized reliably.' -Severity warning -ComponentId 'winget' -EvidenceIds @($inventoryEvidenceId, 'winget.inventory.normalized')))
        }

        $upgrade = Invoke-AuditCommand -Command 'winget' -Arguments @(
            'upgrade',
            '--disable-interactivity'
        ) -TimeoutSeconds 90

        $upgradeEvidenceId = 'winget.upgrades'
        $evidence.Add((New-AuditEvidence -EvidenceId $upgradeEvidenceId -Type command -Source 'winget upgrade --disable-interactivity' -ExitCode $upgrade.ExitCode -Captured $upgrade.Captured -Redacted:$upgrade.Redacted -Attributes @{
            status    = $upgrade.Status
            truncated = $upgrade.Truncated
            timedOut  = $upgrade.TimedOut
        }))

        $upgradeTable = ConvertFrom-WinGetTable -Text $upgrade.Captured
        $upgradeRecords = @(ConvertTo-WinGetPackageRecords -Table $upgradeTable -Mode upgrade -CheckedAt $wingetCheckedAt)
        $upgradeState = Get-WinGetUpgradeLookupState -CommandStatus $upgrade.Status -Output $upgrade.Captured -Table $upgradeTable -UpgradeRecords $upgradeRecords

        $evidence.Add((New-AuditEvidence -EvidenceId 'winget.upgrades.normalized' -Type derived -Source 'normalized winget upgrade output' -Captured $null -Attributes @{
            status       = $upgradeState
            checkedAt    = $wingetCheckedAt
            upgradeCount = $upgradeRecords.Count
            upgrades     = $upgradeRecords
            reviewOnly   = $true
        }))

        switch ($upgradeState) {
            'agreement-required' {
                $componentState = 'partial'
                $hasPartial = $true
                $warnings.Add((New-AuditIssue -Code 'WINGET_UPGRADE_AGREEMENT_REQUIRED' -Message 'WinGet upgrade lookup requires source agreement acceptance; the audit did not accept agreements automatically.' -Severity warning -ComponentId 'winget' -EvidenceIds @($upgradeEvidenceId, 'winget.upgrades.normalized')))
            }
            'source-unavailable' {
                $componentState = 'partial'
                $hasPartial = $true
                $warnings.Add((New-AuditIssue -Code 'WINGET_UPGRADE_SOURCE_UNAVAILABLE' -Message 'WinGet upgrade lookup could not use one or more package sources; local WinGet detection and inventory evidence were preserved.' -Severity warning -ComponentId 'winget' -EvidenceIds @($upgradeEvidenceId, 'winget.upgrades.normalized')))
            }
            'command-failed' {
                $componentState = 'partial'
                $hasPartial = $true
                $warnings.Add((New-AuditIssue -Code 'WINGET_UPGRADE_QUERY_FAILED' -Message 'WinGet upgrade lookup did not complete successfully; no package changes were attempted.' -Severity warning -ComponentId 'winget' -EvidenceIds @($upgradeEvidenceId, 'winget.upgrades.normalized')))
            }
            'unknown' {
                $componentState = 'partial'
                $hasPartial = $true
                $warnings.Add((New-AuditIssue -Code 'WINGET_UPGRADE_STATE_UNKNOWN' -Message 'WinGet upgrade lookup completed, but its output could not be classified reliably.' -Severity warning -ComponentId 'winget' -EvidenceIds @($upgradeEvidenceId, 'winget.upgrades.normalized')))
            }
        }
    }

    $components.Add([pscustomobject][ordered]@{
        componentId         = 'winget'
        name                = 'WinGet'
        state               = $componentState
        installed           = $true
        activeVersion       = $activeVersion
        discoveredVersions  = @(if ($null -ne $activeVersion) { $activeVersion })
        installations       = $installations.ToArray()
        commandResolutions  = @($versionResult.Resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    })
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
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
