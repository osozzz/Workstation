[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Comparison.Core.psm1'
$outputPath = Join-Path $root 'scripts\Core\Comparison.Output.psm1'
$entrypointPath = Join-Path $root 'scripts\Compare-Workstations.ps1'
$gitignorePath = Join-Path $root '.gitignore'

Import-Module $corePath -Force
Import-Module $outputPath -Force

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Normalize-Newlines {
    param([Parameter(Mandatory)][string]$Value)
    $lf = [string][char]10
    $crlf = ([string][char]13) + ([string][char]10)
    return $Value.Replace($crlf, $lf)
}

function New-SyntheticVersion {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$Normalized
    )
    return [pscustomobject][ordered]@{
        raw = $Raw
        normalized = $Normalized
        channel = 'stable'
    }
}

function New-SyntheticVersionIntelligence {
    return [pscustomobject][ordered]@{
        status = 'not-applicable'
        latestStable = $null
        latestLts = $null
        latestCurrent = $null
        source = $null
        checkedAt = $null
        message = $null
    }
}

function New-SyntheticComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][ValidateSet('present','missing','partial','unavailable','not-applicable','unknown')][string]$State,
        [AllowNull()][object]$ActiveVersion = $null
    )

    $installed = switch ($State) {
        'present' { $true }
        'missing' { $false }
        default { $null }
    }

    return [pscustomobject][ordered]@{
        componentId = $ComponentId
        name = "Synthetic $ComponentId"
        state = $State
        installed = $installed
        activeVersion = $ActiveVersion
        discoveredVersions = @()
        installations = @()
        commandResolutions = @()
        versionIntelligence = New-SyntheticVersionIntelligence
    }
}

function New-SyntheticProvider {
    param(
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][ValidateSet('success','warning','partial','failed','unavailable','not-applicable')][string]$Status,
        [object[]]$Components = @(),
        [object[]]$Evidence = @()
    )

    return [pscustomobject][ordered]@{
        providerId = $ProviderId
        category = $Category
        status = $Status
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @($Components)
        warnings = @()
        errors = @()
        evidence = @($Evidence)
    }
}

function New-SyntheticReport {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][object[]]$Providers,
        [string]$SchemaVersion = '1.0.0'
    )

    return [pscustomobject][ordered]@{
        schemaVersion = $SchemaVersion
        generatedAt = '2026-09-24T12:00:00+00:00'
        audit = [pscustomobject][ordered]@{
            mode = 'read-only'
            toolVersion = '0.8.0'
        }
        host = [pscustomobject][ordered]@{
            name = $HostName
            platform = 'windows'
            architecture = 'x64'
        }
        summary = [pscustomobject][ordered]@{
            status = $(if (@($Providers | Where-Object status -eq 'failed').Count -gt 0) { 'failed' } elseif (@($Providers | Where-Object status -in @('partial','unavailable')).Count -gt 0) { 'partial' } else { 'success' })
            providerCount = @($Providers).Count
            successCount = @($Providers | Where-Object status -eq 'success').Count
            warningCount = @($Providers | Where-Object status -eq 'warning').Count
            partialCount = @($Providers | Where-Object status -eq 'partial').Count
            failedCount = @($Providers | Where-Object status -eq 'failed').Count
            unavailableCount = @($Providers | Where-Object status -eq 'unavailable').Count
            notApplicableCount = @($Providers | Where-Object status -eq 'not-applicable').Count
        }
        providers = @($Providers)
        warnings = @()
        errors = @()
    }
}

function New-SyntheticPathEntry {
    param(
        [Parameter(Mandatory)][ValidateSet('machine','user','process')][string]$Scope,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$PathKey
    )
    return [pscustomobject][ordered]@{
        scope = $Scope
        position = $Position
        entry = $PathKey
        original = $PathKey
        expanded = $PathKey
        normalized = $PathKey
        comparisonKey = $PathKey.ToLowerInvariant()
        exists = $true
        duplicate = $false
        duplicateWithinScope = $false
        firstEquivalentPosition = $null
        hasUnresolvedVariable = $false
        unresolvedVariables = @()
        unapprovedReferenceCount = 0
    }
}

