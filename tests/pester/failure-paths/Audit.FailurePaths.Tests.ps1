BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $auditScript = Join-Path $repositoryRoot 'scripts\Audit-Workstation.ps1'
    $coreModulePath = Join-Path $repositoryRoot 'scripts\Core\Audit.Core.psm1'

    $providerDirectory = Join-Path $TestDrive 'failure-providers'
    $outputDirectory = Join-Path $TestDrive 'reports'
    $localConfigurationPath = Join-Path $TestDrive 'workstation.local.missing.json'
    $missingAdditionalProviderPath = Join-Path $TestDrive 'missing-additional-provider.ps1'

    New-Item -ItemType Directory -Path $providerDirectory -Force | Out-Null

    function Write-SyntheticProvider {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$Content
        )

        $path = Join-Path $providerDirectory $Name
        Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
        return $path
    }

    $escapedCorePath = $coreModulePath.Replace("'", "''")

    $missingDependencyProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.missing-dependency'
        category   = 'synthetic'
        order      = 10
    }
}

Import-Module '__CORE_PATH__' -Force

$result = Invoke-AuditCommand -Command '__workstation_failure_path_missing_tool__'

if ($result.Found -or $result.Status -ne 'not-found') {
    throw 'Synthetic missing dependency did not normalize as not-found.'
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.missing-dependency'
    category   = 'synthetic'
    status     = 'success'
    observedAt = $Context.ObservedAt
    components = @(
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
    warnings = @()
    errors   = @()
    evidence = @()
}
'@.Replace('__CORE_PATH__', $escapedCorePath)

    $nonZeroProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.command-nonzero'
        category   = 'synthetic'
        order      = 20
    }
}

Import-Module '__CORE_PATH__' -Force

$pwshPath = Join-Path $PSHOME 'pwsh.exe'
$result = Invoke-AuditCommand -Command $pwshPath -Arguments @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'exit 7'
)

if (-not $result.Found -or $result.Status -ne 'non-zero' -or $result.ExitCode -ne 7) {
    throw 'Synthetic command failure did not preserve the expected non-zero result.'
}

$evidence = New-AuditEvidence -EvidenceId 'synthetic.command.nonzero' -Type command -Source 'synthetic pwsh exit 7' -ExitCode $result.ExitCode -Captured $result.Captured
$error = New-AuditIssue -Code 'SYNTHETIC_COMMAND_NONZERO' -Message 'Synthetic command returned exit code 7.' -Severity error -EvidenceIds @('synthetic.command.nonzero')

return [pscustomobject][ordered]@{
    providerId = 'synthetic.command-nonzero'
    category   = 'synthetic'
    status     = 'partial'
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = @()
    errors     = @($error)
    evidence   = @($evidence)
}
'@.Replace('__CORE_PATH__', $escapedCorePath)

    $malformedEvidenceProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.malformed-evidence'
        category   = 'synthetic'
        order      = 30
    }
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.malformed-evidence'
    category   = 'synthetic'
    status     = 'success'
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = @()
    errors     = @()
    evidence   = @(
        [pscustomobject][ordered]@{
            evidenceId = 'synthetic.malformed'
            type       = 'derived'
            exitCode   = $null
            captured   = 'Synthetic malformed evidence.'
            redacted   = $false
            attributes = [pscustomobject]@{}
        }
    )
}
'@

    $offlineProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.remote-offline'
        category   = 'version-intelligence'
        order      = 40
    }
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.remote-offline'
    category   = 'version-intelligence'
    status     = 'unavailable'
    observedAt = $Context.ObservedAt
    components = @(
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
    warnings = @(
        [pscustomobject][ordered]@{
            code        = 'SYNTHETIC_REMOTE_UNAVAILABLE'
            message     = 'Synthetic remote source is offline.'
            severity    = 'warning'
            componentId = 'remote-version-source'
            evidenceIds = @()
        }
    )
    errors   = @()
    evidence = @()
}
'@

    $throwingProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.throwing'
        category   = 'synthetic'
        order      = 50
    }
}

throw 'Controlled synthetic execution failure.'
'@

    $afterFailureProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.after-failures'
        category   = 'synthetic'
        order      = 60
    }
}

$previous = @{}
foreach ($item in @($Context.PreviousProviderResults)) {
    $previous[$item.providerId] = $item.status
}

$expected = @{
    'synthetic.missing-dependency' = 'success'
    'synthetic.command-nonzero'    = 'partial'
    'synthetic.malformed-evidence' = 'failed'
    'synthetic.remote-offline'     = 'unavailable'
    'synthetic.throwing'           = 'failed'
}

foreach ($providerId in $expected.Keys) {
    if (-not $previous.ContainsKey($providerId)) {
        throw "Expected prior provider '$providerId' was not visible."
    }

    if ($previous[$providerId] -ne $expected[$providerId]) {
        throw "Prior provider '$providerId' had status '$($previous[$providerId])' instead of '$($expected[$providerId])'."
    }
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.after-failures'
    category   = 'synthetic'
    status     = 'success'
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = @()
    errors     = @()
    evidence   = @()
}
'@

    $invalidDescriptionProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.invalid-description'
        category   = 'synthetic'
    }
}

