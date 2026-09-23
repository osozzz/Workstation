[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$providerPath = Join-Path $root 'scripts\Providers\GitBranchWorktreeHygiene.Provider.ps1'

$tempBase = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $env:RUNNER_TEMP
}
else {
    [IO.Path]::GetTempPath()
}

$tempRoot = Join-Path $tempBase "workstation-git-hygiene-$([guid]::NewGuid().ToString('N'))"
$repositoryPath = Join-Path $tempRoot 'repository'
$remotePath = Join-Path $tempRoot 'remote.git'
$linkedWorktreePath = Join-Path $tempRoot 'linked-worktree'
$prunableWorktreePath = Join-Path $tempRoot 'prunable-worktree'

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & git -C $WorkingDirectory @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Git setup command failed in '$WorkingDirectory': git $($Arguments -join ' ') | $($output -join ' ')"
    }

    return @($output)
}

function New-Commit {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][string]$CommitDate = $null
    )

    Set-Content -LiteralPath (Join-Path $Repository $FileName) -Value $Content -Encoding UTF8
    Invoke-Git -WorkingDirectory $Repository -Arguments @('add', $FileName) | Out-Null

    $oldAuthorDate = $env:GIT_AUTHOR_DATE
    $oldCommitterDate = $env:GIT_COMMITTER_DATE

    try {
        if (-not [string]::IsNullOrWhiteSpace($CommitDate)) {
            $env:GIT_AUTHOR_DATE = $CommitDate
            $env:GIT_COMMITTER_DATE = $CommitDate
        }

        Invoke-Git -WorkingDirectory $Repository -Arguments @('commit', '-m', $Message) | Out-Null
    }
    finally {
        $env:GIT_AUTHOR_DATE = $oldAuthorDate
        $env:GIT_COMMITTER_DATE = $oldCommitterDate
    }
}

function Get-RepositoryEvidence {
    param([Parameter(Mandatory)][object]$Result)

    return @(
        $Result.evidence |
            Where-Object { $_.evidenceId -match '^git\.branch-worktree-hygiene\.repository\.\d+$' } |
            Select-Object -First 1
    )[0]
}

