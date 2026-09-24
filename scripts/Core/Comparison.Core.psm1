Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ComparisonSchemaVersion = '1.1.0'
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

function ConvertTo-ComparisonVersionValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$VersionRecord
    )

    if ($null -eq $VersionRecord) {
        return $null
    }

    $normalized = Get-ComparisonOptionalPropertyValue -InputObject $VersionRecord -Name 'normalized'
    $raw = Get-ComparisonOptionalPropertyValue -InputObject $VersionRecord -Name 'raw'
    $channel = Get-ComparisonOptionalPropertyValue -InputObject $VersionRecord -Name 'channel'

    $value = $null
    $valueSource = $null

    if (-not [string]::IsNullOrWhiteSpace([string]$normalized)) {
        $value = [string]$normalized
        $valueSource = 'normalized'
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
        $value = [string]$raw
        $valueSource = 'raw'
    }
    else {
        throw 'Version record does not contain normalized or raw version evidence.'
    }

    return [pscustomobject][ordered]@{
        value       = $value
        valueSource = $valueSource
        channel     = $(if ([string]::IsNullOrWhiteSpace([string]$channel)) { $null } else { [string]$channel })
    }
}

function ConvertTo-ComparisonInstallationValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Installation
    )

    return [pscustomobject][ordered]@{
        path    = $(if ([string]::IsNullOrWhiteSpace([string]$Installation.path)) { $null } else { [string]$Installation.path })
        version = ConvertTo-ComparisonVersionValue -VersionRecord $Installation.version
        active  = [bool]$Installation.active
        source  = [string]$Installation.source
    }
}

function ConvertTo-ComparisonCommandResolutionValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Resolution
    )

    $precedence = Get-ComparisonOptionalPropertyValue -InputObject $Resolution -Name 'precedence'
    $commandType = Get-ComparisonOptionalPropertyValue -InputObject $Resolution -Name 'commandType'
    $path = Get-ComparisonOptionalPropertyValue -InputObject $Resolution -Name 'path'

    return [pscustomobject][ordered]@{
        command     = [string]$Resolution.command
        path        = $(if ([string]::IsNullOrWhiteSpace([string]$path)) { $null } else { [string]$path })
        commandType = $(if ([string]::IsNullOrWhiteSpace([string]$commandType)) { $null } else { [string]$commandType })
        version     = ConvertTo-ComparisonVersionValue -VersionRecord $Resolution.version
        precedence  = $(if ($null -eq $precedence) { $null } else { [int]$precedence })
        active      = [bool]$Resolution.active
    }
}

function ConvertTo-ComparisonCanonicalJson {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value) {
        return 'null'
    }

    return ($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Get-ComparisonValueHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CanonicalJson
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($CanonicalJson)
    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function Add-ComparisonValueDifference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateSet('provider', 'component', 'version', 'path', 'environment', 'application', 'project', 'git')][string]$Category,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*
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

            if ($componentRelation -ne 'equal') {
                $componentKind = if ($referenceComponentExists -and $targetComponentExists) { 'state' } else { 'presence' }
                $parameters = @{
                    Category       = 'component'
                    Kind           = $componentKind
                    ProviderId     = $providerId
                    ComponentId    = $componentId
                    Relation       = $componentRelation
                    ReferenceState = $referenceState
                    TargetState    = $targetState
                }
                $differences.Add((New-ComparisonDifference @parameters))
            }

            if (-not ($referenceComponentExists -and $targetComponentExists)) {
                continue
            }

            $parameters = @{
                Differences        = $differences
                ProviderId         = $providerId
                ComponentId        = $componentId
                ReferenceComponent = $referenceComponent
                TargetComponent    = $targetComponent
            }
            Add-ComparisonComponentVersionDifferences @parameters
        }
    }

    $orderedDifferences = @(
        $differences |
            Sort-Object category, providerId, componentId, subjectId, kind
    )

    $providerDifferenceCount = @($orderedDifferences | Where-Object category -eq 'provider').Count
    $componentDifferenceCount = @($orderedDifferences | Where-Object category -eq 'component').Count
    $versionDifferenceCount = @($orderedDifferences | Where-Object category -eq 'version').Count
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
            versionDifferenceCount   = $versionDifferenceCount
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
    'ConvertTo-ComparisonVersionValue',
    'ConvertTo-ComparisonInstallationValue',
    'ConvertTo-ComparisonCommandResolutionValue',
    'New-ComparisonDifference',
    'New-WorkstationComparison'
)
)][string]$Kind,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComponentId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubjectId,
        [AllowNull()][object]$ReferenceValue,
        [AllowNull()][object]$TargetValue,
        [AllowNull()][string]$ReferenceState,
        [AllowNull()][string]$TargetState
    )

    $referenceExists = ($null -ne $ReferenceValue)
    $targetExists = ($null -ne $TargetValue)

    if (-not $referenceExists -and -not $targetExists) {
        return
    }

    $referenceJson = if ($referenceExists) { ConvertTo-ComparisonCanonicalJson -Value $ReferenceValue } else { $null }
    $targetJson = if ($targetExists) { ConvertTo-ComparisonCanonicalJson -Value $TargetValue } else { $null }

    if ($referenceExists -and $targetExists -and $referenceJson -eq $targetJson) {
        return
    }

    $relation = if ($referenceExists -and -not $targetExists) {
        'reference-only'
    }
    elseif ($targetExists -and -not $referenceExists) {
        'target-only'
    }
    else {
        'different'
    }

    $parameters = @{
        Category       = $Category
        Kind           = $Kind
        ProviderId     = $ProviderId
        ComponentId    = $ComponentId
        SubjectId      = $SubjectId
        Relation       = $relation
        ReferenceState = $ReferenceState
        TargetState    = $TargetState
        ReferenceValue = $ReferenceValue
        TargetValue    = $TargetValue
    }
    $Differences.Add((New-ComparisonDifference @parameters))
}

