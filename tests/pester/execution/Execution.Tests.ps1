BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    Import-Module (Join-Path $repositoryRoot 'scripts\Execution\Execution.Core.psm1') -Force

    $script:digest = 'a' * 64
    $script:now = [DateTimeOffset]::Parse('2026-10-14T12:00:00+00:00')

    function New-TestAction {
        param(
            [int]$Order, [string]$Id, [AllowNull()][string]$Command, [string]$Risk = 'low',
            [AllowNull()][string]$Subject = $null, [AllowNull()][string]$Target = $null, [string]$Source = 'winget'
        )
        [pscustomobject]@{
            order = $Order; actionId = $Id; kind = 'upgrade'; source = [pscustomobject]@{ type = $Source; policyKey = $null }
            componentId = $null; subjectId = $Subject; title = "Action $Order"; currentVersion = '1.0'; targetVersion = $Target
            command = $Command; risk = $Risk; reversible = $false; message = 'm'; evidence = @()
        }
    }

    function New-TestPlan {
        param([object[]]$Actions, [string]$GeneratedAt = '2026-10-14T10:00:00+00:00', [string]$Digest = $script:digest)
        [pscustomobject]@{
            schemaVersion = '1.1.0'; policy = [pscustomobject]@{ schemaVersion = '1.0'; digest = $Digest }
            report = [pscustomobject]@{ generatedAt = $GeneratedAt }; actions = @($Actions)
        }
    }

    $script:plan = New-TestPlan -Actions @(
        New-TestAction -Order 1 -Id 'winget-upgrade:Git.Git' -Command 'winget upgrade --id Git.Git --exact' -Subject 'winget:Git.Git' -Target '2.52.0'
        New-TestAction -Order 2 -Id 'choco-upgrade:python314' -Command 'choco upgrade python314 -y' -Subject 'choco:python314' -Target '3.14.8' -Source 'chocolatey'
        New-TestAction -Order 3 -Id 'policy:path.allowMissingEntries' -Command $null
        New-TestAction -Order 4 -Id 'wsl-update:wsl' -Command 'wsl --update' -Risk 'medium' -Source 'wsl'
        New-TestAction -Order 5 -Id 'policy:node.manager' -Command $null -Risk 'high'
    )

    function Invoke-TestUpdate {
        param([string[]]$Action = @(), [string]$Risk = '', [switch]$Apply, [switch]$ConfirmAll, [string]$Typed = '', [scriptblock]$Runner, [bool]$Elevated = $true, [bool]$Answer = $true, [string[]]$Running = @(), [string]$Downloader = 'wininet')
        $script:ran = [System.Collections.Generic.List[object]]::new()
        $script:asked = 0
        $runner = if ($Runner) { $Runner } else { { param($Call) $script:ran.Add($Call); [pscustomobject]@{ exitCode = 0; timedOut = $false; found = $true; output = 'ok' } } }
        $script:answer = $Answer
        $script:typed = $Typed
        $script:batchAsked = 0
        $script:running = $Running
        $script:downloader = $Downloader
        $elevatedCheck = if ($Elevated) { { $true } } else { { $false } }
        Invoke-WorkstationUpdate -Plan $script:plan -PolicyDigest $script:digest -Action $Action -Risk $Risk -Apply:$Apply -ConfirmAll:$ConfirmAll `
            -LogDirectory (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Now $script:now `
            -Confirmer { param($Item, $Call) $script:asked++; $script:answer } `
            -BatchConfirmer { param($Count) $script:batchAsked++; $script:typed } -Runner $runner -Elevated $elevatedCheck `
            -ProcessLister { $script:running } -DownloaderCheck { $script:downloader } 6>$null
    }
}

