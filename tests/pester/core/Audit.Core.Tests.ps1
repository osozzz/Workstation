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

Describe 'Audit core command exit-code isolation' {
    It 'keeps a child exit code in the result without leaking it into the session' {
        $global:LASTEXITCODE = 0

        $result = Invoke-AuditCommand -Command 'cmd.exe' -Arguments @('/d', '/c', 'exit 7')

        $result.status | Should -Be 'non-zero'
        $result.exitCode | Should -Be 7
        $global:LASTEXITCODE | Should -Be 0
    }
}

Describe 'Audit core provider result validation' {
    BeforeAll {
        function New-ValidProviderResult {
            $evidence = New-AuditEvidence -EvidenceId 'synthetic.version' -Type command -Source 'synthetic --version' -ExitCode 0 -Captured 'v1.2.3'
            $warning = New-AuditIssue -Code 'SYNTHETIC_WARNING' -Message 'Synthetic warning.' -Severity warning -ComponentId 'synthetic-tool' -EvidenceIds @('synthetic.version')

            return [pscustomobject][ordered]@{
                providerId = 'synthetic.valid'
                category   = 'synthetic'
                status     = 'warning'
                observedAt = (Get-Date).ToString('o')
                components = @(
                    [pscustomobject][ordered]@{
                        componentId         = 'synthetic-tool'
                        name                = 'Synthetic Tool'
                        state               = 'present'
                        installed           = $true
                        activeVersion       = New-AuditVersionRecord -Raw 'v1.2.3' -Normalized '1.2.3' -Channel 'stable'
                        discoveredVersions  = @(New-AuditVersionRecord -Raw 'v1.2.3' -Normalized '1.2.3')
                        installations       = @(
                            [pscustomobject][ordered]@{
                                path    = 'C:\Synthetic\tool.exe'
                                version = New-AuditVersionRecord -Raw 'v1.2.3'
                                active  = $true
                                source  = 'command'
                            }
                        )
                        commandResolutions  = @(
                            [pscustomobject][ordered]@{
                                command     = 'tool'
                                path        = 'C:\Synthetic\tool.exe'
                                commandType = 'Application'
                                version     = $null
                                precedence  = 0
                                active      = $true
                            }
                        )
                        versionIntelligence = [pscustomobject][ordered]@{
                            status        = 'known'
                            latestStable  = New-AuditVersionRecord -Raw '1.3.0'
                            latestLts     = $null
                            latestCurrent = $null
                            source        = 'synthetic-source'
                            checkedAt     = '2026-09-28T10:00:00Z'
                            message       = $null
                        }
                    }
                )
                warnings   = @($warning)
                errors     = @()
                evidence   = @($evidence)
            }
        }

        function Invoke-ProviderResultValidation {
            param([AllowNull()][object]$Result)

            Assert-AuditProviderResult -Result $Result -ProviderId 'synthetic.valid' -Category 'synthetic'
        }
    }

    It 'accepts a complete schema-valid provider result' {
        { Invoke-ProviderResultValidation -Result (New-ValidProviderResult) } | Should -Not -Throw
    }

    It 'accepts nullable fields, dictionary attributes, and the maximum captured length' {
        $result = New-ValidProviderResult
        $component = $result.components[0]
        $component.state = 'unknown'
        $component.installed = $null
        $component.activeVersion = $null
        $component.versionIntelligence.checkedAt = $null
        $result.evidence[0].exitCode = $null
        $result.evidence[0].captured = 'x' * 32768
        $result.evidence[0].attributes = @{ source = 'synthetic' }
        $result.warnings[0].componentId = $null

        { Invoke-ProviderResultValidation -Result $result } | Should -Not -Throw
    }

    It 'rejects a missing or multi-object provider result' {
        { Invoke-ProviderResultValidation -Result $null } | Should -Throw -ExpectedMessage '*result must be a single object record*'

        $leakedOutput = @((New-ValidProviderResult), (New-ValidProviderResult))
        { Invoke-ProviderResultValidation -Result $leakedOutput } | Should -Throw -ExpectedMessage '*result must be a single object record*'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unexpected result property'; Message = "result has unexpected property 'extra'"; Mutate = { param($r) $r | Add-Member -NotePropertyName extra -NotePropertyValue 1 } }
        @{ Case = 'a missing result property'; Message = "result is missing 'observedAt'"; Mutate = { param($r) $r.PSObject.Properties.Remove('observedAt') } }
        @{ Case = 'a mismatched providerId'; Message = 'does not match registered id'; Mutate = { param($r) $r.providerId = 'synthetic.other' } }
        @{ Case = 'a providerId with different casing'; Message = 'does not match registered id'; Mutate = { param($r) $r.providerId = 'Synthetic.Valid' } }
        @{ Case = 'a category with different casing'; Message = "returned category 'Synthetic'"; Mutate = { param($r) $r.category = 'Synthetic' } }
        @{ Case = 'a status with different casing'; Message = "invalid status 'Success'"; Mutate = { param($r) $r.status = 'Success' } }
        @{ Case = 'a non date-time observedAt'; Message = 'observedAt must be an RFC 3339'; Mutate = { param($r) $r.observedAt = 'yesterday' } }
        @{ Case = 'a null components collection'; Message = "result 'components' must be an array"; Mutate = { param($r) $r.components = $null } }
        @{ Case = 'a hashtable components collection'; Message = "result 'components' must be an array"; Mutate = { param($r) $r.components = @{ notAnArray = 1 } } }
        @{ Case = 'a string evidence collection'; Message = "result 'evidence' must be an array"; Mutate = { param($r) $r.evidence = 'synthetic' } }
        @{ Case = 'a duplicate componentId'; Message = "duplicate componentId 'synthetic-tool'"; Mutate = { param($r) $r.components = @($r.components[0], $r.components[0]) } }
        @{ Case = 'a component missing required fields'; Message = "component is missing 'name'"; Mutate = { param($r) $r.components = @([pscustomobject]@{ componentId = 'synthetic-tool' }) } }
        @{ Case = 'a string component entry'; Message = 'component must be a single object record'; Mutate = { param($r) $r.components = @('synthetic') } }
        @{ Case = 'an unexpected component property'; Message = "component has unexpected property 'extra'"; Mutate = { param($r) $r.components[0] | Add-Member -NotePropertyName extra -NotePropertyValue 1 } }
        @{ Case = 'a componentId with different casing'; Message = "invalid componentId 'Synthetic-Tool'"; Mutate = { param($r) $r.components[0].componentId = 'Synthetic-Tool' } }
        @{ Case = 'a component state with different casing'; Message = "invalid state 'Present'"; Mutate = { param($r) $r.components[0].state = 'Present' } }
        @{ Case = 'a present component that is not installed'; Message = 'contradicts installed'; Mutate = { param($r) $r.components[0].installed = $false } }
        @{ Case = 'a missing component that is installed'; Message = 'contradicts installed'; Mutate = { param($r) $r.components[0].state = 'missing' } }
        @{ Case = 'a string activeVersion'; Message = 'activeVersion must be a single object record'; Mutate = { param($r) $r.components[0].activeVersion = '1.2.3' } }
        @{ Case = 'an empty discovered version'; Message = 'discoveredVersions entry raw must be a non-empty string'; Mutate = { param($r) $r.components[0].discoveredVersions = @([pscustomobject][ordered]@{ raw = ''; normalized = $null; channel = $null }) } }
        @{ Case = 'an installation source with different casing'; Message = "invalid source 'Command'"; Mutate = { param($r) $r.components[0].installations[0].source = 'Command' } }
        @{ Case = 'a negative command precedence'; Message = 'precedence must be a non-negative integer'; Mutate = { param($r) $r.components[0].commandResolutions[0].precedence = -1 } }
        @{ Case = 'a string command precedence'; Message = 'precedence must be a non-negative integer'; Mutate = { param($r) $r.components[0].commandResolutions[0].precedence = '0' } }
        @{ Case = 'an invalid version-intelligence status'; Message = "versionIntelligence has invalid status 'latest'"; Mutate = { param($r) $r.components[0].versionIntelligence.status = 'latest' } }
        @{ Case = 'a non date-time checkedAt'; Message = 'checkedAt must be an RFC 3339'; Mutate = { param($r) $r.components[0].versionIntelligence.checkedAt = 'soon' } }
        @{ Case = 'evidence without a source'; Message = "evidence is missing 'source'"; Mutate = { param($r) $r.evidence[0].PSObject.Properties.Remove('source') } }
        @{ Case = 'an unexpected evidence property'; Message = "evidence has unexpected property 'bogus'"; Mutate = { param($r) $r.evidence[0] | Add-Member -NotePropertyName bogus -NotePropertyValue 1 } }
        @{ Case = 'an evidenceId with different casing'; Message = "invalid evidenceId 'Synthetic.Version'"; Mutate = { param($r) $r.evidence[0].evidenceId = 'Synthetic.Version' } }
        @{ Case = 'a duplicate evidenceId'; Message = "duplicate evidenceId 'synthetic.version'"; Mutate = { param($r) $r.evidence = @($r.evidence[0], $r.evidence[0]) } }
        @{ Case = 'an evidence type with different casing'; Message = "invalid type 'Command'"; Mutate = { param($r) $r.evidence[0].type = 'Command' } }
        @{ Case = 'a string exitCode'; Message = 'exitCode must be an integer or null'; Mutate = { param($r) $r.evidence[0].exitCode = 'notanint' } }
        @{ Case = 'an array captured value'; Message = 'captured must be null or a string'; Mutate = { param($r) $r.evidence[0].captured = @(1, 2) } }
        @{ Case = 'an oversized captured value'; Message = 'captured must be null or a string'; Mutate = { param($r) $r.evidence[0].captured = 'x' * 32769 } }
        @{ Case = 'a string redacted flag'; Message = 'redacted must be boolean'; Mutate = { param($r) $r.evidence[0].redacted = 'false' } }
        @{ Case = 'string evidence attributes'; Message = 'attributes must be an object'; Mutate = { param($r) $r.evidence[0].attributes = 'a string' } }
        @{ Case = 'a lowercase issue code'; Message = "invalid issue code 'lower_code'"; Mutate = { param($r) $r.warnings[0].code = 'lower_code' } }
        @{ Case = 'a warning severity with different casing'; Message = "invalid severity 'WARNING' for warnings"; Mutate = { param($r) $r.warnings[0].severity = 'WARNING' } }
        @{ Case = 'an error with warning severity'; Message = "invalid severity 'warning' for errors"; Mutate = { param($r) $r.errors = @(New-AuditIssue -Code 'SYNTHETIC_ERROR' -Message 'Synthetic error.' -Severity warning) } }
        @{ Case = 'an empty issue message'; Message = 'message must be a non-empty string'; Mutate = { param($r) $r.warnings[0].message = '' } }
        @{ Case = 'a warning without componentId'; Message = "warnings entry is missing 'componentId'"; Mutate = { param($r) $r.warnings[0].PSObject.Properties.Remove('componentId') } }
        @{ Case = 'string issue evidenceIds'; Message = 'evidenceIds must be an array'; Mutate = { param($r) $r.warnings[0].evidenceIds = 'synthetic.version' } }
        @{ Case = 'null issue evidenceIds'; Message = 'evidenceIds must be an array'; Mutate = { param($r) $r.warnings[0].evidenceIds = $null } }
        @{ Case = 'duplicate issue evidenceIds'; Message = "duplicate evidenceId reference 'synthetic.version'"; Mutate = { param($r) $r.warnings[0].evidenceIds = @('synthetic.version', 'synthetic.version') } }
        @{ Case = 'a dangling issue evidence reference'; Message = "references missing evidenceId 'synthetic.missing'"; Mutate = { param($r) $r.warnings[0].evidenceIds = @('synthetic.missing') } }
    ) {
        $result = New-ValidProviderResult
        & $Mutate $result | Out-Null

        { Invoke-ProviderResultValidation -Result $result } | Should -Throw -ExpectedMessage "*$Message*"
    }
}