function New-SyntheticPathHealthEvidence {
    param(
        [Parameter(Mandatory)][ValidateSet('machine','user','process')][string]$Scope,
        [Parameter(Mandatory)][object[]]$Entries
    )
    $items = @($Entries)
    return [pscustomobject][ordered]@{
        evidenceId = "path.$Scope.health"
        type = 'path'
        source = "Synthetic $Scope PATH"
        exitCode = $null
        captured = $null
        redacted = $false
        attributes = [pscustomobject][ordered]@{
            entryCount = $items.Count
            duplicateCount = 0
            missingCount = 0
            unresolvedVariableCount = 0
            entries = $items
        }
    }
}

function New-SyntheticEnvironmentScope {
    param(
        [Parameter(Mandatory)][ValidateSet('process','user','machine')][string]$Scope,
        [AllowNull()][string]$PathKey,
        [ValidateSet('unset','value')][string]$State = 'value'
    )
    $items = if ($State -eq 'value') { @((New-SyntheticPathEntry -Scope $Scope -Position 0 -PathKey $PathKey)) } else { @() }
    return [pscustomobject][ordered]@{
        scope = $Scope
        state = $State
        raw = $(if ($State -eq 'value') { $PathKey } else { $null })
        expanded = $(if ($State -eq 'value') { $PathKey } else { $null })
        normalized = $(if ($State -eq 'value') { $PathKey } else { $null })
        comparisonKey = $(if ($State -eq 'value') { $PathKey.ToLowerInvariant() } else { $null })
        exists = $(if ($State -eq 'value') { $true } else { $null })
        pathItems = $items
        missingPathCount = 0
        hasUnresolvedVariable = $false
        unresolvedVariables = @()
        unapprovedReferenceCount = 0
        isConfigured = ($State -eq 'value')
        isInvalid = $false
    }
}

function New-SyntheticEnvironmentEvidence {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ProcessPath
    )
    return [pscustomobject][ordered]@{
        evidenceId = 'environment.' + $Name.ToLowerInvariant()
        type = 'environment'
        source = "Synthetic $Name"
        exitCode = $null
        captured = $null
        redacted = $false
        attributes = [pscustomobject][ordered]@{
            process = $ProcessPath
            user = $null
            machine = $null
            kind = 'path'
            filesystem = $true
            configuredScopeCount = 1
            valueScopeCount = 1
            distinctValueCount = 1
            scopeConflict = $false
            emptyScopeCount = 0
            invalidScopeCount = 0
            missingPathCount = 0
            unresolvedScopeCount = 0
            unapprovedReferenceCount = 0
            scopes = @(
                (New-SyntheticEnvironmentScope -Scope process -PathKey $ProcessPath),
                (New-SyntheticEnvironmentScope -Scope user -PathKey $null -State unset),
                (New-SyntheticEnvironmentScope -Scope machine -PathKey $null -State unset)
            )
        }
    }
}

function New-SyntheticAllowlistBoundary {
    return [pscustomobject][ordered]@{
        evidenceId = 'environment.allowlist.boundary'
        type = 'derived'
        source = 'Synthetic approved environment allowlist'
        exitCode = $null
        captured = $null
        redacted = $false
        attributes = [pscustomobject][ordered]@{
            approvedNames = @('JAVA_HOME')
            inspectedCount = 1
            arbitraryEnumeration = $false
            unapprovedReferenceExpansion = $false
        }
    }
}

function New-SyntheticCrossScopeEvidence {
    return [pscustomobject][ordered]@{
        evidenceId = 'path.persistent.cross-scope-duplicates'
        type = 'derived'
        source = 'Synthetic persistent PATH analysis'
        exitCode = $null
        captured = $null
        redacted = $false
        attributes = [pscustomobject][ordered]@{
            duplicateCount = 0
            duplicates = @()
            processScopeExcluded = $true
        }
    }
}

function New-SyntheticPackage {
    param(
        [Parameter(Mandatory)][string]$PackageId,
        [Parameter(Mandatory)][string]$InstalledVersion
    )
    return [pscustomobject][ordered]@{
        name = "Synthetic $PackageId"
        packageId = $PackageId
        identityReliable = $true
        installedVersion = $InstalledVersion
        installedVersionReliable = $true
        availableVersion = $null
        availableVersionReliable = $null
        source = 'winget'
        checkedAt = '2026-09-24T12:00:00+00:00'
    }
}

