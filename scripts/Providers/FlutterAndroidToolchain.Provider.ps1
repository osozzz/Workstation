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
        providerId = 'mobile.flutter-android'
        category   = 'runtime'
        order      = 23
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$components = New-Object System.Collections.Generic.List[object]
$hasPartial = $false

function New-NotApplicableVersionIntelligence {
    return [pscustomobject][ordered]@{
        status        = 'not-applicable'
        latestStable  = $null
        latestLts     = $null
        latestCurrent = $null
        source        = $null
        checkedAt     = $null
        message       = $null
    }
}

function Get-EffectiveEnvironmentValue {
    param(
        [Parameter(Mandatory)][object[]]$Snapshot,
        [Parameter(Mandatory)][string]$Name
    )

    $entry = @($Snapshot | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
    if ($entry.Count -eq 0) {
        return $null
    }

    foreach ($scope in @('process', 'user', 'machine')) {
        $value = [string]$entry[0].$scope
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function Test-PathEquals {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        $leftPath = [IO.Path]::GetFullPath($Left).TrimEnd('\')
        $rightPath = [IO.Path]::GetFullPath($Right).TrimEnd('\')
        return [string]::Equals(
            $leftPath,
            $rightPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return [string]::Equals(
            $Left.Trim().TrimEnd('\'),
            $Right.Trim().TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
}

function Test-PathWithin {
    param(
        [AllowNull()][string]$Child,
        [AllowNull()][string]$Parent
    )

    if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) {
        return $false
    }

    try {
        $childPath = [IO.Path]::GetFullPath($Child).TrimEnd('\') + '\'
        $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
        return $childPath.StartsWith($parentPath, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Add-UniqueVersion {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,

        [AllowNull()][object]$Version
    )

    if ($null -eq $Version) {
        return
    }

    $key = if (-not [string]::IsNullOrWhiteSpace([string]$Version.normalized)) {
        [string]$Version.normalized
    }
    else {
        [string]$Version.raw
    }

    foreach ($existing in $List) {
        $existingKey = if (-not [string]::IsNullOrWhiteSpace([string]$existing.normalized)) {
            [string]$existing.normalized
        }
        else {
            [string]$existing.raw
        }

        if ([string]::Equals($existingKey, $key, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $List.Add($Version)
}

function Add-UniqueInstallation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,

        [AllowNull()][string]$Path,
        [AllowNull()][object]$Version,
        [bool]$Active = $false,

        [Parameter(Mandatory)]
        [ValidateSet('command', 'registry', 'filesystem', 'environment', 'configuration', 'package-manager', 'unknown')]
        [string]$Source
    )

    foreach ($existing in $List) {
        if (
            -not [string]::IsNullOrWhiteSpace($Path) -and
            -not [string]::IsNullOrWhiteSpace([string]$existing.path) -and
            (Test-PathEquals -Left ([string]$existing.path) -Right $Path)
        ) {
            if ($Active) {
                $existing.active = $true
            }
            if ($null -eq $existing.version -and $null -ne $Version) {
                $existing.version = $Version
            }
            return
        }
    }

    $List.Add([pscustomobject][ordered]@{
        path    = $Path
        version = $Version
        active  = $Active
        source  = $Source
    })
}

function Get-VersionRecordFromText {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Channel
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match(
        $Text,
        '(?i)(?<![0-9A-Za-z])v?(?<version>\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?)'
    )

    if (-not $match.Success) {
        return $null
    }

    $normalized = $match.Groups['version'].Value
    $rawLine = @(
        $Text -split '\r?\n' |
            Where-Object { $_ -match [regex]::Escape($match.Value) } |
            Select-Object -First 1
    )

    $raw = if ($rawLine.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$rawLine[0])) {
        ([string]$rawLine[0]).Trim()
    }
    else {
        $match.Value
    }

    return New-AuditVersionRecord -Raw $raw -Normalized $normalized -Channel $Channel
}

function Get-FlutterChannel {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match(
        $Text,
        '(?im)\bchannel\s+(?<channel>stable|beta|main|master|dev)\b'
    )

    if ($match.Success) {
        $channel = $match.Groups['channel'].Value.ToLowerInvariant()
        if ($channel -eq 'master') {
            return 'main'
        }
        return $channel
    }

    return $null
}

function Get-FlutterRootFromCommandPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $directory = Split-Path -Parent $Path
        if ([string]::IsNullOrWhiteSpace($directory)) {
            return $null
        }

        if ([string]::Equals(
            (Split-Path -Leaf $directory),
            'bin',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return Split-Path -Parent $directory
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-AndroidRootFromAdbPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $directory = Split-Path -Parent $Path
        if (
            -not [string]::IsNullOrWhiteSpace($directory) -and
            [string]::Equals(
                (Split-Path -Leaf $directory),
                'platform-tools',
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return Split-Path -Parent $directory
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-AndroidRootFromSdkManagerPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $bin = Split-Path -Parent $Path
        $versionDir = Split-Path -Parent $bin
        $cmdlineTools = Split-Path -Parent $versionDir

        if (
            -not [string]::IsNullOrWhiteSpace($cmdlineTools) -and
            [string]::Equals(
                (Split-Path -Leaf $cmdlineTools),
                'cmdline-tools',
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return Split-Path -Parent $cmdlineTools
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-SourceProperties {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $values = [ordered]@{}

    try {
        foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
            if ($line -notmatch '^\s*(?<key>[^#=]+?)\s*=\s*(?<value>.*)\s*$') {
                continue
            }

            $values[$Matches['key'].Trim()] = $Matches['value'].Trim()
        }
    }
    catch {
        return $null
    }

    return [pscustomobject]$values
}

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

function Get-AndroidSdkMetadata {
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $null
    }

    $items = New-Object System.Collections.Generic.List[object]

    $platformToolsProperties = Join-Path $Root 'platform-tools\source.properties'
    $platformTools = Get-SourceProperties -Path $platformToolsProperties
    if ($null -ne $platformTools) {
        $items.Add([pscustomobject][ordered]@{
            component = 'platform-tools'
            revision  = Get-OptionalPropertyValue -InputObject $platformTools -Name 'Pkg.Revision'
            path      = Join-Path $Root 'platform-tools'
        })
    }

    $cmdlineToolsRoot = Join-Path $Root 'cmdline-tools'
    if (Test-Path -LiteralPath $cmdlineToolsRoot -PathType Container) {
        try {
            foreach ($directory in @(Get-ChildItem -LiteralPath $cmdlineToolsRoot -Directory -ErrorAction Stop)) {
                $properties = Get-SourceProperties -Path (Join-Path $directory.FullName 'source.properties')
                if ($null -eq $properties) {
                    continue
                }

                $items.Add([pscustomobject][ordered]@{
                    component = "cmdline-tools/$($directory.Name)"
                    revision  = Get-OptionalPropertyValue -InputObject $properties -Name 'Pkg.Revision'
                    path      = $directory.FullName
                })
            }
        }
        catch {
            $script:hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'ANDROID_CMDLINE_TOOLS_ENUMERATION_PARTIAL' -Message 'Android command-line tools could not be enumerated completely.' -Severity warning -ComponentId 'android-sdk' -EvidenceIds @('mobile.android-sdk.metadata')))
        }
    }

    $buildToolsRoot = Join-Path $Root 'build-tools'
    if (Test-Path -LiteralPath $buildToolsRoot -PathType Container) {
        try {
            foreach ($directory in @(Get-ChildItem -LiteralPath $buildToolsRoot -Directory -ErrorAction Stop)) {
                $items.Add([pscustomobject][ordered]@{
                    component = "build-tools/$($directory.Name)"
                    revision  = $directory.Name
                    path      = $directory.FullName
                })
            }
        }
        catch {
            $script:hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'ANDROID_BUILD_TOOLS_ENUMERATION_PARTIAL' -Message 'Android build-tools could not be enumerated completely.' -Severity warning -ComponentId 'android-sdk' -EvidenceIds @('mobile.android-sdk.metadata')))
        }
    }

    $platformsRoot = Join-Path $Root 'platforms'
    if (Test-Path -LiteralPath $platformsRoot -PathType Container) {
        try {
            foreach ($directory in @(Get-ChildItem -LiteralPath $platformsRoot -Directory -ErrorAction Stop)) {
                $items.Add([pscustomobject][ordered]@{
                    component = "platforms/$($directory.Name)"
                    revision  = $directory.Name
                    path      = $directory.FullName
                })
            }
        }
        catch {
            $script:hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'ANDROID_PLATFORMS_ENUMERATION_PARTIAL' -Message 'Android platforms could not be enumerated completely.' -Severity warning -ComponentId 'android-sdk' -EvidenceIds @('mobile.android-sdk.metadata')))
        }
    }

    return [pscustomobject][ordered]@{
        root       = $Root
        components = $items.ToArray()
        adbPath    = $(if (Test-Path -LiteralPath (Join-Path $Root 'platform-tools\adb.exe') -PathType Leaf) { Join-Path $Root 'platform-tools\adb.exe' } else { $null })
    }
}

function New-CommandComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$EvidenceId,
        [AllowNull()][scriptblock]$VersionParser,
        [object[]]$AdditionalInstallations = @()
    )

    $result = Invoke-AuditCommand -Command $Command -Arguments $Arguments -TimeoutSeconds 20

    if (-not $result.Found) {
        $installations = New-Object System.Collections.Generic.List[object]
        $versions = New-Object System.Collections.Generic.List[object]

        foreach ($candidate in @($AdditionalInstallations)) {
            $candidatePath = Get-OptionalPropertyValue -InputObject $candidate -Name 'path'
            $candidateVersion = Get-OptionalPropertyValue -InputObject $candidate -Name 'version'
            $candidateSource = [string](Get-OptionalPropertyValue -InputObject $candidate -Name 'source')
            if ([string]::IsNullOrWhiteSpace($candidateSource)) {
                $candidateSource = 'unknown'
            }

            Add-UniqueInstallation -List $installations -Path ([string]$candidatePath) -Version $candidateVersion -Active $false -Source $candidateSource
            Add-UniqueVersion -List $versions -Version $candidateVersion
        }

        return [pscustomobject][ordered]@{
            componentId         = $ComponentId
            name                = $Name
            state               = $(if ($installations.Count -gt 0) { 'partial' } else { 'missing' })
            installed           = $(if ($installations.Count -gt 0) { $true } else { $false })
            activeVersion       = $null
            discoveredVersions  = $versions.ToArray()
            installations       = $installations.ToArray()
            commandResolutions  = @()
            versionIntelligence = New-NotApplicableVersionIntelligence
        }
    }

    $evidence.Add((New-AuditEvidence -EvidenceId $EvidenceId -Type command -Source ((@($Command) + @($Arguments)) -join ' ') -ExitCode $result.ExitCode -Captured $result.Captured -Redacted:$result.Redacted -Attributes @{
        status          = $result.Status
        truncated       = $result.Truncated
        timedOut        = $result.TimedOut
        resolutionCount = @($result.Resolutions).Count
    }))

    $activeVersion = if ($null -ne $VersionParser) {
        & $VersionParser $result.Captured
    }
    else {
        Get-VersionRecordFromText -Text $result.Captured -Channel $null
    }

    $versions = New-Object System.Collections.Generic.List[object]
    Add-UniqueVersion -List $versions -Version $activeVersion

    $installations = New-Object System.Collections.Generic.List[object]
    foreach ($resolution in @($result.Resolutions)) {
        Add-UniqueInstallation -List $installations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $activeVersion } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
    }

    foreach ($candidate in @($AdditionalInstallations)) {
        $candidatePath = Get-OptionalPropertyValue -InputObject $candidate -Name 'path'
        $candidateVersion = Get-OptionalPropertyValue -InputObject $candidate -Name 'version'
        $candidateSource = [string](Get-OptionalPropertyValue -InputObject $candidate -Name 'source')
        if ([string]::IsNullOrWhiteSpace($candidateSource)) {
            $candidateSource = 'unknown'
        }

        Add-UniqueInstallation -List $installations -Path ([string]$candidatePath) -Version $candidateVersion -Active $false -Source $candidateSource
        Add-UniqueVersion -List $versions -Version $candidateVersion
    }

    $state = 'present'
    if ($result.Status -ne 'success' -or $null -eq $activeVersion) {
        $state = 'partial'
        $script:hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'MOBILE_COMMAND_VERSION_INCOMPLETE' -Message "Version detection for '$Name' was incomplete." -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
    }

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = $Name
        state               = $state
        installed           = $true
        activeVersion       = $activeVersion
        discoveredVersions  = $versions.ToArray()
        installations       = $installations.ToArray()
        commandResolutions  = @($result.Resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    }
}

$environmentSnapshot = Get-AuditEnvironmentSnapshot -Names @(
    'FLUTTER_ROOT',
    'PUB_CACHE',
    'ANDROID_HOME',
    'ANDROID_SDK_ROOT'
)

$flutterRootEnvironment = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'FLUTTER_ROOT'
$pubCache = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'PUB_CACHE'
$androidHome = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'ANDROID_HOME'
$androidSdkRoot = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'ANDROID_SDK_ROOT'

$evidence.Add((New-AuditEvidence -EvidenceId 'mobile.environment' -Type environment -Source 'FLUTTER_ROOT/PUB_CACHE/ANDROID_HOME/ANDROID_SDK_ROOT' -Captured $null -Attributes @{
    variables = @($environmentSnapshot)
    flutterRootConfigured = -not [string]::IsNullOrWhiteSpace($flutterRootEnvironment)
    pubCacheConfigured = -not [string]::IsNullOrWhiteSpace($pubCache)
    androidHomeConfigured = -not [string]::IsNullOrWhiteSpace($androidHome)
    androidSdkRootConfigured = -not [string]::IsNullOrWhiteSpace($androidSdkRoot)
}))

$flutterResult = Invoke-AuditCommand -Command 'flutter' -Arguments @('--version') -TimeoutSeconds 25
$flutterChannel = if ($flutterResult.Found) { Get-FlutterChannel -Text $flutterResult.Captured } else { $null }
$flutterVersion = if ($flutterResult.Found) { Get-VersionRecordFromText -Text $flutterResult.Captured -Channel $flutterChannel } else { $null }

$flutterRoots = New-Object System.Collections.Generic.List[object]
if (-not [string]::IsNullOrWhiteSpace($flutterRootEnvironment)) {
    $flutterRoots.Add([pscustomobject][ordered]@{
        path   = $flutterRootEnvironment
        source = 'environment'
    })
}

foreach ($resolution in @($flutterResult.Resolutions)) {
    $root = Get-FlutterRootFromCommandPath -Path ([string]$resolution.path)
    if ([string]::IsNullOrWhiteSpace($root)) {
        continue
    }

    if (@($flutterRoots | Where-Object { Test-PathEquals -Left $_.path -Right $root }).Count -eq 0) {
        $flutterRoots.Add([pscustomobject][ordered]@{
            path   = $root
            source = 'command'
        })
    }
}

$flutterInstallations = New-Object System.Collections.Generic.List[object]
foreach ($candidate in $flutterRoots) {
    $flutterBat = Join-Path ([string]$candidate.path) 'bin\flutter.bat'
    if (-not (Test-Path -LiteralPath $flutterBat -PathType Leaf)) {
        continue
    }

    $active = @(
        $flutterResult.Resolutions |
            Where-Object {
                $_.active -and
                (Test-PathEquals -Left ([string]$_.path) -Right $flutterBat)
            }
    ).Count -gt 0

    Add-UniqueInstallation -List $flutterInstallations -Path ([string]$candidate.path) -Version $flutterVersion -Active $active -Source ([string]$candidate.source)
}

if ($flutterResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'mobile.flutter.version' -Type command -Source 'flutter --version' -ExitCode $flutterResult.ExitCode -Captured $flutterResult.Captured -Redacted:$flutterResult.Redacted -Attributes @{
        status = $flutterResult.Status
        truncated = $flutterResult.Truncated
        timedOut = $flutterResult.TimedOut
        channel = $flutterChannel
        resolutionCount = @($flutterResult.Resolutions).Count
    }))
}

$activeFlutterRoot = $null
$activeFlutterResolution = @($flutterResult.Resolutions | Where-Object active | Select-Object -First 1)
if ($activeFlutterResolution.Count -gt 0) {
    $activeFlutterRoot = Get-FlutterRootFromCommandPath -Path ([string]$activeFlutterResolution[0].path)
}

$flutterState = if ($flutterResult.Found) { 'present' } elseif ($flutterInstallations.Count -gt 0) { 'partial' } else { 'missing' }
$flutterInstalled = if ($flutterResult.Found -or $flutterInstallations.Count -gt 0) { $true } else { $false }

if ($flutterResult.Found -and ($flutterResult.Status -ne 'success' -or $null -eq $flutterVersion)) {
    $flutterState = 'partial'
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'FLUTTER_VERSION_INCOMPLETE' -Message 'Flutter is resolvable, but its version could not be determined reliably.' -Severity warning -ComponentId 'flutter' -EvidenceIds @('mobile.flutter.version')))
}
elseif (-not $flutterResult.Found -and $flutterInstallations.Count -gt 0) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'FLUTTER_COMMAND_UNRESOLVED' -Message 'A Flutter SDK installation was identified, but the flutter command is not resolvable.' -Severity warning -ComponentId 'flutter' -EvidenceIds @('mobile.environment')))
}

