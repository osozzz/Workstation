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
        providerId = 'java.jvm'
        category   = 'runtime'
        order      = 22
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
$versionCorePath = Join-Path $PSScriptRoot '..\Core\VersionIntelligence.Core.psm1'
$jvmMobileVersionCorePath = Join-Path $PSScriptRoot '..\Core\JvmMobileVersionIntelligence.Core.psm1'
Import-Module $corePath -Force
Import-Module $versionCorePath -Force
Import-Module $jvmMobileVersionCorePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$components = New-Object System.Collections.Generic.List[object]
$hasPartial = $false

$versionIntelligenceOffline = $false
$offlineProperty = $Context.PSObject.Properties['VersionIntelligenceOffline']
if ($offlineProperty -and $null -ne $offlineProperty.Value) {
    $versionIntelligenceOffline = [bool]$offlineProperty.Value
}

$versionIntelligenceTransport = $null
$transportProperty = $Context.PSObject.Properties['VersionIntelligenceTransport']
if ($transportProperty -and $transportProperty.Value -is [scriptblock]) {
    $versionIntelligenceTransport = [scriptblock]$transportProperty.Value
}

try {
    $versionCheckedAt = [DateTimeOffset]::Parse([string]$Context.ObservedAt)
}
catch {
    $versionCheckedAt = [DateTimeOffset]::UtcNow
}

