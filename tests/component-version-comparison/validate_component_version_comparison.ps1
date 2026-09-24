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
    param(
        [Parameter(Mandatory)][string]$Raw,
        [AllowNull()][string]$Normalized,
        [AllowNull()][string]$Channel
    )

    return [pscustomobject][ordered]@{
        raw        = $Raw
        normalized = $Normalized
        channel    = $Channel
    }
}

function New-SyntheticVersionIntelligence {
    param(
        [Parameter(Mandatory)][ValidateSet('known', 'unknown', 'unavailable', 'not-applicable')][string]$Status,
        [AllowNull()][object]$LatestStable,
        [AllowNull()][object]$LatestLts,
        [AllowNull()][object]$LatestCurrent
    )

    if ($Status -eq 'not-applicable') {
        return [pscustomobject][ordered]@{
            status        = $Status
            latestStable  = $null
            latestLts     = $null
            latestCurrent = $null
            source        = $null
            checkedAt     = $null
            message       = $null
        }
    }

    return [pscustomobject][ordered]@{
        status        = $Status
        latestStable  = $LatestStable
        latestLts     = $LatestLts
        latestCurrent = $LatestCurrent
        source        = 'synthetic-version-source'
        checkedAt     = '2026-09-24T12:00:00+00:00'
        message       = $(if ($Status -eq 'known') { $null } else { "Synthetic $Status state." })
    }
}

function New-SyntheticInstallation {
    param(
        [AllowNull()][string]$Path,
        [AllowNull()][object]$Version,
        [bool]$Active,
        [Parameter(Mandatory)][ValidateSet('command', 'registry', 'filesystem', 'environment', 'configuration', 'package-manager', 'unknown')][string]$Source
    )

    return [pscustomobject][ordered]@{
        path    = $Path
        version = $Version
        active  = $Active
        source  = $Source
    }
}

function New-SyntheticResolution {
    param(
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][string]$Path,
        [AllowNull()][string]$CommandType,
        [AllowNull()][object]$Version,
        [AllowNull()][Nullable[int]]$Precedence,
        [bool]$Active
    )

    return [pscustomobject][ordered]@{
        command     = $Command
        path        = $Path
        commandType = $CommandType
        version     = $Version
        precedence  = $Precedence
        active      = $Active
    }
}

function New-SyntheticComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][ValidateSet('present', 'missing', 'partial', 'unavailable', 'not-applicable', 'unknown')][string]$State,
        [AllowNull()][object]$ActiveVersion = $null,
        [object[]]$DiscoveredVersions = @(),
        [object[]]$Installations = @(),
        [object[]]$CommandResolutions = @(),
        [AllowNull()][object]$VersionIntelligence = $null
    )

    $installed = switch ($State) {
        'present' { $true }
        'missing' { $false }
        default { $null }
    }

    if ($null -eq $VersionIntelligence) {
        $VersionIntelligence = New-SyntheticVersionIntelligence -Status not-applicable
    }

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = "Synthetic $ComponentId"
        state               = $State
        installed           = $installed
        activeVersion       = $ActiveVersion
        discoveredVersions  = @($DiscoveredVersions)
        installations       = @($Installations)
        commandResolutions  = @($CommandResolutions)
        versionIntelligence = $VersionIntelligence
    }
}

function New-SyntheticProvider {
    param(
        [object[]]$Components
    )

    return [pscustomobject][ordered]@{
        providerId = 'runtime.synthetic'
        category   = 'synthetic'
        status     = 'success'
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @($Components)
        warnings   = @()
        errors     = @()
        evidence   = @()
    }
}

function New-SyntheticReport {
    param(
        [Parameter(Mandatory)][string]$Name,
        [object[]]$Components
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
            providerCount      = 1
            successCount       = 1
            warningCount       = 0
            partialCount       = 0
            failedCount        = 0
            unavailableCount   = 0
            notApplicableCount = 0
        }
        providers     = @(
            (New-SyntheticProvider -Components $Components)
        )
        warnings      = @()
        errors        = @()
    }
}

