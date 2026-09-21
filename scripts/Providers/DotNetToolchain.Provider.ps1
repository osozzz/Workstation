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
        providerId = 'dotnet.toolchain'
        category   = 'runtime'
        order      = 25
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

function Get-VersionRecordFromText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match(
        $Text,
        '(?i)(?<![0-9A-Za-z])(?<version>\d+\.\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.-]+)?)'
    )

    if (-not $match.Success) {
        return $null
    }

    $normalized = $match.Groups['version'].Value
    return New-AuditVersionRecord -Raw $match.Value -Normalized $normalized -Channel $null
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

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    foreach ($existing in $List) {
        if (
            [string]::Equals(
                ([string]$existing.path).TrimEnd('\'),
                $Path.TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase
            )
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

function Parse-DotNetSdkList {
    param([AllowNull()][string]$Text)

    $items = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $items.ToArray()
    }

    foreach ($line in @($Text -split '\r?\n')) {
        $match = [regex]::Match(
            $line.Trim(),
            '^(?<version>\d+\.\d+(?:\.\d+){1,2}(?:[-+][0-9A-Za-z.-]+)?)\s+\[(?<root>.+)\]$'
        )

        if (-not $match.Success) {
            continue
        }

        $version = Get-VersionRecordFromText -Text $match.Groups['version'].Value
        $root = $match.Groups['root'].Value.Trim()
        $installPath = if ([string]::IsNullOrWhiteSpace($root)) {
            $null
        }
        else {
            Join-Path $root $match.Groups['version'].Value
        }

        $items.Add([pscustomobject][ordered]@{
            version = $version
            root    = $root
            path    = $installPath
        })
    }

    return $items.ToArray()
}

function Parse-DotNetRuntimeList {
    param([AllowNull()][string]$Text)

    $items = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $items.ToArray()
    }

    foreach ($line in @($Text -split '\r?\n')) {
        $match = [regex]::Match(
            $line.Trim(),
            '^(?<product>[A-Za-z0-9._-]+)\s+(?<version>\d+\.\d+(?:\.\d+){1,2}(?:[-+][0-9A-Za-z.-]+)?)\s+\[(?<root>.+)\]$'
        )

        if (-not $match.Success) {
            continue
        }

        $versionText = $match.Groups['version'].Value
        $version = Get-VersionRecordFromText -Text $versionText
        $root = $match.Groups['root'].Value.Trim()
        $installPath = if ([string]::IsNullOrWhiteSpace($root)) {
            $null
        }
        else {
            Join-Path $root $versionText
        }

        $items.Add([pscustomobject][ordered]@{
            product = $match.Groups['product'].Value
            version = $version
            root    = $root
            path    = $installPath
        })
    }

    return $items.ToArray()
}

function Convert-DotNetWorkloadListJson {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $jsonText = $Text.Trim()

    $startMarker = '==workloadListJsonOutputStart=='
    $endMarker = '==workloadListJsonOutputEnd=='

    $startIndex = $jsonText.IndexOf($startMarker, [StringComparison]::Ordinal)
    $endIndex = $jsonText.IndexOf($endMarker, [StringComparison]::Ordinal)

    if ($startIndex -ge 0 -and $endIndex -gt $startIndex) {
        $jsonStart = $startIndex + $startMarker.Length
        $jsonText = $jsonText.Substring($jsonStart, $endIndex - $jsonStart).Trim()
    }
    elseif (-not $jsonText.StartsWith('{')) {
        $firstBrace = $jsonText.IndexOf('{')
        $lastBrace = $jsonText.LastIndexOf('}')
        if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
            $jsonText = $jsonText.Substring($firstBrace, ($lastBrace - $firstBrace) + 1)
        }
    }

    try {
        return $jsonText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

$environmentSnapshot = Get-AuditEnvironmentSnapshot -Names @(
    'DOTNET_ROOT',
    'DOTNET_ROOT_X64',
    'DOTNET_ROOT_X86'
)

$evidence.Add((New-AuditEvidence -EvidenceId 'dotnet.environment' -Type environment -Source 'DOTNET_ROOT/DOTNET_ROOT_X64/DOTNET_ROOT_X86' -Captured $null -Attributes @{
    variables = @($environmentSnapshot)
    dotnetRootConfigured = -not [string]::IsNullOrWhiteSpace((Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'DOTNET_ROOT'))
    dotnetRootX64Configured = -not [string]::IsNullOrWhiteSpace((Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'DOTNET_ROOT_X64'))
    dotnetRootX86Configured = -not [string]::IsNullOrWhiteSpace((Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'DOTNET_ROOT_X86'))
}))

$dotnetResolutions = @(Get-AuditCommandResolution -Command 'dotnet')

if ($dotnetResolutions.Count -eq 0) {
    foreach ($component in @(
        @{ Id='dotnet-sdk'; Name='.NET SDK' },
        @{ Id='dotnet-runtime'; Name='.NET Runtimes' },
        @{ Id='dotnet-workloads'; Name='.NET Workloads' }
    )) {
        $components.Add([pscustomobject][ordered]@{
            componentId         = $component.Id
            name                = $component.Name
            state               = 'missing'
            installed           = $false
            activeVersion       = $null
            discoveredVersions  = @()
            installations       = @()
            commandResolutions  = @()
            versionIntelligence = New-NotApplicableVersionIntelligence
        })
    }

    return [pscustomobject][ordered]@{
        providerId = 'dotnet.toolchain'
        category   = 'runtime'
        status     = 'unavailable'
        observedAt = $Context.ObservedAt
        components = $components.ToArray()
        warnings   = @()
        errors     = @()
        evidence   = $evidence.ToArray()
    }
}

if ($dotnetResolutions.Count -gt 1) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DOTNET_COMMAND_COLLISION' -Message 'Multiple dotnet command resolutions were detected. Precedence is preserved instead of silently collapsing them.' -Severity warning -ComponentId 'dotnet-sdk' -EvidenceIds @('dotnet.command-resolution')))
}

$evidence.Add((New-AuditEvidence -EvidenceId 'dotnet.command-resolution' -Type command -Source 'Get-Command dotnet -All' -Captured $null -Attributes @{
    resolutionCount = $dotnetResolutions.Count
    resolutions = @($dotnetResolutions)
}))

$versionResult = Invoke-AuditCommand -Command 'dotnet' -Arguments @('--version') -TimeoutSeconds 20
$activeSdkVersion = if ($versionResult.Status -eq 'success') {
    Get-VersionRecordFromText -Text $versionResult.Captured
}
else {
    $null
}

$evidence.Add((New-AuditEvidence -EvidenceId 'dotnet.version' -Type command -Source 'dotnet --version' -ExitCode $versionResult.ExitCode -Captured $versionResult.Captured -Redacted:$versionResult.Redacted -Attributes @{
    status = $versionResult.Status
    timedOut = $versionResult.TimedOut
    resolutionCount = @($versionResult.Resolutions).Count
}))

$infoResult = Invoke-AuditCommand -Command 'dotnet' -Arguments @('--info') -TimeoutSeconds 25
$evidence.Add((New-AuditEvidence -EvidenceId 'dotnet.info' -Type command -Source 'dotnet --info' -ExitCode $infoResult.ExitCode -Captured $infoResult.Captured -Redacted:$infoResult.Redacted -Attributes @{
    status = $infoResult.Status
    timedOut = $infoResult.TimedOut
}))

$sdkListResult = Invoke-AuditCommand -Command 'dotnet' -Arguments @('--list-sdks') -TimeoutSeconds 25
$sdkItems = if ($sdkListResult.Status -eq 'success') {
    @(Parse-DotNetSdkList -Text $sdkListResult.Captured)
}
else {
    @()
}

$evidence.Add((New-AuditEvidence -EvidenceId 'dotnet.sdks' -Type command -Source 'dotnet --list-sdks' -ExitCode $sdkListResult.ExitCode -Captured $sdkListResult.Captured -Redacted:$sdkListResult.Redacted -Attributes @{
    status = $sdkListResult.Status
    sdkCount = $sdkItems.Count
    sdks = @(
        $sdkItems |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    version = $(if ($null -ne $_.version) { $_.version.normalized } else { $null })
                    root = $_.root
                    path = $_.path
                }
            }
    )
}))

