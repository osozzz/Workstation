Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-OptionalPropertyValue {
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

function ConvertTo-BoundedVersionSourceBody {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Body,
        [Parameter(Mandatory)][ValidateRange(1, 1048576)][int]$MaximumResponseBytes
    )

    if ($null -eq $Body) {
        return [pscustomobject][ordered]@{
            text      = $null
            byteCount = 0
            truncated = $false
        }
    }

    $bytes = if ($Body -is [byte[]]) {
        [byte[]]$Body
    }
    else {
        [Text.Encoding]::UTF8.GetBytes([string]$Body)
    }

    $byteCount = $bytes.Length
    $truncated = ($byteCount -gt $MaximumResponseBytes)

    if (-not $truncated) {
        return [pscustomobject][ordered]@{
            text      = [Text.Encoding]::UTF8.GetString($bytes)
            byteCount = $byteCount
            truncated = $false
        }
    }

    $boundedBytes = New-Object byte[] $MaximumResponseBytes
    [Array]::Copy($bytes, 0, $boundedBytes, 0, $MaximumResponseBytes)

    return [pscustomobject][ordered]@{
        text      = [Text.Encoding]::UTF8.GetString($boundedBytes)
        byteCount = $byteCount
        truncated = $true
    }
}

function New-VersionSourceResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][ValidateSet('success', 'unavailable')][string]$Status,
        [Parameter(Mandatory)][string]$CheckedAt,
        [Parameter(Mandatory)][bool]$NetworkAttempted,
        [AllowNull()][Nullable[int]]$StatusCode,
        [AllowNull()][string]$ContentType,
        [AllowNull()][string]$Body,
        [Parameter(Mandatory)][int64]$ResponseBytes,
        [Parameter(Mandatory)][bool]$Truncated,
        [AllowNull()][string]$FailureKind,
        [AllowNull()][string]$Message
    )

    return [pscustomobject][ordered]@{
        source           = $Source
        status           = $Status
        checkedAt        = $CheckedAt
        networkAttempted = $NetworkAttempted
        statusCode       = $StatusCode
        contentType      = $ContentType
        body             = $Body
        responseBytes    = $ResponseBytes
        truncated        = $Truncated
        failureKind      = $FailureKind
        message          = $Message
    }
}

function Invoke-DefaultVersionSourceTransport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Request
    )

    $headers = @{
        Accept       = 'application/json'
        'User-Agent' = 'Workstation-Audit-Version-Intelligence/0.7'
    }

    $parameters = @{
        Uri                = [string]$Request.uri
        Method             = 'Get'
        Headers            = $headers
        TimeoutSec         = [int]$Request.timeoutSeconds
        MaximumRedirection = 5
        SkipHttpErrorCheck = $true
        ErrorAction        = 'Stop'
    }

    $response = Invoke-WebRequest @parameters

    $contentType = $null
    if ($response.Headers) {
        $contentTypeHeader = $response.Headers['Content-Type']
        if ($contentTypeHeader) {
            $contentType = [string]$contentTypeHeader
        }
    }

    return [pscustomobject][ordered]@{
        statusCode  = [int]$response.StatusCode
        contentType = $contentType
        body        = $response.Content
    }
}

function New-AuditVersionIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('known', 'unknown', 'unavailable', 'not-applicable')][string]$Status,
        [AllowNull()][object]$LatestStable,
        [AllowNull()][object]$LatestLts,
        [AllowNull()][object]$LatestCurrent,
        [AllowNull()][string]$Source,
        [AllowNull()][string]$CheckedAt,
        [AllowNull()][string]$Message
    )

    $hasVersion = (
        $null -ne $LatestStable -or
        $null -ne $LatestLts -or
        $null -ne $LatestCurrent
    )

    if ($Status -eq 'known' -and -not $hasVersion) {
        throw 'Known version intelligence requires at least one latest-version value.'
    }

    if ($Status -in @('unknown', 'unavailable', 'not-applicable') -and $hasVersion) {
        throw "Version intelligence status '$Status' cannot carry latest-version values."
    }

    if ($Status -eq 'not-applicable') {
        if (-not [string]::IsNullOrWhiteSpace($Source) -or -not [string]::IsNullOrWhiteSpace($CheckedAt)) {
            throw 'Not-applicable version intelligence cannot carry source/check timestamp.'
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Source)) {
            throw "Version intelligence status '$Status' requires a source identity."
        }

        if ([string]::IsNullOrWhiteSpace($CheckedAt)) {
            throw "Version intelligence status '$Status' requires a checked-at timestamp."
        }

        [DateTimeOffset]$parsedCheckedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($CheckedAt, [ref]$parsedCheckedAt)) {
            throw "Version intelligence checkedAt is not a valid date-time: '$CheckedAt'."
        }
    }

    return [pscustomobject][ordered]@{
        status        = $Status
        latestStable  = $LatestStable
        latestLts     = $LatestLts
        latestCurrent = $LatestCurrent
        source        = $(if ([string]::IsNullOrWhiteSpace($Source)) { $null } else { $Source })
        checkedAt     = $(if ([string]::IsNullOrWhiteSpace($CheckedAt)) { $null } else { $CheckedAt })
        message       = $Message
    }
}