Describe 'Audit core validation constants' {
    BeforeAll {
        $schema = Get-Content -LiteralPath (Join-Path $repositoryRoot 'schemas\provider-result.schema.json') -Raw |
            ConvertFrom-Json
        $definitions = $schema.'$defs'

        function Get-CoreValue {
            param([Parameter(Mandatory)][string]$Name)

            & (Get-Module Audit.Core) { param($VariableName) (Get-Variable -Name $VariableName -Scope Script).Value } $Name
        }

        function Get-ParameterAttribute {
            param(
                [Parameter(Mandatory)][string]$Command,
                [Parameter(Mandatory)][string]$Parameter,
                [Parameter(Mandatory)][type]$AttributeType
            )

            (Get-Command $Command).Parameters[$Parameter].Attributes |
                Where-Object { $_ -is $AttributeType } |
                Select-Object -First 1
        }
    }

    It 'mirrors the schema enums' {
        (Get-CoreValue AuditProviderStatuses) -join ',' | Should -BeExactly ($definitions.providerStatus.enum -join ',')
        (Get-CoreValue AuditComponentStates) -join ',' | Should -BeExactly ($definitions.componentState.enum -join ',')
        (Get-CoreValue AuditVersionIntelligenceStatuses) -join ',' | Should -BeExactly ($definitions.versionIntelligenceStatus.enum -join ',')
        (Get-CoreValue AuditEvidenceTypes) -join ',' | Should -BeExactly ($definitions.evidenceType.enum -join ',')
        (Get-CoreValue AuditInstallationSources) -join ',' | Should -BeExactly ($definitions.installation.properties.source.enum -join ',')
    }

    It 'mirrors the schema patterns and limits' {
        $identifierPattern = Get-CoreValue AuditIdentifierPattern

        $identifierPattern | Should -BeExactly $schema.properties.providerId.pattern
        $identifierPattern | Should -BeExactly $definitions.evidence.properties.evidenceId.pattern
        $identifierPattern | Should -BeExactly $definitions.component.properties.componentId.pattern
        Get-CoreValue AuditCategoryPattern | Should -BeExactly $schema.properties.category.pattern
        Get-CoreValue AuditIssueCodePattern | Should -BeExactly $definitions.issueBase.properties.code.pattern
        Get-CoreValue AuditMaximumCapturedLength | Should -Be $definitions.evidence.properties.captured.maxLength
    }

    It 'keeps constructor validation aligned with the runtime validator' {
        $validateSet = [System.Management.Automation.ValidateSetAttribute]
        $validatePattern = [System.Management.Automation.ValidatePatternAttribute]

        (Get-ParameterAttribute New-AuditEvidence Type $validateSet).ValidValues -join ',' |
            Should -BeExactly ((Get-CoreValue AuditEvidenceTypes) -join ',')
        (Get-ParameterAttribute New-AuditEvidence EvidenceId $validatePattern).RegexPattern |
            Should -BeExactly (Get-CoreValue AuditIdentifierPattern)
        (Get-ParameterAttribute New-AuditIssue Code $validatePattern).RegexPattern |
            Should -BeExactly (Get-CoreValue AuditIssueCodePattern)
        (Get-ParameterAttribute New-AuditIssue Severity $validateSet).ValidValues -join ',' |
            Should -BeExactly 'info,warning,error'
    }
}
