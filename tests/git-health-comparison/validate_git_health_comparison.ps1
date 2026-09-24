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
    param([Parameter(Mandatory)][string]$Value)

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
    param([Parameter(Mandatory)][string]$Version)

    return [pscustomobject][ordered]@{
        providerId = 'runtime.synthetic'
        category   = 'runtime'
        status     = 'success'
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @(
            [pscustomobject][ordered]@{
                componentId         = 'runtime-a'
                name                = 'Synthetic runtime'
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
        [Parameter(Mandatory)][string]$RelativePath
    )

    return [pscustomobject][ordered]@{
        path             = $Path
        comparisonKey    = $Path.ToLowerInvariant()
        relativePath     = $RelativePath
        depth            = 0
        repositoryMarker = $true
        markerNames      = @('.git')
        rootIndexes      = @(0)
    }
}

function New-ProjectsLocalProvider {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates,
        [ValidateSet('success','partial','failed','unavailable','not-applicable')][string]$Status = 'success'
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
                source     = 'Synthetic bounded discovery'
                exitCode   = $null
                captured   = $null
                redacted   = $false
                attributes = [pscustomobject][ordered]@{
                    maxDepth                   = 4
                    candidateCount             = @($Candidates).Count
                    repositoryCount            = @($Candidates).Count
                    inaccessibleDirectoryCount = 0
                    skippedReparsePointCount   = 0
                    candidates                 = @($Candidates)
                    inaccessibleDirectories    = @()
                }
            }
        )
    }
}

function New-GitHealthModel {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('inspected','unavailable')][string]$State,
        [bool]$Dirty = $false,
        [int]$StagedCount = 0,
        [int]$UnstagedCount = 0,
        [int]$UntrackedCount = 0,
        [int]$ConflictedCount = 0,
        [AllowNull()][string]$BranchHead = $null,
        [AllowNull()][string]$Upstream = $null,
        [AllowNull()][int]$Ahead = $null,
        [AllowNull()][int]$Behind = $null
    )

    if ($State -eq 'unavailable') {
        return [pscustomobject][ordered]@{
            path                = $Path
            state               = 'unavailable'
            reason              = 'synthetic-unavailable'
            clean               = $null
            dirty               = $null
            stagedCount         = $null
            unstagedCount       = $null
            untrackedCount      = $null
            conflictedCount     = $null
            branchHead          = $null
            branchOid           = $null
            detached            = $null
            initial             = $null
            upstream            = $null
            upstreamRemote      = $null
            missingUpstream     = $null
            ahead               = $null
            behind              = $null
            unpushedCommitCount = $null
            diverged            = $null
        }
    }

    $remote = $null
    if (-not [string]::IsNullOrWhiteSpace($Upstream) -and $Upstream.Contains('/')) {
        $remote = $Upstream.Substring(0, $Upstream.IndexOf('/'))
    }

    $diverged = if ($null -ne $Ahead -and $null -ne $Behind) {
        ($Ahead -gt 0 -and $Behind -gt 0)
    }
    else {
        $null
    }

    return [pscustomobject][ordered]@{
        path                = $Path
        state               = 'inspected'
        reason              = $null
        clean               = (-not $Dirty)
        dirty               = $Dirty
        stagedCount         = $StagedCount
        unstagedCount       = $UnstagedCount
        untrackedCount      = $UntrackedCount
        conflictedCount     = $ConflictedCount
        branchHead          = $BranchHead
        branchOid           = 'synthetic-object-id-not-compared'
        detached            = $false
        initial             = $false
        upstream            = $Upstream
        upstreamRemote      = $remote
        missingUpstream     = (-not [string]::IsNullOrWhiteSpace($BranchHead) -and [string]::IsNullOrWhiteSpace($Upstream))
        ahead               = $Ahead
        behind              = $Behind
        unpushedCommitCount = $Ahead
        diverged            = $diverged
    }
}