Describe 'Execution allow-list' {
    It 'rebuilds <Command>' -ForEach @(
        @{ Command = 'winget upgrade --id Git.Git --exact'; Subject = 'winget:Git.Git'; Target = $null; Source = 'winget'; File = 'winget'; First = 'upgrade' }
        @{ Command = 'winget upgrade --id XP89DCGQ3K6VLD --exact --source msstore'; Subject = 'winget:XP89DCGQ3K6VLD'; Target = $null; Source = 'winget'; File = 'winget'; First = 'upgrade' }
        @{ Command = 'choco upgrade python314 -y'; Subject = 'choco:python314'; Target = $null; Source = 'chocolatey'; File = 'choco'; First = 'upgrade' }
        @{ Command = 'pnpm add -g zcatalyst-cli@1.28.0'; Subject = 'npm:zcatalyst-cli'; Target = '1.28.0'; Source = 'npm-registry'; File = 'pnpm'; First = 'add' }
        @{ Command = 'pnpm add -g @angular/cli@22.2.2'; Subject = $null; Target = '22.2.2'; Source = 'policy'; File = 'pnpm'; First = 'add' }
        @{ Command = 'npm install -g nodemon@4.0.0'; Subject = 'npm:nodemon'; Target = '4.0.0'; Source = 'npm-registry'; File = 'npm'; First = 'install' }
        @{ Command = 'sdkmanager cmdline-tools;latest'; Subject = $null; Target = $null; Source = 'toolchain'; File = 'sdkmanager'; First = 'cmdline-tools;latest' }
        @{ Command = 'wsl --update'; Subject = $null; Target = $null; Source = 'wsl'; File = 'wsl'; First = '--update' }
    ) {
        $call = ConvertTo-ExecutionCall -Action (New-TestAction -Order 1 -Id 'x:y' -Command $Command -Subject $Subject -Target $Target -Source $Source)
        $call.filePath | Should -Be $File
        $call.arguments[0] | Should -Be $First
    }

    It 'adds the agreement flags only to WinGet calls' {
        (ConvertTo-ExecutionCall -Action $script:plan.actions[0]).arguments | Should -Contain '--accept-package-agreements'
        (ConvertTo-ExecutionCall -Action $script:plan.actions[1]).arguments | Should -Not -Contain '--accept-package-agreements'
        (ConvertTo-ExecutionCall -Action $script:plan.actions[1]).requiresElevation | Should -BeTrue
    }

    It 'pins pip to the target version' {
        $call = ConvertTo-ExecutionCall -Action (New-TestAction -Order 1 -Id 'tool-upgrade:pip' -Command 'python -m pip install pip==26.2.1' -Target '26.2.1' -Source 'toolchain')
        $call.arguments -join ' ' | Should -Be '-m pip install pip==26.2.1'
        { ConvertTo-ExecutionCall -Action (New-TestAction -Order 1 -Id 'tool-upgrade:pip' -Command 'python -m pip install pip==25.3' -Target '26.2.1' -Source 'toolchain') } | Should -Throw
        { ConvertTo-ExecutionCall -Action (New-TestAction -Order 1 -Id 'tool-upgrade:pip' -Command 'python -m pip install --upgrade pip' -Target '26.2.1' -Source 'toolchain') } | Should -Throw
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a manual action'; Command = $null; Subject = $null; Target = $null }
        @{ Name = 'an unknown command'; Command = 'winget uninstall --id Git.Git'; Subject = 'winget:Git.Git'; Target = $null }
        @{ Name = 'a shell metacharacter'; Command = 'winget upgrade --id Git.Git --exact & calc'; Subject = 'winget:Git.Git'; Target = $null }
        @{ Name = 'a package that is not the subject'; Command = 'winget upgrade --id Evil.Package --exact'; Subject = 'winget:Git.Git'; Target = $null }
        @{ Name = 'a version that is not the target'; Command = 'pnpm add -g nodemon@9.9.9'; Subject = 'npm:nodemon'; Target = '4.0.0' }
        @{ Name = 'an untracked package outside its subject'; Command = 'pnpm add -g left-pad@1.3.0'; Subject = 'npm:nodemon'; Target = '1.3.0' }
        @{ Name = 'winget upgrade --all'; Command = 'winget upgrade --all'; Subject = $null; Target = $null }
    ) {
        { ConvertTo-ExecutionCall -Action (New-TestAction -Order 1 -Id 'x:y' -Command $Command -Subject $Subject -Target $Target -Source 'npm-registry') } | Should -Throw
    }
}