try {
    New-Item -ItemType Directory -Path $repositoryPath -Force | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('init') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('config', 'user.name', 'Synthetic Workstation Test') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('config', 'user.email', 'synthetic@example.invalid') | Out-Null

    New-Commit -Repository $repositoryPath -FileName 'baseline.txt' -Content 'baseline' -Message 'initial'
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('branch', '-M', 'main') | Out-Null

    New-Item -ItemType Directory -Path $remotePath -Force | Out-Null
    $bareOutput = & git -C $remotePath init --bare 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not initialize synthetic bare remote: $($bareOutput -join ' ')"
    }

    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('remote', 'add', 'origin', $remotePath) | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('push', '-u', 'origin', 'main') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('remote', 'set-head', 'origin', 'main') | Out-Null

    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('switch', '-c', 'feat/merged') | Out-Null
    New-Commit -Repository $repositoryPath -FileName 'merged.txt' -Content 'merged' -Message 'merged branch commit'
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('switch', 'main') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('merge', '--no-ff', 'feat/merged', '-m', 'merge feat/merged') | Out-Null

    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('switch', '-c', 'feat/unmerged') | Out-Null
    New-Commit -Repository $repositoryPath -FileName 'unmerged.txt' -Content 'unmerged' -Message 'unmerged branch commit'
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('switch', 'main') | Out-Null

    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('switch', '-c', 'feat/stale') | Out-Null
    New-Commit -Repository $repositoryPath -FileName 'stale.txt' -Content 'stale' -Message 'stale branch commit' -CommitDate '2024-01-15T00:00:00Z'
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('switch', 'main') | Out-Null

    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('switch', '-c', 'feat/gone') | Out-Null
    New-Commit -Repository $repositoryPath -FileName 'gone.txt' -Content 'gone' -Message 'gone upstream branch commit'
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('push', '-u', 'origin', 'feat/gone') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('switch', 'main') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('push', 'origin', '--delete', 'feat/gone') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('fetch', '--prune', 'origin') | Out-Null

    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('branch', 'scratch-bad-name', 'main') | Out-Null

    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('branch', 'feat/worktree', 'main') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('worktree', 'add', $linkedWorktreePath, 'feat/worktree') | Out-Null
    Set-Content -LiteralPath (Join-Path $linkedWorktreePath 'linked-dirty.txt') -Value 'dirty' -Encoding UTF8

    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('branch', 'feat/prunable', 'main') | Out-Null
    Invoke-Git -WorkingDirectory $repositoryPath -Arguments @('worktree', 'add', $prunableWorktreePath, 'feat/prunable') | Out-Null
    Remove-Item -LiteralPath $prunableWorktreePath -Recurse -Force

    $healthRepositoryModel = [pscustomobject][ordered]@{
        index = 0
        path = $repositoryPath
        state = 'inspected'
        branchHead = 'main'
    }

    $gitHealth = [pscustomobject][ordered]@{
        providerId = 'git.repository-health'
        category = 'git'
        status = 'success'
        observedAt = (Get-Date).ToString('o')
        components = @()
        warnings = @()
        errors = @()
        evidence = @(
            [pscustomobject][ordered]@{
                evidenceId = 'git.repository-health.repository.0'
                type = 'command'
                source = 'synthetic'
                exitCode = 0
                captured = $null
                redacted = $false
                attributes = [pscustomobject][ordered]@{
                    repository = $healthRepositoryModel
                }
            }
        )
    }

    $context = [pscustomobject][ordered]@{
        ObservedAt = '2026-09-23T13:00:00+00:00'
        GitBranchStaleDays = 90
        PreviousProviderResults = @($gitHealth)
    }

    $result = & $providerPath -Context $context

    if ($result.providerId -ne 'git.branch-worktree-hygiene' -or $result.category -ne 'git') {
        throw 'Unexpected Git branch/worktree hygiene provider identity.'
    }

    if (@($result.components).Count -ne 0) {
        throw 'git.branch-worktree-hygiene must remain evidence-only.'
    }

    $summary = @(
        $result.evidence |
            Where-Object evidenceId -eq 'git.branch-worktree-hygiene.summary' |
            Select-Object -First 1
    )[0]

    $repositoryEvidence = Get-RepositoryEvidence -Result $result

    if ($null -eq $summary -or $null -eq $repositoryEvidence) {
        throw 'Missing Git hygiene summary/repository evidence.'
    }

    $repository = $repositoryEvidence.attributes.repository
    $branches = @($repository.branches)
    $worktrees = @($repository.worktrees)

    function Get-BranchModel([string]$Name) {
        return @($branches | Where-Object name -eq $Name | Select-Object -First 1)[0]
    }

    $main = Get-BranchModel 'main'
    $merged = Get-BranchModel 'feat/merged'
    $unmerged = Get-BranchModel 'feat/unmerged'
    $stale = Get-BranchModel 'feat/stale'
    $gone = Get-BranchModel 'feat/gone'
    $badName = Get-BranchModel 'scratch-bad-name'
    $worktreeBranch = Get-BranchModel 'feat/worktree'

    if ($main.protected -ne $true -or $main.advisoryCleanupCandidate -ne $false) {
        throw 'main must remain protected and never become a cleanup candidate.'
    }

    if ($merged.merged -ne $true -or $merged.advisoryCleanupCandidate -ne $true) {
        throw 'Expected locally merged short-lived branch cleanup candidate.'
    }

    if ($unmerged.merged -ne $false -or $unmerged.advisoryCleanupCandidate -ne $false) {
        throw 'Unmerged branch must not become a cleanup candidate.'
    }

    if (
        $stale.stale -ne $true -or
        [int]$stale.tipCommitAgeDays -lt 90 -or
        [int]$stale.staleThresholdDays -ne 90
    ) {
        throw 'Stale branch must preserve explicit age and threshold evidence.'
    }

    if ($gone.upstreamGone -ne $true) {
        throw 'Expected gone-upstream branch detection.'
    }

    if ($badName.namingDeviation -ne $true) {
        throw 'Expected branch naming deviation against Workstation governance.'
    }

    if (
        $worktreeBranch.checkedOutInWorktree -ne $true -or
        $worktreeBranch.protected -ne $true -or
        $worktreeBranch.advisoryCleanupCandidate -ne $false
    ) {
        throw 'Branch checked out in a linked worktree must remain protected from cleanup candidacy.'
    }

    $linked = @($worktrees | Where-Object branch -eq 'feat/worktree' | Select-Object -First 1)[0]
    if ($linked.dirty -ne $true -or $linked.isMainWorktree -ne $false) {
        throw 'Expected dirty linked worktree state.'
    }

    $prunable = @($worktrees | Where-Object branch -eq 'feat/prunable' | Select-Object -First 1)[0]
    if (
        $prunable.prunable -ne $true -or
        $prunable.advisoryCleanupCandidate -ne $true
    ) {
        throw 'Expected Git-reported prunable linked worktree advisory candidate.'
    }

    foreach ($flag in @(
        'readOnly',
        'reusesRepositoryHealth',
        'defaultBranchDetectionUsesLocalRefsOnly',
        'optionalLocksDisabled',
        'advisoryOnly'
    )) {
        if ($summary.attributes.$flag -ne $true) {
            throw "Expected $flag=true."
        }
    }

    foreach ($flag in @(
        'independentRepositoryDiscovery',
        'networkAccessRequired',
        'branchDeletionPerformed',
        'worktreePrunePerformed',
        'worktreeRemovePerformed',
        'checkoutPerformed',
        'resetPerformed',
        'historyRewritePerformed',
        'gitConfigurationModified',
        'remoteUrlsCollected',
        'credentialHelpersCollected'
    )) {
        if ($summary.attributes.$flag -ne $false) {
            throw "Expected $flag=false."
        }
    }

    if ([int]$summary.attributes.staleThresholdDays -ne 90) {
        throw 'Expected configured 90-day stale threshold in summary evidence.'
    }

    $warningCodes = @($result.warnings | ForEach-Object code)
    foreach ($expectedCode in @(
        'GIT_BRANCH_MERGED_CANDIDATE',
        'GIT_BRANCH_UPSTREAM_GONE',
        'GIT_BRANCH_STALE',
        'GIT_BRANCH_NAMING_DEVIATION',
        'GIT_WORKTREE_PRUNABLE',
        'GIT_LINKED_WORKTREE_DIRTY'
    )) {
        if ($warningCodes -notcontains $expectedCode) {
            throw "Expected Git hygiene warning code '$expectedCode'."
        }
    }

    $source = Get-Content -LiteralPath $providerPath -Raw
    foreach ($forbidden in @(
        'branch -d',
        'branch -D',
        'worktree prune',
        'worktree remove',
        'git checkout',
        'git switch',
        'git reset',
        'filter-branch',
        'rebase --onto'
    )) {
        if ($source -match [Regex]::Escape($forbidden)) {
            throw "Provider source contains prohibited Git mutation marker: $forbidden"
        }
    }

    $missingDependency = & $providerPath -Context ([pscustomobject][ordered]@{
        ObservedAt = (Get-Date).ToString('o')
        GitBranchStaleDays = 90
        PreviousProviderResults = @()
    })

    if ($missingDependency.status -ne 'unavailable') {
        throw 'Missing git.repository-health dependency must degrade to unavailable.'
    }

    Write-Host 'Git branch and worktree hygiene validation passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