function New-SyntheticWinGetInventoryEvidence {
    param([Parameter(Mandatory)][object[]]$Packages)
    return [pscustomobject][ordered]@{
        evidenceId = 'winget.inventory.normalized'
        type = 'derived'
        source = 'Synthetic normalized WinGet inventory'
        exitCode = $null
        captured = $null
        redacted = $false
        attributes = [pscustomobject][ordered]@{
            status = 'known'
            checkedAt = '2026-09-24T12:00:00+00:00'
            packageCount = @($Packages).Count
            packages = @($Packages)
        }
    }
}

function New-SyntheticCandidate {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RelativePath
    )
    return [pscustomobject][ordered]@{
        path = $Path
        comparisonKey = $Path.ToLowerInvariant()
        relativePath = $RelativePath
        depth = 0
        repositoryMarker = $true
        markerNames = @('.git')
        rootIndexes = @(0)
    }
}

function New-ProjectsLocalProvider {
    param([Parameter(Mandatory)][object[]]$Candidates)
    return New-SyntheticProvider -ProviderId 'projects.local' -Category projects -Status success -Evidence @(
        [pscustomobject][ordered]@{
            evidenceId = 'projects.local.discovery'
            type = 'filesystem'
            source = 'Synthetic configured development roots'
            exitCode = $null
            captured = $null
            redacted = $false
            attributes = [pscustomobject][ordered]@{
                maxDepth = 4
                candidateCount = @($Candidates).Count
                repositoryCount = @($Candidates).Count
                inaccessibleDirectoryCount = 0
                skippedReparsePointCount = 0
                candidates = @($Candidates)
                inaccessibleDirectories = @()
            }
        },
        [pscustomobject][ordered]@{
            evidenceId = 'projects.local.summary'
            type = 'derived'
            source = 'Synthetic bounded discovery'
            exitCode = $null
            captured = $null
            redacted = $false
            attributes = [pscustomobject][ordered]@{
                maxDepth = 4
                candidateCount = @($Candidates).Count
                readOnly = $true
                boundedToConfiguredRoots = $true
                wholeDiskTraversal = $false
                implicitHomeTraversal = $false
                followsReparsePoints = $false
                filesystemMutation = $false
            }
        }
    )
}

function New-SyntheticJavaScriptProject {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$NodeConstraint,
        [Parameter(Mandatory)][string]$PackageManagerVersion
    )
    return [pscustomobject][ordered]@{
        projectIndex = 0
        path = $Path
        repositoryMarker = $true
        packageJsonState = 'read'
        packageName = 'synthetic-alpha'
        types = @('node-package')
        frameworkMarkers = [pscustomobject][ordered]@{
            angular = $false
            nextjs = $false
            prisma = $false
        }
        nodePins = @(
            [pscustomobject][ordered]@{
                source = 'package.json#engines.node'
                value = $NodeConstraint
            }
        )
        nodePinConflict = $false
        packageManager = [pscustomobject][ordered]@{
            raw = "pnpm@$PackageManagerVersion"
            name = 'pnpm'
            version = $PackageManagerVersion
            valid = $true
        }
        lockfiles = @('pnpm-lock.yaml')
        lockManagers = @('pnpm')
        packageManagerSignals = @('pnpm')
        packageManagerConflict = $false
    }
}

function New-SyntheticNonJavaScriptProject {
    param([Parameter(Mandatory)][string]$Path)
    return [pscustomobject][ordered]@{
        projectIndex = 0
        path = $Path
        repositoryMarker = $true
        types = @('go')
        markers = @('go.mod')
        constraints = @(
            [pscustomobject][ordered]@{
                ecosystem = 'go'
                source = 'go.mod'
                value = '1.25.0'
            }
        )
        ambiguous = $false
    }
}

function New-ProjectClassificationProvider {
    param(
        [Parameter(Mandatory)][ValidateSet('javascript','non-javascript')][string]$Kind,
        [Parameter(Mandatory)][object]$Project
    )
    $providerId = if ($Kind -eq 'javascript') { 'projects.javascript-web' } else { 'projects.non-javascript' }
    $evidenceId = if ($Kind -eq 'javascript') { 'projects.javascript-web.summary' } else { 'projects.non-javascript.summary' }
    return New-SyntheticProvider -ProviderId $providerId -Category projects -Status success -Evidence @(
        [pscustomobject][ordered]@{
            evidenceId = $evidenceId
            type = 'derived'
            source = 'Synthetic project classification'
            exitCode = $null
            captured = $null
            redacted = $false
            attributes = [pscustomobject][ordered]@{
                dependencyAvailable = $true
                projectCount = 1
                projects = @($Project)
                readOnly = $true
                reusedProjectsLocalDiscovery = $true
                canonicalFilesOnly = $true
                independentFilesystemTraversal = $false
                globalRuntimeEvidenceModified = $false
            }
        }
    )
}

