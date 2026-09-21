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
$components = New-Object System.Collections.Generic.List[object]
$hasPartial = $false
$unavailable = $false

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
    ) -TimeoutSeconds 30

    $sourceEvidenceId = 'winget.sources'
    $evidence.Add((New-AuditEvidence -EvidenceId $sourceEvidenceId -Type command -Source 'winget source list --disable-interactivity' -ExitCode $sourceResult.ExitCode -Captured $sourceResult.Captured -Redacted:$sourceResult.Redacted -Attributes @{
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

        if ($inventory.Status -ne 'success') {
            $componentState = 'partial'
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'WINGET_INVENTORY_QUERY_FAILED' -Message 'WinGet inventory diagnostics did not complete successfully without accepting source agreements.' -Severity warning -ComponentId 'winget' -EvidenceIds @($inventoryEvidenceId)))
        }
    }

    $components.Add([pscustomobject][ordered]@{
        componentId         = 'winget'
        name                = 'WinGet'
        state               = $componentState
        installed           = $true
        activeVersion       = $activeVersion
        discoveredVersions  = $(if ($activeVersion) { @($activeVersion) } else { @() })
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
