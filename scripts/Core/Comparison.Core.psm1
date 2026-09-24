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
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateSet('provider', 'component', 'version', 'path', 'environment', 'application', 'project', 'git')][string]$Category,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*$')][string]$Kind,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [AllowNull()][string]$ComponentId,
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
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateSet('component', 'version')][string]$Category,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*$')][string]$Kind,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComponentId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubjectPrefix,
        [object[]]$ReferenceValues = @(),
        [object[]]$TargetValues = @()
    )

    $referenceMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($value in @($ReferenceValues)) {
        if ($null -eq $value) {
            continue
        }

        $canonical = ConvertTo-ComparisonCanonicalJson -Value $value
        $referenceMap[$canonical] = $value
    }

    $targetMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($value in @($TargetValues)) {
        if ($null -eq $value) {
            continue
        }

        $canonical = ConvertTo-ComparisonCanonicalJson -Value $value
        $targetMap[$canonical] = $value
    }

    $keys = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $referenceMap.Keys) {
        $null = $keys.Add($key)
    }
    foreach ($key in $targetMap.Keys) {
        $null = $keys.Add($key)
    }

    foreach ($key in $keys) {
        $referenceExists = $referenceMap.ContainsKey($key)
        $targetExists = $targetMap.ContainsKey($key)

        if ($referenceExists -and $targetExists) {
            continue
        }

        $relation = if ($referenceExists) { 'reference-only' } else { 'target-only' }
        $subjectId = "${SubjectPrefix}:$(Get-ComparisonValueHash -CanonicalJson $key)"

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
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
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
        ReferenceValue = (ConvertTo-ComparisonVersionValue -VersionRecord $ReferenceComponent.activeVersion)
        TargetValue    = (ConvertTo-ComparisonVersionValue -VersionRecord $TargetComponent.activeVersion)
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
                ReferenceValue = (ConvertTo-ComparisonVersionValue -VersionRecord $referenceChannel)
                TargetValue    = (ConvertTo-ComparisonVersionValue -VersionRecord $targetChannel)
                ReferenceState = $referenceIntelligenceStatus
                TargetState    = $targetIntelligenceStatus
            }
            Add-ComparisonValueDifference @channelParameters
        }
    }
}


function Get-ComparisonEvidenceIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    $index = @{}
    foreach ($evidence in @($Provider.evidence)) {
        $evidenceId = [string](Get-ComparisonOptionalPropertyValue -InputObject $evidence -Name 'evidenceId')
        if ([string]::IsNullOrWhiteSpace($evidenceId)) {
            throw "$Role provider '$ProviderId' contains evidence without evidenceId."
        }

        if ($index.ContainsKey($evidenceId)) {
            throw "$Role provider '$ProviderId' contains duplicate evidenceId '$evidenceId'."
        }

        $index[$evidenceId] = $evidence
    }

    return $index
}

function Test-ComparisonProviderHasComparableEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Provider
    )

    return ([string]$Provider.status -notin @('failed', 'unavailable', 'not-applicable'))
}

function ConvertTo-ComparisonPathEntryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Entry
    )

    return [pscustomobject][ordered]@{
        scope                    = [string]$Entry.scope
        position                 = [int]$Entry.position
        pathKey                  = $(if ([string]::IsNullOrWhiteSpace([string]$Entry.comparisonKey)) { $null } else { [string]$Entry.comparisonKey })
        exists                   = $(if ($null -eq $Entry.exists) { $null } else { [bool]$Entry.exists })
        duplicateWithinScope     = [bool]$Entry.duplicateWithinScope
        firstEquivalentPosition  = $(if ($null -eq $Entry.firstEquivalentPosition) { $null } else { [int]$Entry.firstEquivalentPosition })
        hasUnresolvedVariable    = [bool]$Entry.hasUnresolvedVariable
        unresolvedVariables      = @(@($Entry.unresolvedVariables) | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        unapprovedReferenceCount = [int]$Entry.unapprovedReferenceCount
    }
}

function ConvertTo-ComparisonPathScopeHealthValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Attributes
    )

    return [pscustomobject][ordered]@{
        entryCount              = [int]$Attributes.entryCount
        duplicateCount          = [int]$Attributes.duplicateCount
        missingCount            = [int]$Attributes.missingCount
        unresolvedVariableCount = [int]$Attributes.unresolvedVariableCount
    }
}

function ConvertTo-ComparisonPathOrderValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Attributes
    )

    return @(
        @($Attributes.entries) |
            Sort-Object position |
            ForEach-Object { ConvertTo-ComparisonPathEntryValue -Entry $_ }
    )
}

function ConvertTo-ComparisonPathFilteredEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Attributes,
        [Parameter(Mandatory)][ValidateSet('duplicate', 'missing', 'unresolved')][string]$Filter
    )

    $entries = @($Attributes.entries)
    $filtered = switch ($Filter) {
        'duplicate' { @($entries | Where-Object { $_.duplicateWithinScope }) }
        'missing' { @($entries | Where-Object { $_.exists -eq $false }) }
        'unresolved' { @($entries | Where-Object { $_.hasUnresolvedVariable }) }
    }

    return @(
        $filtered |
            Sort-Object position |
            ForEach-Object { ConvertTo-ComparisonPathEntryValue -Entry $_ }
    )
}

function ConvertTo-ComparisonPersistentDuplicateValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Attributes
    )

    $duplicates = @(
        @($Attributes.duplicates) |
            Sort-Object comparisonKey |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    pathKey = [string]$_.comparisonKey
                    scopes = @(@($_.scopes) | ForEach-Object { [string]$_ } | Sort-Object -Unique)
                    occurrences = @(
                        @($_.occurrences) |
                            Sort-Object scope, position |
                            ForEach-Object {
                                [pscustomobject][ordered]@{
                                    scope = [string]$_.scope
                                    position = [int]$_.position
                                }
                            }
                    )
                }
            }
    )

    return [pscustomobject][ordered]@{
        duplicateCount = [int]$Attributes.duplicateCount
        duplicates = $duplicates
    }
}

function ConvertTo-ComparisonEnvironmentScopeValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$ScopeValue
    )

    return [pscustomobject][ordered]@{
        scope                    = [string]$ScopeValue.scope
        state                    = [string]$ScopeValue.state
        pathKey                  = $(if ([string]::IsNullOrWhiteSpace([string]$ScopeValue.comparisonKey)) { $null } else { [string]$ScopeValue.comparisonKey })
        exists                   = $(if ($null -eq $ScopeValue.exists) { $null } else { [bool]$ScopeValue.exists })
        pathItems                = @(
            @($ScopeValue.pathItems) |
                Sort-Object position |
                ForEach-Object { ConvertTo-ComparisonPathEntryValue -Entry $_ }
        )
        missingPathCount         = [int]$ScopeValue.missingPathCount
        hasUnresolvedVariable    = [bool]$ScopeValue.hasUnresolvedVariable
        unresolvedVariables      = @(@($ScopeValue.unresolvedVariables) | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        unapprovedReferenceCount = [int]$ScopeValue.unapprovedReferenceCount
        isConfigured             = [bool]$ScopeValue.isConfigured
        isInvalid                = [bool]$ScopeValue.isInvalid
    }
}

function ConvertTo-ComparisonEnvironmentVariableValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Attributes
    )

    $scopeOrder = @{ process = 0; user = 1; machine = 2 }

    return [pscustomobject][ordered]@{
        kind                     = [string]$Attributes.kind
        filesystem               = [bool]$Attributes.filesystem
        configuredScopeCount     = [int]$Attributes.configuredScopeCount
        valueScopeCount          = [int]$Attributes.valueScopeCount
        distinctValueCount       = [int]$Attributes.distinctValueCount
        scopeConflict            = [bool]$Attributes.scopeConflict
        emptyScopeCount          = [int]$Attributes.emptyScopeCount
        invalidScopeCount        = [int]$Attributes.invalidScopeCount
        missingPathCount         = [int]$Attributes.missingPathCount
        unresolvedScopeCount     = [int]$Attributes.unresolvedScopeCount
        unapprovedReferenceCount = [int]$Attributes.unapprovedReferenceCount
        scopes                   = @(
            @($Attributes.scopes) |
                Sort-Object @{ Expression = { $scopeOrder[[string]$_.scope] }; Ascending = $true } |
                ForEach-Object { ConvertTo-ComparisonEnvironmentScopeValue -ScopeValue $_ }
        )
    }
}

function ConvertTo-ComparisonPathPrecedenceResolutionValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Resolution
    )

    return [pscustomobject][ordered]@{
        command                = [string]$Resolution.command
        commandType            = [string]$Resolution.commandType
        precedence             = [int]$Resolution.precedence
        active                 = [bool]$Resolution.active
        pathBased              = [bool]$Resolution.pathBased
        pathKey                = $(if ([string]::IsNullOrWhiteSpace([string]$Resolution.pathComparisonKey)) { $null } else { [string]$Resolution.pathComparisonKey })
        pathMappingStatus      = [string]$Resolution.pathMappingStatus
        pathPosition           = $(if ($null -eq $Resolution.pathPosition) { $null } else { [int]$Resolution.pathPosition })
        candidatePathPositions = @(@($Resolution.candidatePathPositions) | ForEach-Object { [int]$_ } | Sort-Object)
    }
}

function ConvertTo-ComparisonPathPrecedenceValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Attributes
    )

    $activeResolution = Get-ComparisonOptionalPropertyValue -InputObject $Attributes -Name 'activeResolution'

    return [pscustomobject][ordered]@{
        command                     = [string]$Attributes.command
        resolutionCount             = [int]$Attributes.resolutionCount
        pathBasedResolutionCount    = [int]$Attributes.pathBasedResolutionCount
        mappedResolutionCount       = [int]$Attributes.mappedResolutionCount
        unmappedPathResolutionCount = [int]$Attributes.unmappedPathResolutionCount
        hasResolutionCollision      = [bool]$Attributes.hasResolutionCollision
        hasPathResolutionCollision  = [bool]$Attributes.hasPathResolutionCollision
        hasPathOrderConflict        = [bool]$Attributes.hasPathOrderConflict
        fullyMapped                 = [bool]$Attributes.fullyMapped
        activeResolution            = $(if ($null -eq $activeResolution) { $null } else { ConvertTo-ComparisonPathPrecedenceResolutionValue -Resolution $activeResolution })
        shadowedResolutions         = @(
            @($Attributes.shadowedResolutions) |
                Sort-Object precedence, pathComparisonKey |
                ForEach-Object { ConvertTo-ComparisonPathPrecedenceResolutionValue -Resolution $_ }
        )
        resolutions                 = @(
            @($Attributes.resolutions) |
                Sort-Object precedence, pathComparisonKey |
                ForEach-Object { ConvertTo-ComparisonPathPrecedenceResolutionValue -Resolution $_ }
        )
    }
}

function Get-ComparisonApprovedEnvironmentNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$EvidenceIndex
    )

    if (-not $EvidenceIndex.ContainsKey('environment.allowlist.boundary')) {
        return @()
    }

    $boundary = $EvidenceIndex['environment.allowlist.boundary']
    return @(
        @($boundary.attributes.approvedNames) |
            ForEach-Object { ([string]$_).ToUpperInvariant() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Add-ComparisonEnvironmentBaselineDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$ReferenceProvider,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$TargetProvider
    )

    if (-not (Test-ComparisonProviderHasComparableEvidence -Provider $ReferenceProvider) -or
        -not (Test-ComparisonProviderHasComparableEvidence -Provider $TargetProvider)) {
        return
    }

    $referenceEvidence = Get-ComparisonEvidenceIndex -Provider $ReferenceProvider -ProviderId 'environment.baseline' -Role reference
    $targetEvidence = Get-ComparisonEvidenceIndex -Provider $TargetProvider -ProviderId 'environment.baseline' -Role target

    $referenceAllowed = @(Get-ComparisonApprovedEnvironmentNames -EvidenceIndex $referenceEvidence)
    $targetAllowed = @(Get-ComparisonApprovedEnvironmentNames -EvidenceIndex $targetEvidence)

    $allowlistParameters = @{
        Differences    = $Differences
        Category       = 'environment'
        Kind           = 'allowlist'
        ProviderId     = 'environment.baseline'
        ComponentId    = $null
        SubjectId      = 'approved-names'
        ReferenceValue = $referenceAllowed
        TargetValue    = $targetAllowed
        ReferenceState = [string]$ReferenceProvider.status
        TargetState    = [string]$TargetProvider.status
    }
    Add-ComparisonValueDifference @allowlistParameters

    $targetLookup = @{}
    foreach ($name in $targetAllowed) {
        $targetLookup[$name] = $true
    }

    $safeNames = @(
        $referenceAllowed |
            Where-Object { $targetLookup.ContainsKey($_) } |
            Sort-Object -Unique
    )

    foreach ($name in $safeNames) {
        $evidenceId = 'environment.' + $name.ToLowerInvariant()
        $referenceItem = if ($referenceEvidence.ContainsKey($evidenceId)) { $referenceEvidence[$evidenceId] } else { $null }
        $targetItem = if ($targetEvidence.ContainsKey($evidenceId)) { $targetEvidence[$evidenceId] } else { $null }

        $referenceValue = if ($null -eq $referenceItem) { $null } else { ConvertTo-ComparisonEnvironmentVariableValue -Attributes $referenceItem.attributes }
        $targetValue = if ($null -eq $targetItem) { $null } else { ConvertTo-ComparisonEnvironmentVariableValue -Attributes $targetItem.attributes }

        $parameters = @{
            Differences    = $Differences
            Category       = 'environment'
            Kind           = 'allowlisted-variable'
            ProviderId     = 'environment.baseline'
            ComponentId    = $null
            SubjectId      = $name.ToLowerInvariant()
            ReferenceValue = $referenceValue
            TargetValue    = $targetValue
            ReferenceState = [string]$ReferenceProvider.status
            TargetState    = [string]$TargetProvider.status
        }
        Add-ComparisonValueDifference @parameters
    }

    foreach ($scope in @('machine', 'user', 'process')) {
        $evidenceId = "path.$scope.health"
        $referenceItem = if ($referenceEvidence.ContainsKey($evidenceId)) { $referenceEvidence[$evidenceId] } else { $null }
        $targetItem = if ($targetEvidence.ContainsKey($evidenceId)) { $targetEvidence[$evidenceId] } else { $null }

        if ($null -eq $referenceItem -and $null -eq $targetItem) {
            continue
        }

        foreach ($kind in @('scope-health', 'scope-order', 'duplicate-entries', 'missing-entries', 'unresolved-entries')) {
            $referenceValue = $null
            $targetValue = $null

            if ($null -ne $referenceItem) {
                $referenceValue = switch ($kind) {
                    'scope-health' { ConvertTo-ComparisonPathScopeHealthValue -Attributes $referenceItem.attributes }
                    'scope-order' { ConvertTo-ComparisonPathOrderValue -Attributes $referenceItem.attributes }
                    'duplicate-entries' { ConvertTo-ComparisonPathFilteredEntries -Attributes $referenceItem.attributes -Filter duplicate }
                    'missing-entries' { ConvertTo-ComparisonPathFilteredEntries -Attributes $referenceItem.attributes -Filter missing }
                    'unresolved-entries' { ConvertTo-ComparisonPathFilteredEntries -Attributes $referenceItem.attributes -Filter unresolved }
                }
            }

            if ($null -ne $targetItem) {
                $targetValue = switch ($kind) {
                    'scope-health' { ConvertTo-ComparisonPathScopeHealthValue -Attributes $targetItem.attributes }
                    'scope-order' { ConvertTo-ComparisonPathOrderValue -Attributes $targetItem.attributes }
                    'duplicate-entries' { ConvertTo-ComparisonPathFilteredEntries -Attributes $targetItem.attributes -Filter duplicate }
                    'missing-entries' { ConvertTo-ComparisonPathFilteredEntries -Attributes $targetItem.attributes -Filter missing }
                    'unresolved-entries' { ConvertTo-ComparisonPathFilteredEntries -Attributes $targetItem.attributes -Filter unresolved }
                }
            }

            $parameters = @{
                Differences    = $Differences
                Category       = 'path'
                Kind           = $kind
                ProviderId     = 'environment.baseline'
                ComponentId    = $null
                SubjectId      = $scope
                ReferenceValue = $referenceValue
                TargetValue    = $targetValue
                ReferenceState = [string]$ReferenceProvider.status
                TargetState    = [string]$TargetProvider.status
            }
            Add-ComparisonValueDifference @parameters
        }
    }

    $crossScopeId = 'path.persistent.cross-scope-duplicates'
    $referenceCrossScope = if ($referenceEvidence.ContainsKey($crossScopeId)) { $referenceEvidence[$crossScopeId] } else { $null }
    $targetCrossScope = if ($targetEvidence.ContainsKey($crossScopeId)) { $targetEvidence[$crossScopeId] } else { $null }

    $crossScopeParameters = @{
        Differences    = $Differences
        Category       = 'path'
        Kind           = 'persistent-cross-scope-duplicates'
        ProviderId     = 'environment.baseline'
        ComponentId    = $null
        SubjectId      = 'machine-user'
        ReferenceValue = $(if ($null -eq $referenceCrossScope) { $null } else { ConvertTo-ComparisonPersistentDuplicateValue -Attributes $referenceCrossScope.attributes })
        TargetValue    = $(if ($null -eq $targetCrossScope) { $null } else { ConvertTo-ComparisonPersistentDuplicateValue -Attributes $targetCrossScope.attributes })
        ReferenceState = [string]$ReferenceProvider.status
        TargetState    = [string]$TargetProvider.status
    }
    Add-ComparisonValueDifference @crossScopeParameters
}

function Add-ComparisonPathPrecedenceDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$ReferenceProvider,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$TargetProvider
    )

    if (-not (Test-ComparisonProviderHasComparableEvidence -Provider $ReferenceProvider) -or
        -not (Test-ComparisonProviderHasComparableEvidence -Provider $TargetProvider)) {
        return
    }

    $referenceEvidence = Get-ComparisonEvidenceIndex -Provider $ReferenceProvider -ProviderId 'path.precedence' -Role reference
    $targetEvidence = Get-ComparisonEvidenceIndex -Provider $TargetProvider -ProviderId 'path.precedence' -Role target

    $evidenceIds = @(
        @($referenceEvidence.Keys) + @($targetEvidence.Keys) |
            Where-Object { $_ -like 'path-precedence.command.*' } |
            Sort-Object -Unique
    )

    foreach ($evidenceId in $evidenceIds) {
        $referenceItem = if ($referenceEvidence.ContainsKey($evidenceId)) { $referenceEvidence[$evidenceId] } else { $null }
        $targetItem = if ($targetEvidence.ContainsKey($evidenceId)) { $targetEvidence[$evidenceId] } else { $null }

        $parameters = @{
            Differences    = $Differences
            Category       = 'path'
            Kind           = 'command-precedence'
            ProviderId     = 'path.precedence'
            ComponentId    = $null
            SubjectId      = $evidenceId
            ReferenceValue = $(if ($null -eq $referenceItem) { $null } else { ConvertTo-ComparisonPathPrecedenceValue -Attributes $referenceItem.attributes })
            TargetValue    = $(if ($null -eq $targetItem) { $null } else { ConvertTo-ComparisonPathPrecedenceValue -Attributes $targetItem.attributes })
            ReferenceState = [string]$ReferenceProvider.status
            TargetState    = [string]$TargetProvider.status
        }
        Add-ComparisonValueDifference @parameters
    }
}


