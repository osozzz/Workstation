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
        providerId = 'git.branch-worktree-hygiene'
        category   = 'git'
        order      = 44
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

$allowedBranchPrefixes = @(
    'feat/',
    'fix/',
    'docs/',
    'test/',
    'refactor/',
    'chore/',
    'ci/',
    'build/',
    'perf/',
    'security/'
)

function Get-PreviousProvider {
    param([Parameter(Mandatory)][string]$ProviderId)

    $matches = @(
        @($Context.PreviousProviderResults) |
            Where-Object providerId -eq $ProviderId |
            Select-Object -First 1
    )

    if ($matches.Count -gt 0) {
        return $matches[0]
    }

    return $null
}

function Invoke-ReadOnlyGit {
    param(
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $allArguments = @('--no-optional-locks', '-C', $RepositoryPath) + @($Arguments)
    return Invoke-AuditCommand -Command 'git' -Arguments $allArguments -TimeoutSeconds 20 -MaximumCaptureLength 262144
}

function Get-GitLines {
    param([AllowNull()][string]$Text)

    $lines = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    $reader = [System.IO.StringReader]::new($Text)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $lines.Add($line)
        }
    }
    finally {
        $reader.Dispose()
    }

    return $lines.ToArray()
}

function ConvertFrom-BranchInventory {
    param([AllowNull()][string]$Text)

    $branches = New-Object System.Collections.Generic.List[object]
    $separator = [string][char]9

    foreach ($line in @(Get-GitLines -Text $Text)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = @($line -split $separator, 5)
        if ($parts.Count -lt 3) {
            continue
        }

        [long]$committerUnix = 0
        $hasCommitTime = [long]::TryParse([string]$parts[2], [ref]$committerUnix)

        $branches.Add([pscustomobject][ordered]@{
            name            = [string]$parts[0]
            objectId        = [string]$parts[1]
            committerUnix   = $(if ($hasCommitTime) { $committerUnix } else { $null })
            upstream        = $(if ($parts.Count -ge 4 -and -not [string]::IsNullOrWhiteSpace([string]$parts[3])) { [string]$parts[3] } else { $null })
            upstreamTrack   = $(if ($parts.Count -ge 5 -and -not [string]::IsNullOrWhiteSpace([string]$parts[4])) { [string]$parts[4] } else { $null })
        })
    }

    return $branches.ToArray()
}

function ConvertFrom-WorktreePorcelain {
    param([AllowNull()][string]$Text)

    $worktrees = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in @((Get-GitLines -Text $Text) + @(''))) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($null -ne $current) {
                $worktrees.Add([pscustomobject]$current)
                $current = $null
            }
            continue
        }

        if ($line.StartsWith('worktree ')) {
            if ($null -ne $current) {
                $worktrees.Add([pscustomobject]$current)
            }

            $current = [ordered]@{
                path       = $line.Substring(9)
                head       = $null
                branch     = $null
                detached   = $false
                bare       = $false
                locked     = $false
                prunable   = $false
            }
            continue
        }

        if ($null -eq $current) {
            continue
        }

        if ($line.StartsWith('HEAD ')) {
            $current.head = $line.Substring(5)
            continue
        }

        if ($line.StartsWith('branch refs/heads/')) {
            $current.branch = $line.Substring(18)
            continue
        }

        if ($line -eq 'detached') {
            $current.detached = $true
            continue
        }

        if ($line -eq 'bare') {
            $current.bare = $true
            continue
        }

        if ($line.StartsWith('locked')) {
            $current.locked = $true
            continue
        }

        if ($line.StartsWith('prunable')) {
            $current.prunable = $true
        }
    }

    return $worktrees.ToArray()
}

