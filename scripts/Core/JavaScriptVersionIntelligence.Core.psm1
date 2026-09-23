Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-JavaScriptVersionIntelligence {
    param(
        [Parameter(Mandatory)][ValidateSet('known','unknown','unavailable')][string]$Status,
        [AllowNull()][object]$LatestStable,
        [AllowNull()][object]$LatestLts,
        [AllowNull()][object]$LatestCurrent,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$CheckedAt,
        [AllowNull()][string]$Message
    )

    [pscustomobject][ordered]@{
        status = $Status
        latestStable = $LatestStable
        latestLts = $LatestLts
        latestCurrent = $LatestCurrent
        source = $Source
        checkedAt = $CheckedAt
        message = $Message
    }
}

function ConvertTo-ComparableVersion {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $normalized = $Value.Trim()
    if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }

    if ($normalized -match '[-+]') {
        return $null
    }

    [version]$parsed = $null
    if (-not [version]::TryParse($normalized, [ref]$parsed)) {
        return $null
    }

    return $parsed
}

function ConvertTo-VersionRecord {
    param(
        [AllowNull()][string]$Value,
        [AllowNull()][string]$Channel
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmed = $Value.Trim()
    $normalized = $trimmed.TrimStart('v', 'V')
    if ($normalized -notmatch '^\d+(?:\.\d+){1,3}(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        return $null
    }

    return [pscustomobject][ordered]@{
        raw = $trimmed
        normalized = $normalized
        channel = $Channel
    }
}

function Test-VersionBehind {
    param(
        [AllowNull()][object]$InstalledVersion,
        [AllowNull()][object]$LatestVersion
    )

    if ($null -eq $InstalledVersion -or $null -eq $LatestVersion) {
        return $null
    }

    $installed = ConvertTo-ComparableVersion -Value ([string]$InstalledVersion.normalized)
    $latest = ConvertTo-ComparableVersion -Value ([string]$LatestVersion.normalized)

    if ($null -eq $installed -or $null -eq $latest) {
        return $null
    }

    return ($installed -lt $latest)
}

function Resolve-NodeVersionIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$DecodedSource,
        [AllowNull()][object]$InstalledVersion
    )

    if ($DecodedSource.status -eq 'unavailable') {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unavailable -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestLts = $null
            latestCurrent = $null
            installedBehindLts = $null
            installedBehindCurrent = $null
            policyDefaultChannel = 'lts'
            currentIsMandatoryReplacement = $false
        }
    }

    if ($DecodedSource.status -ne 'known' -or $null -eq $DecodedSource.data) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestLts = $null
            latestCurrent = $null
            installedBehindLts = $null
            installedBehindCurrent = $null
            policyDefaultChannel = 'lts'
            currentIsMandatoryReplacement = $false
        }
    }

    $releases = @($DecodedSource.data)
    $ltsCandidates = New-Object System.Collections.Generic.List[object]
    $currentCandidates = New-Object System.Collections.Generic.List[object]

    foreach ($release in $releases) {
        $versionProperty = $release.PSObject.Properties['version']
        if ($null -eq $versionProperty) {
            continue
        }

        $value = [string]$versionProperty.Value
        $comparable = ConvertTo-ComparableVersion -Value $value
        if ($null -eq $comparable) {
            continue
        }

        $ltsProperty = $release.PSObject.Properties['lts']
        $ltsValue = if ($ltsProperty) { $ltsProperty.Value } else { $false }

        $isLts = (
            $null -ne $ltsValue -and
            $ltsValue -ne $false -and
            -not [string]::IsNullOrWhiteSpace([string]$ltsValue)
        )

        $candidate = [pscustomobject][ordered]@{
            comparable = $comparable
            record = ConvertTo-VersionRecord -Value $value -Channel $(if ($isLts) { 'lts' } else { 'current' })
        }

        if ($isLts) {
            $ltsCandidates.Add($candidate)
        }
        else {
            $currentCandidates.Add($candidate)
        }
    }

    $latestLtsCandidate = @($ltsCandidates | Sort-Object comparable -Descending | Select-Object -First 1)
    $latestCurrentCandidate = @($currentCandidates | Sort-Object comparable -Descending | Select-Object -First 1)

    $latestLts = if ($latestLtsCandidate.Count -gt 0) { $latestLtsCandidate[0].record } else { $null }
    $latestCurrent = if ($latestCurrentCandidate.Count -gt 0) { $latestCurrentCandidate[0].record } else { $null }

    if ($null -eq $latestLts -and $null -eq $latestCurrent) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'Node release metadata did not contain interpretable stable release records.'
            latestLts = $null
            latestCurrent = $null
            installedBehindLts = $null
            installedBehindCurrent = $null
            policyDefaultChannel = 'lts'
            currentIsMandatoryReplacement = $false
        }
    }

    $intelligence = New-JavaScriptVersionIntelligence -Status known -LatestStable $null -LatestLts $latestLts -LatestCurrent $latestCurrent -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'Node LTS remains the configured default channel; Current is reported separately and is not a mandatory replacement.'

    return [pscustomobject][ordered]@{
        intelligence = $intelligence
        latestLts = $latestLts
        latestCurrent = $latestCurrent
        installedBehindLts = Test-VersionBehind -InstalledVersion $InstalledVersion -LatestVersion $latestLts
        installedBehindCurrent = Test-VersionBehind -InstalledVersion $InstalledVersion -LatestVersion $latestCurrent
        policyDefaultChannel = 'lts'
        currentIsMandatoryReplacement = $false
    }
}

