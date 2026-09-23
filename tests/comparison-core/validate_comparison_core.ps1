[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Comparison.Core.psm1'

Import-Module $corePath -Force

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-SyntheticComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][ValidateSet('present', 'missing', 'partial', 'unavailable', 'not-applicable', 'unknown')][string]$State
    )

    $installed = switch ($State) {
        'present' { $true }
        'missing' { $false }
        default { $null }
    }

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = "Synthetic $ComponentId"
        state               = $State
        installed           = $installed
        activeVersion       = $null
        discoveredVersions  = @()
        installations       = @()
        commandResolutions  = @()
        versionIntelligence = [pscustomobject][ordered]@{
            status        = 'not-applicable'
            latestStable  = $null
            latestLts     = $null
            latestCurrent = $null
            source        = $null
            checkedAt     = $null
            message       = $null
        }
    }
}

function New-SyntheticProvider {
    param(
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][ValidateSet('success', 'warning', 'partial', 'failed', 'unavailable', 'not-applicable')][string]$Status,
        [object[]]$Components = @()
    )

    return [pscustomobject][ordered]@{
        providerId = $ProviderId
        category   = 'synthetic'
        status     = $Status
        observedAt = '2026-09-23T20:00:00+00:00'
        components = @($Components)
        warnings   = @()
        errors     = @()
        evidence   = @()
    }
}

function New-SyntheticReport {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$SchemaVersion = '1.0.0',
        [object[]]$Providers = @()
    )

    $providersArray = @($Providers)

    return [pscustomobject][ordered]@{
        schemaVersion = $SchemaVersion
        generatedAt   = '2026-09-23T20:00:00+00:00'
        audit         = [pscustomobject][ordered]@{
            mode        = 'read-only'
            toolVersion = '0.7.0'
        }
        host          = [pscustomobject][ordered]@{
            name         = $Name
            platform     = 'windows'
            architecture = 'x64'
        }
        summary       = [pscustomobject][ordered]@{
            status             = 'success'
            providerCount      = $providersArray.Count
            successCount       = @($providersArray | Where-Object status -eq 'success').Count
            warningCount       = @($providersArray | Where-Object status -eq 'warning').Count
            partialCount       = @($providersArray | Where-Object status -eq 'partial').Count
            failedCount        = @($providersArray | Where-Object status -eq 'failed').Count
            unavailableCount   = @($providersArray | Where-Object status -eq 'unavailable').Count
            notApplicableCount = @($providersArray | Where-Object status -eq 'not-applicable').Count
        }
        providers     = $providersArray
        warnings      = @()
        errors        = @()
    }
}

$equalProvider = New-SyntheticProvider -ProviderId 'runtime.synthetic' -Status success -Components @(
    (New-SyntheticComponent -ComponentId 'synthetic-runtime' -State present)
)

$equalReference = New-SyntheticReport -Name 'SYNTHETIC-REFERENCE' -Providers @($equalProvider)
$equalTarget = New-SyntheticReport -Name 'SYNTHETIC-TARGET' -Providers @($equalProvider)

$equalComparison = New-WorkstationComparison -ReferenceReport $equalReference -TargetReport $equalTarget

Assert-True ($equalComparison.schemaVersion -eq '1.0.0') 'Expected comparison schema 1.0.0.'
Assert-True ($equalComparison.auditSchemaMajor -eq 1) 'Expected supported audit schema major 1.'
Assert-True ($equalComparison.direction -eq 'reference-to-target') 'Expected explicit reference-to-target direction.'
Assert-True ($equalComparison.reference.host.name -eq 'SYNTHETIC-REFERENCE') 'Expected reference identity.'
Assert-True ($equalComparison.target.host.name -eq 'SYNTHETIC-TARGET') 'Expected target identity.'
Assert-True ($equalComparison.summary.status -eq 'equal') 'Equivalent normalized reports should compare equal.'
Assert-True ($equalComparison.summary.differenceCount -eq 0) 'Equivalent reports should emit no difference records.'

$referenceProvider = New-SyntheticProvider -ProviderId 'runtime.synthetic' -Status success -Components @(
    (New-SyntheticComponent -ComponentId 'alpha' -State present),
    (New-SyntheticComponent -ComponentId 'reference-only' -State missing),
    (New-SyntheticComponent -ComponentId 'unknown-state' -State present),
    (New-SyntheticComponent -ComponentId 'unavailable-state' -State present),
    (New-SyntheticComponent -ComponentId 'not-applicable-state' -State present)
)

