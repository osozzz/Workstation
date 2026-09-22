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
        providerId = 'projects.local'
        category   = 'projects'
        order      = 40
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

$excludedDirectoryNames = @(
    '.git',
    '.gradle',
    '.idea',
    '.vscode',
    '.dart_tool',
    '.venv',
    'node_modules',
    'vendor',
    'target',
    'bin',
    'obj',
    'build',
    'venv'
)

$candidateExactMarkers = @(
    'package.json',
    'package-lock.json',
    'pnpm-lock.yaml',
    'yarn.lock',
    'bun.lockb',
    'pubspec.yaml',
    'pyproject.toml',
    'requirements.txt',
    'Cargo.toml',
    'rust-toolchain',
    'rust-toolchain.toml',
    'go.mod',
    'go.work',
    'global.json',
    'pom.xml',
    'build.gradle',
    'build.gradle.kts',
    'settings.gradle',
    'settings.gradle.kts'
)

function Get-ContextPropertyValue {
    param(
        [Parameter(Mandatory)][psobject]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $DefaultValue
}

function ConvertTo-ProjectDiscoveryRoot {
    param(
        [Parameter(Mandatory)][string]$RawPath,
        [Parameter(Mandatory)][int]$Index
    )

    $trimmed = $RawPath.Trim().Trim('"')

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return [pscustomobject][ordered]@{
            index            = $Index
            original         = $RawPath
            normalized       = $null
            comparisonKey    = $null
            state            = 'invalid'
            exists           = $null
            duplicate        = $false
            duplicateOfIndex = $null
            reason           = 'empty-path'
        }
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($trimmed)
    }
    catch {
        return [pscustomobject][ordered]@{
            index            = $Index
            original         = $RawPath
            normalized       = $null
            comparisonKey    = $null
            state            = 'invalid'
            exists           = $null
            duplicate        = $false
            duplicateOfIndex = $null
            reason           = 'invalid-path'
        }
    }

    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    $normalized = $fullPath

    if (
        -not [string]::IsNullOrWhiteSpace($pathRoot) -and
        $normalized.Length -gt $pathRoot.Length
    ) {
        $normalized = $normalized.TrimEnd('\', '/')
    }

    $comparisonKey = $normalized.ToLowerInvariant()

    if (
        -not [string]::IsNullOrWhiteSpace($pathRoot) -and
        [string]::Equals(
            $normalized.TrimEnd('\', '/'),
            $pathRoot.TrimEnd('\', '/'),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return [pscustomobject][ordered]@{
            index            = $Index
            original         = $RawPath
            normalized       = $normalized
            comparisonKey    = $comparisonKey
            state            = 'rejected-broad'
            exists           = $true
            duplicate        = $false
            duplicateOfIndex = $null
            reason           = 'filesystem-root'
        }
    }

    try {
        $item = Get-Item -LiteralPath $normalized -Force -ErrorAction Stop

        if (-not $item.PSIsContainer) {
            return [pscustomobject][ordered]@{
                index            = $Index
                original         = $RawPath
                normalized       = $normalized
                comparisonKey    = $comparisonKey
                state            = 'invalid'
                exists           = $true
                duplicate        = $false
                duplicateOfIndex = $null
                reason           = 'not-directory'
            }
        }

        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject][ordered]@{
                index            = $Index
                original         = $RawPath
                normalized       = $normalized
                comparisonKey    = $comparisonKey
                state            = 'rejected-reparse'
                exists           = $true
                duplicate        = $false
                duplicateOfIndex = $null
                reason           = 'root-is-reparse-point'
            }
        }

        return [pscustomobject][ordered]@{
            index            = $Index
            original         = $RawPath
            normalized       = $normalized
            comparisonKey    = $comparisonKey
            state            = 'ready'
            exists           = $true
            duplicate        = $false
            duplicateOfIndex = $null
            reason           = $null
        }
    }
    catch [System.UnauthorizedAccessException] {
        return [pscustomobject][ordered]@{
            index            = $Index
            original         = $RawPath
            normalized       = $normalized
            comparisonKey    = $comparisonKey
            state            = 'inaccessible'
            exists           = $null
            duplicate        = $false
            duplicateOfIndex = $null
            reason           = 'access-denied'
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            index            = $Index
            original         = $RawPath
            normalized       = $normalized
            comparisonKey    = $comparisonKey
            state            = 'missing'
            exists           = $false
            duplicate        = $false
            duplicateOfIndex = $null
            reason           = 'not-found'
        }
    }
}

function Get-CandidateMarkers {
    param(
        [Parameter(Mandatory)]
        [object[]]$Items
    )

    $markers = New-Object System.Collections.Generic.List[string]

    foreach ($item in $Items) {
        $name = [string]$item.Name

        if ([string]::Equals($name, '.git', [StringComparison]::OrdinalIgnoreCase)) {
            if (-not $markers.Contains('.git')) {
                $markers.Add('.git')
            }
            continue
        }

        foreach ($marker in $candidateExactMarkers) {
            if ([string]::Equals($name, $marker, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not $markers.Contains($marker)) {
                    $markers.Add($marker)
                }
                break
            }
        }

        if (
            $name -match '(?i)\.(sln|csproj|fsproj|vbproj)$' -and
            -not $markers.Contains($name)
        ) {
            $markers.Add($name)
        }
    }

    return @($markers.ToArray() | Sort-Object)
}

function Get-BoundedProjectDiscovery {
    param(
        [Parameter(Mandatory)]
        [object[]]$Roots,

        [Parameter(Mandatory)]
        [ValidateRange(1, 32)]
        [int]$MaxDepth
    )

    $candidatesByKey = @{}
    $inaccessibleByKey = @{}
    $skippedReparsePointCount = 0
    $traversedDirectoryCount = 0

    foreach ($root in @($Roots | Where-Object { $_.state -eq 'ready' -and -not $_.duplicate })) {
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue([pscustomobject]@{
            path      = [string]$root.normalized
            depth     = 0
            rootIndex = [int]$root.index
        })

        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $items = @()

            try {
                $items = @(Get-ChildItem -LiteralPath $current.path -Force -ErrorAction Stop)
                $traversedDirectoryCount++
            }
            catch {
                $key = ([string]$current.path).ToLowerInvariant()
                if (-not $inaccessibleByKey.ContainsKey($key)) {
                    $inaccessibleByKey[$key] = [pscustomobject][ordered]@{
                        path      = [string]$current.path
                        rootIndex = [int]$current.rootIndex
                        depth     = [int]$current.depth
                    }
                }
                continue
            }

            $markers = @(Get-CandidateMarkers -Items $items)

            if ($markers.Count -gt 0) {
                $candidatePath = [string]$current.path
                $candidateKey = $candidatePath.ToLowerInvariant()

                if (-not $candidatesByKey.ContainsKey($candidateKey)) {
                    $rootPath = [string]$root.normalized
                    $relativePath = [IO.Path]::GetRelativePath($rootPath, $candidatePath)

                    $candidatesByKey[$candidateKey] = [pscustomobject][ordered]@{
                        path             = $candidatePath
                        comparisonKey    = $candidateKey
                        relativePath     = $relativePath
                        depth            = [int]$current.depth
                        repositoryMarker = ($markers -contains '.git')
                        markerNames      = @($markers)
                        rootIndexes      = @([int]$current.rootIndex)
                    }
                }
                else {
                    $existing = $candidatesByKey[$candidateKey]
                    if (@($existing.rootIndexes) -notcontains [int]$current.rootIndex) {
                        $existing.rootIndexes = @($existing.rootIndexes) + @([int]$current.rootIndex)
                    }

                    $combinedMarkers = @($existing.markerNames) + @($markers)
                    $existing.markerNames = @($combinedMarkers | Sort-Object -Unique)
                    if ($markers -contains '.git') {
                        $existing.repositoryMarker = $true
                    }
                }
            }

            if ([int]$current.depth -ge $MaxDepth) {
                continue
            }

            foreach ($directory in @($items | Where-Object { $_.PSIsContainer })) {
                if ($excludedDirectoryNames -contains [string]$directory.Name) {
                    continue
                }

                if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $skippedReparsePointCount++
                    continue
                }

                $queue.Enqueue([pscustomobject]@{
                    path      = [string]$directory.FullName
                    depth     = ([int]$current.depth + 1)
                    rootIndex = [int]$current.rootIndex
                })
            }
        }
    }

    return [pscustomobject][ordered]@{
        candidates                 = @($candidatesByKey.Values | Sort-Object path)
        inaccessibleDirectories    = @($inaccessibleByKey.Values | Sort-Object path)
        skippedReparsePointCount   = $skippedReparsePointCount
        traversedDirectoryCount    = $traversedDirectoryCount
    }
}