if (
    -not [string]::IsNullOrWhiteSpace($flutterRootEnvironment) -and
    -not [string]::IsNullOrWhiteSpace($activeFlutterRoot) -and
    -not (Test-PathEquals -Left $flutterRootEnvironment -Right $activeFlutterRoot)
) {
    $flutterState = 'partial'
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'FLUTTER_ROOT_COMMAND_MISMATCH' -Message 'FLUTTER_ROOT points to a different Flutter SDK than the active flutter command.' -Severity warning -ComponentId 'flutter' -EvidenceIds @('mobile.environment', 'mobile.flutter.version')))
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'flutter'
    name                = 'Flutter SDK'
    state               = $flutterState
    installed           = $flutterInstalled
    activeVersion       = $flutterVersion
    discoveredVersions  = $(if ($null -ne $flutterVersion) { @($flutterVersion) } else { @() })
    installations       = $flutterInstallations.ToArray()
    commandResolutions  = @($flutterResult.Resolutions)
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$bundledDartCandidates = New-Object System.Collections.Generic.List[object]
foreach ($flutterInstallation in $flutterInstallations) {
    $dartPath = Join-Path ([string]$flutterInstallation.path) 'bin\cache\dart-sdk\bin\dart.exe'
    if (Test-Path -LiteralPath $dartPath -PathType Leaf) {
        $bundledDartCandidates.Add([pscustomobject][ordered]@{
            path        = $dartPath
            flutterRoot = [string]$flutterInstallation.path
            source      = 'filesystem'
        })
    }
}