$sdkVersions = New-Object System.Collections.Generic.List[object]
$sdkInstallations = New-Object System.Collections.Generic.List[object]

foreach ($sdk in $sdkItems) {
    Add-UniqueVersion -List $sdkVersions -Version $sdk.version
    Add-UniqueInstallation -List $sdkInstallations -Path ([string]$sdk.path) -Version $sdk.version -Active $(if ($null -ne $activeSdkVersion -and $null -ne $sdk.version) { [string]::Equals([string]$activeSdkVersion.normalized, [string]$sdk.version.normalized, [StringComparison]::OrdinalIgnoreCase) } else { $false }) -Source command
}

$sdkState = 'present'
$sdkInstalled = $true

if ($sdkListResult.Status -ne 'success') {
    $sdkState = 'partial'
    $sdkInstalled = $null
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DOTNET_SDK_LIST_FAILED' -Message 'The dotnet CLI is available, but installed SDK enumeration failed.' -Severity warning -ComponentId 'dotnet-sdk' -EvidenceIds @('dotnet.sdks')))
}
elseif ($sdkItems.Count -eq 0) {
    $sdkState = 'missing'
    $sdkInstalled = $false
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DOTNET_SDK_MISSING' -Message 'The dotnet host is available, but no .NET SDKs were reported.' -Severity warning -ComponentId 'dotnet-sdk' -EvidenceIds @('dotnet.sdks', 'dotnet.version')))
}
elseif ($null -eq $activeSdkVersion) {
    $sdkState = 'partial'
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DOTNET_ACTIVE_SDK_VERSION_INCOMPLETE' -Message 'Installed .NET SDKs were discovered, but the active SDK version could not be determined.' -Severity warning -ComponentId 'dotnet-sdk' -EvidenceIds @('dotnet.version', 'dotnet.sdks')))
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'dotnet-sdk'
    name                = '.NET SDK'
    state               = $sdkState
    installed           = $sdkInstalled
    activeVersion       = $activeSdkVersion
    discoveredVersions  = $sdkVersions.ToArray()
    installations       = $sdkInstallations.ToArray()
    commandResolutions  = $dotnetResolutions
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$runtimeListResult = Invoke-AuditCommand -Command 'dotnet' -Arguments @('--list-runtimes') -TimeoutSeconds 25
$runtimeItems = if ($runtimeListResult.Status -eq 'success') {
    @(Parse-DotNetRuntimeList -Text $runtimeListResult.Captured)
}
else {
    @()
}

$evidence.Add((New-AuditEvidence -EvidenceId 'dotnet.runtimes' -Type command -Source 'dotnet --list-runtimes' -ExitCode $runtimeListResult.ExitCode -Captured $runtimeListResult.Captured -Redacted:$runtimeListResult.Redacted -Attributes @{
    status = $runtimeListResult.Status
    runtimeCount = $runtimeItems.Count
    runtimes = @(
        $runtimeItems |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    product = $_.product
                    version = $(if ($null -ne $_.version) { $_.version.normalized } else { $null })
                    root = $_.root
                    path = $_.path
                }
            }
    )
}))

