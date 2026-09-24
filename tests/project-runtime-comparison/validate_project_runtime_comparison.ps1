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
        [Parameter(Mandatory)][string]$Value
    )

    return [pscustomobject][ordered]@{
        raw        = $Value
        normalized = $Value
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

function New-SyntheticRuntimeProvider {
    param(
        [Parameter(Mandatory)][string]$Version
    )

    return [pscustomobject][ordered]@{
        providerId = 'runtime.synthetic'
        category   = 'runtime'
        status     = 'success'
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @(
            [pscustomobject][ordered]@{
                componentId         = 'node-global'
                name                = 'Synthetic global Node'
                state               = 'present'
                installed           = $true
                activeVersion       = New-SyntheticVersion -Value $Version
                discoveredVersions  = @()
                installations       = @()
                commandResolutions  = @()
                versionIntelligence = New-SyntheticVersionIntelligence
            }
        )
        warnings   = @()
        errors     = @()
        evidence   = @()
    }
}

function New-SyntheticCandidate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath,
        [bool]$RepositoryMarker,
        [int[]]$RootIndexes = @(0)
    )

    return [pscustomobject][ordered]@{
        path             = $Path
        comparisonKey    = $Path.ToLowerInvariant()
        relativePath     = $RelativePath
        depth            = 0
        repositoryMarker = $RepositoryMarker
        markerNames      = @('.git')
        rootIndexes      = @($RootIndexes)
    }
}

function New-ProjectsLocalProvider {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [ValidateSet('success','warning','partial','failed','unavailable','not-applicable')][string]$Status = 'success'
    )

    return [pscustomobject][ordered]@{
        providerId = 'projects.local'
        category   = 'projects'
        status     = $Status
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @()
        warnings   = @()
        errors     = @()
        evidence   = @(
            [pscustomobject][ordered]@{
                evidenceId = 'projects.local.discovery'
                type       = 'filesystem'
                source     = 'Synthetic configured development roots'
                exitCode   = $null
                captured   = $null
                redacted   = $false
                attributes = [pscustomobject][ordered]@{
                    maxDepth                    = 4
                    traversedDirectoryCount     = 4
                    candidateCount              = @($Candidates).Count
                    repositoryCount             = @($Candidates | Where-Object repositoryMarker).Count
                    inaccessibleDirectoryCount  = 0
                    skippedReparsePointCount    = 0
                    candidates                  = @($Candidates)
                    inaccessibleDirectories     = @()
                }
            },
            [pscustomobject][ordered]@{
                evidenceId = 'projects.local.summary'
                type       = 'derived'
                source     = 'Synthetic bounded discovery'
                exitCode   = $null
                captured   = $null
                redacted   = $false
                attributes = [pscustomobject][ordered]@{
                    maxDepth                 = 4
                    candidateCount           = @($Candidates).Count
                    readOnly                 = $true
                    boundedToConfiguredRoots = $true
                    wholeDiskTraversal       = $false
                    implicitHomeTraversal    = $false
                    followsReparsePoints     = $false
                    filesystemMutation       = $false
                }
            }
        )
    }
}

function New-JavaScriptProject {
    param(
        [Parameter(Mandatory)][int]$ProjectIndex,
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$NodeConstraint,
        [Parameter(Mandatory)][string]$PackageManagerVersion
    )

    return [pscustomobject][ordered]@{
        projectIndex           = $ProjectIndex
        path                   = "X:\Synthetic\$PackageName"
        repositoryMarker       = $true
        packageJsonState       = 'read'
        packageName            = $PackageName
        types                  = @('node-package')
        frameworkMarkers       = [pscustomobject][ordered]@{
            angular = $false
            nextjs  = $false
            prisma  = $false
        }
        nodePins               = @(
            [pscustomobject][ordered]@{
                source = 'package.json#engines.node'
                value  = $NodeConstraint
            }
        )
        nodePinConflict        = $false
        packageManager         = [pscustomobject][ordered]@{
            raw     = "pnpm@$PackageManagerVersion"
            name    = 'pnpm'
            version = $PackageManagerVersion
            valid   = $true
        }
        lockfiles              = @('pnpm-lock.yaml')
        lockManagers           = @('pnpm')
        packageManagerSignals  = @('pnpm')
        packageManagerConflict = $false
    }
}

function New-NonJavaScriptProject {
    param(
        [Parameter(Mandatory)][int]$ProjectIndex,
        [Parameter(Mandatory)][string[]]$Types,
        [Parameter(Mandatory)][object[]]$Constraints
    )

    return [pscustomobject][ordered]@{
        projectIndex     = $ProjectIndex
        path             = "X:\Synthetic\project-$ProjectIndex"
        repositoryMarker = $true
        types            = @($Types)
        markers          = @()
        constraints      = @($Constraints)
        ambiguous        = $false
    }
}

function New-Constraint {
    param(
        [Parameter(Mandatory)][string]$Ecosystem,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Value
    )

    return [pscustomobject][ordered]@{
        ecosystem = $Ecosystem
        source    = $Source
        value     = $Value
    }
}