$configState = [string](Get-ContextPropertyValue -InputObject $Context -Name 'LocalConfigurationState' -DefaultValue 'missing')
$configSource = [string](Get-ContextPropertyValue -InputObject $Context -Name 'LocalConfigurationSource' -DefaultValue 'workstation.local.json')
$configError = Get-ContextPropertyValue -InputObject $Context -Name 'LocalConfigurationError' -DefaultValue $null
$developmentRoots = @(
    Get-ContextPropertyValue -InputObject $Context -Name 'DevelopmentRoots' -DefaultValue @()
)

$maxDepthValue = Get-ContextPropertyValue -InputObject $Context -Name 'ProjectDiscoveryMaxDepth' -DefaultValue 6
[int]$maxDepth = 6
if (-not [int]::TryParse($maxDepthValue.ToString(), [ref]$maxDepth) -or $maxDepth -lt 1 -or $maxDepth -gt 32) {
    $maxDepth = 6
}

$rootModels = New-Object System.Collections.Generic.List[object]
$firstRootIndexByKey = @{}

for ($index = 0; $index -lt $developmentRoots.Count; $index++) {
    $rawRoot = [string]$developmentRoots[$index]
    $rootModel = ConvertTo-ProjectDiscoveryRoot -RawPath $rawRoot -Index $index

    if (-not [string]::IsNullOrWhiteSpace([string]$rootModel.comparisonKey)) {
        $key = [string]$rootModel.comparisonKey

        if ($firstRootIndexByKey.ContainsKey($key)) {
            $rootModel.duplicate = $true
            $rootModel.duplicateOfIndex = [int]$firstRootIndexByKey[$key]
        }
        else {
            $firstRootIndexByKey[$key] = $index
        }
    }

    $rootModels.Add($rootModel)
}