function New-GitHealthProvider {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Repositories,
        [ValidateSet('success','partial','failed','unavailable','not-applicable')][string]$Status = 'success'
    )

    $evidence = @()
    for ($index = 0; $index -lt $Repositories.Count; $index++) {
        $evidence += [pscustomobject][ordered]@{
            evidenceId = "git.repository-health.repository.$index"
            type       = 'derived'
            source     = 'Synthetic normalized Git health'
            exitCode   = $null
            captured   = $null
            redacted   = $false
            attributes = [pscustomobject][ordered]@{
                repository = $Repositories[$index]
            }
        }
    }

    return [pscustomobject][ordered]@{
        providerId = 'git.repository-health'
        category   = 'git'
        status     = $Status
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @()
        warnings   = @()
        errors     = @()
        evidence   = @($evidence)
    }
}

function New-SyntheticBranch {
    param(
        [bool]$Stale = $false,
        [bool]$UpstreamGone = $false,
        [bool]$NamingDeviation = $false,
        [bool]$CleanupCandidate = $false
    )

    return [pscustomobject][ordered]@{
        name                     = 'synthetic-branch'
        upstream                 = 'origin/synthetic-branch'
        upstreamGone             = $UpstreamGone
        stale                    = $Stale
        namingDeviation          = $NamingDeviation
        advisoryCleanupCandidate = $CleanupCandidate
    }
}

function New-SyntheticWorktree {
    param(
        [bool]$IsMain = $true,
        [bool]$Dirty = $false,
        [bool]$Prunable = $false,
        [bool]$CleanupCandidate = $false,
        [string]$State = 'inspected'
    )

    return [pscustomobject][ordered]@{
        path                     = 'X:\Synthetic\worktree-path-not-compared'
        branch                   = 'synthetic-branch'
        isMainWorktree           = $IsMain
        dirty                    = $Dirty
        prunable                 = $Prunable
        advisoryCleanupCandidate = $CleanupCandidate
        state                    = $State
    }
}

function New-GitHygieneModel {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Branches,
        [Parameter(Mandatory)][object[]]$Worktrees
    )

    return [pscustomobject][ordered]@{
        path                    = $Path
        currentBranch           = 'main'
        detectedDefaultBranches = @('main')
        mergeTarget             = 'main'
        mergeTargetRef          = 'refs/heads/main'
        branchCount             = @($Branches).Count
        worktreeCount           = @($Worktrees).Count
        branches                = @($Branches)
        worktrees               = @($Worktrees)
    }
}