$dartResult = Invoke-AuditCommand -Command 'dart' -Arguments @('--version') -TimeoutSeconds 20
$dartVersion = if ($dartResult.Found) { Get-VersionRecordFromText -Text $dartResult.Captured -Channel $null } else { $null }

if ($dartResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'mobile.dart.version' -Type command -Source 'dart --version' -ExitCode $dartResult.ExitCode -Captured $dartResult.Captured -Redacted:$dartResult.Redacted -Attributes @{
        status = $dartResult.Status
        truncated = $dartResult.Truncated
        timedOut = $dartResult.TimedOut
        resolutionCount = @($dartResult.Resolutions).Count
    }))
}

$dartInstallations = New-Object System.Collections.Generic.List[object]
foreach ($resolution in @($dartResult.Resolutions)) {
    Add-UniqueInstallation -List $dartInstallations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $dartVersion } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
}

foreach ($candidate in $bundledDartCandidates) {
    Add-UniqueInstallation -List $dartInstallations -Path ([string]$candidate.path) -Version $null -Active $false -Source filesystem
}

$activeDartPath = $null
$activeDartResolution = @($dartResult.Resolutions | Where-Object active | Select-Object -First 1)
if ($activeDartResolution.Count -gt 0) {
    $activeDartPath = [string]$activeDartResolution[0].path
}