function Get-ComparisonWinGetEvidenceState {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Evidence
    )

    if ($null -eq $Evidence) {
        return $null
    }

    $attributes = Get-ComparisonOptionalPropertyValue -InputObject $Evidence -Name 'attributes'
    if ($null -eq $attributes) {
        return $null
    }

    $status = Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name 'status'
    if ([string]::IsNullOrWhiteSpace([string]$status)) {
        return $null
    }

    return [string]$status
}

function Get-ComparisonWinGetStateRelation {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ReferenceState,
        [AllowNull()][string]$TargetState
    )

    if ([string]$ReferenceState -eq [string]$TargetState) {
        return 'equal'
    }

    if ([string]::IsNullOrWhiteSpace([string]$ReferenceState)) {
        return 'target-only'
    }

    if ([string]::IsNullOrWhiteSpace([string]$TargetState)) {
        return 'reference-only'
    }

    if ($ReferenceState -eq 'unknown' -or $TargetState -eq 'unknown') {
        return 'unknown'
    }

    $unavailableStates = @(
        'unavailable',
        'source-unavailable',
        'agreement-required',
        'command-failed'
    )
    if ($ReferenceState -in $unavailableStates -or $TargetState -in $unavailableStates) {
        return 'unavailable'
    }

    return 'different'
}

function Add-ComparisonWinGetEvidenceStateDifference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*$')][string]$Kind,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubjectId,
        [AllowNull()][object]$ReferenceEvidence,
        [AllowNull()][object]$TargetEvidence
    )

    $referenceState = Get-ComparisonWinGetEvidenceState -Evidence $ReferenceEvidence
    $targetState = Get-ComparisonWinGetEvidenceState -Evidence $TargetEvidence
    $relation = Get-ComparisonWinGetStateRelation -ReferenceState $referenceState -TargetState $targetState

    if ($relation -eq 'equal') {
        return
    }

    $parameters = @{
        Category       = 'application'
        Kind           = $Kind
        ProviderId     = 'winget.baseline'
        ComponentId    = 'winget'
        SubjectId      = $SubjectId
        Relation       = $relation
        ReferenceState = $referenceState
        TargetState    = $targetState
    }
    $Differences.Add((New-ComparisonDifference @parameters))
}

function Get-ComparisonWinGetReliablePackageIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Evidence,
        [Parameter(Mandatory)][ValidateSet('packages', 'upgrades')][string]$RecordProperty,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    $attributes = Get-ComparisonOptionalPropertyValue -InputObject $Evidence -Name 'attributes'
    if ($null -eq $attributes) {
        throw "$Role WinGet '$RecordProperty' evidence does not contain attributes."
    }

    $records = Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name $RecordProperty
    $index = @{}

    foreach ($record in @($records)) {
        if ($null -eq $record) {
            continue
        }

        $identityReliable = Get-ComparisonOptionalPropertyValue -InputObject $record -Name 'identityReliable'
        $packageId = [string](Get-ComparisonOptionalPropertyValue -InputObject $record -Name 'packageId')

        if ($identityReliable -ne $true -or [string]::IsNullOrWhiteSpace($packageId)) {
            continue
        }

        $key = $packageId.Trim().ToLowerInvariant()
        if ($index.ContainsKey($key)) {
            throw "$Role WinGet '$RecordProperty' evidence contains duplicate reliable packageId '$packageId'."
        }

        $index[$key] = $record
    }

    return $index
}

function New-ComparisonWinGetPackageIdentityValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageId
    )

    return [pscustomobject][ordered]@{
        packageId = $PackageId.Trim().ToLowerInvariant()
    }
}

function Add-ComparisonWinGetVersionDifference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*$')][string]$Kind,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubjectId,
        [Parameter(Mandatory)][ValidateSet('installedVersion', 'availableVersion')][string]$VersionProperty,
        [Parameter(Mandatory)][ValidateSet('installedVersionReliable', 'availableVersionReliable')][string]$ReliabilityProperty,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$ReferenceRecord,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$TargetRecord
    )

    $referenceReliable = (Get-ComparisonOptionalPropertyValue -InputObject $ReferenceRecord -Name $ReliabilityProperty) -eq $true
    $targetReliable = (Get-ComparisonOptionalPropertyValue -InputObject $TargetRecord -Name $ReliabilityProperty) -eq $true

    $referenceRaw = Get-ComparisonOptionalPropertyValue -InputObject $ReferenceRecord -Name $VersionProperty
    $targetRaw = Get-ComparisonOptionalPropertyValue -InputObject $TargetRecord -Name $VersionProperty

    $referenceKnown = $referenceReliable -and -not [string]::IsNullOrWhiteSpace([string]$referenceRaw)
    $targetKnown = $targetReliable -and -not [string]::IsNullOrWhiteSpace([string]$targetRaw)

    if (-not $referenceKnown -and -not $targetKnown) {
        return
    }

    $referenceValue = $(if ($referenceKnown) { [string]$referenceRaw } else { $null })
    $targetValue = $(if ($targetKnown) { [string]$targetRaw } else { $null })
    $referenceState = $(if ($referenceKnown) { 'known' } else { 'unknown' })
    $targetState = $(if ($targetKnown) { 'known' } else { 'unknown' })

    if ($referenceKnown -and $targetKnown -and $referenceValue -eq $targetValue) {
        return
    }

    $relation = if ($referenceKnown -and $targetKnown) { 'different' } else { 'unknown' }

    $parameters = @{
        Category       = 'application'
        Kind           = $Kind
        ProviderId     = 'winget.baseline'
        ComponentId    = 'winget'
        SubjectId      = $SubjectId
        Relation       = $relation
        ReferenceState = $referenceState
        TargetState    = $targetState
        ReferenceValue = $referenceValue
        TargetValue    = $targetValue
    }
    $Differences.Add((New-ComparisonDifference @parameters))
}

function Test-ComparisonWinGetUpgradeStateComparable {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$State
    )

    return ($State -in @('current', 'upgrades-available'))
}

function Add-ComparisonWinGetApplicationDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$ReferenceProvider,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$TargetProvider
    )

    if (-not (Test-ComparisonProviderHasComparableEvidence -Provider $ReferenceProvider) -or
        -not (Test-ComparisonProviderHasComparableEvidence -Provider $TargetProvider)) {
        return
    }

    $referenceEvidence = Get-ComparisonEvidenceIndex -Provider $ReferenceProvider -ProviderId 'winget.baseline' -Role reference
    $targetEvidence = Get-ComparisonEvidenceIndex -Provider $TargetProvider -ProviderId 'winget.baseline' -Role target

    $inventoryEvidenceId = 'winget.inventory.normalized'
    $referenceInventory = if ($referenceEvidence.ContainsKey($inventoryEvidenceId)) { $referenceEvidence[$inventoryEvidenceId] } else { $null }
    $targetInventory = if ($targetEvidence.ContainsKey($inventoryEvidenceId)) { $targetEvidence[$inventoryEvidenceId] } else { $null }

    $inventoryStateParameters = @{
        Differences       = $Differences
        Kind              = 'inventory-status'
        SubjectId         = 'winget-inventory'
        ReferenceEvidence = $referenceInventory
        TargetEvidence    = $targetInventory
    }
    Add-ComparisonWinGetEvidenceStateDifference @inventoryStateParameters

    $referenceInventoryState = Get-ComparisonWinGetEvidenceState -Evidence $referenceInventory
    $targetInventoryState = Get-ComparisonWinGetEvidenceState -Evidence $targetInventory

    if ($null -ne $referenceInventory -and
        $null -ne $targetInventory -and
        $referenceInventoryState -eq 'known' -and
        $targetInventoryState -eq 'known') {

        $referencePackages = Get-ComparisonWinGetReliablePackageIndex -Evidence $referenceInventory -RecordProperty packages -Role reference
        $targetPackages = Get-ComparisonWinGetReliablePackageIndex -Evidence $targetInventory -RecordProperty packages -Role target
        $packageIds = @(
            @($referencePackages.Keys) + @($targetPackages.Keys) |
                Sort-Object -Unique
        )

        foreach ($packageId in $packageIds) {
            $referenceExists = $referencePackages.ContainsKey($packageId)
            $targetExists = $targetPackages.ContainsKey($packageId)
            $subjectId = "winget-package:$packageId"

            if (-not ($referenceExists -and $targetExists)) {
                $relation = if ($referenceExists) { 'reference-only' } else { 'target-only' }
                $parameters = @{
                    Category       = 'application'
                    Kind           = 'presence'
                    ProviderId     = 'winget.baseline'
                    ComponentId    = 'winget'
                    SubjectId      = $subjectId
                    Relation       = $relation
                    ReferenceState = $(if ($referenceExists) { 'installed' } else { 'missing' })
                    TargetState    = $(if ($targetExists) { 'installed' } else { 'missing' })
                    ReferenceValue = $(if ($referenceExists) { New-ComparisonWinGetPackageIdentityValue -PackageId $packageId } else { $null })
                    TargetValue    = $(if ($targetExists) { New-ComparisonWinGetPackageIdentityValue -PackageId $packageId } else { $null })
                }
                $Differences.Add((New-ComparisonDifference @parameters))
                continue
            }

            $versionParameters = @{
                Differences         = $Differences
                Kind                = 'installed-version'
                SubjectId           = $subjectId
                VersionProperty     = 'installedVersion'
                ReliabilityProperty = 'installedVersionReliable'
                ReferenceRecord     = $referencePackages[$packageId]
                TargetRecord        = $targetPackages[$packageId]
            }
            Add-ComparisonWinGetVersionDifference @versionParameters
        }
    }

    $upgradeEvidenceId = 'winget.upgrades.normalized'
    $referenceUpgrades = if ($referenceEvidence.ContainsKey($upgradeEvidenceId)) { $referenceEvidence[$upgradeEvidenceId] } else { $null }
    $targetUpgrades = if ($targetEvidence.ContainsKey($upgradeEvidenceId)) { $targetEvidence[$upgradeEvidenceId] } else { $null }

    $upgradeStateParameters = @{
        Differences       = $Differences
        Kind              = 'upgrade-status'
        SubjectId         = 'winget-upgrades'
        ReferenceEvidence = $referenceUpgrades
        TargetEvidence    = $targetUpgrades
    }
    Add-ComparisonWinGetEvidenceStateDifference @upgradeStateParameters

    $referenceUpgradeState = Get-ComparisonWinGetEvidenceState -Evidence $referenceUpgrades
    $targetUpgradeState = Get-ComparisonWinGetEvidenceState -Evidence $targetUpgrades

    if ($null -eq $referenceUpgrades -or
        $null -eq $targetUpgrades -or
        -not (Test-ComparisonWinGetUpgradeStateComparable -State $referenceUpgradeState) -or
        -not (Test-ComparisonWinGetUpgradeStateComparable -State $targetUpgradeState)) {
        return
    }

    $referenceUpgradePackages = Get-ComparisonWinGetReliablePackageIndex -Evidence $referenceUpgrades -RecordProperty upgrades -Role reference
    $targetUpgradePackages = Get-ComparisonWinGetReliablePackageIndex -Evidence $targetUpgrades -RecordProperty upgrades -Role target
    $upgradePackageIds = @(
        @($referenceUpgradePackages.Keys) + @($targetUpgradePackages.Keys) |
            Sort-Object -Unique
    )

    foreach ($packageId in $upgradePackageIds) {
        $referenceExists = $referenceUpgradePackages.ContainsKey($packageId)
        $targetExists = $targetUpgradePackages.ContainsKey($packageId)
        $subjectId = "winget-upgrade:$packageId"

        if (-not ($referenceExists -and $targetExists)) {
            $relation = if ($referenceExists) { 'reference-only' } else { 'target-only' }
            $parameters = @{
                Category       = 'application'
                Kind           = 'upgrade-availability'
                ProviderId     = 'winget.baseline'
                ComponentId    = 'winget'
                SubjectId      = $subjectId
                Relation       = $relation
                ReferenceState = $(if ($referenceExists) { 'upgrade-available' } else { 'current' })
                TargetState    = $(if ($targetExists) { 'upgrade-available' } else { 'current' })
                ReferenceValue = $(if ($referenceExists) { New-ComparisonWinGetPackageIdentityValue -PackageId $packageId } else { $null })
                TargetValue    = $(if ($targetExists) { New-ComparisonWinGetPackageIdentityValue -PackageId $packageId } else { $null })
            }
            $Differences.Add((New-ComparisonDifference @parameters))
            continue
        }

        $versionParameters = @{
            Differences         = $Differences
            Kind                = 'available-version'
            SubjectId           = $subjectId
            VersionProperty     = 'availableVersion'
            ReliabilityProperty = 'availableVersionReliable'
            ReferenceRecord     = $referenceUpgradePackages[$packageId]
            TargetRecord        = $targetUpgradePackages[$packageId]
        }
        Add-ComparisonWinGetVersionDifference @versionParameters
    }
}


