[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$versionCore = Join-Path $root 'scripts\Core\VersionIntelligence.Core.psm1'
$jvmMobileCore = Join-Path $root 'scripts\Core\JvmMobileVersionIntelligence.Core.psm1'
$javaProvider = Join-Path $root 'scripts\Providers\JavaJvmToolchain.Provider.ps1'
$flutterProvider = Join-Path $root 'scripts\Providers\FlutterAndroidToolchain.Provider.ps1'

Import-Module $versionCore -Force
Import-Module $jvmMobileCore -Force

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestVersionRecord {
    param(
        [Parameter(Mandatory)][string]$Version,
        [AllowNull()][string]$Channel
    )

    [pscustomobject][ordered]@{
        raw = $Version
        normalized = $Version.TrimStart('v', 'V')
        channel = $Channel
    }
}

function New-Decoded {
    param(
        [Parameter(Mandatory)][string]$Source,
        [AllowNull()][object]$Data,
        [ValidateSet('known','unknown','unavailable')][string]$Status = 'known'
    )

    [pscustomobject][ordered]@{
        status = $Status
        source = $Source
        checkedAt = '2026-09-23T17:15:00.0000000+00:00'
        data = $(if ($Status -eq 'known') { $Data } else { $null })
        message = $(if ($Status -eq 'known') { $null } else { 'synthetic unavailable' })
    }
}

$flutterData = [pscustomobject][ordered]@{
    current_release = [pscustomobject][ordered]@{
        stable = 'stable-hash'
        beta = 'beta-hash'
    }
    releases = @(
        [pscustomobject][ordered]@{
            hash = 'stable-hash'
            channel = 'stable'
            version = '3.50.1'
            dart_sdk_version = '3.12.0'
        },
        [pscustomobject][ordered]@{
            hash = 'beta-hash'
            channel = 'beta'
            version = '3.51.0-0.1.pre'
            dart_sdk_version = '3.13.0'
        }
    )
}

$flutterOutdated = Resolve-FlutterVersionIntelligence -DecodedSource (New-Decoded -Source 'flutter-sdk-archive:windows' -Data $flutterData) -InstalledVersion (New-TestVersionRecord -Version '3.47.2' -Channel stable) -InstalledChannel stable

Assert-True ($flutterOutdated.intelligence.status -eq 'known') 'Flutter intelligence must be known.'
Assert-True ($flutterOutdated.latestStable.normalized -eq '3.50.1') 'Flutter must report the archive current stable release.'
Assert-True ($flutterOutdated.latestStable.channel -eq 'stable') 'Flutter latest release must retain the stable channel.'
Assert-True ($flutterOutdated.updateAvailable -eq $true) 'Synthetic stable Flutter install should report a stable update.'
Assert-True ($flutterOutdated.installedOnStable -eq $true) 'Stable Flutter install must retain local channel evidence.'
Assert-True ($flutterOutdated.channelSwitchRequired -eq $false) 'Stable Flutter comparison must not imply a channel switch.'
Assert-True ($flutterOutdated.intelligence.source -eq 'flutter-sdk-archive:windows') 'Flutter source identity must be explicit.'
Assert-True ($flutterOutdated.intelligence.checkedAt -eq '2026-09-23T17:15:00.0000000+00:00') 'Flutter checkedAt must be explicit.'

$flutterCurrent = Resolve-FlutterVersionIntelligence -DecodedSource (New-Decoded -Source 'flutter-sdk-archive:windows' -Data $flutterData) -InstalledVersion (New-TestVersionRecord -Version '3.50.1' -Channel stable) -InstalledChannel stable
Assert-True ($flutterCurrent.updateAvailable -eq $false) 'Current stable Flutter must not report an update.'

$flutterBeta = Resolve-FlutterVersionIntelligence -DecodedSource (New-Decoded -Source 'flutter-sdk-archive:windows' -Data $flutterData) -InstalledVersion (New-TestVersionRecord -Version '3.51.0-0.1.pre' -Channel beta) -InstalledChannel beta
Assert-True ($flutterBeta.intelligence.latestStable.normalized -eq '3.50.1') 'Flutter beta install must still expose stable reference information.'
Assert-True ($null -eq $flutterBeta.updateAvailable) 'Flutter beta must not be compared as a direct stable upgrade.'
Assert-True ($flutterBeta.installedOnStable -eq $false) 'Flutter beta must remain a distinct local channel.'
Assert-True ($flutterBeta.channelSwitchRequired -eq $true) 'Flutter beta to stable requires an explicit channel switch.'
Assert-True ($flutterBeta.intelligence.message -match 'no automatic channel switch') 'Flutter non-stable message must reject implicit channel switching.'

$offlineFlutter = Resolve-FlutterVersionIntelligence -DecodedSource (New-Decoded -Source 'flutter-sdk-archive:windows' -Data $null -Status unavailable) -InstalledVersion (New-TestVersionRecord -Version '3.47.2' -Channel stable) -InstalledChannel stable
Assert-True ($offlineFlutter.intelligence.status -eq 'unavailable') 'Offline Flutter intelligence must be unavailable.'
Assert-True ($null -eq $offlineFlutter.latestStable) 'Offline Flutter must not fabricate a stable version.'
Assert-True ($offlineFlutter.installedOnStable -eq $true) 'Offline Flutter must preserve local stable-channel evidence.'
Assert-True ($offlineFlutter.channelSwitchRequired -eq $false) 'Offline stable Flutter must not imply a channel switch.'

$temurinSource = New-FoojayJavaVersionSource -MajorVersion 17 -Distribution 'Temurin' -PackageType jdk -Architecture amd64
Assert-True ($temurinSource.source -eq 'foojay-disco:java-17:temurin:jdk:x64') 'Java source identity must encode the installed context.'
Assert-True ($temurinSource.uri.AbsoluteUri -match 'version=17') 'Java source URI must preserve the installed major.'
Assert-True ($temurinSource.uri.AbsoluteUri -match 'distro=temurin') 'Java source URI must preserve the mapped distribution.'
Assert-True ($temurinSource.uri.AbsoluteUri -match 'package_type=jdk') 'Java source URI must preserve JDK versus JRE context.'
Assert-True ($temurinSource.uri.AbsoluteUri -match 'architecture=x64') 'Java source URI must normalize architecture.'
Assert-True ($temurinSource.uri.AbsoluteUri -match 'release_status=ga') 'Java source URI must request GA releases.'

$unknownSource = New-FoojayJavaVersionSource -MajorVersion 17 -Distribution 'Unknown Distribution' -PackageType jdk -Architecture x64
Assert-True ($unknownSource.source -match 'any-distribution') 'Unknown Java distribution must remain explicit.'
Assert-True ($unknownSource.uri.AbsoluteUri -notmatch 'distro=') 'Unknown Java distribution must not be guessed.'

$javaData = [pscustomobject][ordered]@{
    result = @(
        [pscustomobject][ordered]@{
            distribution = 'temurin'
            major_version = 17
            java_version = '17.0.17+10'
            release_status = 'ga'
            package_type = 'jdk'
            architecture = 'x64'
        },
        [pscustomobject][ordered]@{
            distribution = 'microsoft'
            major_version = 17
            java_version = '17.0.18+8'
            release_status = 'ga'
            package_type = 'jdk'
            architecture = 'x64'
        },
        [pscustomobject][ordered]@{
            distribution = 'temurin'
            major_version = 21
            java_version = '21.0.9+10'
            release_status = 'ga'
            package_type = 'jdk'
            architecture = 'x64'
        }
    )
}

$javaTemurin = Resolve-JavaVersionIntelligence -DecodedSource (New-Decoded -Source $temurinSource.source -Data $javaData) -InstalledVersion (New-TestVersionRecord -Version '17.0.16+8' -Channel $null) -InstalledMajor 17 -InstalledDistribution 'Temurin' -ExpectedDistribution temurin -PackageType jdk -Architecture amd64
Assert-True ($javaTemurin.intelligence.status -eq 'known') 'Java same-major intelligence must be known.'
Assert-True ($javaTemurin.latestSameMajor.normalized -eq '17.0.17+10') 'Java must prefer the matching distribution within the installed major.'
Assert-True ($javaTemurin.selectedDistribution -eq 'temurin') 'Java must preserve selected distribution context.'
Assert-True ($javaTemurin.distributionMatched -eq $true) 'Temurin source must match Temurin install context.'
Assert-True ($javaTemurin.packageTypeMatched -eq $true) 'Java package type must match.'
Assert-True ($javaTemurin.architectureMatched -eq $true) 'Java architecture must match.'
Assert-True ($javaTemurin.directReplacement -eq $true) 'Only a fully matching same-major context may be considered directly comparable.'
Assert-True ($javaTemurin.updateAvailable -eq $true) 'Synthetic Temurin 17 install should report a same-context update.'
Assert-True ($javaTemurin.higherMajorObserved -eq $true) 'Higher Java majors may be observed without replacing the installed major.'
Assert-True ($javaTemurin.otherDistributionObserved -eq $true) 'Multi-vendor source evidence must be preserved.'
Assert-True ($javaTemurin.intelligence.latestStable.normalized -eq '17.0.17+10') 'Component latestStable must remain same-major/context relevant.'

$javaMicrosoft = Resolve-JavaVersionIntelligence -DecodedSource (New-Decoded -Source 'foojay-disco:java-17:microsoft:jdk:x64' -Data $javaData) -InstalledVersion (New-TestVersionRecord -Version '17.0.17+7' -Channel $null) -InstalledMajor 17 -InstalledDistribution 'Microsoft Build of OpenJDK' -ExpectedDistribution microsoft -PackageType jdk -Architecture x64
Assert-True ($javaMicrosoft.latestSameMajor.normalized -eq '17.0.18+8') 'Java multi-vendor data must select the requested vendor context.'
Assert-True ($javaMicrosoft.selectedDistribution -eq 'microsoft') 'Microsoft context must remain distinct from Temurin.'
Assert-True ($javaMicrosoft.directReplacement -eq $true) 'Matching Microsoft same-major context should be directly comparable.'

$javaGeneric = Resolve-JavaVersionIntelligence -DecodedSource (New-Decoded -Source 'foojay-disco:java-17:any-distribution:jdk:x64' -Data $javaData) -InstalledVersion (New-TestVersionRecord -Version '17.0.16+8' -Channel $null) -InstalledMajor 17 -InstalledDistribution 'Unknown Distribution' -ExpectedDistribution $null -PackageType jdk -Architecture x64
Assert-True ($javaGeneric.latestSameMajor.normalized -eq '17.0.18+8') 'Unknown distribution may expose same-major reference information.'
Assert-True ($javaGeneric.distributionMatched -eq $false) 'Unknown distribution must not fabricate a vendor match.'
Assert-True ($javaGeneric.directReplacement -eq $false) 'Unknown distribution must never be treated as a direct replacement.'
Assert-True ($null -eq $javaGeneric.updateAvailable) 'Unknown distribution must not produce a direct update recommendation.'

$higherMajorOnlyData = [pscustomobject][ordered]@{
    result = @(
        [pscustomobject][ordered]@{
            distribution = 'temurin'
            major_version = 21
            java_version = '21.0.9+10'
            release_status = 'ga'
            package_type = 'jdk'
            architecture = 'x64'
        }
    )
}

$higherMajorOnly = Resolve-JavaVersionIntelligence -DecodedSource (New-Decoded -Source $temurinSource.source -Data $higherMajorOnlyData) -InstalledVersion (New-TestVersionRecord -Version '17.0.16+8' -Channel $null) -InstalledMajor 17 -InstalledDistribution 'Temurin' -ExpectedDistribution temurin -PackageType jdk -Architecture x64
Assert-True ($higherMajorOnly.intelligence.status -eq 'unknown') 'A higher Java major alone must not become latestStable for the installed major.'
Assert-True ($higherMajorOnly.higherMajorObserved -eq $true) 'Higher Java major presence must be explicit.'
Assert-True ($null -eq $higherMajorOnly.latestSameMajor) 'Higher Java major must not be fabricated as same-major latest.'
Assert-True ($higherMajorOnly.directReplacement -eq $false) 'Higher Java major must not be a direct replacement.'
Assert-True ($higherMajorOnly.intelligence.message -match 'none are treated as a direct replacement') 'Higher-major message must reject automatic replacement.'

$architectureMismatchData = [pscustomobject][ordered]@{
    result = @(
        [pscustomobject][ordered]@{
            distribution = 'temurin'
            major_version = 17
            java_version = '17.0.17+10'
            release_status = 'ga'
            package_type = 'jdk'
            architecture = 'aarch64'
        }
    )
}

$architectureMismatch = Resolve-JavaVersionIntelligence -DecodedSource (New-Decoded -Source $temurinSource.source -Data $architectureMismatchData) -InstalledVersion (New-TestVersionRecord -Version '17.0.16+8' -Channel $null) -InstalledMajor 17 -InstalledDistribution 'Temurin' -ExpectedDistribution temurin -PackageType jdk -Architecture x64
Assert-True ($architectureMismatch.distributionMatched -eq $true) 'Architecture mismatch must not erase vendor match.'
Assert-True ($architectureMismatch.architectureMatched -eq $false) 'Architecture mismatch must remain explicit.'
Assert-True ($architectureMismatch.directReplacement -eq $false) 'Architecture mismatch must block direct replacement semantics.'
Assert-True ($null -eq $architectureMismatch.updateAvailable) 'Architecture mismatch must not report a direct update.'

$offlineJava = Resolve-JavaVersionIntelligence -DecodedSource (New-Decoded -Source $temurinSource.source -Data $null -Status unavailable) -InstalledVersion (New-TestVersionRecord -Version '17.0.16+8' -Channel $null) -InstalledMajor 17 -InstalledDistribution 'Temurin' -ExpectedDistribution temurin -PackageType jdk -Architecture x64
Assert-True ($offlineJava.intelligence.status -eq 'unavailable') 'Offline Java intelligence must be unavailable.'
Assert-True ($offlineJava.installedMajor -eq 17) 'Offline Java must preserve installed major context.'
Assert-True ($offlineJava.installedDistribution -eq 'Temurin') 'Offline Java must preserve distribution context.'
Assert-True ($offlineJava.architecture -eq 'x64') 'Offline Java must preserve architecture context.'
Assert-True ($offlineJava.directReplacement -eq $false) 'Offline Java must not fabricate replacement semantics.'

$javaSource = Get-Content -LiteralPath $javaProvider -Raw
$flutterSource = Get-Content -LiteralPath $flutterProvider -Raw
$jvmMobileSource = Get-Content -LiteralPath $jvmMobileCore -Raw

foreach ($marker in @(
    'JvmMobileVersionIntelligence.Core.psm1',
    'New-FoojayJavaVersionSource',
    'java.version-intelligence.source',
    'java.version-intelligence',
    'directReplacement',
    'installedContexts',
    'VersionIntelligenceOffline'
)) {
    if ($javaSource -notmatch [Regex]::Escape($marker)) {
        throw "Missing Java provider marker: $marker"
    }
}

foreach ($marker in @(
    'foojay-disco',
    'https://api.foojay.io/disco/v3.0/packages',
    'Get-FoojayDistributionSlug',
    'Resolve-JavaVersionIntelligence'
)) {
    if ($jvmMobileSource -notmatch [Regex]::Escape($marker)) {
        throw "Missing JVM/mobile core marker: $marker"
    }
}

foreach ($marker in @(
    'JvmMobileVersionIntelligence.Core.psm1',
    'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json',
    'flutter-sdk-archive:windows',
    'mobile.version-intelligence.flutter-source',
    'mobile.version-intelligence.flutter',
    'channelSwitchRequired',
    'VersionIntelligenceOffline'
)) {
    if ($flutterSource -notmatch [Regex]::Escape($marker)) {
        throw "Missing Flutter provider marker: $marker"
    }
}

$forbiddenMutationPatterns = @(
    '(?i)\bflutter\s+(upgrade|channel|downgrade|precache)\b',
    '(?i)\bsdk\s+(install|use|default|uninstall)\b',
    '(?i)\bwinget\s+(install|upgrade|uninstall)\b',
    '(?i)\bchoco\s+(install|upgrade|uninstall)\b',
    '(?i)\bscoop\s+(install|update|uninstall)\b'
)

foreach ($pattern in $forbiddenMutationPatterns) {
    if ($javaSource -match $pattern) {
        throw "Forbidden Java mutation pattern: $pattern"
    }
    if ($flutterSource -match $pattern) {
        throw "Forbidden Flutter mutation pattern: $pattern"
    }
    if ($jvmMobileSource -match $pattern) {
        throw "Forbidden JVM/mobile core mutation pattern: $pattern"
    }
}

Write-Host 'Flutter Java version intelligence validation passed.'