$activeDartSource = 'unknown'
$activeBundledFlutterRoot = $null

if (-not [string]::IsNullOrWhiteSpace($activeDartPath)) {
    foreach ($candidate in $bundledDartCandidates) {
        if (Test-PathEquals -Left $activeDartPath -Right ([string]$candidate.path)) {
            $activeDartSource = 'flutter-bundled'
            $activeBundledFlutterRoot = [string]$candidate.flutterRoot
            break
        }
    }

    if ($activeDartSource -eq 'unknown') {
        $activeDartSource = 'standalone-or-external'
    }
}

$evidence.Add((New-AuditEvidence -EvidenceId 'mobile.dart.relationship' -Type derived -Source 'Flutter-bundled versus standalone Dart classification' -Captured $null -Attributes @{
    activeSource = $activeDartSource
    activeBundledFlutterRoot = $activeBundledFlutterRoot
    bundledInstallationCount = $bundledDartCandidates.Count
}))

$dartState = if ($dartResult.Found) { 'present' } elseif ($bundledDartCandidates.Count -gt 0) { 'partial' } else { 'missing' }
$dartInstalled = if ($dartResult.Found -or $bundledDartCandidates.Count -gt 0) { $true } else { $false }

if ($dartResult.Found -and ($dartResult.Status -ne 'success' -or $null -eq $dartVersion)) {
    $dartState = 'partial'
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DART_VERSION_INCOMPLETE' -Message 'Dart is resolvable, but its version could not be determined reliably.' -Severity warning -ComponentId 'dart' -EvidenceIds @('mobile.dart.version')))
}
elseif (-not $dartResult.Found -and $bundledDartCandidates.Count -gt 0) {
    $dartState = 'partial'
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DART_COMMAND_UNRESOLVED' -Message 'Flutter-bundled Dart was discovered, but the dart command is not resolvable.' -Severity warning -ComponentId 'dart' -EvidenceIds @('mobile.dart.relationship')))
}

