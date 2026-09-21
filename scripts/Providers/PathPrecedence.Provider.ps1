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
        providerId = 'path.precedence'
        category   = 'environment'
        order      = 29
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()
$evidence = [System.Collections.Generic.List[object]]::new()
$hasPartial = $false

$previousProviderResults = if ($Context.PSObject.Properties['PreviousProviderResults']) {
    @($Context.PreviousProviderResults)
}
else {
    @()
}

$processPathModel = Get-AuditPathScopeModel -Scope process -RawPath ([Environment]::GetEnvironmentVariable('Path', 'Process'))

$groups = @{}

foreach ($provider in $previousProviderResults) {
    foreach ($component in @($provider.components)) {
        if ($null -eq $component.PSObject.Properties['commandResolutions']) {
            continue
        }

        foreach ($resolution in @($component.commandResolutions)) {
            if ($null -eq $resolution.PSObject.Properties['command']) {
                continue
            }

            $command = [string]$resolution.command
            if ([string]::IsNullOrWhiteSpace($command)) {
                continue
            }

            $commandKey = $command.ToLowerInvariant()
            if (-not $groups.ContainsKey($commandKey)) {
                $groups[$commandKey] = [pscustomobject][ordered]@{
                    command     = $command
                    resolutions = [System.Collections.Generic.List[object]]::new()
                    resolutionKeys = @{}
                    sources     = [System.Collections.Generic.List[object]]::new()
                    sourceKeys  = @{}
                }
            }

            $group = $groups[$commandKey]
            $path = if ($resolution.PSObject.Properties['path']) { [string]$resolution.path } else { '' }
            $commandType = if ($resolution.PSObject.Properties['commandType']) { [string]$resolution.commandType } else { '' }
            $precedence = if ($resolution.PSObject.Properties['precedence']) { [int]$resolution.precedence } else { $group.resolutions.Count }
            $active = if ($resolution.PSObject.Properties['active']) { [bool]$resolution.active } else { $false }

            $resolutionKey = '{0}|{1}|{2}|{3}' -f $commandType.ToLowerInvariant(), $path.ToLowerInvariant(), $precedence, $active
            if (-not $group.resolutionKeys.ContainsKey($resolutionKey)) {
                $group.resolutionKeys[$resolutionKey] = $true
                $group.resolutions.Add([pscustomobject][ordered]@{
                    command     = $command
                    path        = $path
                    commandType = $commandType
                    version     = $(if ($resolution.PSObject.Properties['version']) { $resolution.version } else { $null })
                    precedence  = $precedence
                    active      = $active
                })
            }

            $sourceComponentId = if ($component.PSObject.Properties['componentId']) { [string]$component.componentId } else { '' }
            $sourceKey = '{0}|{1}' -f ([string]$provider.providerId).ToLowerInvariant(), $sourceComponentId.ToLowerInvariant()
            if (-not $group.sourceKeys.ContainsKey($sourceKey)) {
                $group.sourceKeys[$sourceKey] = $true
                $group.sources.Add([pscustomobject][ordered]@{
                    providerId  = [string]$provider.providerId
                    componentId = $sourceComponentId
                })
            }
        }
    }
}

$analyses = [System.Collections.Generic.List[object]]::new()
$usedEvidenceIds = @{}

foreach ($commandKey in @($groups.Keys | Sort-Object)) {
    $group = $groups[$commandKey]
    $orderedResolutions = @(
        $group.resolutions |
            Sort-Object @{ Expression = 'precedence'; Ascending = $true }, @{ Expression = 'active'; Descending = $true }, @{ Expression = 'path'; Ascending = $true }
    )

    $analysis = Get-AuditCommandPathAnalysis -CommandResolutions $orderedResolutions -ProcessPathEntries $processPathModel.entries

    $slug = $commandKey -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'unknown'
    }

    $evidenceId = "path-precedence.command.$slug"
    if ($usedEvidenceIds.ContainsKey($evidenceId)) {
        $suffix = 2
        while ($usedEvidenceIds.ContainsKey("$evidenceId-$suffix")) { $suffix++ }
        $evidenceId = "$evidenceId-$suffix"
    }
    $usedEvidenceIds[$evidenceId] = $true

    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type derived -Source "command PATH precedence: $($group.command)" -Captured $null -Attributes @{
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
        sources = $group.sources.ToArray()
    }))

    $analyses.Add([pscustomobject][ordered]@{
        command = $analysis.command
        evidenceId = $evidenceId
        analysis = $analysis
    })

    if ($analysis.hasPathOrderConflict) {
        $activeText = if ($null -ne $analysis.activeResolution) {
            $activePosition = if ($null -ne $analysis.activeResolution.pathPosition) { "PATH[$($analysis.activeResolution.pathPosition)]" } else { 'PATH[unknown]' }
            "'$($analysis.activeResolution.path)' at $activePosition"
        }
        else {
            'no explicitly active resolution'
        }

        $shadowedText = @(
            $analysis.shadowedResolutions |
                Where-Object { $_.pathBased } |
                ForEach-Object {
                    $position = if ($null -ne $_.pathPosition) { "PATH[$($_.pathPosition)]" } else { 'PATH[unknown]' }
                    "'$($_.path)' at $position"
                }
        ) -join '; '

        $warnings.Add((New-AuditIssue -Code 'COMMAND_PATH_PRECEDENCE_CONFLICT' -Message "Command '$($analysis.command)' resolves actively to $activeText and shadows: $shadowedText." -Severity warning -EvidenceIds @($evidenceId)))
    }

    if ($analysis.unmappedPathResolutionCount -gt 0) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'COMMAND_PATH_ORIGIN_UNKNOWN' -Message "Command '$($analysis.command)' has $($analysis.unmappedPathResolutionCount) PATH-based resolution(s) whose Process PATH origin could not be proven." -Severity warning -EvidenceIds @($evidenceId)))
    }
}

$summaryEvidenceId = 'path-precedence.summary'
$evidence.Add((New-AuditEvidence -EvidenceId $summaryEvidenceId -Type derived -Source 'command-to-PATH precedence summary' -Captured $null -Attributes @{
    analyzedCommandCount = $analyses.Count
    sourceProviderCount = @($previousProviderResults).Count
    processPathEntryCount = $processPathModel.entryCount
    commandCollisionCount = @($analyses | Where-Object { $_.analysis.hasResolutionCollision }).Count
    pathResolutionCollisionCount = @($analyses | Where-Object { $_.analysis.hasPathResolutionCollision }).Count
    pathOrderConflictCount = @($analyses | Where-Object { $_.analysis.hasPathOrderConflict }).Count
    commandsWithUnknownPathOrigins = @($analyses | Where-Object { $_.analysis.unmappedPathResolutionCount -gt 0 }).Count
    readOnly = $true
}))

$status = if ($analyses.Count -eq 0) {
    'unavailable'
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial
}

return [pscustomobject][ordered]@{
    providerId = 'path.precedence'
    category   = 'environment'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