$v181 = New-SyntheticVersion -Raw 'v18.20.0' -Normalized '18.20.0' -Channel lts
$v201Reference = New-SyntheticVersion -Raw 'v20.1.0' -Normalized '20.1.0' -Channel lts
$v202Target = New-SyntheticVersion -Raw 'node-v20.2.0' -Normalized '20.2.0' -Channel lts
$v210Current = New-SyntheticVersion -Raw 'v21.0.0' -Normalized '21.0.0' -Channel current

$runtimeAReferenceParams = @{
    ComponentId = 'runtime-a'
    State = 'present'
    ActiveVersion = $v201Reference
    DiscoveredVersions = @($v181, $v201Reference)
    Installations = @(
        (New-SyntheticInstallation -Path 'C:\Synthetic\Node\v20' -Version $v201Reference -Active $true -Source filesystem),
        (New-SyntheticInstallation -Path 'C:\Synthetic\Node\v18' -Version $v181 -Active $false -Source filesystem)
    )
    CommandResolutions = @(
        (New-SyntheticResolution -Command 'node' -Path 'C:\Synthetic\Node\v20\node.exe' -CommandType Application -Version $v201Reference -Precedence 0 -Active $true)
    )
    VersionIntelligence = (New-SyntheticVersionIntelligence -Status known -LatestLts $v201Reference -LatestCurrent $v210Current)
}
$runtimeAReference = New-SyntheticComponent @runtimeAReferenceParams

$runtimeATargetParams = @{
    ComponentId = 'runtime-a'
    State = 'present'
    ActiveVersion = $v202Target
    DiscoveredVersions = @($v202Target, $v181)
    Installations = @(
        (New-SyntheticInstallation -Path 'C:\Synthetic\Node\v18' -Version $v181 -Active $false -Source filesystem),
        (New-SyntheticInstallation -Path 'C:\Synthetic\Node\v20' -Version $v202Target -Active $true -Source filesystem)
    )
    CommandResolutions = @(
        (New-SyntheticResolution -Command 'node' -Path 'C:\Synthetic\Node\v20\node.exe' -CommandType Application -Version $v202Target -Precedence 1 -Active $true)
    )
    VersionIntelligence = (New-SyntheticVersionIntelligence -Status known -LatestLts $v202Target -LatestCurrent $v210Current)
}
$runtimeATarget = New-SyntheticComponent @runtimeATargetParams

$normalizedSameReference = New-SyntheticVersion -Raw 'v1.2.3' -Normalized '1.2.3' -Channel stable
$normalizedSameTarget = New-SyntheticVersion -Raw 'vendor-build-1.2.3' -Normalized '1.2.3' -Channel stable

$runtimeBReference = New-SyntheticComponent -ComponentId 'runtime-b' -State present -ActiveVersion $normalizedSameReference
$runtimeBTarget = New-SyntheticComponent -ComponentId 'runtime-b' -State present -ActiveVersion $normalizedSameTarget

$rawOnlyReference = New-SyntheticVersion -Raw 'custom-2026.09-a' -Normalized $null -Channel preview
$rawOnlyTarget = New-SyntheticVersion -Raw 'custom-2026.09-b' -Normalized $null -Channel preview

$runtimeCReference = New-SyntheticComponent -ComponentId 'runtime-c' -State present -ActiveVersion $rawOnlyReference
$runtimeCTarget = New-SyntheticComponent -ComponentId 'runtime-c' -State present -ActiveVersion $rawOnlyTarget

$runtimeDReference = New-SyntheticComponent -ComponentId 'runtime-d' -State present -VersionIntelligence (New-SyntheticVersionIntelligence -Status unknown)
$runtimeDTarget = New-SyntheticComponent -ComponentId 'runtime-d' -State present -VersionIntelligence (New-SyntheticVersionIntelligence -Status unavailable)