Describe 'Plan checks' {
    It 'refuses a plan older than 24 hours' {
        { Assert-ExecutablePlan -Plan (New-TestPlan -Actions @() -GeneratedAt '2026-10-12T10:00:00+00:00') -PolicyDigest $script:digest -Now $script:now } | Should -Throw '*older than 24 hours*'
    }

    It 'refuses a plan built from a different policy' {
        { Assert-ExecutablePlan -Plan (New-TestPlan -Actions @() -Digest ('b' * 64)) -PolicyDigest $script:digest -Now $script:now } | Should -Throw '*different workstation policy*'
    }

    It 'selects nothing by default and refuses unknown actions' {
        { Invoke-TestUpdate } | Should -Throw '*No action selected*'
        { Invoke-TestUpdate -Action @('99') } | Should -Throw "*no action '99'*"
    }

    It 'selects by risk without ever including high risk' {
        @(Select-ExecutionAction -Plan $script:plan -Risk medium | ForEach-Object order) -join ',' | Should -Be '1,2,3,4'
        @(Select-ExecutionAction -Plan $script:plan -Action @('5', 'wsl-update:wsl') | ForEach-Object order) -join ',' | Should -Be '4,5'
    }
}

Describe 'Running actions' {
    It 'changes nothing and asks nothing in a dry run' {
        $result = Invoke-TestUpdate -Risk medium
        $script:ran.Count | Should -Be 0
        $script:asked | Should -Be 0
        $result.log.mode | Should -Be 'dry-run'
    }

    It 'runs confirmed actions, skips manual, high-risk and unelevated ones, and logs every result' {
        $result = Invoke-TestUpdate -Action @('1', '2', '3', '4', '5') -Apply -Elevated $false
        @($script:ran | ForEach-Object filePath) -join ',' | Should -Be 'winget,wsl'
        $byOrder = @{}
        foreach ($entry in $result.log.actions) { $byOrder[[int]$entry.order] = $entry }
        $byOrder[1].result | Should -Be 'succeeded'
        $byOrder[2].reason | Should -Match 'elevated'
        $byOrder[3].reason | Should -Match 'manual'
        $byOrder[5].reason | Should -Match 'High-risk'
        (Get-Content -LiteralPath $result.logPath -Raw -Encoding UTF8 | ConvertFrom-Json).actions.Count | Should -Be 5
    }

    It 'runs nothing the operator declines' {
        $result = Invoke-TestUpdate -Action @('1') -Apply -Answer $false
        $script:ran.Count | Should -Be 0
        $result.log.actions[0].result | Should -Be 'skipped'
    }

    It 'stops at the first failure' {
        $failing = { param($Call) $script:ran.Add($Call); [pscustomobject]@{ exitCode = 1603; timedOut = $false; found = $true; output = 'installer failed' } }
        $result = Invoke-TestUpdate -Action @('1', '4') -Apply -Runner $failing
        $script:ran.Count | Should -Be 1
        $result.log.actions[0].result | Should -Be 'failed'
        $result.log.actions[0].reason | Should -Match '1603'
        $result.log.actions[1].result | Should -Be 'not-run'
    }
}

