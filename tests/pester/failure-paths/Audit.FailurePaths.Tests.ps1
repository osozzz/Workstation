BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $auditScript = Join-Path $repositoryRoot 'scripts\Audit-Workstation.ps1'
    $escapedCorePath = (Join-Path $repositoryRoot 'scripts\Core\Audit.Core.psm1').Replace("'", "''")

    function New-SyntheticProvider {
        param(
            [Parameter(Mandatory)][string]$Directory,
            [Parameter(Mandatory)][string]$FileName,
            [Parameter(Mandatory)][string]$ProviderId,
            [Parameter(Mandatory)][int]$Order,
            [Parameter(Mandatory)][string]$Run,
            [string]$Category = 'synthetic',
            [switch]$OmitOrder
        )

        $orderLine = if ($OmitOrder) { '' } else { "order = $Order" }

        $content = @"
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]`$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]`$Context
)

if (`$Describe) {
    return [pscustomobject]@{ providerId = '$ProviderId'; category = '$Category'; $orderLine }
}

Import-Module '$escapedCorePath' -Force

$Run
"@

        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Directory $FileName) -Value $content -Encoding UTF8
    }

    function Get-SyntheticResultText {
        param(
            [Parameter(Mandatory)][string]$ProviderId,
            [Parameter(Mandatory)][string]$Status,
            [string]$Category = 'synthetic',
            [string]$Components = '@()',
            [string]$Warnings = '@()',
            [string]$Errors = '@()',
            [string]$Evidence = '@()'
        )

        return @"
return [pscustomobject][ordered]@{
    providerId = '$ProviderId'
    category   = '$Category'
    status     = '$Status'
    observedAt = `$Context.ObservedAt
    components = $Components
    warnings   = $Warnings
    errors     = $Errors
    evidence   = $Evidence
}
"@
    }

    function Invoke-SyntheticAudit {
        param(
            [Parameter(Mandatory)][string]$ProviderDirectory,
            [string[]]$AdditionalProviderPath = @()
        )

        $global:LASTEXITCODE = 0

        $auditArguments = @{
            ProviderDirectory          = $ProviderDirectory
            AdditionalProviderPath     = $AdditionalProviderPath
            LocalConfigurationPath     = Join-Path $TestDrive 'workstation.local.missing.json'
            OutputDirectory            = Join-Path $ProviderDirectory 'reports'
            OfflineVersionIntelligence = $true
            PassThru                   = $true
        }

        return & $auditScript @auditArguments
    }

    $missingComponent = @'
@(
    [pscustomobject][ordered]@{
        componentId         = 'missing-tool'
        name                = 'Synthetic Missing Tool'
        state               = 'missing'
        installed           = $false
        activeVersion       = $null
        discoveredVersions  = @()
        installations       = @()
        commandResolutions  = @()
        versionIntelligence = [pscustomobject][ordered]@{
            status        = 'not-applicable'
            latestStable  = $null
            latestLts     = $null
            latestCurrent = $null
            source        = $null
            checkedAt     = $null
            message       = $null
        }
    }
)
'@

    $offlineComponent = @'