$presentReference = New-SyntheticComponent -ComponentId 'state-drift' -State present
$missingTarget = New-SyntheticComponent -ComponentId 'state-drift' -State missing

$referenceExtra = New-SyntheticComponent -ComponentId 'reference-extra' -State present
$targetExtra = New-SyntheticComponent -ComponentId 'target-extra' -State present

$orderV1 = New-SyntheticVersion -Raw 'v3.0.0' -Normalized '3.0.0' -Channel stable
$orderV2 = New-SyntheticVersion -Raw 'v4.0.0' -Normalized '4.0.0' -Channel stable

$orderInstallation1 = New-SyntheticInstallation -Path 'C:\Synthetic\Order\v3' -Version $orderV1 -Active $false -Source filesystem
$orderInstallation2 = New-SyntheticInstallation -Path 'C:\Synthetic\Order\v4' -Version $orderV2 -Active $true -Source filesystem
$orderResolution1 = New-SyntheticResolution -Command 'order-demo' -Path 'C:\Synthetic\Order\v4\demo.exe' -CommandType Application -Version $orderV2 -Precedence 0 -Active $true
$orderResolution2 = New-SyntheticResolution -Command 'order-demo' -Path 'C:\Synthetic\Order\v3\demo.exe' -CommandType Application -Version $orderV1 -Precedence 1 -Active $false

$orderReferenceParams = @{
    ComponentId = 'order-insensitive'
    State = 'present'
    ActiveVersion = $orderV2
    DiscoveredVersions = @($orderV1, $orderV2)
    Installations = @($orderInstallation1, $orderInstallation2)
    CommandResolutions = @($orderResolution1, $orderResolution2)
}
$orderReference = New-SyntheticComponent @orderReferenceParams

$orderTargetParams = @{
    ComponentId = 'order-insensitive'
    State = 'present'
    ActiveVersion = $orderV2
    DiscoveredVersions = @($orderV2, $orderV1)
    Installations = @($orderInstallation2, $orderInstallation1)
    CommandResolutions = @($orderResolution2, $orderResolution1)
}
$orderTarget = New-SyntheticComponent @orderTargetParams

$referenceReport = New-SyntheticReport -Name 'SYNTHETIC-REFERENCE' -Components @(
    $runtimeAReference,
    $runtimeBReference,
    $runtimeCReference,
    $runtimeDReference,
    $presentReference,
    $referenceExtra,
    $orderReference
)

$targetReport = New-SyntheticReport -Name 'SYNTHETIC-TARGET' -Components @(
    $runtimeATarget,
    $runtimeBTarget,
    $runtimeCTarget,
    $runtimeDTarget,
    $missingTarget,
    $targetExtra,
    $orderTarget
)

$comparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport

Assert-True ($comparison.schemaVersion -eq '1.1.0') 'Expected comparison schema 1.1.0.'
Assert-True ($comparison.summary.status -eq 'different') 'Known component/version drift should produce different status.'
Assert-True ($comparison.summary.versionDifferenceCount -eq 6) "Expected six version differences, found $($comparison.summary.versionDifferenceCount)."
Assert-True ($comparison.summary.componentDifferenceCount -eq 7) "Expected seven component differences, found $($comparison.summary.componentDifferenceCount)."
Assert-True ($comparison.summary.differenceCount -eq 13) "Expected thirteen total differences, found $($comparison.summary.differenceCount)."

