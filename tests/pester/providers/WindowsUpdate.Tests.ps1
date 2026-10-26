BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $providerPath = Join-Path $repositoryRoot 'scripts\Providers\WindowsUpdate.Provider.ps1'
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\Audit.Core.psm1') -Force

    function Invoke-WindowsUpdateProvider {
        param([scriptblock]$Search, [bool]$Offline = $false)
        & $providerPath -Context ([pscustomobject]@{ ObservedAt = '2026-10-26T12:00:00+00:00'; VersionIntelligenceOffline = $Offline; WindowsUpdateSearch = $Search })
    }

    $script:probe = @{}
    $probe = $script:probe
    $script:result = Invoke-WindowsUpdateProvider -Search ({
        param($Online)
        $probe['online'] = $Online
        [pscustomobject]@{ updateId = 'a1b2'; title = 'PowerShell v7.6.9 (x64)'; kb = @('5021051'); type = 'software'; isMandatory = $false; mayReboot = $true; categories = @('Updates') }
        [pscustomobject]@{ updateId = 'c3d4'; title = 'Intel - System - 1.2.3'; kb = @(); type = 'driver'; isMandatory = $false; mayReboot = $false; categories = @('Drivers') }
    }.GetNewClosure())
}

Describe 'Windows Update provider' {
    It 'returns a valid provider result with the pending updates' {
        { Assert-AuditProviderResult -Result $script:result -ProviderId 'windows.update' -Category 'host' } | Should -Not -Throw
        $pending = ($script:result.evidence | Where-Object evidenceId -eq 'windows.update.pending').attributes
        $pending.updateCount | Should -Be 2
        $pending.reviewOnly | Should -BeTrue
        $script:probe['online'] | Should -BeTrue
    }

    It 'searches the cached scan when the audit is offline' {
        $probe = @{}
        Invoke-WindowsUpdateProvider -Offline $true -Search ({ param($Online) $probe['online'] = $Online }.GetNewClosure()) | Out-Null
        $probe['online'] | Should -BeFalse
    }

    It 'reports a failed search as a warning instead of failing the audit' {
        $failed = Invoke-WindowsUpdateProvider -Search { param($Online) throw 'service unavailable' }
        $failed.status | Should -Be 'partial'
        @($failed.warnings | ForEach-Object code) | Should -Contain 'WINDOWS_UPDATE_SEARCH_FAILED'
    }
}