function Add-ComparisonSetDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateSet('component', 'version')][string]$Category,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*
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
)][string]$Kind,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComponentId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubjectPrefix,
        [object[]]$ReferenceValues = @(),
        [object[]]$TargetValues = @()
    )

    $referenceMap = @{}
    foreach ($value in @($ReferenceValues)) {
        if ($null -eq $value) {
            continue
        }

        $canonical = ConvertTo-ComparisonCanonicalJson -Value $value
        $referenceMap[$canonical] = $value
    }

    $targetMap = @{}
    foreach ($value in @($TargetValues)) {
        if ($null -eq $value) {
            continue
        }

        $canonical = ConvertTo-ComparisonCanonicalJson -Value $value
        $targetMap[$canonical] = $value
    }

    $keys = @(
        @($referenceMap.Keys) + @($targetMap.Keys) |
            Sort-Object -Unique
    )

    foreach ($key in $keys) {
        $referenceExists = $referenceMap.ContainsKey($key)
        $targetExists = $targetMap.ContainsKey($key)

        if ($referenceExists -and $targetExists) {
            continue
        }

        $relation = if ($referenceExists) { 'reference-only' } else { 'target-only' }
        $subjectId = "$SubjectPrefix:$(Get-ComparisonValueHash -CanonicalJson $key)"

        $parameters = @{
            Category       = $Category
            Kind           = $Kind
            ProviderId     = $ProviderId
            ComponentId    = $ComponentId
            SubjectId      = $subjectId
            Relation       = $relation
            ReferenceValue = $(if ($referenceExists) { $referenceMap[$key] } else { $null })
            TargetValue    = $(if ($targetExists) { $targetMap[$key] } else { $null })
        }
        $Differences.Add((New-ComparisonDifference @parameters))
    }
}

