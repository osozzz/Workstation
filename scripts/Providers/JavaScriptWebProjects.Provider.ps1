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
        providerId = 'projects.javascript-web'
        category   = 'projects'
        order      = 41
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

function Read-OptionalText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 65536)][int]$MaximumLength = 4096
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $value = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ($value.Length -gt $MaximumLength) {
            return [pscustomobject][ordered]@{
                state = 'too-large'
                value = $null
            }
        }

        return [pscustomobject][ordered]@{
            state = 'read'
            value = $value.Trim()
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            state = 'unreadable'
            value = $null
        }
    }
}

function Read-PackageJson {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            state = 'missing'
            value = $null
        }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ($raw.Length -gt 1048576) {
            return [pscustomobject][ordered]@{
                state = 'too-large'
                value = $null
            }
        }

        return [pscustomobject][ordered]@{
            state = 'read'
            value = ($raw | ConvertFrom-Json -ErrorAction Stop)
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            state = 'invalid'
            value = $null
        }
    }
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-DependencyNames {
    param([AllowNull()][object]$Package)

    $names = New-Object System.Collections.Generic.List[string]

    foreach ($sectionName in @('dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies')) {
        $section = Get-PropertyValue -Object $Package -Name $sectionName
        if ($null -eq $section) {
            continue
        }

        foreach ($property in @($section.PSObject.Properties)) {
            if (-not $names.Contains([string]$property.Name)) {
                $names.Add([string]$property.Name)
            }
        }
    }

    return @($names.ToArray() | Sort-Object)
}

function Get-ExplicitPackageManager {
    param([AllowNull()][object]$Package)

    $raw = [string](Get-PropertyValue -Object $Package -Name 'packageManager')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    $match = [regex]::Match($raw.Trim(), '^(?<name>npm|pnpm|yarn|bun)@(?<version>.+)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return [pscustomobject][ordered]@{
            raw = $raw.Trim()
            name = $null
            version = $null
            valid = $false
        }
    }

    return [pscustomobject][ordered]@{
        raw = $raw.Trim()
        name = $match.Groups['name'].Value.ToLowerInvariant()
        version = $match.Groups['version'].Value
        valid = $true
    }
}

function Test-AnyFile {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        if (Test-Path -LiteralPath (Join-Path $Directory $name) -PathType Leaf) {
            return $true
        }
    }

    return $false
}

$projectsLocal = Get-PreviousProvider -ProviderId 'projects.local'

