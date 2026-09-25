BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $auditScript = Join-Path $repositoryRoot 'scripts\Audit-Workstation.ps1'

    $providerDirectory = Join-Path $TestDrive 'providers'
    $outputDirectory = Join-Path $TestDrive 'reports'
    $localConfigurationPath = Join-Path $TestDrive 'workstation.local.missing.json'

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

    $successProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.success'
        category   = 'synthetic'
        order      = 10
    }
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.success'
    category   = 'synthetic'
    status     = 'success'
    observedAt = $Context.ObservedAt
    components = @(
        [pscustomobject][ordered]@{
            componentId        = 'synthetic-present'
            name               = 'Synthetic Present'
            state              = 'present'
            installed          = $true
            activeVersion      = $null
            discoveredVersions = @()
            installations      = @()
            commandResolutions = @()
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
    warnings   = @()
    errors     = @()
    evidence   = @()
}
'@

    $missingProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.missing'
        category   = 'synthetic'
        order      = 20
    }
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.missing'
    category   = 'synthetic'
    status     = 'success'
    observedAt = $Context.ObservedAt
    components = @(
        [pscustomobject][ordered]@{
            componentId        = 'synthetic-missing'
            name               = 'Synthetic Missing'
            state              = 'missing'
            installed          = $false
            activeVersion      = $null
            discoveredVersions = @()
            installations      = @()
            commandResolutions = @()
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
'@

    $partialProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.partial'
        category   = 'synthetic'
        order      = 30
    }
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.partial'
    category   = 'synthetic'
    status     = 'partial'
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = @()
    errors     = @(
        [pscustomobject][ordered]@{
            code        = 'SYNTHETIC_PARTIAL'
            message     = 'A controlled part of the synthetic inspection was unavailable.'
            severity    = 'error'
            componentId = $null
            evidenceIds = @()
        }
    )
    evidence = @()
}
'@

    $unavailableProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.unavailable'
        category   = 'synthetic'
        order      = 40
    }
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.unavailable'
    category   = 'synthetic'
    status     = 'unavailable'
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = @()
    errors     = @()
    evidence   = @()
}
'@

    $failureProvider = @'
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'synthetic.failure'
        category   = 'synthetic'
        order      = 50
    }
}

throw 'Controlled synthetic provider failure.'
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
        providerId = 'synthetic.after-failure'
        category   = 'synthetic'
        order      = 60
    }
}

$failed = @(
    $Context.PreviousProviderResults |
        Where-Object providerId -eq 'synthetic.failure'
)

if ($failed.Count -ne 1 -or $failed[0].status -ne 'failed') {
    throw 'Expected the prior provider failure to be normalized before later providers execute.'
}

return [pscustomobject][ordered]@{
    providerId = 'synthetic.after-failure'
    category   = 'synthetic'
    status     = 'success'
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = @()
    errors     = @()
    evidence   = @()
}
'@

    Write-SyntheticProvider -Name '10.Success.Provider.ps1' -Content $successProvider | Out-Null
    Write-SyntheticProvider -Name '20.Missing.Provider.ps1' -Content $missingProvider | Out-Null
    Write-SyntheticProvider -Name '30.Partial.Provider.ps1' -Content $partialProvider | Out-Null
    Write-SyntheticProvider -Name '40.Unavailable.Provider.ps1' -Content $unavailableProvider | Out-Null
    Write-SyntheticProvider -Name '50.Failure.Provider.ps1' -Content $failureProvider | Out-Null
    Write-SyntheticProvider -Name '60.AfterFailure.Provider.ps1' -Content $afterFailureProvider | Out-Null

    $auditArguments = @{
        ProviderDirectory           = $providerDirectory
        AdditionalProviderPath      = @()
        LocalConfigurationPath      = $localConfigurationPath
        OutputDirectory             = $outputDirectory
        OfflineVersionIntelligence  = $true
        PassThru                    = $true
    }

    $script:auditResult = & $auditScript @auditArguments
}

Describe 'Synthetic provider contract orchestration' {
    It 'executes only the controlled synthetic provider set' {
        $auditResult.Report.summary.providerCount | Should -Be 6
        @($auditResult.Report.providers) | Should -HaveCount 6

        @($auditResult.Report.providers.providerId) | Should -Be @(
            'synthetic.success',
            'synthetic.missing',
            'synthetic.partial',
            'synthetic.unavailable',
            'synthetic.failure',
            'synthetic.after-failure'
        )
    }

    It 'preserves present and missing component state semantics' {
        $presentProvider = $auditResult.Report.providers | Where-Object providerId -eq 'synthetic.success'
        $missingProvider = $auditResult.Report.providers | Where-Object providerId -eq 'synthetic.missing'

        $presentProvider.components[0].state | Should -Be 'present'
        $presentProvider.components[0].installed | Should -BeTrue

        $missingProvider.components[0].state | Should -Be 'missing'
        $missingProvider.components[0].installed | Should -BeFalse
    }

    It 'preserves partial and unavailable provider outcomes' {
        ($auditResult.Report.providers | Where-Object providerId -eq 'synthetic.partial').status |
            Should -Be 'partial'

        ($auditResult.Report.providers | Where-Object providerId -eq 'synthetic.unavailable').status |
            Should -Be 'unavailable'
    }

    It 'normalizes a thrown provider exception as a failed provider result' {
        $failedProvider = $auditResult.Report.providers | Where-Object providerId -eq 'synthetic.failure'

        $failedProvider.status | Should -Be 'failed'
        @($failedProvider.errors) | Should -HaveCount 1
        $failedProvider.errors[0].code | Should -Be 'PROVIDER_EXECUTION_FAILED'
    }

    It 'continues to later providers after an isolated provider failure' {
        $afterFailure = $auditResult.Report.providers | Where-Object providerId -eq 'synthetic.after-failure'

        $afterFailure.status | Should -Be 'success'
    }

    It 'derives aggregate summary counts from provider outcomes' {
        $auditResult.Report.summary.status | Should -Be 'failed'
        $auditResult.Report.summary.successCount | Should -Be 3
        $auditResult.Report.summary.partialCount | Should -Be 1
        $auditResult.Report.summary.unavailableCount | Should -Be 1
        $auditResult.Report.summary.failedCount | Should -Be 1
    }

    It 'keeps generated reports inside the Pester temporary workspace' {
        Test-Path -LiteralPath $auditResult.JsonPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $auditResult.MarkdownPath -PathType Leaf | Should -BeTrue

        [IO.Path]::GetFullPath($auditResult.JsonPath).StartsWith(
            [IO.Path]::GetFullPath($TestDrive),
            [StringComparison]::OrdinalIgnoreCase
        ) | Should -BeTrue
    }
}