function Add-ComparisonComponentVersionDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComponentId,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$ReferenceComponent,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$TargetComponent
    )

    $referenceState = [string]$ReferenceComponent.state
    $targetState = [string]$TargetComponent.state

    $activeParameters = @{
        Differences    = $Differences
        Category       = 'version'
        Kind           = 'active-version'
        ProviderId     = $ProviderId
        ComponentId    = $ComponentId
        SubjectId      = 'active'
        ReferenceValue = ConvertTo-ComparisonVersionValue -VersionRecord $ReferenceComponent.activeVersion
        TargetValue    = ConvertTo-ComparisonVersionValue -VersionRecord $TargetComponent.activeVersion
        ReferenceState = $referenceState
        TargetState    = $targetState
    }
    Add-ComparisonValueDifference @activeParameters

    $referenceDiscovered = @(
        @($ReferenceComponent.discoveredVersions) |
            ForEach-Object { ConvertTo-ComparisonVersionValue -VersionRecord $_ }
    )
    $targetDiscovered = @(
        @($TargetComponent.discoveredVersions) |
            ForEach-Object { ConvertTo-ComparisonVersionValue -VersionRecord $_ }
    )

    $discoveredParameters = @{
        Differences     = $Differences
        Category        = 'version'
        Kind            = 'discovered-version'
        ProviderId      = $ProviderId
        ComponentId     = $ComponentId
        SubjectPrefix   = 'discovered-version'
        ReferenceValues = $referenceDiscovered
        TargetValues    = $targetDiscovered
    }
    Add-ComparisonSetDifferences @discoveredParameters

    $referenceInstallations = @(
        @($ReferenceComponent.installations) |
            ForEach-Object { ConvertTo-ComparisonInstallationValue -Installation $_ }
    )
    $targetInstallations = @(
        @($TargetComponent.installations) |
            ForEach-Object { ConvertTo-ComparisonInstallationValue -Installation $_ }
    )

    $installationParameters = @{
        Differences     = $Differences
        Category        = 'component'
        Kind            = 'installation'
        ProviderId      = $ProviderId
        ComponentId     = $ComponentId
        SubjectPrefix   = 'installation'
        ReferenceValues = $referenceInstallations
        TargetValues    = $targetInstallations
    }
    Add-ComparisonSetDifferences @installationParameters

    $referenceResolutions = @(
        @($ReferenceComponent.commandResolutions) |
            ForEach-Object { ConvertTo-ComparisonCommandResolutionValue -Resolution $_ }
    )
    $targetResolutions = @(
        @($TargetComponent.commandResolutions) |
            ForEach-Object { ConvertTo-ComparisonCommandResolutionValue -Resolution $_ }
    )

    $resolutionParameters = @{
        Differences     = $Differences
        Category        = 'component'
        Kind            = 'command-resolution'
        ProviderId      = $ProviderId
        ComponentId     = $ComponentId
        SubjectPrefix   = 'command-resolution'
        ReferenceValues = $referenceResolutions
        TargetValues    = $targetResolutions
    }
    Add-ComparisonSetDifferences @resolutionParameters

    $referenceIntelligence = $ReferenceComponent.versionIntelligence
    $targetIntelligence = $TargetComponent.versionIntelligence
    $referenceIntelligenceStatus = [string]$referenceIntelligence.status
    $targetIntelligenceStatus = [string]$targetIntelligence.status

    $relationParameters = @{
        ReferenceExists = $true
        TargetExists    = $true
        ReferenceState  = $referenceIntelligenceStatus
        TargetState     = $targetIntelligenceStatus
    }
    $intelligenceRelation = Get-ComparisonRelation @relationParameters

    if ($intelligenceRelation -ne 'equal') {
        $parameters = @{
            Category       = 'version'
            Kind           = 'intelligence-status'
            ProviderId     = $ProviderId
            ComponentId    = $ComponentId
            SubjectId      = 'version-intelligence'
            Relation       = $intelligenceRelation
            ReferenceState = $referenceIntelligenceStatus
            TargetState    = $targetIntelligenceStatus
        }
        $Differences.Add((New-ComparisonDifference @parameters))
    }

    if ($referenceIntelligenceStatus -eq 'known' -and $targetIntelligenceStatus -eq 'known') {
        foreach ($channel in @(
            [pscustomobject]@{ Property = 'latestStable'; Kind = 'latest-stable'; Subject = 'stable' },
            [pscustomobject]@{ Property = 'latestLts'; Kind = 'latest-lts'; Subject = 'lts' },
            [pscustomobject]@{ Property = 'latestCurrent'; Kind = 'latest-current'; Subject = 'current' }
        )) {
            $referenceChannel = Get-ComparisonOptionalPropertyValue -InputObject $referenceIntelligence -Name $channel.Property
            $targetChannel = Get-ComparisonOptionalPropertyValue -InputObject $targetIntelligence -Name $channel.Property

            $channelParameters = @{
                Differences    = $Differences
                Category       = 'version'
                Kind           = $channel.Kind
                ProviderId     = $ProviderId
                ComponentId    = $ComponentId
                SubjectId      = $channel.Subject
                ReferenceValue = ConvertTo-ComparisonVersionValue -VersionRecord $referenceChannel
                TargetValue    = ConvertTo-ComparisonVersionValue -VersionRecord $targetChannel
                ReferenceState = $referenceIntelligenceStatus
                TargetState    = $targetIntelligenceStatus
            }
            Add-ComparisonValueDifference @channelParameters
        }
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