function Get-WorktreeState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject][ordered]@{
            state          = 'missing'
            dirty          = $null
            stagedCount    = $null
            unstagedCount  = $null
            untrackedCount = $null
        }
    }

    $status = Invoke-ReadOnlyGit -RepositoryPath $Path -Arguments @(
        'status',
        '--porcelain=v2',
        '--untracked-files=normal'
    )

    if ($status.Status -ne 'success') {
        return [pscustomobject][ordered]@{
            state          = 'unavailable'
            dirty          = $null
            stagedCount    = $null
            unstagedCount  = $null
            untrackedCount = $null
        }
    }

    $staged = 0
    $unstaged = 0
    $untracked = 0

    foreach ($line in @(Get-GitLines -Text $status.Captured)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith('! ')) {
            continue
        }

        if ($line.StartsWith('? ')) {
            $untracked++
            continue
        }

        if ($line -match '^[12u] (?<xy>.{2}) ') {
            $xy = [string]$Matches.xy
            if ($xy.Length -ge 2) {
                if ($xy[0] -ne '.') {
                    $staged++
                }
                if ($xy[1] -ne '.') {
                    $unstaged++
                }
            }
        }
    }

    $dirty = ($staged -gt 0 -or $unstaged -gt 0 -or $untracked -gt 0)

    return [pscustomobject][ordered]@{
        state          = 'inspected'
        dirty          = $dirty
        stagedCount    = $staged
        unstagedCount  = $unstaged
        untrackedCount = $untracked
    }
}

function Test-AllowedBranchName {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($prefix in $allowedBranchPrefixes) {
        if ($Name.StartsWith($prefix, [StringComparison]::Ordinal)) {
            return $true
        }
    }

    return $false
}

$gitHealth = Get-PreviousProvider -ProviderId 'git.repository-health'
$staleDays = 90

$staleProperty = $Context.PSObject.Properties['GitBranchStaleDays']
if ($staleProperty -and $null -ne $staleProperty.Value) {
    [int]$parsedStaleDays = 0
    if ([int]::TryParse($staleProperty.Value.ToString(), [ref]$parsedStaleDays) -and $parsedStaleDays -ge 1 -and $parsedStaleDays -le 3650) {
        $staleDays = $parsedStaleDays
    }
}

try {
    $observedAt = [DateTimeOffset]::Parse([string]$Context.ObservedAt)
}
catch {
    $observedAt = [DateTimeOffset]::Now
}

if ($null -eq $gitHealth) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'git.branch-worktree-hygiene.summary' -Type derived -Source 'git.repository-health dependency' -Captured $null -Attributes @{
        dependencyAvailable = $false
        repositoryCount = 0
        staleThresholdDays = $staleDays
        readOnly = $true
        reusesRepositoryHealth = $true
        independentRepositoryDiscovery = $false
        networkAccessRequired = $false
        branchDeletionPerformed = $false
        worktreePrunePerformed = $false
        worktreeRemovePerformed = $false
        checkoutPerformed = $false
        resetPerformed = $false
        historyRewritePerformed = $false
        gitConfigurationModified = $false
        remoteUrlsCollected = $false
        credentialHelpersCollected = $false
        optionalLocksDisabled = $true
        advisoryOnly = $true
    }))

    return [pscustomobject][ordered]@{
        providerId = 'git.branch-worktree-hygiene'
        category   = 'git'
        status     = Get-AuditProviderStatus -Unavailable
        observedAt = $Context.ObservedAt
        components = @()
        warnings   = @()
        errors     = @()
        evidence   = $evidence.ToArray()
    }
}

$repositoryEvidence = @(
    $gitHealth.evidence |
        Where-Object { $_.evidenceId -match '^git\.repository-health\.repository\.\d+$' } |
        Where-Object { $_.attributes.repository.state -eq 'inspected' }
)

$repositoryModels = New-Object System.Collections.Generic.List[object]