Describe 'Batch confirmation' {
    It 'runs every runnable action after the operator types their number, without asking per action' {
        $result = Invoke-TestUpdate -Risk medium -Apply -ConfirmAll -Typed '3'
        $script:batchAsked | Should -Be 1
        $script:asked | Should -Be 0
        @($script:ran | ForEach-Object filePath) -join ',' | Should -Be 'winget,choco,wsl'
        $result.log.mode | Should -Be 'apply-confirm-all'
        @($result.log.actions | Where-Object result -eq 'succeeded') | Should -HaveCount 3
    }

    It 'runs nothing when the typed number does not match' {
        $result = Invoke-TestUpdate -Risk medium -Apply -ConfirmAll -Typed 'yes'
        $script:ran.Count | Should -Be 0
        @($result.log.actions | Where-Object { $_.reason -eq 'Batch not confirmed by the operator.' }) | Should -HaveCount 3
    }

    It 'keeps going past a failure and records it' {
        $failFirst = {
            param($Call)
            $script:ran.Add($Call)
            $code = if ($Call.filePath -eq 'winget') { 1603 } else { 0 }
            [pscustomobject]@{ exitCode = $code; timedOut = $false; found = $true; output = '' }
        }
        $result = Invoke-TestUpdate -Risk medium -Apply -ConfirmAll -Typed '3' -Runner $failFirst
        $script:ran.Count | Should -Be 3
        ($result.log.actions | Where-Object order -eq 1).result | Should -Be 'failed'
        ($result.log.actions | Where-Object order -eq 4).result | Should -Be 'succeeded'
    }

    It 'is still a dry run without -Apply' {
        Invoke-TestUpdate -Risk medium -ConfirmAll -Typed '3' | Out-Null
        $script:ran.Count | Should -Be 0
        $script:batchAsked | Should -Be 0
    }
}

