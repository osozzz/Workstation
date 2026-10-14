BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\Comparison.Core.psm1') -Force
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\PolicyEvaluation.Core.psm1') -Force

    $policyPath = Join-Path $repositoryRoot 'config\workstation.policy.json'
    $script:policyJson = Get-Content -LiteralPath $policyPath -Encoding UTF8 -Raw
    $script:digest = '0' * 64

    function New-TestPolicy {
        param([hashtable]$Override = @{})
        $policy = ConvertFrom-WorkstationJson -Json $script:policyJson
        foreach ($key in $Override.Keys) {
            $section, $name = $key.Split('.')
            $policy.$section.$name = $Override[$key]
        }
        return $policy
    }

    function New-TestVersion {
        param([string]$Version, [string]$Channel = '')
        if ($null -eq $Version) { return $null }
        [pscustomobject]@{ raw = $Version; normalized = $Version; channel = $Channel }
    }

    function New-TestComponent {
        param(
            [string]$Id,
            [string]$Version,
            [string]$State = 'present',
            [string]$Channel = '',
            [object]$Intelligence = [pscustomobject]@{ status = 'not-applicable' },
            [string[]]$Discovered = @()
        )
        [pscustomobject]@{
            componentId         = $Id
            state               = $State
            activeVersion       = New-TestVersion -Version $Version -Channel $Channel
            discoveredVersions  = @(@($Version) + $Discovered | Where-Object { $_ } | ForEach-Object { New-TestVersion -Version $_ })
            versionIntelligence = $Intelligence
        }
    }

    function New-TestIntelligence {
        param([string]$Stable, [string]$Lts, [string]$Current)
        [pscustomobject]@{
            status        = 'known'
            latestStable  = New-TestVersion -Version $Stable
            latestLts     = New-TestVersion -Version $Lts
            latestCurrent = New-TestVersion -Version $Current
        }
    }

    function New-TestReport {
        param(
            [object[]]$Components = @(),
            [hashtable]$Evidence = @{},
            [object[]]$ExtraProviders = @()
        )
        $evidenceItems = foreach ($id in $Evidence.Keys) { [pscustomobject]@{ evidenceId = $id; attributes = $Evidence[$id] } }
        [pscustomobject]@{
            schemaVersion = '1.0.0'
            generatedAt   = '2026-10-14T12:00:00+00:00'
            audit         = [pscustomobject]@{ mode = 'read-only'; toolVersion = '1.1.0' }
            host          = [pscustomobject]@{ name = 'SYNTHETIC'; platform = 'windows'; architecture = 'x64' }
            providers     = @(
                [pscustomobject]@{ providerId = 'synthetic.toolchain'; status = 'success'; components = @($Components); evidence = @($evidenceItems); warnings = @() }
            ) + $ExtraProviders
        }
    }

    function Invoke-TestEvaluation {
        param([psobject]$Report, [hashtable]$Override = @{})
        New-WorkstationPolicyEvaluation -Report $Report -Policy (New-TestPolicy -Override $Override) -PolicyDigest $script:digest
    }

    function Get-TestFinding {
        param([psobject]$Evaluation, [string]$PolicyKey)
        @($Evaluation.findings | Where-Object policyKey -eq $PolicyKey)
    }

    $script:nodeLts = New-TestIntelligence -Lts '24.21.0' -Current '26.11.1'
}

Describe 'Policy rule catalog' {
    It 'has exactly one rule per policy key' {
        $policyKeys = @(Get-PolicyLeafKeys -Policy (New-TestPolicy) | Sort-Object)
        $ruleKeys = @(Get-PolicyEvaluationRuleKeys | Sort-Object)
        Compare-Object $policyKeys $ruleKeys | Should -BeNullOrEmpty
    }

    It 'refuses a policy key without a rule' {
        $policy = New-TestPolicy
        $policy.node | Add-Member -NotePropertyName 'unknownSetting' -NotePropertyValue $true
        { New-WorkstationPolicyEvaluation -Report (New-TestReport) -Policy $policy -PolicyDigest $script:digest } |
            Should -Throw '*node.unknownSetting*'
    }
}

Describe 'Version comparison' {
    It 'orders <Left> against <Right> as <Expected>' -ForEach @(
        @{ Left = '24.21.0'; Right = '24.13.0'; Expected = 1 }
        @{ Left = '24.13.0'; Right = '24.21.0'; Expected = -1 }
        @{ Left = '3.44'; Right = '3.44.0'; Expected = 0 }
        @{ Left = '8.0.0'; Right = '8.0.0-rc.15'; Expected = 1 }
        @{ Left = '8.0.0-rc.15'; Right = '7.9.0'; Expected = 1 }
    ) {
        Compare-PolicyVersion -Left $Left -Right $Right | Should -Be $Expected
    }
}

