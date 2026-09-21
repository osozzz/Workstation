[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$fixturePath = Join-Path $PSScriptRoot 'command-path-cases.json'

Import-Module $corePath -Force
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

function Get-CaseAnalysis {
    param([Parameter(Mandatory)][object]$Case)

    $pathModel = Get-AuditPathScopeModel -Scope process -RawPath ([string]$Case.processPath)
    return Get-AuditCommandPathAnalysis -CommandResolutions @($Case.resolutions) -ProcessPathEntries @($pathModel.entries)
}

if (-not (Test-AuditPathBasedCommandType -CommandType 'Application')) {
    throw 'Application command type must be treated as PATH-based.'
}

if (-not (Test-AuditPathBasedCommandType -CommandType 'ExternalScript')) {
    throw 'ExternalScript command type must be treated as PATH-based.'
}

if (Test-AuditPathBasedCommandType -CommandType 'Alias') {
    throw 'Alias command type must not be attributed to PATH.'
}

$single = Get-CaseAnalysis -Case $fixture.cases.singleMapped
if ($single.resolutionCount -ne 1 -or $single.mappedResolutionCount -ne 1) {
    throw 'Single mapped command resolution was not normalized correctly.'
}
if ($single.activeResolution.pathPosition -ne 0 -or $single.activeResolution.pathMappingStatus -ne 'mapped') {
    throw 'Single mapped command did not resolve to PATH position 0.'
}
if (-not $single.fullyMapped -or $single.hasPathOrderConflict) {
    throw 'Single mapped command must be fully mapped without a PATH order conflict.'
}

$collision = Get-CaseAnalysis -Case $fixture.cases.pathCollision
if (-not $collision.hasResolutionCollision -or -not $collision.hasPathResolutionCollision -or -not $collision.hasPathOrderConflict) {
    throw 'Distinct PATH origins must produce a PATH precedence conflict.'
}
if ($collision.activeResolution.pathPosition -ne 0) {
    throw 'Active collision resolution must map to PATH position 0.'
}
if (@($collision.shadowedResolutions).Count -ne 1 -or $collision.shadowedResolutions[0].pathPosition -ne 1) {
    throw 'Shadowed collision resolution must map to PATH position 1.'
}
if ($collision.resolutions[0].precedence -ne 0 -or $collision.resolutions[1].precedence -ne 1) {
    throw 'Command resolution precedence order must remain unchanged.'
}

$nonPath = Get-CaseAnalysis -Case $fixture.cases.nonPathPrecedence
if ($nonPath.activeResolution.commandType -ne 'Alias' -or $nonPath.activeResolution.pathBased) {
    throw 'Active alias must remain explicitly non-PATH-based.'
}
if ($nonPath.activeResolution.pathMappingStatus -ne 'not-path-based' -or $null -ne $nonPath.activeResolution.pathPosition) {
    throw 'Non-PATH active resolution must not receive a PATH position.'
}
if ($nonPath.pathBasedResolutionCount -ne 1 -or $nonPath.shadowedResolutions[0].pathPosition -ne 0) {
    throw 'Shadowed executable should still map to the Process PATH independently.'
}
if ($nonPath.hasPathOrderConflict) {
    throw 'Alias precedence over one executable is not a PATH order conflict.'
}

$unmapped = Get-CaseAnalysis -Case $fixture.cases.unmapped
if ($unmapped.unmappedPathResolutionCount -ne 1 -or $unmapped.fullyMapped) {
    throw 'Unmapped PATH-based resolution must remain explicitly partial.'
}
if ($unmapped.activeResolution.pathMappingStatus -ne 'not-in-process-path' -or $null -ne $unmapped.activeResolution.pathPosition) {
    throw 'Unmapped executable must not receive an invented PATH origin.'
}

$equivalent = Get-CaseAnalysis -Case $fixture.cases.equivalentPathEntries
if ($equivalent.activeResolution.pathMappingStatus -ne 'mapped-equivalent-duplicates') {
    throw 'Equivalent normalized PATH entries must remain explicit.'
}
if ($equivalent.activeResolution.pathPosition -ne 0) {
    throw 'Equivalent PATH entries must map to the first effective Process PATH position.'
}
if (@($equivalent.activeResolution.candidatePathPositions).Count -ne 2 -or
    $equivalent.activeResolution.candidatePathPositions[0] -ne 0 -or
    $equivalent.activeResolution.candidatePathPositions[1] -ne 1) {
    throw 'Equivalent PATH candidate positions must preserve all matching positions.'
}
if ($equivalent.hasPathOrderConflict) {
    throw 'Duplicate equivalent PATH entries do not represent distinct command origins.'
}


$providerPath = Join-Path $root 'scripts\Providers\PathPrecedence.Provider.ps1'
$providerSource = Get-Content -LiteralPath $providerPath -Raw
if ($providerSource -match '(?i)\bGet-Command\b') {
    throw 'Derived PATH precedence provider must not rediscover commands with Get-Command.'
}

$previousProcessPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
try {
    [Environment]::SetEnvironmentVariable('Path', 'C:\Primary;C:\Secondary', 'Process')

    $syntheticProvider = [pscustomobject][ordered]@{
        providerId = 'synthetic.runtime'
        category = 'runtime'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @(
            [pscustomobject][ordered]@{
                componentId = 'synthetic-command'
                commandResolutions = @(
                    [pscustomobject][ordered]@{ command='demo'; path='C:\Primary\demo.exe'; commandType='Application'; version=$null; precedence=0; active=$true },
                    [pscustomobject][ordered]@{ command='demo'; path='C:\Secondary\demo.exe'; commandType='Application'; version=$null; precedence=1; active=$false }
                )
            }
        )
        warnings = @()
        errors = @()
        evidence = @()
    }

    $context = [pscustomobject][ordered]@{
        ObservedAt = '2026-09-21T00:00:00Z'
        PreviousProviderResults = @($syntheticProvider)
    }

    $providerResult = & $providerPath -Context $context

    if ($providerResult.providerId -ne 'path.precedence' -or $providerResult.status -ne 'warning') {
        throw "Synthetic precedence provider result was unexpected: $($providerResult.status)"
    }

    if (@($providerResult.components).Count -ne 0) {
        throw 'Derived PATH precedence provider must not own components.'
    }

    $conflict = @($providerResult.warnings | Where-Object code -eq 'COMMAND_PATH_PRECEDENCE_CONFLICT')
    if ($conflict.Count -ne 1) {
        throw 'Synthetic PATH collision must emit exactly one precedence conflict finding.'
    }

    if ($conflict[0].message -notmatch 'C:\\Primary\\demo\.exe' -or
        $conflict[0].message -notmatch 'PATH\[0\]' -or
        $conflict[0].message -notmatch 'C:\\Secondary\\demo\.exe' -or
        $conflict[0].message -notmatch 'PATH\[1\]') {
        throw "PATH conflict finding does not explain active/shadowed positions: $($conflict[0].message)"
    }

    $summary = @($providerResult.evidence | Where-Object evidenceId -eq 'path-precedence.summary')
    if ($summary.Count -ne 1 -or [int]$summary[0].attributes.analyzedCommandCount -ne 1) {
        throw 'Synthetic provider summary must report one analyzed command.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable('Path', $previousProcessPath, 'Process')
}

Write-Host 'Command-to-PATH precedence validation passed.'
