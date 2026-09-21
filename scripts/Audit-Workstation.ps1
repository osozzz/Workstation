[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\reports'),

    [switch]$IncludeWingetInventory,

    [string]$ProviderDirectory = (Join-Path $PSScriptRoot 'Providers'),

    [string[]]$AdditionalProviderPath = @(),

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$corePath = Join-Path $PSScriptRoot 'Core\Audit.Core.psm1'
Import-Module $corePath -Force

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Convert-ToMarkdownSafe {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return ($Value.ToString() -replace '\|', '\|' -replace [Environment]::NewLine, '<br>')
}

function Get-HostArchitecture {
    $value = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    }
    else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch -Regex ($value) {
        '^(AMD64|x64)$' { return 'x64' }
        '^ARM64$' { return 'arm64' }
        '^(x86|i386)$' { return 'x86' }
        default {
            if ([string]::IsNullOrWhiteSpace($value)) {
                return 'unknown'
            }
            return $value.ToLowerInvariant()
        }
    }
}

function Get-FallbackProviderId {
    param([Parameter(Mandatory)][string]$Path)

    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $name = $name -replace '\.Provider$', ''
    $name = $name.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $name = $name.Trim('-', '.', '_')

    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = 'unknown'
    }

    return "provider.$name"
}

function Test-ProviderDescription {
    param(
        [Parameter(Mandatory)][object]$Description,
        [Parameter(Mandatory)][string]$Path
    )

    foreach ($property in @('providerId', 'category', 'order')) {
        if ($null -eq $Description.PSObject.Properties[$property]) {
            throw "Provider '$Path' description is missing '$property'."
        }
    }

    if ($Description.providerId -notmatch '^[a-z0-9]+(?:[._-][a-z0-9]+)*$') {
        throw "Provider '$Path' returned invalid providerId '$($Description.providerId)'."
    }

    if ($Description.category -notmatch '^[a-z][a-z0-9-]*$') {
        throw "Provider '$Path' returned invalid category '$($Description.category)'."
    }

    [int]$order = 0
    if (-not [int]::TryParse($Description.order.ToString(), [ref]$order)) {
        throw "Provider '$Path' returned a non-numeric order."
    }
}

function Test-ProviderResultShape {
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][object]$Registration
    )

    foreach ($property in @('providerId', 'category', 'status', 'observedAt', 'components', 'warnings', 'errors', 'evidence')) {
        if ($null -eq $Result.PSObject.Properties[$property]) {
            throw "Provider '$($Registration.providerId)' result is missing '$property'."
        }
    }

    if ($Result.providerId -ne $Registration.providerId) {
        throw "Provider result id '$($Result.providerId)' does not match registered id '$($Registration.providerId)'."
    }

    if ($Result.category -ne $Registration.category) {
        throw "Provider '$($Registration.providerId)' returned category '$($Result.category)' instead of '$($Registration.category)'."
    }

    if ($Result.status -notin @('success', 'warning', 'partial', 'failed', 'unavailable', 'not-applicable')) {
        throw "Provider '$($Registration.providerId)' returned invalid status '$($Result.status)'."
    }
}

function New-FailedProviderResult {
    param(
        [Parameter(Mandatory)][object]$Registration,
        [Parameter(Mandatory)][string]$ObservedAt,
        [Parameter(Mandatory)][string]$Message
    )

    $safeEvidenceId = "provider.$($Registration.providerId).failure"
    $evidence = New-AuditEvidence -EvidenceId $safeEvidenceId -Type derived -Source $Registration.path -Captured $Message
    $error = New-AuditIssue -Code 'PROVIDER_EXECUTION_FAILED' -Message $Message -Severity error -EvidenceIds @($safeEvidenceId)

    return [pscustomobject][ordered]@{
        providerId = $Registration.providerId
        category   = $Registration.category
        status     = 'failed'
        observedAt = $ObservedAt
        components = @()
        warnings   = @()
        errors     = @($error)
        evidence   = @($evidence)
    }
}

Ensure-Directory -Path $OutputDirectory

$timestamp = Get-Date
$observedAt = $timestamp.ToString('o')
$stamp = $timestamp.ToString('yyyyMMdd-HHmmss')

$computerName = [Environment]::MachineName
if ([string]::IsNullOrWhiteSpace($computerName)) {
    $computerName = 'Windows-PC'
}
$safeComputerName = $computerName -replace '[^A-Za-z0-9._-]', '_'

$versionPath = Join-Path $PSScriptRoot '..\VERSION'
$toolVersion = if (Test-Path -LiteralPath $versionPath) {
    (Get-Content -LiteralPath $versionPath -Raw).Trim()
}
else {
    '0.0.0'
}