if ($null -eq $projectsLocal) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'projects.javascript-web.summary' -Type derived -Source 'projects.local dependency' -Captured $null -Attributes @{
        dependencyAvailable = $false
        projectCount = 0
        readOnly = $true
        independentFilesystemTraversal = $false
        executesProjectCode = $false
        installsDependencies = $false
    }))

    return [pscustomobject][ordered]@{
        providerId = 'projects.javascript-web'
        category   = 'projects'
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

$projectModels = New-Object System.Collections.Generic.List[object]

for ($index = 0; $index -lt $candidates.Count; $index++) {
    $candidate = $candidates[$index]
    $projectPath = [string]$candidate.path

    if ([string]::IsNullOrWhiteSpace($projectPath) -or -not (Test-Path -LiteralPath $projectPath -PathType Container)) {
        continue
    }

    $packagePath = Join-Path $projectPath 'package.json'
    $packageRead = Read-PackageJson -Path $packagePath

    $lockfiles = New-Object System.Collections.Generic.List[string]
    $lockManagerMap = [ordered]@{
        'package-lock.json' = 'npm'
        'npm-shrinkwrap.json' = 'npm'
        'pnpm-lock.yaml' = 'pnpm'
        'yarn.lock' = 'yarn'
        'bun.lock' = 'bun'
        'bun.lockb' = 'bun'
    }

    foreach ($lockName in $lockManagerMap.Keys) {
        if (Test-Path -LiteralPath (Join-Path $projectPath $lockName) -PathType Leaf) {
            $lockfiles.Add($lockName)
        }
    }

    $angularMarker = Test-Path -LiteralPath (Join-Path $projectPath 'angular.json') -PathType Leaf
    $nextMarker = Test-AnyFile -Directory $projectPath -Names @(
        'next.config.js',
        'next.config.cjs',
        'next.config.mjs',
        'next.config.ts'
    )
    $prismaMarker = (
        (Test-Path -LiteralPath (Join-Path $projectPath 'prisma\schema.prisma') -PathType Leaf) -or
        (Test-AnyFile -Directory $projectPath -Names @('prisma.config.js', 'prisma.config.ts', 'prisma.config.mjs', 'prisma.config.cjs'))
    )

    $isJavaScriptProject = (
        $packageRead.state -ne 'missing' -or
        $lockfiles.Count -gt 0 -or
        $angularMarker -or
        $nextMarker -or
        $prismaMarker
    )

    if (-not $isJavaScriptProject) {
        continue
    }

    $package = $packageRead.value
    $dependencyNames = @(Get-DependencyNames -Package $package)

    $angular = $angularMarker -or ($dependencyNames -contains '@angular/core') -or ($dependencyNames -contains '@angular/cli')
    $next = $nextMarker -or ($dependencyNames -contains 'next')
    $prisma = $prismaMarker -or ($dependencyNames -contains 'prisma') -or ($dependencyNames -contains '@prisma/client')

    $nvmrc = Read-OptionalText -Path (Join-Path $projectPath '.nvmrc')
    $nodeVersion = Read-OptionalText -Path (Join-Path $projectPath '.node-version')

    $engines = Get-PropertyValue -Object $package -Name 'engines'
    $engineNode = if ($null -ne $engines) {
        [string](Get-PropertyValue -Object $engines -Name 'node')
    }
    else {
        $null
    }

    if ([string]::IsNullOrWhiteSpace($engineNode)) {
        $engineNode = $null
    }

    $packageManager = Get-ExplicitPackageManager -Package $package

    $pinSources = New-Object System.Collections.Generic.List[object]
    if ($null -ne $nvmrc -and $nvmrc.state -eq 'read' -and -not [string]::IsNullOrWhiteSpace([string]$nvmrc.value)) {
        $pinSources.Add([pscustomobject][ordered]@{ source = '.nvmrc'; value = [string]$nvmrc.value })
    }
    if ($null -ne $nodeVersion -and $nodeVersion.state -eq 'read' -and -not [string]::IsNullOrWhiteSpace([string]$nodeVersion.value)) {
        $pinSources.Add([pscustomobject][ordered]@{ source = '.node-version'; value = [string]$nodeVersion.value })
    }
    if ($null -ne $engineNode) {
        $pinSources.Add([pscustomobject][ordered]@{ source = 'package.json#engines.node'; value = $engineNode })
    }

    $pinValues = @($pinSources | ForEach-Object { ([string]$_.value).Trim().ToLowerInvariant() } | Sort-Object -Unique)
    $nodePinConflict = ($pinValues.Count -gt 1)

    $lockManagers = @(
        $lockfiles |
            ForEach-Object { [string]$lockManagerMap[$_] } |
            Sort-Object -Unique
    )

    $managerSignals = @($lockManagers)
    if ($null -ne $packageManager -and $packageManager.valid -and $packageManager.name) {
        $managerSignals += [string]$packageManager.name
    }
    $managerSignals = @($managerSignals | Sort-Object -Unique)
    $packageManagerConflict = ($managerSignals.Count -gt 1)

    $projectId = "project-$index"
    $evidenceId = "projects.javascript-web.$projectId"

    $model = [pscustomobject][ordered]@{
        projectIndex = $index
        path = $projectPath
        repositoryMarker = [bool]$candidate.repositoryMarker
        packageJsonState = $packageRead.state
        packageName = $(if ($null -ne $package) { [string](Get-PropertyValue -Object $package -Name 'name') } else { $null })
        types = @(
            @('node-package') +
            $(if ($angular) { @('angular') } else { @() }) +
            $(if ($next) { @('nextjs') } else { @() }) +
            $(if ($prisma) { @('prisma') } else { @() })
        )
        frameworkMarkers = [pscustomobject][ordered]@{
            angular = $angular
            nextjs = $next
            prisma = $prisma
        }
        nodePins = $pinSources.ToArray()
        nodePinConflict = $nodePinConflict
        packageManager = $packageManager
        lockfiles = $lockfiles.ToArray()
        lockManagers = $lockManagers
        packageManagerSignals = $managerSignals
        packageManagerConflict = $packageManagerConflict
    }

    $projectModels.Add($model)

    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type filesystem -Source 'projects.local candidate' -Captured $null -Attributes @{
        project = $model
        canonicalFilesOnly = $true
        nodeModulesInspected = $false
        projectCodeExecuted = $false
        packageManagerInvoked = $false
    }))

    if ($packageRead.state -in @('invalid', 'too-large')) {
        $warnings.Add((New-AuditIssue -Code 'JS_PROJECT_PACKAGE_JSON_UNREADABLE' -Message "JavaScript project candidate index $index has a package.json that could not be safely parsed." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($null -ne $packageManager -and -not $packageManager.valid) {
        $warnings.Add((New-AuditIssue -Code 'JS_PROJECT_PACKAGE_MANAGER_INVALID' -Message "JavaScript project candidate index $index has an unrecognized packageManager declaration." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($nodePinConflict) {
        $warnings.Add((New-AuditIssue -Code 'JS_PROJECT_NODE_PIN_CONFLICT' -Message "JavaScript project candidate index $index contains multiple distinct Node runtime constraints." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($packageManagerConflict) {
        $warnings.Add((New-AuditIssue -Code 'JS_PROJECT_PACKAGE_MANAGER_CONFLICT' -Message "JavaScript project candidate index $index contains conflicting package-manager signals." -Severity warning -EvidenceIds @($evidenceId)))
    }
}

$summaryEvidenceId = 'projects.javascript-web.summary'
$evidence.Add((New-AuditEvidence -EvidenceId $summaryEvidenceId -Type derived -Source 'projects.local discovery evidence' -Captured $null -Attributes @{
    dependencyAvailable = $true
    candidateCount = $candidates.Count
    projectCount = $projectModels.Count
    angularProjectCount = @($projectModels | Where-Object { $_.frameworkMarkers.angular }).Count
    nextProjectCount = @($projectModels | Where-Object { $_.frameworkMarkers.nextjs }).Count
    prismaProjectCount = @($projectModels | Where-Object { $_.frameworkMarkers.prisma }).Count
    nodePinConflictCount = @($projectModels | Where-Object nodePinConflict).Count
    packageManagerConflictCount = @($projectModels | Where-Object packageManagerConflict).Count
    projects = $projectModels.ToArray()
    readOnly = $true
    reusedProjectsLocalDiscovery = $true
    independentFilesystemTraversal = $false
    canonicalFilesOnly = $true
    nodeModulesInspected = $false
    executesProjectCode = $false
    installsDependencies = $false
    packageManagersInvoked = $false
    globalRuntimeEvidenceModified = $false
}))

$status = if ($projectModels.Count -eq 0 -and $warnings.Count -eq 0) {
    Get-AuditProviderStatus -NotApplicable
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray()
}

return [pscustomobject][ordered]@{
    providerId = 'projects.javascript-web'
    category   = 'projects'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