if (
    $flutterResult.Found -and
    $dartResult.Found -and
    $activeDartSource -eq 'standalone-or-external'
) {
    $hasPartial = $true
    if ($dartState -eq 'present') {
        $dartState = 'partial'
    }
    $warnings.Add((New-AuditIssue -Code 'DART_ACTIVE_NOT_FLUTTER_BUNDLED' -Message 'Flutter is active, but the active dart command does not resolve to the Dart SDK bundled with a discovered Flutter installation.' -Severity warning -ComponentId 'dart' -EvidenceIds @('mobile.dart.relationship', 'mobile.flutter.version', 'mobile.dart.version')))
}

$dartVersions = New-Object System.Collections.Generic.List[object]
Add-UniqueVersion -List $dartVersions -Version $dartVersion

$components.Add([pscustomobject][ordered]@{
    componentId         = 'dart'
    name                = 'Dart SDK'
    state               = $dartState
    installed           = $dartInstalled
    activeVersion       = $dartVersion
    discoveredVersions  = $dartVersions.ToArray()
    installations       = $dartInstallations.ToArray()
    commandResolutions  = @($dartResult.Resolutions)
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$adbResult = Invoke-AuditCommand -Command 'adb' -Arguments @('version') -TimeoutSeconds 20
$adbVersion = if ($adbResult.Found) { Get-VersionRecordFromText -Text $adbResult.Captured -Channel $null } else { $null }

if ($adbResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'mobile.adb.version' -Type command -Source 'adb version' -ExitCode $adbResult.ExitCode -Captured $adbResult.Captured -Redacted:$adbResult.Redacted -Attributes @{
        status = $adbResult.Status
        truncated = $adbResult.Truncated
        timedOut = $adbResult.TimedOut
        resolutionCount = @($adbResult.Resolutions).Count
    }))
}

