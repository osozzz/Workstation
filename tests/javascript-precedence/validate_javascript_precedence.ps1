[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$providerPath = Join-Path $root 'scripts\Providers\JavaScriptPrecedence.Provider.ps1'
$javascriptProviderPath = Join-Path $root 'scripts\Providers\JavaScriptToolchain.Provider.ps1'
$pathProviderPath = Join-Path $root 'scripts\Providers\PathPrecedence.Provider.ps1'
$environmentProviderPath = Join-Path $root 'scripts\Providers\EnvironmentBaseline.Provider.ps1'
$fixturePath = Join-Path $PSScriptRoot 'javascript-precedence-cases.json'

Import-Module $corePath -Force
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

function Get-OptionalPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function New-UnsetScopeValue {
    param([Parameter(Mandatory)][string]$Scope)

    return [pscustomobject][ordered]@{
        scope = $Scope
        state = 'unset'
        raw = $null
        expanded = $null
        normalized = $null
        comparisonKey = $null
        exists = $null
        pathItems = @()
        missingPathCount = 0
        hasUnresolvedVariable = $false
        unresolvedVariables = @()
        unapprovedReferenceCount = 0
        isConfigured = $false
        isInvalid = $false
    }
}

function New-EnvironmentVariableEvidence {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Definition
    )

    $processScope = New-UnsetScopeValue -Scope 'process'

    if ($null -ne $Definition) {
        $value = [string](Get-OptionalPropertyValue -InputObject $Definition -Name 'value')
        $existsValue = Get-OptionalPropertyValue -InputObject $Definition -Name 'exists'
        $entry = ConvertTo-AuditPathEntry -Scope process -Position 0 -Entry $value -EnvironmentValues @{}

        $processScope = [pscustomobject][ordered]@{
            scope = 'process'
            state = 'value'
            raw = $value
            expanded = $entry.expanded
            normalized = $entry.normalized
            comparisonKey = $entry.comparisonKey
            exists = $(if ($null -eq $existsValue) { $null } else { [bool]$existsValue })
            pathItems = @($entry)
            missingPathCount = $(if ($existsValue -eq $false) { 1 } else { 0 })
            hasUnresolvedVariable = $false
            unresolvedVariables = @()
            unapprovedReferenceCount = 0
            isConfigured = $true
            isInvalid = $false
        }
    }

    return New-AuditEvidence -EvidenceId "environment.$($Name.ToLowerInvariant())" -Type environment -Source $Name -Captured $null -Attributes @{
        scopes = @(
            $processScope,
            (New-UnsetScopeValue -Scope 'user'),
            (New-UnsetScopeValue -Scope 'machine')
        )
    }
}

function New-SyntheticEnvironmentProvider {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][object]$PathModel
    )

    $environmentEvidence = [System.Collections.Generic.List[object]]::new()

    foreach ($name in @('NVM_HOME', 'NVM_SYMLINK', 'PNPM_HOME')) {
        $definition = Get-OptionalPropertyValue -InputObject $Case.environment -Name $name
        $environmentEvidence.Add((New-EnvironmentVariableEvidence -Name $name -Definition $definition))
    }

    $environmentEvidence.Add((New-AuditEvidence -EvidenceId 'path.process.health' -Type path -Source 'process PATH' -Captured $null -Attributes @{
        entryCount = $PathModel.entryCount
        duplicateCount = $PathModel.duplicateCount
        missingCount = $PathModel.missingCount
        unresolvedVariableCount = $PathModel.unresolvedVariableCount
        entries = $PathModel.entries
    }))

    return [pscustomobject][ordered]@{
        providerId = 'environment.baseline'
        category = 'environment'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @()
        warnings = @()
        errors = @()
        evidence = $environmentEvidence.ToArray()
    }
}

function Get-CaseCommandResolutions {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][string]$Command
    )

    $value = Get-OptionalPropertyValue -InputObject $Case.resolutions -Name $Command
    if ($null -eq $value) {
        return @()
    }

    return @($value)
}

function New-SyntheticJavascriptProvider {
    param([Parameter(Mandatory)][object]$Case)

    $components = [System.Collections.Generic.List[object]]::new()

    foreach ($componentId in @('nvm-windows', 'node', 'npm', 'pnpm')) {
        $stateValue = Get-OptionalPropertyValue -InputObject $Case.components -Name $componentId
        $command = switch ($componentId) {
            'nvm-windows' { 'nvm' }
            default { $componentId }
        }

        $components.Add([pscustomobject][ordered]@{
            componentId = $componentId
            state = $(if ($null -eq $stateValue) { 'missing' } else { [string]$stateValue })
            commandResolutions = @(Get-CaseCommandResolutions -Case $Case -Command $command)
        })
    }

    return [pscustomobject][ordered]@{
        providerId = 'javascript.toolchain'
        category = 'runtime'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = $components.ToArray()
        warnings = @()
        errors = @()
        evidence = @()
    }
}

