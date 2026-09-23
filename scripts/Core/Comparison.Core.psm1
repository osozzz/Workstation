Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ComparisonSchemaVersion = '1.0.0'
$script:SupportedAuditSchemaMajor = 1

function Get-ComparisonOptionalPropertyValue {
    [CmdletBinding()]
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

function ConvertTo-ComparisonSemanticVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Version,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FieldName
    )

    $match = [regex]::Match(
        $Version,
        '^(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:[-+][0-9A-Za-z.-]+)?$'
    )

    if (-not $match.Success) {
        throw "$FieldName must be a semantic version. Found '$Version'."
    }

    return [pscustomobject][ordered]@{
        raw   = $Version
        major = [int]$match.Groups['major'].Value
        minor = [int]$match.Groups['minor'].Value
        patch = [int]$match.Groups['patch'].Value
    }
}

function Assert-WorkstationComparisonReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Report,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    $schemaVersionValue = Get-ComparisonOptionalPropertyValue -InputObject $Report -Name 'schemaVersion'
    if ([string]::IsNullOrWhiteSpace([string]$schemaVersionValue)) {
        throw "$Role report does not declare schemaVersion."
    }

    $schemaVersion = ConvertTo-ComparisonSemanticVersion -Version ([string]$schemaVersionValue) -FieldName "$Role schemaVersion"
    if ($schemaVersion.major -ne $script:SupportedAuditSchemaMajor) {
        throw "$Role report uses unsupported audit schema major $($schemaVersion.major). Supported major: $script:SupportedAuditSchemaMajor."
    }

    $providersValue = Get-ComparisonOptionalPropertyValue -InputObject $Report -Name 'providers'
    if ($null -eq $providersValue) {
        throw "$Role report does not contain normalized providers."
    }

    $audit = Get-ComparisonOptionalPropertyValue -InputObject $Report -Name 'audit'
    $auditMode = Get-ComparisonOptionalPropertyValue -InputObject $audit -Name 'mode'
    if ([string]$auditMode -ne 'read-only') {
        throw "$Role report must declare audit.mode as read-only."
    }

    $host = Get-ComparisonOptionalPropertyValue -InputObject $Report -Name 'host'
    if ($null -eq $host) {
        throw "$Role report does not contain normalized host identity."
    }

    Get-ComparisonProviderIndex -Report $Report -Role $Role | Out-Null

    return $schemaVersion
}

function Get-ComparisonProviderIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Report,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    $index = @{}
    foreach ($provider in @($Report.providers)) {
        $providerId = [string](Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'providerId')
        if ([string]::IsNullOrWhiteSpace($providerId)) {
            throw "$Role report contains a provider without providerId."
        }

        if ($index.ContainsKey($providerId)) {
            throw "$Role report contains duplicate providerId '$providerId'."
        }

        $index[$providerId] = $provider
    }

    return $index
}

function Get-ComparisonComponentIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    $index = @{}
    foreach ($component in @($Provider.components)) {
        $componentId = [string](Get-ComparisonOptionalPropertyValue -InputObject $component -Name 'componentId')
        if ([string]::IsNullOrWhiteSpace($componentId)) {
            throw "$Role provider '$ProviderId' contains a component without componentId."
        }

        if ($index.ContainsKey($componentId)) {
            throw "$Role provider '$ProviderId' contains duplicate componentId '$componentId'."
        }

        $index[$componentId] = $component
    }

    return $index
}

function Get-ComparisonRelation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$ReferenceExists,
        [Parameter(Mandatory)][bool]$TargetExists,
        [AllowNull()][string]$ReferenceState,
        [AllowNull()][string]$TargetState
    )

    if ($ReferenceExists -and -not $TargetExists) {
        return 'reference-only'
    }

    if ($TargetExists -and -not $ReferenceExists) {
        return 'target-only'
    }

    if (-not $ReferenceExists -and -not $TargetExists) {
        throw 'Comparison relation requires at least one side to exist.'
    }

    if ([string]$ReferenceState -eq [string]$TargetState) {
        return 'equal'
    }

    if ($ReferenceState -eq 'unavailable' -or $TargetState -eq 'unavailable') {
        return 'unavailable'
    }

    if ($ReferenceState -eq 'unknown' -or $TargetState -eq 'unknown') {
        return 'unknown'
    }

    if ($ReferenceState -eq 'not-applicable' -or $TargetState -eq 'not-applicable') {
        return 'not-applicable'
    }

    return 'different'
}