function Get-JavaVersionSource {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    $parameters = @{
        Source = $Source
        Uri = $Uri
        CheckedAt = $versionCheckedAt
        Offline = $versionIntelligenceOffline
        MaximumResponseBytes = 262144
    }

    if ($null -ne $versionIntelligenceTransport) {
        $parameters['Transport'] = $versionIntelligenceTransport
    }

    $sourceResult = Invoke-AuditVersionSource @parameters
    $evidence.Add((New-AuditEvidence -EvidenceId $EvidenceId -Type api -Source $Source -Captured $null -Attributes (Get-AuditVersionSourceEvidenceAttributes -SourceResult $sourceResult)))
    return ConvertFrom-AuditVersionSourceJson -SourceResult $sourceResult
}

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
        return [string]::Equals($leftPath, $rightPath, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return [string]::Equals(
            $Left.Trim().TrimEnd('\'),
            $Right.Trim().TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
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

function Get-JavaVersionRecord {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $patterns = @(
        '(?i)(?<![0-9A-Za-z])(?<version>1\.\d+(?:\.\d+)*(?:_\d+)?(?:[-+][0-9A-Za-z._-]+)?)',
        '(?i)(?<![0-9A-Za-z])(?<version>\d+(?:\.\d+){0,3}(?:[-+][0-9A-Za-z._-]+)?)'
    )

    $match = $null
    foreach ($pattern in $patterns) {
        $candidate = [regex]::Match($Text, $pattern)
        if ($candidate.Success) {
            $match = $candidate
            break
        }
    }

    if ($null -eq $match -or -not $match.Success) {
        return $null
    }

    $normalized = $match.Groups['version'].Value.Trim('"')
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

    return New-AuditVersionRecord -Raw $raw -Normalized $normalized -Channel $null
}

function Get-JavaMajorVersion {
    param([AllowNull()][object]$Version)

    if ($null -eq $Version -or [string]::IsNullOrWhiteSpace([string]$Version.normalized)) {
        return $null
    }

    $normalized = [string]$Version.normalized
    if ($normalized -match '^1\.(?<major>\d+)') {
        return [int]$Matches['major']
    }

    if ($normalized -match '^(?<major>\d+)') {
        return [int]$Matches['major']
    }

    return $null
}

function Get-JavaRootFromExecutable {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        $binPath = Split-Path -Parent $Path
        if ([string]::IsNullOrWhiteSpace($binPath)) {
            return $null
        }

        if ([string]::Equals(
            (Split-Path -Leaf $binPath),
            'bin',
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return Split-Path -Parent $binPath
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-JavaDistribution {
    param(
        [AllowNull()][string]$Vendor,
        [AllowNull()][string]$Path
    )

    $combined = "$Vendor $Path"

    if ($combined -match '(?i)adoptium|temurin') {
        return 'Temurin'
    }
    if ($combined -match '(?i)amazon|corretto') {
        return 'Corretto'
    }
    if ($combined -match '(?i)azul|zulu') {
        return 'Zulu'
    }
    if ($combined -match '(?i)bellsoft|liberica') {
        return 'Liberica'
    }
    if ($combined -match '(?i)microsoft') {
        return 'Microsoft Build of OpenJDK'
    }
    if ($combined -match '(?i)red hat') {
        return 'Red Hat OpenJDK'
    }
    if ($combined -match '(?i)ibm|semeru') {
        return 'Semeru'
    }
    if ($combined -match '(?i)oracle') {
        return 'Oracle'
    }

    return $null
}

function Get-JavaReleaseMetadata {
    param([Parameter(Mandatory)][string]$RootPath)

    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        return $null
    }

    $releasePath = Join-Path $RootPath 'release'
    $values = @{}

    if (Test-Path -LiteralPath $releasePath -PathType Leaf) {
        try {
            foreach ($line in @(Get-Content -LiteralPath $releasePath -ErrorAction Stop)) {
                if ($line -notmatch '^(?<key>[A-Z0-9_]+)=(?<value>.*)$') {
                    continue
                }

                $value = $Matches['value'].Trim()
                if (
                    $value.Length -ge 2 -and
                    $value.StartsWith('"') -and
                    $value.EndsWith('"')
                ) {
                    $value = $value.Substring(1, $value.Length - 2)
                }

                $values[$Matches['key']] = $value
            }
        }
        catch {
            return $null
        }
    }

    $javaPath = Join-Path $RootPath 'bin\java.exe'
    $javacPath = Join-Path $RootPath 'bin\javac.exe'

    if (
        $values.Count -eq 0 -and
        -not (Test-Path -LiteralPath $javaPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $javacPath -PathType Leaf)
    ) {
        return $null
    }

    $versionText = $null
    foreach ($key in @('JAVA_VERSION', 'JAVA_RUNTIME_VERSION', 'FULL_VERSION')) {
        if ($values.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$values[$key])) {
            $versionText = [string]$values[$key]
            break
        }
    }

    $version = Get-JavaVersionRecord -Text $versionText
    $vendor = if ($values.ContainsKey('IMPLEMENTOR')) { [string]$values['IMPLEMENTOR'] } else { $null }
    $architecture = if ($values.ContainsKey('OS_ARCH')) { [string]$values['OS_ARCH'] } else { $null }

    return [pscustomobject][ordered]@{
        path         = $RootPath
        version      = $version
        majorVersion = Get-JavaMajorVersion -Version $version
        vendor       = $vendor
        distribution = Get-JavaDistribution -Vendor $vendor -Path $RootPath
        kind         = $(if (Test-Path -LiteralPath $javacPath -PathType Leaf) { 'jdk' } else { 'jre' })
        architecture = $architecture
        releaseFile  = $(if (Test-Path -LiteralPath $releasePath -PathType Leaf) { $releasePath } else { $null })
    }
}

function Add-JavaCandidate {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,

        [AllowNull()][string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('command', 'registry', 'filesystem', 'environment', 'configuration', 'unknown')]
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $normalizedPath = $Path.Trim().Trim('"')

    foreach ($item in $List) {
        if (Test-PathEquals -Left ([string]$item.path) -Right $normalizedPath) {
            if ($item.sources -notcontains $Source) {
                $item.sources = @($item.sources) + @($Source)
            }
            return
        }
    }

    $List.Add([pscustomobject][ordered]@{
        path    = $normalizedPath
        sources = @($Source)
    })
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

function Get-JavaProperties {
    param([AllowNull()][string]$Text)

    $result = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]$result
    }

    foreach ($line in @($Text -split '\r?\n')) {
        if ($line -match '^\s*(?<key>java\.version|java\.home|java\.vendor|java\.runtime\.name|java\.vm\.name|os\.arch)\s*=\s*(?<value>.+?)\s*$') {
            $result[$Matches['key']] = $Matches['value']
        }
    }

    return [pscustomobject]$result
}

function Get-PropertyValue {
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

function New-SimpleCommandComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-AuditCommand -Command $Command -Arguments $Arguments -TimeoutSeconds 20

    if (-not $result.Found) {
        return [pscustomobject][ordered]@{
            componentId         = $ComponentId
            name                = $Name
            state               = 'missing'
            installed           = $false
            activeVersion       = $null
            discoveredVersions  = @()
            installations       = @()
            commandResolutions  = @()
            versionIntelligence = New-NotApplicableVersionIntelligence
        }
    }

    $evidenceId = "java.$ComponentId.version"
    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type command -Source ((@($Command) + @($Arguments)) -join ' ') -ExitCode $result.ExitCode -Captured $result.Captured -Redacted:$result.Redacted -Attributes @{
        status          = $result.Status
        truncated       = $result.Truncated
        timedOut        = $result.TimedOut
        resolutionCount = @($result.Resolutions).Count
    }))

    $version = Get-JavaVersionRecord -Text $result.Captured
    $state = 'present'

    if ($result.Status -ne 'success' -or $null -eq $version) {
        $state = 'partial'
        $script:hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'JAVA_BUILD_TOOL_VERSION_INCOMPLETE' -Message "Version detection for '$Name' was incomplete." -Severity warning -ComponentId $ComponentId -EvidenceIds @($evidenceId)))
    }

    $installations = @(
        $result.Resolutions |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path    = $_.path
                    version = $(if ($_.active) { $version } else { $_.version })
                    active  = [bool]$_.active
                    source  = 'command'
                }
            }
    )

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = $Name
        state               = $state
        installed           = $true
        activeVersion       = $version
        discoveredVersions  = @(if ($null -ne $version) { $version })
        installations       = $installations
        commandResolutions  = @($result.Resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    }
}

