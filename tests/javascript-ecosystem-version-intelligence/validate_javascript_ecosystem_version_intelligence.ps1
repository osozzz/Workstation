[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$jsVersionCore = Join-Path $root 'scripts\Core\JavaScriptVersionIntelligence.Core.psm1'
$providerPath = Join-Path $root 'scripts\Providers\JavaScriptToolchain.Provider.ps1'

Import-Module $jsVersionCore -Force

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestVersionRecord {
    param(
        [Parameter(Mandatory)][string]$Version,
        [AllowNull()][string]$Channel
    )

    [pscustomobject][ordered]@{
        raw = $Version
        normalized = $Version.TrimStart('v', 'V')
        channel = $Channel
    }
}

function New-Decoded {
    param(
        [Parameter(Mandatory)][string]$Source,
        [AllowNull()][object]$Data,
        [ValidateSet('known','unknown','unavailable')][string]$Status = 'known'
    )

    [pscustomobject][ordered]@{
        status = $Status
        source = $Source
        checkedAt = '2026-09-23T16:45:00.0000000+00:00'
        data = $(if ($Status -eq 'known') { $Data } else { $null })
        message = $(if ($Status -eq 'known') { $null } else { 'synthetic unavailable' })
    }
}

$angularTags = [pscustomobject][ordered]@{
    latest = '21.2.4'
    next = '22.0.0-next.3'
}

$angular = Resolve-AngularCliVersionIntelligence -DecodedSource (New-Decoded -Source 'npm-registry-dist-tags:@angular/cli' -Data $angularTags) -InstalledVersion (New-TestVersionRecord -Version '21.2.3' -Channel stable)

Assert-True ($angular.intelligence.status -eq 'known') 'Angular intelligence must be known.'
Assert-True ($angular.latestStable.normalized -eq '21.2.4') 'Angular must report the latest stable dist-tag.'
Assert-True ($angular.latestStable.channel -eq 'stable') 'Angular latest version must use the stable channel.'
Assert-True ($angular.updateAvailable -eq $true) 'Synthetic Angular install should report a stable update.'
Assert-True ($angular.majorMigrationRequiresExplicitAction -eq $true) 'Angular major migration must remain explicit.'
Assert-True ($angular.projectCompatibilityOverridesGlobal -eq $true) 'Angular project compatibility must override global latest.'
Assert-True ($angular.intelligence.source -eq 'npm-registry-dist-tags:@angular/cli') 'Angular source identity must be explicit.'
Assert-True ($angular.intelligence.checkedAt -eq '2026-09-23T16:45:00.0000000+00:00') 'Angular checkedAt must be preserved.'

$typescriptTags = [pscustomobject][ordered]@{
    latest = '5.9.3'
    next = '6.0.0-dev.20260923'
    beta = '6.0.0-beta'
}

$typescript = Resolve-TypeScriptVersionIntelligence -DecodedSource (New-Decoded -Source 'npm-registry-dist-tags:typescript' -Data $typescriptTags) -InstalledVersion (New-TestVersionRecord -Version '5.9.3' -Channel stable)

Assert-True ($typescript.intelligence.status -eq 'known') 'TypeScript intelligence must be known.'
Assert-True ($typescript.latestStable.normalized -eq '5.9.3') 'TypeScript stable dist-tag must be reported.'
Assert-True ($typescript.latestPrerelease.normalized -eq '6.0.0-dev.20260923') 'TypeScript prerelease channel must be reported separately.'
Assert-True ($typescript.latestPrerelease.channel -eq 'next') 'TypeScript prerelease must retain its dist-tag channel.'
Assert-True ($typescript.prereleaseTag -eq 'next') 'TypeScript prerelease tag must be explicit.'
Assert-True ($typescript.intelligence.latestCurrent.normalized -eq '6.0.0-dev.20260923') 'TypeScript prerelease must occupy the contract current slot.'
Assert-True ($typescript.stableUpdateAvailable -eq $false) 'Current stable TypeScript must not report a stable update.'
Assert-True ($typescript.prereleaseRequiresExplicitOptIn -eq $true) 'TypeScript prerelease adoption must require explicit opt-in.'
Assert-True ($typescript.projectCompatibilityOverridesGlobal -eq $true) 'TypeScript project compatibility must override global latest.'

$prismaTags = [pscustomobject][ordered]@{
    latest = '7.1.0'
    rc = '7.2.0-rc.2'
    dev = '7.3.0-dev.12'
}

$prisma = Resolve-PrismaVersionIntelligence -DecodedSource (New-Decoded -Source 'npm-registry-dist-tags:prisma' -Data $prismaTags) -InstalledVersion (New-TestVersionRecord -Version '7.0.1' -Channel stable)

Assert-True ($prisma.intelligence.status -eq 'known') 'Prisma intelligence must be known.'
Assert-True ($prisma.latestStable.normalized -eq '7.1.0') 'Prisma stable dist-tag must be reported.'
Assert-True ($prisma.latestReleaseCandidate.normalized -eq '7.2.0-rc.2') 'Prisma release candidate must be reported separately.'
Assert-True ($prisma.latestReleaseCandidate.channel -eq 'rc') 'Prisma release candidate must retain the rc channel.'
Assert-True ($prisma.releaseCandidateTag -eq 'rc') 'Prisma RC tag must be explicit.'
Assert-True ($prisma.intelligence.latestCurrent.normalized -eq '7.2.0-rc.2') 'Prisma RC must occupy the contract current slot.'
Assert-True ($prisma.stableUpdateAvailable -eq $true) 'Synthetic Prisma install should report a stable update.'
Assert-True ($prisma.releaseCandidateRequiresExplicitOptIn -eq $true) 'Prisma RC adoption must require explicit opt-in.'
Assert-True ($prisma.projectPinsOverrideGlobal -eq $true) 'Prisma project-local pins must override global latest.'

$prismaAlternateTags = [pscustomobject][ordered]@{
    latest = '7.1.0'
    preview = '7.2.0-rc.4'
}
$prismaAlternate = Resolve-PrismaVersionIntelligence -DecodedSource (New-Decoded -Source 'npm-registry-dist-tags:prisma' -Data $prismaAlternateTags) -InstalledVersion $null
Assert-True ($prismaAlternate.latestReleaseCandidate.normalized -eq '7.2.0-rc.4') 'Prisma must identify an RC version even when the dist-tag name is not exactly rc.'

$offlineAngular = Resolve-AngularCliVersionIntelligence -DecodedSource (New-Decoded -Source 'npm-registry-dist-tags:@angular/cli' -Data $null -Status unavailable) -InstalledVersion $null
$offlineTypeScript = Resolve-TypeScriptVersionIntelligence -DecodedSource (New-Decoded -Source 'npm-registry-dist-tags:typescript' -Data $null -Status unavailable) -InstalledVersion $null
$offlinePrisma = Resolve-PrismaVersionIntelligence -DecodedSource (New-Decoded -Source 'npm-registry-dist-tags:prisma' -Data $null -Status unavailable) -InstalledVersion $null

foreach ($offline in @($offlineAngular, $offlineTypeScript, $offlinePrisma)) {
    Assert-True ($offline.intelligence.status -eq 'unavailable') 'Offline ecosystem intelligence must be unavailable.'
    Assert-True ($null -eq $offline.intelligence.latestStable) 'Offline ecosystem intelligence must not fabricate stable versions.'
    Assert-True ($null -eq $offline.intelligence.latestCurrent) 'Offline ecosystem intelligence must not fabricate prerelease versions.'
}

$source = Get-Content -LiteralPath $providerPath -Raw

foreach ($marker in @(
    'npm-registry-dist-tags:@angular/cli',
    'https://registry.npmjs.org/-/package/@angular%2fcli/dist-tags',
    'npm-registry-dist-tags:typescript',
    'https://registry.npmjs.org/-/package/typescript/dist-tags',
    'npm-registry-dist-tags:prisma',
    'https://registry.npmjs.org/-/package/prisma/dist-tags',
    'majorMigrationRequiresExplicitAction',
    'prereleaseRequiresExplicitOptIn',
    'releaseCandidateRequiresExplicitOptIn',
    'projectCompatibilityOverridesGlobal',
    'projectPinsOverrideGlobal'
)) {
    if ($source -notmatch [Regex]::Escape($marker)) {
        throw "Missing provider marker: $marker"
    }
}

foreach ($forbidden in @(
    'ng update',
    'npm install -g @angular/cli',
    'npm install -g typescript',
    'npm install -g prisma',
    'pnpm add -g @angular/cli',
    'pnpm add -g typescript',
    'pnpm add -g prisma',
    'prisma migrate',
    'prisma db push'
)) {
    if ($source -match [Regex]::Escape($forbidden)) {
        throw "Forbidden mutation marker: $forbidden"
    }
}

Write-Host 'Angular TypeScript Prisma version intelligence validation passed.'