throw 'Invalid-description provider must never execute its run path.'
'@

    Write-SyntheticProvider -Name '10.MissingDependency.Provider.ps1' -Content $missingDependencyProvider | Out-Null
    Write-SyntheticProvider -Name '20.CommandNonZero.Provider.ps1' -Content $nonZeroProvider | Out-Null
    Write-SyntheticProvider -Name '30.MalformedEvidence.Provider.ps1' -Content $malformedEvidenceProvider | Out-Null
    Write-SyntheticProvider -Name '40.RemoteOffline.Provider.ps1' -Content $offlineProvider | Out-Null
    Write-SyntheticProvider -Name '50.Throwing.Provider.ps1' -Content $throwingProvider | Out-Null
    Write-SyntheticProvider -Name '60.AfterFailures.Provider.ps1' -Content $afterFailureProvider | Out-Null
    Write-SyntheticProvider -Name '70.InvalidDescription.Provider.ps1' -Content $invalidDescriptionProvider | Out-Null

    $auditArguments = @{
        ProviderDirectory          = $providerDirectory
        AdditionalProviderPath     = @($missingAdditionalProviderPath)
        LocalConfigurationPath     = $localConfigurationPath
        OutputDirectory            = $outputDirectory
        OfflineVersionIntelligence = $true
        PassThru                   = $true
    }

    $script:failureAuditResult = & $auditScript @auditArguments
}

Describe 'Failure-path and provider-isolation hardening' {
    It 'keeps a missing dependency explicit without failing its provider' {
        $provider = $failureAuditResult.Report.providers |
            Where-Object providerId -eq 'synthetic.missing-dependency'

        $provider.status | Should -Be 'success'
        @($provider.components) | Should -HaveCount 1
        $provider.components[0].state | Should -Be 'missing'
        $provider.components[0].installed | Should -BeFalse
    }

    It 'preserves a controlled non-zero command result as partial evidence' {
        $provider = $failureAuditResult.Report.providers |
            Where-Object providerId -eq 'synthetic.command-nonzero'

        $provider.status | Should -Be 'partial'
        @($provider.errors) | Should -HaveCount 1
        $provider.errors[0].code | Should -Be 'SYNTHETIC_COMMAND_NONZERO'
        @($provider.evidence) | Should -HaveCount 1
        $provider.evidence[0].exitCode | Should -Be 7
    }

    It 'rejects malformed provider evidence as an explicit failed provider' {
        $provider = $failureAuditResult.Report.providers |
            Where-Object providerId -eq 'synthetic.malformed-evidence'

        $provider.status | Should -Be 'failed'
        @($provider.errors) | Should -HaveCount 1
        $provider.errors[0].code | Should -Be 'PROVIDER_EXECUTION_FAILED'
        $provider.errors[0].message | Should -Match "evidence is missing 'source'"
    }

    It 'preserves an offline remote source as unavailable rather than success' {
        $provider = $failureAuditResult.Report.providers |
            Where-Object providerId -eq 'synthetic.remote-offline'

        $provider.status | Should -Be 'unavailable'
        $provider.components[0].state | Should -Be 'unavailable'
        $provider.components[0].versionIntelligence.status | Should -Be 'unavailable'
        $provider.components[0].versionIntelligence.message | Should -Match 'offline'
    }

    It 'normalizes a direct provider exception without collapsing the audit' {
        $provider = $failureAuditResult.Report.providers |
            Where-Object providerId -eq 'synthetic.throwing'

        $provider.status | Should -Be 'failed'
        $provider.errors[0].code | Should -Be 'PROVIDER_EXECUTION_FAILED'
        $provider.errors[0].message | Should -Match 'Controlled synthetic execution failure'
    }

    It 'runs an unrelated provider after middle-of-run failures' {
        $provider = $failureAuditResult.Report.providers |
            Where-Object providerId -eq 'synthetic.after-failures'

        $provider.status | Should -Be 'success'
    }

    It 'normalizes invalid provider discovery and records a report-level error' {
        $provider = $failureAuditResult.Report.providers |
            Where-Object providerId -eq 'provider.70.invaliddescription'

        $provider.status | Should -Be 'failed'
        $provider.errors[0].code | Should -Be 'PROVIDER_EXECUTION_FAILED'

        @(
            $failureAuditResult.Report.errors |
                Where-Object code -eq 'PROVIDER_DISCOVERY_FAILED'
        ) | Should -HaveCount 1
    }

    It 'records a missing additional-provider path without stopping valid providers' {
        @(
            $failureAuditResult.Report.errors |
                Where-Object code -eq 'PROVIDER_PATH_NOT_FOUND'
        ) | Should -HaveCount 1

        (
            $failureAuditResult.Report.providers |
                Where-Object providerId -eq 'synthetic.after-failures'
        ).status | Should -Be 'success'
    }

    It 'never converts controlled failures into aggregate success' {
        $failureAuditResult.Report.summary.status | Should -Be 'failed'
        $failureAuditResult.Report.summary.providerCount | Should -Be 7
        $failureAuditResult.Report.summary.successCount | Should -Be 2
        $failureAuditResult.Report.summary.partialCount | Should -Be 1
        $failureAuditResult.Report.summary.unavailableCount | Should -Be 1
        $failureAuditResult.Report.summary.failedCount | Should -Be 3
    }

    It 'keeps all generated state inside the temporary test workspace' {
        Test-Path -LiteralPath $failureAuditResult.JsonPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $failureAuditResult.MarkdownPath -PathType Leaf | Should -BeTrue

        [IO.Path]::GetFullPath($failureAuditResult.JsonPath).StartsWith(
            [IO.Path]::GetFullPath($TestDrive),
            [StringComparison]::OrdinalIgnoreCase
        ) | Should -BeTrue
    }
}