$environmentVariableNames = @(
    'NVM_HOME',
    'NVM_SYMLINK',
    'PNPM_HOME',
    'JAVA_HOME',
    'ANDROID_HOME',
    'ANDROID_SDK_ROOT',
    'FLUTTER_ROOT',
    'PUB_CACHE',
    'CARGO_HOME',
    'RUSTUP_HOME',
    'GOPATH',
    'GOROOT',
    'PYENV_ROOT'
)

$context = [pscustomobject][ordered]@{
    ObservedAt               = $observedAt
    ToolVersion              = $toolVersion
    IncludeWingetInventory   = [bool]$IncludeWingetInventory
    EnvironmentVariableNames = $environmentVariableNames
}

$reportWarnings = New-Object System.Collections.Generic.List[object]
$reportErrors = New-Object System.Collections.Generic.List[object]

$providerPaths = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $ProviderDirectory) {
    Get-ChildItem -LiteralPath $ProviderDirectory -Filter '*.Provider.ps1' -File |
        ForEach-Object { $providerPaths.Add($_.FullName) }
}
else {
    $message = "Provider directory '$ProviderDirectory' was not found."
    $reportErrors.Add((New-AuditIssue -Code 'PROVIDER_DIRECTORY_NOT_FOUND' -Message $message -Severity error -EvidenceIds @()))
}

foreach ($path in $AdditionalProviderPath) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
        if (-not $providerPaths.Contains($resolvedPath)) {
            $providerPaths.Add($resolvedPath)
        }
    }
    catch {
        $message = "Additional provider path '$path' could not be resolved: $($_.Exception.Message)"
        $reportErrors.Add((New-AuditIssue -Code 'PROVIDER_PATH_NOT_FOUND' -Message $message -Severity error -EvidenceIds @()))
    }
}

$registrations = New-Object System.Collections.Generic.List[object]

foreach ($path in $providerPaths) {
    try {
        $description = & $path -Describe
        Test-ProviderDescription -Description $description -Path $path

        $registrations.Add([pscustomobject][ordered]@{
            providerId = $description.providerId
            category   = $description.category
            order      = [int]$description.order
            path       = $path
        })
    }
    catch {
        $fallbackId = Get-FallbackProviderId -Path $path
        $message = "Provider discovery failed for '$path': $($_.Exception.Message)"
        $reportErrors.Add((New-AuditIssue -Code 'PROVIDER_DISCOVERY_FAILED' -Message $message -Severity error -EvidenceIds @()))

        $registrations.Add([pscustomobject][ordered]@{
            providerId = $fallbackId
            category   = 'unknown'
            order      = 2147483647
            path       = $path
            discoveryFailure = $message
        })
    }
}

$orderedRegistrations = @(
    $registrations |
        Sort-Object @{ Expression = 'order'; Ascending = $true }, @{ Expression = 'providerId'; Ascending = $true }, @{ Expression = 'path'; Ascending = $true }
)

$duplicateProviderIds = @(
    $orderedRegistrations |
        Group-Object providerId |
        Where-Object { $_.Count -gt 1 }
)

if ($duplicateProviderIds.Count -gt 0) {
    foreach ($duplicate in $duplicateProviderIds) {
        $message = "Duplicate providerId '$($duplicate.Name)' was registered $($duplicate.Count) times. Those registrations were skipped."
        $reportErrors.Add((New-AuditIssue -Code 'PROVIDER_ID_DUPLICATE' -Message $message -Severity error -EvidenceIds @()))
    }

    $duplicateNames = @($duplicateProviderIds | ForEach-Object { $_.Name })
    $orderedRegistrations = @(
        $orderedRegistrations |
            Where-Object { $_.providerId -notin $duplicateNames }
    )
}

$providerResults = New-Object System.Collections.Generic.List[object]

foreach ($registration in $orderedRegistrations) {
    $discoveryFailureProperty = $registration.PSObject.Properties['discoveryFailure']
    if ($discoveryFailureProperty -and $discoveryFailureProperty.Value) {
        $providerResults.Add((New-FailedProviderResult -Registration $registration -ObservedAt $observedAt -Message $discoveryFailureProperty.Value))
        continue
    }

    try {
        $result = & $registration.path -Context $context
        Test-ProviderResultShape -Result $result -Registration $registration
        $providerResults.Add($result)
    }
    catch {
        $message = "Provider '$($registration.providerId)' failed: $($_.Exception.Message)"
        $providerResults.Add((New-FailedProviderResult -Registration $registration -ObservedAt $observedAt -Message $message))
    }
}

$providers = $providerResults.ToArray()
$successCount = @($providers | Where-Object { $_.status -eq 'success' }).Count
$warningCount = @($providers | Where-Object { $_.status -eq 'warning' }).Count
$partialCount = @($providers | Where-Object { $_.status -eq 'partial' }).Count
$failedCount = @($providers | Where-Object { $_.status -eq 'failed' }).Count
$unavailableCount = @($providers | Where-Object { $_.status -eq 'unavailable' }).Count
$notApplicableCount = @($providers | Where-Object { $_.status -eq 'not-applicable' }).Count