$sdkManagerResult = Invoke-AuditCommand -Command 'sdkmanager' -Arguments @('--version') -TimeoutSeconds 20
$sdkManagerVersion = if ($sdkManagerResult.Found) { Get-VersionRecordFromText -Text $sdkManagerResult.Captured -Channel $null } else { $null }

if ($sdkManagerResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'mobile.sdkmanager.version' -Type command -Source 'sdkmanager --version' -ExitCode $sdkManagerResult.ExitCode -Captured $sdkManagerResult.Captured -Redacted:$sdkManagerResult.Redacted -Attributes @{
        status = $sdkManagerResult.Status
        truncated = $sdkManagerResult.Truncated
        timedOut = $sdkManagerResult.TimedOut
        resolutionCount = @($sdkManagerResult.Resolutions).Count
    }))
}

$androidRootCandidates = New-Object System.Collections.Generic.List[object]

function Add-AndroidRootCandidate {
    param(
        [AllowNull()][string]$Path,
        [Parameter(Mandatory)][string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    foreach ($candidate in $androidRootCandidates) {
        if (Test-PathEquals -Left ([string]$candidate.path) -Right $Path) {
            if ($candidate.sources -notcontains $Source) {
                $candidate.sources = @($candidate.sources) + @($Source)
            }
            return
        }
    }

    $androidRootCandidates.Add([pscustomobject][ordered]@{
        path    = $Path
        sources = @($Source)
    })
}

Add-AndroidRootCandidate -Path $androidHome -Source 'ANDROID_HOME'
Add-AndroidRootCandidate -Path $androidSdkRoot -Source 'ANDROID_SDK_ROOT'

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    $defaultAndroidSdk = Join-Path $localAppData 'Android\Sdk'
    if (Test-Path -LiteralPath $defaultAndroidSdk -PathType Container) {
        Add-AndroidRootCandidate -Path $defaultAndroidSdk -Source 'default-location'
    }
}

foreach ($resolution in @($adbResult.Resolutions)) {
    Add-AndroidRootCandidate -Path (Get-AndroidRootFromAdbPath -Path ([string]$resolution.path)) -Source 'adb-command'
}

foreach ($resolution in @($sdkManagerResult.Resolutions)) {
    Add-AndroidRootCandidate -Path (Get-AndroidRootFromSdkManagerPath -Path ([string]$resolution.path)) -Source 'sdkmanager-command'
}

$androidMetadata = New-Object System.Collections.Generic.List[object]
foreach ($candidate in $androidRootCandidates) {
    $metadata = Get-AndroidSdkMetadata -Root ([string]$candidate.path)
    if ($null -eq $metadata) {
        continue
    }

    $androidMetadata.Add([pscustomobject][ordered]@{
        root       = $metadata.root
        components = @($metadata.components)
        adbPath    = $metadata.adbPath
        sources    = @($candidate.sources)
    })
}

$evidence.Add((New-AuditEvidence -EvidenceId 'mobile.android-sdk.metadata' -Type derived -Source 'bounded Android SDK root/component inspection' -Captured $null -Attributes @{
    roots = @(
        $androidMetadata |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path       = $_.root
                    sources    = @($_.sources)
                    components = @($_.components)
                    adbPresent = -not [string]::IsNullOrWhiteSpace([string]$_.adbPath)
                }
            }
    )
}))