Describe 'Track rules' {
    It 'marks Node <Installed> as <Status> on the LTS track' -ForEach @(
        @{ Installed = '24.21.0'; Status = 'compliant' }
        @{ Installed = '24.13.0'; Status = 'deviation' }
        @{ Installed = '26.11.1'; Status = 'deviation' }
    ) {
        $report = New-TestReport -Components @(New-TestComponent -Id node -Version $Installed -Intelligence $script:nodeLts)
        $finding = Get-TestFinding (Invoke-TestEvaluation $report) 'node.defaultTrack'
        $finding.status | Should -Be $Status
        $finding.observed.latestLts | Should -Be '24.21.0'
    }

    It 'is unknown when latest-version information is unavailable' {
        $report = New-TestReport -Components @(New-TestComponent -Id flutter -Version '3.44.1' -Channel stable -Intelligence ([pscustomobject]@{ status = 'unavailable' }))
        $finding = Get-TestFinding (Invoke-TestEvaluation $report) 'flutter.sdkTrack'
        $finding.status | Should -Be 'unknown'
        $finding.evidence.Count | Should -Be 0
    }

    It 'accepts a newer release candidate on a release-candidate-allowed track' {
        $report = New-TestReport -Components @(New-TestComponent -Id prisma -Version '8.0.0-rc.15' -Intelligence (New-TestIntelligence -Current '8.0.0-rc.10'))
        $evaluation = Invoke-TestEvaluation $report
        (Get-TestFinding $evaluation 'prisma.globalTrack').status | Should -Be 'compliant'
        (Get-TestFinding $evaluation 'versioning.prereleasePolicy').status | Should -Be 'compliant'
    }

    It 'skips track rules for tools that are not installed' {
        $report = New-TestReport -Components @(New-TestComponent -Id typescript -Version $null -State missing)
        Get-TestFinding (Invoke-TestEvaluation $report) 'typescript.globalTrack' | Should -BeNullOrEmpty
    }
}

Describe 'Component rules' {
    It 'requires the configured Node manager only when Node is installed' {
        $withoutManager = New-TestReport -Components @(New-TestComponent -Id node -Version '24.21.0' -Intelligence $script:nodeLts)
        (Get-TestFinding (Invoke-TestEvaluation $withoutManager) 'node.manager').status | Should -Be 'deviation'

        $withManager = New-TestReport -Components @(
            New-TestComponent -Id node -Version '24.21.0' -Intelligence $script:nodeLts
            New-TestComponent -Id nvm-windows -Version '1.2.2'
        )
        (Get-TestFinding (Invoke-TestEvaluation $withManager) 'node.manager').status | Should -Be 'compliant'

        Get-TestFinding (Invoke-TestEvaluation (New-TestReport)) 'node.manager' | Should -BeNullOrEmpty
    }

    It 'checks for an installed Node Current major' {
        $report = New-TestReport -Components @(New-TestComponent -Id node -Version '24.21.0' -Discovered @('26.1.0') -Intelligence $script:nodeLts)
        (Get-TestFinding (Invoke-TestEvaluation $report) 'node.alsoInstallCurrent').status | Should -Be 'compliant'
    }

    It 'flags a prerelease without an explicit opt-in' {
        $report = New-TestReport -Components @(New-TestComponent -Id angular-cli -Version '22.0.0-rc.1' -Intelligence (New-TestIntelligence -Stable '21.2.24'))
        $finding = Get-TestFinding (Invoke-TestEvaluation $report) 'versioning.prereleasePolicy'
        $finding.status | Should -Be 'deviation'
        $finding.subjectId | Should -Be 'component:angular-cli'
    }

    It 'does not treat build metadata as a prerelease' {
        $report = New-TestReport -Components @(New-TestComponent -Id adb -Version '37.0.0-14910828')
        (Get-TestFinding (Invoke-TestEvaluation $report) 'versioning.prereleasePolicy').status | Should -Be 'compliant'
    }

    It 'compares the Flutter channel' {
        $report = New-TestReport -Components @(New-TestComponent -Id flutter -Version '3.48.0' -Channel beta)
        (Get-TestFinding (Invoke-TestEvaluation $report) 'flutter.channel').status | Should -Be 'deviation'
    }

    It 'prefers ANDROID_HOME when an Android SDK is installed' {
        $scope = { param($Configured) [pscustomobject]@{ scopes = @([pscustomobject]@{ scope = 'user'; isConfigured = $Configured }) } }
        $report = New-TestReport -Components @(New-TestComponent -Id android-sdk -Version '1') -Evidence @{
            'environment.android_home'     = & $scope $true
            'environment.android_sdk_root' = & $scope $false
        }
        (Get-TestFinding (Invoke-TestEvaluation $report) 'android.preferAndroidHome').status | Should -Be 'compliant'
    }
}

