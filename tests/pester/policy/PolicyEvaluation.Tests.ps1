BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\Comparison.Core.psm1') -Force
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\PolicyEvaluation.Core.psm1') -Force
    Import-Module (Join-Path $repositoryRoot 'scripts\Core\UpdatePlan.Core.psm1') -Force

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

    It 'evaluates the <Key> track and plans <Command>' -ForEach @(
        @{ Key = 'python.defaultTrack'; Component = 'python'; Installed = '3.13.17'; Latest = '3.15.1'; Command = $null }
        @{ Key = 'dotnet.defaultTrack'; Component = 'dotnet-sdk'; Installed = '9.0.311'; Latest = '10.0.204'; Command = $null }
        @{ Key = 'rust.defaultTrack'; Component = 'rustc'; Installed = '1.98.0'; Latest = '1.99.1'; Command = 'rustup update stable' }
        @{ Key = 'go.defaultTrack'; Component = 'go'; Installed = '1.26.9'; Latest = '1.27.3'; Command = $null }
    ) {
        $report = New-TestReport -Components @(New-TestComponent -Id $Component -Version $Installed -Intelligence (New-TestIntelligence -Stable $Latest))
        (Get-TestFinding (Invoke-TestEvaluation $report) $Key).status | Should -Be 'deviation'
        $action = @((New-WorkstationUpdatePlan -Report $report -Policy (New-TestPolicy) -PolicyDigest $script:digest).actions | Where-Object actionId -eq "policy:$Key")[0]
        $action.targetVersion | Should -Be $Latest
        $action.command | Should -Be $Command
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

    It 'checks the Python Install Manager in the WinGet inventory (<Name>)' -ForEach @(
        @{ Name = 'installed'; Packages = @(@{ name = 'Python Install Manager'; packageId = 'Python.PythonInstallManager' }); Status = 'compliant' }
        @{ Name = 'missing'; Packages = @(@{ name = 'Git'; packageId = 'Git.Git' }); Status = 'deviation' }
    ) {
        $inventory = [pscustomobject]@{ packages = @($Packages | ForEach-Object { [pscustomobject]$_ }) }
        $report = New-TestReport -Components @(New-TestComponent -Id python -Version '3.14.2') -Evidence @{ 'winget.inventory.normalized' = $inventory }
        (Get-TestFinding (Invoke-TestEvaluation $report) 'python.windowsManager').status | Should -Be $Status
    }

    It 'leaves the Python manager unknown without a WinGet inventory' {
        $report = New-TestReport -Components @(New-TestComponent -Id python -Version '3.14.2')
        (Get-TestFinding (Invoke-TestEvaluation $report) 'python.windowsManager').status | Should -Be 'unknown'
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

Describe 'Output JSON' {
    It 'writes HTML-sensitive characters literally but keeps an escaped backslash sequence intact' {
        $json = ConvertTo-WorkstationOutputJson -InputObject ([pscustomobject]@{ a = '< 1 & >'; b = 'x\u003cy' })
        $json | Should -BeExactly ('{"a":"< 1 & >","b":"x\\u003cy"}' + [char]10)
    }
}

Describe 'Update plan' {
    BeforeAll {
        function New-TestWinGetProvider {
            param([object[]]$Upgrades)
            [pscustomobject]@{
                providerId = 'winget.baseline'; status = 'success'; components = @(); warnings = @()
                evidence   = @([pscustomobject]@{ evidenceId = 'winget.upgrades.normalized'; attributes = [pscustomobject]@{ upgrades = @($Upgrades) } })
            }
        }
        function New-TestUpgrade {
            param([string]$Id, [string]$From, [string]$To, [bool]$Reliable = $true)
            [pscustomobject]@{ name = $Id; packageId = $Id; identityReliable = $Reliable; installedVersion = $From; availableVersion = $To }
        }
        function Invoke-TestPlan {
            param([psobject]$Report)
            New-WorkstationUpdatePlan -Report $Report -Policy (New-TestPolicy) -PolicyDigest $script:digest
        }

        $projectPath = Join-Path $TestDrive 'someone\app'
        $discovery = [pscustomobject]@{ candidates = @(
                [pscustomobject]@{ path = "$projectPath-a"; relativePath = 'app-a' }
                [pscustomobject]@{ path = "$projectPath-b"; relativePath = 'app-b' }
            ) }
        $project = { param($Index) [pscustomobject]@{ project = [pscustomobject]@{ projectIndex = $Index; nodePins = @(); lockfiles = @('pnpm-lock.yaml') } } }

        $winget = New-TestWinGetProvider -Upgrades @(
            New-TestUpgrade -Id 'Git.Git' -From '2.51.0' -To '2.52.0'
            New-TestUpgrade -Id 'Docker.DockerDesktop' -From '4.9.0' -To '5.0.0'
            New-TestUpgrade -Id 'Unreliable.Package' -From '1.0' -To '2.0' -Reliable $false
        )
        $report = New-TestReport -ExtraProviders @($winget) -Components @(
            New-TestComponent -Id node -Version '24.13.0' -Intelligence $script:nodeLts
            New-TestComponent -Id nvm-windows -Version '1.2.2'
            New-TestComponent -Id angular-cli -Version '21.2.24' -Intelligence (New-TestIntelligence -Stable '22.2.2')
        ) -Evidence @{
            'projects.local.discovery'          = $discovery
            'projects.javascript-web.project-0' = & $project 0
            'projects.javascript-web.project-1' = & $project 1
        }
        $script:plan = Invoke-TestPlan $report
        $script:byId = @{}
        foreach ($action in $script:plan.actions) { $script:byId[$action.actionId] = $action }
    }

    It 'plans every reliable WinGet upgrade with its command' {
        $git = $script:byId['winget-upgrade:Git.Git']
        $git.command | Should -Be 'winget upgrade --id Git.Git --exact'
        $git.subjectId | Should -Be 'winget:Git.Git'
        $git.risk | Should -Be 'low'
        $script:byId['winget-upgrade:Docker.DockerDesktop'].risk | Should -Be 'medium'
        $script:byId.ContainsKey('winget-upgrade:Unreliable.Package') | Should -BeFalse
    }

    It 'turns policy deviations into actions with versions' {
        $node = $script:byId['policy:node.defaultTrack']
        $node.kind | Should -Be 'upgrade'
        $node.currentVersion | Should -Be '24.13.0'
        $node.targetVersion | Should -Be '24.21.0'
        $node.command | Should -BeNullOrEmpty

        $angular = $script:byId['policy:angular.globalCliTrack']
        $angular.command | Should -Be 'pnpm add -g @angular/cli@22.2.2'
        $angular.risk | Should -Be 'medium'
    }

    It 'groups per-project deviations into one action' {
        $pins = $script:byId['policy:node.projectVersionsMustBePinned']
        $pins.title | Should -Match '\(2\)$'
        $pins.evidence.Count | Should -Be 2
        $script:byId.ContainsKey('policy:javascript.projectDependencies') | Should -BeFalse
    }

    It 'orders by risk then action id, numbers from 1 and summarizes' {
        $rank = @{ low = 0; medium = 1; high = 2 }
        $keys = @($script:plan.actions | ForEach-Object { '{0}|{1}' -f $rank[$_.risk], $_.actionId })
        $sorted = [string[]]$keys.Clone()
        [Array]::Sort($sorted, [StringComparer]::Ordinal)
        $keys -join ';' | Should -Be ($sorted -join ';')
        @($script:plan.actions | ForEach-Object order) -join ',' | Should -Be ((1..$script:plan.actions.Count) -join ',')
        $script:plan.summary.actionCount | Should -Be $script:plan.actions.Count
        $script:plan.summary.manualCount | Should -Be @($script:plan.actions | Where-Object { $null -eq $_.command }).Count
    }

    It 'writes a shareable plan without project paths' {
        $paths = Write-WorkstationUpdatePlanOutputs -Plan $script:plan -OutputDirectory (Join-Path $TestDrive 'plan')
        $text = Get-Content -LiteralPath $paths.structuredPath -Encoding UTF8 -Raw
        $text | Should -Not -Match 'someone'
        Get-Content -LiteralPath $paths.humanReadablePath -Encoding UTF8 -Raw | Should -Match 'Nothing has been run'
    }

    It 'says which installer owns a runtime with a manual upgrade (<Source>)' -ForEach @(
        @{ Source = 'winget'; PackageId = 'OpenJS.NodeJS.LTS'; Expected = 'WinGet package OpenJS.NodeJS.LTS manages' }
        @{ Source = $null; PackageId = 'ARP\Machine\X64\{node}'; Expected = 'not made with WinGet' }
    ) {
        $inventory = [pscustomobject]@{ packages = @([pscustomobject]@{ name = 'Node.js'; packageId = $PackageId; installedVersion = '24.13.0'; source = $Source }) }
        $provider = [pscustomobject]@{
            providerId = 'winget.baseline'; status = 'success'; components = @(); warnings = @()
            evidence   = @([pscustomobject]@{ evidenceId = 'winget.inventory.normalized'; attributes = $inventory })
        }
        $report = New-TestReport -ExtraProviders @($provider) -Components @(
            New-TestComponent -Id node -Version '24.13.0' -Intelligence $script:nodeLts
            New-TestComponent -Id nvm-windows -Version '1.2.2'
        )
        $node = @((Invoke-TestPlan $report).actions | Where-Object actionId -eq 'policy:node.defaultTrack')[0]
        $node.message | Should -Match ([regex]::Escape($Expected))
        $node.message | Should -Not -Match 'ARP'
    }

    It 'scopes Microsoft Store upgrades to the msstore source' {
        $store = [pscustomobject]@{ name = 'PowerToys (Preview) x64'; packageId = 'XP89DCGQ3K6VLD'; identityReliable = $true; installedVersion = '0.100.2'; availableVersion = '0.101.2362.0'; source = 'msstore' }
        $actions = @((Invoke-TestPlan (New-TestReport -ExtraProviders @(New-TestWinGetProvider -Upgrades @($store)))).actions)
        $actions[0].command | Should -Be 'winget upgrade --id XP89DCGQ3K6VLD --exact --source msstore'
        $actions[0].title | Should -Match 'Microsoft Store'
    }

    It 'plans unpinned Chocolatey upgrades and leaves pinned packages alone' {
        $upgrades = @(
            [pscustomobject]@{ packageId = 'python314'; installedVersion = '3.14.2'; availableVersion = '3.14.8'; pinned = $false }
            [pscustomobject]@{ packageId = 'git'; installedVersion = '2.51.0'; availableVersion = '3.0.0'; pinned = $true }
        )
        $provider = [pscustomobject]@{
            providerId = 'chocolatey.baseline'; status = 'success'; components = @(); warnings = @()
            evidence   = @([pscustomobject]@{ evidenceId = 'chocolatey.outdated.normalized'; attributes = [pscustomobject]@{ upgrades = $upgrades } })
        }
        $actions = @((Invoke-TestPlan (New-TestReport -ExtraProviders @($provider))).actions)
        $python = @($actions | Where-Object actionId -eq 'choco-upgrade:python314')[0]
        $python.command | Should -Be 'choco upgrade python314 -y'
        $python.source.type | Should -Be 'chocolatey'
        $python.subjectId | Should -Be 'choco:python314'
        @($actions | Where-Object actionId -eq 'choco-upgrade:git') | Should -HaveCount 0
    }

    It 'plans wsl --update only when WSL is behind (<Current>)' -ForEach @(
        @{ Current = '2.5.7.0'; Expected = 1 }
        @{ Current = '3.0.3'; Expected = 0 }
    ) {
        $wsl = New-TestComponent -Id wsl -Version $Current -Intelligence (New-TestIntelligence -Stable '3.0.3')
        $provider = [pscustomobject]@{ providerId = 'wsl.baseline'; status = 'success'; components = @($wsl); warnings = @(); evidence = @() }
        $actions = @((Invoke-TestPlan (New-TestReport -ExtraProviders @($provider))).actions | Where-Object actionId -eq 'wsl-update:wsl')
        $actions | Should -HaveCount $Expected
        if ($Expected) {
            $actions[0].command | Should -Be 'wsl --update'
            $actions[0].risk | Should -Be 'medium'
        }
    }

    It 'plans pnpm and global CLI upgrades with the manager that installed them' {
        $evidence = @(
            [pscustomobject]@{ evidenceId = 'javascript.version-intelligence.pnpm'; attributes = [pscustomobject]@{ installedVersion = '12.4.2'; latestStable = '12.5.0'; updateAvailable = $true } }
            [pscustomobject]@{ evidenceId = 'javascript.version-intelligence.npm'; attributes = [pscustomobject]@{ installedVersion = '11.19.1'; latestStable = '11.20.0'; updateAvailable = $true } }
            [pscustomobject]@{ evidenceId = 'javascript.version-intelligence.global.zcatalyst-cli'; attributes = [pscustomobject]@{ packageName = 'zcatalyst-cli'; manager = 'pnpm'; componentId = 'zoho-catalyst-cli'; installedVersion = '1.27.2'; latestStable = '1.28.0'; updateAvailable = $true } }
            [pscustomobject]@{ evidenceId = 'javascript.version-intelligence.global.nodemon'; attributes = [pscustomobject]@{ packageName = 'nodemon'; manager = 'npm'; componentId = 'nodemon'; installedVersion = '3.1.14'; latestStable = '4.0.0'; updateAvailable = $true } }
            [pscustomobject]@{ evidenceId = 'javascript.version-intelligence.global.rimraf'; attributes = [pscustomobject]@{ packageName = 'rimraf'; manager = 'pnpm'; componentId = 'rimraf'; installedVersion = '6.1.3'; latestStable = '6.1.3'; updateAvailable = $false } }
        )
        $provider = [pscustomobject]@{ providerId = 'javascript.toolchain'; status = 'success'; components = @(); warnings = @(); evidence = $evidence }
        $byId = @{}
        foreach ($action in @((Invoke-TestPlan (New-TestReport -ExtraProviders @($provider))).actions)) { $byId[$action.actionId] = $action }

        $byId['pnpm-self-update:pnpm'].command | Should -Be 'pnpm self-update'
        $byId['npm-global-upgrade:zcatalyst-cli'].command | Should -Be 'pnpm add -g zcatalyst-cli@1.28.0'
        $byId['npm-global-upgrade:nodemon'].command | Should -Be 'npm install -g nodemon@4.0.0'
        $byId['npm-global-upgrade:nodemon'].risk | Should -Be 'medium'
        $byId.ContainsKey('npm-global-upgrade:rimraf') | Should -BeFalse
        # npm is the copy bundled with Node.js and is updated with Node.
        @($byId.Keys | Where-Object { $_ -like '*:npm' }) | Should -HaveCount 0
    }

    It 'plans developer tool upgrades from their latest-version sources' {
        $python = [pscustomobject]@{
            providerId = 'python.ecosystem'; status = 'success'; warnings = @()
            components = @(
                New-TestComponent -Id pip -Version '26.1.0' -Intelligence (New-TestIntelligence -Stable '26.2.1')
                New-TestComponent -Id uv -Version '0.11.28' -Intelligence (New-TestIntelligence -Stable '0.13.1')
            )
            evidence   = @([pscustomobject]@{ evidenceId = 'python.uv.install-kind'; attributes = [pscustomobject]@{ selfUpdateSupported = $false } })
        }
        $android = [pscustomobject]@{
            providerId = 'mobile.flutter-android'; status = 'success'; warnings = @(); evidence = @()
            components = @(
                New-TestComponent -Id adb -Version '37.0.1-14910828' -Intelligence (New-TestIntelligence -Stable '37.0.1')
                New-TestComponent -Id sdkmanager -Version '20.0' -Intelligence (New-TestIntelligence -Stable '23.0')
            )
        }
        $byId = @{}
        foreach ($action in @((Invoke-TestPlan (New-TestReport -ExtraProviders @($python, $android))).actions)) { $byId[$action.actionId] = $action }

        $byId['tool-upgrade:pip'].command | Should -Be 'python -m pip install pip==26.2.1'
        $byId['tool-upgrade:uv'].command | Should -BeNullOrEmpty
        $byId['tool-upgrade:uv'].message | Should -Match 'package manager that installed it'
        $byId['tool-upgrade:sdkmanager'].command | Should -BeNullOrEmpty
        $byId['tool-upgrade:sdkmanager'].message | Should -Match 'Android Studio'
        $byId['tool-upgrade:sdkmanager'].risk | Should -Be 'medium'
        # adb 37.0.1-14910828 is the 37.0.1 release plus a build number, not behind 37.0.1.
        $byId.ContainsKey('tool-upgrade:adb') | Should -BeFalse
    }

    It 'flags tools owned by more than one package manager' {
        $chocolatey = [pscustomobject]@{
            providerId = 'chocolatey.baseline'; status = 'success'; components = @(); warnings = @()
            evidence   = @([pscustomobject]@{ evidenceId = 'chocolatey.inventory.normalized'; attributes = [pscustomobject]@{ packages = @(
                            [pscustomobject]@{ packageId = 'python314'; installedVersion = '3.14.2' }
                            [pscustomobject]@{ packageId = 'python3'; installedVersion = '3.14.2' }
                            [pscustomobject]@{ packageId = 'python-docs'; installedVersion = '1.0' }
                        ) } })
        }
        $winget = [pscustomobject]@{
            providerId = 'winget.baseline'; status = 'success'; components = @(); warnings = @()
            evidence   = @([pscustomobject]@{ evidenceId = 'winget.inventory.normalized'; attributes = [pscustomobject]@{ packages = @(
                            [pscustomobject]@{ name = 'Python 3.14.2 (64-bit)'; packageId = 'Python.Python.3.14'; source = 'winget' }
                            [pscustomobject]@{ name = 'Python 3.14.2'; packageId = 'ARP\User\X64\pymanager-pythoncore-3.14-64'; source = $null }
                            [pscustomobject]@{ name = 'Git'; packageId = 'Git.Git'; source = 'winget' }
                        ) } })
        }
        $actions = @((Invoke-TestPlan (New-TestReport -ExtraProviders @($chocolatey, $winget))).actions | Where-Object { $_.source.type -eq 'consolidation' })

        $actions | Should -HaveCount 1
        $actions[0].actionId | Should -Be 'consolidate-managers:python'
        $actions[0].command | Should -BeNullOrEmpty
        $actions[0].message | Should -Match 'Chocolatey \(python3, python314\) and WinGet \(Python\.Python\.3\.14\) and Python Install Manager'
        $actions[0].message | Should -Not -Match 'python-docs'
        $actions[0].evidence | Should -HaveCount 2
    }

    It 'upgrades shared tools through WinGet only and keeps tools WinGet does not manage' {
        $chocolatey = [pscustomobject]@{
            providerId = 'chocolatey.baseline'; status = 'success'; components = @(); warnings = @()
            evidence   = @(
                [pscustomobject]@{ evidenceId = 'chocolatey.inventory.normalized'; attributes = [pscustomobject]@{ packages = @(
                            [pscustomobject]@{ packageId = 'python314'; installedVersion = '3.14.2' }
                            [pscustomobject]@{ packageId = 'python313'; installedVersion = '3.13.5' }
                            [pscustomobject]@{ packageId = 'chocolatey'; installedVersion = '2.6.0' }
                        ) } }
                [pscustomobject]@{ evidenceId = 'chocolatey.outdated.normalized'; attributes = [pscustomobject]@{ upgrades = @(
                            [pscustomobject]@{ packageId = 'python314'; installedVersion = '3.14.2'; availableVersion = '3.14.8'; pinned = $false }
                            [pscustomobject]@{ packageId = 'python313'; installedVersion = '3.13.5'; availableVersion = '3.13.16'; pinned = $false }
                            [pscustomobject]@{ packageId = 'chocolatey'; installedVersion = '2.6.0'; availableVersion = '2.7.4'; pinned = $false }
                        ) } }
            )
        }
        $winget = [pscustomobject]@{
            providerId = 'winget.baseline'; status = 'success'; components = @(); warnings = @()
            evidence   = @(
                [pscustomobject]@{ evidenceId = 'winget.inventory.normalized'; attributes = [pscustomobject]@{ packages = @(
                            [pscustomobject]@{ name = 'Python 3.14.2 (64-bit)'; packageId = 'Python.Python.3.14'; source = 'winget' }
                        ) } }
                [pscustomobject]@{ evidenceId = 'winget.upgrades.normalized'; attributes = [pscustomobject]@{ upgrades = @(
                            New-TestUpgrade -Id 'Python.Python.3.14' -From '3.14.2' -To '3.14.7'
                            New-TestUpgrade -Id 'Microsoft.WSL' -From '2.5.7.0' -To '2.7.13'
                        ) } }
            )
        }
        $wsl = [pscustomobject]@{ providerId = 'wsl.baseline'; status = 'success'; warnings = @(); evidence = @()
            components = @(New-TestComponent -Id wsl -Version '2.5.7.0' -Intelligence (New-TestIntelligence -Stable '3.0.3')) }

        $ids = @((Invoke-TestPlan (New-TestReport -ExtraProviders @($chocolatey, $winget, $wsl))).actions | ForEach-Object actionId)

        $ids | Should -Contain 'winget-upgrade:Python.Python.3.14'
        $ids | Should -Not -Contain 'choco-upgrade:python314'
        # WinGet does not manage Python 3.13, so Chocolatey keeps updating it.
        $ids | Should -Contain 'choco-upgrade:python313'
        $ids | Should -Contain 'choco-upgrade:chocolatey'
        # wsl --update reaches the latest release; the lagging WinGet package would conflict.
        $ids | Should -Contain 'wsl-update:wsl'
        $ids | Should -Not -Contain 'winget-upgrade:Microsoft.WSL'
    }

    It 'is empty for a compliant report' {
        $plan = Invoke-TestPlan (New-TestReport)
        $plan.summary.actionCount | Should -Be 0
        , $plan.actions | Should -BeOfType [object[]]
    }
}
