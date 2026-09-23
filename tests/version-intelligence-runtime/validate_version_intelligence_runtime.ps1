[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$auditCorePath = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$versionCorePath = Join-Path $root 'scripts\Core\VersionIntelligence.Core.psm1'

Import-Module $auditCorePath -Force
Import-Module $versionCorePath -Force

$checkedAt = [DateTimeOffset]::Parse('2026-09-23T15:00:00+00:00')
$checkedAtText = $checkedAt.ToString('o')

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$stable = New-AuditVersionRecord -Raw '1.2.3' -Normalized '1.2.3' -Channel stable
$lts = New-AuditVersionRecord -Raw '20.19.5' -Normalized '20.19.5' -Channel lts
$current = New-AuditVersionRecord -Raw '24.8.0' -Normalized '24.8.0' -Channel current

$knownParameters = @{
    Status        = 'known'
    LatestStable  = $stable
    LatestLts     = $lts
    LatestCurrent = $current
    Source        = 'synthetic-version-source'
    CheckedAt     = $checkedAtText
}
$known = New-AuditVersionIntelligence @knownParameters

Assert-True ($known.status -eq 'known') 'Expected known version intelligence.'
Assert-True ($known.latestStable.normalized -eq '1.2.3') 'Expected latest stable version.'
Assert-True ($known.latestLts.channel -eq 'lts') 'Expected LTS channel preservation.'
Assert-True ($known.latestCurrent.channel -eq 'current') 'Expected Current channel preservation.'
Assert-True ($known.source -eq 'synthetic-version-source') 'Expected version-intelligence source identity.'
Assert-True ($known.checkedAt -eq $checkedAtText) 'Expected deterministic checked-at timestamp.'

$unknown = New-AuditVersionIntelligence -Status unknown -Source 'synthetic-version-source' -CheckedAt $checkedAtText -Message 'Synthetic data could not be interpreted.'
Assert-True ($unknown.status -eq 'unknown') 'Expected unknown version intelligence.'
Assert-True ($null -eq $unknown.latestStable) 'Unknown intelligence must not fabricate a stable version.'

$unavailable = New-AuditVersionIntelligence -Status unavailable -Source 'synthetic-version-source' -CheckedAt $checkedAtText -Message 'Synthetic source is unavailable.'
Assert-True ($unavailable.status -eq 'unavailable') 'Expected unavailable version intelligence.'

$notApplicable = New-AuditVersionIntelligence -Status not-applicable
Assert-True ($notApplicable.status -eq 'not-applicable') 'Expected not-applicable version intelligence.'
Assert-True ($null -eq $notApplicable.source) 'Not-applicable intelligence must not carry a source.'

$knownWithoutVersionRejected = $false
try {
    New-AuditVersionIntelligence -Status known -Source 'synthetic-version-source' -CheckedAt $checkedAtText | Out-Null
}
catch {
    $knownWithoutVersionRejected = $true
}
Assert-True $knownWithoutVersionRejected 'Known intelligence without a version must be rejected.'

$syntheticTransport = {
    param($request)

    if ($request.source -ne 'synthetic-json') {
        throw "Unexpected synthetic source identity: $($request.source)"
    }

    [pscustomobject][ordered]@{
        statusCode  = 200
        contentType = 'application/json; charset=utf-8'
        body        = '{"stable":"1.2.3","lts":"20.19.5","current":"24.8.0"}'
    }
}

$sourceParameters = @{
    Source               = 'synthetic-json'
    Uri                  = 'https://synthetic.invalid/releases.json'
    Transport            = $syntheticTransport
    CheckedAt            = $checkedAt
    MaximumResponseBytes = 4096
}
$source = Invoke-AuditVersionSource @sourceParameters

Assert-True ($source.status -eq 'success') 'Expected successful synthetic source lookup.'
Assert-True ($source.networkAttempted -eq $true) 'Synthetic transport must count as an attempted source lookup.'
Assert-True ($source.statusCode -eq 200) 'Expected HTTP status preservation.'
Assert-True ($source.checkedAt -eq $checkedAtText) 'Expected source checked-at timestamp.'
Assert-True ($source.responseBytes -gt 0 -and $source.responseBytes -lt 4096) 'Expected bounded byte count.'
Assert-True ($source.truncated -eq $false) 'Expected non-truncated synthetic response.'

$decoded = ConvertFrom-AuditVersionSourceJson -SourceResult $source
Assert-True ($decoded.status -eq 'known') 'Valid JSON source should decode as known.'
Assert-True ($decoded.data.stable -eq '1.2.3') 'Expected decoded JSON data.'
Assert-True ($decoded.source -eq 'synthetic-json') 'Decoded source must preserve source identity.'
Assert-True ($decoded.checkedAt -eq $checkedAtText) 'Decoded source must preserve checked-at timestamp.'

$attributes = Get-AuditVersionSourceEvidenceAttributes -SourceResult $source
foreach ($requiredName in @(
    'sourceStatus',
    'checkedAt',
    'networkAttempted',
    'statusCode',
    'contentType',
    'responseBytes',
    'truncated',
    'failureKind'
)) {
    if (-not $attributes.Contains($requiredName)) {
        throw "Safe source evidence attributes missing '$requiredName'."
    }
}

foreach ($forbiddenName in @(
    'body',
    'uri',
    'headers',
    'credentials',
    'cookies',
    'exception',
    'exceptionText'
)) {
    if ($attributes.Contains($forbiddenName)) {
        throw "Safe source evidence attributes must not contain '$forbiddenName'."
    }
}

$evidence = New-AuditEvidence -EvidenceId 'version-source.synthetic' -Type api -Source $source.source -Captured $null -Attributes $attributes
Assert-True ($null -eq $evidence.captured) 'Version source evidence must not persist raw response content.'

$malformedTransport = {
    param($request)

    [pscustomobject][ordered]@{
        statusCode  = 200
        contentType = 'application/json'
        body        = '{"stable":'
    }
}

$malformedSource = Invoke-AuditVersionSource -Source 'malformed-json' -Uri 'https://synthetic.invalid/malformed.json' -Transport $malformedTransport -CheckedAt $checkedAt
$malformedDecoded = ConvertFrom-AuditVersionSourceJson -SourceResult $malformedSource
Assert-True ($malformedDecoded.status -eq 'unknown') 'Malformed JSON must degrade to unknown.'
Assert-True ($null -eq $malformedDecoded.data) 'Malformed JSON must not return parsed data.'

$timeoutTransport = {
    param($request)
    throw [System.TimeoutException]::new('synthetic timeout')
}

$timedOutSource = Invoke-AuditVersionSource -Source 'timeout-source' -Uri 'https://synthetic.invalid/timeout' -Transport $timeoutTransport -CheckedAt $checkedAt
Assert-True ($timedOutSource.status -eq 'unavailable') 'Timeout must degrade to unavailable.'
Assert-True ($timedOutSource.failureKind -eq 'timeout') 'Expected normalized timeout failure kind.'
Assert-True ($timedOutSource.checkedAt -eq $checkedAtText) 'Timeout must preserve checked-at timestamp.'

$unreachableTransport = {
    param($request)
    throw [System.Net.Http.HttpRequestException]::new('synthetic unreachable')
}

$unreachableSource = Invoke-AuditVersionSource -Source 'unreachable-source' -Uri 'https://synthetic.invalid/unreachable' -Transport $unreachableTransport -CheckedAt $checkedAt
Assert-True ($unreachableSource.status -eq 'unavailable') 'Unreachable source must degrade to unavailable.'
Assert-True ($unreachableSource.failureKind -eq 'unreachable') 'Expected normalized unreachable failure kind.'

$httpFailureTransport = {
    param($request)

    [pscustomobject][ordered]@{
        statusCode  = 503
        contentType = 'application/json'
        body        = '{"error":"synthetic"}'
    }
}

$httpFailure = Invoke-AuditVersionSource -Source 'http-failure-source' -Uri 'https://synthetic.invalid/http-failure' -Transport $httpFailureTransport -CheckedAt $checkedAt
Assert-True ($httpFailure.status -eq 'unavailable') 'Non-success HTTP source must degrade to unavailable.'
Assert-True ($httpFailure.failureKind -eq 'http-status') 'Expected normalized HTTP failure kind.'
Assert-True ($httpFailure.statusCode -eq 503) 'Expected HTTP failure status code.'
Assert-True ($null -eq $httpFailure.body) 'HTTP failure bodies must not be retained.'

$offlineTransport = {
    param($request)
    throw 'Offline mode must not invoke transport.'
}

$offline = Invoke-AuditVersionSource -Source 'offline-source' -Uri 'https://synthetic.invalid/offline' -Transport $offlineTransport -Offline -CheckedAt $checkedAt
Assert-True ($offline.status -eq 'unavailable') 'Offline mode must return unavailable.'
Assert-True ($offline.failureKind -eq 'offline') 'Expected offline failure kind.'
Assert-True ($offline.networkAttempted -eq $false) 'Offline mode must not attempt network/transport.'
Assert-True ($offline.checkedAt -eq $checkedAtText) 'Offline result must preserve checked-at timestamp.'

$largeBody = '{"payload":"' + ('x' * 4096) + '"}'
$largeTransport = {
    param($request)

    [pscustomobject][ordered]@{
        statusCode  = 200
        contentType = 'application/json'
        body        = $largeBody
    }
}.GetNewClosure()

$bounded = Invoke-AuditVersionSource -Source 'bounded-source' -Uri 'https://synthetic.invalid/bounded' -Transport $largeTransport -CheckedAt $checkedAt -MaximumResponseBytes 512
Assert-True ($bounded.status -eq 'success') 'Bounded source transport should preserve successful HTTP status.'
Assert-True ($bounded.truncated -eq $true) 'Oversized response must be marked truncated.'
Assert-True ([Text.Encoding]::UTF8.GetByteCount($bounded.body) -le 512) 'Retained source body must respect configured byte bound.'

$boundedDecoded = ConvertFrom-AuditVersionSourceJson -SourceResult $bounded
Assert-True ($boundedDecoded.status -eq 'unknown') 'Truncated source must degrade to unknown before interpretation.'

$invalidSchemeRejected = $false
try {
    Invoke-AuditVersionSource -Source 'invalid-http-source' -Uri 'http://synthetic.invalid/releases' -Transport $syntheticTransport -CheckedAt $checkedAt | Out-Null
}
catch {
    $invalidSchemeRejected = $true
}
Assert-True $invalidSchemeRejected 'Non-HTTPS version source must be rejected.'

$credentialUriRejected = $false
try {
    Invoke-AuditVersionSource -Source 'credential-source' -Uri 'https://user:password@synthetic.invalid/releases' -Transport $syntheticTransport -CheckedAt $checkedAt | Out-Null
}
catch {
    $credentialUriRejected = $true
}
Assert-True $credentialUriRejected 'Credential-bearing version source URI must be rejected.'

$moduleSource = Get-Content -LiteralPath $versionCorePath -Raw

foreach ($forbiddenMutation in @(
    'winget upgrade',
    'winget install',
    'npm install',
    'pnpm add',
    'flutter upgrade',
    'rustup update',
    'dotnet workload update',
    'git push'
)) {
    if ($moduleSource -match [Regex]::Escape($forbiddenMutation)) {
        throw "Version-intelligence runtime contains prohibited mutation marker: $forbiddenMutation"
    }
}

foreach ($requiredMarker in @(
    'Version-intelligence sources must use HTTPS.',
    'Version-intelligence source URIs must not contain embedded credentials.',
    'MaximumResponseBytes',
    'networkAttempted',
    'failureKind',
    'Get-AuditVersionSourceEvidenceAttributes'
)) {
    if ($moduleSource -notmatch [Regex]::Escape($requiredMarker)) {
        throw "Version-intelligence runtime is missing required safety marker: $requiredMarker"
    }
}

Write-Host 'Shared version-intelligence source runtime validation passed.'