function Test-ComparisonProjectClassificationProviderReadable {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Provider
    )

    if ($null -eq $Provider) {
        return $false
    }

    return ([string]$Provider.status -notin @('failed', 'unavailable'))
}

function Get-ComparisonProjectSummaryEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EvidenceId,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    $evidenceIndex = Get-ComparisonEvidenceIndex -Provider $Provider -ProviderId $ProviderId -Role $Role
    if (-not $evidenceIndex.ContainsKey($EvidenceId)) {
        return $null
    }

    return $evidenceIndex[$EvidenceId]
}

function ConvertTo-ComparisonProjectRelativePath {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return '.'
    }

    $normalized = $RelativePath.Trim().Replace('\', '/')
    while ($normalized.StartsWith('./', [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return '.'
    }

    return $normalized.ToLowerInvariant()
}

function Get-ComparisonProjectLeafName {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Path,
        [Parameter(Mandatory)][int]$ProjectIndex
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "project-$ProjectIndex"
    }

    $trimmed = $Path.Trim().TrimEnd('\', '/')
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return "project-$ProjectIndex"
    }

    $segments = @($trimmed -split '[\\/]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) {
        return "project-$ProjectIndex"
    }

    return ([string]$segments[-1]).ToLowerInvariant()
}

function Get-ComparisonProjectClassificationIndex {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SummaryEvidenceId,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    $index = @{}
    if (-not (Test-ComparisonProjectClassificationProviderReadable -Provider $Provider)) {
        return [pscustomobject][ordered]@{
            available = $false
            projects  = $index
        }
    }

    $summary = Get-ComparisonProjectSummaryEvidence -Provider $Provider -ProviderId $ProviderId -EvidenceId $SummaryEvidenceId -Role $Role
    if ($null -eq $summary) {
        return [pscustomobject][ordered]@{
            available = $false
            projects  = $index
        }
    }

    $attributes = Get-ComparisonOptionalPropertyValue -InputObject $summary -Name 'attributes'
    $projects = Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name 'projects'

    foreach ($project in @($projects)) {
        if ($null -eq $project) {
            continue
        }

        $projectIndexValue = Get-ComparisonOptionalPropertyValue -InputObject $project -Name 'projectIndex'
        if ($null -eq $projectIndexValue) {
            continue
        }

        $projectIndex = [int]$projectIndexValue
        if ($index.ContainsKey($projectIndex)) {
            throw "$Role provider '$ProviderId' contains duplicate projectIndex '$projectIndex'."
        }

        $index[$projectIndex] = $project
    }

    return [pscustomobject][ordered]@{
        available = $true
        projects  = $index
    }
}

function ConvertTo-ComparisonProjectTypes {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$JavaScriptProject,
        [AllowNull()][object]$NonJavaScriptProject
    )

    $types = @()
    if ($null -ne $JavaScriptProject) {
        $types += @((Get-ComparisonOptionalPropertyValue -InputObject $JavaScriptProject -Name 'types'))
    }
    if ($null -ne $NonJavaScriptProject) {
        $types += @((Get-ComparisonOptionalPropertyValue -InputObject $NonJavaScriptProject -Name 'types'))
    }

    return @(
        $types |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
            Sort-Object -Unique
    )
}

function ConvertTo-ComparisonProjectRuntimeConstraints {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$JavaScriptProject,
        [AllowNull()][object]$NonJavaScriptProject
    )

    $constraints = [System.Collections.Generic.List[object]]::new()

    if ($null -ne $JavaScriptProject) {
        $nodePins = Get-ComparisonOptionalPropertyValue -InputObject $JavaScriptProject -Name 'nodePins'
        foreach ($pin in @($nodePins)) {
            if ($null -eq $pin) {
                continue
            }

            $source = [string](Get-ComparisonOptionalPropertyValue -InputObject $pin -Name 'source')
            $value = [string](Get-ComparisonOptionalPropertyValue -InputObject $pin -Name 'value')
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $constraints.Add([pscustomobject][ordered]@{
                ecosystem = 'node'
                source    = $source.Trim().ToLowerInvariant()
                value     = $value.Trim()
            })
        }
    }

    if ($null -ne $NonJavaScriptProject) {
        $nonJavaScriptConstraints = Get-ComparisonOptionalPropertyValue -InputObject $NonJavaScriptProject -Name 'constraints'
        foreach ($constraint in @($nonJavaScriptConstraints)) {
            if ($null -eq $constraint) {
                continue
            }

            $ecosystem = [string](Get-ComparisonOptionalPropertyValue -InputObject $constraint -Name 'ecosystem')
            $source = [string](Get-ComparisonOptionalPropertyValue -InputObject $constraint -Name 'source')
            $value = [string](Get-ComparisonOptionalPropertyValue -InputObject $constraint -Name 'value')
            if ([string]::IsNullOrWhiteSpace($ecosystem) -or
                [string]::IsNullOrWhiteSpace($source) -or
                [string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            $constraints.Add([pscustomobject][ordered]@{
                ecosystem = $ecosystem.Trim().ToLowerInvariant()
                source    = $source.Trim().ToLowerInvariant()
                value     = $value.Trim()
            })
        }
    }

    return @($constraints.ToArray() | Sort-Object ecosystem, source, value)
}

function ConvertTo-ComparisonProjectPackageManager {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$JavaScriptProject
    )

    if ($null -eq $JavaScriptProject) {
        return $null
    }

    $packageManager = Get-ComparisonOptionalPropertyValue -InputObject $JavaScriptProject -Name 'packageManager'
    $declaration = $null

    if ($null -ne $packageManager) {
        $name = [string](Get-ComparisonOptionalPropertyValue -InputObject $packageManager -Name 'name')
        $version = [string](Get-ComparisonOptionalPropertyValue -InputObject $packageManager -Name 'version')
        $validValue = Get-ComparisonOptionalPropertyValue -InputObject $packageManager -Name 'valid'

        $declaration = [pscustomobject][ordered]@{
            valid   = ($validValue -eq $true)
            name    = $(if ([string]::IsNullOrWhiteSpace($name)) { $null } else { $name.Trim().ToLowerInvariant() })
            version = $(if ([string]::IsNullOrWhiteSpace($version)) { $null } else { $version.Trim() })
        }
    }

    $lockManagers = @(
        @((Get-ComparisonOptionalPropertyValue -InputObject $JavaScriptProject -Name 'lockManagers')) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
            Sort-Object -Unique
    )

    if ($null -eq $declaration -and $lockManagers.Count -eq 0) {
        return $null
    }

    return [pscustomobject][ordered]@{
        declaration = $declaration
        lockManagers = $lockManagers
    }
}

function New-ComparisonProjectIdentityValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RelativePath
    )

    return [pscustomobject][ordered]@{
        name         = $Name
        relativePath = $RelativePath
    }
}

function Get-ComparisonProjectReportState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][System.Collections.IDictionary]$Providers,
        [Parameter(Mandatory)][ValidateSet('reference', 'target')][string]$Role
    )

    if (-not $Providers.Contains('projects.local')) {
        return [pscustomobject][ordered]@{
            available              = $false
            javascriptAvailable    = $false
            nonJavascriptAvailable = $false
            projects               = @{}
        }
    }

    $localProvider = $Providers['projects.local']
    if (-not (Test-ComparisonProviderHasComparableEvidence -Provider $localProvider)) {
        return [pscustomobject][ordered]@{
            available              = $false
            javascriptAvailable    = $false
            nonJavascriptAvailable = $false
            projects               = @{}
        }
    }

    $localEvidenceIndex = Get-ComparisonEvidenceIndex -Provider $localProvider -ProviderId 'projects.local' -Role $Role
    if (-not $localEvidenceIndex.ContainsKey('projects.local.discovery')) {
        return [pscustomobject][ordered]@{
            available              = $false
            javascriptAvailable    = $false
            nonJavascriptAvailable = $false
            projects               = @{}
        }
    }

    $discovery = $localEvidenceIndex['projects.local.discovery']
    $discoveryAttributes = Get-ComparisonOptionalPropertyValue -InputObject $discovery -Name 'attributes'
    $candidates = @((Get-ComparisonOptionalPropertyValue -InputObject $discoveryAttributes -Name 'candidates'))

    $javascriptProvider = if ($Providers.Contains('projects.javascript-web')) { $Providers['projects.javascript-web'] } else { $null }
    $nonJavaScriptProvider = if ($Providers.Contains('projects.non-javascript')) { $Providers['projects.non-javascript'] } else { $null }

    $javascriptState = Get-ComparisonProjectClassificationIndex -Provider $javascriptProvider -ProviderId 'projects.javascript-web' -SummaryEvidenceId 'projects.javascript-web.summary' -Role $Role
    $nonJavaScriptState = Get-ComparisonProjectClassificationIndex -Provider $nonJavaScriptProvider -ProviderId 'projects.non-javascript' -SummaryEvidenceId 'projects.non-javascript.summary' -Role $Role

    $rawCandidates = [System.Collections.Generic.List[object]]::new()
    $identityCounts = @{}

    for ($index = 0; $index -lt $candidates.Count; $index++) {
        $candidate = $candidates[$index]
        if ($null -eq $candidate) {
            continue
        }

        $path = [string](Get-ComparisonOptionalPropertyValue -InputObject $candidate -Name 'path')
        $relativePath = ConvertTo-ComparisonProjectRelativePath -RelativePath ([string](Get-ComparisonOptionalPropertyValue -InputObject $candidate -Name 'relativePath'))
        $name = Get-ComparisonProjectLeafName -Path $path -ProjectIndex $index
        $baseIdentity = "$name|$relativePath"

        if (-not $identityCounts.ContainsKey($baseIdentity)) {
            $identityCounts[$baseIdentity] = 0
        }
        $identityCounts[$baseIdentity]++

        $rootIndexes = @(
            @((Get-ComparisonOptionalPropertyValue -InputObject $candidate -Name 'rootIndexes')) |
                ForEach-Object { [int]$_ } |
                Sort-Object -Unique
        )

        $rawCandidates.Add([pscustomobject][ordered]@{
            projectIndex     = $index
            name             = $name
            relativePath     = $relativePath
            baseIdentity     = $baseIdentity
            rootIndexes      = $rootIndexes
            repositoryMarker = ((Get-ComparisonOptionalPropertyValue -InputObject $candidate -Name 'repositoryMarker') -eq $true)
        })
    }

    $projects = @{}
    foreach ($candidate in $rawCandidates) {
        $identity = [pscustomobject][ordered]@{
            name         = [string]$candidate.name
            relativePath = [string]$candidate.relativePath
        }

        if ([int]$identityCounts[[string]$candidate.baseIdentity] -gt 1) {
            $identity | Add-Member -NotePropertyName rootIndexes -NotePropertyValue @($candidate.rootIndexes)
        }

        $identityJson = ConvertTo-ComparisonCanonicalJson -Value $identity
        $subjectId = "project:$(Get-ComparisonValueHash -CanonicalJson $identityJson)"

        if ($projects.ContainsKey($subjectId)) {
            throw "$Role project comparison produced duplicate path-safe project identity '$subjectId'."
        }

        $javascriptProject = if ($javascriptState.projects.ContainsKey([int]$candidate.projectIndex)) {
            $javascriptState.projects[[int]$candidate.projectIndex]
        }
        else {
            $null
        }

        $nonJavaScriptProject = if ($nonJavaScriptState.projects.ContainsKey([int]$candidate.projectIndex)) {
            $nonJavaScriptState.projects[[int]$candidate.projectIndex]
        }
        else {
            $null
        }

        $projects[$subjectId] = [pscustomobject][ordered]@{
            subjectId             = $subjectId
            identity              = New-ComparisonProjectIdentityValue -Name ([string]$candidate.name) -RelativePath ([string]$candidate.relativePath)
            repositoryMarker      = [bool]$candidate.repositoryMarker
            javascriptProject     = $javascriptProject
            nonJavaScriptProject  = $nonJavaScriptProject
        }
    }

    return [pscustomobject][ordered]@{
        available              = $true
        javascriptAvailable    = [bool]$javascriptState.available
        nonJavascriptAvailable = [bool]$nonJavaScriptState.available
        projects               = $projects
    }
}

