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
        providerId = 'git.repository-health'
        category   = 'git'
        order      = 43
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

function Get-PreviousProvider {
    param([Parameter(Mandatory)][string]$ProviderId)

    return @(
        @($Context.PreviousProviderResults) |
            Where-Object providerId -eq $ProviderId |
            Select-Object -First 1
    )[0]
}

function Invoke-ReadOnlyGit {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $allArguments = @('--no-optional-locks', '-C', $RepositoryPath) + @($Arguments)
    return Invoke-AuditCommand -Command 'git' -Arguments $allArguments -TimeoutSeconds 20 -MaximumCaptureLength 131072
}

function ConvertFrom-GitPorcelainV2 {
    param([AllowNull()][string]$Text)

    $branchOid = $null
    $branchHead = $null
    $upstream = $null
    $ahead = $null
    $behind = $null
    $stagedCount = 0
    $unstagedCount = 0
    $untrackedCount = 0
    $conflictedCount = 0

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $reader = [System.IO.StringReader]::new($Text)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                if ($line -match '^# branch\.oid (?<value>.+)$') {
                    $branchOid = $Matches.value
                    continue
                }

                if ($line -match '^# branch\.head (?<value>.+)$') {
                    $branchHead = $Matches.value
                    continue
                }

                if ($line -match '^# branch\.upstream (?<value>.+)$') {
                    $upstream = $Matches.value
                    continue
                }

                if ($line -match '^# branch\.ab \+(?<ahead>\d+) -(?<behind>\d+)$') {
                    $ahead = [int]$Matches.ahead
                    $behind = [int]$Matches.behind
                    continue
                }

                if ($line.StartsWith('? ')) {
                    $untrackedCount++
                    continue
                }

                if ($line.StartsWith('! ')) {
                    continue
                }

                if ($line -match '^(?<kind>[12u]) (?<xy>.{2}) ') {
                    $xy = [string]$Matches.xy

                    if ($Matches.kind -eq 'u') {
                        $conflictedCount++
                    }

                    if ($xy.Length -ge 2) {
                        if ($xy[0] -ne '.') {
                            $stagedCount++
                        }

                        if ($xy[1] -ne '.') {
                            $unstagedCount++
                        }
                    }
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }

    $detached = [string]::Equals([string]$branchHead, '(detached)', [StringComparison]::OrdinalIgnoreCase)
    $initial = [string]::Equals([string]$branchHead, '(initial)', [StringComparison]::OrdinalIgnoreCase)

    $remoteName = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$upstream)) {
        $slashIndex = $upstream.IndexOf('/')
        if ($slashIndex -gt 0) {
            $remoteName = $upstream.Substring(0, $slashIndex)
        }
    }

    $dirty = (
        $stagedCount -gt 0 -or
        $unstagedCount -gt 0 -or
        $untrackedCount -gt 0 -or
        $conflictedCount -gt 0
    )

    return [pscustomobject][ordered]@{
        branchOid       = $branchOid
        branchHead      = $branchHead
        detached        = $detached
        initial         = $initial
        upstream        = $upstream
        upstreamRemote  = $remoteName
        ahead           = $ahead
        behind          = $behind
        stagedCount     = $stagedCount
        unstagedCount   = $unstagedCount
        untrackedCount  = $untrackedCount
        conflictedCount = $conflictedCount
        dirty           = $dirty
        clean           = (-not $dirty)
    }
}

$projectsLocal = Get-PreviousProvider -ProviderId 'projects.local'

if ($null -eq $projectsLocal) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'git.repository-health.summary' -Type derived -Source 'projects.local dependency' -Captured $null -Attributes @{
        dependencyAvailable = $false
        repositoryCount = 0
        inspectedRepositoryCount = 0
        readOnly = $true
        usesOnlyDiscoveredRepositories = $true
        performsFilesystemTraversal = $false
        networkAccessRequired = $false
        fetchPerformed = $false
        pullPerformed = $false
        pushPerformed = $false
        checkoutPerformed = $false
        resetPerformed = $false
        cleanPerformed = $false
        stashPerformed = $false
        commitPerformed = $false
        gitConfigurationCollected = $false
        remoteUrlsCollected = $false
        credentialHelpersCollected = $false
        optionalLocksDisabled = $true
    }))

    return [pscustomobject][ordered]@{
        providerId = 'git.repository-health'
        category   = 'git'
        status     = Get-AuditProviderStatus -Unavailable
        observedAt = $Context.ObservedAt
        components = @()
        warnings   = @()
        errors     = @()
        evidence   = $evidence.ToArray()
    }
}

