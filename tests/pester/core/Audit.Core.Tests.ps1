BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $coreModulePath = Join-Path $repositoryRoot 'scripts\Core\Audit.Core.psm1'
    Import-Module $coreModulePath -Force
}

Describe 'Audit core provider status normalization' {
    It 'returns success when no degraded condition is present' {
        Get-AuditProviderStatus | Should -Be 'success'
    }

    It 'returns warning when warnings are present' {
        $warning = New-AuditIssue -Code 'SYNTHETIC_WARNING' -Message 'Synthetic warning.' -Severity warning
        Get-AuditProviderStatus -Warnings @($warning) | Should -Be 'warning'
    }

    It 'returns partial when errors are present without a fatal failure' {
        $error = New-AuditIssue -Code 'SYNTHETIC_ERROR' -Message 'Synthetic partial error.' -Severity error
        Get-AuditProviderStatus -Errors @($error) | Should -Be 'partial'
    }

    It 'returns partial when explicitly marked partial' {
        Get-AuditProviderStatus -Partial | Should -Be 'partial'
    }

    It 'returns unavailable when the provider capability is unavailable' {
        Get-AuditProviderStatus -Unavailable | Should -Be 'unavailable'
    }

    It 'returns failed for fatal provider failure' {
        Get-AuditProviderStatus -Failed | Should -Be 'failed'
    }

    It 'returns not-applicable when the provider does not apply' {
        Get-AuditProviderStatus -NotApplicable | Should -Be 'not-applicable'
    }
}

Describe 'Audit core normalized evidence and issue behavior' {
    It 'redacts sensitive evidence instead of preserving captured content' {
        $evidence = New-AuditEvidence -EvidenceId 'synthetic.secret' -Type command -Source 'synthetic command' -Captured 'sensitive-value' -Sensitive

        $evidence.redacted | Should -BeTrue
        $evidence.captured | Should -BeNullOrEmpty
        $evidence.evidenceId | Should -Be 'synthetic.secret'
    }

    It 'deduplicates evidence references on normalized issues' {
        $issue = New-AuditIssue -Code 'SYNTHETIC_DUPLICATE' -Message 'Synthetic issue.' -Severity warning -EvidenceIds @(
            'synthetic.one',
            'synthetic.one',
            'synthetic.two'
        )

        @($issue.evidenceIds) | Should -HaveCount 2
        @($issue.evidenceIds) | Should -Contain 'synthetic.one'
        @($issue.evidenceIds) | Should -Contain 'synthetic.two'
    }
}

Describe 'Audit core missing-command behavior' {
    It 'normalizes an intentionally missing command without throwing' {
        $result = Invoke-AuditCommand -Command '__workstation_pester_command_that_does_not_exist__'

        $result.found | Should -BeFalse
        $result.status | Should -Be 'not-found'
        $result.exitCode | Should -BeNullOrEmpty
        $result.timedOut | Should -BeFalse
        @($result.resolutions) | Should -HaveCount 0
    }
}
