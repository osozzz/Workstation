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

function Split-PathEntries {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value -split ';' |
            ForEach-Object { $_.Trim().Trim('"') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-PathHealth {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [AllowNull()][string]$RawPath
    )

    $entries = Split-PathEntries -Value $RawPath
    $seen = @{}
    $details = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $entries) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry)
        $unresolved = $expanded -match '%[^%]+%'
        $key = $expanded.TrimEnd('\').ToLowerInvariant()
        $duplicate = $seen.ContainsKey($key)

        if (-not $duplicate) {
            $seen[$key] = $true
        }

        $exists = $null
        if (-not $unresolved) {
            try {
                $exists = Test-Path -LiteralPath $expanded
            }
            catch {
                $exists = $false
            }
        }

        $details.Add([pscustomobject][ordered]@{
            entry = $entry
            expanded = $expanded
            exists = $exists
            duplicate = $duplicate
            hasUnresolvedVariable = $unresolved
        })
    }

    return [pscustomobject][ordered]@{
        scope = $Scope
        entryCount = $entries.Count
        duplicateCount = @($details | Where-Object { $_.duplicate }).Count
        missingCount = @($details | Where-Object { $_.exists -eq $false }).Count
        unresolvedVariableCount = @($details | Where-Object { $_.hasUnresolvedVariable }).Count
        entries = $details.ToArray()
    }
}

$environment = Get-AuditEnvironmentSnapshot -Names $Context.EnvironmentVariableNames

foreach ($item in $environment) {
    $evidenceId = "environment.$($item.name.ToLowerInvariant())"
    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type environment -Source $item.name -Captured $null -Attributes @{
        process = $item.process
        user = $item.user
        machine = $item.machine
    }))
}

$pathScopes = @(
    @{ Name = 'machine'; Value = [Environment]::GetEnvironmentVariable('Path', 'Machine') },
    @{ Name = 'user'; Value = [Environment]::GetEnvironmentVariable('Path', 'User') },
    @{ Name = 'process'; Value = [Environment]::GetEnvironmentVariable('Path', 'Process') }
)

foreach ($scope in $pathScopes) {
    $health = Get-PathHealth -Scope $scope.Name -RawPath $scope.Value
    $evidenceId = "path.$($scope.Name).health"

    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type path -Source "$($scope.Name) PATH" -Captured $null -Attributes @{
        entryCount = $health.entryCount
        duplicateCount = $health.duplicateCount
        missingCount = $health.missingCount
        unresolvedVariableCount = $health.unresolvedVariableCount
        entries = $health.entries
    }))

    if ($health.duplicateCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'PATH_DUPLICATE_ENTRIES' -Message "$($scope.Name) PATH contains $($health.duplicateCount) duplicate entries." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($health.missingCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'PATH_MISSING_ENTRIES' -Message "$($scope.Name) PATH contains $($health.missingCount) missing entries." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($health.unresolvedVariableCount -gt 0) {
        $warnings.Add((New-AuditIssue -Code 'PATH_UNRESOLVED_VARIABLES' -Message "$($scope.Name) PATH contains $($health.unresolvedVariableCount) unresolved environment-variable references." -Severity warning -EvidenceIds @($evidenceId)))
    }
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