Describe 'Process runner' {
    BeforeAll {
        $script:windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    It 'returns when the process exits even if a child it started keeps running' {
        $command = 'Start-Process -FilePath ping.exe -ArgumentList ''-n 30 127.0.0.1'' -NoNewWindow; Write-Output parent-done'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $outcome = Invoke-ExecutionCall -Call ([pscustomobject]@{ filePath = $script:windowsPowerShell; arguments = @('-NoProfile', '-Command', $command) })
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 20
        $outcome.timedOut | Should -BeFalse
        $outcome.output | Should -Match 'parent-done'
    }

    It 'answers a prompt with end-of-input instead of waiting' {
        $outcome = Invoke-ExecutionCall -Call ([pscustomobject]@{ filePath = $script:windowsPowerShell; arguments = @('-NoProfile', '-Command', '$null = Read-Host prompt; Write-Output answered') })
        $outcome.timedOut | Should -BeFalse
    }

    It 'passes the exit code through and quotes cmd separators' {
        (Invoke-ExecutionCall -Call ([pscustomobject]@{ filePath = 'cmd.exe'; arguments = @('/d', '/c', 'exit 7') })).exitCode | Should -Be 7
        ConvertTo-ExecutionArgumentString -Arguments @('cmdline-tools;latest', 'add', '-g', 'a@1.0') | Should -Be '"cmdline-tools;latest" add -g a@1.0'
    }

    # Run-Update.cmd hosts the executor in Windows PowerShell 5.1, which loses ExitCode unless the
    # process handle is opened early; Pester itself runs on PowerShell 7.
    It 'passes the exit code through on Windows PowerShell 5.1' {
        $module = Join-Path $PSScriptRoot '..\..\..\scripts\Execution\Execution.Core.psm1'
        $probe = "Import-Module '$module'; (Invoke-ExecutionCall -Call ([pscustomobject]@{ filePath = 'cmd.exe'; arguments = @('/d', '/c', 'exit 7') })).exitCode"
        (& $script:windowsPowerShell -NoProfile -NonInteractive -Command $probe | Select-Object -Last 1) | Should -Be '7'
    }

    It 'reports a command that cannot be found' {
        (Invoke-ExecutionCall -Call ([pscustomobject]@{ filePath = 'workstation-no-such-tool'; arguments = @() })).found | Should -BeFalse
    }
}

Describe 'Failure explanations' {
    BeforeAll {
        $script:wingetCall = [pscustomobject]@{ filePath = 'winget'; arguments = @('upgrade', '--id', 'Git.Git', '--exact') }
    }

    It 'reads the blocking programs from the installer log WinGet reports' {
        $installerLog = Join-Path $TestDrive 'Git.Git.log'
        Set-Content -LiteralPath $installerLog -Encoding UTF8 -Value @(
            '2026-10-26 00:07:19.384   Defaulting to Cancel for suppressed message box (Retry/Cancel):'
            '                          The following process(es) use Git for Windows:'
            '                          bash.exe (PID 15512)'
            '                          bash.exe (PID 9576)'
            '2026-10-26 00:07:19.384   Failed to proceed to next wizard page; aborting.'
        )
        $output = "Installer failed with exit code: 1`nInstaller log is available at: $installerLog"
        $detail = Get-ExecutionFailureDetail -Call $script:wingetCall -ExitCode -1978335226 -Output $output
        $detail.result | Should -Be 'failed'
        $detail.reason | Should -Match '0x8A150006'
        $detail.reason | Should -Match 'using it: bash\.exe\. Close them'
        $detail.reason | Should -Match ([regex]::Escape($installerLog))
    }

    It 'classifies WinGet result <Code> as <Result>' -ForEach @(
        @{ Code = -1978335189; Result = 'skipped' }
        @{ Code = -1978334967; Result = 'succeeded' }
        @{ Code = -1978334975; Result = 'failed' }
        @{ Code = 5; Result = 'failed' }
    ) {
        (Get-ExecutionFailureDetail -Call $script:wingetCall -ExitCode $Code).result | Should -Be $Result
    }

    It 'explains a stalled download' {
        $detail = Get-ExecutionFailureDetail -Call $script:wingetCall -ExitCode $null -TimedOut $true -Output "Found Docker Desktop`nDownloading https://desktop.docker.com/installer.exe"
        $detail.reason | Should -Match 'download stalled'
        $detail.reason | Should -Match 'wininet'
    }

    It 'treats exit code 0 as success' {
        (Get-ExecutionFailureDetail -Call $script:wingetCall -ExitCode 0).result | Should -Be 'succeeded'
    }
}

Describe 'Preflight' {
    It 'names running apps that would block their own update' {
        $apps = @(Get-ExecutionBlockingApps -Calls @($script:wingetCall) -RunningProcesses @('explorer', 'bash'))
        $apps | Should -HaveCount 1
        $apps[0].app | Should -Be 'Git Bash windows'
        @(Get-ExecutionBlockingApps -Calls @($script:wingetCall) -RunningProcesses @('explorer')) | Should -HaveCount 0
    }

    It 'reads the WinGet downloader setting (<Name>)' -ForEach @(
        @{ Name = 'wininet with comments'; Content = "{`n  // comment`n  `"network`": { `"downloader`": `"wininet`" }`n}"; Expected = 'wininet' }
        @{ Name = 'unset'; Content = '{ "visual": { "progressBar": "rainbow" } }'; Expected = 'default' }
        @{ Name = 'malformed'; Content = '{ not json'; Expected = $null }
    ) {
        $path = Join-Path $TestDrive "settings-$([guid]::NewGuid().ToString('N')).json"
        Set-Content -LiteralPath $path -Encoding UTF8 -Value $Content
        Get-WinGetDownloader -SettingsPath $path | Should -Be $Expected
        Get-WinGetDownloader -SettingsPath (Join-Path $TestDrive 'missing.json') | Should -Be 'default'
    }

    It 'records blocking apps and the downloader in the run log' {
        $result = Invoke-TestUpdate -Action @('1') -Running @('bash') -Downloader 'default'
        @($result.log.preflight.blockingApps) | Should -HaveCount 1
        $result.log.preflight.winGetDownloader | Should -Be 'default'
    }
}

Describe 'WinGet downloader fix' {
    It 'sets wininet, keeps other settings and backs up the file' {
        $path = Join-Path $TestDrive 'existing\settings.json'
        New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Encoding UTF8 -Value "{`n  // keep me?`n  `"visual`": { `"progressBar`": `"rainbow`" }`n}"
        $backup = Set-WinGetDownloader -SettingsPath $path
        Test-Path -LiteralPath $backup | Should -BeTrue
        Get-WinGetDownloader -SettingsPath $path | Should -Be 'wininet'
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).visual.progressBar | Should -Be 'rainbow'
    }

    It 'creates the settings file when WinGet has none' {
        $path = Join-Path $TestDrive 'new\settings.json'
        Set-WinGetDownloader -SettingsPath $path | Should -BeNullOrEmpty
        Get-WinGetDownloader -SettingsPath $path | Should -Be 'wininet'
    }
}

