[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$fixturePath = Join-Path $PSScriptRoot 'path-model-cases.json'

Import-Module $corePath -Force
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

$previousValues = @{}

try {
    foreach ($property in $fixture.environmentOverrides.PSObject.Properties) {
        $name = [string]$property.Name
        $previousValues[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$property.Value, 'Process')
    }

    $model = Get-AuditPathModel -MachinePath ([string]$fixture.machinePath) -UserPath ([string]$fixture.userPath) -ProcessPath ([string]$fixture.processPath)

    if (@($model.scopes).Count -ne 3) {
        throw 'Expected machine, user, and process PATH scope models.'
    }

    $machine = @($model.scopes | Where-Object scope -eq 'machine')[0]
    $user = @($model.scopes | Where-Object scope -eq 'user')[0]
    $process = @($model.scopes | Where-Object scope -eq 'process')[0]

    if ($machine.entryCount -ne [int]$fixture.expected.machineEntryCount) {
        throw "Unexpected machine PATH entry count: $($machine.entryCount)"
    }

    if ($machine.duplicateCount -ne [int]$fixture.expected.machineDuplicateCount) {
        throw "Unexpected machine duplicate count: $($machine.duplicateCount)"
    }

    if ($user.entryCount -ne [int]$fixture.expected.userEntryCount) {
        throw "Unexpected user PATH entry count: $($user.entryCount)"
    }

    if ($process.entryCount -ne [int]$fixture.expected.processEntryCount) {
        throw "Unexpected process PATH entry count: $($process.entryCount)"
    }

    if ($model.crossScopeDuplicateCount -ne [int]$fixture.expected.crossScopeDuplicateCount) {
        throw "Unexpected persistent cross-scope duplicate count: $($model.crossScopeDuplicateCount)"
    }

    if ($machine.entries[0].normalized -ne [string]$fixture.expected.normalizedFirstMachine) {
        throw "Quoted PATH entry did not normalize correctly: $($machine.entries[0].normalized)"
    }

    if ($machine.entries[1].normalized -ne [string]$fixture.expected.normalizedSecondMachine) {
        throw "Slash/trailing-separator normalization failed: $($machine.entries[1].normalized)"
    }

    if ($machine.entries[0].comparisonKey -ne [string]$fixture.expected.firstMachineComparisonKey) {
        throw "Case-insensitive comparison key mismatch: $($machine.entries[0].comparisonKey)"
    }

    if (-not $machine.entries[1].duplicateWithinScope) {
        throw 'Equivalent machine PATH entry was not marked as a within-scope duplicate.'
    }

    if ($machine.entries[1].firstEquivalentPosition -ne [int]$fixture.expected.duplicateFirstEquivalentPosition) {
        throw "Duplicate did not retain first equivalent position: $($machine.entries[1].firstEquivalentPosition)"
    }

    if ($machine.entries[3].normalized -ne [string]$fixture.expected.normalizedEnvironmentExpansion) {
        throw "Environment reference expansion mismatch: $($machine.entries[3].normalized)"
    }

    if ($machine.entries[4].normalized -ne [string]$fixture.expected.unresolvedNormalized) {
        throw "Unresolved environment reference normalization mismatch: $($machine.entries[4].normalized)"
    }

    if (-not $machine.entries[4].hasUnresolvedVariable) {
        throw 'Expected unresolved environment reference to remain explicit.'
    }

    if ($null -ne $machine.entries[4].exists) {
        throw 'Existence must remain unknown when a PATH entry contains an unresolved variable.'
    }

    if ($user.entries[1].normalized -ne [string]$fixture.expected.userSecondNormalized) {
        throw "Repeated/trailing separator normalization failed for user PATH: $($user.entries[1].normalized)"
    }

    if ($process.entries[1].normalized -ne [string]$fixture.expected.processSecondNormalized) {
        throw "Forward-slash normalization failed for process PATH: $($process.entries[1].normalized)"
    }

    $persistentDuplicate = @($model.crossScopeDuplicates)[0]
    if (@($persistentDuplicate.scopes).Count -ne 2 -or
        @($persistentDuplicate.scopes) -notcontains 'machine' -or
        @($persistentDuplicate.scopes) -notcontains 'user') {
        throw 'Persistent duplicate must represent Machine/User scope overlap.'
    }

    if (@($persistentDuplicate.scopes) -contains 'process') {
        throw 'Process PATH must not be treated as a persistent cross-scope duplicate source.'
    }

    $empty = Get-AuditPathScopeModel -Scope user -RawPath ' ; ; '
    if ($empty.entryCount -ne 0 -or @($empty.entries).Count -ne 0) {
        throw 'Blank PATH segments should not create normalized entries.'
    }

    $driveRoot = ConvertTo-AuditPathEntry -Scope process -Position 0 -Entry 'C:\'
    if ($driveRoot.normalized -ne 'C:\') {
        throw "Drive root normalization must preserve the root separator: $($driveRoot.normalized)"
    }

    $unc = ConvertTo-AuditPathEntry -Scope process -Position 0 -Entry '\\SyntheticServer\\Share\\Tools\\'
    if ($unc.normalized -ne '\\SyntheticServer\Share\Tools') {
        throw "UNC normalization mismatch: $($unc.normalized)"
    }

    Write-Host 'PATH scope model validation passed.'
}
finally {
    foreach ($name in $previousValues.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousValues[$name], 'Process')
    }
}