function New-SyntheticGitHealthModel {
    param(
        [Parameter(Mandatory)][string]$Path,
        [bool]$Dirty,
        [int]$Ahead,
        [int]$Behind
    )
    return [pscustomobject][ordered]@{
        index = 0
        path = $Path
        state = 'inspected'
        reason = $null
        clean = (-not $Dirty)
        dirty = $Dirty
        stagedCount = 0
        unstagedCount = $(if ($Dirty) { 1 } else { 0 })
        untrackedCount = 0
        conflictedCount = 0
        branchHead = 'main'
        branchOid = 'synthetic-object-id-not-compared'
        detached = $false
        initial = $false
        upstream = 'origin/main'
        upstreamRemote = 'origin'
        missingUpstream = $false
        ahead = $Ahead
        behind = $Behind
        unpushedCommitCount = $Ahead
        diverged = ($Ahead -gt 0 -and $Behind -gt 0)
    }
}

function New-GitHealthProvider {
    param([Parameter(Mandatory)][object]$Repository)
    return New-SyntheticProvider -ProviderId 'git.repository-health' -Category git -Status success -Evidence @(
        [pscustomobject][ordered]@{
            evidenceId = 'git.repository-health.repository.0'
            type = 'derived'
            source = 'Synthetic normalized Git health'
            exitCode = $null
            captured = $null
            redacted = $false
            attributes = [pscustomobject][ordered]@{
                repository = $Repository
            }
        }
    )
}

function New-SyntheticGitHygieneModel {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$LinkedWorktrees
    )

    $worktrees = @(
        [pscustomobject][ordered]@{
            index = 0
            path = "$Path\main-worktree"
            branch = 'main'
            head = 'synthetic-head-not-compared'
            detached = $false
            bare = $false
            locked = $false
            prunable = $false
            isMainWorktree = $true
            state = 'inspected'
            dirty = $false
            stagedCount = 0
            unstagedCount = 0
            untrackedCount = 0
            advisoryCleanupCandidate = $false
            cleanupCriterion = $null
        }
    )

    if ($LinkedWorktrees -gt 0) {
        $worktrees += [pscustomobject][ordered]@{
            index = 1
            path = "$Path\linked-worktree"
            branch = 'feat/synthetic'
            head = 'synthetic-linked-head-not-compared'
            detached = $false
            bare = $false
            locked = $false
            prunable = $false
            isMainWorktree = $false
            state = 'inspected'
            dirty = $true
            stagedCount = 0
            unstagedCount = 1
            untrackedCount = 0
            advisoryCleanupCandidate = $false
            cleanupCriterion = $null
        }
    }

    return [pscustomobject][ordered]@{
        index = 0
        path = $Path
        currentBranch = 'main'
        detectedDefaultBranches = @('main')
        mergeTarget = 'main'
        mergeTargetRef = 'refs/heads/main'
        branchCount = 1
        worktreeCount = @($worktrees).Count
        branches = @(
            [pscustomobject][ordered]@{
                name = 'main'
                objectId = 'synthetic-main-object-not-compared'
                upstream = 'origin/main'
                upstreamGone = $false
                upstreamTrack = ''
                tipCommitAgeDays = 1
                staleThresholdDays = 90
                stale = $false
                mergedInto = 'main'
                merged = $true
                current = $true
                default = $true
                checkedOutInWorktree = $true
                protected = $true
                protectedReasons = @('current-branch')
                namingPolicy = 'workstation-governance'
                namingDeviation = $false
                advisoryCleanupCandidate = $false
                cleanupCriterion = $null
            }
        )
        worktrees = $worktrees
    }
}

