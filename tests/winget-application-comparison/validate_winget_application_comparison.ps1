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

function New-SyntheticVersion {
    return [pscustomobject][ordered]@{
        raw        = 'v1.0.0'
        normalized = '1.0.0'
        channel    = 'stable'
    }
}

function New-SyntheticVersionIntelligence {
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

function New-SyntheticComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][ValidateSet('present','missing','partial','unavailable','not-applicable','unknown')][string]$State
    )

    $installed = if ($State -eq 'present') {
        $true
    }
    elseif ($State -eq 'missing') {
        $false
    }
    else {
        $null
    }

    $activeVersion = if ($ComponentId -eq 'winget' -and $State -ne 'unavailable') {
        New-SyntheticVersion
    }
    else {
        $null
    }

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = "Synthetic $ComponentId"
        state               = $State
        installed           = $installed
        activeVersion       = $activeVersion
        discoveredVersions  = @()
        installations       = @()
        commandResolutions  = @()
        versionIntelligence = New-SyntheticVersionIntelligence
    }
}

function New-SyntheticPackage {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$InstalledVersion,
        [AllowNull()][string]$AvailableVersion = $null,
        [bool]$IdentityReliable = $true,
        [bool]$InstalledVersionReliable = $true,
        [AllowNull()][object]$AvailableVersionReliable = $null,
        [string]$CheckedAt = '2026-09-24T12:00:00+00:00'
    )

    return [pscustomobject][ordered]@{
        name                     = "Display $PackageId"
        packageId                = $PackageId
        identityReliable         = $IdentityReliable
        installedVersion         = $InstalledVersion
        installedVersionReliable = $InstalledVersionReliable
        availableVersion         = $AvailableVersion
        availableVersionReliable = $AvailableVersionReliable
        source                   = 'winget'
        checkedAt                = $CheckedAt
    }
}

function New-SyntheticEvidence {
    param(
        [Parameter(Mandatory)][ValidateSet('inventory','upgrade')][string]$Mode,
        [Parameter(Mandatory)][string]$State,
        [object[]]$Records = @(),
        [string]$CheckedAt = '2026-09-24T12:00:00+00:00'
    )

    if ($Mode -eq 'inventory') {
        return [pscustomobject][ordered]@{
            evidenceId = 'winget.inventory.normalized'
            type       = 'derived'
            source     = 'normalized synthetic inventory'
            exitCode   = $null
            captured   = $null
            redacted   = $false
            attributes = [pscustomobject][ordered]@{
                status       = $State
                checkedAt    = $CheckedAt
                packageCount = @($Records).Count
                packages     = @($Records)
            }
        }
    }

    return [pscustomobject][ordered]@{
        evidenceId = 'winget.upgrades.normalized'
        type       = 'derived'
        source     = 'normalized synthetic upgrades'
        exitCode   = $null
        captured   = $null
        redacted   = $false
        attributes = [pscustomobject][ordered]@{
            status       = $State
            checkedAt    = $CheckedAt
            upgradeCount = @($Records).Count
            upgrades     = @($Records)
            reviewOnly   = $true
        }
    }
}

function New-RawCommandEvidence {
    param([string]$Captured)

    return [pscustomobject][ordered]@{
        evidenceId = 'winget.inventory.raw.synthetic'
        type       = 'command'
        source     = 'synthetic raw output that must not be compared'
        exitCode   = 0
        captured   = $Captured
        redacted   = $false
        attributes = [pscustomobject][ordered]@{
            status = 'success'
        }
    }
}