$environmentSnapshot = Get-AuditEnvironmentSnapshot -Names @('JAVA_HOME')
$javaHome = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'JAVA_HOME'

$evidence.Add((New-AuditEvidence -EvidenceId 'java.environment' -Type environment -Source 'JAVA_HOME' -Captured $null -Attributes @{
    variables = @($environmentSnapshot)
    configured = -not [string]::IsNullOrWhiteSpace($javaHome)
}))

$javaResult = Invoke-AuditCommand -Command 'java' -Arguments @('-XshowSettings:properties', '-version') -TimeoutSeconds 25
$javaProperties = if ($javaResult.Found) { Get-JavaProperties -Text $javaResult.Captured } else { [pscustomobject]@{} }
$activeJavaVersion = $null

if ($javaResult.Found) {
    $activeJavaVersion = Get-JavaVersionRecord -Text ([string](Get-PropertyValue -InputObject $javaProperties -Name 'java.version'))
    if ($null -eq $activeJavaVersion) {
        $activeJavaVersion = Get-JavaVersionRecord -Text $javaResult.Captured
    }

    $evidence.Add((New-AuditEvidence -EvidenceId 'java.runtime.properties' -Type command -Source 'java -XshowSettings:properties -version' -ExitCode $javaResult.ExitCode -Captured $javaResult.Captured -Redacted:$javaResult.Redacted -Attributes @{
        status          = $javaResult.Status
        truncated       = $javaResult.Truncated
        timedOut        = $javaResult.TimedOut
        resolutionCount = @($javaResult.Resolutions).Count
        javaVersion     = Get-PropertyValue -InputObject $javaProperties -Name 'java.version'
        javaHomeKnown   = -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -InputObject $javaProperties -Name 'java.home'))
        vendor          = Get-PropertyValue -InputObject $javaProperties -Name 'java.vendor'
        runtimeName     = Get-PropertyValue -InputObject $javaProperties -Name 'java.runtime.name'
        vmName          = Get-PropertyValue -InputObject $javaProperties -Name 'java.vm.name'
        architecture    = Get-PropertyValue -InputObject $javaProperties -Name 'os.arch'
    }))
}

$javacResult = Invoke-AuditCommand -Command 'javac' -Arguments @('-version') -TimeoutSeconds 20
$activeJavacVersion = if ($javacResult.Found) { Get-JavaVersionRecord -Text $javacResult.Captured } else { $null }