function Invoke-AuditVersionSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Source,
        [Parameter(Mandatory)][uri]$Uri,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 15,
        [ValidateRange(256, 1048576)][int]$MaximumResponseBytes = 65536,
        [switch]$Offline,
        [AllowNull()][scriptblock]$Transport,
        [DateTimeOffset]$CheckedAt = [DateTimeOffset]::UtcNow
    )

    if (-not [string]::Equals($Uri.Scheme, 'https', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Version-intelligence sources must use HTTPS.'
    }

    if (-not [string]::IsNullOrWhiteSpace($Uri.UserInfo)) {
        throw 'Version-intelligence source URIs must not contain embedded credentials.'
    }

    $checkedAtText = $CheckedAt.ToString('o')

    if ($Offline) {
        $parameters = @{
            Source           = $Source
            Status           = 'unavailable'
            CheckedAt        = $checkedAtText
            NetworkAttempted = $false
            StatusCode       = $null
            ContentType      = $null
            Body             = $null
            ResponseBytes    = 0
            Truncated        = $false
            FailureKind      = 'offline'
            Message          = 'Version source lookup was skipped because offline mode is enabled.'
        }
        return New-VersionSourceResult @parameters
    }

    $request = [pscustomobject][ordered]@{
        source               = $Source
        uri                  = $Uri.AbsoluteUri
        timeoutSeconds       = $TimeoutSeconds
        maximumResponseBytes = $MaximumResponseBytes
    }

    try {
        $transportResponse = if ($null -ne $Transport) {
            & $Transport $request
        }
        else {
            Invoke-DefaultVersionSourceTransport -Request $request
        }

        if ($null -eq $transportResponse) {
            $parameters = @{
                Source           = $Source
                Status           = 'unavailable'
                CheckedAt        = $checkedAtText
                NetworkAttempted = $true
                StatusCode       = $null
                ContentType      = $null
                Body             = $null
                ResponseBytes    = 0
                Truncated        = $false
                FailureKind      = 'transport-invalid'
                Message          = 'Version source transport returned no response.'
            }
            return New-VersionSourceResult @parameters
        }

        $statusCodeValue = Get-OptionalPropertyValue -InputObject $transportResponse -Name 'statusCode'
        [int]$statusCode = 0
        if ($null -eq $statusCodeValue -or -not [int]::TryParse($statusCodeValue.ToString(), [ref]$statusCode)) {
            $parameters = @{
                Source           = $Source
                Status           = 'unavailable'
                CheckedAt        = $checkedAtText
                NetworkAttempted = $true
                StatusCode       = $null
                ContentType      = $null
                Body             = $null
                ResponseBytes    = 0
                Truncated        = $false
                FailureKind      = 'transport-invalid'
                Message          = 'Version source transport did not return a valid HTTP status code.'
            }
            return New-VersionSourceResult @parameters
        }

        $contentTypeValue = Get-OptionalPropertyValue -InputObject $transportResponse -Name 'contentType'
        $contentType = if ($null -eq $contentTypeValue) { $null } else { [string]$contentTypeValue }
        $bodyValue = Get-OptionalPropertyValue -InputObject $transportResponse -Name 'body'
        $boundedBody = ConvertTo-BoundedVersionSourceBody -Body $bodyValue -MaximumResponseBytes $MaximumResponseBytes

        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            $parameters = @{
                Source           = $Source
                Status           = 'unavailable'
                CheckedAt        = $checkedAtText
                NetworkAttempted = $true
                StatusCode       = $statusCode
                ContentType      = $contentType
                Body             = $null
                ResponseBytes    = $boundedBody.byteCount
                Truncated        = $boundedBody.truncated
                FailureKind      = 'http-status'
                Message          = "Version source returned HTTP status $statusCode."
            }
            return New-VersionSourceResult @parameters
        }

        $parameters = @{
            Source           = $Source
            Status           = 'success'
            CheckedAt        = $checkedAtText
            NetworkAttempted = $true
            StatusCode       = $statusCode
            ContentType      = $contentType
            Body             = $boundedBody.text
            ResponseBytes    = $boundedBody.byteCount
            Truncated        = $boundedBody.truncated
            FailureKind      = $null
            Message          = $null
        }
        return New-VersionSourceResult @parameters
    }
    catch [System.TimeoutException] {
        $parameters = @{
            Source           = $Source
            Status           = 'unavailable'
            CheckedAt        = $checkedAtText
            NetworkAttempted = $true
            StatusCode       = $null
            ContentType      = $null
            Body             = $null
            ResponseBytes    = 0
            Truncated        = $false
            FailureKind      = 'timeout'
            Message          = 'Version source lookup timed out.'
        }
        return New-VersionSourceResult @parameters
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        $parameters = @{
            Source           = $Source
            Status           = 'unavailable'
            CheckedAt        = $checkedAtText
            NetworkAttempted = $true
            StatusCode       = $null
            ContentType      = $null
            Body             = $null
            ResponseBytes    = 0
            Truncated        = $false
            FailureKind      = 'timeout'
            Message          = 'Version source lookup timed out.'
        }
        return New-VersionSourceResult @parameters
    }
    catch [System.Net.Http.HttpRequestException] {
        $parameters = @{
            Source           = $Source
            Status           = 'unavailable'
            CheckedAt        = $checkedAtText
            NetworkAttempted = $true
            StatusCode       = $null
            ContentType      = $null
            Body             = $null
            ResponseBytes    = 0
            Truncated        = $false
            FailureKind      = 'unreachable'
            Message          = 'Version source could not be reached.'
        }
        return New-VersionSourceResult @parameters
    }
    catch {
        $parameters = @{
            Source           = $Source
            Status           = 'unavailable'
            CheckedAt        = $checkedAtText
            NetworkAttempted = $true
            StatusCode       = $null
            ContentType      = $null
            Body             = $null
            ResponseBytes    = 0
            Truncated        = $false
            FailureKind      = 'transport'
            Message          = 'Version source transport failed.'
        }
        return New-VersionSourceResult @parameters
    }
}

