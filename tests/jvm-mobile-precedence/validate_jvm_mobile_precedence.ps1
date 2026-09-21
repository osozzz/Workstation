[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$providerPath = Join-Path $root 'scripts\Providers\JvmMobilePrecedence.Provider.ps1'
$javaProviderPath = Join-Path $root 'scripts\Providers\JavaJvmToolchain.Provider.ps1'
$mobileProviderPath = Join-Path $root 'scripts\Providers\FlutterAndroidToolchain.Provider.ps1'
$pathProviderPath = Join-Path $root 'scripts\Providers\PathPrecedence.Provider.ps1'
$environmentProviderPath = Join-Path $root 'scripts\Providers\EnvironmentBaseline.Provider.ps1'
$javascriptPrecedenceProviderPath = Join-Path $root 'scripts\Providers\JavaScriptPrecedence.Provider.ps1'
$fixturePath = Join-Path $PSScriptRoot 'jvm-mobile-precedence-cases.json'

Import-Module $corePath -Force
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

function Get-OptionalPropertyValue {
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

function New-UnsetScopeValue {
    param([Parameter(Mandatory)][string]$Scope)

    return [pscustomobject][ordered]@{
        scope = $Scope
        state = 'unset'
        raw = $null
        expanded = $null
        normalized = $null
        comparisonKey = $null
        exists = $null
        pathItems = @()
        missingPathCount = 0
        hasUnresolvedVariable = $false
        unresolvedVariables = @()
        unapprovedReferenceCount = 0
        isConfigured = $false
        isInvalid = $false
    }
}

function New-EnvironmentVariableEvidence {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Definition
    )

    $processScope = New-UnsetScopeValue -Scope 'process'

    if ($null -ne $Definition) {
        $value = [string](Get-OptionalPropertyValue -InputObject $Definition -Name 'value')
        $existsValue = Get-OptionalPropertyValue -InputObject $Definition -Name 'exists'
        $entry = ConvertTo-AuditPathEntry -Scope process -Position 0 -Entry $value -EnvironmentValues @{}

        $processScope = [pscustomobject][ordered]@{
            scope = 'process'
            state = 'value'
            raw = $value
            expanded = $entry.expanded
            normalized = $entry.normalized
            comparisonKey = $entry.comparisonKey
            exists = $(if ($null -eq $existsValue) { $null } else { [bool]$existsValue })
            pathItems = @($entry)
            missingPathCount = $(if ($existsValue -eq $false) { 1 } else { 0 })
            hasUnresolvedVariable = $false
            unresolvedVariables = @()
            unapprovedReferenceCount = 0
            isConfigured = $true
            isInvalid = $false
        }
    }

    return New-AuditEvidence -EvidenceId "environment.$($Name.ToLowerInvariant())" -Type environment -Source $Name -Captured $null -Attributes @{
        scopes = @(
            $processScope,
            (New-UnsetScopeValue -Scope 'user'),
            (New-UnsetScopeValue -Scope 'machine')
        )
    }
}

function New-SyntheticEnvironmentProvider {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][object]$PathModel
    )

    $environmentEvidence = [System.Collections.Generic.List[object]]::new()

    foreach ($name in @('JAVA_HOME', 'FLUTTER_ROOT', 'PUB_CACHE', 'ANDROID_HOME', 'ANDROID_SDK_ROOT')) {
        $definition = Get-OptionalPropertyValue -InputObject $Case.environment -Name $name
        $environmentEvidence.Add((New-EnvironmentVariableEvidence -Name $name -Definition $definition))
    }

    $environmentEvidence.Add((New-AuditEvidence -EvidenceId 'path.process.health' -Type path -Source 'process PATH' -Captured $null -Attributes @{
        entryCount = $PathModel.entryCount
        duplicateCount = $PathModel.duplicateCount
        missingCount = $PathModel.missingCount
        unresolvedVariableCount = $PathModel.unresolvedVariableCount
        entries = $PathModel.entries
    }))

    return [pscustomobject][ordered]@{
        providerId = 'environment.baseline'
        category = 'environment'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @()
        warnings = @()
        errors = @()
        evidence = $environmentEvidence.ToArray()
    }
}

