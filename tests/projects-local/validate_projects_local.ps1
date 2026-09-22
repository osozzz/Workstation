[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$providerPath = Join-Path $root 'scripts\Providers\ProjectsLocal.Provider.ps1'
$auditPath = Join-Path $root 'scripts\Audit-Workstation.ps1'
$fixturePath = Join-Path $PSScriptRoot 'project-discovery-cases.json'
$gitIgnorePath = Join-Path $root '.gitignore'
$exampleConfigPath = Join-Path $root 'config\workstation.local.example.json'

$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

$tempBase = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $env:RUNNER_TEMP
}
else {
    [IO.Path]::GetTempPath()
}

$tempRoot = Join-Path $tempBase "workstation-project-discovery-$([guid]::NewGuid().ToString('N'))"

function New-SyntheticFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Content = '{}'
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Get-Evidence {
    param(
        [Parameter(Mandatory)][object]$ProviderResult,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    return @(
        $ProviderResult.evidence |
            Where-Object evidenceId -eq $EvidenceId |
            Select-Object -First 1
    )[0]
}

try {
    $rootA = Join-Path $tempRoot 'rootA'
    $rootB = Join-Path $tempRoot 'rootB'
    $emptyRoot = Join-Path $tempRoot 'emptyRoot'
    $missingRoot = Join-Path $tempRoot 'missingRoot'
    $outsideRoot = Join-Path $tempRoot 'outside'

    foreach ($directory in @($rootA, $rootB, $emptyRoot, $outsideRoot)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $repoA = Join-Path $rootA 'RepoA'
    New-Item -ItemType Directory -Path (Join-Path $repoA '.git') -Force | Out-Null
    New-SyntheticFile -Path (Join-Path $repoA 'package.json')

    $nestedRepo = Join-Path $repoA 'NestedRepo'
    New-Item -ItemType Directory -Path (Join-Path $nestedRepo '.git') -Force | Out-Null

    $pythonPackage = Join-Path $repoA 'Nested\Package'
    New-SyntheticFile -Path (Join-Path $pythonPackage 'pyproject.toml')

    $tooDeep = Join-Path $rootA 'Deep1\Deep2\Deep3\Deep4'
    New-SyntheticFile -Path (Join-Path $tooDeep 'package.json')

    $repoB = Join-Path $rootB 'RepoB'
    New-SyntheticFile -Path (Join-Path $repoB 'go.mod') -Content 'module synthetic.example/repo'

    $outside = Join-Path $outsideRoot 'OutsideProject'
    New-SyntheticFile -Path (Join-Path $outside 'package.json')

    $broadRoot = [IO.Path]::GetPathRoot($tempRoot)

    $context = [pscustomobject][ordered]@{
        ObservedAt               = (Get-Date).ToString('o')
        LocalConfigurationState  = 'loaded'
        LocalConfigurationSource = 'workstation.local.json'
        LocalConfigurationError  = $null
        DevelopmentRoots         = @(
            $rootA,
            ($rootA + [IO.Path]::DirectorySeparatorChar),
            $rootB,
            $emptyRoot,
            $missingRoot,
            $broadRoot
        )
        ProjectDiscoveryMaxDepth = [int]$fixture.maxDepth
    }

    $result = & $providerPath -Context $context

    if ($result.providerId -ne 'projects.local' -or $result.category -ne 'projects') {
        throw 'Unexpected projects.local provider identity.'
    }

    if ($result.status -ne 'warning') {
        throw "Expected warning status for duplicate/missing/broad synthetic roots, got '$($result.status)'."
    }

    if (@($result.components).Count -ne 0) {
        throw 'projects.local must not own project technology or Git-health components.'
    }

    $summary = Get-Evidence -ProviderResult $result -EvidenceId 'projects.local.summary'
    $discovery = Get-Evidence -ProviderResult $result -EvidenceId 'projects.local.discovery'

    if ($null -eq $summary -or $null -eq $discovery) {
        throw 'Expected projects.local summary and discovery evidence.'
    }

    foreach ($flag in @(
        'readOnly',
        'boundedToConfiguredRoots'
    )) {
        if ($summary.attributes.$flag -ne $true) {
            throw "Expected projects.local summary $flag=true."
        }
    }

    foreach ($flag in @(
        'wholeDiskTraversal',
        'implicitHomeTraversal',
        'followsReparsePoints',
        'filesystemMutation',
        'projectClassificationOwned',
        'gitHealthOwned'
    )) {
        if ($summary.attributes.$flag -ne $false) {
            throw "Expected projects.local summary $flag=false."
        }
    }

    $expected = $fixture.expected

    foreach ($pair in @(
        @('configuredRootCount', [int]$expected.configuredRootCount),
        @('readyRootCount', [int]$expected.readyRootCount),
        @('duplicateRootCount', [int]$expected.duplicateRootCount),
        @('missingRootCount', [int]$expected.missingRootCount),
        @('rejectedBroadRootCount', [int]$expected.rejectedBroadRootCount),
        @('candidateCount', [int]$expected.candidateCount),
        @('repositoryCount', [int]$expected.repositoryCount)
    )) {
        $name = [string]$pair[0]
        $expectedValue = [int]$pair[1]
        $actualValue = [int]$summary.attributes.$name

        if ($actualValue -ne $expectedValue) {
            throw "Unexpected ${name}: expected $expectedValue, got $actualValue."
        }
    }

    if ([int]$discovery.attributes.maxDepth -ne [int]$fixture.maxDepth) {
        throw 'Project discovery did not preserve the configured maximum depth.'
    }

    $candidatePaths = @(
        $discovery.attributes.candidates |
            ForEach-Object { [IO.Path]::GetFullPath([string]$_.path) }
    )

    $expectedPaths = @{
        repoA         = [IO.Path]::GetFullPath($repoA)
        nestedRepo    = [IO.Path]::GetFullPath($nestedRepo)
        pythonPackage = [IO.Path]::GetFullPath($pythonPackage)
        repoB         = [IO.Path]::GetFullPath($repoB)
        tooDeep       = [IO.Path]::GetFullPath($tooDeep)
        outside       = [IO.Path]::GetFullPath($outside)
    }

    foreach ($label in @($expected.expectedCandidateLabels)) {
        $expectedPath = $expectedPaths[[string]$label]
        if ($candidatePaths -notcontains $expectedPath) {
            throw "Expected synthetic candidate '$label' was not discovered."
        }
    }

    foreach ($label in @($expected.forbiddenCandidateLabels)) {
        $forbiddenPath = $expectedPaths[[string]$label]
        if ($candidatePaths -contains $forbiddenPath) {
            throw "Forbidden synthetic candidate '$label' escaped the discovery boundary."
        }
    }

    $outsidePrefix = ([IO.Path]::GetFullPath($outsideRoot)).TrimEnd('\') + '\'
    foreach ($candidatePath in $candidatePaths) {
        if ($candidatePath.StartsWith($outsidePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Project discovery traversed outside configured development roots.'
        }
    }

    $repoCandidates = @(
        $discovery.attributes.candidates |
            Where-Object repositoryMarker
    )

    if ($repoCandidates.Count -ne [int]$expected.repositoryCount) {
        throw 'Unexpected synthetic repository candidate count.'
    }

    $rootEvidence = @(
        $result.evidence |
            Where-Object { $_.evidenceId -match '^projects\.local\.root\.\d+$' }
    )

    if ($rootEvidence.Count -ne [int]$expected.configuredRootCount) {
        throw 'Expected one root evidence record per configured development root.'
    }

    $warningCodes = @($result.warnings | ForEach-Object code | Sort-Object -Unique)
    $expectedWarningCodes = @($expected.warningCodes | Sort-Object -Unique)

    if (($warningCodes -join '|') -ne ($expectedWarningCodes -join '|')) {
        throw "Unexpected project discovery warnings: $($warningCodes -join ', ')."
    }

    $noRootsContext = [pscustomobject][ordered]@{
        ObservedAt               = (Get-Date).ToString('o')
        LocalConfigurationState  = 'missing'
        LocalConfigurationSource = 'workstation.local.json'
        LocalConfigurationError  = $null
        DevelopmentRoots         = @()
        ProjectDiscoveryMaxDepth = 6
    }

    $noRoots = & $providerPath -Context $noRootsContext

    if ($noRoots.status -ne 'not-applicable') {
        throw "Missing local config with no roots must be neutral/not-applicable, got '$($noRoots.status)'."
    }

    $noRootsDiscovery = Get-Evidence -ProviderResult $noRoots -EvidenceId 'projects.local.discovery'
    if (
        [int]$noRootsDiscovery.attributes.traversedDirectoryCount -ne 0 -or
        @($noRootsDiscovery.attributes.candidates).Count -ne 0
    ) {
        throw 'No-root project discovery must not traverse the filesystem.'
    }

    $invalidContext = [pscustomobject][ordered]@{
        ObservedAt               = (Get-Date).ToString('o')
        LocalConfigurationState  = 'invalid'
        LocalConfigurationSource = 'workstation.local.json'
        LocalConfigurationError  = 'Synthetic invalid configuration.'
        DevelopmentRoots         = @()
        ProjectDiscoveryMaxDepth = 6
    }

    $invalid = & $providerPath -Context $invalidContext
    $invalidCodes = @($invalid.warnings | ForEach-Object code)

    if ($invalid.status -ne 'warning' -or $invalidCodes -notcontains 'PROJECT_LOCAL_CONFIG_INVALID') {
        throw 'Invalid local configuration must produce a normalized warning without traversal.'
    }

    $invalidDiscovery = Get-Evidence -ProviderResult $invalid -EvidenceId 'projects.local.discovery'
    if ([int]$invalidDiscovery.attributes.traversedDirectoryCount -ne 0) {
        throw 'Invalid local configuration must not trigger filesystem traversal.'
    }

    $providerSource = Get-Content -LiteralPath $providerPath -Raw
    foreach ($pattern in @(
        '\bInvoke-AuditCommand\b',
        '\bRemove-Item\b',
        '\bSet-Content\b',
        '\bAdd-Content\b',
        '\bOut-File\b',
        '\bMove-Item\b',
        '\bCopy-Item\b',
        '\bRename-Item\b',
        '\bNew-Item\b',
        '\bgit\s+(fetch|pull|push|checkout|switch|reset|clean|stash|commit|worktree\s+prune)\b'
    )) {
        if ($providerSource -match $pattern) {
            throw "projects.local source contains prohibited mutation/execution pattern: $pattern"
        }
    }

    $auditSource = Get-Content -LiteralPath $auditPath -Raw
    foreach ($requiredText in @(
        'LocalConfigurationPath',
        'Get-LocalAuditConfiguration',
        'DevelopmentRoots',
        'ProjectDiscoveryMaxDepth'
    )) {
        if ($auditSource -notmatch [Regex]::Escape($requiredText)) {
            throw "Audit orchestrator is missing local project configuration integration: $requiredText"
        }
    }

    $gitIgnore = Get-Content -LiteralPath $gitIgnorePath -Raw
    if ($gitIgnore -notmatch '(?m)^config/workstation\.local\.json\s*$') {
        throw 'Machine-local workstation config must remain ignored by Git.'
    }

    $exampleConfig = Get-Content -LiteralPath $exampleConfigPath -Raw | ConvertFrom-Json
    if (@($exampleConfig.projects.developmentRoots).Count -ne 0) {
        throw 'Committed local-config example must not contain real development roots.'
    }

    if ([int]$exampleConfig.projects.maxDiscoveryDepth -ne 6) {
        throw 'Committed local-config example must preserve the default bounded discovery depth.'
    }

    Write-Host 'Bounded local project discovery validation passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