$summaryStatus = if ($failedCount -gt 0 -or $reportErrors.Count -gt 0) {
    'failed'
}
elseif ($partialCount -gt 0 -or $unavailableCount -gt 0) {
    'partial'
}
elseif ($warningCount -gt 0 -or $reportWarnings.Count -gt 0) {
    'warning'
}
else {
    'success'
}

$report = [pscustomobject][ordered]@{
    schemaVersion = '1.0.0'
    generatedAt   = $observedAt
    audit         = [pscustomobject][ordered]@{
        mode        = 'read-only'
        toolVersion = $toolVersion
    }
    host          = [pscustomobject][ordered]@{
        name         = $computerName
        platform     = 'windows'
        architecture = Get-HostArchitecture
    }
    summary       = [pscustomobject][ordered]@{
        status             = $summaryStatus
        providerCount      = $providers.Count
        successCount       = $successCount
        warningCount       = $warningCount
        partialCount       = $partialCount
        failedCount        = $failedCount
        unavailableCount   = $unavailableCount
        notApplicableCount = $notApplicableCount
    }
    providers     = $providers
    warnings      = $reportWarnings.ToArray()
    errors        = $reportErrors.ToArray()
}

$jsonPath = Join-Path $OutputDirectory "$safeComputerName-$stamp.json"
$mdPath = Join-Path $OutputDirectory "$safeComputerName-$stamp.md"

$report | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Developer Workstation Audit')
$md.Add('')
$md.Add("- **Computer:** $computerName")
$md.Add("- **Generated:** $($timestamp.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
$md.Add("- **Tool version:** $toolVersion")
$md.Add("- **Schema:** $($report.schemaVersion)")
$md.Add("- **Audit status:** $($report.summary.status)")
$md.Add('')
$md.Add('> Read-only audit. Machine-specific reports stay local and evidence is limited by the audit safety policy.')
$md.Add('')
$md.Add('## Provider summary')
$md.Add('')
$md.Add('| Provider | Category | Status | Components | Warnings | Errors |')
$md.Add('|---|---|---|---:|---:|---:|')

foreach ($provider in $providers) {
    $md.Add("| $(Convert-ToMarkdownSafe $provider.providerId) | $(Convert-ToMarkdownSafe $provider.category) | $(Convert-ToMarkdownSafe $provider.status) | $(@($provider.components).Count) | $(@($provider.warnings).Count) | $(@($provider.errors).Count) |")
}

$md.Add('')
$md.Add('## Components')
$md.Add('')
$md.Add('| Provider | Component | State | Installed | Active version |')
$md.Add('|---|---|---|:---:|---|')

foreach ($provider in $providers) {
    foreach ($component in @($provider.components)) {
        $version = if ($component.activeVersion) { $component.activeVersion.raw } else { '' }
        $installed = if ($null -eq $component.installed) { '' } elseif ($component.installed) { 'Yes' } else { 'No' }
        $md.Add("| $(Convert-ToMarkdownSafe $provider.providerId) | $(Convert-ToMarkdownSafe $component.name) | $(Convert-ToMarkdownSafe $component.state) | $installed | $(Convert-ToMarkdownSafe $version) |")
    }
}

$providerWarnings = @($providers | ForEach-Object { @($_.warnings) })
$providerErrors = @($providers | ForEach-Object { @($_.errors) })
$allWarnings = @($report.warnings) + $providerWarnings
$allErrors = @($report.errors) + $providerErrors

$md.Add('')
$md.Add('## Findings')
$md.Add('')

if ($allWarnings.Count -eq 0 -and $allErrors.Count -eq 0) {
    $md.Add('- No warnings or errors were reported by the current providers.')
}
else {
    foreach ($item in $allErrors) {
        $md.Add("- **ERROR $($item.code):** $(Convert-ToMarkdownSafe $item.message)")
    }
    foreach ($item in $allWarnings) {
        $md.Add("- **$($item.severity.ToUpperInvariant()) $($item.code):** $(Convert-ToMarkdownSafe $item.message)")
    }
}

$md -join [Environment]::NewLine | Set-Content -LiteralPath $mdPath -Encoding UTF8

Write-Host ''
Write-Host 'Audit complete.' -ForegroundColor Green
Write-Host "JSON: $jsonPath"
Write-Host "Markdown: $mdPath"
Write-Host "Providers: $($report.summary.providerCount) | Status: $($report.summary.status)"
Write-Host ''

if ($PassThru) {
    return [pscustomobject][ordered]@{
        Report       = $report
        JsonPath     = $jsonPath
        MarkdownPath = $mdPath
    }
}