function New-WinGetProvider {
    param(
        [ValidateSet('success','partial','failed','unavailable','not-applicable')][string]$Status = 'success',
        [AllowNull()][object]$InventoryEvidence = $null,
        [AllowNull()][object]$UpgradeEvidence = $null,
        [string]$RawCaptured = 'raw-a'
    )

    $evidence = @()
    if ($null -ne $InventoryEvidence) {
        $evidence += $InventoryEvidence
    }
    if ($null -ne $UpgradeEvidence) {
        $evidence += $UpgradeEvidence
    }
    if ($Status -notin @('unavailable','not-applicable')) {
        $evidence += New-RawCommandEvidence -Captured $RawCaptured
    }

    $components = if ($Status -eq 'unavailable') {
        @()
    }
    else {
        @((New-SyntheticComponent -ComponentId winget -State present))
    }

    return [pscustomobject][ordered]@{
        providerId = 'winget.baseline'
        category   = 'package-manager'
        status     = $Status
        observedAt = '2026-09-24T12:00:00+00:00'
        components = $components
        warnings   = @()
        errors     = @()
        evidence   = @($evidence)
    }
}

function New-RuntimeProvider {
    param([ValidateSet('present','missing')][string]$State)

    return [pscustomobject][ordered]@{
        providerId = 'runtime.synthetic'
        category   = 'synthetic'
        status     = 'success'
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @((New-SyntheticComponent -ComponentId tool-a -State $State))
        warnings   = @()
        errors     = @()
        evidence   = @()
    }
}

function New-SyntheticReport {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Providers
    )

    return [pscustomobject][ordered]@{
        schemaVersion = '1.0.0'
        generatedAt   = '2026-09-24T12:00:00+00:00'
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
            providerCount      = @($Providers).Count
            successCount       = @($Providers | Where-Object status -eq 'success').Count
            warningCount       = 0
            partialCount       = @($Providers | Where-Object status -eq 'partial').Count
            failedCount        = @($Providers | Where-Object status -eq 'failed').Count
            unavailableCount   = @($Providers | Where-Object status -eq 'unavailable').Count
            notApplicableCount = @($Providers | Where-Object status -eq 'not-applicable').Count
        }
        providers     = @($Providers)
        warnings      = @()
        errors        = @()
    }
}

$referenceInventory = New-SyntheticEvidence -Mode inventory -State known -CheckedAt '2026-09-24T12:00:00+00:00' -Records @(
    (New-SyntheticPackage -PackageId 'Git.Git' -InstalledVersion '2.53.0'),
    (New-SyntheticPackage -PackageId 'OpenJS.NodeJS.LTS' -InstalledVersion '20.19.0'),
    (New-SyntheticPackage -PackageId 'Synthetic.ReferenceOnly' -InstalledVersion '1.0.0'),
    (New-SyntheticPackage -PackageId 'Truncated…' -InstalledVersion '9.0.0' -IdentityReliable $false)
)

$targetInventory = New-SyntheticEvidence -Mode inventory -State known -CheckedAt '2026-09-24T13:00:00+00:00' -Records @(
    (New-SyntheticPackage -PackageId 'git.git' -InstalledVersion '2.54.0' -CheckedAt '2026-09-24T13:00:00+00:00'),
    (New-SyntheticPackage -PackageId 'OpenJS.NodeJS.LTS' -InstalledVersion '20.19.0' -CheckedAt '2026-09-24T13:00:00+00:00'),
    (New-SyntheticPackage -PackageId 'Synthetic.TargetOnly' -InstalledVersion '1.0.0' -CheckedAt '2026-09-24T13:00:00+00:00'),
    (New-SyntheticPackage -PackageId 'Other…' -InstalledVersion '10.0.0' -IdentityReliable $false -CheckedAt '2026-09-24T13:00:00+00:00')
)

$referenceUpgrades = New-SyntheticEvidence -Mode upgrade -State upgrades-available -CheckedAt '2026-09-24T12:00:00+00:00' -Records @(
    (New-SyntheticPackage -PackageId 'Git.Git' -InstalledVersion '2.53.0' -AvailableVersion '2.54.0' -AvailableVersionReliable $true),
    (New-SyntheticPackage -PackageId 'Synthetic.ReferenceOnly' -InstalledVersion '1.0.0' -AvailableVersion '2.0.0' -AvailableVersionReliable $true)
)