if ($javacResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'java.javac.version' -Type command -Source 'javac -version' -ExitCode $javacResult.ExitCode -Captured $javacResult.Captured -Redacted:$javacResult.Redacted -Attributes @{
        status          = $javacResult.Status
        truncated       = $javacResult.Truncated
        timedOut        = $javacResult.TimedOut
        resolutionCount = @($javacResult.Resolutions).Count
    }))
}

$candidates = New-Object System.Collections.Generic.List[object]

if (-not [string]::IsNullOrWhiteSpace($javaHome)) {
    Add-JavaCandidate -List $candidates -Path $javaHome -Source environment
}

$runtimeHome = [string](Get-PropertyValue -InputObject $javaProperties -Name 'java.home')
if (-not [string]::IsNullOrWhiteSpace($runtimeHome)) {
    Add-JavaCandidate -List $candidates -Path $runtimeHome -Source command
}

foreach ($resolution in @($javaResult.Resolutions)) {
    Add-JavaCandidate -List $candidates -Path (Get-JavaRootFromExecutable -Path ([string]$resolution.path)) -Source command
}

foreach ($resolution in @($javacResult.Resolutions)) {
    Add-JavaCandidate -List $candidates -Path (Get-JavaRootFromExecutable -Path ([string]$resolution.path)) -Source command
}

$registryPaths = @(
    'HKLM:\SOFTWARE\JavaSoft\JDK',
    'HKLM:\SOFTWARE\JavaSoft\Java Development Kit',
    'HKLM:\SOFTWARE\JavaSoft\JRE',
    'HKLM:\SOFTWARE\JavaSoft\Java Runtime Environment',
    'HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK',
    'HKLM:\SOFTWARE\WOW6432Node\JavaSoft\Java Development Kit',
    'HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JRE',
    'HKLM:\SOFTWARE\WOW6432Node\JavaSoft\Java Runtime Environment'
)

$registryRootCount = 0
foreach ($registryPath in $registryPaths) {
    if (-not (Test-Path -LiteralPath $registryPath)) {
        continue
    }

    try {
        foreach ($key in @(Get-ChildItem -LiteralPath $registryPath -ErrorAction Stop)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $properties) {
                continue
            }

            $javaHomeProperty = $properties.PSObject.Properties['JavaHome']
            $candidateHome = if ($null -ne $javaHomeProperty) { [string]$javaHomeProperty.Value } else { $null }
            if (-not [string]::IsNullOrWhiteSpace($candidateHome)) {
                Add-JavaCandidate -List $candidates -Path $candidateHome -Source registry
                $registryRootCount++
            }
        }
    }
    catch {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'JAVA_REGISTRY_ENUMERATION_PARTIAL' -Message "Java registry source '$registryPath' could not be enumerated completely." -Severity warning -ComponentId 'java' -EvidenceIds @('java.registry')))
    }
}

$evidence.Add((New-AuditEvidence -EvidenceId 'java.registry' -Type registry -Source 'JavaSoft JDK/JRE registry keys' -Captured $null -Attributes @{
    inspectedKeyCount = $registryPaths.Count
    discoveredRootCount = $registryRootCount
}))

$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$filesystemRoots = @(
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'Java' }),
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'Eclipse Adoptium' }),
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'Microsoft' }),
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'Amazon Corretto' }),
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'Zulu' }),
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'BellSoft' }),
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'RedHat' }),
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'IBM' }),
    $(if (-not [string]::IsNullOrWhiteSpace($programFiles)) { Join-Path $programFiles 'Semeru' })
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

$filesystemCandidateCount = 0
foreach ($root in $filesystemRoots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        continue
    }

    $rootMetadata = Get-JavaReleaseMetadata -RootPath $root
    if ($null -ne $rootMetadata) {
        Add-JavaCandidate -List $candidates -Path $root -Source filesystem
        $filesystemCandidateCount++
    }

    try {
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
            $metadata = Get-JavaReleaseMetadata -RootPath $directory.FullName
            if ($null -eq $metadata) {
                continue
            }

            Add-JavaCandidate -List $candidates -Path $directory.FullName -Source filesystem
            $filesystemCandidateCount++
        }
    }
    catch {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'JAVA_FILESYSTEM_ENUMERATION_PARTIAL' -Message "Java installation root '$root' could not be enumerated completely." -Severity warning -ComponentId 'java' -EvidenceIds @('java.filesystem')))
    }
}

