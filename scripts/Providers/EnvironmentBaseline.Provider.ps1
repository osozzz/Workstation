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
$environmentModel = Get-AuditEnvironmentModel -Snapshot $environment

foreach ($variable in @($environmentModel.variables)) {
    $snapshotItem = @($environment | Where-Object name -eq $variable.name | Select-Object -First 1)
    $evidenceId = "environment.$($variable.name.ToLowerInvariant())"

    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type environment -Source $variable.name -Captured $null -Attributes @{
        process = $(if ($snapshotItem.Count -gt 0) { $snapshotItem[0].process } else { $null })
        user = $(if ($snapshotItem.Count -gt 0) { $snapshotItem[0].user } else { $null })
        machine = $(if ($snapshotItem.Count -gt 0) { $snapshotItem[0].machine } else { $null })
        kind = $variable.kind
        filesystem = $variable.filesystem
        configuredScopeCount = $variable.configuredScopeCount
        valueScopeCount = $variable.valueScopeCount
        distinctValueCount = $variable.distinctValueCount
        scopeConflict = $variable.scopeConflict
        emptyScopeCount = $variable.emptyScopeCount
        invalidScopeCount = $variable.invalidScopeCount
        missingPathCount = $variable.missingPathCount
        unresolvedScopeCount = $variable.unresolvedScopeCount
        scopes = $variable.scopes
    }))

    if ($variable.scopeConflict) {
        $warnings.Add((New-AuditIssue -Code 'ENV_SCOPE_CONFLICT' -Message "$($variable.name) has conflicting configured values across Process/User/Machine scopes." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($variable.emptyScopeCount -gt 0 -or $variable.invalidScopeCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'ENV_EMPTY_OR_INVALID_VALUE' -Message "$($variable.name) has $($variable.invalidScopeCount) configured scope value(s) that are empty or invalid as filesystem paths." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($variable.missingPathCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'ENV_MISSING_PATHS' -Message "$($variable.name) references $($variable.missingPathCount) filesystem path(s) that do not exist." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($variable.unresolvedScopeCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'ENV_UNRESOLVED_REFERENCES' -Message "$($variable.name) contains unresolved environment-variable reference(s) in $($variable.unresolvedScopeCount) scope(s)." -Severity warning -EvidenceIds @($evidenceId)))
    }
}

$evidence.Add((New-AuditEvidence -EvidenceId 'environment.allowlist.boundary' -Type derived -Source 'Approved environment-variable allowlist' -Captured $null -Attributes @{
    approvedNames = @($Context.EnvironmentVariableNames)
    inspectedCount = $environmentModel.variableCount
    arbitraryEnumeration = $false
    unapprovedReferenceExpansion = $false
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