$targetUpgrades = New-SyntheticEvidence -Mode upgrade -State upgrades-available -CheckedAt '2026-09-24T13:00:00+00:00' -Records @(
    (New-SyntheticPackage -PackageId 'git.git' -InstalledVersion '2.54.0' -AvailableVersion '2.55.0' -AvailableVersionReliable $true -CheckedAt '2026-09-24T13:00:00+00:00'),
    (New-SyntheticPackage -PackageId 'Synthetic.TargetOnly' -InstalledVersion '1.0.0' -AvailableVersion '3.0.0' -AvailableVersionReliable $true -CheckedAt '2026-09-24T13:00:00+00:00')
)

$referenceProvider = New-WinGetProvider -InventoryEvidence $referenceInventory -UpgradeEvidence $referenceUpgrades -RawCaptured 'reference formatted table'
$targetProvider = New-WinGetProvider -InventoryEvidence $targetInventory -UpgradeEvidence $targetUpgrades -RawCaptured 'completely different target table formatting'
$referenceReport = New-SyntheticReport -Name reference -Providers @($referenceProvider)
$targetReport = New-SyntheticReport -Name target -Providers @($targetProvider)

$comparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport
$applicationDifferences = @($comparison.differences | Where-Object category -eq 'application')

Assert-True ($applicationDifferences.Count -eq 6) 'Primary WinGet comparison must emit exactly six application differences.'
Assert-True (@($applicationDifferences | Where-Object kind -eq 'presence').Count -eq 2) 'Reference-only and target-only installed applications must be distinguishable.'
Assert-True (@($applicationDifferences | Where-Object kind -eq 'installed-version').Count -eq 1) 'Reliable installed-version drift must be compared independently.'
Assert-True (@($applicationDifferences | Where-Object kind -eq 'upgrade-availability').Count -eq 2) 'Upgrade package-set drift must remain separate from installed presence.'
Assert-True (@($applicationDifferences | Where-Object kind -eq 'available-version').Count -eq 1) 'Reliable available-version drift must be compared independently.'
Assert-True (-not ($applicationDifferences | Where-Object subjectId -match 'truncated|other')) 'Unreliable package identities must not be used to claim application drift.'

$gitVersion = $applicationDifferences | Where-Object { $_.kind -eq 'installed-version' -and $_.subjectId -eq 'winget-package:git.git' }
Assert-True ($null -ne $gitVersion) 'WinGet package IDs must compare case-insensitively.'
Assert-True ($gitVersion.referenceValue -eq '2.53.0' -and $gitVersion.targetValue -eq '2.54.0') 'Installed-version difference must preserve normalized package versions.'

$firstJson = $comparison | ConvertTo-Json -Depth 30 -Compress
$secondJson = (New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport) | ConvertTo-Json -Depth 30 -Compress
Assert-True ($firstJson -eq $secondJson) 'WinGet/application comparison output must remain deterministic.'

$currentTarget = New-SyntheticEvidence -Mode upgrade -State current -Records @() -CheckedAt '2026-09-24T14:00:00+00:00'
$currentTargetProvider = New-WinGetProvider -InventoryEvidence $referenceInventory -UpgradeEvidence $currentTarget -RawCaptured 'irrelevant raw current output'
$currentTargetReport = New-SyntheticReport -Name current-target -Providers @($currentTargetProvider)
$currentComparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $currentTargetReport

$currentApplication = @($currentComparison.differences | Where-Object category -eq 'application')
Assert-True (@($currentApplication | Where-Object kind -eq 'upgrade-status').Count -eq 1) 'Current versus upgrades-available must preserve an explicit upgrade-status difference.'
Assert-True (@($currentApplication | Where-Object kind -eq 'upgrade-availability').Count -eq 2) 'Current state must compare as an empty reliable upgrade set.'

