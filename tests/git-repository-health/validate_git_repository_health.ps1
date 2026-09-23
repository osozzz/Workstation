[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$providerPath = Join-Path $root 'scripts\Providers\GitRepositoryHealth.Provider.ps1'

$tempBase = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $env:RUNNER_TEMP
}
else {
    [IO.Path]::GetTempPath()
}

$tempRoot = Join-Path $tempBase "workstation-git-health-$([guid]::NewGuid().ToString('N'))"

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

function Initialize-Repository {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$InitialText = 'initial'
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Invoke-Git -WorkingDirectory $Path -Arguments @('init') | Out-Null
    Invoke-Git -WorkingDirectory $Path -Arguments @('config', 'user.name', 'Synthetic Workstation Test') | Out-Null
    Invoke-Git -WorkingDirectory $Path -Arguments @('config', 'user.email', 'synthetic@example.invalid') | Out-Null

    Set-Content -LiteralPath (Join-Path $Path 'tracked.txt') -Value $InitialText -Encoding UTF8
    Invoke-Git -WorkingDirectory $Path -Arguments @('add', 'tracked.txt') | Out-Null
    Invoke-Git -WorkingDirectory $Path -Arguments @('commit', '-m', 'initial') | Out-Null
}

function Get-RepositoryEvidence {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][string]$Path
    )

    return @(
        $Result.evidence |
            Where-Object { $_.evidenceId -match '^git\.repository-health\.repository\.\d+$' } |
            Where-Object {
                [string]::Equals(
                    [string]$_.attributes.repository.path,
                    $Path,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } |
            Select-Object -First 1
    )[0]
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $cleanNoUpstream = Join-Path $tempRoot 'clean-no-upstream'
    Initialize-Repository -Path $cleanNoUpstream

    $dirty = Join-Path $tempRoot 'dirty'
    Initialize-Repository -Path $dirty
    Set-Content -LiteralPath (Join-Path $dirty 'staged.txt') -Value 'staged' -Encoding UTF8
    Invoke-Git -WorkingDirectory $dirty -Arguments @('add', 'staged.txt') | Out-Null
    Add-Content -LiteralPath (Join-Path $dirty 'tracked.txt') -Value 'unstaged' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dirty 'untracked.txt') -Value 'untracked' -Encoding UTF8

    $detached = Join-Path $tempRoot 'detached'
    Initialize-Repository -Path $detached
    Invoke-Git -WorkingDirectory $detached -Arguments @('checkout', '--detach', 'HEAD') | Out-Null

    $remote = Join-Path $tempRoot 'remote.git'
    New-Item -ItemType Directory -Path $remote -Force | Out-Null
    $bareOutput = & git -C $remote init --bare 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not initialize synthetic bare remote: $($bareOutput -join ' ')"
    }

    $seed = Join-Path $tempRoot 'seed'
    Initialize-Repository -Path $seed
    Invoke-Git -WorkingDirectory $seed -Arguments @('remote', 'add', 'origin', $remote) | Out-Null
    Invoke-Git -WorkingDirectory $seed -Arguments @('push', '-u', 'origin', 'HEAD') | Out-Null

    $defaultBranch = (Invoke-Git -WorkingDirectory $seed -Arguments @('branch', '--show-current') | Select-Object -Last 1).Trim()
    if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
        throw 'Synthetic seed repository did not expose a current branch.'
    }

    function Clone-Repository {
        param(
            [Parameter(Mandatory)][string]$Destination
        )

        $cloneOutput = & git clone $remote $Destination 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Synthetic clone failed: $($cloneOutput -join ' ')"
        }

        Invoke-Git -WorkingDirectory $Destination -Arguments @('config', 'user.name', 'Synthetic Workstation Test') | Out-Null
        Invoke-Git -WorkingDirectory $Destination -Arguments @('config', 'user.email', 'synthetic@example.invalid') | Out-Null
    }

    $cleanTracked = Join-Path $tempRoot 'clean-tracked'
    Clone-Repository -Destination $cleanTracked

    $ahead = Join-Path $tempRoot 'ahead'
    Clone-Repository -Destination $ahead
    Set-Content -LiteralPath (Join-Path $ahead 'ahead.txt') -Value 'ahead' -Encoding UTF8
    Invoke-Git -WorkingDirectory $ahead -Arguments @('add', 'ahead.txt') | Out-Null
    Invoke-Git -WorkingDirectory $ahead -Arguments @('commit', '-m', 'ahead') | Out-Null

    $behind = Join-Path $tempRoot 'behind'
    Clone-Repository -Destination $behind

    $diverged = Join-Path $tempRoot 'diverged'
    Clone-Repository -Destination $diverged
    Set-Content -LiteralPath (Join-Path $diverged 'local.txt') -Value 'local' -Encoding UTF8
    Invoke-Git -WorkingDirectory $diverged -Arguments @('add', 'local.txt') | Out-Null
    Invoke-Git -WorkingDirectory $diverged -Arguments @('commit', '-m', 'local diverged') | Out-Null

    Set-Content -LiteralPath (Join-Path $seed 'remote.txt') -Value 'remote' -Encoding UTF8
    Invoke-Git -WorkingDirectory $seed -Arguments @('add', 'remote.txt') | Out-Null
    Invoke-Git -WorkingDirectory $seed -Arguments @('commit', '-m', 'remote advance') | Out-Null
    Invoke-Git -WorkingDirectory $seed -Arguments @('push', 'origin', $defaultBranch) | Out-Null

    Invoke-Git -WorkingDirectory $behind -Arguments @('fetch', 'origin') | Out-Null
    Invoke-Git -WorkingDirectory $diverged -Arguments @('fetch', 'origin') | Out-Null

    $repositoryPaths = @(
        $cleanNoUpstream,
        $dirty,
        $detached,
        $cleanTracked,
        $ahead,
        $behind,
        $diverged
    )

    $candidates = @(
        foreach ($path in $repositoryPaths) {
            [pscustomobject][ordered]@{
                path = $path
                repositoryMarker = $true
                markerNames = @('.git')
            }
        }
    )

    $projectsLocal = [pscustomobject][ordered]@{
        providerId = 'projects.local'
        category = 'projects'
        status = 'success'
        observedAt = (Get-Date).ToString('o')
        components = @()
        warnings = @()
        errors = @()
        evidence = @(
            [pscustomobject][ordered]@{
                evidenceId = 'projects.local.discovery'
                type = 'filesystem'
                source = 'Synthetic configured roots'
                exitCode = $null
                captured = $null
                redacted = $false
                attributes = [pscustomobject][ordered]@{
                    candidates = $candidates
                }
            }
        )
    }

    $context = [pscustomobject][ordered]@{
        ObservedAt = (Get-Date).ToString('o')
        PreviousProviderResults = @($projectsLocal)
    }

    $result = & $providerPath -Context $context

    if ($result.providerId -ne 'git.repository-health' -or $result.category -ne 'git') {
        throw 'Unexpected Git repository health provider identity.'
    }

    if (@($result.components).Count -ne 0) {
        throw 'git.repository-health must remain evidence-only and own zero components.'
    }

    $summary = @(
        $result.evidence |
            Where-Object evidenceId -eq 'git.repository-health.summary' |
            Select-Object -First 1
    )[0]

    if ($null -eq $summary) {
        throw 'Missing git.repository-health summary evidence.'
    }

    foreach ($flag in @(
        'readOnly',
        'usesOnlyDiscoveredRepositories',
        'optionalLocksDisabled'
    )) {
        if ($summary.attributes.$flag -ne $true) {
            throw "Expected $flag=true."
        }
    }

    foreach ($flag in @(
        'performsFilesystemTraversal',
        'networkAccessRequired',
        'fetchPerformed',
        'pullPerformed',
        'pushPerformed',
        'checkoutPerformed',
        'resetPerformed',
        'cleanPerformed',
        'stashPerformed',
        'commitPerformed',
        'gitConfigurationCollected',
        'remoteUrlsCollected',
        'credentialHelpersCollected'
    )) {
        if ($summary.attributes.$flag -ne $false) {
            throw "Expected $flag=false."
        }
    }

    if ([int]$summary.attributes.repositoryCount -ne $repositoryPaths.Count) {
        throw 'Unexpected repository count in Git repository health summary.'
    }

    if ([int]$summary.attributes.inspectedRepositoryCount -ne $repositoryPaths.Count) {
        throw 'Every synthetic repository should be inspected.'
    }

    $cleanEvidence = Get-RepositoryEvidence -Result $result -Path $cleanTracked
    if ($null -eq $cleanEvidence -or $cleanEvidence.attributes.repository.clean -ne $true) {
        throw 'Expected clean tracked repository state.'
    }

    if ($cleanEvidence.attributes.repository.upstreamRemote -ne 'origin') {
        throw 'Expected sanitized upstream remote identity only.'
    }

    $dirtyEvidence = Get-RepositoryEvidence -Result $result -Path $dirty
    $dirtyModel = $dirtyEvidence.attributes.repository
    if (
        $dirtyModel.dirty -ne $true -or
        [int]$dirtyModel.stagedCount -lt 1 -or
        [int]$dirtyModel.unstagedCount -lt 1 -or
        [int]$dirtyModel.untrackedCount -lt 1
    ) {
        throw 'Dirty repository must preserve staged, unstaged, and untracked counts.'
    }

    $detachedEvidence = Get-RepositoryEvidence -Result $result -Path $detached
    if ($detachedEvidence.attributes.repository.detached -ne $true) {
        throw 'Expected detached HEAD detection.'
    }

    $missingEvidence = Get-RepositoryEvidence -Result $result -Path $cleanNoUpstream
    if ($missingEvidence.attributes.repository.missingUpstream -ne $true) {
        throw 'Expected missing upstream detection.'
    }

    $aheadEvidence = Get-RepositoryEvidence -Result $result -Path $ahead
    if (
        [int]$aheadEvidence.attributes.repository.ahead -lt 1 -or
        [int]$aheadEvidence.attributes.repository.behind -ne 0 -or
        [int]$aheadEvidence.attributes.repository.unpushedCommitCount -lt 1
    ) {
        throw 'Expected ahead/unpushed commit detection from local refs.'
    }

    $behindEvidence = Get-RepositoryEvidence -Result $result -Path $behind
    if (
        [int]$behindEvidence.attributes.repository.ahead -ne 0 -or
        [int]$behindEvidence.attributes.repository.behind -lt 1
    ) {
        throw 'Expected behind detection from locally known upstream refs.'
    }

    $divergedEvidence = Get-RepositoryEvidence -Result $result -Path $diverged
    if (
        [int]$divergedEvidence.attributes.repository.ahead -lt 1 -or
        [int]$divergedEvidence.attributes.repository.behind -lt 1 -or
        $divergedEvidence.attributes.repository.diverged -ne $true
    ) {
        throw 'Expected diverged repository detection.'
    }

    $warningCodes = @($result.warnings | ForEach-Object code)
    foreach ($expectedCode in @(
        'GIT_WORKTREE_DIRTY',
        'GIT_DETACHED_HEAD',
        'GIT_UPSTREAM_MISSING',
        'GIT_UNPUSHED_COMMITS',
        'GIT_BRANCH_DIVERGED'
    )) {
        if ($warningCodes -notcontains $expectedCode) {
            throw "Expected warning code '$expectedCode'."
        }
    }

    $source = Get-Content -LiteralPath $providerPath -Raw

    foreach ($forbidden in @(
        'git fetch',
        'git pull',
        'git push',
        'git checkout',
        'git reset',
        'git clean',
        'git stash',
        'git commit',
        'remote get-url',
        'credential.helper'
    )) {
        if ($source -match [Regex]::Escape($forbidden)) {
            throw "Provider source contains prohibited Git behavior marker: $forbidden"
        }
    }

    if ($source -notmatch [Regex]::Escape('--no-optional-locks')) {
        throw 'Provider must disable Git optional locks during audit inspection.'
    }

    $missingDependencyContext = [pscustomobject][ordered]@{
        ObservedAt = (Get-Date).ToString('o')
        PreviousProviderResults = @()
    }

    $missingDependency = & $providerPath -Context $missingDependencyContext
    if ($missingDependency.status -ne 'unavailable') {
        throw 'Missing projects.local dependency must produce unavailable state.'
    }

    Write-Host 'Git repository state and upstream health validation passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