if ($configState -eq 'invalid') {
    $evidence.Add((New-AuditEvidence -EvidenceId 'projects.local.configuration' -Type configuration -Source $configSource -Captured $null -Attributes @{
        state = $configState
        error = $configError
        arbitraryFilesystemFallback = $false
    }))

    $warnings.Add((New-AuditIssue -Code 'PROJECT_LOCAL_CONFIG_INVALID' -Message 'The machine-local project discovery configuration is invalid. No project traversal was performed.' -Severity warning -EvidenceIds @('projects.local.configuration')))
}

foreach ($root in $rootModels) {
    $rootEvidenceId = "projects.local.root.$($root.index)"

    $evidence.Add((New-AuditEvidence -EvidenceId $rootEvidenceId -Type configuration -Source $configSource -Captured $null -Attributes @{
        index = $root.index
        original = $root.original
        normalized = $root.normalized
        comparisonKey = $root.comparisonKey
        state = $root.state
        exists = $root.exists
        duplicate = $root.duplicate
        duplicateOfIndex = $root.duplicateOfIndex
        reason = $root.reason
    }))

    if ($root.duplicate) {
        $warnings.Add((New-AuditIssue -Code 'PROJECT_ROOT_DUPLICATE' -Message "Configured development root index $($root.index) is equivalent to an earlier root and will not be traversed twice." -Severity info -EvidenceIds @($rootEvidenceId)))
    }

    switch ($root.state) {
        'invalid' {
            $warnings.Add((New-AuditIssue -Code 'PROJECT_ROOT_INVALID' -Message "Configured development root index $($root.index) is not a usable directory path." -Severity warning -EvidenceIds @($rootEvidenceId)))
        }
        'missing' {
            $warnings.Add((New-AuditIssue -Code 'PROJECT_ROOT_MISSING' -Message "Configured development root index $($root.index) does not exist." -Severity warning -EvidenceIds @($rootEvidenceId)))
        }
        'inaccessible' {
            $warnings.Add((New-AuditIssue -Code 'PROJECT_ROOT_INACCESSIBLE' -Message "Configured development root index $($root.index) could not be inspected." -Severity warning -EvidenceIds @($rootEvidenceId)))
        }
        'rejected-broad' {
            $warnings.Add((New-AuditIssue -Code 'PROJECT_ROOT_TOO_BROAD' -Message "Configured development root index $($root.index) resolves to a filesystem root and was rejected to prevent whole-disk traversal." -Severity warning -EvidenceIds @($rootEvidenceId)))
        }
        'rejected-reparse' {
            $warnings.Add((New-AuditIssue -Code 'PROJECT_ROOT_REPARSE_REJECTED' -Message "Configured development root index $($root.index) is a reparse point and was rejected to preserve the discovery boundary." -Severity warning -EvidenceIds @($rootEvidenceId)))
        }
    }
}