function ConvertFrom-AuditVersionSourceJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$SourceResult,
        [ValidateRange(1, 100)][int]$Depth = 20
    )

    $source = [string](Get-OptionalPropertyValue -InputObject $SourceResult -Name 'source')
    $checkedAt = [string](Get-OptionalPropertyValue -InputObject $SourceResult -Name 'checkedAt')
    $sourceStatus = [string](Get-OptionalPropertyValue -InputObject $SourceResult -Name 'status')

    if ($sourceStatus -eq 'unavailable') {
        return [pscustomobject][ordered]@{
            status    = 'unavailable'
            source    = $source
            checkedAt = $checkedAt
            data      = $null
            message   = [string](Get-OptionalPropertyValue -InputObject $SourceResult -Name 'message')
        }
    }

    if ($sourceStatus -ne 'success') {
        return [pscustomobject][ordered]@{
            status    = 'unknown'
            source    = $source
            checkedAt = $checkedAt
            data      = $null
            message   = 'Version source result has an unrecognized status.'
        }
    }

    $truncated = [bool](Get-OptionalPropertyValue -InputObject $SourceResult -Name 'truncated')
    if ($truncated) {
        return [pscustomobject][ordered]@{
            status    = 'unknown'
            source    = $source
            checkedAt = $checkedAt
            data      = $null
            message   = 'Version source response exceeded the configured capture bound.'
        }
    }

    $body = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'body'
    if ($null -eq $body -or [string]::IsNullOrWhiteSpace([string]$body)) {
        return [pscustomobject][ordered]@{
            status    = 'unknown'
            source    = $source
            checkedAt = $checkedAt
            data      = $null
            message   = 'Version source returned an empty response.'
        }
    }

    try {
        $data = [string]$body | ConvertFrom-Json -Depth $Depth -ErrorAction Stop
        return [pscustomobject][ordered]@{
            status    = 'known'
            source    = $source
            checkedAt = $checkedAt
            data      = $data
            message   = $null
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            status    = 'unknown'
            source    = $source
            checkedAt = $checkedAt
            data      = $null
            message   = 'Version source response was not valid JSON.'
        }
    }
}

function Get-AuditVersionSourceEvidenceAttributes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$SourceResult
    )

    return [ordered]@{
        sourceStatus     = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'status'
        checkedAt        = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'checkedAt'
        networkAttempted = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'networkAttempted'
        statusCode       = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'statusCode'
        contentType      = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'contentType'
        responseBytes    = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'responseBytes'
        truncated        = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'truncated'
        failureKind      = Get-OptionalPropertyValue -InputObject $SourceResult -Name 'failureKind'
    }
}

Export-ModuleMember -Function @(
    'New-AuditVersionIntelligence',
    'Invoke-AuditVersionSource',
    'ConvertFrom-AuditVersionSourceJson',
    'Get-AuditVersionSourceEvidenceAttributes'
)