function Get-CaseCommandResolutions {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][string]$Command
    )

    $value = Get-OptionalPropertyValue -InputObject $Case.resolutions -Name $Command
    if ($null -eq $value) {
        return @()
    }

    return @($value)
}

function New-SyntheticJavaProvider {
    param([Parameter(Mandatory)][object]$Case)

    $components = [System.Collections.Generic.List[object]]::new()

    foreach ($componentId in @('java', 'javac')) {
        $stateValue = Get-OptionalPropertyValue -InputObject $Case.components -Name $componentId
        $components.Add([pscustomobject][ordered]@{
            componentId = $componentId
            state = $(if ($null -eq $stateValue) { 'missing' } else { [string]$stateValue })
            commandResolutions = @(Get-CaseCommandResolutions -Case $Case -Command $componentId)
        })
    }

    return [pscustomobject][ordered]@{
        providerId = 'java.jvm'
        category = 'runtime'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = $components.ToArray()
        warnings = @()
        errors = @()
        evidence = @()
    }
}

function New-SyntheticMobileProvider {
    param([Parameter(Mandatory)][object]$Case)

    $components = [System.Collections.Generic.List[object]]::new()

    foreach ($componentId in @('flutter', 'dart', 'android-sdk', 'adb')) {
        $stateValue = Get-OptionalPropertyValue -InputObject $Case.components -Name $componentId
        $command = switch ($componentId) {
            'android-sdk' { $null }
            default { $componentId }
        }

        $components.Add([pscustomobject][ordered]@{
            componentId = $componentId
            state = $(if ($null -eq $stateValue) { 'missing' } else { [string]$stateValue })
            commandResolutions = $(if ($null -eq $command) { @() } else { @(Get-CaseCommandResolutions -Case $Case -Command $command) })
        })
    }

    $mobileEvidence = [System.Collections.Generic.List[object]]::new()
    $dartRelationship = Get-OptionalPropertyValue -InputObject $Case -Name 'dartRelationship'

    if ($null -ne $dartRelationship) {
        $mobileEvidence.Add((New-AuditEvidence -EvidenceId 'mobile.dart.relationship' -Type derived -Source 'synthetic Flutter-bundled versus standalone Dart classification' -Captured $null -Attributes @{
            activeSource = $dartRelationship.activeSource
            activeBundledFlutterRoot = $dartRelationship.activeBundledFlutterRoot
            bundledInstallationCount = $dartRelationship.bundledInstallationCount
        }))
    }

    $androidRoots = [System.Collections.Generic.List[object]]::new()
    foreach ($spec in @(
        [pscustomobject]@{ Name = 'ANDROID_HOME'; Source = 'ANDROID_HOME' },
        [pscustomobject]@{ Name = 'ANDROID_SDK_ROOT'; Source = 'ANDROID_SDK_ROOT' }
    )) {
        $definition = Get-OptionalPropertyValue -InputObject $Case.environment -Name $spec.Name
        if ($null -eq $definition) {
            continue
        }

        $androidRoots.Add([pscustomobject][ordered]@{
            path = [string]$definition.value
            sources = @($spec.Source)
            components = @()
            adbPresent = ([string](Get-OptionalPropertyValue -InputObject $Case.components -Name 'adb') -in @('present', 'partial'))
        })
    }

    $mobileEvidence.Add((New-AuditEvidence -EvidenceId 'mobile.android-sdk.metadata' -Type derived -Source 'synthetic bounded Android SDK root metadata' -Captured $null -Attributes @{
        roots = $androidRoots.ToArray()
    }))

    return [pscustomobject][ordered]@{
        providerId = 'mobile.flutter-android'
        category = 'runtime'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = $components.ToArray()
        warnings = @()
        errors = @()
        evidence = $mobileEvidence.ToArray()
    }
}