$evidence.Add((New-AuditEvidence -EvidenceId 'java.filesystem' -Type filesystem -Source 'bounded known Java installation roots' -Captured $null -Attributes @{
    inspectedRootCount = $filesystemRoots.Count
    discoveredCandidateCount = $filesystemCandidateCount
}))

$metadataByPath = New-Object System.Collections.Generic.List[object]
foreach ($candidate in $candidates) {
    $metadata = Get-JavaReleaseMetadata -RootPath ([string]$candidate.path)
    if ($null -eq $metadata) {
        continue
    }

    $metadataByPath.Add([pscustomobject][ordered]@{
        path         = $metadata.path
        version      = $metadata.version
        majorVersion = $metadata.majorVersion
        vendor       = $metadata.vendor
        distribution = $metadata.distribution
        kind         = $metadata.kind
        architecture = $metadata.architecture
        sources      = @($candidate.sources)
    })
}

$activeJavaRoot = $runtimeHome
if ([string]::IsNullOrWhiteSpace($activeJavaRoot) -and @($javaResult.Resolutions).Count -gt 0) {
    $activeResolution = @($javaResult.Resolutions | Where-Object active | Select-Object -First 1)
    if ($activeResolution.Count -gt 0) {
        $activeJavaRoot = Get-JavaRootFromExecutable -Path ([string]$activeResolution[0].path)
    }
}

$javaVersions = New-Object System.Collections.Generic.List[object]
Add-UniqueVersion -List $javaVersions -Version $activeJavaVersion
foreach ($metadata in $metadataByPath) {
    Add-UniqueVersion -List $javaVersions -Version $metadata.version
}

$javaInstallations = @(
    $metadataByPath |
        ForEach-Object {
            [pscustomobject][ordered]@{
                path    = $_.path
                version = $_.version
                active  = $(if (-not [string]::IsNullOrWhiteSpace($activeJavaRoot)) { Test-PathEquals -Left $_.path -Right $activeJavaRoot } else { $false })
                source  = $(if ($_.sources -contains 'command') { 'command' } elseif ($_.sources -contains 'environment') { 'environment' } elseif ($_.sources -contains 'registry') { 'registry' } else { 'filesystem' })
            }
        }
)

$evidence.Add((New-AuditEvidence -EvidenceId 'java.installations' -Type derived -Source 'normalized Java installation metadata' -Captured $null -Attributes @{
    installations = @(
        $metadataByPath |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path         = $_.path
                    version      = $(if ($null -ne $_.version) { $_.version.normalized } else { $null })
                    majorVersion = $_.majorVersion
                    vendor       = $_.vendor
                    distribution = $_.distribution
                    kind         = $_.kind
                    architecture = $_.architecture
                    sources      = @($_.sources)
                }
            }
    )
}))

$javaState = 'missing'
$javaInstalled = $false

if ($javaResult.Found) {
    $javaState = 'present'
    $javaInstalled = $true

    if ($javaResult.Status -ne 'success' -or $null -eq $activeJavaVersion) {
        $javaState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'JAVA_RUNTIME_VERSION_INCOMPLETE' -Message 'Active Java runtime version detection was incomplete.' -Severity warning -ComponentId 'java' -EvidenceIds @('java.runtime.properties')))
    }
}
elseif ($metadataByPath.Count -gt 0) {
    $javaState = 'partial'
    $javaInstalled = $true
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'JAVA_COMMAND_UNRESOLVED' -Message 'Java installations were discovered but the java command is not resolvable.' -Severity warning -ComponentId 'java' -EvidenceIds @('java.installations')))
}

