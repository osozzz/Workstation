[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$fixturePath = Join-Path $PSScriptRoot 'environment-model-cases.json'

Import-Module $corePath -Force
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('workstation-env-model-' + [Guid]::NewGuid().ToString('N'))
$existingA = Join-Path $tempRoot 'ExistingA'
$existingB = Join-Path $tempRoot 'ExistingB'
$androidSdk = Join-Path $existingA 'AndroidSdk'
$missing = Join-Path $tempRoot 'Missing'
$secretName = 'WORKSTATION_SECRET_TEST'
$previousSecret = [Environment]::GetEnvironmentVariable($secretName, 'Process')

try {
    New-Item -ItemType Directory -Path $existingA -Force | Out-Null
    New-Item -ItemType Directory -Path $existingB -Force | Out-Null
    New-Item -ItemType Directory -Path $androidSdk -Force | Out-Null

    [Environment]::SetEnvironmentVariable($secretName, 'MUST_NOT_BE_READ', 'Process')

    $replacements = @{
        '{{EXISTING_A}}' = $existingA
        '{{EXISTING_B}}' = $existingB
        '{{EXISTING_ANDROID_SDK}}' = $androidSdk
        '{{MISSING}}' = $missing
    }

    $snapshot = @(
        foreach ($item in @($fixture.snapshot)) {
            $values = @{}
            foreach ($scope in @('process', 'user', 'machine')) {
                $value = $item.$scope
                if ($null -ne $value) {
                    $text = [string]$value
                    foreach ($token in $replacements.Keys) {
                        $text = $text.Replace($token, [string]$replacements[$token])
                    }
                    $values[$scope] = $text
                }
                else {
                    $values[$scope] = $null
                }
            }

            [pscustomobject][ordered]@{
                name = [string]$item.name
                process = $values.process
                user = $values.user
                machine = $values.machine
            }
        }
    )

    foreach ($name in @($fixture.expectedAllowedNames)) {
        $definition = Get-AuditEnvironmentVariableDefinition -Name ([string]$name)
        if ($definition.name -ne [string]$name) {
            throw "Definition lookup changed variable name '$name'."
        }
    }

    $unapprovedFailed = $false
    try {
        Get-AuditEnvironmentSnapshot -Names @('WORKSTATION_SECRET_TEST') | Out-Null
    }
    catch {
        $unapprovedFailed = $true
    }
    if (-not $unapprovedFailed) {
        throw 'Unapproved environment-variable snapshot request must fail.'
    }

    $directResolution = Resolve-AuditEnvironmentReferences -Value '%WORKSTATION_SECRET_TEST%\Direct' -ReferenceValues @{ WORKSTATION_SECRET_TEST = 'MUST_NOT_BE_READ' }
    if ($directResolution.expanded -match 'MUST_NOT_BE_READ') {
        throw 'Resolver must ignore unapproved dictionary values even when explicitly supplied.'
    }
    if ($directResolution.unapprovedReferenceCount -ne 1 -or @($directResolution.unresolvedVariables).Count -ne 0) {
        throw 'Direct unapproved resolver classification is incorrect.'
    }

    $model = Get-AuditEnvironmentModel -Snapshot $snapshot
    if ($model.variableCount -ne @($fixture.snapshot).Count) {
        throw "Unexpected environment model variable count: $($model.variableCount)"
    }

    function Get-VariableModel {
        param([string]$Name)
        return @($model.variables | Where-Object name -eq $Name)[0]
    }

    $java = Get-VariableModel -Name 'JAVA_HOME'
    if ($java.scopeConflict) {
        throw 'Aligned JAVA_HOME values must not be reported as a scope conflict.'
    }
    if ($java.distinctValueCount -ne 1 -or $java.configuredScopeCount -ne 2) {
        throw 'Aligned JAVA_HOME scope counts are incorrect.'
    }
    if ($java.missingPathCount -ne 0) {
        throw 'Existing JAVA_HOME paths must not be reported missing.'
    }

    $nvm = Get-VariableModel -Name 'NVM_HOME'
    if (-not $nvm.scopeConflict -or $nvm.distinctValueCount -ne 2) {
        throw 'Conflicting NVM_HOME values were not detected.'
    }
    if ($nvm.missingPathCount -ne 0) {
        throw 'Existing NVM_HOME conflict paths must remain valid.'
    }

    $flutter = Get-VariableModel -Name 'FLUTTER_ROOT'
    if ($flutter.missingPathCount -ne 1) {
        throw 'Missing FLUTTER_ROOT path was not detected.'
    }

    $pyenv = Get-VariableModel -Name 'PYENV_ROOT'
    if ($pyenv.configuredScopeCount -ne 0) {
        throw 'Unset PYENV_ROOT must remain distinguishable from configured values.'
    }
    foreach ($scope in @($pyenv.scopes)) {
        if ($scope.state -ne 'unset' -or $scope.isConfigured) {
            throw 'Unset PYENV_ROOT scope state was not preserved.'
        }
    }

    $pnpm = Get-VariableModel -Name 'PNPM_HOME'
    if ($pnpm.emptyScopeCount -ne 1 -or $pnpm.invalidScopeCount -ne 1) {
        throw 'Empty PNPM_HOME must remain explicit and invalid.'
    }
    $pnpmProcess = @($pnpm.scopes | Where-Object scope -eq 'process')[0]
    if ($pnpmProcess.state -ne 'empty' -or -not $pnpmProcess.isConfigured) {
        throw 'Empty PNPM_HOME process state was not preserved.'
    }

    $android = Get-VariableModel -Name 'ANDROID_HOME'
    if ($android.unresolvedScopeCount -ne 1) {
        throw 'Unapproved reference inside ANDROID_HOME must remain unresolved.'
    }
    $androidProcess = @($android.scopes | Where-Object scope -eq 'process')[0]
    if ($androidProcess.expanded -notmatch '%WORKSTATION_SECRET_TEST%') {
        throw 'Unapproved reference token was not preserved.'
    }
    if ($androidProcess.expanded -match 'MUST_NOT_BE_READ') {
        throw 'Unapproved environment-variable value leaked into approved evidence.'
    }
    if (@($androidProcess.unresolvedVariables).Count -ne 0) {
        throw 'Unapproved reference names must not be promoted into structured evidence.'
    }
    if ($androidProcess.unapprovedReferenceCount -ne 1) {
        throw 'Expected one unapproved reference count for ANDROID_HOME.'
    }

    $androidSdkModel = Get-VariableModel -Name 'ANDROID_SDK_ROOT'
    if ($androidSdkModel.unresolvedScopeCount -ne 0 -or $androidSdkModel.missingPathCount -ne 0) {
        throw 'Approved JAVA_HOME reference should resolve inside ANDROID_SDK_ROOT.'
    }
    $androidSdkProcess = @($androidSdkModel.scopes | Where-Object scope -eq 'process')[0]
    if ($androidSdkProcess.normalized -ne $androidSdk) {
        throw "Approved reference expansion mismatch: $($androidSdkProcess.normalized)"
    }

    $dotnetX86 = Get-VariableModel -Name 'DOTNET_ROOT_X86'
    if ($dotnetX86.unresolvedScopeCount -ne 1 -or $dotnetX86.unapprovedReferenceCount -ne 0) {
        throw 'Approved unresolved DOTNET_ROOT reference must remain distinct from unapproved references.'
    }
    $dotnetX86Process = @($dotnetX86.scopes | Where-Object scope -eq 'process')[0]
    if (@($dotnetX86Process.unresolvedVariables) -notcontains 'DOTNET_ROOT') {
        throw 'Approved unresolved reference name should remain explicit.'
    }

    $gopath = Get-VariableModel -Name 'GOPATH'
    if ($gopath.kind -ne 'path-list') {
        throw 'GOPATH must be modeled as a path-list.'
    }
    $goProcess = @($gopath.scopes | Where-Object scope -eq 'process')[0]
    if (@($goProcess.pathItems).Count -ne 2 -or $goProcess.missingPathCount -ne 1) {
        throw 'GOPATH path-list items or missing-path count are incorrect.'
    }

    $cargo = Get-VariableModel -Name 'CARGO_HOME'
    if ($cargo.invalidScopeCount -ne 1) {
        throw 'Whitespace-only CARGO_HOME must be treated as invalid.'
    }

    $duplicateFailed = $false
    try {
        Get-AuditEnvironmentModel -Snapshot @(
            [pscustomobject]@{ name='JAVA_HOME'; process=$existingA; user=$null; machine=$null },
            [pscustomobject]@{ name='java_home'; process=$existingA; user=$null; machine=$null }
        ) | Out-Null
    }
    catch {
        $duplicateFailed = $true
    }
    if (-not $duplicateFailed) {
        throw 'Duplicate environment snapshot names must be rejected case-insensitively.'
    }

    Write-Host 'Safe environment-variable intelligence validation passed.'
}
finally {
    [Environment]::SetEnvironmentVariable($secretName, $previousSecret, 'Process')
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