function New-ComparisonEndpointDescriptor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Report
    )

    return [pscustomobject][ordered]@{
        schemaVersion = [string]$Report.schemaVersion
        generatedAt   = [string]$Report.generatedAt
        audit          = [pscustomobject][ordered]@{
            mode        = [string]$Report.audit.mode
            toolVersion = [string]$Report.audit.toolVersion
        }
        host           = [pscustomobject][ordered]@{
            name         = [string]$Report.host.name
            platform     = [string]$Report.host.platform
            architecture = [string]$Report.host.architecture
        }
    }
}

function New-ComparisonDifference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('provider', 'component', 'version', 'path', 'environment', 'application', 'project', 'git')][string]$Category,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*$')][string]$Kind,
        [AllowNull()][string]$ProviderId,
        [AllowNull()][string]$ComponentId,
        [AllowNull()][string]$SubjectId,
        [Parameter(Mandatory)][ValidateSet('reference-only', 'target-only', 'different', 'unavailable', 'unknown', 'not-applicable')][string]$Relation,
        [AllowNull()][string]$ReferenceState,
        [AllowNull()][string]$TargetState,
        [AllowNull()][object]$ReferenceValue,
        [AllowNull()][object]$TargetValue
    )

    return [pscustomobject][ordered]@{
        category       = $Category
        kind           = $Kind
        providerId     = $(if ([string]::IsNullOrEmpty($ProviderId)) { $null } else { $ProviderId })
        componentId    = $(if ([string]::IsNullOrEmpty($ComponentId)) { $null } else { $ComponentId })
        subjectId      = $(if ([string]::IsNullOrEmpty($SubjectId)) { $null } else { $SubjectId })
        relation       = $Relation
        referenceState = $(if ([string]::IsNullOrEmpty($ReferenceState)) { $null } else { $ReferenceState })
        targetState    = $(if ([string]::IsNullOrEmpty($TargetState)) { $null } else { $TargetState })
        referenceValue = $ReferenceValue
        targetValue    = $TargetValue
    }
}