function Resolve-NpmPackageVersionIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('npm', 'pnpm')][string]$PackageName,
        [Parameter(Mandatory)][psobject]$DecodedSource,
        [AllowNull()][object]$InstalledVersion
    )

    if ($DecodedSource.status -eq 'unavailable') {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unavailable -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            updateAvailable = $null
        }
    }

    if ($DecodedSource.status -ne 'known' -or $null -eq $DecodedSource.data) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            updateAvailable = $null
        }
    }

    $versionProperty = $DecodedSource.data.PSObject.Properties['version']
    $latest = if ($versionProperty) {
        ConvertTo-VersionRecord -Value ([string]$versionProperty.Value) -Channel stable
    }
    else {
        $null
    }

    if ($null -eq $latest) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message "$PackageName registry metadata did not contain an interpretable stable version."
            latestStable = $null
            updateAvailable = $null
        }
    }

    $updateAvailable = Test-VersionBehind -InstalledVersion $InstalledVersion -LatestVersion $latest
    $message = if ($updateAvailable -eq $true) {
        "A newer stable $PackageName version is available."
    }
    elseif ($updateAvailable -eq $false) {
        "Installed $PackageName is at or ahead of the reported stable version."
    }
    else {
        "Latest stable $PackageName is known; installed-version comparison is unavailable."
    }

    return [pscustomobject][ordered]@{
        intelligence = New-JavaScriptVersionIntelligence -Status known -LatestStable $latest -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $message
        latestStable = $latest
        updateAvailable = $updateAvailable
    }
}


function Get-DistTagValue {
    param(
        [AllowNull()][object]$Data,
        [Parameter(Mandatory)][string]$Tag
    )

    if ($null -eq $Data) {
        return $null
    }

    foreach ($property in @($Data.PSObject.Properties)) {
        if ([string]::Equals([string]$property.Name, $Tag, [StringComparison]::OrdinalIgnoreCase)) {
            if ($null -eq $property.Value -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return $null
            }

            return [string]$property.Value
        }
    }

    return $null
}

function Get-StableDistTagVersionRecord {
    param(
        [AllowNull()][object]$Data,
        [string]$Tag = 'latest'
    )

    $value = Get-DistTagValue -Data $Data -Tag $Tag
    if ($null -eq (ConvertTo-ComparableVersion -Value $value)) {
        return $null
    }

    return ConvertTo-VersionRecord -Value $value -Channel stable
}

function Get-PrereleaseDistTagRecord {
    param(
        [AllowNull()][object]$Data,
        [Parameter(Mandatory)][string[]]$PreferredTags
    )

    foreach ($tag in $PreferredTags) {
        $value = Get-DistTagValue -Data $Data -Tag $tag
        if ([string]::IsNullOrWhiteSpace($value) -or $value -notmatch '-') {
            continue
        }

        $record = ConvertTo-VersionRecord -Value $value -Channel $tag
        if ($null -ne $record) {
            return [pscustomobject][ordered]@{
                tag = $tag
                version = $record
            }
        }
    }

    return $null
}