@(
    [pscustomobject][ordered]@{
        componentId         = 'remote-version-source'
        name                = 'Synthetic Remote Version Source'
        state               = 'unavailable'
        installed           = $null
        activeVersion       = $null
        discoveredVersions  = @()
        installations       = @()
        commandResolutions  = @()
        versionIntelligence = [pscustomobject][ordered]@{
            status        = 'unavailable'
            latestStable  = $null
            latestLts     = $null
            latestCurrent = $null
            source        = 'synthetic-offline-source'
            checkedAt     = $Context.ObservedAt
            message       = 'Synthetic remote source is offline.'
        }
    }
)
'@

    $providerDirectory = Join-Path $TestDrive 'failure-providers'
    $missingAdditionalProviderPath = Join-Path $TestDrive 'missing-additional-provider.ps1'

    New-SyntheticProvider -Directory $providerDirectory -FileName '10.MissingDependency.Provider.ps1' -ProviderId 'synthetic.missing-dependency' -Order 10 -Run (@'
$result = Invoke-AuditCommand -Command '__workstation_failure_path_missing_tool__'
if ($result.found -or $result.status -ne 'not-found') {
    throw 'Synthetic missing dependency did not normalize as not-found.'
}

'@ + (Get-SyntheticResultText -ProviderId 'synthetic.missing-dependency' -Status 'success' -Components $missingComponent))

    New-SyntheticProvider -Directory $providerDirectory -FileName '20.CommandNonZero.Provider.ps1' -ProviderId 'synthetic.command-nonzero' -Order 20 -Run (@'
$result = Invoke-AuditCommand -Command 'cmd.exe' -Arguments @('/d', '/c', 'exit 7')
if (-not $result.found -or $result.status -ne 'non-zero' -or $result.exitCode -ne 7) {
    throw 'Synthetic command failure did not preserve the expected non-zero result.'
}

$evidence = New-AuditEvidence -EvidenceId 'synthetic.command.nonzero' -Type command -Source 'synthetic cmd exit 7' -ExitCode $result.exitCode -Captured $result.captured
$commandError = New-AuditIssue -Code 'SYNTHETIC_COMMAND_NONZERO' -Message 'Synthetic command returned exit code 7.' -Severity error -EvidenceIds @('synthetic.command.nonzero')

'@ + (Get-SyntheticResultText -ProviderId 'synthetic.command-nonzero' -Status 'partial' -Errors '@($commandError)' -Evidence '@($evidence)'))

    New-SyntheticProvider -Directory $providerDirectory -FileName '30.MalformedEvidence.Provider.ps1' -ProviderId 'synthetic.malformed-evidence' -Order 30 -Run (
        Get-SyntheticResultText -ProviderId 'synthetic.malformed-evidence' -Status 'success' -Evidence @'
@(
    [pscustomobject][ordered]@{
        evidenceId = 'synthetic.malformed'
        type       = 'derived'
        exitCode   = $null
        captured   = 'Synthetic malformed evidence.'
        redacted   = $false
        attributes = [pscustomobject]@{}
    }
)
'@
    )

    New-SyntheticProvider -Directory $providerDirectory -FileName '31.MalformedComponent.Provider.ps1' -ProviderId 'synthetic.malformed-component' -Order 31 -Run (
        Get-SyntheticResultText -ProviderId 'synthetic.malformed-component' -Status 'success' -Components "@([pscustomobject]@{ componentId = 'partial-record' })"
    )

    New-SyntheticProvider -Directory $providerDirectory -FileName '32.HashtableComponents.Provider.ps1' -ProviderId 'synthetic.hashtable-components' -Order 32 -Run (
        Get-SyntheticResultText -ProviderId 'synthetic.hashtable-components' -Status 'success' -Components '@{ notAnArray = 1 }'
    )

    New-SyntheticProvider -Directory $providerDirectory -FileName '40.RemoteOffline.Provider.ps1' -ProviderId 'synthetic.remote-offline' -Category 'version-intelligence' -Order 40 -Run (
        Get-SyntheticResultText -ProviderId 'synthetic.remote-offline' -Category 'version-intelligence' -Status 'unavailable' -Components $offlineComponent -Warnings @'
@(
    (New-AuditIssue -Code 'SYNTHETIC_REMOTE_UNAVAILABLE' -Message 'Synthetic remote source is offline.' -Severity warning -ComponentId 'remote-version-source')
)
'@
    )

    New-SyntheticProvider -Directory $providerDirectory -FileName '50.Throwing.Provider.ps1' -ProviderId 'synthetic.throwing' -Order 50 -Run "throw 'Controlled synthetic execution failure.'"

    New-SyntheticProvider -Directory $providerDirectory -FileName '60.AfterFailures.Provider.ps1' -ProviderId 'synthetic.after-failures' -Order 60 -Run (@'
$previous = @{}
foreach ($item in @($Context.PreviousProviderResults)) {
    $previous[$item.providerId] = $item.status
}

$expected = @{
    'synthetic.missing-dependency'   = 'success'
    'synthetic.command-nonzero'      = 'partial'
    'synthetic.malformed-evidence'   = 'failed'
    'synthetic.malformed-component'  = 'failed'
    'synthetic.hashtable-components' = 'failed'
    'synthetic.remote-offline'       = 'unavailable'
    'synthetic.throwing'             = 'failed'
}

foreach ($providerId in $expected.Keys) {
    if (-not $previous.ContainsKey($providerId)) {
        throw "Expected prior provider '$providerId' was not visible."
    }

    if ($previous[$providerId] -ne $expected[$providerId]) {
        throw "Prior provider '$providerId' had status '$($previous[$providerId])' instead of '$($expected[$providerId])'."
    }
}

'@ + (Get-SyntheticResultText -ProviderId 'synthetic.after-failures' -Status 'success'))

    New-SyntheticProvider -Directory $providerDirectory -FileName '70.InvalidDescription.Provider.ps1' -ProviderId 'synthetic.invalid-description' -Order 70 -OmitOrder -Run "throw 'Invalid-description provider must never execute its run path.'"

    # The file name contains a separator run ('_-') that previously produced an
    # invalid fallback evidence id and terminated the audit before any report.
    New-SyntheticProvider -Directory $providerDirectory -FileName '80.Bad_-Name.Provider.ps1' -ProviderId 'Synthetic.Uppercase' -Order 80 -Run "throw 'Uppercase-id provider must never execute its run path.'"

    $script:failureAuditResult = Invoke-SyntheticAudit -ProviderDirectory $providerDirectory -AdditionalProviderPath @($missingAdditionalProviderPath)
    $script:exitCodeAfterAudit = $global:LASTEXITCODE
    $script:failureReport = $failureAuditResult.Report
    $script:failureMarkdown = Get-Content -LiteralPath $failureAuditResult.MarkdownPath -Raw

    function Get-FailureProvider {
        param([Parameter(Mandatory)][string]$ProviderId)

        return $failureReport.providers | Where-Object providerId -eq $ProviderId
    }
}

Describe 'Failure-path and provider-isolation hardening' {
    It 'keeps a missing dependency explicit without failing its provider' {
        $provider = Get-FailureProvider 'synthetic.missing-dependency'

        $provider.status | Should -Be 'success'
        @($provider.components) | Should -HaveCount 1
        $provider.components[0].state | Should -Be 'missing'
        $provider.components[0].installed | Should -BeFalse
    }

    It 'preserves a controlled non-zero command result as partial evidence' {
        $provider = Get-FailureProvider 'synthetic.command-nonzero'

        $provider.status | Should -Be 'partial'
        @($provider.errors) | Should -HaveCount 1
        $provider.errors[0].code | Should -Be 'SYNTHETIC_COMMAND_NONZERO'
        @($provider.evidence) | Should -HaveCount 1
        $provider.evidence[0].exitCode | Should -Be 7
    }

    It 'does not leak a provider command exit code into the audit session' {
        $exitCodeAfterAudit | Should -Be 0
    }

    It 'rejects malformed <Name> as an explicit failed provider' -ForEach @(
        @{ Name = 'evidence'; ProviderId = 'synthetic.malformed-evidence'; Message = "evidence is missing 'source'" }
        @{ Name = 'components'; ProviderId = 'synthetic.malformed-component'; Message = "component is missing 'name'" }
        @{ Name = 'collections'; ProviderId = 'synthetic.hashtable-components'; Message = "result 'components' must be an array" }
    ) {
        $provider = Get-FailureProvider $ProviderId

        $provider.status | Should -Be 'failed'
        @($provider.components) | Should -HaveCount 0
        @($provider.errors) | Should -HaveCount 1
        $provider.errors[0].code | Should -Be 'PROVIDER_EXECUTION_FAILED'
        $provider.errors[0].message | Should -BeLike "*$Message*"
    }

    It 'renders the Markdown report after rejecting malformed components' {
        $failureMarkdown | Should -Match '\| synthetic\.malformed-component \| synthetic \| failed \| 0 \| 0 \| 1 \|'
        $failureMarkdown | Should -Match '\| synthetic\.hashtable-components \| synthetic \| failed \| 0 \| 0 \| 1 \|'
    }

    It 'preserves an offline remote source as unavailable rather than success' {
        $provider = Get-FailureProvider 'synthetic.remote-offline'

        $provider.status | Should -Be 'unavailable'
        $provider.components[0].state | Should -Be 'unavailable'
        $provider.components[0].versionIntelligence.status | Should -Be 'unavailable'
        $provider.components[0].versionIntelligence.message | Should -Match 'offline'
    }

    It 'normalizes a direct provider exception without collapsing the audit' {
        $provider = Get-FailureProvider 'synthetic.throwing'

        $provider.status | Should -Be 'failed'
        $provider.errors[0].code | Should -Be 'PROVIDER_EXECUTION_FAILED'
        $provider.errors[0].message | Should -Match 'Controlled synthetic execution failure'
    }

    It 'runs an unrelated provider after middle-of-run failures' {
        (Get-FailureProvider 'synthetic.after-failures').status | Should -Be 'success'
    }

    It 'normalizes invalid provider discovery for <FileName>' -ForEach @(
        @{ FileName = '70.InvalidDescription.Provider.ps1'; FallbackId = 'provider.70.invaliddescription'; Reason = "missing 'order'" }
        @{ FileName = '80.Bad_-Name.Provider.ps1'; FallbackId = 'provider.80.bad-name'; Reason = "invalid providerId 'Synthetic.Uppercase'" }
    ) {
        $provider = Get-FailureProvider $FallbackId

        $provider.status | Should -Be 'failed'
        $provider.category | Should -Be 'unknown'
        $provider.errors[0].code | Should -Be 'PROVIDER_EXECUTION_FAILED'
        $provider.evidence[0].evidenceId | Should -Be "provider.$FallbackId.failure"

        $discoveryErrors = @(
            $failureReport.errors |
                Where-Object { $_.code -eq 'PROVIDER_DISCOVERY_FAILED' -and $_.message -like "*$FileName*" }
        )
        $discoveryErrors | Should -HaveCount 1
        $discoveryErrors[0].message | Should -BeLike "*$Reason*"
    }

    It 'records a missing additional-provider path while every directory provider still runs' {
        @(
            $failureReport.errors |
                Where-Object code -eq 'PROVIDER_PATH_NOT_FOUND'
        ) | Should -HaveCount 1

        $failureReport.summary.providerCount | Should -Be 10
    }

    It 'aggregates every controlled outcome into the summary' {
        $failureReport.summary.status | Should -Be 'failed'
        $failureReport.summary.providerCount | Should -Be 10
        $failureReport.summary.successCount | Should -Be 2
        $failureReport.summary.partialCount | Should -Be 1
        $failureReport.summary.unavailableCount | Should -Be 1
        $failureReport.summary.failedCount | Should -Be 6
        @($failureReport.errors) | Should -HaveCount 3
    }

    It 'keeps all generated state inside the temporary test workspace' {
        Test-Path -LiteralPath $failureAuditResult.JsonPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $failureAuditResult.MarkdownPath -PathType Leaf | Should -BeTrue

        foreach ($path in @($failureAuditResult.JsonPath, $failureAuditResult.MarkdownPath)) {
            [IO.Path]::GetFullPath($path).StartsWith(
                [IO.Path]::GetFullPath($TestDrive),
                [StringComparison]::OrdinalIgnoreCase
            ) | Should -BeTrue
        }
    }
}

Describe 'Aggregate status without report-level errors' {
    BeforeAll {
        $isolatedDirectory = Join-Path $TestDrive 'provider-only-failure'

        New-SyntheticProvider -Directory $isolatedDirectory -FileName '10.Healthy.Provider.ps1' -ProviderId 'synthetic.healthy' -Order 10 -Run (
            Get-SyntheticResultText -ProviderId 'synthetic.healthy' -Status 'success'
        )
        New-SyntheticProvider -Directory $isolatedDirectory -FileName '20.Throwing.Provider.ps1' -ProviderId 'synthetic.throwing' -Order 20 -Run "throw 'Controlled synthetic execution failure.'"

        $script:isolatedReport = (Invoke-SyntheticAudit -ProviderDirectory $isolatedDirectory).Report
    }

    It 'reports failed from provider failures alone' {
        @($isolatedReport.errors) | Should -HaveCount 0
        $isolatedReport.summary.successCount | Should -Be 1
        $isolatedReport.summary.failedCount | Should -Be 1
        $isolatedReport.summary.status | Should -Be 'failed'
    }
}