function New-GitHygieneProvider {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Repositories,
        [ValidateSet('success','partial','failed','unavailable','not-applicable')][string]$Status = 'success'
    )

    $evidence = @()
    for ($index = 0; $index -lt $Repositories.Count; $index++) {
        $evidence += [pscustomobject][ordered]@{
            evidenceId = "git.branch-worktree-hygiene.repository.$index"
            type       = 'derived'
            source     = 'Synthetic normalized branch/worktree hygiene'
            exitCode   = $null
            captured   = $null
            redacted   = $false
            attributes = [pscustomobject][ordered]@{
                repository = $Repositories[$index]
            }
        }
    }

    return [pscustomobject][ordered]@{
        providerId = 'git.branch-worktree-hygiene'
        category   = 'git'
        status     = $Status
        observedAt = '2026-09-24T12:00:00+00:00'
        components = @()
        warnings   = @()
        errors     = @()
        evidence   = @($evidence)
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

$referenceCandidates = @(
    (New-SyntheticCandidate -Path 'C:\Dev\Alpha' -RelativePath 'Alpha'),
    (New-SyntheticCandidate -Path 'C:\Dev\Beta' -RelativePath 'Beta'),
    (New-SyntheticCandidate -Path 'C:\Dev\Gamma' -RelativePath 'Gamma')
)
$targetCandidates = @(
    (New-SyntheticCandidate -Path 'D:\Projects\Alpha' -RelativePath 'Alpha'),
    (New-SyntheticCandidate -Path 'D:\Projects\Beta' -RelativePath 'Beta'),
    (New-SyntheticCandidate -Path 'D:\Projects\Gamma' -RelativePath 'Gamma')
)

$referenceHealth = @(
    (New-GitHealthModel -Path 'C:\Dev\Alpha' -State inspected -BranchHead main -Upstream 'origin/main' -Ahead 0 -Behind 0),
    (New-GitHealthModel -Path 'C:\Dev\Beta' -State inspected -BranchHead 'feat/local' -Upstream $null -Ahead $null -Behind $null),
    (New-GitHealthModel -Path 'C:\Dev\Gamma' -State unavailable)
)
$targetHealth = @(
    (New-GitHealthModel -Path 'D:\Projects\Alpha' -State inspected -Dirty $true -UnstagedCount 1 -BranchHead main -Upstream 'origin/main' -Ahead 2 -Behind 1),
    (New-GitHealthModel -Path 'D:\Projects\Beta' -State inspected -BranchHead 'feat/local' -Upstream 'origin/feat/local' -Ahead $null -Behind $null),
    (New-GitHealthModel -Path 'D:\Projects\Gamma' -State inspected -BranchHead main -Upstream 'origin/main' -Ahead 0 -Behind 0)
)

$referenceHygiene = @(
    (New-GitHygieneModel -Path 'C:\Dev\Alpha' -Branches @(
        (New-SyntheticBranch)
    ) -Worktrees @(
        (New-SyntheticWorktree -IsMain $true)
    ))
)
$targetHygiene = @(
    (New-GitHygieneModel -Path 'D:\Projects\Alpha' -Branches @(
        (New-SyntheticBranch),
        (New-SyntheticBranch -Stale $true -UpstreamGone $true -CleanupCandidate $true)
    ) -Worktrees @(
        (New-SyntheticWorktree -IsMain $true),
        (New-SyntheticWorktree -IsMain $false -Dirty $true)
    ))
)

$referenceProviders = @(
    (New-ProjectsLocalProvider -Candidates $referenceCandidates),
    (New-GitHealthProvider -Repositories $referenceHealth -Status partial),
    (New-GitHygieneProvider -Repositories $referenceHygiene),
    (New-SyntheticRuntimeProvider -Version '1.0.0')
)
$targetProviders = @(
    (New-ProjectsLocalProvider -Candidates $targetCandidates),
    (New-GitHealthProvider -Repositories $targetHealth),
    (New-GitHygieneProvider -Repositories $targetHygiene),
    (New-SyntheticRuntimeProvider -Version '2.0.0')
)

$referenceReport = New-SyntheticReport -Name reference -Providers $referenceProviders
$targetReport = New-SyntheticReport -Name target -Providers $targetProviders
$comparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport

$gitDifferences = @($comparison.differences | Where-Object category -eq 'git')

Assert-True ($gitDifferences.Count -eq 6) 'Primary Git comparison must emit exactly six Git-health differences.'
Assert-True (@($gitDifferences | Where-Object kind -eq 'inspection-state').Count -eq 1) 'Unavailable repository inspection must remain explicit.'
Assert-True (@($gitDifferences | Where-Object kind -eq 'branch-upstream').Count -eq 1) 'Missing/configured upstream state must be distinguishable.'
Assert-True (@($gitDifferences | Where-Object kind -eq 'divergence').Count -eq 1) 'Reliable ahead/behind divergence drift must be represented.'
Assert-True (@($gitDifferences | Where-Object kind -eq 'worktree-state').Count -eq 1) 'Clean/dirty working-tree drift must be summarized.'
Assert-True (@($gitDifferences | Where-Object kind -eq 'branch-hygiene').Count -eq 1) 'Branch hygiene drift must be summarized safely.'
Assert-True (@($gitDifferences | Where-Object kind -eq 'worktree-hygiene').Count -eq 1) 'Linked/extra worktree hygiene drift must be summarized safely.'

$inspectionDifference = @($gitDifferences | Where-Object kind -eq 'inspection-state')[0]
Assert-True ($inspectionDifference.relation -eq 'unavailable') 'Unavailable repository state must use unavailable relation semantics.'

$upstreamDifference = @($gitDifferences | Where-Object kind -eq 'branch-upstream')[0]
Assert-True ($upstreamDifference.referenceValue.missingUpstream -eq $true) 'Reference missing-upstream state must be preserved.'
Assert-True ($upstreamDifference.targetValue.upstreamConfigured -eq $true) 'Target configured-upstream state must be preserved.'

$divergenceDifference = @($gitDifferences | Where-Object kind -eq 'divergence')[0]
Assert-True ($divergenceDifference.referenceValue.ahead -eq 0 -and $divergenceDifference.referenceValue.behind -eq 0) 'Reference divergence counters must remain normalized.'
Assert-True ($divergenceDifference.targetValue.ahead -eq 2 -and $divergenceDifference.targetValue.behind -eq 1) 'Target divergence counters must remain normalized.'
Assert-True ($divergenceDifference.targetValue.diverged -eq $true) 'Target diverged state must be explicit.'

$worktreeState = @($gitDifferences | Where-Object kind -eq 'worktree-state')[0]
Assert-True ($worktreeState.referenceValue.clean -eq $true) 'Reference clean state must be preserved.'
Assert-True ($worktreeState.targetValue.dirty -eq $true -and $worktreeState.targetValue.unstagedCount -eq 1) 'Target dirty state must preserve safe aggregate counts.'

$worktreeHygiene = @($gitDifferences | Where-Object kind -eq 'worktree-hygiene')[0]
Assert-True ($worktreeHygiene.referenceValue.worktreeCount -eq 1) 'Reference worktree count must be preserved.'
Assert-True ($worktreeHygiene.targetValue.worktreeCount -eq 2) 'Extra target worktree must be represented.'
Assert-True ($worktreeHygiene.targetValue.dirtyLinkedWorktreeCount -eq 1) 'Dirty linked-worktree count must be represented without exposing its path.'

$gitJson = $gitDifferences | ConvertTo-Json -Depth 30 -Compress
foreach ($forbidden in @(
    'C:\Dev',
    'D:\Projects',
    'X:\Synthetic',
    'synthetic-object-id-not-compared',
    'worktree-path-not-compared'
)) {
    Assert-True ($gitJson -notmatch [Regex]::Escape($forbidden)) "Git comparison output must not expose path/object evidence '$forbidden'."
}

$firstJson = $comparison | ConvertTo-Json -Depth 30 -Compress
$secondJson = (New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport) | ConvertTo-Json -Depth 30 -Compress
Assert-True ($firstJson -eq $secondJson) 'Git comparison output must remain deterministic.'

$targetUnavailableProviders = @(
    (New-ProjectsLocalProvider -Candidates $targetCandidates),
    (New-GitHealthProvider -Repositories @() -Status unavailable),
    (New-GitHygieneProvider -Repositories @() -Status unavailable),
    (New-SyntheticRuntimeProvider -Version '2.0.0')
)
$unavailableTargetReport = New-SyntheticReport -Name target-unavailable -Providers $targetUnavailableProviders
$unavailableParameters = @{
    ReferenceReport = $referenceReport
    TargetReport    = $unavailableTargetReport
}
$unavailableComparison = New-WorkstationComparison @unavailableParameters

Assert-True (@($unavailableComparison.differences | Where-Object category -eq 'git').Count -eq 0) 'Unavailable Git providers must not fabricate specialized repository drift.'
Assert-True (@($unavailableComparison.differences | Where-Object { $_.providerId -eq 'runtime.synthetic' -and $_.category -eq 'version' }).Count -eq 1) 'Unavailable Git evidence must not block unrelated runtime comparison.'

$coreSource = Get-Content -LiteralPath $corePath -Raw
foreach ($required in @(
    'git.repository-health.repository.',
    'git.branch-worktree-hygiene.repository.',
    'branch-upstream',
    'divergence',
    'worktree-state',
    'worktree-hygiene'
)) {
    Assert-True ($coreSource -match [Regex]::Escape($required)) "Missing normalized Git comparison marker: $required"
}

foreach ($forbiddenOperation in @(
    'git fetch',
    'git pull',
    'git checkout',
    'git reset',
    'git clean',
    'git branch -D',
    'Invoke-ReadOnlyGit'
)) {
    Assert-True ($coreSource -notmatch [Regex]::Escape($forbiddenOperation)) "Comparison core must not execute Git operation marker: $forbiddenOperation"
}

Write-Host 'Git health comparison validation passed.'
