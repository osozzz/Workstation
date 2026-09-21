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
        providerId = 'environment.baseline'
        category   = 'environment'
        order      = 30
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

$environment = Get-AuditEnvironmentSnapshot -Names $Context.EnvironmentVariableNames

$environmentModels = Get-AuditEnvironmentIntelligence -Snapshot $environment

foreach ($model in @($environmentModels)) {
    $evidenceId = "environment.$($model.name.ToLowerInvariant()).intelligence"

    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type environment -Source $model.name -Captured $null -Attributes @{
        configuredScopeCount = $model.configuredScopeCount
        presentScopeCount = $model.presentScopeCount
        unsetScopeCount = $model.unsetScopeCount
        emptyScopeCount = $model.emptyScopeCount
        distinctPresentValueCount = $model.distinctPresentValueCount
        hasScopeDrift = $model.hasScopeDrift
        hasEmptyConfiguredScope = $model.hasEmptyConfiguredScope
        missingPathCount = $model.missingPathCount
        unresolvedVariableCount = $model.unresolvedVariableCount
        scopes = $model.scopes
    }))

    if ($model.hasScopeDrift) {
        $warnings.Add((New-AuditIssue -Code 'ENV_SCOPE_DRIFT' -Message "$($model.name) has conflicting configured values across Process/User/Machine scopes." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($model.missingPathCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'ENV_MISSING_PATHS' -Message "$($model.name) references $($model.missingPathCount) missing filesystem path(s)." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($model.unresolvedVariableCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'ENV_UNRESOLVED_REFERENCES' -Message "$($model.name) contains $($model.unresolvedVariableCount) unresolved or unapproved environment-variable reference(s)." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($model.hasEmptyConfiguredScope) {
        $warnings.Add((New-AuditIssue -Code 'ENV_EMPTY_CONFIGURED_SCOPE' -Message "$($model.name) is explicitly configured as an empty value in one or more scopes." -Severity warning -EvidenceIds @($evidenceId)))
    }
}

$environmentSummaryEvidenceId = 'environment.intelligence.summary'
$evidence.Add((New-AuditEvidence -EvidenceId $environmentSummaryEvidenceId -Type derived -Source 'approved environment-variable intelligence' -Captured $null -Attributes @{
    approvedVariableCount = @($environmentModels).Count
    scopeDriftCount = @($environmentModels | Where-Object { $_.hasScopeDrift }).Count
    variablesWithMissingPaths = @($environmentModels | Where-Object { $_.missingPathCount -gt 0 }).Count
    variablesWithUnresolvedReferences = @($environmentModels | Where-Object { $_.unresolvedVariableCount -gt 0 }).Count
    variablesWithEmptyConfiguredScope = @($environmentModels | Where-Object { $_.hasEmptyConfiguredScope }).Count
    arbitraryEnumerationPerformed = $false
}))

$pathModel = Get-AuditPathModel -MachinePath ([Environment]::GetEnvironmentVariable('Path', 'Machine')) -UserPath ([Environment]::GetEnvironmentVariable('Path', 'User')) -ProcessPath ([Environment]::GetEnvironmentVariable('Path', 'Process'))

foreach ($scopeModel in @($pathModel.scopes)) {
    $evidenceId = "path.$($scopeModel.scope).health"

    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type path -Source "$($scopeModel.scope) PATH" -Captured $null -Attributes @{
        entryCount = $scopeModel.entryCount
        duplicateCount = $scopeModel.duplicateCount
        missingCount = $scopeModel.missingCount
        unresolvedVariableCount = $scopeModel.unresolvedVariableCount
        entries = $scopeModel.entries
    }))

    if ($scopeModel.duplicateCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'PATH_DUPLICATE_ENTRIES' -Message "$($scopeModel.scope) PATH contains $($scopeModel.duplicateCount) duplicate entries." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($scopeModel.missingCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'PATH_MISSING_ENTRIES' -Message "$($scopeModel.scope) PATH contains $($scopeModel.missingCount) missing entries." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($scopeModel.unresolvedVariableCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'PATH_UNRESOLVED_VARIABLES' -Message "$($scopeModel.scope) PATH contains $($scopeModel.unresolvedVariableCount) unresolved environment-variable references." -Severity warning -EvidenceIds @($evidenceId)))
    }
}

$crossScopeEvidenceId = 'path.persistent.cross-scope-duplicates'
$evidence.Add((New-AuditEvidence -EvidenceId $crossScopeEvidenceId -Type derived -Source 'Machine/User PATH equivalence analysis' -Captured $null -Attributes @{
    duplicateCount = $pathModel.crossScopeDuplicateCount
    duplicates = $pathModel.crossScopeDuplicates
    processScopeExcluded = $true
}))

if ($pathModel.crossScopeDuplicateCount -gt 0) {
    $warnings.Add((New-AuditIssue -Code 'PATH_CROSS_SCOPE_DUPLICATES' -Message "Machine and User PATH contain $($pathModel.crossScopeDuplicateCount) equivalent persistent entries." -Severity warning -EvidenceIds @($crossScopeEvidenceId)))
}

return [pscustomobject][ordered]@{
    providerId = 'environment.baseline'
    category   = 'environment'
    status     = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray()
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