if (-not [string]::IsNullOrWhiteSpace($javaHome)) {
    $javaHomeMatch = @($metadataByPath | Where-Object { Test-PathEquals -Left $_.path -Right $javaHome })

    if ($javaHomeMatch.Count -eq 0) {
        $hasPartial = $true
        if ($javaState -eq 'present') {
            $javaState = 'partial'
        }
        $warnings.Add((New-AuditIssue -Code 'JAVA_HOME_UNRESOLVED' -Message 'JAVA_HOME is configured, but it does not resolve to a confirmed Java installation.' -Severity warning -ComponentId 'java' -EvidenceIds @('java.environment', 'java.installations')))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($activeJavaRoot) -and -not (Test-PathEquals -Left $javaHome -Right $activeJavaRoot)) {
        $hasPartial = $true
        if ($javaState -eq 'present') {
            $javaState = 'partial'
        }
        $warnings.Add((New-AuditIssue -Code 'JAVA_HOME_COMMAND_MISMATCH' -Message 'JAVA_HOME points to a different Java installation than the active java command.' -Severity warning -ComponentId 'java' -EvidenceIds @('java.environment', 'java.runtime.properties', 'java.installations')))
    }
}

$javaVersionIntelligence = New-NotApplicableVersionIntelligence

if ($javaInstalled -and $null -ne $activeJavaVersion) {
    $activeMetadata = @(
        $metadataByPath |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($activeJavaRoot) -and
                (Test-PathEquals -Left ([string]$_.path) -Right $activeJavaRoot)
            } |
            Select-Object -First 1
    )

    $activeVendor = [string](Get-PropertyValue -InputObject $javaProperties -Name 'java.vendor')
    $activeDistribution = $null
    $activeKind = 'jre'
    $activeArchitecture = [string](Get-PropertyValue -InputObject $javaProperties -Name 'os.arch')

    if ($activeMetadata.Count -eq 1) {
        if (-not [string]::IsNullOrWhiteSpace([string]$activeMetadata[0].vendor)) {
            $activeVendor = [string]$activeMetadata[0].vendor
        }
        $activeDistribution = [string]$activeMetadata[0].distribution
        if (-not [string]::IsNullOrWhiteSpace([string]$activeMetadata[0].kind)) {
            $activeKind = [string]$activeMetadata[0].kind
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$activeMetadata[0].architecture)) {
            $activeArchitecture = [string]$activeMetadata[0].architecture
        }
    }
    else {
        $activeDistribution = Get-JavaDistribution -Vendor $activeVendor -Path $activeJavaRoot

        if ($javacResult.Found -and $null -ne $activeJavacVersion -and -not [string]::IsNullOrWhiteSpace($activeJavaRoot)) {
            $activeJavacResolution = @(
                $javacResult.Resolutions |
                    Where-Object active |
                    Select-Object -First 1
            )

            if ($activeJavacResolution.Count -eq 1) {
                $activeJavacRoot = Get-JavaRootFromExecutable -Path ([string]$activeJavacResolution[0].path)
                if (Test-PathEquals -Left $activeJavacRoot -Right $activeJavaRoot) {
                    $activeKind = 'jdk'
                }
            }
        }
    }

    $activeMajor = Get-JavaMajorVersion -Version $activeJavaVersion
    if ($null -ne $activeMajor) {
        $sourceSpec = New-FoojayJavaVersionSource -MajorVersion $activeMajor -Distribution $activeDistribution -PackageType $activeKind -Architecture $activeArchitecture
        $decodedSource = Get-JavaVersionSource -Source $sourceSpec.source -Uri $sourceSpec.uri -EvidenceId 'java.version-intelligence.source'
        $javaVersionResult = Resolve-JavaVersionIntelligence -DecodedSource $decodedSource -InstalledVersion $activeJavaVersion -InstalledMajor $activeMajor -InstalledDistribution $activeDistribution -ExpectedDistribution $sourceSpec.expectedDistribution -PackageType $activeKind -Architecture $activeArchitecture
        $javaVersionIntelligence = $javaVersionResult.intelligence

        $evidence.Add((New-AuditEvidence -EvidenceId 'java.version-intelligence' -Type derived -Source 'Java same-major and distribution-context interpretation' -Captured $null -Attributes @{
            installedVersion = $activeJavaVersion.normalized
            installedMajor = $activeMajor
            installedVendor = $activeVendor
            installedDistribution = $activeDistribution
            installedPackageType = $activeKind
            installedArchitecture = $activeArchitecture
            expectedDistribution = $sourceSpec.expectedDistribution
            latestSameMajor = $(if ($javaVersionResult.latestSameMajor) { $javaVersionResult.latestSameMajor.normalized } else { $null })
            selectedDistribution = $javaVersionResult.selectedDistribution
            updateAvailable = $javaVersionResult.updateAvailable
            directReplacement = $javaVersionResult.directReplacement
            distributionMatched = $javaVersionResult.distributionMatched
            packageTypeMatched = $javaVersionResult.packageTypeMatched
            architectureMatched = $javaVersionResult.architectureMatched
            higherMajorObserved = $javaVersionResult.higherMajorObserved
            otherDistributionObserved = $javaVersionResult.otherDistributionObserved
            installedContexts = @(
                $metadataByPath |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            version = $(if ($null -ne $_.version) { $_.version.normalized } else { $null })
                            majorVersion = $_.majorVersion
                            vendor = $_.vendor
                            distribution = $_.distribution
                            kind = $_.kind
                            architecture = $_.architecture
                            active = $(if (-not [string]::IsNullOrWhiteSpace($activeJavaRoot)) { Test-PathEquals -Left ([string]$_.path) -Right $activeJavaRoot } else { $false })
                        }
                    }
            )
        }))
    }
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'java'
    name                = 'Java Runtime'
    state               = $javaState
    installed           = $javaInstalled
    activeVersion       = $activeJavaVersion
    discoveredVersions  = $javaVersions.ToArray()
    installations       = $javaInstallations
    commandResolutions  = @($javaResult.Resolutions)
    versionIntelligence = $javaVersionIntelligence
})