function New-GitHygieneProvider {
    param([Parameter(Mandatory)][object]$Repository)
    return New-SyntheticProvider -ProviderId 'git.branch-worktree-hygiene' -Category git -Status success -Evidence @(
        [pscustomobject][ordered]@{
            evidenceId = 'git.branch-worktree-hygiene.repository.0'
            type = 'derived'
            source = 'Synthetic branch/worktree hygiene'
            exitCode = $null
            captured = $null
            redacted = $false
            attributes = [pscustomobject][ordered]@{
                repository = $Repository
            }
        }
    )
}

$referenceVersion = New-SyntheticVersion -Raw 'v1.0.0' -Normalized '1.0.0'
$targetVersion = New-SyntheticVersion -Raw 'v2.0.0' -Normalized '2.0.0'

$referenceRuntime = New-SyntheticProvider -ProviderId 'runtime.synthetic' -Category runtime -Status partial -Components @(
    (New-SyntheticComponent -ComponentId 'active-tool' -State present -ActiveVersion $referenceVersion),
    (New-SyntheticComponent -ComponentId 'installed-tool' -State present),
    (New-SyntheticComponent -ComponentId 'unknown-tool' -State unknown),
    (New-SyntheticComponent -ComponentId 'optional-tool' -State not-applicable)
)

$targetRuntime = New-SyntheticProvider -ProviderId 'runtime.synthetic' -Category runtime -Status success -Components @(
    (New-SyntheticComponent -ComponentId 'active-tool' -State present -ActiveVersion $targetVersion),
    (New-SyntheticComponent -ComponentId 'installed-tool' -State missing),
    (New-SyntheticComponent -ComponentId 'unknown-tool' -State present),
    (New-SyntheticComponent -ComponentId 'optional-tool' -State present)
)

$referenceEnvironment = New-SyntheticProvider -ProviderId 'environment.baseline' -Category environment -Status success -Evidence @(
    (New-SyntheticAllowlistBoundary),
    (New-SyntheticEnvironmentEvidence -Name 'JAVA_HOME' -ProcessPath 'X:\Synthetic\Java17'),
    (New-SyntheticPathHealthEvidence -Scope machine -Entries @((New-SyntheticPathEntry -Scope machine -Position 0 -PathKey 'X:\Synthetic\Tools'))),
    (New-SyntheticCrossScopeEvidence)
)

$targetEnvironment = New-SyntheticProvider -ProviderId 'environment.baseline' -Category environment -Status success -Evidence @(
    (New-SyntheticAllowlistBoundary),
    (New-SyntheticEnvironmentEvidence -Name 'JAVA_HOME' -ProcessPath 'Y:\Synthetic\Java21'),
    (New-SyntheticPathHealthEvidence -Scope machine -Entries @((New-SyntheticPathEntry -Scope machine -Position 0 -PathKey 'Y:\Synthetic\Tools'))),
    (New-SyntheticCrossScopeEvidence)
)

$referenceWinGet = New-SyntheticProvider -ProviderId 'winget.baseline' -Category package-manager -Status success -Components @(
    (New-SyntheticComponent -ComponentId winget -State present)
) -Evidence @(
    (New-SyntheticWinGetInventoryEvidence -Packages @(
        (New-SyntheticPackage -PackageId 'Synthetic.SharedApp' -InstalledVersion '1.0.0'),
        (New-SyntheticPackage -PackageId 'Synthetic.ReferenceOnly' -InstalledVersion '1.0.0')
    ))
)

$targetWinGet = New-SyntheticProvider -ProviderId 'winget.baseline' -Category package-manager -Status success -Components @(
    (New-SyntheticComponent -ComponentId winget -State present)
) -Evidence @(
    (New-SyntheticWinGetInventoryEvidence -Packages @(
        (New-SyntheticPackage -PackageId 'Synthetic.SharedApp' -InstalledVersion '2.0.0'),
        (New-SyntheticPackage -PackageId 'Synthetic.TargetOnly' -InstalledVersion '1.0.0')
    ))
)

$referenceProjectPath = 'X:\Synthetic\Reference\Alpha'
$targetProjectPath = 'Y:\Synthetic\Target\Alpha'

$referenceProjectsLocal = New-ProjectsLocalProvider -Candidates @((New-SyntheticCandidate -Path $referenceProjectPath -RelativePath Alpha))
$targetProjectsLocal = New-ProjectsLocalProvider -Candidates @((New-SyntheticCandidate -Path $targetProjectPath -RelativePath Alpha))