$androidInstallations = New-Object System.Collections.Generic.List[object]
foreach ($metadata in $androidMetadata) {
    $active = $false

    foreach ($resolution in @($adbResult.Resolutions | Where-Object active)) {
        $root = Get-AndroidRootFromAdbPath -Path ([string]$resolution.path)
        if (Test-PathEquals -Left $root -Right ([string]$metadata.root)) {
            $active = $true
            break
        }
    }

    Add-UniqueInstallation -List $androidInstallations -Path ([string]$metadata.root) -Version $null -Active $active -Source $(if ($metadata.sources -contains 'ANDROID_HOME' -or $metadata.sources -contains 'ANDROID_SDK_ROOT') { 'environment' } elseif ($metadata.sources -contains 'adb-command' -or $metadata.sources -contains 'sdkmanager-command') { 'command' } else { 'filesystem' })
}

$androidState = if ($androidMetadata.Count -gt 0) { 'present' } elseif (
    -not [string]::IsNullOrWhiteSpace($androidHome) -or
    -not [string]::IsNullOrWhiteSpace($androidSdkRoot)
) { 'partial' } else { 'missing' }

$androidInstalled = if ($androidMetadata.Count -gt 0) { $true } elseif ($androidState -eq 'partial') { $null } else { $false }

if (
    -not [string]::IsNullOrWhiteSpace($androidHome) -and
    -not [string]::IsNullOrWhiteSpace($androidSdkRoot) -and
    -not (Test-PathEquals -Left $androidHome -Right $androidSdkRoot)
) {
    $androidState = 'partial'
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'ANDROID_SDK_ROOT_CONFLICT' -Message 'ANDROID_HOME and ANDROID_SDK_ROOT point to different Android SDK locations.' -Severity warning -ComponentId 'android-sdk' -EvidenceIds @('mobile.environment', 'mobile.android-sdk.metadata')))
}