function New-SyntheticPathProvider {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][object]$PathModel
    )

    $pathEvidence = [System.Collections.Generic.List[object]]::new()

    foreach ($commandProperty in @($Case.resolutions.PSObject.Properties)) {
        $command = [string]$commandProperty.Name
        $resolutions = @($commandProperty.Value)
        if ($resolutions.Count -eq 0) {
            continue
        }

        $analysis = Get-AuditCommandPathAnalysis -CommandResolutions $resolutions -ProcessPathEntries @($PathModel.entries)

        $pathEvidence.Add((New-AuditEvidence -EvidenceId "path-precedence.command.$command" -Type derived -Source "synthetic command PATH precedence: $command" -Captured $null -Attributes @{
            command = $analysis.command
            resolutionCount = $analysis.resolutionCount
            pathBasedResolutionCount = $analysis.pathBasedResolutionCount
            mappedResolutionCount = $analysis.mappedResolutionCount
            unmappedPathResolutionCount = $analysis.unmappedPathResolutionCount
            hasResolutionCollision = $analysis.hasResolutionCollision
            hasPathResolutionCollision = $analysis.hasPathResolutionCollision
            hasPathOrderConflict = $analysis.hasPathOrderConflict
            fullyMapped = $analysis.fullyMapped
            activeResolution = $analysis.activeResolution
            shadowedResolutions = $analysis.shadowedResolutions
            resolutions = $analysis.resolutions
        }))
    }

    return [pscustomobject][ordered]@{
        providerId = 'path.precedence'
        category = 'environment'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @()
        warnings = @()
        errors = @()
        evidence = $pathEvidence.ToArray()
    }
}

