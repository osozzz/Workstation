Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function New-RuntimeVersionRecord {
    param(
        [AllowNull()][string]$Value,
        [AllowNull()][string]$Channel
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmed = $Value.Trim().Trim('"')
    $normalized = $trimmed.TrimStart('v', 'V')

    if ($normalized -notmatch '^(?:1\.)?\d+(?:[._]\d+)*(?:[-+][0-9A-Za-z._-]+)?$') {
        return $null
    }

    return [pscustomobject][ordered]@{
        raw = $trimmed
        normalized = $normalized
        channel = $Channel
    }
}

function ConvertTo-VersionParts {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = $Value.Trim().TrimStart('v', 'V')

    if ($normalized -match '^1\.(?<legacyMajor>\d+)(?:\.0)?_(?<update>\d+)(?:[-+]b?(?<build>\d+))?') {
        return [pscustomobject][ordered]@{
            parts = @(
                [int]$Matches['legacyMajor'],
                0,
                [int]$Matches['update'],
                $(if ($Matches['build']) { [int]$Matches['build'] } else { 0 })
            )
        }
    }

    $build = 0
    if ($normalized -match '\+(?<build>\d+)') {
        $build = [int]$Matches['build']
    }

    $core = ($normalized -split '\+', 2)[0]
    $core = ($core -split '-', 2)[0]

    if ($core -notmatch '^\d+(?:\.\d+){0,3}$') {
        return $null
    }

    $parts = @($core -split '\.' | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) {
        $parts += 0
    }

    $parts += $build
    return [pscustomobject][ordered]@{
        parts = $parts
    }
}

function Compare-VersionText {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    $leftComparable = ConvertTo-VersionParts -Value $Left
    $rightComparable = ConvertTo-VersionParts -Value $Right

    if ($null -eq $leftComparable -or $null -eq $rightComparable) {
        return $null
    }

    $length = [Math]::Max($leftComparable.parts.Count, $rightComparable.parts.Count)
    for ($index = 0; $index -lt $length; $index++) {
        $leftPart = if ($index -lt $leftComparable.parts.Count) { [int]$leftComparable.parts[$index] } else { 0 }
        $rightPart = if ($index -lt $rightComparable.parts.Count) { [int]$rightComparable.parts[$index] } else { 0 }

        if ($leftPart -lt $rightPart) {
            return -1
        }
        if ($leftPart -gt $rightPart) {
            return 1
        }
    }

    return 0
}

function Test-VersionBehind {
    param(
        [AllowNull()][object]$InstalledVersion,
        [AllowNull()][object]$LatestVersion
    )

    if ($null -eq $InstalledVersion -or $null -eq $LatestVersion) {
        return $null
    }

    $comparison = Compare-VersionText -Left ([string]$InstalledVersion.normalized) -Right ([string]$LatestVersion.normalized)
    if ($null -eq $comparison) {
        return $null
    }

    return ($comparison -lt 0)
}

function Normalize-JavaArchitecture {
    param([AllowNull()][string]$Architecture)

    if ([string]::IsNullOrWhiteSpace($Architecture)) {
        return $null
    }

    switch -Regex ($Architecture.Trim().ToLowerInvariant()) {
        '^(x86_64|x86-64|amd64|x64)$' { return 'x64' }
        '^(aarch64|arm64)$' { return 'aarch64' }
        '^(x86|i[3-6]86|x86-32)$' { return 'x86' }
        default { return $Architecture.Trim().ToLowerInvariant() }
    }
}

function Get-FoojayDistributionSlug {
    param([AllowNull()][string]$Distribution)

    if ([string]::IsNullOrWhiteSpace($Distribution)) {
        return $null
    }

    switch ($Distribution.Trim()) {
        'Temurin' { return 'temurin' }
        'Corretto' { return 'corretto' }
        'Zulu' { return 'zulu' }
        'Liberica' { return 'liberica' }
        'Microsoft Build of OpenJDK' { return 'microsoft' }
        'Red Hat OpenJDK' { return 'redhat' }
        'Semeru' { return 'semeru' }
        'Oracle' { return 'oracle' }
        default { return $null }
    }
}

function New-FoojayJavaVersionSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$MajorVersion,
        [AllowNull()][string]$Distribution,
        [ValidateSet('jdk','jre')][string]$PackageType = 'jdk',
        [AllowNull()][string]$Architecture
    )

    $distributionSlug = Get-FoojayDistributionSlug -Distribution $Distribution
    $architectureSlug = Normalize-JavaArchitecture -Architecture $Architecture

    $pairs = New-Object System.Collections.Generic.List[string]
    $pairs.Add("version=$MajorVersion")
    $pairs.Add("package_type=$PackageType")
    $pairs.Add('operating_system=windows')
    $pairs.Add('release_status=ga')
    $pairs.Add('latest=available')

    if (-not [string]::IsNullOrWhiteSpace($distributionSlug)) {
        $pairs.Add("distro=$([uri]::EscapeDataString($distributionSlug))")
    }

    if (-not [string]::IsNullOrWhiteSpace($architectureSlug)) {
        $pairs.Add("architecture=$([uri]::EscapeDataString($architectureSlug))")
    }

    $contextDistribution = if ($distributionSlug) { $distributionSlug } else { 'any-distribution' }
    $contextArchitecture = if ($architectureSlug) { $architectureSlug } else { 'any-architecture' }

    return [pscustomobject][ordered]@{
        source = "foojay-disco:java-${MajorVersion}:${contextDistribution}:${PackageType}:${contextArchitecture}"
        uri = [uri]("https://api.foojay.io/disco/v3.0/packages?" + ($pairs -join '&'))
        expectedDistribution = $distributionSlug
        architecture = $architectureSlug
        packageType = $PackageType
        majorVersion = $MajorVersion
    }
}

