Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Audit.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VersionIntelligence.Core.psm1') -Force

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

    $parsed = ConvertTo-ComparableVersion -Value $Value
    if ($null -eq $parsed) {
        return $null
    }

    $normalized = $Value.Trim().TrimStart('v', 'V')
    return New-AuditVersionRecord -Raw $Value.Trim() -Normalized $normalized -Channel $Channel
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
            intelligence = New-AuditVersionIntelligence -Status unavailable -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
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
            intelligence = New-AuditVersionIntelligence -Status unknown -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
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
            intelligence = New-AuditVersionIntelligence -Status unknown -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'Node release metadata did not contain interpretable stable release records.'
            latestLts = $null
            latestCurrent = $null
            installedBehindLts = $null
            installedBehindCurrent = $null
            policyDefaultChannel = 'lts'
            currentIsMandatoryReplacement = $false
        }
    }

    $intelligence = New-AuditVersionIntelligence -Status known -LatestLts $latestLts -LatestCurrent $latestCurrent -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message 'Node LTS remains the configured default channel; Current is reported separately and is not a mandatory replacement.'

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
            intelligence = New-AuditVersionIntelligence -Status unavailable -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
            latestStable = $null
            updateAvailable = $null
        }
    }

    if ($DecodedSource.status -ne 'known' -or $null -eq $DecodedSource.data) {
        return [pscustomobject][ordered]@{
            intelligence = New-AuditVersionIntelligence -Status unknown -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $DecodedSource.message
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
            intelligence = New-AuditVersionIntelligence -Status unknown -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message "$PackageName registry metadata did not contain an interpretable stable version."
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
        intelligence = New-AuditVersionIntelligence -Status known -LatestStable $latest -Source $DecodedSource.source -CheckedAt $DecodedSource.checkedAt -Message $message
        latestStable = $latest
        updateAvailable = $updateAvailable
    }
}

Export-ModuleMember -Function @(
    'Resolve-NodeVersionIntelligence',
    'Resolve-NpmPackageVersionIntelligence'
)