$referenceJavaScriptProjects = New-ProjectClassificationProvider -Kind javascript -Project (
    New-SyntheticJavaScriptProject -Path $referenceProjectPath -NodeConstraint '>=20' -PackageManagerVersion '10.0.0'
)
$targetJavaScriptProjects = New-ProjectClassificationProvider -Kind javascript -Project (
    New-SyntheticJavaScriptProject -Path $targetProjectPath -NodeConstraint '>=22' -PackageManagerVersion '10.1.0'
)

$referenceNonJavaScriptProjects = New-ProjectClassificationProvider -Kind non-javascript -Project (
    New-SyntheticNonJavaScriptProject -Path $referenceProjectPath
)
$targetNonJavaScriptProjects = New-ProjectClassificationProvider -Kind non-javascript -Project (
    New-SyntheticNonJavaScriptProject -Path $targetProjectPath
)

$referenceGitHealth = New-GitHealthProvider -Repository (
    New-SyntheticGitHealthModel -Path $referenceProjectPath -Dirty $false -Ahead 0 -Behind 0
)
$targetGitHealth = New-GitHealthProvider -Repository (
    New-SyntheticGitHealthModel -Path $targetProjectPath -Dirty $true -Ahead 1 -Behind 1
)

$referenceGitHygiene = New-GitHygieneProvider -Repository (
    New-SyntheticGitHygieneModel -Path $referenceProjectPath -LinkedWorktrees 0
)
$targetGitHygiene = New-GitHygieneProvider -Repository (
    New-SyntheticGitHygieneModel -Path $targetProjectPath -LinkedWorktrees 1
)

$referenceAvailability = New-SyntheticProvider -ProviderId 'synthetic.availability' -Category synthetic -Status unavailable
$targetAvailability = New-SyntheticProvider -ProviderId 'synthetic.availability' -Category synthetic -Status success
$referenceOptional = New-SyntheticProvider -ProviderId 'synthetic.optional' -Category synthetic -Status not-applicable
$targetOptional = New-SyntheticProvider -ProviderId 'synthetic.optional' -Category synthetic -Status success
$referenceOnlyProvider = New-SyntheticProvider -ProviderId 'synthetic.reference-only' -Category synthetic -Status success

$referenceProviders = @(
    $referenceRuntime,
    $referenceEnvironment,
    $referenceWinGet,
    $referenceProjectsLocal,
    $referenceJavaScriptProjects,
    $referenceNonJavaScriptProjects,
    $referenceGitHealth,
    $referenceGitHygiene,
    $referenceAvailability,
    $referenceOptional,
    $referenceOnlyProvider
)

$targetProviders = @(
    $targetRuntime,
    $targetEnvironment,
    $targetWinGet,
    $targetProjectsLocal,
    $targetJavaScriptProjects,
    $targetNonJavaScriptProjects,
    $targetGitHealth,
    $targetGitHygiene,
    $targetAvailability,
    $targetOptional
)

$referenceReport = New-SyntheticReport -HostName 'SYNTHETIC-REFERENCE' -Providers $referenceProviders
$targetReport = New-SyntheticReport -HostName 'SYNTHETIC-TARGET' -Providers $targetProviders

$comparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport
$secondComparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport

$structured = ConvertTo-WorkstationComparisonJson -Comparison $comparison
$structuredAgain = ConvertTo-WorkstationComparisonJson -Comparison $secondComparison

Assert-True ($structured -eq $structuredAgain) 'Complete Sprint 6 structured comparison must be deterministic.'
Assert-True ($comparison.direction -eq 'reference-to-target') 'Complete comparison must preserve reference-to-target direction.'
Assert-True ($comparison.reference.host.name -eq 'SYNTHETIC-REFERENCE') 'Reference endpoint identity must remain explicit.'
Assert-True ($comparison.target.host.name -eq 'SYNTHETIC-TARGET') 'Target endpoint identity must remain explicit.'
Assert-True ($comparison.summary.status -eq 'different') 'Known synthetic drift must produce different summary status.'

foreach ($category in @('provider','component','version','path','environment','application','project','git')) {
    Assert-True (@($comparison.differences | Where-Object category -eq $category).Count -gt 0) "Complete comparison is missing category '$category'."
}