function Resolve-FlutterVersionIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$DecodedSource,
        [AllowNull()][object]$InstalledVersion,
        [AllowNull()][string]$InstalledChannel
    )

    $installedOnStable = [string]::Equals(
        [string]$InstalledChannel,
        'stable',
        [StringComparison]::OrdinalIgnoreCase
    )
    $channelSwitchRequired = (
        -not [string]::IsNullOrWhiteSpace([string]$InstalledChannel) -and
        -not $installedOnStable
    )

    if ($DecodedSource.status -eq 'unavailable') {
        return [pscustomobject][ordered]@{
            intelligence = New-AuditVersionIntelligence -Status unavailable -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            updateAvailable = $null
            installedChannel = $InstalledChannel
            installedOnStable = $installedOnStable
            channelSwitchRequired = $channelSwitchRequired
        }
    }

    if ($DecodedSource.status -ne 'known' -or $null -eq $DecodedSource.data) {
        return [pscustomobject][ordered]@{
            intelligence = New-AuditVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            updateAvailable = $null
            installedChannel = $InstalledChannel
            installedOnStable = $installedOnStable
            channelSwitchRequired = $channelSwitchRequired
        }
    }

    $currentRelease = Get-OptionalPropertyValue -InputObject $DecodedSource.data -Name 'current_release'
    $stableHash = [string](Get-OptionalPropertyValue -InputObject $currentRelease -Name 'stable')
    $releasesValue = Get-OptionalPropertyValue -InputObject $DecodedSource.data -Name 'releases'
    $releases = @($releasesValue)

    $stableRelease = $null
    if (-not [string]::IsNullOrWhiteSpace($stableHash)) {
        $stableRelease = @(
            $releases |
                Where-Object {
                    [string]::Equals(
                        [string](Get-OptionalPropertyValue -InputObject $_ -Name 'hash'),
                        $stableHash,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Select-Object -First 1
        )
        if ($stableRelease.Count -gt 0) {
            $stableRelease = $stableRelease[0]
        }
        else {
            $stableRelease = $null
        }
    }

    if ($null -eq $stableRelease) {
        $stableRelease = @(
            $releases |
                Where-Object {
                    [string]::Equals(
                        [string](Get-OptionalPropertyValue -InputObject $_ -Name 'channel'),
                        'stable',
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Select-Object -First 1
        )
        if ($stableRelease.Count -gt 0) {
            $stableRelease = $stableRelease[0]
        }
        else {
            $stableRelease = $null
        }
    }

    $stableVersionText = [string](Get-OptionalPropertyValue -InputObject $stableRelease -Name 'version')
    $latestStable = New-RuntimeVersionRecord -Value $stableVersionText -Channel stable

    if ($null -eq $latestStable) {
        return [pscustomobject][ordered]@{
            intelligence = New-AuditVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'Flutter release metadata did not contain an interpretable stable release.'
            latestStable = $null
            updateAvailable = $null
            installedChannel = $InstalledChannel
            installedOnStable = $installedOnStable
            channelSwitchRequired = $channelSwitchRequired
        }
    }

    $updateAvailable = if ($installedOnStable) {
        Test-VersionBehind -InstalledVersion $InstalledVersion -LatestVersion $latestStable
    }
    else {
        $null
    }

    $message = if ($installedOnStable) {
        'Flutter stable-channel intelligence is compared only against an installed stable-channel SDK.'
    }
    elseif ($channelSwitchRequired) {
        'Latest Flutter stable is reported for reference; the installed SDK is on another channel and no automatic channel switch is implied.'
    }
    else {
        'Latest Flutter stable is known; installed channel comparison is unavailable.'
    }

    return [pscustomobject][ordered]@{
        intelligence = New-AuditVersionIntelligence -Status known -LatestStable $latestStable -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $message
        latestStable = $latestStable
        updateAvailable = $updateAvailable
        installedChannel = $InstalledChannel
        installedOnStable = $installedOnStable
        channelSwitchRequired = $channelSwitchRequired
    }
}

function Resolve-JavaVersionIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$DecodedSource,
        [AllowNull()][object]$InstalledVersion,
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$InstalledMajor,
        [AllowNull()][string]$InstalledDistribution,
        [AllowNull()][string]$ExpectedDistribution,
        [ValidateSet('jdk','jre')][string]$PackageType = 'jdk',
        [AllowNull()][string]$Architecture
    )

    $baseResult = [ordered]@{
        latestSameMajor = $null
        selectedDistribution = $null
        updateAvailable = $null
        sameMajor = $false
        distributionMatched = $false
        packageTypeMatched = $false
        architectureMatched = $false
        directReplacement = $false
        higherMajorObserved = $false
        otherDistributionObserved = $false
        installedMajor = $InstalledMajor
        installedDistribution = $InstalledDistribution
        packageType = $PackageType
        architecture = Normalize-JavaArchitecture -Architecture $Architecture
    }

    if ($DecodedSource.status -eq 'unavailable') {
        $baseResult['intelligence'] = New-AuditVersionIntelligence -Status unavailable -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
        return [pscustomobject]$baseResult
    }

    if ($DecodedSource.status -ne 'known' -or $null -eq $DecodedSource.data) {
        $baseResult['intelligence'] = New-AuditVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
        return [pscustomobject]$baseResult
    }

    $resultValue = Get-OptionalPropertyValue -InputObject $DecodedSource.data -Name 'result'
    $packages = @($resultValue)
    $sameMajorCandidates = @()
    $expectedDistributionCandidates = @()

    foreach ($package in $packages) {
        $majorValue = Get-OptionalPropertyValue -InputObject $package -Name 'major_version'
        [int]$major = 0
        if ($null -eq $majorValue -or -not [int]::TryParse([string]$majorValue, [ref]$major)) {
            continue
        }

        if ($major -gt $InstalledMajor) {
            $baseResult['higherMajorObserved'] = $true
        }

        $distribution = [string](Get-OptionalPropertyValue -InputObject $package -Name 'distribution')
        if (
            -not [string]::IsNullOrWhiteSpace($ExpectedDistribution) -and
            -not [string]::Equals($distribution, $ExpectedDistribution, [StringComparison]::OrdinalIgnoreCase)
        ) {
            $baseResult['otherDistributionObserved'] = $true
        }

        if ($major -ne $InstalledMajor) {
            continue
        }

        $releaseStatus = [string](Get-OptionalPropertyValue -InputObject $package -Name 'release_status')
        if (
            -not [string]::IsNullOrWhiteSpace($releaseStatus) -and
            -not [string]::Equals($releaseStatus, 'ga', [StringComparison]::OrdinalIgnoreCase)
        ) {
            continue
        }

        $versionText = [string](Get-OptionalPropertyValue -InputObject $package -Name 'java_version')
        $versionRecord = New-RuntimeVersionRecord -Value $versionText -Channel stable
        $parts = ConvertTo-VersionParts -Value $versionText
        if ($null -eq $versionRecord -or $null -eq $parts) {
            continue
        }

        $candidate = [pscustomobject][ordered]@{
            package = $package
            distribution = $distribution
            version = $versionRecord
            parts = $parts.parts
        }
        $sameMajorCandidates += $candidate

        if (
            -not [string]::IsNullOrWhiteSpace($ExpectedDistribution) -and
            [string]::Equals($distribution, $ExpectedDistribution, [StringComparison]::OrdinalIgnoreCase)
        ) {
            $expectedDistributionCandidates += $candidate
        }
    }

    if ($sameMajorCandidates.Count -eq 0) {
        $message = if ($baseResult['higherMajorObserved']) {
            'Java source data contains newer majors, but none are treated as a direct replacement for the installed major.'
        }
        else {
            'Java source data did not contain a relevant GA release for the installed major.'
        }
        $baseResult['intelligence'] = New-AuditVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $message
        return [pscustomobject]$baseResult
    }

    $candidatePool = if ($expectedDistributionCandidates.Count -gt 0) {
        $expectedDistributionCandidates
    }
    else {
        $sameMajorCandidates
    }

    $selected = $candidatePool[0]
    foreach ($candidate in $candidatePool) {
        $comparison = Compare-VersionText -Left ([string]$selected.version.normalized) -Right ([string]$candidate.version.normalized)
        if ($null -ne $comparison -and $comparison -lt 0) {
            $selected = $candidate
        }
    }

    $selectedPackageType = [string](Get-OptionalPropertyValue -InputObject $selected.package -Name 'package_type')
    $selectedArchitecture = Normalize-JavaArchitecture -Architecture ([string](Get-OptionalPropertyValue -InputObject $selected.package -Name 'architecture'))

    $baseResult['latestSameMajor'] = $selected.version
    $baseResult['selectedDistribution'] = $selected.distribution
    $baseResult['sameMajor'] = $true
    $baseResult['distributionMatched'] = (
        -not [string]::IsNullOrWhiteSpace($ExpectedDistribution) -and
        [string]::Equals($selected.distribution, $ExpectedDistribution, [StringComparison]::OrdinalIgnoreCase)
    )
    $baseResult['packageTypeMatched'] = (
        -not [string]::IsNullOrWhiteSpace($selectedPackageType) -and
        [string]::Equals($selectedPackageType, $PackageType, [StringComparison]::OrdinalIgnoreCase)
    )

    $normalizedInstalledArchitecture = Normalize-JavaArchitecture -Architecture $Architecture
    $baseResult['architectureMatched'] = (
        -not [string]::IsNullOrWhiteSpace($normalizedInstalledArchitecture) -and
        -not [string]::IsNullOrWhiteSpace($selectedArchitecture) -and
        [string]::Equals($selectedArchitecture, $normalizedInstalledArchitecture, [StringComparison]::OrdinalIgnoreCase)
    )

    $baseResult['directReplacement'] = (
        $baseResult['sameMajor'] -and
        $baseResult['distributionMatched'] -and
        $baseResult['packageTypeMatched'] -and
        $baseResult['architectureMatched']
    )

    if ($baseResult['directReplacement']) {
        $baseResult['updateAvailable'] = Test-VersionBehind -InstalledVersion $InstalledVersion -LatestVersion $selected.version
    }

    $message = if ($baseResult['directReplacement']) {
        'Java latest information matches the installed major, distribution, package type, and architecture; project compatibility still takes precedence.'
    }
    elseif ($baseResult['distributionMatched']) {
        'Java same-major information is available, but the package context does not fully match the installed runtime and is not treated as a direct replacement.'
    }
    else {
        'Java same-major information is available from another or unspecified distribution and is informational only, not a direct replacement.'
    }

    $baseResult['intelligence'] = New-AuditVersionIntelligence -Status known -LatestStable $selected.version -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $message
    return [pscustomobject]$baseResult
}

Export-ModuleMember -Function @(
    'New-FoojayJavaVersionSource',
    'Resolve-FlutterVersionIntelligence',
    'Resolve-JavaVersionIntelligence'
)
