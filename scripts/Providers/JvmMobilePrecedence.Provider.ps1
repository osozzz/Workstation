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
        providerId = 'jvm-mobile.precedence'
        category   = 'environment'
        order      = 32
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

function Get-PreviousProviderResult {
    param([Parameter(Mandatory)][string]$ProviderId)

    return @(
        $previousProviderResults |
            Where-Object { [string]$_.providerId -eq $ProviderId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Get-ProviderEvidence {
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    if ($null -eq $Provider) {
        return $null
    }

    return @(
        @($Provider.evidence) |
            Where-Object { [string]$_.evidenceId -eq $EvidenceId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Get-ProviderComponent {
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory)][string]$ComponentId
    )

    if ($null -eq $Provider) {
        return $null
    }

    return @(
        @($Provider.components) |
            Where-Object { [string]$_.componentId -eq $ComponentId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Get-CommandPrecedenceEvidence {
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory)][string]$Command
    )

    if ($null -eq $Provider) {
        return $null
    }

    return @(
        @($Provider.evidence) |
            Where-Object {
                [string]$_.evidenceId -like 'path-precedence.command.*' -and
                $null -ne $_.attributes -and
                [string]$_.attributes.command -eq $Command
            } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Get-EnvironmentPathState {
    param(
        [AllowNull()][object]$EnvironmentProvider,
        [AllowNull()][object]$ProcessPathEvidence,
        [Parameter(Mandatory)][string]$Name
    )

    $evidenceId = "environment.$($Name.ToLowerInvariant())"
    $variableEvidence = Get-ProviderEvidence -Provider $EnvironmentProvider -EvidenceId $evidenceId

    $result = [pscustomobject][ordered]@{
        name              = $Name
        evidenceId        = $evidenceId
        configured        = $false
        scope             = $null
        state             = 'unavailable'
        normalized        = $null
        comparisonKey     = $null
        exists            = $null
        invalid           = $false
        unresolved        = $false
        onProcessPath     = $false
        pathPositions     = @()
        firstPathPosition = $null
    }

    if ($null -eq $variableEvidence -or $null -eq $variableEvidence.attributes) {
        return $result
    }

    $scopes = @($variableEvidence.attributes.scopes)
    $selected = $null

    foreach ($scopeName in @('process', 'user', 'machine')) {
        $candidate = @(
            $scopes |
                Where-Object { [string]$_.scope -eq $scopeName } |
                Select-Object -First 1
        ) | Select-Object -First 1

        if ($null -eq $candidate) {
            continue
        }

        if ([string]$candidate.state -eq 'value' -and -not [bool]$candidate.isInvalid) {
            $selected = $candidate
            break
        }

        if ($null -eq $selected -and [bool]$candidate.isConfigured) {
            $selected = $candidate
        }
    }

    if ($null -eq $selected) {
        $result.state = 'unset'
        return $result
    }

    $result.configured = [bool]$selected.isConfigured
    $result.scope = [string]$selected.scope
    $result.state = [string]$selected.state
    $result.normalized = $selected.normalized
    $result.comparisonKey = $selected.comparisonKey
    $result.exists = $selected.exists
    $result.invalid = [bool]$selected.isInvalid
    $result.unresolved = [bool]$selected.hasUnresolvedVariable

    if (
        -not [string]::IsNullOrWhiteSpace([string]$result.comparisonKey) -and
        $null -ne $ProcessPathEvidence -and
        $null -ne $ProcessPathEvidence.attributes
    ) {
        $positions = @(
            @($ProcessPathEvidence.attributes.entries) |
                Where-Object {
                    [string]::Equals(
                        [string]$_.comparisonKey,
                        [string]$result.comparisonKey,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Sort-Object position |
                ForEach-Object { [int]$_.position }
        )

        $result.pathPositions = @($positions)
        $result.onProcessPath = ($positions.Count -gt 0)
        if ($positions.Count -gt 0) {
            $result.firstPathPosition = [int]$positions[0]
        }
    }

    return $result
}

function Get-ChildPathState {
    param(
        [AllowNull()][object]$RootState,
        [AllowNull()][object]$ProcessPathEvidence,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $result = [pscustomobject][ordered]@{
        rootName          = $(if ($RootState) { $RootState.name } else { $null })
        configured        = $(if ($RootState) { [bool]$RootState.configured } else { $false })
        scope             = $(if ($RootState) { $RootState.scope } else { $null })
        state             = $(if ($RootState) { $RootState.state } else { 'unavailable' })
        normalized        = $null
        comparisonKey     = $null
        exists            = $(if ($RootState) { $RootState.exists } else { $null })
        invalid           = $(if ($RootState) { [bool]$RootState.invalid } else { $false })
        unresolved        = $(if ($RootState) { [bool]$RootState.unresolved } else { $false })
        onProcessPath     = $false
        pathPositions     = @()
        firstPathPosition = $null
    }

    if (
        $null -eq $RootState -or
        -not $RootState.configured -or
        $RootState.invalid -or
        $RootState.unresolved -or
        [string]::IsNullOrWhiteSpace([string]$RootState.normalized) -or
        [string]::IsNullOrWhiteSpace([string]$RootState.comparisonKey)
    ) {
        return $result
    }

    $suffix = $RelativePath.Trim('\', '/')
    $normalizedRoot = ([string]$RootState.normalized).TrimEnd('\', '/')
    $comparisonRoot = ([string]$RootState.comparisonKey).TrimEnd('\', '/')
    $normalizedSuffix = ($suffix -replace '/', '\')
    $comparisonSuffix = $normalizedSuffix.ToLowerInvariant()

    $result.normalized = "$normalizedRoot\$normalizedSuffix"
    $result.comparisonKey = "$comparisonRoot\$comparisonSuffix"

    if ($null -ne $ProcessPathEvidence -and $null -ne $ProcessPathEvidence.attributes) {
        $positions = @(
            @($ProcessPathEvidence.attributes.entries) |
                Where-Object {
                    [string]::Equals(
                        [string]$_.comparisonKey,
                        [string]$result.comparisonKey,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Sort-Object position |
                ForEach-Object { [int]$_.position }
        )

        $result.pathPositions = @($positions)
        $result.onProcessPath = ($positions.Count -gt 0)
        if ($positions.Count -gt 0) {
            $result.firstPathPosition = [int]$positions[0]
        }
    }

    return $result
}

function Get-CommandRelationship {
    param(
        [AllowNull()][object]$PathProvider,
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][object]$ExpectedPathState
    )

    $commandEvidence = Get-CommandPrecedenceEvidence -Provider $PathProvider -Command $Command

    $result = [pscustomobject][ordered]@{
        command                    = $Command
        evidenceId                 = $(if ($commandEvidence) { [string]$commandEvidence.evidenceId } else { $null })
        available                  = ($null -ne $commandEvidence)
        resolutionCount            = 0
        hasPathResolutionCollision = $false
        activePath                 = $null
        activePathDirectory        = $null
        activePathComparisonKey    = $null
        activePathPosition         = $null
        activePathMappingStatus    = $null
        activePathBased            = $false
        shadowedResolutions        = @()
        expectedPath               = $(if ($ExpectedPathState) { $ExpectedPathState.normalized } else { $null })
        expectedPathPosition       = $(if ($ExpectedPathState) { $ExpectedPathState.firstPathPosition } else { $null })
        expectedPathOnProcessPath  = $(if ($ExpectedPathState) { [bool]$ExpectedPathState.onProcessPath } else { $false })
        relationship               = 'not-configured'
    }

    if ($null -eq $commandEvidence -or $null -eq $commandEvidence.attributes) {
        $result.relationship = 'command-analysis-unavailable'
        return $result
    }

    $attributes = $commandEvidence.attributes
    $result.resolutionCount = [int]$attributes.resolutionCount
    $result.hasPathResolutionCollision = [bool]$attributes.hasPathResolutionCollision
    $result.shadowedResolutions = @($attributes.shadowedResolutions)

    $active = $attributes.activeResolution
    if ($null -eq $active) {
        $result.relationship = 'no-active-resolution'
        return $result
    }

    $result.activePath = $active.path
    $result.activePathDirectory = $active.pathDirectory
    $result.activePathComparisonKey = $active.pathComparisonKey
    $result.activePathPosition = $active.pathPosition
    $result.activePathMappingStatus = $active.pathMappingStatus
    $result.activePathBased = [bool]$active.pathBased

    if ($null -eq $ExpectedPathState -or -not $ExpectedPathState.configured) {
        $result.relationship = 'not-configured'
        return $result
    }

    if (
        [string]::IsNullOrWhiteSpace([string]$ExpectedPathState.comparisonKey) -or
        $ExpectedPathState.invalid -or
        $ExpectedPathState.unresolved
    ) {
        $result.relationship = 'expected-path-unusable'
        return $result
    }

    if (-not $result.activePathBased) {
        $result.relationship = 'active-resolution-not-path-based'
        return $result
    }

    if ([string]::IsNullOrWhiteSpace([string]$result.activePathComparisonKey)) {
        $result.relationship = 'active-origin-unproven'
        return $result
    }

    if (
        [string]::Equals(
            [string]$result.activePathComparisonKey,
            [string]$ExpectedPathState.comparisonKey,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $result.relationship = 'aligned'
    }
    else {
        $result.relationship = 'mismatch'
    }

    return $result
}

function Format-PathPosition {
    param([AllowNull()][object]$Position)

    if ($null -eq $Position) {
        return 'PATH[unknown]'
    }

    return "PATH[$Position]"
}

function Add-CommandCollisionFinding {
    param(
        [Parameter(Mandatory)][object]$Relationship,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    if (-not $Relationship.available -or -not $Relationship.hasPathResolutionCollision) {
        return
    }

    $shadowedText = @(
        @($Relationship.shadowedResolutions) |
            Where-Object { [bool]$_.pathBased } |
            ForEach-Object {
                "'$($_.path)' at $(Format-PathPosition -Position $_.pathPosition)"
            }
    ) -join '; '

    $warnings.Add((New-AuditIssue -Code $Code -Message "Command '$($Relationship.command)' resolves actively to '$($Relationship.activePath)' at $(Format-PathPosition -Position $Relationship.activePathPosition) and shadows: $shadowedText." -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
}

function Get-AdbRootRelationship {
    param(
        [Parameter(Mandatory)][object]$AdbRelationship,
        [Parameter(Mandatory)][object]$AndroidHomePlatformTools,
        [Parameter(Mandatory)][object]$AndroidSdkRootPlatformTools
    )

    $result = [pscustomobject][ordered]@{
        relationship         = 'not-configured'
        matchedRoot          = $null
        activePath           = $AdbRelationship.activePath
        activePathPosition   = $AdbRelationship.activePathPosition
        androidHomeExpected  = $AndroidHomePlatformTools.normalized
        androidHomePosition  = $AndroidHomePlatformTools.firstPathPosition
        sdkRootExpected      = $AndroidSdkRootPlatformTools.normalized
        sdkRootPosition      = $AndroidSdkRootPlatformTools.firstPathPosition
    }

    $homeUsable = (
        $AndroidHomePlatformTools.configured -and
        -not [string]::IsNullOrWhiteSpace([string]$AndroidHomePlatformTools.comparisonKey)
    )
    $sdkUsable = (
        $AndroidSdkRootPlatformTools.configured -and
        -not [string]::IsNullOrWhiteSpace([string]$AndroidSdkRootPlatformTools.comparisonKey)
    )

    if (-not $homeUsable -and -not $sdkUsable) {
        return $result
    }

    if (
        -not $AdbRelationship.activePathBased -or
        [string]::IsNullOrWhiteSpace([string]$AdbRelationship.activePathComparisonKey)
    ) {
        $result.relationship = 'active-origin-unproven'
        return $result
    }

    $matchesHome = $homeUsable -and [string]::Equals(
        [string]$AdbRelationship.activePathComparisonKey,
        [string]$AndroidHomePlatformTools.comparisonKey,
        [StringComparison]::OrdinalIgnoreCase
    )
    $matchesSdk = $sdkUsable -and [string]::Equals(
        [string]$AdbRelationship.activePathComparisonKey,
        [string]$AndroidSdkRootPlatformTools.comparisonKey,
        [StringComparison]::OrdinalIgnoreCase
    )

    if ($matchesHome -and $matchesSdk) {
        $result.relationship = 'aligned'
        $result.matchedRoot = 'both'
    }
    elseif ($matchesHome) {
        $result.relationship = 'aligned-android-home'
        $result.matchedRoot = 'ANDROID_HOME'
    }
    elseif ($matchesSdk) {
        $result.relationship = 'aligned-android-sdk-root'
        $result.matchedRoot = 'ANDROID_SDK_ROOT'
    }
    else {
        $result.relationship = 'mismatch'
    }

    return $result
}

$javaProvider = Get-PreviousProviderResult -ProviderId 'java.jvm'
$mobileProvider = Get-PreviousProviderResult -ProviderId 'mobile.flutter-android'
$pathProvider = Get-PreviousProviderResult -ProviderId 'path.precedence'
$environmentProvider = Get-PreviousProviderResult -ProviderId 'environment.baseline'

$dependencyStates = [ordered]@{
    javaJvm              = ($null -ne $javaProvider)
    mobileFlutterAndroid = ($null -ne $mobileProvider)
    pathPrecedence       = ($null -ne $pathProvider)
    environmentBaseline  = ($null -ne $environmentProvider)
}

foreach ($dependencyName in @($dependencyStates.Keys)) {
    if (-not [bool]$dependencyStates[$dependencyName]) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'JVM_MOBILE_PRECEDENCE_DEPENDENCY_MISSING' -Message "JVM/mobile precedence analysis could not find required prior provider '$dependencyName'." -Severity warning -EvidenceIds @('jvm-mobile-precedence.summary')))
    }
}

foreach ($dependency in @($javaProvider, $mobileProvider, $pathProvider, $environmentProvider)) {
    if ($null -ne $dependency -and [string]$dependency.status -eq 'failed') {
        $hasPartial = $true
    }
}

$processPathEvidence = Get-ProviderEvidence -Provider $environmentProvider -EvidenceId 'path.process.health'

$javaHome = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -ProcessPathEvidence $processPathEvidence -Name 'JAVA_HOME'
$flutterRoot = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -ProcessPathEvidence $processPathEvidence -Name 'FLUTTER_ROOT'
$androidHome = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -ProcessPathEvidence $processPathEvidence -Name 'ANDROID_HOME'
$androidSdkRoot = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -ProcessPathEvidence $processPathEvidence -Name 'ANDROID_SDK_ROOT'
$pubCache = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -ProcessPathEvidence $processPathEvidence -Name 'PUB_CACHE'

$javaBin = Get-ChildPathState -RootState $javaHome -ProcessPathEvidence $processPathEvidence -RelativePath 'bin'
$flutterBin = Get-ChildPathState -RootState $flutterRoot -ProcessPathEvidence $processPathEvidence -RelativePath 'bin'
$androidHomePlatformTools = Get-ChildPathState -RootState $androidHome -ProcessPathEvidence $processPathEvidence -RelativePath 'platform-tools'
$androidSdkRootPlatformTools = Get-ChildPathState -RootState $androidSdkRoot -ProcessPathEvidence $processPathEvidence -RelativePath 'platform-tools'

$javaComponent = Get-ProviderComponent -Provider $javaProvider -ComponentId 'java'
$javacComponent = Get-ProviderComponent -Provider $javaProvider -ComponentId 'javac'
$flutterComponent = Get-ProviderComponent -Provider $mobileProvider -ComponentId 'flutter'
$dartComponent = Get-ProviderComponent -Provider $mobileProvider -ComponentId 'dart'
$androidSdkComponent = Get-ProviderComponent -Provider $mobileProvider -ComponentId 'android-sdk'
$adbComponent = Get-ProviderComponent -Provider $mobileProvider -ComponentId 'adb'

$javaPresent = ($null -ne $javaComponent -and [string]$javaComponent.state -in @('present', 'partial'))
$javacPresent = ($null -ne $javacComponent -and [string]$javacComponent.state -in @('present', 'partial'))
$flutterPresent = ($null -ne $flutterComponent -and [string]$flutterComponent.state -in @('present', 'partial'))
$dartPresent = ($null -ne $dartComponent -and [string]$dartComponent.state -in @('present', 'partial'))
$androidSdkPresent = ($null -ne $androidSdkComponent -and [string]$androidSdkComponent.state -in @('present', 'partial'))
$adbPresent = ($null -ne $adbComponent -and [string]$adbComponent.state -in @('present', 'partial'))

$javaRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'java' -ExpectedPathState $javaBin
$javacRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'javac' -ExpectedPathState $javaBin
$flutterRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'flutter' -ExpectedPathState $flutterBin
$dartRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'dart' -ExpectedPathState $flutterBin
$adbRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'adb' -ExpectedPathState $androidHomePlatformTools

$mobileDartEvidence = Get-ProviderEvidence -Provider $mobileProvider -EvidenceId 'mobile.dart.relationship'
$mobileAndroidMetadata = Get-ProviderEvidence -Provider $mobileProvider -EvidenceId 'mobile.android-sdk.metadata'
$activeDartSource = if ($mobileDartEvidence -and $mobileDartEvidence.attributes) {
    [string]$mobileDartEvidence.attributes.activeSource
}
else {
    $null
}
$activeBundledFlutterRoot = if ($mobileDartEvidence -and $mobileDartEvidence.attributes) {
    $mobileDartEvidence.attributes.activeBundledFlutterRoot
}
else {
    $null
}
$androidMetadataRootCount = if ($mobileAndroidMetadata -and $mobileAndroidMetadata.attributes) {
    @($mobileAndroidMetadata.attributes.roots).Count
}
else {
    0
}

$androidRootsComparable = (
    $androidHome.configured -and
    $androidSdkRoot.configured -and
    -not $androidHome.invalid -and
    -not $androidSdkRoot.invalid -and
    -not $androidHome.unresolved -and
    -not $androidSdkRoot.unresolved -and
    -not [string]::IsNullOrWhiteSpace([string]$androidHome.comparisonKey) -and
    -not [string]::IsNullOrWhiteSpace([string]$androidSdkRoot.comparisonKey)
)

$androidRootsAgree = $null
if ($androidRootsComparable) {
    $androidRootsAgree = [string]::Equals(
        [string]$androidHome.comparisonKey,
        [string]$androidSdkRoot.comparisonKey,
        [StringComparison]::OrdinalIgnoreCase
    )
}

$environmentEvidenceId = 'jvm-mobile-precedence.environment'
$evidence.Add((New-AuditEvidence -EvidenceId $environmentEvidenceId -Type derived -Source 'JVM/mobile environment and PATH relationships' -Captured $null -Attributes @{
    javaHome = $javaHome
    javaBin = $javaBin
    flutterRoot = $flutterRoot
    flutterBin = $flutterBin
    androidHome = $androidHome
    androidSdkRoot = $androidSdkRoot
    androidHomePlatformTools = $androidHomePlatformTools
    androidSdkRootPlatformTools = $androidSdkRootPlatformTools
    androidRootsComparable = $androidRootsComparable
    androidRootsAgree = $androidRootsAgree
    pubCache = $pubCache
    pubCachePathRequired = $false
    androidMetadataRootCount = $androidMetadataRootCount
}))

$javaEvidenceId = 'jvm-mobile-precedence.command.java'
$evidence.Add((New-AuditEvidence -EvidenceId $javaEvidenceId -Type derived -Source 'JAVA_HOME and java PATH precedence' -Captured $null -Attributes @{
    componentPresent = $javaPresent
    relationship = $javaRelationship
}))
$javacEvidenceId = 'jvm-mobile-precedence.command.javac'
$evidence.Add((New-AuditEvidence -EvidenceId $javacEvidenceId -Type derived -Source 'JAVA_HOME and javac PATH precedence' -Captured $null -Attributes @{
    componentPresent = $javacPresent
    relationship = $javacRelationship
}))
$flutterEvidenceId = 'jvm-mobile-precedence.command.flutter'
$evidence.Add((New-AuditEvidence -EvidenceId $flutterEvidenceId -Type derived -Source 'FLUTTER_ROOT and flutter PATH precedence' -Captured $null -Attributes @{
    componentPresent = $flutterPresent
    relationship = $flutterRelationship
}))
$dartEvidenceId = 'jvm-mobile-precedence.command.dart'
$evidence.Add((New-AuditEvidence -EvidenceId $dartEvidenceId -Type derived -Source 'Flutter-bundled versus standalone Dart PATH precedence' -Captured $null -Attributes @{
    componentPresent = $dartPresent
    activeSource = $activeDartSource
    activeBundledFlutterRoot = $activeBundledFlutterRoot
    relationship = $dartRelationship
}))
$adbEvidenceId = 'jvm-mobile-precedence.command.adb'
$adbRootRelationship = Get-AdbRootRelationship -AdbRelationship $adbRelationship -AndroidHomePlatformTools $androidHomePlatformTools -AndroidSdkRootPlatformTools $androidSdkRootPlatformTools
$evidence.Add((New-AuditEvidence -EvidenceId $adbEvidenceId -Type derived -Source 'Android SDK roots and adb PATH precedence' -Captured $null -Attributes @{
    componentPresent = $adbPresent
    sdkComponentPresent = $androidSdkPresent
    relationship = $adbRelationship
    rootRelationship = $adbRootRelationship
}))

Add-CommandCollisionFinding -Relationship $javaRelationship -Code 'JAVA_PATH_COLLISION' -ComponentId 'java' -EvidenceId $javaEvidenceId
Add-CommandCollisionFinding -Relationship $javacRelationship -Code 'JAVAC_PATH_COLLISION' -ComponentId 'javac' -EvidenceId $javacEvidenceId
Add-CommandCollisionFinding -Relationship $flutterRelationship -Code 'FLUTTER_PATH_COLLISION' -ComponentId 'flutter' -EvidenceId $flutterEvidenceId
Add-CommandCollisionFinding -Relationship $dartRelationship -Code 'DART_PATH_COLLISION' -ComponentId 'dart' -EvidenceId $dartEvidenceId
Add-CommandCollisionFinding -Relationship $adbRelationship -Code 'ADB_PATH_COLLISION' -ComponentId 'adb' -EvidenceId $adbEvidenceId

if (
    $javaPresent -and
    $javaHome.configured -and
    $javaRelationship.relationship -eq 'mismatch' -and
    [string]$javaRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'JAVA_HOME_JAVA_PRECEDENCE_MISMATCH' -Message "JAVA_HOME expects java under '$($javaBin.normalized)' at $(Format-PathPosition -Position $javaBin.firstPathPosition), but active java resolves to '$($javaRelationship.activePath)' at $(Format-PathPosition -Position $javaRelationship.activePathPosition)." -Severity warning -ComponentId 'java' -EvidenceIds @($environmentEvidenceId, $javaEvidenceId)))
}

if (
    $javacPresent -and
    $javaHome.configured -and
    $javacRelationship.relationship -eq 'mismatch' -and
    [string]$javacRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'JAVA_HOME_JAVAC_PRECEDENCE_MISMATCH' -Message "JAVA_HOME expects javac under '$($javaBin.normalized)' at $(Format-PathPosition -Position $javaBin.firstPathPosition), but active javac resolves to '$($javacRelationship.activePath)' at $(Format-PathPosition -Position $javacRelationship.activePathPosition)." -Severity warning -ComponentId 'javac' -EvidenceIds @($environmentEvidenceId, $javacEvidenceId)))
}

if (
    $flutterPresent -and
    $flutterRoot.configured -and
    $flutterRelationship.relationship -eq 'mismatch' -and
    [string]$flutterRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'FLUTTER_ROOT_PRECEDENCE_MISMATCH' -Message "FLUTTER_ROOT expects flutter under '$($flutterBin.normalized)' at $(Format-PathPosition -Position $flutterBin.firstPathPosition), but active flutter resolves to '$($flutterRelationship.activePath)' at $(Format-PathPosition -Position $flutterRelationship.activePathPosition)." -Severity warning -ComponentId 'flutter' -EvidenceIds @($environmentEvidenceId, $flutterEvidenceId)))
}

if (
    $flutterPresent -and
    $dartPresent -and
    [string]$activeDartSource -eq 'standalone' -and
    $dartRelationship.activePathBased -and
    [string]$dartRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'DART_STANDALONE_SHADOWS_FLUTTER' -Message "Flutter is present, but active Dart resolves to standalone path '$($dartRelationship.activePath)' at $(Format-PathPosition -Position $dartRelationship.activePathPosition) instead of Flutter-bundled Dart under '$($flutterRoot.normalized)'." -Severity warning -ComponentId 'dart' -EvidenceIds @($environmentEvidenceId, $dartEvidenceId)))
}

if ($androidRootsComparable -and $androidRootsAgree -eq $false) {
    $warnings.Add((New-AuditIssue -Code 'ANDROID_SDK_ROOT_DISAGREEMENT' -Message "ANDROID_HOME points to '$($androidHome.normalized)' while ANDROID_SDK_ROOT points to '$($androidSdkRoot.normalized)'." -Severity warning -ComponentId 'android-sdk' -EvidenceIds @($environmentEvidenceId, $adbEvidenceId)))
}

$singleAndroidRoot = $null
if (
    $androidHome.configured -and
    -not $androidHome.invalid -and
    -not $androidHome.unresolved -and
    (
        -not $androidSdkRoot.configured -or
        ($androidRootsComparable -and $androidRootsAgree -eq $true)
    )
) {
    $singleAndroidRoot = $androidHomePlatformTools
}
elseif (
    $androidSdkRoot.configured -and
    -not $androidSdkRoot.invalid -and
    -not $androidSdkRoot.unresolved -and
    -not $androidHome.configured
) {
    $singleAndroidRoot = $androidSdkRootPlatformTools
}

if (
    $adbPresent -and
    $null -ne $singleAndroidRoot -and
    $adbRelationship.activePathBased -and
    -not [string]::IsNullOrWhiteSpace([string]$adbRelationship.activePathComparisonKey) -and
    -not [string]::Equals(
        [string]$adbRelationship.activePathComparisonKey,
        [string]$singleAndroidRoot.comparisonKey,
        [StringComparison]::OrdinalIgnoreCase
    ) -and
    [string]$adbRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'ADB_SDK_ROOT_PRECEDENCE_MISMATCH' -Message "Configured Android SDK expects adb under '$($singleAndroidRoot.normalized)' at $(Format-PathPosition -Position $singleAndroidRoot.firstPathPosition), but active adb resolves to '$($adbRelationship.activePath)' at $(Format-PathPosition -Position $adbRelationship.activePathPosition)." -Severity warning -ComponentId 'adb' -EvidenceIds @($environmentEvidenceId, $adbEvidenceId)))
}

if (
    $adbPresent -and
    $androidRootsComparable -and
    $androidRootsAgree -eq $false -and
    $adbRootRelationship.relationship -eq 'mismatch' -and
    [string]$adbRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'ADB_OUTSIDE_CONFIGURED_SDK_ROOTS' -Message "Active adb resolves to '$($adbRelationship.activePath)' at $(Format-PathPosition -Position $adbRelationship.activePathPosition), outside both configured Android SDK roots." -Severity warning -ComponentId 'adb' -EvidenceIds @($environmentEvidenceId, $adbEvidenceId)))
}

$summaryEvidenceId = 'jvm-mobile-precedence.summary'
$evidence.Insert(0, (New-AuditEvidence -EvidenceId $summaryEvidenceId -Type derived -Source 'JVM/mobile PATH and environment precedence summary' -Captured $null -Attributes @{
    dependencies = [pscustomobject]$dependencyStates
    javaPresent = $javaPresent
    javacPresent = $javacPresent
    flutterPresent = $flutterPresent
    dartPresent = $dartPresent
    androidSdkPresent = $androidSdkPresent
    adbPresent = $adbPresent
    javaHomeConfigured = $javaHome.configured
    flutterRootConfigured = $flutterRoot.configured
    androidHomeConfigured = $androidHome.configured
    androidSdkRootConfigured = $androidSdkRoot.configured
    pubCacheConfigured = $pubCache.configured
    javaRelationship = $javaRelationship.relationship
    javacRelationship = $javacRelationship.relationship
    flutterRelationship = $flutterRelationship.relationship
    dartActiveSource = $activeDartSource
    adbRootRelationship = $adbRootRelationship.relationship
    warningCount = $warnings.Count
    readOnly = $true
    duplicatedRuntimeDiscovery = $false
    directEnvironmentAccess = $false
    filesystemProbes = $false
}))

$status = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial

return [pscustomobject][ordered]@{
    providerId = 'jvm-mobile.precedence'
    category   = 'environment'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