foreach ($kind in @(
    'active-version',
    'state',
    'scope-order',
    'allowlisted-variable',
    'installed-version',
    'presence',
    'runtime-constraints',
    'package-manager',
    'divergence',
    'worktree-state',
    'worktree-hygiene'
)) {
    Assert-True (@($comparison.differences | Where-Object kind -eq $kind).Count -gt 0) "Complete comparison is missing expected drift kind '$kind'."
}

Assert-True (@($comparison.differences | Where-Object { $_.componentId -eq 'installed-tool' -and $_.relation -eq 'different' }).Count -eq 1) 'Installed versus missing tool state must be represented.'
Assert-True (@($comparison.differences | Where-Object { $_.componentId -eq 'unknown-tool' -and $_.relation -eq 'unknown' }).Count -eq 1) 'Unknown component state must remain semantically distinct.'
Assert-True (@($comparison.differences | Where-Object { $_.componentId -eq 'optional-tool' -and $_.relation -eq 'not-applicable' }).Count -eq 1) 'Not-applicable component state must remain semantically distinct.'
Assert-True (@($comparison.differences | Where-Object { $_.providerId -eq 'runtime.synthetic' -and $_.category -eq 'provider' -and $_.referenceState -eq 'partial' }).Count -eq 1) 'Partial provider state must remain explicit.'
Assert-True (@($comparison.differences | Where-Object { $_.providerId -eq 'synthetic.availability' -and $_.relation -eq 'unavailable' }).Count -eq 1) 'Unavailable provider state must remain explicit.'
Assert-True (@($comparison.differences | Where-Object { $_.providerId -eq 'synthetic.optional' -and $_.relation -eq 'not-applicable' }).Count -eq 1) 'Not-applicable provider state must remain explicit.'
Assert-True (@($comparison.differences | Where-Object { $_.providerId -eq 'synthetic.reference-only' -and $_.relation -eq 'reference-only' }).Count -eq 1) 'Missing provider state must remain explicit.'

Assert-True (@($comparison.differences | Where-Object { $_.providerId -eq 'runtime.synthetic' -and $_.category -eq 'version' }).Count -gt 0) 'Unavailable unrelated provider must not block runtime comparison.'
Assert-True (@($comparison.differences | Where-Object category -eq 'path').Count -gt 0) 'Unavailable unrelated provider must not block PATH comparison.'
Assert-True (@($comparison.differences | Where-Object category -eq 'application').Count -gt 0) 'Unavailable unrelated provider must not block application comparison.'
Assert-True (@($comparison.differences | Where-Object category -eq 'project').Count -gt 0) 'Unavailable unrelated provider must not block project comparison.'
Assert-True (@($comparison.differences | Where-Object category -eq 'git').Count -gt 0) 'Unavailable unrelated provider must not block Git comparison.'

$human = ConvertTo-WorkstationComparisonText -Comparison $comparison
$roundTripped = $structured | ConvertFrom-Json -Depth 100
$humanFromStructured = ConvertTo-WorkstationComparisonText -Comparison $roundTripped
Assert-True ($human -eq $humanFromStructured) 'Human-readable output must be derived consistently from the structured comparison result.'

foreach ($heading in @('Components and versions','PATH and environment','Applications','Projects and runtime constraints','Git health')) {
    Assert-True ($human.Contains($heading)) "Human-readable output is missing '$heading'."
}
foreach ($marker in @('[unavailable]','[unknown]','[not-applicable]','Direction: reference -> target')) {
    Assert-True ($human.Contains($marker)) "Human-readable output is missing semantic marker '$marker'."
}

$compatibleTarget = $targetReport | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
$compatibleTarget.schemaVersion = '1.1.0'
$compatibleComparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $compatibleTarget
Assert-True ($compatibleComparison.summary.differenceCount -eq $comparison.summary.differenceCount) 'Compatible audit schema minor drift must not change semantic differences.'