$discoveryEvidence = @(
    $projectsLocal.evidence |
        Where-Object evidenceId -eq 'projects.local.discovery' |
        Select-Object -First 1
)[0]

$candidates = if ($null -ne $discoveryEvidence) {
    @($discoveryEvidence.attributes.candidates)
}
else {
    @()
}

$repositories = @(
    $candidates |
        Where-Object {
            $_.repositoryMarker -eq $true -and
            -not [string]::IsNullOrWhiteSpace([string]$_.path)
        }
)

$repositoryModels = New-Object System.Collections.Generic.List[object]

for ($index = 0; $index -lt $repositories.Count; $index++) {
    $candidate = $repositories[$index]
    $repositoryPath = [string]$candidate.path
    $evidenceId = "git.repository-health.repository.$index"

    if (-not (Test-Path -LiteralPath $repositoryPath -PathType Container)) {
        $model = [pscustomobject][ordered]@{
            index = $index
            path = $repositoryPath
            state = 'unavailable'
            reason = 'repository-path-missing'
            clean = $null
            dirty = $null
            stagedCount = $null
            unstagedCount = $null
            untrackedCount = $null
            conflictedCount = $null
            branchHead = $null
            branchOid = $null
            detached = $null
            initial = $null
            upstream = $null
            upstreamRemote = $null
            missingUpstream = $null
            ahead = $null
            behind = $null
            unpushedCommitCount = $null
            diverged = $null
        }

        $repositoryModels.Add($model)
        $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type derived -Source 'projects.local repository candidate' -Captured $null -Attributes @{
            repository = $model
        }))
        $warnings.Add((New-AuditIssue -Code 'GIT_REPOSITORY_PATH_UNAVAILABLE' -Message "Discovered repository index $index is no longer available for inspection." -Severity warning -EvidenceIds @($evidenceId)))
        continue
    }

    $statusResult = Invoke-ReadOnlyGit -RepositoryPath $repositoryPath -Arguments @(
        'status',
        '--porcelain=v2',
        '--branch',
        '--untracked-files=normal'
    )

    if ($statusResult.Status -ne 'success') {
        $model = [pscustomobject][ordered]@{
            index = $index
            path = $repositoryPath
            state = 'unavailable'
            reason = 'git-status-unavailable'
            clean = $null
            dirty = $null
            stagedCount = $null
            unstagedCount = $null
            untrackedCount = $null
            conflictedCount = $null
            branchHead = $null
            branchOid = $null
            detached = $null
            initial = $null
            upstream = $null
            upstreamRemote = $null
            missingUpstream = $null
            ahead = $null
            behind = $null
            unpushedCommitCount = $null
            diverged = $null
        }

        $repositoryModels.Add($model)
        $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type command -Source 'git --no-optional-locks status --porcelain=v2 --branch --untracked-files=normal' -ExitCode $statusResult.ExitCode -Captured $null -Attributes @{
            repository = $model
            commandStatus = $statusResult.Status
            timedOut = $statusResult.TimedOut
            optionalLocksDisabled = $true
        }))
        $warnings.Add((New-AuditIssue -Code 'GIT_REPOSITORY_STATUS_UNAVAILABLE' -Message "Git repository index $index could not be inspected with read-only porcelain status." -Severity warning -EvidenceIds @($evidenceId)))
        continue
    }

    $parsed = ConvertFrom-GitPorcelainV2 -Text $statusResult.Captured
    $missingUpstream = (
        -not $parsed.detached -and
        -not $parsed.initial -and
        [string]::IsNullOrWhiteSpace([string]$parsed.upstream)
    )

    $unpushedCommitCount = if ($null -ne $parsed.ahead) { [int]$parsed.ahead } else { $null }
    $diverged = if ($null -ne $parsed.ahead -and $null -ne $parsed.behind) {
        ($parsed.ahead -gt 0 -and $parsed.behind -gt 0)
    }
    else {
        $null
    }

    $model = [pscustomobject][ordered]@{
        index = $index
        path = $repositoryPath
        state = 'inspected'
        reason = $null
        clean = $parsed.clean
        dirty = $parsed.dirty
        stagedCount = $parsed.stagedCount
        unstagedCount = $parsed.unstagedCount
        untrackedCount = $parsed.untrackedCount
        conflictedCount = $parsed.conflictedCount
        branchHead = $parsed.branchHead
        branchOid = $parsed.branchOid
        detached = $parsed.detached
        initial = $parsed.initial
        upstream = $parsed.upstream
        upstreamRemote = $parsed.upstreamRemote
        missingUpstream = $missingUpstream
        ahead = $parsed.ahead
        behind = $parsed.behind
        unpushedCommitCount = $unpushedCommitCount
        diverged = $diverged
    }

    $repositoryModels.Add($model)
    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type command -Source 'git --no-optional-locks status --porcelain=v2 --branch --untracked-files=normal' -ExitCode $statusResult.ExitCode -Captured $null -Attributes @{
        repository = $model
        commandStatus = $statusResult.Status
        optionalLocksDisabled = $true
        rawStatusRetained = $false
        remoteUrlCollected = $false
    }))

    if ($parsed.dirty) {
        $warnings.Add((New-AuditIssue -Code 'GIT_WORKTREE_DIRTY' -Message "Repository index $index has local working-tree changes." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($parsed.detached) {
        $warnings.Add((New-AuditIssue -Code 'GIT_DETACHED_HEAD' -Message "Repository index $index is in detached HEAD state." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($missingUpstream) {
        $warnings.Add((New-AuditIssue -Code 'GIT_UPSTREAM_MISSING' -Message "Repository index $index has no configured upstream for its current branch." -Severity info -EvidenceIds @($evidenceId)))
    }

    if ($null -ne $parsed.ahead -and $parsed.ahead -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'GIT_UNPUSHED_COMMITS' -Message "Repository index $index is ahead of its locally known upstream by $($parsed.ahead) commit(s)." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($null -ne $diverged -and $diverged) {
        $warnings.Add((New-AuditIssue -Code 'GIT_BRANCH_DIVERGED' -Message "Repository index $index has both ahead and behind commits relative to its locally known upstream." -Severity warning -EvidenceIds @($evidenceId)))
    }
}

$inspectedRepositories = @($repositoryModels | Where-Object state -eq 'inspected')
$unpushedMeasure = @(
    $inspectedRepositories |
        Where-Object { $null -ne $_.unpushedCommitCount } |
        Measure-Object -Property unpushedCommitCount -Sum
)

$summaryEvidenceId = 'git.repository-health.summary'
$evidence.Add((New-AuditEvidence -EvidenceId $summaryEvidenceId -Type derived -Source 'projects.local repository candidates' -Captured $null -Attributes @{
    dependencyAvailable = $true
    repositoryCount = $repositories.Count
    inspectedRepositoryCount = $inspectedRepositories.Count
    unavailableRepositoryCount = @($repositoryModels | Where-Object state -eq 'unavailable').Count
    cleanRepositoryCount = @($inspectedRepositories | Where-Object clean).Count
    dirtyRepositoryCount = @($inspectedRepositories | Where-Object dirty).Count
    detachedRepositoryCount = @($inspectedRepositories | Where-Object detached).Count
    missingUpstreamRepositoryCount = @($inspectedRepositories | Where-Object missingUpstream).Count
    aheadRepositoryCount = @($inspectedRepositories | Where-Object { $null -ne $_.ahead -and $_.ahead -gt 0 }).Count
    behindRepositoryCount = @($inspectedRepositories | Where-Object { $null -ne $_.behind -and $_.behind -gt 0 }).Count
    divergedRepositoryCount = @($inspectedRepositories | Where-Object { $_.diverged -eq $true }).Count
    unpushedCommitCount = $(if ($unpushedMeasure.Count -gt 0 -and $null -ne $unpushedMeasure[0].Sum) { [int]$unpushedMeasure[0].Sum } else { 0 })
    readOnly = $true
    usesOnlyDiscoveredRepositories = $true
    performsFilesystemTraversal = $false
    networkAccessRequired = $false
    fetchPerformed = $false
    pullPerformed = $false
    pushPerformed = $false
    checkoutPerformed = $false
    resetPerformed = $false
    cleanPerformed = $false
    stashPerformed = $false
    commitPerformed = $false
    gitConfigurationCollected = $false
    remoteUrlsCollected = $false
    credentialHelpersCollected = $false
    optionalLocksDisabled = $true
}))

$status = if ($repositories.Count -eq 0) {
    Get-AuditProviderStatus -NotApplicable
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray()
}

return [pscustomobject][ordered]@{
    providerId = 'git.repository-health'
    category   = 'git'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
