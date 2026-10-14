BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $providerPath = Join-Path $repositoryRoot 'scripts\Providers\ChocolateyBaseline.Provider.ps1'
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\Audit.Core.psm1') -Force

    function Invoke-ChocolateyProvider {
        param([string[]]$ChocoScript)

        $fakeBin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        if ($null -ne $ChocoScript) {
            Set-Content -LiteralPath (Join-Path $fakeBin 'choco.cmd') -Encoding ASCII -Value $ChocoScript
        }

        $originalPath = $env:PATH
        $env:PATH = @($fakeBin, "$env:SystemRoot\System32", $env:SystemRoot) -join ';'
        try {
            return & $providerPath -Context ([pscustomobject]@{ ObservedAt = '2026-10-14T12:00:00+00:00' })
        }
        finally {
            $env:PATH = $originalPath
        }
    }

    # Chocolatey 2.x: "list" is local; "outdated" exits 2 when packages are outdated (enhanced exit codes).
    $script:fakeChoco = @(
        '@echo off'
        'if "%1"=="--version" echo 2.6.0& exit /b 0'
        'if "%1"=="list" echo chocolatey^|2.6.0& echo python314^|3.14.2& echo git^|2.51.0& exit /b 0'
        'if "%1"=="outdated" echo python314^|3.14.2^|3.14.8^|false& echo git^|2.51.0^|3.0.0^|true& exit /b 2'
        'exit /b 1'
    )
    $script:result = Invoke-ChocolateyProvider -ChocoScript $script:fakeChoco

    function Get-ChocoEvidence {
        param([string]$EvidenceId)
        ($script:result.evidence | Where-Object evidenceId -eq $EvidenceId).attributes
    }
}

Describe 'Chocolatey provider' {
    It 'returns a valid provider result' {
        { Assert-AuditProviderResult -Result $script:result -ProviderId 'chocolatey.baseline' -Category 'package-manager' } | Should -Not -Throw
        $script:result.status | Should -Be 'success'
        $script:result.components[0].activeVersion.normalized | Should -Be '2.6.0'
    }

    It 'normalizes installed packages' {
        $inventory = Get-ChocoEvidence 'chocolatey.inventory.normalized'
        $inventory.packageCount | Should -Be 3
        ($inventory.packages | Where-Object packageId -eq 'python314').installedVersion | Should -Be '3.14.2'
    }

    It 'treats exit code 2 from outdated as success and keeps the pinned flag' {
        $outdated = Get-ChocoEvidence 'chocolatey.outdated.normalized'
        $outdated.status | Should -Be 'known'
        $outdated.upgradeCount | Should -Be 2
        ($outdated.upgrades | Where-Object packageId -eq 'python314').availableVersion | Should -Be '3.14.8'
        ($outdated.upgrades | Where-Object packageId -eq 'git').pinned | Should -BeTrue
    }

    It 'only runs read-only Chocolatey commands' {
        @($script:result.evidence | Where-Object type -eq 'command' | ForEach-Object source) |
            Should -Be @('choco --version', 'choco list --limit-output', 'choco outdated --limit-output')
    }

    It 'reports Chocolatey as missing when it is not installed' {
        $missing = Invoke-ChocolateyProvider -ChocoScript $null
        $missing.components[0].state | Should -Be 'missing'
        @($missing.evidence) | Should -HaveCount 0
    }

    It 'warns when the outdated lookup fails' {
        $failing = Invoke-ChocolateyProvider -ChocoScript ($script:fakeChoco -replace 'exit /b 2', 'exit /b 1')
        @($failing.warnings | ForEach-Object code) | Should -Contain 'CHOCOLATEY_OUTDATED_QUERY_FAILED'
        (($failing.evidence | Where-Object evidenceId -eq 'chocolatey.outdated.normalized').attributes).status | Should -Be 'unavailable'
    }
}
