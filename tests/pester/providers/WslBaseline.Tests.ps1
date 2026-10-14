BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $providerPath = Join-Path $repositoryRoot 'scripts\Providers\WslBaseline.Provider.ps1'
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\Audit.Core.psm1') -Force

    function Invoke-WslProvider {
        param(
            [AllowNull()][string[]]$WslScript,
            [AllowNull()][string]$LatestTag = 'v3.0.3',
            [switch]$Offline
        )

        $fakeBin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        if ($null -ne $WslScript) {
            Set-Content -LiteralPath (Join-Path $fakeBin 'wsl.cmd') -Encoding ASCII -Value $WslScript
        }

        $body = '{"tag_name":"' + $LatestTag + '","prerelease":false}'
        $context = [pscustomobject]@{
            ObservedAt                   = '2026-10-14T12:00:00+00:00'
            VersionIntelligenceOffline   = [bool]$Offline
            VersionIntelligenceTransport = { param($Request) [pscustomobject]@{ statusCode = 200; contentType = 'application/json'; body = $body } }.GetNewClosure()
        }

        # Only the fake wsl.cmd is resolvable, so the real WSL on the machine is never queried.
        $originalPath = $env:PATH
        $env:PATH = @($fakeBin, "$env:SystemRoot\System32\WindowsPowerShell\v1.0", "$env:SystemRoot\System32\wbem") -join ';'
        try {
            return & $providerPath -Context $context
        }
        finally {
            $env:PATH = $originalPath
        }
    }

    $script:fakeWsl = @(
        '@echo off'
        'if "%1"=="--version" echo WSL version: 2.5.7.0& echo Kernel version: 6.6.87.1-1& exit /b 0'
        'if "%1"=="--list" echo   NAME              STATE           VERSION& echo * Ubuntu            Stopped         2& echo   docker-desktop    Running         2& exit /b 0'
        'exit /b 1'
    )
    $script:result = Invoke-WslProvider -WslScript $script:fakeWsl
}

Describe 'WSL provider' {
    It 'returns a valid provider result with version and latest release' {
        { Assert-AuditProviderResult -Result $script:result -ProviderId 'wsl.baseline' -Category 'host' } | Should -Not -Throw
        $wsl = $script:result.components[0]
        $wsl.activeVersion.normalized | Should -Be '2.5.7.0'
        $wsl.versionIntelligence.status | Should -Be 'known'
        $wsl.versionIntelligence.latestStable.normalized | Should -Be '3.0.3'
    }

    It 'lists distributions with their state and default flag' {
        $distributions = @((($script:result.evidence | Where-Object evidenceId -eq 'wsl.distributions.normalized').attributes).distributions)
        $distributions | Should -HaveCount 2
        ($distributions | Where-Object name -eq 'Ubuntu').default | Should -BeTrue
        ($distributions | Where-Object name -eq 'docker-desktop').state | Should -Be 'Running'
    }

    It 'only runs commands that never start a distribution' {
        @($script:result.evidence | Where-Object type -eq 'command' | ForEach-Object source) | Should -Be @('wsl --version', 'wsl --list --verbose')
    }

    It 'leaves the latest release unavailable when offline' {
        $offline = Invoke-WslProvider -WslScript $script:fakeWsl -Offline
        $offline.components[0].versionIntelligence.status | Should -Be 'unavailable'
        $offline.components[0].activeVersion.normalized | Should -Be '2.5.7.0'
    }

    It 'reports WSL as unavailable when it is not installed' {
        $missing = Invoke-WslProvider -WslScript $null
        $missing.status | Should -Be 'unavailable'
        $missing.components[0].state | Should -Be 'missing'
    }

    It 'does not leak WSL_UTF8 into the session' {
        $env:WSL_UTF8 | Should -BeNullOrEmpty
    }
}
