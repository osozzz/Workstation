BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $providerPath = Join-Path $repositoryRoot 'scripts\Providers\JavaScriptToolchain.Provider.ps1'

    # Prisma 8 prints its version as a one-line JSON document.
    $fakeBin = Join-Path $TestDrive 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeBin 'prisma.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'echo {"kind":"result","envelope":{"ok":true,"commandId":"version","result":{"version":"8.0.0-rc.15"},"exitCode":0,"diagnostics":[],"nextActions":[]},"commandId":"version","timestamp":"2026-09-29T14:13:19.061Z"}'
    )

    # Only the operating system and the fake Prisma are resolvable, so every other
    # JavaScript CLI is absent regardless of what the runner has installed.
    $originalPath = $env:PATH
    $env:PATH = @($fakeBin, "$env:SystemRoot\System32", $env:SystemRoot) -join ';'

    try {
        $context = [pscustomobject][ordered]@{
            ObservedAt                 = '2026-09-29T12:00:00+00:00'
            EnvironmentVariableNames   = @('NVM_HOME', 'NVM_SYMLINK', 'PNPM_HOME')
            VersionIntelligenceOffline = $true
            PreviousProviderResults    = @()
        }

        $script:providerResult = & $providerPath -Context $context
    }
    finally {
        $env:PATH = $originalPath
    }

    function Get-CliComponent {
        param([Parameter(Mandatory)][string]$ComponentId)

        return $providerResult.components | Where-Object componentId -eq $ComponentId
    }
}

Describe 'JavaScript toolchain CLI detection' {
    It 'reports an absent <ComponentId> as missing without inventing installations' -ForEach @(
        @{ ComponentId = 'angular-cli' }
        @{ ComponentId = 'typescript' }
        @{ ComponentId = 'nodemon' }
        @{ ComponentId = 'rimraf' }
        @{ ComponentId = 'zoho-extension-toolkit' }
        @{ ComponentId = 'zoho-catalyst-cli' }
        @{ ComponentId = 'redis-commander' }
    ) {
        $component = Get-CliComponent $ComponentId

        $component.state | Should -Be 'missing'
        $component.installed | Should -BeFalse
        @($component.installations) | Should -HaveCount 0
    }

    It 'raises no unresolved-command warnings for absent CLIs' {
        $cliIds = @('angular-cli', 'typescript', 'nodemon', 'rimraf', 'zoho-extension-toolkit', 'zoho-catalyst-cli', 'redis-commander')

        @(
            $providerResult.warnings |
                Where-Object { $_.code -eq 'JAVASCRIPT_COMMAND_UNRESOLVED' -and $_.componentId -in $cliIds }
        ) | Should -HaveCount 0
    }

    It 'reads the version field from JSON --version output' {
        $prisma = Get-CliComponent 'prisma'

        $prisma.state | Should -Be 'present'
        $prisma.activeVersion.raw | Should -BeExactly '8.0.0-rc.15'
        $prisma.activeVersion.normalized | Should -BeExactly '8.0.0-rc.15'
    }
}