function New-WorkstationComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$ReferenceReport,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$TargetReport
    )

    $referenceSchema = Assert-WorkstationComparisonReport -Report $ReferenceReport -Role reference
    $targetSchema = Assert-WorkstationComparisonReport -Report $TargetReport -Role target

    if ($referenceSchema.major -ne $targetSchema.major) {
        throw "Reference and target audit schema majors differ: $($referenceSchema.major) vs $($targetSchema.major)."
    }

    $referenceProviders = Get-ComparisonProviderIndex -Report $ReferenceReport -Role reference
    $targetProviders = Get-ComparisonProviderIndex -Report $TargetReport -Role target

    $providerIds = @(
        @($referenceProviders.Keys) + @($targetProviders.Keys) |
            Sort-Object -Unique
    )

    $differences = [System.Collections.Generic.List[object]]::new()

    foreach ($providerId in $providerIds) {
        $referenceExists = $referenceProviders.ContainsKey($providerId)
        $targetExists = $targetProviders.ContainsKey($providerId)
        $referenceProvider = if ($referenceExists) { $referenceProviders[$providerId] } else { $null }
        $targetProvider = if ($targetExists) { $targetProviders[$providerId] } else { $null }

        $referenceStatus = if ($referenceExists) { [string]$referenceProvider.status } else { $null }
        $targetStatus = if ($targetExists) { [string]$targetProvider.status } else { $null }

        $providerRelation = Get-ComparisonRelation `
            -ReferenceExists $referenceExists `
            -TargetExists $targetExists `
            -ReferenceState $referenceStatus `
            -TargetState $targetStatus

        if ($providerRelation -ne 'equal') {
            $providerKind = if ($referenceExists -and $targetExists) { 'status' } else { 'presence' }
            $differences.Add(
                (New-ComparisonDifference `
                    -Category provider `
                    -Kind $providerKind `
                    -ProviderId $providerId `
                    -Relation $providerRelation `
                    -ReferenceState $referenceStatus `
                    -TargetState $targetStatus)
            )
        }

        if (-not ($referenceExists -and $targetExists)) {
            continue
        }

        $referenceComponents = Get-ComparisonComponentIndex -Provider $referenceProvider -ProviderId $providerId -Role reference
        $targetComponents = Get-ComparisonComponentIndex -Provider $targetProvider -ProviderId $providerId -Role target

        $componentIds = @(
            @($referenceComponents.Keys) + @($targetComponents.Keys) |
                Sort-Object -Unique
        )

        foreach ($componentId in $componentIds) {
            $referenceComponentExists = $referenceComponents.ContainsKey($componentId)
            $targetComponentExists = $targetComponents.ContainsKey($componentId)
            $referenceComponent = if ($referenceComponentExists) { $referenceComponents[$componentId] } else { $null }
            $targetComponent = if ($targetComponentExists) { $targetComponents[$componentId] } else { $null }

            $referenceState = if ($referenceComponentExists) { [string]$referenceComponent.state } else { $null }
            $targetState = if ($targetComponentExists) { [string]$targetComponent.state } else { $null }

            $componentRelation = Get-ComparisonRelation `
                -ReferenceExists $referenceComponentExists `
                -TargetExists $targetComponentExists `
                -ReferenceState $referenceState `
                -TargetState $targetState

            if ($componentRelation -eq 'equal') {
                continue
            }

            $componentKind = if ($referenceComponentExists -and $targetComponentExists) { 'state' } else { 'presence' }
            $differences.Add(
                (New-ComparisonDifference `
                    -Category component `
                    -Kind $componentKind `
                    -ProviderId $providerId `
                    -ComponentId $componentId `
                    -Relation $componentRelation `
                    -ReferenceState $referenceState `
                    -TargetState $targetState)
            )
        }
    }

    $orderedDifferences = @(
        $differences |
            Sort-Object category, providerId, componentId, subjectId, kind
    )

    $providerDifferenceCount = @($orderedDifferences | Where-Object category -eq 'provider').Count
    $componentDifferenceCount = @($orderedDifferences | Where-Object category -eq 'component').Count
    $unavailableCount = @($orderedDifferences | Where-Object relation -eq 'unavailable').Count
    $unknownCount = @($orderedDifferences | Where-Object relation -eq 'unknown').Count
    $notApplicableCount = @($orderedDifferences | Where-Object relation -eq 'not-applicable').Count

    return [pscustomobject][ordered]@{
        schemaVersion    = $script:ComparisonSchemaVersion
        auditSchemaMajor = $script:SupportedAuditSchemaMajor
        direction        = 'reference-to-target'
        reference        = New-ComparisonEndpointDescriptor -Report $ReferenceReport
        target           = New-ComparisonEndpointDescriptor -Report $TargetReport
        summary          = [pscustomobject][ordered]@{
            status                   = $(if ($orderedDifferences.Count -eq 0) { 'equal' } else { 'different' })
            differenceCount          = $orderedDifferences.Count
            providerDifferenceCount  = $providerDifferenceCount
            componentDifferenceCount = $componentDifferenceCount
            unavailableCount         = $unavailableCount
            unknownCount             = $unknownCount
            notApplicableCount       = $notApplicableCount
        }
        differences      = $orderedDifferences
    }
}

Export-ModuleMember -Function @(
    'Assert-WorkstationComparisonReport',
    'Get-ComparisonProviderIndex',
    'Get-ComparisonComponentIndex',
    'Get-ComparisonRelation',
    'New-ComparisonDifference',
    'New-WorkstationComparison'
)
