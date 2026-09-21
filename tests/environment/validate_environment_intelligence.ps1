[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$fixturePath = Join-Path $PSScriptRoot 'environment-intelligence-cases.json'

Import-Module $corePath -Force
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

function New-ModelFromCase {
    param([Parameter(Mandatory)][object]$Case)
    return Get-AuditEnvironmentVariableModel -Name ([string]$Case.name) -ProcessValue $Case.process -UserValue $Case.user -MachineValue $Case.machine
}

$secretName = 'WORKSTATION_UNAPPROVED_REF'
$previousSecret = [Environment]::GetEnvironmentVariable($secretName, 'Process')
[Environment]::SetEnvironmentVariable($secretName, 'C:\Synthetic\SecretShouldNotLeak', 'Process')

try {
    $aligned = New-ModelFromCase -Case $fixture.cases.aligned
    if ($aligned.hasScopeDrift) {
        throw 'Equivalent normalized JAVA_HOME values must not report scope drift.'
    }
    if ($aligned.presentScopeCount -ne 2 -or $aligned.unsetScopeCount -ne 1) {
        throw 'Aligned case did not preserve present/unset scope counts.'
    }
    if ($aligned.scopes[0].comparisonKey -ne $aligned.scopes[1].comparisonKey) {
        throw 'Aligned case must compare case-insensitively after path normalization.'
    }

    $drift = New-ModelFromCase -Case $fixture.cases.drift
    if (-not $drift.hasScopeDrift -or $drift.distinctPresentValueCount -ne 2) {
        throw 'Conflicting NVM_HOME values must report scope drift.'
    }

    $missing = New-ModelFromCase -Case $fixture.cases.missing
    if ($missing.missingPathCount -lt 1) {
        throw 'Missing FLUTTER_ROOT must report a missing filesystem path.'
    }

    $empty = New-ModelFromCase -Case $fixture.cases.emptyVsUnset
    if (-not $empty.hasEmptyConfiguredScope) {
        throw 'Explicit empty PNPM_HOME must remain distinct from unset.'
    }
    $processScope = @($empty.scopes | Where-Object scope -eq 'process')[0]
    $userScope = @($empty.scopes | Where-Object scope -eq 'user')[0]
    if ($processScope.state -ne 'empty' -or $userScope.state -ne 'unset') {
        throw 'Empty and unset environment states were not preserved independently.'
    }

    $unresolved = New-ModelFromCase -Case $fixture.cases.unresolved
    if ($unresolved.unresolvedVariableCount -lt 1) {
        throw 'Unapproved reference inside JAVA_HOME must remain unresolved.'
    }
    $unresolvedProcess = @($unresolved.scopes | Where-Object scope -eq 'process')[0]
    if ($unresolvedProcess.normalized -match 'SecretShouldNotLeak') {
        throw 'Unapproved environment reference value leaked into normalized evidence.'
    }
    if ($unresolvedProcess.normalized -notmatch '%WORKSTATION_UNAPPROVED_REF%') {
        throw 'Unapproved environment reference token must be preserved explicitly.'
    }
    if (@($unresolvedProcess.paths[0].unresolvedVariables) -notcontains $secretName) {
        throw 'Unresolved variable name must remain explicit in path evidence.'
    }

    $gopath = New-ModelFromCase -Case $fixture.cases.gopath
    $goProcess = @($gopath.scopes | Where-Object scope -eq 'process')[0]
    if ($goProcess.pathCount -ne 2) {
        throw "GOPATH must preserve multiple Windows path roots; got $($goProcess.pathCount)."
    }
    if (@($goProcess.paths).Count -ne 2) {
        throw 'GOPATH normalized paths must remain individually inspectable.'
    }

    $snapshot = @(
        [pscustomobject]@{ name = 'JAVA_HOME'; process = 'C:\Synthetic\Java'; user = 'c:\synthetic\java\'; machine = $null },
        [pscustomobject]@{ name = 'PNPM_HOME'; process = $null; user = $null; machine = $null }
    )
    $models = Get-AuditEnvironmentIntelligence -Snapshot $snapshot
    if (@($models).Count -ne 2) {
        throw 'Environment intelligence must preserve requested approved-variable count.'
    }

    $blocked = $false
    try {
        Get-AuditEnvironmentVariableModel -Name 'SECRET_TOKEN' -ProcessValue 'C:\Secret' -UserValue $null -MachineValue $null | Out-Null
    }
    catch {
        $blocked = ($_.Exception.Message -match 'not in the audit allowlist')
    }
    if (-not $blocked) {
        throw 'Unapproved environment-variable names must be rejected.'
    }

    $blockedSnapshot = $false
    try {
        Get-AuditEnvironmentIntelligence -Snapshot @([pscustomobject]@{ name = 'SECRET_TOKEN'; process = 'secret'; user = $null; machine = $null }) | Out-Null
    }
    catch {
        $blockedSnapshot = ($_.Exception.Message -match 'not in the audit allowlist')
    }
    if (-not $blockedSnapshot) {
        throw 'Environment intelligence must reject snapshots containing unapproved keys.'
    }

    Write-Host 'Environment intelligence validation passed.'
}
finally {
    [Environment]::SetEnvironmentVariable($secretName, $previousSecret, 'Process')
}