$jdkMetadata = @($metadataByPath | Where-Object kind -eq 'jdk')
$javacVersions = New-Object System.Collections.Generic.List[object]
Add-UniqueVersion -List $javacVersions -Version $activeJavacVersion
foreach ($metadata in $jdkMetadata) {
    Add-UniqueVersion -List $javacVersions -Version $metadata.version
}

$javacInstallations = @(
    $jdkMetadata |
        ForEach-Object {
            $jdkMetadataItem = $_
            [pscustomobject][ordered]@{
                path    = Join-Path $jdkMetadataItem.path 'bin\javac.exe'
                version = $jdkMetadataItem.version
                active  = @(
                    $javacResult.Resolutions |
                        Where-Object {
                            $_.active -and
                            (Test-PathEquals -Left $_.path -Right (Join-Path $jdkMetadataItem.path 'bin\javac.exe'))
                        }
                ).Count -gt 0
                source  = 'filesystem'
            }
        }
)

$javacState = if ($javacResult.Found) { 'present' } elseif ($jdkMetadata.Count -gt 0) { 'partial' } else { 'missing' }
$javacInstalled = if ($javacResult.Found -or $jdkMetadata.Count -gt 0) { $true } else { $false }

if ($javacResult.Found -and ($javacResult.Status -ne 'success' -or $null -eq $activeJavacVersion)) {
    $javacState = 'partial'
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'JAVAC_VERSION_INCOMPLETE' -Message 'javac is resolvable, but its version could not be determined reliably.' -Severity warning -ComponentId 'javac' -EvidenceIds @('java.javac.version')))
}
elseif (-not $javacResult.Found -and $jdkMetadata.Count -gt 0) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'JAVAC_COMMAND_UNRESOLVED' -Message 'JDK installations were discovered, but javac is not resolvable from the active command path.' -Severity warning -ComponentId 'javac' -EvidenceIds @('java.installations')))
}
elseif (-not $javacResult.Found -and $javaResult.Found) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'JAVAC_COMMAND_MISSING' -Message 'Java runtime is available, but javac is not resolvable. A complete developer JDK toolchain is not active.' -Severity warning -ComponentId 'javac' -EvidenceIds @('java.installations')))
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'javac'
    name                = 'Java Compiler'
    state               = $javacState
    installed           = $javacInstalled
    activeVersion       = $activeJavacVersion
    discoveredVersions  = $javacVersions.ToArray()
    installations       = $javacInstallations
    commandResolutions  = @($javacResult.Resolutions)
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$components.Add((New-SimpleCommandComponent -ComponentId 'maven' -Name 'Apache Maven' -Command 'mvn' -Arguments @('-version')))
$components.Add((New-SimpleCommandComponent -ComponentId 'gradle' -Name 'Gradle' -Command 'gradle' -Arguments @('--version')))

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
    providerId = 'java.jvm'
    category   = 'runtime'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