$discovery = [pscustomobject][ordered]@{
    candidates               = @()
    inaccessibleDirectories  = @()
    skippedReparsePointCount = 0
    traversedDirectoryCount  = 0
}

$readyRoots = @($rootModels | Where-Object { $_.state -eq 'ready' -and -not $_.duplicate })

if ($configState -ne 'invalid' -and $readyRoots.Count -gt 0) {
    $discovery = Get-BoundedProjectDiscovery -Roots $rootModels.ToArray() -MaxDepth $maxDepth
}

$discoveryEvidenceId = 'projects.local.discovery'
$evidence.Add((New-AuditEvidence -EvidenceId $discoveryEvidenceId -Type filesystem -Source 'Configured development roots' -Captured $null -Attributes @{
    maxDepth = $maxDepth
    traversedDirectoryCount = $discovery.traversedDirectoryCount
    candidateCount = @($discovery.candidates).Count
    repositoryCount = @($discovery.candidates | Where-Object repositoryMarker).Count
    inaccessibleDirectoryCount = @($discovery.inaccessibleDirectories).Count
    skippedReparsePointCount = $discovery.skippedReparsePointCount
    candidates = @($discovery.candidates)
    inaccessibleDirectories = @($discovery.inaccessibleDirectories)
}))

if (@($discovery.inaccessibleDirectories).Count -gt 0) {
    $warnings.Add((New-AuditIssue -Code 'PROJECT_DISCOVERY_INACCESSIBLE_DIRECTORIES' -Message "Bounded project discovery could not inspect $(@($discovery.inaccessibleDirectories).Count) directorie(s) beneath configured roots." -Severity warning -EvidenceIds @($discoveryEvidenceId)))
}

$summaryEvidenceId = 'projects.local.summary'
$evidence.Add((New-AuditEvidence -EvidenceId $summaryEvidenceId -Type derived -Source 'Bounded local project discovery' -Captured $null -Attributes @{
    configurationState = $configState
    configuredRootCount = $developmentRoots.Count
    normalizedRootCount = $rootModels.Count
    readyRootCount = $readyRoots.Count
    duplicateRootCount = @($rootModels | Where-Object duplicate).Count
    missingRootCount = @($rootModels | Where-Object state -eq 'missing').Count
    invalidRootCount = @($rootModels | Where-Object state -eq 'invalid').Count
    inaccessibleRootCount = @($rootModels | Where-Object state -eq 'inaccessible').Count
    rejectedBroadRootCount = @($rootModels | Where-Object state -eq 'rejected-broad').Count
    rejectedReparseRootCount = @($rootModels | Where-Object state -eq 'rejected-reparse').Count
    maxDepth = $maxDepth
    candidateCount = @($discovery.candidates).Count
    repositoryCount = @($discovery.candidates | Where-Object repositoryMarker).Count
    readOnly = $true
    boundedToConfiguredRoots = $true
    wholeDiskTraversal = $false
    implicitHomeTraversal = $false
    followsReparsePoints = $false
    filesystemMutation = $false
    projectClassificationOwned = $false
    gitHealthOwned = $false
}))

$status = if (
    $configState -ne 'invalid' -and
    $developmentRoots.Count -eq 0 -and
    $warnings.Count -eq 0
) {
    Get-AuditProviderStatus -NotApplicable
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray()
}

return [pscustomobject][ordered]@{
    providerId = 'projects.local'
    category   = 'projects'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