$active = @(
    $comparison.differences |
        Where-Object {
            $_.providerId -eq 'runtime.synthetic' -and
            $_.componentId -eq 'runtime-a' -and
            $_.category -eq 'version' -and
            $_.kind -eq 'active-version'
        }
)
Assert-True ($active.Count -eq 1) 'Expected one active-version difference for runtime-a.'
Assert-True ($active[0].referenceValue.value -eq '20.1.0') 'Active version must use normalized reference value.'
Assert-True ($active[0].targetValue.value -eq '20.2.0') 'Active version must use normalized target value.'
Assert-True ($active[0].referenceValue.valueSource -eq 'normalized') 'Active reference version must identify normalized source.'
Assert-True ($active[0].targetValue.valueSource -eq 'normalized') 'Active target version must identify normalized source.'
Assert-True ($active[0].referenceValue.channel -eq 'lts') 'Active reference channel must remain LTS.'
Assert-True ($active[0].targetValue.channel -eq 'lts') 'Active target channel must remain LTS.'
Assert-True ($null -eq $active[0].referenceValue.PSObject.Properties['raw']) 'Structured version output must not retain raw when normalized is available.'

$discovered = @(
    $comparison.differences |
        Where-Object {
            $_.componentId -eq 'runtime-a' -and
            $_.kind -eq 'discovered-version'
        }
)
Assert-True ($discovered.Count -eq 2) 'Expected reference-only and target-only discovered-version drift.'
Assert-True (@($discovered | Where-Object relation -eq 'reference-only').Count -eq 1) 'Expected one reference-only discovered version.'
Assert-True (@($discovered | Where-Object relation -eq 'target-only').Count -eq 1) 'Expected one target-only discovered version.'

$installations = @(
    $comparison.differences |
        Where-Object {
            $_.componentId -eq 'runtime-a' -and
            $_.kind -eq 'installation'
        }
)
Assert-True ($installations.Count -eq 2) 'Expected installation-set replacement to emit two deterministic membership differences.'
foreach ($difference in $installations) {
    Assert-True ($difference.subjectId -match '^installation:[0-9a-f]{64}$') 'Installation subject ID must be a deterministic hash.'
    $value = if ($null -ne $difference.referenceValue) { $difference.referenceValue } else { $difference.targetValue }
    Assert-True ($value.path -eq 'C:\Synthetic\Node\v20') 'Installation drift must preserve normalized installation path.'
    Assert-True ($value.version.valueSource -eq 'normalized') 'Installation version must prefer normalized version evidence.'
}

$resolutions = @(
    $comparison.differences |
        Where-Object {
            $_.componentId -eq 'runtime-a' -and
            $_.kind -eq 'command-resolution'
        }
)
Assert-True ($resolutions.Count -eq 2) 'Expected command-resolution replacement to emit two deterministic membership differences.'
foreach ($difference in $resolutions) {
    Assert-True ($difference.subjectId -match '^command-resolution:[0-9a-f]{64}$') 'Command resolution subject ID must be a deterministic hash.'
    $value = if ($null -ne $difference.referenceValue) { $difference.referenceValue } else { $difference.targetValue }
    Assert-True ($value.command -eq 'node') 'Command resolution must preserve normalized command identity.'
    Assert-True ($value.path -eq 'C:\Synthetic\Node\v20\node.exe') 'Command resolution must preserve normalized resolved path.'
    Assert-True ($value.precedence -in @(0, 1)) 'Command resolution must preserve precedence.'
}

$latestLts = @(
    $comparison.differences |
        Where-Object {
            $_.componentId -eq 'runtime-a' -and
            $_.category -eq 'version' -and
            $_.kind -eq 'latest-lts'
        }
)
Assert-True ($latestLts.Count -eq 1) 'Expected one LTS latest-version difference.'
Assert-True ($latestLts[0].referenceValue.channel -eq 'lts') 'Reference latest LTS channel must remain explicit.'
Assert-True ($latestLts[0].targetValue.channel -eq 'lts') 'Target latest LTS channel must remain explicit.'

$latestCurrent = @(
    $comparison.differences |
        Where-Object {
            $_.componentId -eq 'runtime-a' -and
            $_.kind -eq 'latest-current'
        }
)
Assert-True ($latestCurrent.Count -eq 0) 'Equal Current-channel intelligence must not produce drift.'