function New-SyntheticPathProvider {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][object]$PathModel
    )

    $pathEvidence = [System.Collections.Generic.List[object]]::new()

    foreach ($commandProperty in @($Case.resolutions.PSObject.Properties)) {
        $command = [string]$commandProperty.Name
        $resolutions = @($commandProperty.Value)
        if ($resolutions.Count -eq 0) {
            continue
        }

        $analysis = Get-AuditCommandPathAnalysis -CommandResolutions $resolutions -ProcessPathEntries @($PathModel.entries)

        $pathEvidence.Add((New-AuditEvidence -EvidenceId "path-precedence.command.$command" -Type derived -Source "synthetic command PATH precedence: $command" -Captured $null -Attributes @{
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
        }))
    }

    return [pscustomobject][ordered]@{
        providerId = 'path.precedence'
        category = 'environment'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @()
        warnings = @()
        errors = @()
        evidence = $pathEvidence.ToArray()
    }
}

function Get-EvidenceById {
    param(
        [Parameter(Mandatory)][object]$ProviderResult,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    return @(
        @($ProviderResult.evidence) |
            Where-Object { [string]$_.evidenceId -eq $EvidenceId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

$providerDescription = & $providerPath -Describe
$javaDescription = & $javaProviderPath -Describe
$mobileDescription = & $mobileProviderPath -Describe
$pathDescription = & $pathProviderPath -Describe
$environmentDescription = & $environmentProviderPath -Describe
$javascriptPrecedenceDescription = & $javascriptPrecedenceProviderPath -Describe

if ($providerDescription.providerId -ne 'jvm-mobile.precedence') {
    throw 'JVM/mobile precedence provider id changed unexpectedly.'
}

foreach ($dependencyDescription in @(
    $javaDescription,
    $mobileDescription,
    $pathDescription,
    $environmentDescription,
    $javascriptPrecedenceDescription
)) {
    if ([int]$providerDescription.order -le [int]$dependencyDescription.order) {
        throw "JVM/mobile precedence provider must run after '$($dependencyDescription.providerId)'."
    }
}

$providerSource = Get-Content -LiteralPath $providerPath -Raw
foreach ($forbiddenPattern in @(
    '(?i)\bGet-Command\b',
    '(?i)\bInvoke-AuditCommand\b',
    '(?i)GetEnvironmentVariable',
    '(?i)SetEnvironmentVariable',
    '(?i)\bTest-Path\b',
    '(?i)\bflutter\s+(upgrade|precache|install)\b',
    '(?i)\bflutter\s+doctor\s+--android-licenses\b',
    '(?i)\bsdkmanager\b.*--licenses',
    '(?i)\bsdkmanager\b.*--install',
    '(?i)\bavdmanager\b.*\bcreate\b'
)) {
    if ($providerSource -match $forbiddenPattern) {
        throw "JVM/mobile precedence provider contains forbidden discovery/mutation pattern: $forbiddenPattern"
    }
}

$results = @{}

foreach ($caseProperty in @($fixture.cases.PSObject.Properties)) {
    $caseName = [string]$caseProperty.Name
    $case = $caseProperty.Value

    $pathModel = Get-AuditPathScopeModel -Scope process -RawPath ([string]$case.processPath)
    $javaProvider = New-SyntheticJavaProvider -Case $case
    $mobileProvider = New-SyntheticMobileProvider -Case $case
    $pathProvider = New-SyntheticPathProvider -Case $case -PathModel $pathModel
    $environmentProvider = New-SyntheticEnvironmentProvider -Case $case -PathModel $pathModel

    $context = [pscustomobject][ordered]@{
        ObservedAt = '2026-09-21T00:00:00Z'
        PreviousProviderResults = @(
            $javaProvider,
            $mobileProvider,
            $pathProvider,
            $environmentProvider
        )
    }

    $result = & $providerPath -Context $context
    $results[$caseName] = $result

    if ($result.providerId -ne 'jvm-mobile.precedence') {
        throw "$caseName returned unexpected provider id '$($result.providerId)'."
    }

    if (@($result.components).Count -ne 0) {
        throw ("{0}: derived JVM/mobile precedence provider must own zero components." -f $caseName)
    }

    $summary = Get-EvidenceById -ProviderResult $result -EvidenceId 'jvm-mobile-precedence.summary'
    if ($null -eq $summary) {
        throw ("{0}: missing JVM/mobile precedence summary evidence." -f $caseName)
    }

    if (
        $summary.attributes.readOnly -ne $true -or
        $summary.attributes.duplicatedRuntimeDiscovery -ne $false -or
        $summary.attributes.directEnvironmentAccess -ne $false -or
        $summary.attributes.filesystemProbes -ne $false
    ) {
        throw ("{0}: summary must preserve the derived read-only/no-rediscovery boundary." -f $caseName)
    }

    foreach ($dependencyName in @('javaJvm', 'mobileFlutterAndroid', 'pathPrecedence', 'environmentBaseline')) {
        if ($summary.attributes.dependencies.$dependencyName -ne $true) {
            throw ("{0}: expected dependency '{1}' to be available." -f $caseName, $dependencyName)
        }
    }

    $actualCodes = @($result.warnings | ForEach-Object { [string]$_.code } | Sort-Object)
    $expectedCodes = @($case.expectedWarningCodes | ForEach-Object { [string]$_ } | Sort-Object)

    if (($actualCodes -join '|') -ne ($expectedCodes -join '|')) {
        throw "$caseName warning mismatch. Expected '$($expectedCodes -join ', ')', got '$($actualCodes -join ', ')'."
    }

    if ($expectedCodes.Count -eq 0 -and $result.status -ne 'success') {
        throw "$caseName must remain successful when no conflict is expected; status=$($result.status)."
    }

    if ($expectedCodes.Count -gt 0 -and $result.status -ne 'warning') {
        throw "$caseName must report warning status when conflicts are present; status=$($result.status)."
    }
}

$aligned = $results['alignedJvmMobile']
$alignedEnvironment = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'jvm-mobile-precedence.environment'
$alignedJava = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'jvm-mobile-precedence.command.java'
$alignedJavac = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'jvm-mobile-precedence.command.javac'
$alignedFlutter = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'jvm-mobile-precedence.command.flutter'
$alignedDart = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'jvm-mobile-precedence.command.dart'
$alignedAdb = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'jvm-mobile-precedence.command.adb'

if ($alignedEnvironment.attributes.javaBin.firstPathPosition -ne 0 -or
    $alignedEnvironment.attributes.flutterBin.firstPathPosition -ne 1 -or
    $alignedEnvironment.attributes.androidHomePlatformTools.firstPathPosition -ne 2) {
    throw 'Aligned JVM/mobile layout must preserve expected Process PATH positions.'
}

foreach ($relationshipEvidence in @($alignedJava, $alignedJavac, $alignedFlutter)) {
    if ($relationshipEvidence.attributes.relationship.relationship -ne 'aligned') {
        throw 'Aligned JVM/mobile layout must align Java/Javac/Flutter command origins with configured roots.'
    }
}

if ($alignedDart.attributes.activeSource -ne 'flutter-bundled') {
    throw 'Aligned JVM/mobile layout must preserve Flutter-bundled Dart classification.'
}

if ($alignedAdb.attributes.rootRelationship.relationship -ne 'aligned-android-home') {
    throw 'Aligned JVM/mobile layout must correlate adb with ANDROID_HOME platform-tools.'
}

if (
    -not $alignedEnvironment.attributes.pubCache.configured -or
    $alignedEnvironment.attributes.pubCachePathRequired -ne $false
) {
    throw 'PUB_CACHE must be represented only as approved environment evidence and must not be required on PATH.'
}

$javaMismatch = $results['javaHomeMismatch']
$javaMismatchEvidence = Get-EvidenceById -ProviderResult $javaMismatch -EvidenceId 'jvm-mobile-precedence.command.java'
$javacMismatchEvidence = Get-EvidenceById -ProviderResult $javaMismatch -EvidenceId 'jvm-mobile-precedence.command.javac'

if (
    $javaMismatchEvidence.attributes.relationship.relationship -ne 'mismatch' -or
    $javaMismatchEvidence.attributes.relationship.activePathPosition -ne 0 -or
    $javaMismatchEvidence.attributes.relationship.expectedPathPosition -ne 1
) {
    throw 'JAVA_HOME java mismatch must prove active and expected PATH positions.'
}

if (
    $javacMismatchEvidence.attributes.relationship.relationship -ne 'mismatch' -or
    $javacMismatchEvidence.attributes.relationship.activePathPosition -ne 0 -or
    $javacMismatchEvidence.attributes.relationship.expectedPathPosition -ne 1
) {
    throw 'JAVA_HOME javac mismatch must prove active and expected PATH positions.'
}

$flutterMismatch = $results['flutterRootMismatch']
$flutterMismatchEvidence = Get-EvidenceById -ProviderResult $flutterMismatch -EvidenceId 'jvm-mobile-precedence.command.flutter'
if (
    $flutterMismatchEvidence.attributes.relationship.relationship -ne 'mismatch' -or
    $flutterMismatchEvidence.attributes.relationship.activePathPosition -ne 0 -or
    $flutterMismatchEvidence.attributes.relationship.expectedPathPosition -ne 1
) {
    throw 'FLUTTER_ROOT mismatch must prove active and expected PATH positions.'
}

$standaloneDart = $results['standaloneDartShadowing']
$standaloneDartEvidence = Get-EvidenceById -ProviderResult $standaloneDart -EvidenceId 'jvm-mobile-precedence.command.dart'
if (
    $standaloneDartEvidence.attributes.activeSource -ne 'standalone' -or
    $standaloneDartEvidence.attributes.relationship.activePathPosition -ne 0
) {
    throw 'Standalone Dart shadowing must preserve active source and PATH precedence.'
}

$dartWarning = @($standaloneDart.warnings | Where-Object code -eq 'DART_STANDALONE_SHADOWS_FLUTTER')
if (
    $dartWarning.Count -ne 1 -or
    $dartWarning[0].message -notmatch 'StandaloneDart' -or
    $dartWarning[0].message -notmatch 'PATH\[0\]' -or
    $dartWarning[0].message -notmatch 'Flutter'
) {
    throw 'Standalone Dart warning must explain the active standalone path and Flutter relationship.'
}

$androidConflict = $results['androidRootDisagreement']
$androidConflictEnvironment = Get-EvidenceById -ProviderResult $androidConflict -EvidenceId 'jvm-mobile-precedence.environment'
$androidConflictAdb = Get-EvidenceById -ProviderResult $androidConflict -EvidenceId 'jvm-mobile-precedence.command.adb'
if (
    $androidConflictEnvironment.attributes.androidRootsAgree -ne $false -or
    $androidConflictAdb.attributes.rootRelationship.relationship -ne 'aligned-android-home'
) {
    throw 'Android root disagreement must remain explicit while preserving which configured root supplies active adb.'
}

$adbMismatch = $results['adbOutsideConfiguredRoot']
$adbMismatchEvidence = Get-EvidenceById -ProviderResult $adbMismatch -EvidenceId 'jvm-mobile-precedence.command.adb'
if (
    $adbMismatchEvidence.attributes.relationship.activePathPosition -ne 0 -or
    $adbMismatchEvidence.attributes.rootRelationship.relationship -ne 'mismatch'
) {
    throw 'ADB root mismatch must preserve active PATH position and mismatch state.'
}

$missingOptional = $results['missingOptionalTooling']
$missingSummary = Get-EvidenceById -ProviderResult $missingOptional -EvidenceId 'jvm-mobile-precedence.summary'
if (
    $missingSummary.attributes.javaHomeConfigured -ne $false -or
    $missingSummary.attributes.flutterRootConfigured -ne $false -or
    $missingSummary.attributes.androidHomeConfigured -ne $false -or
    $missingSummary.attributes.androidSdkRootConfigured -ne $false -or
    @($missingOptional.warnings).Count -ne 0
) {
    throw 'Missing optional roots/tooling must remain neutral when configuration is absent.'
}

Write-Host 'JVM/mobile PATH and environment precedence validation passed.'