for ($repositoryIndex = 0; $repositoryIndex -lt $repositoryEvidence.Count; $repositoryIndex++) {
    $healthEvidence = $repositoryEvidence[$repositoryIndex]
    $repositoryPath = [string]$healthEvidence.attributes.repository.path
    $currentBranch = [string]$healthEvidence.attributes.repository.branchHead
    $repositoryEvidenceId = "git.branch-worktree-hygiene.repository.$repositoryIndex"

    if ([string]::IsNullOrWhiteSpace($repositoryPath) -or -not (Test-Path -LiteralPath $repositoryPath -PathType Container)) {
        continue
    }

    $branchResult = Invoke-ReadOnlyGit -RepositoryPath $repositoryPath -Arguments @(
        'for-each-ref',
        '--format=%(refname:short)%09%(objectname)%09%(committerdate:unix)%09%(upstream:short)%09%(upstream:track)',
        'refs/heads'
    )

    $worktreeResult = Invoke-ReadOnlyGit -RepositoryPath $repositoryPath -Arguments @(
        'worktree',
        'list',
        '--porcelain'
    )

    $defaultResult = Invoke-ReadOnlyGit -RepositoryPath $repositoryPath -Arguments @(
        'for-each-ref',
        '--format=%(symref:short)',
        'refs/remotes/*/HEAD'
    )

    if ($branchResult.Status -ne 'success' -or $worktreeResult.Status -ne 'success') {
        $warnings.Add((New-AuditIssue -Code 'GIT_HYGIENE_METADATA_UNAVAILABLE' -Message "Repository index $repositoryIndex could not provide branch/worktree metadata using read-only Git commands." -Severity warning -EvidenceIds @()))
        continue
    }

    $branches = @(ConvertFrom-BranchInventory -Text $branchResult.Captured)
    $worktreesRaw = @(ConvertFrom-WorktreePorcelain -Text $worktreeResult.Captured)

    $defaultBranchNames = New-Object System.Collections.Generic.List[string]
    if ($defaultResult.Status -eq 'success') {
        foreach ($line in @(Get-GitLines -Text $defaultResult.Captured)) {
            $value = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $slash = $value.IndexOf('/')
            if ($slash -gt 0 -and $slash -lt ($value.Length - 1)) {
                $localName = $value.Substring($slash + 1)
                if (-not $defaultBranchNames.Contains($localName)) {
                    $defaultBranchNames.Add($localName)
                }
            }
        }
    }

    $localBranchNames = @($branches | ForEach-Object name)
    $mergeTargetName = $null

    foreach ($candidateName in $defaultBranchNames) {
        if ($localBranchNames -contains $candidateName) {
            $mergeTargetName = $candidateName
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($mergeTargetName) -and $localBranchNames -contains 'main') {
        $mergeTargetName = 'main'
    }

    if ([string]::IsNullOrWhiteSpace($mergeTargetName) -and $localBranchNames -contains 'master') {
        $mergeTargetName = 'master'
    }

    if (
        [string]::IsNullOrWhiteSpace($mergeTargetName) -and
        -not [string]::IsNullOrWhiteSpace($currentBranch) -and
        $currentBranch -notin @('(detached)', '(initial)') -and
        $localBranchNames -contains $currentBranch
    ) {
        $mergeTargetName = $currentBranch
    }

    $mergeTargetRef = if ([string]::IsNullOrWhiteSpace($mergeTargetName)) {
        'HEAD'
    }
    else {
        "refs/heads/$mergeTargetName"
    }

    $mergedResult = Invoke-ReadOnlyGit -RepositoryPath $repositoryPath -Arguments @(
        'for-each-ref',
        "--merged=$mergeTargetRef",
        '--format=%(refname:short)',
        'refs/heads'
    )

    $mergedNames = @{}
    if ($mergedResult.Status -eq 'success') {
        foreach ($line in @(Get-GitLines -Text $mergedResult.Captured)) {
            $name = $line.Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $mergedNames[$name] = $true
            }
        }
    }

    $worktreeModels = New-Object System.Collections.Generic.List[object]
    $checkedOutBranches = @{}

    for ($worktreeIndex = 0; $worktreeIndex -lt $worktreesRaw.Count; $worktreeIndex++) {
        $worktree = $worktreesRaw[$worktreeIndex]
        $isMainWorktree = ($worktreeIndex -eq 0)

        if (-not [string]::IsNullOrWhiteSpace([string]$worktree.branch)) {
            $checkedOutBranches[[string]$worktree.branch] = $true
        }

        $state = Get-WorktreeState -Path ([string]$worktree.path)
        $cleanupCandidate = (
            $worktree.prunable -eq $true -and
            $worktree.locked -ne $true -and
            -not $isMainWorktree
        )

        $worktreeModels.Add([pscustomobject][ordered]@{
            index = $worktreeIndex
            path = [string]$worktree.path
            branch = $worktree.branch
            head = $worktree.head
            detached = [bool]$worktree.detached
            bare = [bool]$worktree.bare
            locked = [bool]$worktree.locked
            prunable = [bool]$worktree.prunable
            isMainWorktree = $isMainWorktree
            state = $state.state
            dirty = $state.dirty
            stagedCount = $state.stagedCount
            unstagedCount = $state.unstagedCount
            untrackedCount = $state.untrackedCount
            advisoryCleanupCandidate = $cleanupCandidate
            cleanupCriterion = $(if ($cleanupCandidate) { 'git-reports-prunable-and-worktree-is-not-main-or-locked' } else { $null })
        })
    }

    $branchModels = New-Object System.Collections.Generic.List[object]

    foreach ($branch in $branches) {
        $name = [string]$branch.name
        $ageDays = $null

        if ($null -ne $branch.committerUnix) {
            try {
                $tipTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$branch.committerUnix)
                $calculatedAge = [Math]::Floor(($observedAt - $tipTime).TotalDays)
                if ($calculatedAge -lt 0) {
                    $calculatedAge = 0
                }
                $ageDays = [int]$calculatedAge
            }
            catch {
                $ageDays = $null
            }
        }

        $isCurrent = (-not [string]::IsNullOrWhiteSpace($currentBranch) -and $name -eq $currentBranch)
        $isDefault = ($defaultBranchNames -contains $name)
        $isConventionalPermanent = ($name -in @('main', 'master'))
        $checkedOutInWorktree = $checkedOutBranches.ContainsKey($name)
        $isProtected = ($isCurrent -or $isDefault -or $isConventionalPermanent -or $checkedOutInWorktree)
        $isMerged = $mergedNames.ContainsKey($name)
        $isStale = ($null -ne $ageDays -and $ageDays -ge $staleDays)
        $upstreamGone = (-not [string]::IsNullOrWhiteSpace([string]$branch.upstreamTrack) -and [string]$branch.upstreamTrack -match '\[gone\]')
        $namingDeviation = (-not $isProtected -and -not (Test-AllowedBranchName -Name $name))
        $cleanupCandidate = ($isMerged -and -not $isProtected)

        $protectedReasons = New-Object System.Collections.Generic.List[string]
        if ($isCurrent) { $protectedReasons.Add('current-branch') }
        if ($isDefault) { $protectedReasons.Add('detected-default-branch') }
        if ($isConventionalPermanent) { $protectedReasons.Add('conventional-permanent-branch') }
        if ($checkedOutInWorktree) { $protectedReasons.Add('checked-out-in-worktree') }

        $branchModel = [pscustomobject][ordered]@{
            name = $name
            objectId = $branch.objectId
            upstream = $branch.upstream
            upstreamGone = $upstreamGone
            upstreamTrack = $branch.upstreamTrack
            tipCommitAgeDays = $ageDays
            staleThresholdDays = $staleDays
            stale = $isStale
            mergedInto = $mergeTargetName
            merged = $isMerged
            current = $isCurrent
            default = $isDefault
            checkedOutInWorktree = $checkedOutInWorktree
            protected = $isProtected
            protectedReasons = $protectedReasons.ToArray()
            namingPolicy = 'workstation-governance'
            namingDeviation = $namingDeviation
            advisoryCleanupCandidate = $cleanupCandidate
            cleanupCriterion = $(if ($cleanupCandidate) { 'locally-merged-and-not-current-default-permanent-or-worktree-checked-out' } else { $null })
        }

        $branchModels.Add($branchModel)
    }

    $repositoryModel = [pscustomobject][ordered]@{
        index = $repositoryIndex
        path = $repositoryPath
        currentBranch = $currentBranch
        detectedDefaultBranches = $defaultBranchNames.ToArray()
        mergeTarget = $mergeTargetName
        mergeTargetRef = $mergeTargetRef
        branchCount = $branchModels.Count
        worktreeCount = $worktreeModels.Count
        branches = $branchModels.ToArray()
        worktrees = $worktreeModels.ToArray()
    }

    $repositoryModels.Add($repositoryModel)

    $evidence.Add((New-AuditEvidence -EvidenceId $repositoryEvidenceId -Type command -Source 'Read-only local Git refs and worktree metadata' -Captured $null -Attributes @{
        repository = $repositoryModel
        branchInventoryCommand = 'git --no-optional-locks for-each-ref refs/heads'
        worktreeInventoryCommand = 'git --no-optional-locks worktree list --porcelain'
        mergedBranchCommand = 'git --no-optional-locks for-each-ref --merged=<local-ref> refs/heads'
        optionalLocksDisabled = $true
        rawCommandOutputRetained = $false
        remoteUrlsCollected = $false
    }))

    foreach ($branchModel in $branchModels) {
        if ($branchModel.advisoryCleanupCandidate) {
            $warnings.Add((New-AuditIssue -Code 'GIT_BRANCH_MERGED_CANDIDATE' -Message "Repository index $repositoryIndex branch '$($branchModel.name)' is locally merged into '$mergeTargetName' and is an advisory cleanup candidate." -Severity info -EvidenceIds @($repositoryEvidenceId)))
        }

        if ($branchModel.upstreamGone) {
            $warnings.Add((New-AuditIssue -Code 'GIT_BRANCH_UPSTREAM_GONE' -Message "Repository index $repositoryIndex branch '$($branchModel.name)' tracks an upstream ref that is locally known as gone." -Severity warning -EvidenceIds @($repositoryEvidenceId)))
        }

        if ($branchModel.stale) {
            $warnings.Add((New-AuditIssue -Code 'GIT_BRANCH_STALE' -Message "Repository index $repositoryIndex branch '$($branchModel.name)' tip is $($branchModel.tipCommitAgeDays) day(s) old, meeting the configured stale threshold of $staleDays day(s)." -Severity info -EvidenceIds @($repositoryEvidenceId)))
        }

        if ($branchModel.namingDeviation) {
            $warnings.Add((New-AuditIssue -Code 'GIT_BRANCH_NAMING_DEVIATION' -Message "Repository index $repositoryIndex branch '$($branchModel.name)' does not match the documented Workstation branch-prefix policy." -Severity info -EvidenceIds @($repositoryEvidenceId)))
        }
    }

    foreach ($worktreeModel in $worktreeModels) {
        if ($worktreeModel.prunable) {
            $warnings.Add((New-AuditIssue -Code 'GIT_WORKTREE_PRUNABLE' -Message "Repository index $repositoryIndex worktree index $($worktreeModel.index) is reported as prunable by Git metadata. No prune action was performed." -Severity warning -EvidenceIds @($repositoryEvidenceId)))
        }

        if ($worktreeModel.dirty -eq $true -and -not $worktreeModel.isMainWorktree) {
            $warnings.Add((New-AuditIssue -Code 'GIT_LINKED_WORKTREE_DIRTY' -Message "Repository index $repositoryIndex linked worktree index $($worktreeModel.index) has local changes." -Severity warning -EvidenceIds @($repositoryEvidenceId)))
        }
    }
}

