[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$auditPath = Join-Path $root 'scripts\Audit-Workstation.ps1'
$workflowPath = Join-Path $root '.github\workflows\validate.yml'
$policyPath = Join-Path $root 'config\workstation.policy.json'
$gitignorePath = Join-Path $root '.gitignore'

function Assert-True {
    param(
        [bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-Provider {
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$ProviderId
    )

    return @(
        $Report.providers |
            Where-Object providerId -eq $ProviderId |
            Select-Object -First 1
    )[0]
}

function Get-Evidence {
    param(
        [Parameter(Mandatory)][object]$Provider,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    return @(
        $Provider.evidence |
            Where-Object evidenceId -eq $EvidenceId |
            Select-Object -First 1
    )[0]
}

$fixtureValidators = @(
    'tests\version-intelligence-runtime\validate_version_intelligence_runtime.ps1',
    'tests\javascript-version-intelligence\validate_javascript_version_intelligence.ps1',
    'tests\javascript-ecosystem-version-intelligence\validate_javascript_ecosystem_version_intelligence.ps1',
    'tests\jvm-mobile-version-intelligence\validate_jvm_mobile_version_intelligence.ps1',
    'tests\winget-upgrade-intelligence\validate_winget_upgrade_intelligence.ps1'
)

foreach ($relativePath in $fixtureValidators) {
    Assert-True (Test-Path -LiteralPath (Join-Path $root $relativePath) -PathType Leaf) "Missing Sprint 5 fixture validator: $relativePath"
}

$workflowSource = Get-Content -LiteralPath $workflowPath -Raw
foreach ($relativePath in $fixtureValidators) {
    $workflowMarker = './' + ($relativePath -replace '\\', '/')
    Assert-True ($workflowSource -match [Regex]::Escape($workflowMarker)) "CI must run Sprint 5 fixture validator: $workflowMarker"
}
Assert-True ($workflowSource -match [Regex]::Escape('./tests/sprint5-integration/validate_sprint5_version_intelligence.ps1')) 'CI must run the Sprint 5 integration gate.'

$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
Assert-True ($policy.windows.updatePolicy -eq 'review-then-upgrade') 'Windows update policy must remain review-then-upgrade.'
Assert-True ($policy.node.defaultTrack -eq 'lts') 'Node default track must remain LTS.'
Assert-True ($policy.versioning.projectCompatibilityOverridesGlobal -eq $true) 'Project compatibility must override global version intelligence.'
Assert-True ($policy.versioning.prereleasePolicy -eq 'explicit-opt-in-only') 'Prerelease adoption must remain explicit opt-in.'

$gitignoreLines = @(
    Get-Content -LiteralPath $gitignorePath |
        ForEach-Object { $_.Trim() }
)
Assert-True ($gitignoreLines -contains 'reports/') 'Generated audit reports must remain ignored by Git.'
Assert-True ($gitignoreLines -contains 'config/workstation.local.json') 'Machine-local workstation configuration must remain ignored by Git.'

$safetyRoots = @(
    'tests\version-intelligence-runtime',
    'tests\javascript-version-intelligence',
    'tests\javascript-ecosystem-version-intelligence',
    'tests\jvm-mobile-version-intelligence',
    'tests\winget-upgrade-intelligence'
)

$forbiddenCommittedMarkers = @(
    'c:\users\',
    '/home/',
    'ghp_',
    'github_pat_',
    'bearer '
)

foreach ($relativeRoot in $safetyRoots) {
    $scanRoot = Join-Path $root $relativeRoot
    foreach ($file in @(Get-ChildItem -LiteralPath $scanRoot -Recurse -File)) {
        $content = (Get-Content -LiteralPath $file.FullName -Raw).ToLowerInvariant()
        foreach ($marker in $forbiddenCommittedMarkers) {
            Assert-True (-not $content.Contains($marker)) "Committed Sprint 5 test source contains forbidden machine/credential marker '$marker': $($file.FullName)"
        }
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('workstation-sprint5-' + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $tempRoot 'SyntheticPinnedProject'
$reportRoot = Join-Path $tempRoot 'reports'
$localConfigPath = Join-Path $tempRoot 'workstation.local.json'
$failureProviderPath = Join-Path $tempRoot 'SyntheticVersionFailure.Provider.ps1'

try {
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $projectRoot 'prisma') -Force | Out-Null

    [ordered]@{
        name = 'synthetic-pinned-project'
        private = $true
        engines = [ordered]@{
            node = '20.19.5'
        }
        packageManager = 'pnpm@9.15.4'
        devDependencies = [ordered]@{
            '@angular/cli' = '20.3.0'
            '@angular/core' = '20.3.0'
            typescript = '5.8.3'
            prisma = '6.16.0'
            '@prisma/client' = '6.16.0'
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $projectRoot 'package.json') -Encoding UTF8

    '20.19.5' | Set-Content -LiteralPath (Join-Path $projectRoot '.nvmrc') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $projectRoot 'angular.json') -Encoding UTF8
    'generator client { provider = "prisma-client-js" }' | Set-Content -LiteralPath (Join-Path $projectRoot 'prisma\schema.prisma') -Encoding UTF8

    [ordered]@{
        projects = [ordered]@{
            developmentRoots = @($projectRoot)
            maxDiscoveryDepth = 2
        }
        git = [ordered]@{
            branchStaleDays = 90
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $localConfigPath -Encoding UTF8

    @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.version-intelligence-failure'
        category   = 'synthetic'
        order      = 19
    }
}

throw 'Synthetic early provider failure for Sprint 5 isolation validation.'
'@ | Set-Content -LiteralPath $failureProviderPath -Encoding UTF8

    $auditParameters = @{
        OutputDirectory = $reportRoot
        LocalConfigurationPath = $localConfigPath
        AdditionalProviderPath = @($failureProviderPath)
        OfflineVersionIntelligence = $true
        PassThru = $true
    }

    $result = & $auditPath @auditParameters
    $report = $result.Report

    Assert-True ($report.schemaVersion -eq '1.0.0') 'Integrated audit must preserve report schema 1.0.0.'
    Assert-True ($report.audit.mode -eq 'read-only') 'Integrated Sprint 5 audit must remain read-only.'
    Assert-True ($report.summary.providerCount -eq 21) 'Expected 20 built-in providers plus one controlled failure provider.'

    $syntheticFailure = Get-Provider -Report $report -ProviderId 'synthetic.version-intelligence-failure'
    Assert-True ($null -ne $syntheticFailure) 'Controlled early failure provider must appear in the report.'
    Assert-True ($syntheticFailure.status -eq 'failed') 'Controlled early failure provider must be normalized as failed.'

    $laterProviderIds = @(
        'javascript.toolchain',
        'java.jvm',
        'mobile.flutter-android',
        'winget.baseline',
        'projects.local',
        'projects.javascript-web',
        'projects.non-javascript',
        'git.repository-health',
        'git.branch-worktree-hygiene'
    )

    foreach ($providerId in $laterProviderIds) {
        $provider = Get-Provider -Report $report -ProviderId $providerId
        Assert-True ($null -ne $provider) "Provider '$providerId' must still be attempted after an earlier provider failure."
    }

    foreach ($providerId in @('javascript.toolchain', 'java.jvm', 'mobile.flutter-android', 'winget.baseline')) {
        $provider = Get-Provider -Report $report -ProviderId $providerId
        Assert-True ($provider.status -ne 'failed') "Sprint 5 provider '$providerId' must not fail the complete offline audit."
    }

    $attemptedIntelligenceCount = 0
    foreach ($provider in @($report.providers)) {
        foreach ($component in @($provider.components)) {
            $intelligence = $component.versionIntelligence
            if ($null -eq $intelligence) {
                continue
            }

            if ($intelligence.status -in @('known', 'unknown', 'unavailable')) {
                $attemptedIntelligenceCount++
                Assert-True (-not [string]::IsNullOrWhiteSpace([string]$intelligence.source)) "$($provider.providerId)/$($component.componentId) attempted version intelligence without a source identity."
                Assert-True (-not [string]::IsNullOrWhiteSpace([string]$intelligence.checkedAt)) "$($provider.providerId)/$($component.componentId) attempted version intelligence without checkedAt."

                [DateTimeOffset]$parsed = [DateTimeOffset]::MinValue
                Assert-True ([DateTimeOffset]::TryParse([string]$intelligence.checkedAt, [ref]$parsed)) "$($provider.providerId)/$($component.componentId) has an invalid checkedAt timestamp."
            }
        }
    }

    Assert-True ($attemptedIntelligenceCount -ge 1) 'Integrated audit must exercise at least one normalized version-intelligence result.'

    $javascriptProvider = Get-Provider -Report $report -ProviderId 'javascript.toolchain'
    foreach ($componentId in @('node', 'npm', 'pnpm')) {
        $component = @(
            $javascriptProvider.components |
                Where-Object componentId -eq $componentId |
                Select-Object -First 1
        )[0]

        if ($null -ne $component -and $component.installed -eq $true) {
            Assert-True ($component.versionIntelligence.status -in @('unknown', 'unavailable')) "Offline '$componentId' intelligence must degrade to unknown/unavailable."
        }
    }

    $projectsProvider = Get-Provider -Report $report -ProviderId 'projects.javascript-web'
    Assert-True ($projectsProvider.status -ne 'failed') 'JavaScript project classification must survive the integrated audit.'

    $projectSummary = Get-Evidence -Provider $projectsProvider -EvidenceId 'projects.javascript-web.summary'
    Assert-True ($null -ne $projectSummary) 'Integrated audit must preserve JavaScript project summary evidence.'
    Assert-True ($projectSummary.attributes.dependencyAvailable -eq $true) 'JavaScript project classification must reuse projects.local evidence.'
    Assert-True ([int]$projectSummary.attributes.projectCount -eq 1) 'Synthetic pinned project must be classified exactly once.'
    Assert-True ($projectSummary.attributes.globalRuntimeEvidenceModified -eq $false) 'Project classification must not modify global runtime evidence.'
    Assert-True ($projectSummary.attributes.readOnly -eq $true) 'Project classification must remain read-only.'

    $project = @($projectSummary.attributes.projects)[0]
    Assert-True ($null -ne $project) 'Synthetic pinned project evidence must be retained.'
    Assert-True ($project.frameworkMarkers.angular -eq $true) 'Synthetic Angular marker must be retained.'
    Assert-True ($project.frameworkMarkers.prisma -eq $true) 'Synthetic Prisma marker must be retained.'
    Assert-True ($project.packageManager.name -eq 'pnpm') 'Project-local package manager must remain pnpm.'
    Assert-True ($project.packageManager.version -eq '9.15.4') 'Project-local pnpm pin must remain unchanged.'

    $nodePinValues = @($project.nodePins | ForEach-Object { [string]$_.value })
    Assert-True ($nodePinValues -contains '20.19.5') 'Project-local Node pin must remain separate from global latest intelligence.'
    Assert-True ($project.nodePinConflict -eq $false) 'Equivalent synthetic Node pins must not become a conflict.'

    $wingetProvider = Get-Provider -Report $report -ProviderId 'winget.baseline'
    if ($null -ne $wingetProvider) {
        $wingetComponent = @(
            $wingetProvider.components |
                Where-Object componentId -eq 'winget' |
                Select-Object -First 1
        )[0]

        if ($null -ne $wingetComponent -and $wingetComponent.installed -eq $true) {
            $upgradeEvidence = Get-Evidence -Provider $wingetProvider -EvidenceId 'winget.upgrades.normalized'
            Assert-True ($null -ne $upgradeEvidence) 'Installed WinGet must preserve normalized upgrade evidence.'
            Assert-True ($upgradeEvidence.attributes.reviewOnly -eq $true) 'WinGet upgrade intelligence must remain review-only.'
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$upgradeEvidence.attributes.checkedAt)) 'WinGet upgrade intelligence must preserve checkedAt.'
        }
    }

    Assert-True (Test-Path -LiteralPath $result.JsonPath -PathType Leaf) 'Integrated audit JSON report must be generated in temporary storage.'
    Assert-True (Test-Path -LiteralPath $result.MarkdownPath -PathType Leaf) 'Integrated audit Markdown report must be generated in temporary storage.'
    Assert-True ($result.JsonPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) 'Integrated audit JSON report must remain temporary.'
    Assert-True ($result.MarkdownPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) 'Integrated audit Markdown report must remain temporary.'

    Write-Host 'Sprint 5 Version Intelligence integration gate passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