if (
    $androidMetadata.Count -eq 0 -and
    (
        -not [string]::IsNullOrWhiteSpace($androidHome) -or
        -not [string]::IsNullOrWhiteSpace($androidSdkRoot)
    )
) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'ANDROID_SDK_ROOT_UNRESOLVED' -Message 'Android SDK environment configuration exists, but no valid SDK root could be confirmed.' -Severity warning -ComponentId 'android-sdk' -EvidenceIds @('mobile.environment', 'mobile.android-sdk.metadata')))
}

if ($flutterResult.Found -and $androidState -eq 'missing') {
    $warnings.Add((New-AuditIssue -Code 'ANDROID_SDK_MISSING_FOR_FLUTTER' -Message 'Flutter is available, but no Android SDK installation was detected.' -Severity warning -ComponentId 'android-sdk' -EvidenceIds @('mobile.flutter.version', 'mobile.android-sdk.metadata')))
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'android-sdk'
    name                = 'Android SDK'
    state               = $androidState
    installed           = $androidInstalled
    activeVersion       = $null
    discoveredVersions  = @()
    installations       = $androidInstallations.ToArray()
    commandResolutions  = @()
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$adbAdditionalInstallations = New-Object System.Collections.Generic.List[object]
foreach ($metadata in $androidMetadata) {
    if (-not [string]::IsNullOrWhiteSpace([string]$metadata.adbPath)) {
        $adbAdditionalInstallations.Add([pscustomobject][ordered]@{
            path    = [string]$metadata.adbPath
            version = $null
            source  = 'filesystem'
        })
    }
}

$adbComponent = New-CommandComponent -ComponentId 'adb' -Name 'Android Debug Bridge' -Command 'adb' -Arguments @('version') -EvidenceId 'mobile.adb.version' -VersionParser {
    param($text)
    Get-VersionRecordFromText -Text $text -Channel $null
} -AdditionalInstallations $adbAdditionalInstallations.ToArray()

if ($adbComponent.state -eq 'partial' -and -not $adbResult.Found -and $adbAdditionalInstallations.Count -gt 0) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'ADB_COMMAND_UNRESOLVED' -Message 'Android platform-tools include adb, but the adb command is not resolvable.' -Severity warning -ComponentId 'adb' -EvidenceIds @('mobile.android-sdk.metadata')))
}

$components.Add($adbComponent)

$sdkManagerAdditionalInstallations = New-Object System.Collections.Generic.List[object]
foreach ($metadata in $androidMetadata) {
    foreach ($componentMetadata in @($metadata.components | Where-Object { $_.component -like 'cmdline-tools/*' })) {
        $candidatePath = Join-Path ([string]$componentMetadata.path) 'bin\sdkmanager.bat'
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $sdkManagerAdditionalInstallations.Add([pscustomobject][ordered]@{
                path    = $candidatePath
                version = $(if (-not [string]::IsNullOrWhiteSpace([string]$componentMetadata.revision)) { Get-VersionRecordFromText -Text ([string]$componentMetadata.revision) -Channel $null } else { $null })
                source  = 'filesystem'
            })
        }
    }
}

$components.Add((New-CommandComponent -ComponentId 'sdkmanager' -Name 'Android SDK Manager' -Command 'sdkmanager' -Arguments @('--version') -EvidenceId 'mobile.sdkmanager.version' -VersionParser {
    param($text)
    Get-VersionRecordFromText -Text $text -Channel $null
} -AdditionalInstallations $sdkManagerAdditionalInstallations.ToArray()))

$anyPresent = @(
    $components |
        Where-Object { $_.state -in @('present', 'partial') }
).Count -gt 0

$status = if (-not $anyPresent) {
    'unavailable'
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial
}

return [pscustomobject][ordered]@{
    providerId = 'mobile.flutter-android'
    category   = 'runtime'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