Describe 'PATH rules' {
    It 'counts missing and duplicate entries across persistent scopes' {
        $report = New-TestReport -Evidence @{
            'path.machine.health'                    = [pscustomobject]@{ missingCount = 0; duplicateCount = 1 }
            'path.user.health'                       = [pscustomobject]@{ missingCount = 0; duplicateCount = 0 }
            'path.persistent.cross-scope-duplicates' = [pscustomobject]@{ duplicateCount = 2 }
        }
        $evaluation = Invoke-TestEvaluation $report
        (Get-TestFinding $evaluation 'path.allowMissingEntries').status | Should -Be 'compliant'
        $duplicates = Get-TestFinding $evaluation 'path.allowDuplicateEntries'
        $duplicates.status | Should -Be 'deviation'
        $duplicates.observed.duplicateEntryCount | Should -Be 3
        $duplicates.evidence.Count | Should -Be 3
    }

    It 'is unknown without PATH evidence and compliant when duplicates are allowed' {
        (Get-TestFinding (Invoke-TestEvaluation (New-TestReport)) 'path.allowMissingEntries').status | Should -Be 'unknown'

        $report = New-TestReport -Evidence @{ 'path.user.health' = [pscustomobject]@{ missingCount = 0; duplicateCount = 4 } }
        (Get-TestFinding (Invoke-TestEvaluation $report -Override @{ 'path.allowDuplicateEntries' = $true }) 'path.allowDuplicateEntries').status | Should -Be 'compliant'
    }
}

Describe 'Project rules' {
    BeforeAll {
        $projectPath = Join-Path $TestDrive 'someone\secret-client\app'
        $discovery = [pscustomobject]@{ candidates = @([pscustomobject]@{ path = $projectPath; relativePath = 'secret-client\app' }) }
        $project = [pscustomobject]@{ project = [pscustomobject]@{ projectIndex = 0; path = $projectPath; nodePins = @(); lockfiles = @('pnpm-lock.yaml') } }
        $script:projectEvaluation = Invoke-TestEvaluation (New-TestReport -Evidence @{
                'projects.local.discovery'          = $discovery
                'projects.javascript-web.project-0' = $project
            })
    }

    It 'evaluates each project under a path-safe subject' {
        $pin = Get-TestFinding $script:projectEvaluation 'node.projectVersionsMustBePinned'
        $pin.status | Should -Be 'deviation'
        $pin.subjectId | Should -Match '^project:[0-9a-f]{64}$'
        (Get-TestFinding $script:projectEvaluation 'javascript.projectDependencies').status | Should -Be 'compliant'
    }

    It 'never emits the project path' {
        $json = $script:projectEvaluation | ConvertTo-Json -Depth 100
        $json | Should -Not -Match 'secret-client'
        $json | Should -Not -Match 'someone'
    }
}

Describe 'Evaluation output' {
    BeforeAll {
        $report = New-TestReport -Components @(
            New-TestComponent -Id node -Version '24.13.0' -Intelligence $script:nodeLts
            New-TestComponent -Id flutter -Version '3.44.1' -Channel stable -Intelligence ([pscustomobject]@{ status = 'unavailable' })
        )
        $script:evaluation = Invoke-TestEvaluation $report
    }

    It 'summarizes every finding' {
        $s = $script:evaluation.summary
        $s.findingCount | Should -Be @($script:evaluation.findings).Count
        ($s.compliantCount + $s.deviationCount + $s.unknownCount + $s.notEvaluableCount) | Should -Be $s.findingCount
        $s.status | Should -Be 'deviations'
    }

    It 'orders findings ordinally by policy key, rule and subject' {
        $keys = @($script:evaluation.findings | ForEach-Object { '{0}|{1}|{2}' -f $_.policyKey, $_.ruleId, $_.subjectId })
        $sorted = [string[]]$keys.Clone()
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        $keys -join ';' | Should -Be ($sorted -join ';')
    }

    It 'keeps evidence as JSON arrays and not-evaluable findings empty' {
        $directory = Join-Path $TestDrive 'out'
        $paths = Write-WorkstationPolicyEvaluationOutputs -Evaluation $script:evaluation -OutputDirectory $directory
        $written = ConvertFrom-WorkstationJson -Json (Get-Content -LiteralPath $paths.structuredPath -Encoding UTF8 -Raw)
        foreach ($finding in $written.findings) {
            , $finding.evidence | Should -BeOfType [object[]]
            if ($finding.status -eq 'not-evaluable') {
                $finding.evidence.Count | Should -Be 0
                $finding.observed | Should -BeNullOrEmpty
            }
        }
        Get-Content -LiteralPath $paths.humanReadablePath -Encoding UTF8 -Raw | Should -Match 'Workstation policy evaluation: deviations'
    }
}