$runtimeVersions = New-Object System.Collections.Generic.List[object]
$runtimeInstallations = New-Object System.Collections.Generic.List[object]

foreach ($runtime in $runtimeItems) {
    Add-UniqueVersion -List $runtimeVersions -Version $runtime.version
    Add-UniqueInstallation -List $runtimeInstallations -Path ([string]$runtime.path) -Version $runtime.version -Active $false -Source command
}

$runtimeState = if ($runtimeListResult.Status -eq 'success') { 'present' } else { 'partial' }
$runtimeInstalled = if ($runtimeListResult.Status -eq 'success') { ($runtimeItems.Count -gt 0) } else { $null }

if ($runtimeListResult.Status -ne 'success') {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DOTNET_RUNTIME_LIST_FAILED' -Message 'Installed .NET runtime enumeration did not complete successfully.' -Severity warning -ComponentId 'dotnet-runtime' -EvidenceIds @('dotnet.runtimes')))
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'dotnet-runtime'
    name                = '.NET Runtimes'
    state               = $runtimeState
    installed           = $runtimeInstalled
    activeVersion       = $null
    discoveredVersions  = $runtimeVersions.ToArray()
    installations       = $runtimeInstallations.ToArray()
    commandResolutions  = @()
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$workloadState = 'missing'
$workloadInstalled = $false
$workloadIds = @()
$workloadResult = $null
$workloadJson = $null

if ($sdkItems.Count -gt 0) {
    $workloadResult = Invoke-AuditCommand -Command 'dotnet' -Arguments @('workload', 'list', '--machine-readable') -TimeoutSeconds 30

    if ($workloadResult.Status -eq 'success') {
        $workloadJson = Convert-DotNetWorkloadListJson -Text $workloadResult.Captured

        if ($null -ne $workloadJson) {
            $installedProperty = $workloadJson.PSObject.Properties['installed']
            if ($null -ne $installedProperty -and $null -ne $installedProperty.Value) {
                $workloadIds = @(
                    @($installedProperty.Value) |
                        ForEach-Object { [string]$_ } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                )
            }

            $workloadState = 'present'
            $workloadInstalled = ($workloadIds.Count -gt 0)
        }
        else {
            $workloadState = 'partial'
            $workloadInstalled = $null
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'DOTNET_WORKLOAD_LIST_PARSE_FAILED' -Message 'The .NET workload list command succeeded, but its machine-readable output could not be parsed.' -Severity warning -ComponentId 'dotnet-workloads' -EvidenceIds @('dotnet.workloads')))
        }
    }
    else {
        $workloadState = 'partial'
        $workloadInstalled = $null
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'DOTNET_WORKLOAD_LIST_FAILED' -Message 'Installed .NET workloads could not be enumerated for the active SDK.' -Severity warning -ComponentId 'dotnet-workloads' -EvidenceIds @('dotnet.workloads')))
    }

    $workloadCaptured = if ($workloadResult.Status -eq 'success') {
        $null
    }
    else {
        $workloadResult.Captured
    }

    $evidence.Add((New-AuditEvidence -EvidenceId 'dotnet.workloads' -Type command -Source 'dotnet workload list --machine-readable' -ExitCode $workloadResult.ExitCode -Captured $workloadCaptured -Redacted:$workloadResult.Redacted -Attributes @{
        status = $workloadResult.Status
        installed = @($workloadIds)
        installedCount = $workloadIds.Count
        updateMetadataIgnored = $true
        rawOutputRetained = ($workloadResult.Status -ne 'success')
    }))
}
else {
    $evidence.Add((New-AuditEvidence -EvidenceId 'dotnet.workloads' -Type derived -Source 'workload inspection skipped because no SDK is installed' -Captured $null -Attributes @{
        status = 'not-applicable'
        installed = @()
        installedCount = 0
        updateMetadataIgnored = $true
        rawOutputRetained = $false
    }))
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'dotnet-workloads'
    name                = '.NET Workloads'
    state               = $workloadState
    installed           = $workloadInstalled
    activeVersion       = $null
    discoveredVersions  = @()
    installations       = @()
    commandResolutions  = @()
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$status = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial

return [pscustomobject][ordered]@{
    providerId = 'dotnet.toolchain'
    category   = 'runtime'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