function New-ClassificationProvider {
    param(
        [Parameter(Mandatory)][ValidateSet('javascript','non-javascript')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Projects,
        [ValidateSet('success','warning','partial','failed','unavailable','not-applicable')][string]$Status = 'success'
    )

    if ($Kind -eq 'javascript') {
        $providerId = 'projects.javascript-web'
        $evidenceId = 'projects.javascript-web.summary'
    }
    else {
        $providerId = 'projects.non-javascript'
        $evidenceId = 'projects.non-javascript.summary'
    }

    return [pscustomobject][ordered]@{
        providerId = $providerId
        category   = 'projects'
        status     = $Status
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @()
        warnings   = @()
        errors     = @()
        evidence   = @(
            [pscustomobject][ordered]@{
                evidenceId = $evidenceId
                type       = 'derived'
                source     = 'Synthetic project classification'
                exitCode   = $null
                captured   = $null
                redacted   = $false
                attributes = [pscustomobject][ordered]@{
                    dependencyAvailable          = ($Status -ne 'unavailable')
                    projectCount                 = @($Projects).Count
                    projects                     = @($Projects)
                    readOnly                     = $true
                    reusedProjectsLocalDiscovery = $true
                    canonicalFilesOnly           = $true
                    independentFilesystemTraversal = $false
                    globalRuntimeEvidenceModified  = $false
                }
            }
        )
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
            toolVersion = '0.8.0'
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
            warningCount       = @($Providers | Where-Object status -eq 'warning').Count
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

$referenceCandidates = @(
    (New-SyntheticCandidate -Path 'C:\Synthetic\Roots\Alpha' -RelativePath '.' -RepositoryMarker $true -RootIndexes @(0)),
    (New-SyntheticCandidate -Path 'C:\Synthetic\Roots\Beta' -RelativePath 'Beta' -RepositoryMarker $true -RootIndexes @(1)),
    (New-SyntheticCandidate -Path 'C:\Synthetic\Roots\ReferenceOnly' -RelativePath 'ReferenceOnly' -RepositoryMarker $true -RootIndexes @(1))
)

$targetCandidates = @(
    (New-SyntheticCandidate -Path 'D:\Elsewhere\Alpha' -RelativePath '.' -RepositoryMarker $true -RootIndexes @(3)),
    (New-SyntheticCandidate -Path 'D:\Elsewhere\Beta' -RelativePath 'Beta' -RepositoryMarker $false -RootIndexes @(4)),
    (New-SyntheticCandidate -Path 'D:\Elsewhere\TargetOnly' -RelativePath 'TargetOnly' -RepositoryMarker $true -RootIndexes @(4))
)

$referenceJs = @(
    (New-JavaScriptProject -ProjectIndex 0 -PackageName 'alpha' -NodeConstraint '>=20' -PackageManagerVersion '10.0.0')
)
$targetJs = @(
    (New-JavaScriptProject -ProjectIndex 0 -PackageName 'alpha' -NodeConstraint '>=22' -PackageManagerVersion '10.1.0')
)

$referenceNonJs = @(
    (New-NonJavaScriptProject -ProjectIndex 1 -Types @('go') -Constraints @(
        (New-Constraint -Ecosystem go -Source 'go.mod#go' -Value '1.24.0')
    ))
)
$targetNonJs = @(
    (New-NonJavaScriptProject -ProjectIndex 1 -Types @('go','python') -Constraints @(
        (New-Constraint -Ecosystem go -Source 'go.mod#go' -Value '1.25.0'),
        (New-Constraint -Ecosystem python -Source 'pyproject.toml#requires-python' -Value '>=3.12')
    ))
)

$referenceProviders = @(
    (New-ProjectsLocalProvider -Candidates $referenceCandidates),
    (New-ClassificationProvider -Kind javascript -Projects $referenceJs),
    (New-ClassificationProvider -Kind non-javascript -Projects $referenceNonJs),
    (New-SyntheticRuntimeProvider -Version '22.0.0')
)
$targetProviders = @(
    (New-ProjectsLocalProvider -Candidates $targetCandidates),
    (New-ClassificationProvider -Kind javascript -Projects $targetJs),
    (New-ClassificationProvider -Kind non-javascript -Projects $targetNonJs),
    (New-SyntheticRuntimeProvider -Version '24.0.0')
)

$referenceReport = New-SyntheticReport -Name reference -Providers $referenceProviders
$targetReport = New-SyntheticReport -Name target -Providers $targetProviders
$comparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport

$projectDifferences = @($comparison.differences | Where-Object category -eq 'project')

Assert-True ($projectDifferences.Count -eq 7) 'Primary project comparison must emit exactly seven project differences.'
Assert-True (@($projectDifferences | Where-Object kind -eq 'presence').Count -eq 2) 'Added and removed projects must be distinguishable.'
Assert-True (@($projectDifferences | Where-Object kind -eq 'types').Count -eq 1) 'Project ecosystem/type drift must be summarized.'
Assert-True (@($projectDifferences | Where-Object kind -eq 'runtime-constraints').Count -eq 2) 'Project-local runtime constraints must compare independently.'
Assert-True (@($projectDifferences | Where-Object kind -eq 'package-manager').Count -eq 1) 'Project package-manager drift must be compared separately.'
Assert-True (@($projectDifferences | Where-Object kind -eq 'git-association').Count -eq 1) 'Project Git association must come from normalized candidate evidence.'

$alphaConstraint = @(
    $projectDifferences |
        Where-Object {
            $_.kind -eq 'runtime-constraints' -and
            @($_.referenceValue | Where-Object ecosystem -eq 'node').Count -eq 1
        }
)[0]
Assert-True ($null -ne $alphaConstraint) 'Expected Node project-local constraint drift.'
Assert-True ($alphaConstraint.referenceValue[0].value -eq '>=20') 'Reference Node constraint must preserve project-local engines.node.'
Assert-True ($alphaConstraint.targetValue[0].value -eq '>=22') 'Target Node constraint must preserve project-local engines.node.'
Assert-True ($alphaConstraint.referenceValue[0].value -ne '22.0.0') 'Global active runtime must not overwrite the reference project pin.'
Assert-True ($alphaConstraint.targetValue[0].value -ne '24.0.0') 'Global active runtime must not overwrite the target project pin.'

$alphaPackageManager = @($projectDifferences | Where-Object kind -eq 'package-manager')[0]
Assert-True ($alphaPackageManager.referenceValue.declaration.name -eq 'pnpm') 'Package manager identity must remain normalized.'
Assert-True ($alphaPackageManager.referenceValue.declaration.version -eq '10.0.0') 'Reference package-manager pin must be preserved.'
Assert-True ($alphaPackageManager.targetValue.declaration.version -eq '10.1.0') 'Target package-manager pin must be preserved.'

$projectJson = $projectDifferences | ConvertTo-Json -Depth 30 -Compress
foreach ($forbiddenPath in @('C:\Synthetic','D:\Elsewhere','X:\Synthetic')) {
    Assert-True ($projectJson -notmatch [Regex]::Escape($forbiddenPath)) "Project comparison output must not expose synthetic absolute path '$forbiddenPath'."
}

$alphaPresence = @(
    $projectDifferences |
        Where-Object {
            $_.kind -ne 'presence' -and
            ($_.referenceValue -ne $null -or $_.targetValue -ne $null)
        }
)
Assert-True ($alphaPresence.Count -gt 0) 'Projects rooted at different absolute paths must still match through path-safe identity.'

$firstJson = $comparison | ConvertTo-Json -Depth 30 -Compress
$secondJson = (New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport) | ConvertTo-Json -Depth 30 -Compress
Assert-True ($firstJson -eq $secondJson) 'Project comparison output must remain deterministic.'

$targetJsUnavailable = New-ClassificationProvider -Kind javascript -Projects @() -Status unavailable
$classificationUnavailableReport = New-SyntheticReport -Name target-js-unavailable -Providers @(
    (New-ProjectsLocalProvider -Candidates $referenceCandidates),
    $targetJsUnavailable,
    (New-ClassificationProvider -Kind non-javascript -Projects $referenceNonJs),
    (New-SyntheticRuntimeProvider -Version '24.0.0')
)
$classificationUnavailableComparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $classificationUnavailableReport
$classificationProjectDiffs = @($classificationUnavailableComparison.differences | Where-Object category -eq 'project')

Assert-True (@($classificationProjectDiffs | Where-Object kind -eq 'package-manager').Count -eq 0) 'Unavailable JavaScript classification must not fabricate package-manager drift.'
Assert-True (@($classificationProjectDiffs | Where-Object kind -eq 'types').Count -eq 0) 'Unavailable project classification must not fabricate combined type drift.'
Assert-True (@($classificationProjectDiffs | Where-Object kind -eq 'runtime-constraints').Count -eq 0) 'Unavailable project classification must not fabricate combined runtime-constraint drift.'

$localUnavailableReport = New-SyntheticReport -Name target-local-unavailable -Providers @(
    (New-ProjectsLocalProvider -Candidates @() -Status unavailable),
    (New-ClassificationProvider -Kind javascript -Projects @() -Status unavailable),
    (New-ClassificationProvider -Kind non-javascript -Projects @() -Status unavailable),
    (New-SyntheticRuntimeProvider -Version '24.0.0')
)
$localUnavailableComparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $localUnavailableReport
Assert-True (@($localUnavailableComparison.differences | Where-Object category -eq 'project').Count -eq 0) 'Unavailable bounded discovery must not fabricate all projects as missing.'
Assert-True (@($localUnavailableComparison.differences | Where-Object { $_.providerId -eq 'runtime.synthetic' -and $_.category -eq 'version' }).Count -eq 1) 'Unavailable project discovery must not block unrelated runtime comparison.'

$coreSource = Get-Content -LiteralPath $corePath -Raw
foreach ($required in @(
    'projects.local.discovery',
    'projects.javascript-web.summary',
    'projects.non-javascript.summary',
    'runtime-constraints',
    'package-manager',
    'git-association'
)) {
    Assert-True ($coreSource -match [Regex]::Escape($required)) "Missing normalized project-comparison marker: $required"
}

Write-Host 'Project and runtime-constraint comparison validation passed.'