function Resolve-AngularCliVersionIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$DecodedSource,
        [AllowNull()][object]$InstalledVersion
    )

    if ($DecodedSource.status -eq 'unavailable') {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unavailable -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            updateAvailable = $null
            majorMigrationRequiresExplicitAction = $true
            projectCompatibilityOverridesGlobal = $true
        }
    }

    if ($DecodedSource.status -ne 'known' -or $null -eq $DecodedSource.data) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            updateAvailable = $null
            majorMigrationRequiresExplicitAction = $true
            projectCompatibilityOverridesGlobal = $true
        }
    }

    $latestStable = Get-StableDistTagVersionRecord -Data $DecodedSource.data
    if ($null -eq $latestStable) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'Angular CLI dist-tags did not contain an interpretable latest stable version.'
            latestStable = $null
            updateAvailable = $null
            majorMigrationRequiresExplicitAction = $true
            projectCompatibilityOverridesGlobal = $true
        }
    }

    $updateAvailable = Test-VersionBehind -InstalledVersion $InstalledVersion -LatestVersion $latestStable
    $message = if ($updateAvailable -eq $true) {
        'A newer stable Angular CLI release is available; major migrations remain explicit and project compatibility takes precedence.'
    }
    elseif ($updateAvailable -eq $false) {
        'Installed Angular CLI is at or ahead of the reported stable release; project compatibility still takes precedence.'
    }
    else {
        'Latest stable Angular CLI is known; installed-version comparison is unavailable and project compatibility takes precedence.'
    }

    return [pscustomobject][ordered]@{
        intelligence = New-JavaScriptVersionIntelligence -Status known -LatestStable $latestStable -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $message
        latestStable = $latestStable
        updateAvailable = $updateAvailable
        majorMigrationRequiresExplicitAction = $true
        projectCompatibilityOverridesGlobal = $true
    }
}

function Resolve-TypeScriptVersionIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$DecodedSource,
        [AllowNull()][object]$InstalledVersion
    )

    if ($DecodedSource.status -eq 'unavailable') {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unavailable -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            latestPrerelease = $null
            prereleaseTag = $null
            stableUpdateAvailable = $null
            prereleaseRequiresExplicitOptIn = $true
            projectCompatibilityOverridesGlobal = $true
        }
    }

    if ($DecodedSource.status -ne 'known' -or $null -eq $DecodedSource.data) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            latestPrerelease = $null
            prereleaseTag = $null
            stableUpdateAvailable = $null
            prereleaseRequiresExplicitOptIn = $true
            projectCompatibilityOverridesGlobal = $true
        }
    }

    $latestStable = Get-StableDistTagVersionRecord -Data $DecodedSource.data
    $prerelease = Get-PrereleaseDistTagRecord -Data $DecodedSource.data -PreferredTags @('next', 'rc', 'beta', 'dev', 'insiders')

    if ($null -eq $latestStable -and $null -eq $prerelease) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'TypeScript dist-tags did not contain interpretable stable or prerelease versions.'
            latestStable = $null
            latestPrerelease = $null
            prereleaseTag = $null
            stableUpdateAvailable = $null
            prereleaseRequiresExplicitOptIn = $true
            projectCompatibilityOverridesGlobal = $true
        }
    }

    $latestPrerelease = if ($null -ne $prerelease) { $prerelease.version } else { $null }
    $prereleaseTag = if ($null -ne $prerelease) { $prerelease.tag } else { $null }
    $stableUpdateAvailable = Test-VersionBehind -InstalledVersion $InstalledVersion -LatestVersion $latestStable

    return [pscustomobject][ordered]@{
        intelligence = New-JavaScriptVersionIntelligence -Status known -LatestStable $latestStable -LatestLts $null -LatestCurrent $latestPrerelease -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'TypeScript stable and prerelease channels are reported separately; prerelease adoption requires explicit opt-in and project compatibility takes precedence.'
        latestStable = $latestStable
        latestPrerelease = $latestPrerelease
        prereleaseTag = $prereleaseTag
        stableUpdateAvailable = $stableUpdateAvailable
        prereleaseRequiresExplicitOptIn = $true
        projectCompatibilityOverridesGlobal = $true
    }
}