function Get-EvidenceById {
    param(
        [Parameter(Mandatory)][object]$ProviderResult,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    return @(
        @($ProviderResult.evidence) |
            Where-Object { [string]$_.evidenceId -eq $EvidenceId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

$providerDescription = & $providerPath -Describe
$javascriptDescription = & $javascriptProviderPath -Describe
$pathDescription = & $pathProviderPath -Describe
$environmentDescription = & $environmentProviderPath -Describe

if ($providerDescription.providerId -ne 'javascript.precedence') {
    throw 'JavaScript precedence provider id changed unexpectedly.'
}

if (
    [int]$providerDescription.order -le [int]$javascriptDescription.order -or
    [int]$providerDescription.order -le [int]$pathDescription.order -or
    [int]$providerDescription.order -le [int]$environmentDescription.order
) {
    throw 'JavaScript precedence provider must run after JavaScript, PATH precedence, and environment baseline providers.'
}

$providerSource = Get-Content -LiteralPath $providerPath -Raw
foreach ($forbiddenPattern in @(
    '(?i)\bGet-Command\b',
    '(?i)\bInvoke-AuditCommand\b',
    '(?i)GetEnvironmentVariable',
    '(?i)SetEnvironmentVariable',
    '(?i)\bTest-Path\b',
    '(?i)\bnvm\s+(install|use|uninstall)\b',
    '(?i)\bcorepack\s+(enable|disable|prepare|use|install)\b',
    '(?i)\bpnpm\s+(add|install|update|remove)\b',
    '(?i)\bnpm\s+(install|update)\b'
)) {
    if ($providerSource -match $forbiddenPattern) {
        throw "JavaScript precedence provider contains forbidden discovery/mutation pattern: $forbiddenPattern"
    }
}

$results = @{}

foreach ($caseProperty in @($fixture.cases.PSObject.Properties)) {
    $caseName = [string]$caseProperty.Name
    $case = $caseProperty.Value

    $pathModel = Get-AuditPathScopeModel -Scope process -RawPath ([string]$case.processPath)
    $javascriptProvider = New-SyntheticJavascriptProvider -Case $case
    $pathProvider = New-SyntheticPathProvider -Case $case -PathModel $pathModel
    $environmentProvider = New-SyntheticEnvironmentProvider -Case $case -PathModel $pathModel

    $context = [pscustomobject][ordered]@{
        ObservedAt = '2026-09-21T00:00:00Z'
        PreviousProviderResults = @(
            $javascriptProvider,
            $pathProvider,
            $environmentProvider
        )
    }

    $result = & $providerPath -Context $context
    $results[$caseName] = $result

    if ($result.providerId -ne 'javascript.precedence') {
        throw "$caseName returned unexpected provider id '$($result.providerId)'."
    }

    if (@($result.components).Count -ne 0) {
        throw "${caseName}: derived JavaScript precedence provider must own zero components."
    }

    $summary = Get-EvidenceById -ProviderResult $result -EvidenceId 'javascript-precedence.summary'
    if ($null -eq $summary) {
        throw "${caseName}: missing JavaScript precedence summary evidence."
    }

    if ($summary.attributes.readOnly -ne $true -or $summary.attributes.duplicatedRuntimeDiscovery -ne $false) {
        throw "${caseName}: summary must preserve the read-only/no-rediscovery boundary."
    }

    foreach ($dependencyName in @('javascriptToolchain', 'pathPrecedence', 'environmentBaseline')) {
        if ($summary.attributes.dependencies.$dependencyName -ne $true) {
            throw "${caseName}: expected dependency '$dependencyName' to be available."
        }
    }

    $actualCodes = @($result.warnings | ForEach-Object { [string]$_.code } | Sort-Object)
    $expectedCodes = @($case.expectedWarningCodes | ForEach-Object { [string]$_ } | Sort-Object)

    if (($actualCodes -join '|') -ne ($expectedCodes -join '|')) {
        throw "$caseName warning mismatch. Expected '$($expectedCodes -join ', ')', got '$($actualCodes -join ', ')'."
    }

    if ($expectedCodes.Count -eq 0 -and $result.status -ne 'success') {
        throw "$caseName must remain successful when no conflict is expected; status=$($result.status)."
    }

    if ($expectedCodes.Count -gt 0 -and $result.status -ne 'warning') {
        throw "$caseName must report warning status when conflicts are present; status=$($result.status)."
    }
}

$intended = $results['intendedNvmLayout']
$intendedEnvironment = Get-EvidenceById -ProviderResult $intended -EvidenceId 'javascript-precedence.environment'
$intendedNode = Get-EvidenceById -ProviderResult $intended -EvidenceId 'javascript-precedence.command.node'
$intendedPnpm = Get-EvidenceById -ProviderResult $intended -EvidenceId 'javascript-precedence.command.pnpm'

if ($intendedEnvironment.attributes.nvmHome.firstPathPosition -ne 0 -or
    $intendedEnvironment.attributes.nvmSymlink.firstPathPosition -ne 1 -or
    $intendedEnvironment.attributes.nvmPathOrder -ne 'home-before-symlink') {
    throw 'Intended NVM layout must preserve NVM_HOME/NVM_SYMLINK Process PATH positions and order.'
}

if ($intendedNode.attributes.relationship.relationship -ne 'aligned') {
    throw 'Intended NVM layout must align active Node.js with NVM_SYMLINK.'
}

if ($intendedPnpm.attributes.relationship.relationship -ne 'aligned') {
    throw 'Intended NVM layout must align active pnpm with PNPM_HOME.'
}

$shadowing = $results['directNodeShadowing']
$shadowingNode = Get-EvidenceById -ProviderResult $shadowing -EvidenceId 'javascript-precedence.command.node'
if ($shadowingNode.attributes.relationship.relationship -ne 'mismatch' -or
    $shadowingNode.attributes.relationship.activePathPosition -ne 0 -or
    $shadowingNode.attributes.relationship.expectedPathPosition -ne 2) {
    throw 'Direct Node shadowing must prove the active direct installation precedes NVM_SYMLINK.'
}

$shadowWarning = @($shadowing.warnings | Where-Object code -eq 'NODE_BYPASSES_NVM_SYMLINK')
if ($shadowWarning.Count -ne 1 -or
    $shadowWarning[0].message -notmatch 'DirectNode' -or
    $shadowWarning[0].message -notmatch 'PATH\[0\]' -or
    $shadowWarning[0].message -notmatch 'NvmShim' -or
    $shadowWarning[0].message -notmatch 'PATH\[2\]') {
    throw 'Node bypass warning must explain active and intended NVM PATH positions.'
}

$pnpmConflict = $results['pnpmConflict']
$pnpmEvidence = Get-EvidenceById -ProviderResult $pnpmConflict -EvidenceId 'javascript-precedence.command.pnpm'
if ($pnpmEvidence.attributes.relationship.relationship -ne 'mismatch' -or
    $pnpmEvidence.attributes.relationship.activePathPosition -ne 0 -or
    $pnpmEvidence.attributes.relationship.expectedPathPosition -ne 1) {
    throw 'pnpm conflict must preserve active and PNPM_HOME PATH positions.'
}

$missingOptional = $results['missingOptionalTooling']
$missingSummary = Get-EvidenceById -ProviderResult $missingOptional -EvidenceId 'javascript-precedence.summary'
if ($missingSummary.attributes.nvmPresent -ne $false -or
    $missingSummary.attributes.pnpmPresent -ne $false -or
    @($missingOptional.warnings).Count -ne 0) {
    throw 'Missing optional NVM/pnpm tooling must remain neutral when their configuration is absent.'
}

Write-Host 'JavaScript PATH/environment precedence validation passed.'