$allBranches = @($repositoryModels | ForEach-Object { @($_.branches) })
$allWorktrees = @($repositoryModels | ForEach-Object { @($_.worktrees) })

$summaryEvidenceId = 'git.branch-worktree-hygiene.summary'
$evidence.Add((New-AuditEvidence -EvidenceId $summaryEvidenceId -Type derived -Source 'git.repository-health plus local Git refs/worktree metadata' -Captured $null -Attributes @{
    dependencyAvailable = $true
    repositoryCount = $repositoryModels.Count
    branchCount = $allBranches.Count
    staleBranchCount = @($allBranches | Where-Object stale).Count
    mergedCleanupCandidateCount = @($allBranches | Where-Object advisoryCleanupCandidate).Count
    goneUpstreamBranchCount = @($allBranches | Where-Object upstreamGone).Count
    namingDeviationCount = @($allBranches | Where-Object namingDeviation).Count
    worktreeCount = $allWorktrees.Count
    linkedWorktreeCount = @($allWorktrees | Where-Object { -not $_.isMainWorktree }).Count
    dirtyLinkedWorktreeCount = @($allWorktrees | Where-Object { -not $_.isMainWorktree -and $_.dirty -eq $true }).Count
    prunableWorktreeCount = @($allWorktrees | Where-Object prunable).Count
    worktreeCleanupCandidateCount = @($allWorktrees | Where-Object advisoryCleanupCandidate).Count
    staleThresholdDays = $staleDays
    allowedBranchPrefixes = $allowedBranchPrefixes
    readOnly = $true
    reusesRepositoryHealth = $true
    independentRepositoryDiscovery = $false
    defaultBranchDetectionUsesLocalRefsOnly = $true
    networkAccessRequired = $false
    branchDeletionPerformed = $false
    worktreePrunePerformed = $false
    worktreeRemovePerformed = $false
    checkoutPerformed = $false
    resetPerformed = $false
    historyRewritePerformed = $false
    gitConfigurationModified = $false
    remoteUrlsCollected = $false
    credentialHelpersCollected = $false
    optionalLocksDisabled = $true
    advisoryOnly = $true
}))

$status = if ($repositoryModels.Count -eq 0) {
    Get-AuditProviderStatus -NotApplicable
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray()
}

return [pscustomobject][ordered]@{
    providerId = 'git.branch-worktree-hygiene'
    category   = 'git'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