foreach ($state in @('source-unavailable','agreement-required','command-failed')) {
    $stateEvidence = New-SyntheticEvidence -Mode upgrade -State $state -Records @()
    $stateProvider = New-WinGetProvider -Status partial -InventoryEvidence $referenceInventory -UpgradeEvidence $stateEvidence
    $stateReport = New-SyntheticReport -Name $state -Providers @($stateProvider)
    $stateComparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $stateReport
    $statusDifference = @($stateComparison.differences | Where-Object { $_.category -eq 'application' -and $_.kind -eq 'upgrade-status' })[0]

    Assert-True ($null -ne $statusDifference) "Expected upgrade-status difference for $state."
    Assert-True ($statusDifference.targetState -eq $state) "Upgrade state '$state' must remain explicit."
    Assert-True ($statusDifference.relation -eq 'unavailable') "Upgrade state '$state' must preserve unavailable comparison semantics."
    Assert-True (@($stateComparison.differences | Where-Object { $_.category -eq 'application' -and $_.kind -eq 'upgrade-availability' }).Count -eq 0) "Unreliable upgrade state '$state' must not fabricate package-level upgrade drift."
}

$unavailableInventory = New-SyntheticEvidence -Mode inventory -State unavailable -Records @()
$inventoryUnavailableProvider = New-WinGetProvider -Status partial -InventoryEvidence $unavailableInventory -UpgradeEvidence $targetUpgrades
$inventoryUnavailableReport = New-SyntheticReport -Name inventory-unavailable -Providers @($inventoryUnavailableProvider)
$inventoryStateComparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $inventoryUnavailableReport
$inventoryStatus = @($inventoryStateComparison.differences | Where-Object { $_.category -eq 'application' -and $_.kind -eq 'inventory-status' })[0]
Assert-True ($inventoryStatus.relation -eq 'unavailable') 'Unavailable inventory must remain explicit instead of fabricating missing applications.'
Assert-True (@($inventoryStateComparison.differences | Where-Object { $_.category -eq 'application' -and $_.kind -eq 'presence' }).Count -eq 0) 'Unavailable inventory must not fabricate installed application presence drift.'

$unavailableReference = New-SyntheticReport -Name unavailable-reference -Providers @(
    (New-WinGetProvider -InventoryEvidence $referenceInventory -UpgradeEvidence $referenceUpgrades),
    (New-RuntimeProvider -State present)
)
$unavailableTarget = New-SyntheticReport -Name unavailable-target -Providers @(
    (New-WinGetProvider -Status unavailable),
    (New-RuntimeProvider -State missing)
)
$unavailableComparison = New-WorkstationComparison -ReferenceReport $unavailableReference -TargetReport $unavailableTarget

Assert-True (@($unavailableComparison.differences | Where-Object { $_.providerId -eq 'runtime.synthetic' -and $_.category -eq 'component' }).Count -eq 1) 'Unavailable WinGet must not prevent unrelated comparison categories from completing.'
Assert-True (@($unavailableComparison.differences | Where-Object category -eq 'application').Count -eq 0) 'Unavailable WinGet provider must not fabricate application-level drift from absent normalized evidence.'

$coreSource = Get-Content -LiteralPath $corePath -Raw
foreach ($required in @(
    'winget.inventory.normalized',
    'winget.upgrades.normalized',
    'identityReliable',
    'installedVersionReliable',
    'availableVersionReliable'
)) {
    Assert-True ($coreSource -match [Regex]::Escape($required)) "Missing normalized WinGet comparison marker: $required"
}

foreach ($forbidden in @(
    'winget list --disable-interactivity',
    'winget upgrade --disable-interactivity',
    '--accept-source-agreements',
    '--accept-package-agreements',
    'Invoke-AuditCommand'
)) {
    Assert-True ($coreSource -notmatch [Regex]::Escape($forbidden)) "Comparison core must not execute or authorize WinGet mutation/discovery marker: $forbidden"
}

Write-Host 'WinGet/application comparison validation passed.'