$unsupportedTarget = $targetReport | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
$unsupportedTarget.schemaVersion = '2.0.0'
$unsupportedFailed = $false
try {
    New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $unsupportedTarget | Out-Null
}
catch {
    $unsupportedFailed = ($_.Exception.Message -match 'unsupported audit schema major|schema majors differ')
}
Assert-True $unsupportedFailed 'Unsupported audit schema major must fail explicitly.'

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('workstation-sprint6-comparison-' + [guid]::NewGuid().ToString('N'))
$outputDirectory = Join-Path $tempRoot 'reports\comparison'
$referencePath = Join-Path $tempRoot 'reference.json'
$targetPath = Join-Path $tempRoot 'target.json'

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $referenceReport | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $referencePath -Encoding UTF8
    $targetReport | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $targetPath -Encoding UTF8

    $entryComparison = & $entrypointPath -Reference $referencePath -Target $targetPath -OutputDirectory $outputDirectory

    Assert-True ($entryComparison.summary.differenceCount -eq $comparison.summary.differenceCount) 'Entrypoint comparison must match direct normalized comparison.'
    Assert-True (Test-Path -LiteralPath (Join-Path $outputDirectory 'comparison.json') -PathType Leaf) 'Structured comparison output must be written locally.'
    Assert-True (Test-Path -LiteralPath (Join-Path $outputDirectory 'comparison.txt') -PathType Leaf) 'Human-readable comparison output must be written locally.'

    $writtenStructured = Normalize-Newlines -Value ([IO.File]::ReadAllText((Join-Path $outputDirectory 'comparison.json')))
    $writtenHuman = Normalize-Newlines -Value ([IO.File]::ReadAllText((Join-Path $outputDirectory 'comparison.txt')))
    $entryStructured = Normalize-Newlines -Value (ConvertTo-WorkstationComparisonJson -Comparison $entryComparison)
    $entryHuman = Normalize-Newlines -Value (ConvertTo-WorkstationComparisonText -Comparison $entryComparison)

    Assert-True ($writtenStructured -eq $entryStructured) 'Written structured output must match the entrypoint normalized comparison result.'
    Assert-True ($writtenHuman -eq $entryHuman) 'Written human-readable output must match the entrypoint rendering.'

    $writtenRoundTrip = $writtenStructured | ConvertFrom-Json -Depth 100
    $writtenHumanFromStructured = Normalize-Newlines -Value (ConvertTo-WorkstationComparisonText -Comparison $writtenRoundTrip)
    Assert-True ($writtenHuman -eq $writtenHumanFromStructured) 'Written human-readable output must be reproducible from written structured output.'

    $repoPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
    $outputPrefix = [IO.Path]::GetFullPath($outputDirectory)
    Assert-True (-not $outputPrefix.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) 'Controlled comparison output must remain outside the repository workspace.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Assert-True (-not (Test-Path -LiteralPath $tempRoot)) 'Controlled comparison temporary output must be deleted after validation.'
Assert-True (@(Get-Content -LiteralPath $gitignorePath) -contains 'reports/') 'Machine-specific audit/comparison reports must remain ignored by Git.'

$fixtureSource = Get-Content -LiteralPath $MyInvocation.MyCommand.Path -Raw
$slash = [string][char]92
$forbiddenFixturePatterns = @(
    ('C:' + $slash + 'Users' + $slash),
    ('D:' + $slash + 'Users' + $slash),
    ('@gmail' + '.com'),
    ('@outlook' + '.com'),
    ('github_' + 'pat_'),
    ('gh' + 'p_'),
    ('Bearer' + ' '),
    ('Authorization' + ':')
)
foreach ($forbiddenFixturePattern in $forbiddenFixturePatterns) {
    Assert-True ($fixtureSource -notmatch [Regex]::Escape($forbiddenFixturePattern)) "Committed Sprint 6 fixture source contains forbidden real-account/path marker '$forbiddenFixturePattern'."
}

$comparisonSources = @(
    (Get-Content -LiteralPath $corePath -Raw),
    (Get-Content -LiteralPath $outputPath -Raw),
    (Get-Content -LiteralPath $entrypointPath -Raw)
) -join [Environment]::NewLine

foreach ($forbiddenMutation in @(
    'SetEnvironmentVariable(',
    'winget install',
    'winget upgrade',
    'winget uninstall',
    'npm install',
    'pnpm add',
    'git fetch',
    'git pull',
    'git checkout',
    'git reset',
    'git clean',
    'git branch -D',
    'Invoke-AuditCommand',
    'Invoke-ReadOnlyGit'
)) {
    Assert-True ($comparisonSources -notmatch [Regex]::Escape($forbiddenMutation)) "Comparison runtime must not contain mutation/discovery marker '$forbiddenMutation'."
}

Write-Host "Sprint 6 Cross-PC Comparison integration gate passed with $($comparison.summary.differenceCount) deterministic differences."