$targetProvider = New-SyntheticProvider -ProviderId 'runtime.synthetic' -Status partial -Components @(
    (New-SyntheticComponent -ComponentId 'alpha' -State present),
    (New-SyntheticComponent -ComponentId 'unknown-state' -State unknown),
    (New-SyntheticComponent -ComponentId 'unavailable-state' -State unavailable),
    (New-SyntheticComponent -ComponentId 'not-applicable-state' -State not-applicable),
    (New-SyntheticComponent -ComponentId 'target-only' -State present)
)

$referenceOnlyProvider = New-SyntheticProvider -ProviderId 'environment.reference-only' -Status unavailable
$targetOnlyProvider = New-SyntheticProvider -ProviderId 'application.target-only' -Status success

$referenceReport = New-SyntheticReport -Name 'SYNTHETIC-REFERENCE' -Providers @(
    $referenceProvider,
    $referenceOnlyProvider
)

$targetReport = New-SyntheticReport -Name 'SYNTHETIC-TARGET' -Providers @(
    $targetProvider,
    $targetOnlyProvider
)

$comparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport

Assert-True ($comparison.summary.status -eq 'different') 'Known drift should produce different status.'
Assert-True ($comparison.summary.providerDifferenceCount -eq 3) 'Expected three provider-level differences.'
Assert-True ($comparison.summary.componentDifferenceCount -eq 5) 'Expected five component-level differences.'
Assert-True ($comparison.summary.differenceCount -eq 8) 'Expected eight total differences.'

$providerStatus = @(
    $comparison.differences |
        Where-Object {
            $_.category -eq 'provider' -and
            $_.providerId -eq 'runtime.synthetic' -and
            $_.kind -eq 'status'
        }
)
Assert-True ($providerStatus.Count -eq 1) 'Expected normalized provider status difference.'
Assert-True ($providerStatus[0].referenceState -eq 'success') 'Expected reference provider status preservation.'
Assert-True ($providerStatus[0].targetState -eq 'partial') 'Expected target provider status preservation.'
Assert-True ($providerStatus[0].relation -eq 'different') 'Expected provider status relation different.'

$referenceOnly = @(
    $comparison.differences |
        Where-Object providerId -eq 'environment.reference-only'
)
Assert-True ($referenceOnly.Count -eq 1) 'Expected reference-only provider difference.'
Assert-True ($referenceOnly[0].relation -eq 'reference-only') 'Expected reference-only relation.'
Assert-True ($referenceOnly[0].referenceState -eq 'unavailable') 'Reference-only provider must preserve unavailable state.'
Assert-True ($null -eq $referenceOnly[0].targetState) 'Absent target provider must preserve null target state.'

$targetOnly = @(
    $comparison.differences |
        Where-Object providerId -eq 'application.target-only'
)
Assert-True ($targetOnly.Count -eq 1) 'Expected target-only provider difference.'
Assert-True ($targetOnly[0].relation -eq 'target-only') 'Expected target-only relation.'

$missingComponent = @(
    $comparison.differences |
        Where-Object componentId -eq 'reference-only'
)
Assert-True ($missingComponent.Count -eq 1) 'Expected reference-only component difference.'
Assert-True ($missingComponent[0].relation -eq 'reference-only') 'Expected reference-only component relation.'
Assert-True ($missingComponent[0].referenceState -eq 'missing') 'Missing state must remain explicit.'

$unknownComponent = @(
    $comparison.differences |
        Where-Object componentId -eq 'unknown-state'
)
Assert-True ($unknownComponent.Count -eq 1) 'Expected unknown-state component difference.'
Assert-True ($unknownComponent[0].relation -eq 'unknown') 'Unknown state must remain semantically distinct.'
Assert-True ($unknownComponent[0].referenceState -eq 'present') 'Unknown comparison must preserve reference state.'
Assert-True ($unknownComponent[0].targetState -eq 'unknown') 'Unknown comparison must preserve target state.'

$unavailableComponent = @(
    $comparison.differences |
        Where-Object componentId -eq 'unavailable-state'
)
Assert-True ($unavailableComponent.Count -eq 1) 'Expected unavailable-state component difference.'
Assert-True ($unavailableComponent[0].relation -eq 'unavailable') 'Unavailable state must remain semantically distinct.'

$notApplicableComponent = @(
    $comparison.differences |
        Where-Object componentId -eq 'not-applicable-state'
)
Assert-True ($notApplicableComponent.Count -eq 1) 'Expected not-applicable component difference.'
Assert-True ($notApplicableComponent[0].relation -eq 'not-applicable') 'Not-applicable state must remain semantically distinct.'

Assert-True ($comparison.summary.unavailableCount -eq 1) 'Expected one unavailable relation.'
Assert-True ($comparison.summary.unknownCount -eq 1) 'Expected one unknown relation.'
Assert-True ($comparison.summary.notApplicableCount -eq 1) 'Expected one not-applicable relation.'