function Add-ComparisonProjectDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateNotNull()][System.Collections.IDictionary]$ReferenceProviders,
        [Parameter(Mandatory)][ValidateNotNull()][System.Collections.IDictionary]$TargetProviders
    )

    $referenceState = Get-ComparisonProjectReportState -Providers $ReferenceProviders -Role reference
    $targetState = Get-ComparisonProjectReportState -Providers $TargetProviders -Role target

    if (-not $referenceState.available -or -not $targetState.available) {
        return
    }

    $subjectIds = @(
        @($referenceState.projects.Keys) + @($targetState.projects.Keys) |
            Sort-Object -Unique
    )

    foreach ($subjectId in $subjectIds) {
        $referenceExists = $referenceState.projects.ContainsKey($subjectId)
        $targetExists = $targetState.projects.ContainsKey($subjectId)
        $referenceProject = if ($referenceExists) { $referenceState.projects[$subjectId] } else { $null }
        $targetProject = if ($targetExists) { $targetState.projects[$subjectId] } else { $null }

        if (-not ($referenceExists -and $targetExists)) {
            $relation = if ($referenceExists) { 'reference-only' } else { 'target-only' }
            $parameters = @{
                Category       = 'project'
                Kind           = 'presence'
                ProviderId     = 'projects.local'
                ComponentId    = $null
                SubjectId      = $subjectId
                Relation       = $relation
                ReferenceState = $(if ($referenceExists) { 'present' } else { 'missing' })
                TargetState    = $(if ($targetExists) { 'present' } else { 'missing' })
                ReferenceValue = $(if ($referenceExists) { $referenceProject.identity } else { $null })
                TargetValue    = $(if ($targetExists) { $targetProject.identity } else { $null })
            }
            $Differences.Add((New-ComparisonDifference @parameters))
            continue
        }

        $gitParameters = @{
            Differences    = $Differences
            Category       = 'project'
            Kind           = 'git-association'
            ProviderId     = 'projects.local'
            ComponentId    = $null
            SubjectId      = $subjectId
            ReferenceValue = [bool]$referenceProject.repositoryMarker
            TargetValue    = [bool]$targetProject.repositoryMarker
        }
        Add-ComparisonValueDifference @gitParameters

        if ($referenceState.javascriptAvailable -and
            $targetState.javascriptAvailable -and
            $referenceState.nonJavascriptAvailable -and
            $targetState.nonJavascriptAvailable) {

            $typeParameters = @{
                Differences    = $Differences
                Category       = 'project'
                Kind           = 'types'
                ProviderId     = 'projects.local'
                ComponentId    = $null
                SubjectId      = $subjectId
                ReferenceValue = @(ConvertTo-ComparisonProjectTypes -JavaScriptProject $referenceProject.javascriptProject -NonJavaScriptProject $referenceProject.nonJavaScriptProject)
                TargetValue    = @(ConvertTo-ComparisonProjectTypes -JavaScriptProject $targetProject.javascriptProject -NonJavaScriptProject $targetProject.nonJavaScriptProject)
            }
            Add-ComparisonValueDifference @typeParameters

            $constraintParameters = @{
                Differences    = $Differences
                Category       = 'project'
                Kind           = 'runtime-constraints'
                ProviderId     = 'projects.local'
                ComponentId    = $null
                SubjectId      = $subjectId
                ReferenceValue = @(ConvertTo-ComparisonProjectRuntimeConstraints -JavaScriptProject $referenceProject.javascriptProject -NonJavaScriptProject $referenceProject.nonJavaScriptProject)
                TargetValue    = @(ConvertTo-ComparisonProjectRuntimeConstraints -JavaScriptProject $targetProject.javascriptProject -NonJavaScriptProject $targetProject.nonJavaScriptProject)
            }
            Add-ComparisonValueDifference @constraintParameters
        }

        if ($referenceState.javascriptAvailable -and $targetState.javascriptAvailable) {
            $packageManagerParameters = @{
                Differences    = $Differences
                Category       = 'project'
                Kind           = 'package-manager'
                ProviderId     = 'projects.local'
                ComponentId    = $null
                SubjectId      = $subjectId
                ReferenceValue = ConvertTo-ComparisonProjectPackageManager -JavaScriptProject $referenceProject.javascriptProject
                TargetValue    = ConvertTo-ComparisonProjectPackageManager -JavaScriptProject $targetProject.javascriptProject
            }
            Add-ComparisonValueDifference @packageManagerParameters
        }
    }
}

function Add-ComparisonPathEnvironmentProviderDifferences {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Differences,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProviderId,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$ReferenceProvider,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$TargetProvider
    )

    switch ($ProviderId) {
        'environment.baseline' {
            Add-ComparisonEnvironmentBaselineDifferences -Differences $Differences -ReferenceProvider $ReferenceProvider -TargetProvider $TargetProvider
        }
        'path.precedence' {
            Add-ComparisonPathPrecedenceDifferences -Differences $Differences -ReferenceProvider $ReferenceProvider -TargetProvider $TargetProvider
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

    Add-ComparisonProjectDifferences -Differences $differences -ReferenceProviders $referenceProviders -TargetProviders $targetProviders

    foreach ($providerId in $providerIds) {
        $referenceExists = $referenceProviders.ContainsKey($providerId)
        $targetExists = $targetProviders.ContainsKey($providerId)
        $referenceProvider = if ($referenceExists) { $referenceProviders[$providerId] } else { $null }
        $targetProvider = if ($targetExists) { $targetProviders[$providerId] } else { $null }

        $referenceStatus = if ($referenceExists) { [string]$referenceProvider.status } else { $null }
        $targetStatus = if ($targetExists) { [string]$targetProvider.status } else { $null }

        $relationParameters = @{
            ReferenceExists = $referenceExists
            TargetExists    = $targetExists
            ReferenceState  = $referenceStatus
            TargetState     = $targetStatus
        }
        $providerRelation = Get-ComparisonRelation @relationParameters

        if ($providerRelation -ne 'equal') {
            $providerKind = if ($referenceExists -and $targetExists) { 'status' } else { 'presence' }
            $parameters = @{
                Category       = 'provider'
                Kind           = $providerKind
                ProviderId     = $providerId
                Relation       = $providerRelation
                ReferenceState = $referenceStatus
                TargetState    = $targetStatus
            }
            $differences.Add((New-ComparisonDifference @parameters))
        }

        if (-not ($referenceExists -and $targetExists)) {
            continue
        }

        $pathEnvironmentParameters = @{
            Differences       = $differences
            ProviderId        = $providerId
            ReferenceProvider = $referenceProvider
            TargetProvider    = $targetProvider
        }
        Add-ComparisonPathEnvironmentProviderDifferences @pathEnvironmentParameters

        if ($providerId -eq 'winget.baseline') {
            $applicationParameters = @{
                Differences       = $differences
                ReferenceProvider = $referenceProvider
                TargetProvider    = $targetProvider
            }
            Add-ComparisonWinGetApplicationDifferences @applicationParameters
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

            $relationParameters = @{
                ReferenceExists = $referenceComponentExists
                TargetExists    = $targetComponentExists
                ReferenceState  = $referenceState
                TargetState     = $targetState
            }
            $componentRelation = Get-ComparisonRelation @relationParameters

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