function Get-PrismaReleaseCandidateRecord {
    param([AllowNull()][object]$Data)

    if ($null -eq $Data) {
        return $null
    }

    $exactRcValue = Get-DistTagValue -Data $Data -Tag 'rc'
    if (-not [string]::IsNullOrWhiteSpace($exactRcValue)) {
        $record = ConvertTo-VersionRecord -Value $exactRcValue -Channel rc
        if ($null -ne $record -and $record.normalized -match '(?i)-.*rc') {
            return [pscustomobject][ordered]@{
                tag = 'rc'
                version = $record
            }
        }
    }

    foreach ($property in @($Data.PSObject.Properties)) {
        $tag = [string]$property.Name
        $value = [string]$property.Value
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        $isRcTag = $tag -match '(?i)(^|[-_.])rc($|[-_.0-9])'
        $isRcVersion = $value -match '(?i)-[^+]*rc(?:[.-]|$)'
        if (-not $isRcTag -and -not $isRcVersion) {
            continue
        }

        $record = ConvertTo-VersionRecord -Value $value -Channel $tag
        if ($null -ne $record) {
            return [pscustomobject][ordered]@{
                tag = $tag
                version = $record
            }
        }
    }

    return $null
}

function Resolve-PrismaVersionIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$DecodedSource,
        [AllowNull()][object]$InstalledVersion
    )

    if ($DecodedSource.status -eq 'unavailable') {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unavailable -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            latestReleaseCandidate = $null
            releaseCandidateTag = $null
            stableUpdateAvailable = $null
            releaseCandidateRequiresExplicitOptIn = $true
            projectPinsOverrideGlobal = $true
        }
    }

    if ($DecodedSource.status -ne 'known' -or $null -eq $DecodedSource.data) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            latestReleaseCandidate = $null
            releaseCandidateTag = $null
            stableUpdateAvailable = $null
            releaseCandidateRequiresExplicitOptIn = $true
            projectPinsOverrideGlobal = $true
        }
    }

    $latestStable = Get-StableDistTagVersionRecord -Data $DecodedSource.data
    $releaseCandidate = Get-PrismaReleaseCandidateRecord -Data $DecodedSource.data

    if ($null -eq $latestStable -and $null -eq $releaseCandidate) {
        return [pscustomobject][ordered]@{
            intelligence = New-JavaScriptVersionIntelligence -Status unknown -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'Prisma dist-tags did not contain interpretable stable or release-candidate versions.'
            latestStable = $null
            latestReleaseCandidate = $null
            releaseCandidateTag = $null
            stableUpdateAvailable = $null
            releaseCandidateRequiresExplicitOptIn = $true
            projectPinsOverrideGlobal = $true
        }
    }

    $latestReleaseCandidate = if ($null -ne $releaseCandidate) { $releaseCandidate.version } else { $null }
    $releaseCandidateTag = if ($null -ne $releaseCandidate) { $releaseCandidate.tag } else { $null }
    $stableUpdateAvailable = Test-VersionBehind -InstalledVersion $InstalledVersion -LatestVersion $latestStable

    return [pscustomobject][ordered]@{
        intelligence = New-JavaScriptVersionIntelligence -Status known -LatestStable $latestStable -LatestLts $null -LatestCurrent $latestReleaseCandidate -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'Prisma stable and release-candidate channels are reported separately; release candidates require explicit opt-in and project-local pins take precedence.'
        latestStable = $latestStable
        latestReleaseCandidate = $latestReleaseCandidate
        releaseCandidateTag = $releaseCandidateTag
        stableUpdateAvailable = $stableUpdateAvailable
        releaseCandidateRequiresExplicitOptIn = $true
        projectPinsOverrideGlobal = $true
    }
}

Export-ModuleMember -Function @(
    'Resolve-NodeVersionIntelligence',
    'Resolve-NpmPackageVersionIntelligence',
    'Resolve-AngularCliVersionIntelligence',
    'Resolve-TypeScriptVersionIntelligence',
    'Resolve-PrismaVersionIntelligence'
)