$firstJson = $comparison | ConvertTo-Json -Depth 20 -Compress
$secondJson = (New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport) | ConvertTo-Json -Depth 20 -Compress
Assert-True ($firstJson -eq $secondJson) 'Comparison output ordering must be deterministic.'

$unsupportedRejected = $false
try {
    $unsupported = New-SyntheticReport -Name 'SYNTHETIC-UNSUPPORTED' -SchemaVersion '2.0.0' -Providers @($equalProvider)
    New-WorkstationComparison -ReferenceReport $unsupported -TargetReport $equalTarget | Out-Null
}
catch {
    $unsupportedRejected = ($_.Exception.Message -match 'unsupported audit schema major 2')
}
Assert-True $unsupportedRejected 'Unsupported audit schema major must be rejected explicitly.'

$malformedRejected = $false
try {
    $malformed = New-SyntheticReport -Name 'SYNTHETIC-MALFORMED' -SchemaVersion 'not-semver' -Providers @($equalProvider)
    New-WorkstationComparison -ReferenceReport $malformed -TargetReport $equalTarget | Out-Null
}
catch {
    $malformedRejected = ($_.Exception.Message -match 'must be a semantic version')
}
Assert-True $malformedRejected 'Malformed audit schemaVersion must be rejected.'

$duplicateProviderRejected = $false
try {
    $duplicateProviderReport = New-SyntheticReport -Name 'SYNTHETIC-DUPLICATE-PROVIDER' -Providers @(
        $equalProvider,
        $equalProvider
    )
    New-WorkstationComparison -ReferenceReport $duplicateProviderReport -TargetReport $equalTarget | Out-Null
}
catch {
    $duplicateProviderRejected = ($_.Exception.Message -match 'duplicate providerId')
}
Assert-True $duplicateProviderRejected 'Duplicate providerId must be rejected.'

$duplicateComponentRejected = $false
try {
    $duplicateComponentProvider = New-SyntheticProvider -ProviderId 'runtime.duplicate-components' -Status success -Components @(
        (New-SyntheticComponent -ComponentId 'duplicate' -State present),
        (New-SyntheticComponent -ComponentId 'duplicate' -State missing)
    )
    $duplicateComponentReport = New-SyntheticReport -Name 'SYNTHETIC-DUPLICATE-COMPONENT' -Providers @($duplicateComponentProvider)
    New-WorkstationComparison -ReferenceReport $duplicateComponentReport -TargetReport $duplicateComponentReport | Out-Null
}
catch {
    $duplicateComponentRejected = ($_.Exception.Message -match 'duplicate componentId')
}
Assert-True $duplicateComponentRejected 'Duplicate componentId must be rejected.'

$mutableModeRejected = $false
try {
    $mutableReport = New-SyntheticReport -Name 'SYNTHETIC-MUTABLE' -Providers @($equalProvider)
    $mutableReport.audit.mode = 'apply'
    New-WorkstationComparison -ReferenceReport $mutableReport -TargetReport $equalTarget | Out-Null
}
catch {
    $mutableModeRejected = ($_.Exception.Message -match 'audit.mode as read-only')
}
Assert-True $mutableModeRejected 'Comparison input must remain read-only.'

$coreSource = Get-Content -LiteralPath $corePath -Raw

foreach ($legacyMarker in @(
    '.Tools',
    'VersionOutput',
    '.PathHealth',
    '.Computer'
)) {
    if ($coreSource -match [Regex]::Escape($legacyMarker)) {
        throw "Comparison core must not depend on legacy report marker '$legacyMarker'."
    }
}

foreach ($requiredMarker in @(
    'SupportedAuditSchemaMajor',
    'providerId',
    'componentId',
    'reference-to-target',
    'reference-only',
    'target-only',
    'unavailable',
    'unknown',
    'not-applicable'
)) {
    if ($coreSource -notmatch [Regex]::Escape($requiredMarker)) {
        throw "Comparison core is missing required contract marker '$requiredMarker'."
    }
}

foreach ($forbiddenMutation in @(
    'winget install',
    'winget upgrade',
    'winget uninstall',
    'npm install',
    'pnpm add',
    'flutter upgrade',
    'rustup update',
    'git checkout',
    'git reset',
    'git clean',
    'SetEnvironmentVariable'
)) {
    if ($coreSource -match [Regex]::Escape($forbiddenMutation)) {
        throw "Comparison core contains prohibited mutation marker '$forbiddenMutation'."
    }
}

Write-Host 'Normalized comparison core validation passed.'