Describe 'Verification after a run' {
    It 'marks ran actions verified or still pending against the new plan' {
        $log = [pscustomobject]@{ actions = @(
                [pscustomobject]@{ order = 1; actionId = 'winget-upgrade:Git.Git'; title = 'Upgrade Git'; result = 'succeeded' }
                [pscustomobject]@{ order = 2; actionId = 'winget-upgrade:Zoom.Zoom'; title = 'Upgrade Zoom'; result = 'succeeded' }
                [pscustomobject]@{ order = 3; actionId = 'winget-upgrade:Docker.DockerDesktop'; title = 'Upgrade Docker'; result = 'failed' }
                [pscustomobject]@{ order = 4; actionId = 'tool-upgrade:uv'; title = 'Upgrade uv'; result = 'not-run' }
            ) }
        $newPlan = [pscustomobject]@{ report = [pscustomobject]@{ generatedAt = '2026-10-26T02:00:00+00:00' }; actions = @(
                [pscustomobject]@{ actionId = 'winget-upgrade:Zoom.Zoom'; currentVersion = '7.1.9'; targetVersion = '7.2.1' }
                [pscustomobject]@{ actionId = 'winget-upgrade:Docker.DockerDesktop'; currentVersion = '4.91.0'; targetVersion = '4.96.3' }
            ) }
        $verification = Get-ExecutionVerification -Log $log -NewPlan $newPlan
        $byOrder = @{}
        foreach ($item in $verification.actions) { $byOrder[[int]$item.order] = $item }
        $byOrder[1].verification | Should -Be 'verified'
        $byOrder[2].verification | Should -Be 'still-pending'
        $byOrder[2].currentVersion | Should -Be '7.1.9'
        $byOrder[3].verification | Should -Be 'still-pending'
        $byOrder[4].verification | Should -Be 'resolved'
        $verification.verifiedCount | Should -Be 1
        $verification.stillPendingCount | Should -Be 2
        $verification.remainingPlanCount | Should -Be 2
    }
}

Describe 'Rust toolchain update' {
    It 'allows rustup update stable' {
        $call = ConvertTo-ExecutionCall -Action (New-TestAction -Order 1 -Id 'policy:rust.defaultTrack' -Command 'rustup update stable' -Target '1.99.1' -Source 'policy')
        $call.filePath | Should -Be 'rustup'
        $call.arguments -join ' ' | Should -Be 'update stable'
    }
}

Describe 'Causes seen in the PC #1 batch' {
    It 'explains WinGet result <Code>' -ForEach @(
        @{ Code = -1978335090; Pattern = 'different installer technology' }
        @{ Code = -2145844845; Pattern = 'HTTP 403' }
        @{ Code = -1978335189; Pattern = 'no update that applies' }
    ) {
        (Get-ExecutionFailureDetail -Call ([pscustomobject]@{ filePath = 'winget'; arguments = @() }) -ExitCode $Code).reason | Should -Match $Pattern
    }
}
