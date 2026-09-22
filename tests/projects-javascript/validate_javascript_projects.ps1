[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$localProvider = Join-Path $root 'scripts\Providers\ProjectsLocal.Provider.ps1'
$provider = Join-Path $root 'scripts\Providers\JavaScriptWebProjects.Provider.ps1'

$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$tempRoot = Join-Path $tempBase "workstation-js-projects-$([guid]::NewGuid().ToString('N'))"

function Write-JsonFile {
    param([string]$Path, [object]$Value)

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $plain = Join-Path $tempRoot 'PlainNode'
    Write-JsonFile -Path (Join-Path $plain 'package.json') -Value @{
        name = 'plain-node'
        engines = @{ node = '>=20' }
        packageManager = 'pnpm@10.0.0'
    }
    '' | Set-Content -LiteralPath (Join-Path $plain 'pnpm-lock.yaml') -Encoding UTF8

    $angular = Join-Path $tempRoot 'AngularApp'
    Write-JsonFile -Path (Join-Path $angular 'package.json') -Value @{
        name = 'angular-app'
        dependencies = @{ '@angular/core' = '^20.0.0' }
    }
    '{}' | Set-Content -LiteralPath (Join-Path $angular 'angular.json') -Encoding UTF8

    $next = Join-Path $tempRoot 'NextApp'
    Write-JsonFile -Path (Join-Path $next 'package.json') -Value @{
        name = 'next-app'
        dependencies = @{ next = '^16.0.0'; react = '^19.0.0' }
    }
    'export default {}' | Set-Content -LiteralPath (Join-Path $next 'next.config.mjs') -Encoding UTF8

    $prisma = Join-Path $tempRoot 'PrismaApp'
    Write-JsonFile -Path (Join-Path $prisma 'package.json') -Value @{
        name = 'prisma-app'
        devDependencies = @{ prisma = '^7.0.0' }
        dependencies = @{ '@prisma/client' = '^7.0.0' }
    }
    New-Item -ItemType Directory -Path (Join-Path $prisma 'prisma') -Force | Out-Null
    'datasource db { provider = "sqlite" }' | Set-Content -LiteralPath (Join-Path $prisma 'prisma\schema.prisma') -Encoding UTF8

    $unpinned = Join-Path $tempRoot 'Unpinned'
    Write-JsonFile -Path (Join-Path $unpinned 'package.json') -Value @{
        name = 'unpinned'
    }

    $conflict = Join-Path $tempRoot 'Conflict'
    Write-JsonFile -Path (Join-Path $conflict 'package.json') -Value @{
        name = 'conflict'
        engines = @{ node = '>=22' }
        packageManager = 'pnpm@10.0.0'
    }
    '20.0.0' | Set-Content -LiteralPath (Join-Path $conflict '.nvmrc') -Encoding UTF8
    '21.0.0' | Set-Content -LiteralPath (Join-Path $conflict '.node-version') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $conflict 'package-lock.json') -Encoding UTF8
    '' | Set-Content -LiteralPath (Join-Path $conflict 'pnpm-lock.yaml') -Encoding UTF8

    $nonJs = Join-Path $tempRoot 'GoOnly'
    New-Item -ItemType Directory -Path $nonJs -Force | Out-Null
    'module synthetic.example/go' | Set-Content -LiteralPath (Join-Path $nonJs 'go.mod') -Encoding UTF8

    $localContext = [pscustomobject][ordered]@{
        ObservedAt               = (Get-Date).ToString('o')
        LocalConfigurationState  = 'loaded'
        LocalConfigurationSource = 'workstation.local.json'
        LocalConfigurationError  = $null
        DevelopmentRoots         = @($tempRoot)
        ProjectDiscoveryMaxDepth = 4
        PreviousProviderResults  = @()
    }

    $local = & $localProvider -Context $localContext
    $context = [pscustomobject][ordered]@{
        ObservedAt = (Get-Date).ToString('o')
        PreviousProviderResults = @($local)
    }

    $result = & $provider -Context $context

    if ($result.providerId -ne 'projects.javascript-web') {
        throw 'Unexpected JavaScript/web project provider id.'
    }

    if (@($result.components).Count -ne 0) {
        throw 'JavaScript/web project provider must remain evidence-only.'
    }

    $summary = @($result.evidence | Where-Object evidenceId -eq 'projects.javascript-web.summary')[0]
    if (-not $summary) { throw 'Missing JavaScript/web summary evidence.' }

    if ([int]$summary.attributes.projectCount -ne 6) {
        throw "Expected 6 JavaScript/web projects, got $($summary.attributes.projectCount)."
    }

    if ([int]$summary.attributes.angularProjectCount -ne 1) {
        throw 'Expected exactly one Angular project.'
    }
    if ([int]$summary.attributes.nextProjectCount -ne 1) {
        throw 'Expected exactly one Next.js project.'
    }
    if ([int]$summary.attributes.prismaProjectCount -ne 1) {
        throw 'Expected exactly one Prisma project.'
    }
    if ([int]$summary.attributes.nodePinConflictCount -ne 1) {
        throw 'Expected exactly one Node-pin conflict.'
    }
    if ([int]$summary.attributes.packageManagerConflictCount -ne 1) {
        throw 'Expected exactly one package-manager conflict.'
    }

    foreach ($flag in @('readOnly','reusedProjectsLocalDiscovery','canonicalFilesOnly')) {
        if ($summary.attributes.$flag -ne $true) {
            throw "Expected $flag=true."
        }
    }

    foreach ($flag in @(
        'independentFilesystemTraversal',
        'nodeModulesInspected',
        'executesProjectCode',
        'installsDependencies',
        'packageManagersInvoked',
        'globalRuntimeEvidenceModified'
    )) {
        if ($summary.attributes.$flag -ne $false) {
            throw "Expected $flag=false."
        }
    }

    $projects = @($summary.attributes.projects)
    $types = @($projects | ForEach-Object { @($_.types) })
    foreach ($requiredType in @('node-package','angular','nextjs','prisma')) {
        if ($types -notcontains $requiredType) {
            throw "Missing project type '$requiredType'."
        }
    }

    $conflictProject = @($projects | Where-Object packageName -eq 'conflict')[0]
    if (-not $conflictProject.nodePinConflict -or -not $conflictProject.packageManagerConflict) {
        throw 'Conflict project must preserve both conflict dimensions.'
    }
    if (@($conflictProject.nodePins).Count -ne 3) {
        throw 'Conflict project must preserve .nvmrc, .node-version, and engines.node.'
    }
    if (@($conflictProject.lockManagers | Sort-Object) -join '|' -ne 'npm|pnpm') {
        throw 'Conflict project must preserve npm and pnpm lockfile signals.'
    }

    $unpinnedProject = @($projects | Where-Object packageName -eq 'unpinned')[0]
    if (@($unpinnedProject.nodePins).Count -ne 0) {
        throw 'Unpinned project must remain explicitly unpinned.'
    }

    $warningCodes = @($result.warnings | ForEach-Object code)
    foreach ($requiredCode in @('JS_PROJECT_NODE_PIN_CONFLICT','JS_PROJECT_PACKAGE_MANAGER_CONFLICT')) {
        if ($warningCodes -notcontains $requiredCode) {
            throw "Missing warning '$requiredCode'."
        }
    }

    $source = Get-Content -LiteralPath $provider -Raw
    foreach ($forbidden in @(
        'node_modules',
        'npm install',
        'pnpm install',
        'yarn install',
        'bun install',
        'Invoke-AuditCommand'
    )) {
        if ($source -match [Regex]::Escape($forbidden)) {
            if ($forbidden -eq 'node_modules' -and $source -match 'nodeModulesInspected') {
                continue
            }
            throw "Provider source contains forbidden execution/traversal marker '$forbidden'."
        }
    }

    Write-Host 'JavaScript and web project detection validation passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