$runtimeBDifferences = @($comparison.differences | Where-Object componentId -eq 'runtime-b')
Assert-True ($runtimeBDifferences.Count -eq 0) 'Different raw text with the same normalized version must compare equal.'

$runtimeCActive = @(
    $comparison.differences |
        Where-Object {
            $_.componentId -eq 'runtime-c' -and
            $_.kind -eq 'active-version'
        }
)
Assert-True ($runtimeCActive.Count -eq 1) 'Raw-only versions must still compare when normalized is unavailable.'
Assert-True ($runtimeCActive[0].referenceValue.valueSource -eq 'raw') 'Raw fallback must be explicit rather than fabricated as normalized.'
Assert-True ($runtimeCActive[0].targetValue.valueSource -eq 'raw') 'Raw fallback must be explicit on target.'
Assert-True ($runtimeCActive[0].referenceValue.value -eq 'custom-2026.09-a') 'Expected raw-only reference value.'
Assert-True ($runtimeCActive[0].targetValue.value -eq 'custom-2026.09-b') 'Expected raw-only target value.'

$intelligenceStatus = @(
    $comparison.differences |
        Where-Object {
            $_.componentId -eq 'runtime-d' -and
            $_.kind -eq 'intelligence-status'
        }
)
Assert-True ($intelligenceStatus.Count -eq 1) 'Expected one version-intelligence status difference.'
Assert-True ($intelligenceStatus[0].referenceState -eq 'unknown') 'Unknown intelligence state must remain explicit.'
Assert-True ($intelligenceStatus[0].targetState -eq 'unavailable') 'Unavailable intelligence state must remain explicit.'
Assert-True ($intelligenceStatus[0].relation -eq 'unavailable') 'Unavailable intelligence must not collapse into missing/different.'

$stateDrift = @(
    $comparison.differences |
        Where-Object {
            $_.componentId -eq 'state-drift' -and
            $_.category -eq 'component' -and
            $_.kind -eq 'state'
        }
)
Assert-True ($stateDrift.Count -eq 1) 'Present/missing component state must be compared from normalized state.'
Assert-True ($stateDrift[0].referenceState -eq 'present') 'Expected present reference state.'
Assert-True ($stateDrift[0].targetState -eq 'missing') 'Expected missing target state.'

$referenceExtraDiff = @($comparison.differences | Where-Object componentId -eq 'reference-extra')
$targetExtraDiff = @($comparison.differences | Where-Object componentId -eq 'target-extra')
Assert-True ($referenceExtraDiff.Count -eq 1 -and $referenceExtraDiff[0].relation -eq 'reference-only') 'Reference-only component must remain explicit.'
Assert-True ($targetExtraDiff.Count -eq 1 -and $targetExtraDiff[0].relation -eq 'target-only') 'Target-only component must remain explicit.'

$orderDifferences = @($comparison.differences | Where-Object componentId -eq 'order-insensitive')
Assert-True ($orderDifferences.Count -eq 0) 'Reordering normalized sets must not create drift.'

$firstJson = $comparison | ConvertTo-Json -Depth 30 -Compress
$secondJson = (New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport) | ConvertTo-Json -Depth 30 -Compress
Assert-True ($firstJson -eq $secondJson) 'Component/version comparison output must remain deterministic.'

Assert-True ($firstJson -notmatch [Regex]::Escape('vendor-build-1.2.3')) 'Raw text must not leak into output when normalized evidence is available.'
Assert-True ($firstJson -notmatch [Regex]::Escape('node-v20.2.0')) 'Normalized version output must not retain raw display text.'
Assert-True ($firstJson -notmatch '(?i)mandatory.{0,20}upgrade|required.{0,20}upgrade|automatic.{0,20}upgrade') 'Comparison output must not imply automatic upgrade/remediation.'

Write-Host 'Normalized component and version comparison validation passed.'
