Set-StrictMode -Version Latest

# The only code in the toolkit allowed to change a workstation. Every rule here comes from
# docs/policies/update-execution-safety.md; change the policy first, then this module.


$script:SupportedPlanVersions = @('1.1.0')
$script:MaximumPlanAgeHours = 24
$script:ActionTimeoutSeconds = 1800
$script:OutputTailLength = 4000
$script:PolicyTrackedPackages = @('@angular/cli', 'typescript', 'prisma')
$script:WinGetAgreementArguments = @('--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')

function Get-ExecutionProperty {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-ExecutionCall {
    <#
    .SYNOPSIS
    Validates a plan action's command against the allow-list and rebuilds it from its parts.
    Returns @{ filePath; arguments; requiresElevation; acceptsAgreements } or throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Action)

    $command = [string](Get-ExecutionProperty -InputObject $Action -Name 'command')
    $subjectId = [string](Get-ExecutionProperty -InputObject $Action -Name 'subjectId')
    $target = [string](Get-ExecutionProperty -InputObject $Action -Name 'targetVersion')
    $sourceType = [string](Get-ExecutionProperty -InputObject (Get-ExecutionProperty -InputObject $Action -Name 'source') -Name 'type')

    if ([string]::IsNullOrWhiteSpace($command)) { throw 'The action is manual; it has no command to run.' }
    if ($command -cnotmatch '^[A-Za-z0-9 ._+@/;:=-]+$') { throw "The command contains characters outside the allow-list: $command" }

    $call = { param($File, $Arguments, $Elevation = $false, $Agreements = $false)
        [pscustomobject][ordered]@{ filePath = $File; arguments = @($Arguments); requiresElevation = $Elevation; acceptsAgreements = $Agreements }
    }

    $match = [regex]::Match($command, '^winget upgrade --id (?<id>[A-Za-z0-9][A-Za-z0-9._+-]*) --exact(?<store> --source msstore)?$')
    if ($match.Success) {
        $id = $match.Groups['id'].Value
        if ($subjectId -cne "winget:$id") { throw "The WinGet package '$id' does not match the action subject '$subjectId'." }
        $arguments = @('upgrade', '--id', $id, '--exact')
        if ($match.Groups['store'].Success) { $arguments += @('--source', 'msstore') }
        return & $call 'winget' ($arguments + $script:WinGetAgreementArguments) $false $true
    }

    if ($command -cmatch '^winget install --id (?<id>pnpm\.pnpm|Python\.PythonInstallManager) --exact$') {
        return & $call 'winget' (@('install', '--id', $Matches['id'], '--exact') + $script:WinGetAgreementArguments) $false $true
    }

    $match = [regex]::Match($command, '^choco upgrade (?<id>[0-9A-Za-z][0-9A-Za-z._-]*) -y$')
    if ($match.Success) {
        $id = $match.Groups['id'].Value
        if ($subjectId -cne "choco:$id") { throw "The Chocolatey package '$id' does not match the action subject '$subjectId'." }
        return & $call 'choco' @('upgrade', $id, '-y') $true $false
    }

    $match = [regex]::Match($command, '^(?<manager>pnpm add|npm install) -g (?<package>@angular/cli|[a-z0-9][a-z0-9._-]*)@(?<version>\d+(?:\.\d+){1,3}(?:-[0-9A-Za-z.]+)?)$')
    if ($match.Success) {
        $package = $match.Groups['package'].Value
        $version = $match.Groups['version'].Value
        $tracked = $sourceType -eq 'policy' -and $package -in $script:PolicyTrackedPackages
        if (-not $tracked -and $subjectId -cne "npm:$package") { throw "The package '$package' is neither policy-tracked nor the action subject '$subjectId'." }
        if ($version -cne $target) { throw "The version '$version' is not the action's target version '$target'." }
        $verb = 'install'
        if ($match.Groups['manager'].Value -eq 'pnpm add') { $verb = 'add' }
        $arguments = @($verb, '-g', "$package@$version")
        return & $call ($match.Groups['manager'].Value.Split(' ')[0]) $arguments
    }

    $match = [regex]::Match($command, '^python -m pip install pip==(?<version>\d+(?:\.\d+){1,3})$')
    if ($match.Success) {
        if ($match.Groups['version'].Value -cne $target) { throw "The pip version '$($match.Groups['version'].Value)' is not the action's target version '$target'." }
        return & $call 'python' @('-m', 'pip', 'install', "pip==$($match.Groups['version'].Value)")
    }

    $exact = @{
        'wsl --update'                        = @('wsl', @('--update'))
        'flutter upgrade'                     = @('flutter', @('upgrade'))
        'flutter channel stable'              = @('flutter', @('channel', 'stable'))
        'flutter channel beta'                = @('flutter', @('channel', 'beta'))
        'flutter channel master'              = @('flutter', @('channel', 'master'))
        'pnpm self-update'                    = @('pnpm', @('self-update'))
        'uv self update'                      = @('uv', @('self', 'update'))
        'rustup update stable'                = @('rustup', @('update', 'stable'))
        'sdkmanager platform-tools'           = @('sdkmanager', @('platform-tools'))
        'sdkmanager cmdline-tools;latest'     = @('sdkmanager', @('cmdline-tools;latest'))
    }
    foreach ($key in $exact.Keys) {
        if ($command -ceq $key) { return & $call $exact[$key][0] $exact[$key][1] }
    }

    throw "The command is not in the execution allow-list: $command"
}

function Get-ExecutionFileDigest {
    param([Parameter(Mandatory)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-ExecutablePlan {
    <#
    .SYNOPSIS
    Refuses a plan that is malformed, older than 24 hours, or built from a different policy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$PolicyDigest,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $version = [string](Get-ExecutionProperty -InputObject $Plan -Name 'schemaVersion')
    if ($version -notin $script:SupportedPlanVersions) { throw "Unsupported update plan schema version '$version'." }
    if ($null -eq $Plan.PSObject.Properties['actions']) { throw 'The update plan has no actions array.' }

    $generatedAt = [DateTimeOffset]::MinValue
    $generatedText = [string](Get-ExecutionProperty -InputObject (Get-ExecutionProperty -InputObject $Plan -Name 'report') -Name 'generatedAt')
    if (-not [DateTimeOffset]::TryParse($generatedText, [ref]$generatedAt)) { throw 'The update plan does not say when its audit report was generated.' }
    if (($Now - $generatedAt).TotalHours -gt $script:MaximumPlanAgeHours) {
        throw "The audit report behind this plan is older than $($script:MaximumPlanAgeHours) hours ($generatedText). Re-run the audit and the plan."
    }

    $planDigest = [string](Get-ExecutionProperty -InputObject (Get-ExecutionProperty -InputObject $Plan -Name 'policy') -Name 'digest')
    if ($planDigest -cne $PolicyDigest) { throw 'The update plan was built from a different workstation policy. Re-run the plan.' }
}

function Select-ExecutionAction {
    <#
    .SYNOPSIS
    Chooses actions by order or actionId, or every action up to a risk level. Nothing by default; never high risk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [AllowEmptyCollection()][string[]]$Action = @(),
        [ValidateSet('', 'low', 'medium')][string]$Risk = ''
    )

    $actions = @(Get-ExecutionProperty -InputObject $Plan -Name 'actions' | Where-Object { $null -ne $_ })
    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $actions) {
        $byRisk = ($Risk -eq 'low' -and $item.risk -eq 'low') -or ($Risk -eq 'medium' -and $item.risk -in @('low', 'medium'))
        $byName = ([string]$item.order -in $Action) -or ([string]$item.actionId -in $Action)
        if ($byRisk -or $byName) { $selected.Add($item) }
    }

    foreach ($requested in $Action) {
        if (-not @($actions | Where-Object { [string]$_.order -eq $requested -or [string]$_.actionId -eq $requested })) {
            throw "The plan has no action '$requested'."
        }
    }

    return $selected.ToArray()
}

function Test-ExecutionElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ExecutionArgumentString {
    <#
    .SYNOPSIS
    Joins validated arguments for CreateProcess; arguments with spaces or cmd separators (;) are quoted.
    #>
    param([string[]]$Arguments)

    return (@($Arguments | ForEach-Object { if ($_ -match '[\s;,=]') { '"' + $_ + '"' } else { $_ } }) -join ' ')
}

function Invoke-ExecutionCall {
    <#
    .SYNOPSIS
    Runs one validated call; the default runner for Invoke-WorkstationUpdate.
    .DESCRIPTION
    Output goes to files and stdin is an empty file. The executor waits only for the process it
    started: a child left running by the tool (flutter upgrade starts Dart processes) can no longer
    hold a pipe open and keep the action "running" after the update finished, and a prompt reads
    end-of-input instead of waiting forever. On timeout the process is stopped and the partial
    output is kept.
    #>
    param([Parameter(Mandatory)][psobject]$Call)

    $resolved = Get-Command $Call.filePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $resolved) {
        return [pscustomobject][ordered]@{ exitCode = $null; timedOut = $false; found = $false; output = '' }
    }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('workstation-update-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $stdin = Join-Path $work 'stdin.txt'
    $stdout = Join-Path $work 'stdout.txt'
    $stderr = Join-Path $work 'stderr.txt'
    [IO.File]::WriteAllText($stdin, '')

    try {
        $startParameters = @{
            FilePath               = $resolved.Source
            RedirectStandardInput  = $stdin
            RedirectStandardOutput = $stdout
            RedirectStandardError  = $stderr
            NoNewWindow            = $true
            PassThru               = $true
        }
        $argumentString = ConvertTo-ExecutionArgumentString -Arguments $Call.arguments
        if (-not [string]::IsNullOrEmpty($argumentString)) { $startParameters['ArgumentList'] = $argumentString }

        $process = Start-Process @startParameters
        # Windows PowerShell 5.1 reports ExitCode as $null unless the process handle is opened
        # before the process exits; every successful update was logged as "Exit code ." without this.
        $null = $process.Handle
        $exited = $process.WaitForExit($script:ActionTimeoutSeconds * 1000)
        if (-not $exited) {
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(10000)
        }

        # A child that outlives the process may still hold the file open; read it shared.
        $read = {
            param($Path)
            if (-not (Test-Path -LiteralPath $Path)) { return '' }
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            try { return (New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $stream.Dispose() }
        }
        $text = ((& $read $stdout) + [Environment]::NewLine + (& $read $stderr)).Trim()
        $escape = [string][char]27
        $text = [regex]::Replace($text, $escape + '(\[[0-9;?]*[ -/]*[@-~]|\][^' + [char]7 + $escape + ']*(' + [char]7 + '|' + $escape + '\\))', '')

        return [pscustomobject][ordered]@{
            exitCode = $(if ($exited) { $process.ExitCode } else { $null })
            timedOut = -not $exited
            found    = $true
            output   = $text
        }
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-ExecutionLog {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][psobject]$Log)

    $json = ($Log | ConvertTo-Json -Depth 20).Replace("`r`n", "`n")
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

# WinGet result codes the executor explains (0x8A15xxxx, as signed 32-bit values).
$script:WinGetResults = @{
    -1978335226 = @{ result = 'failed'; reason = 'The installer failed (WinGet 0x8A150006).' }
    -1978335212 = @{ result = 'failed'; reason = 'WinGet found no installed package with this ID (0x8A150014).' }
    -1978335189 = @{ result = 'skipped'; reason = 'WinGet found no update that applies to this installation (0x8A15002B); update it from the app itself.' }
    -1978335090 = @{ result = 'failed'; reason = 'The new version uses a different installer technology than the installed one; uninstall it and install the new version (WinGet 0x8A15008E).' }
    -1978334975 = @{ result = 'failed'; reason = 'The application is running; close it and retry (WinGet 0x8A150101).' }
    -1978334974 = @{ result = 'failed'; reason = 'Another installation is in progress; retry when it finishes (WinGet 0x8A150102).' }
    -1978334967 = @{ result = 'succeeded'; reason = 'Installed; restart Windows to finish (WinGet 0x8A150109).' }
    -2145844845 = @{ result = 'failed'; reason = 'The vendor download server refused the download (HTTP 403, 0x80190193); retry later.' }
}

# Apps that block their own update while they run. Matched against the WinGet package ID.
$script:BlockingProcesses = @(
    @{ Package = '^Git\.Git$'; Processes = @('bash', 'mintty', 'git-bash'); Name = 'Git Bash windows' }
    @{ Package = '^Docker\.DockerDesktop$'; Processes = @('Docker Desktop'); Name = 'Docker Desktop' }
    @{ Package = '^Google\.Chrome'; Processes = @('chrome'); Name = 'Google Chrome' }
    @{ Package = '^Mozilla\.Firefox'; Processes = @('firefox'); Name = 'Firefox' }
    @{ Package = '^Zen-Team\.Zen-Browser'; Processes = @('zen'); Name = 'Zen Browser' }
    @{ Package = '^Zoom\.Zoom'; Processes = @('Zoom'); Name = 'Zoom' }
    @{ Package = '^Postman\.Postman$'; Processes = @('Postman'); Name = 'Postman' }
    @{ Package = '^Notion\.Notion$'; Processes = @('Notion'); Name = 'Notion' }
    @{ Package = '^Notion\.NotionCalendar$'; Processes = @('Notion Calendar'); Name = 'Notion Calendar' }
    @{ Package = '^Figma\.Figma$'; Processes = @('Figma'); Name = 'Figma' }
    @{ Package = '^Anysphere\.Cursor$'; Processes = @('Cursor'); Name = 'Cursor' }
    @{ Package = '^Anthropic\.Claude$'; Processes = @('claude'); Name = 'Claude' }
    @{ Package = '^Codeium\.Windsurf$'; Processes = @('Windsurf'); Name = 'Windsurf' }
    @{ Package = '^ByteDance\.Trae$'; Processes = @('Trae'); Name = 'Trae' }
    @{ Package = '^Microsoft\.VisualStudioCode$'; Processes = @('Code'); Name = 'Visual Studio Code' }
    @{ Package = '^Microsoft\.WindowsTerminal$'; Processes = @('WindowsTerminal'); Name = 'Windows Terminal' }
    @{ Package = '^Microsoft\.PowerShell$'; Processes = @('pwsh'); Name = 'PowerShell 7 windows' }
)

function Get-ExecutionBlockingApps {
    <#
    .SYNOPSIS
    For the WinGet actions about to run, the running apps that would make their installer fail.
    #>
    param(
        [AllowEmptyCollection()][object[]]$Calls = @(),
        [AllowEmptyCollection()][string[]]$RunningProcesses = @()
    )

    $running = @{}
    foreach ($name in $RunningProcesses) { $running[$name.ToLowerInvariant()] = $true }
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($call in $Calls) {
        if ($call.filePath -ne 'winget') { continue }
        $id = [string]$call.arguments[([array]::IndexOf([string[]]$call.arguments, '--id') + 1)]
        foreach ($rule in $script:BlockingProcesses) {
            if ($id -notmatch $rule.Package) { continue }
            if (@($rule.Processes | Where-Object { $running.ContainsKey($_.ToLowerInvariant()) }).Count -gt 0) {
                $found.Add([pscustomobject]@{ packageId = $id; app = $rule.Name })
            }
        }
    }
    return $found.ToArray()
}

function Get-WinGetDownloader {
    <#
    .SYNOPSIS
    The downloader WinGet is configured to use ('default' when unset, $null when unreadable).
    Delivery Optimization ('default'/'do') can stall at 0 bytes; 'wininet' avoids it.
    #>
    param([string]$SettingsPath = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'))

    if (-not (Test-Path -LiteralPath $SettingsPath)) { return 'default' }
    try {
        # settings.json allows // comments.
        $text = (Get-Content -LiteralPath $SettingsPath -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
        $settings = $text | ConvertFrom-Json
        $network = $settings.PSObject.Properties['network']
        if ($null -eq $network -or $null -eq $network.Value.PSObject.Properties['downloader']) { return 'default' }
        return [string]$network.Value.downloader
    }
    catch {
        return $null
    }
}

function Set-WinGetDownloader {
    <#
    .SYNOPSIS
    Sets network.downloader to wininet in WinGet's settings.json, after a backup. Other settings are kept;
    // comments are not (WinGet does not need them). Returns the backup path, or $null when no file existed.
    #>
    param([string]$SettingsPath = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'))

    $backup = $null
    $settings = [pscustomobject]@{}
    if (Test-Path -LiteralPath $SettingsPath) {
        $backup = "$SettingsPath.$(Get-Date -Format yyyyMMdd-HHmmss).bak"
        Copy-Item -LiteralPath $SettingsPath -Destination $backup
        $text = (Get-Content -LiteralPath $SettingsPath -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
        if (-not [string]::IsNullOrWhiteSpace($text)) { $settings = $text | ConvertFrom-Json }
    }

    if ($null -eq $settings.PSObject.Properties['network']) {
        $settings | Add-Member -NotePropertyName network -NotePropertyValue ([pscustomobject]@{})
    }
    if ($null -eq $settings.network.PSObject.Properties['downloader']) {
        $settings.network | Add-Member -NotePropertyName downloader -NotePropertyValue 'wininet'
    }
    else {
        $settings.network.downloader = 'wininet'
    }

    [IO.Directory]::CreateDirectory((Split-Path -Parent $SettingsPath)) | Out-Null
    [IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    return $backup
}

function Get-ExecutionFailureDetail {
    <#
    .SYNOPSIS
    Classifies a finished call: known WinGet results, the cause in the installer log, stalled downloads.
    Returns @{ result; reason }.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Call,
        [AllowNull()][object]$ExitCode,
        [bool]$TimedOut = $false,
        [AllowNull()][string]$Output = ''
    )

    $lines = @(([string]$Output) -split '\r?\n' | Where-Object { $_.Trim() })
    $last = if ($lines.Count -gt 0) { $lines[-1] } else { '' }

    if ($TimedOut) {
        if ($Call.filePath -eq 'winget' -and $last -match '(?i)^\s*(Downloading|Descargando)\b') {
            return @{ result = 'failed'; reason = "The download stalled and timed out after $($script:ActionTimeoutSeconds) seconds. WinGet's Delivery Optimization downloader can hang; set network.downloader to wininet (winget settings) and retry." }
        }
        return @{ result = 'failed'; reason = "Timed out after $($script:ActionTimeoutSeconds) seconds; the process was stopped. Last output: $($last.Trim())" }
    }
    if ($null -eq $ExitCode -or [int]$ExitCode -eq 0) { return @{ result = 'succeeded'; reason = $null } }

    $known = $null
    if ($Call.filePath -eq 'winget' -and $script:WinGetResults.ContainsKey([int]$ExitCode)) { $known = $script:WinGetResults[[int]$ExitCode] }
    $result = if ($null -ne $known) { $known.result } else { 'failed' }
    $reason = if ($null -ne $known) { $known.reason } else { "Exit code $ExitCode." }

    # WinGet prints the installer's own log path; its last lines usually name the cause.
    $logMatch = [regex]::Match([string]$Output, '[A-Za-z]:\\[^\r\n"<>|]+?\.log')
    if ($result -eq 'failed' -and $logMatch.Success -and (Test-Path -LiteralPath $logMatch.Value)) {
        $installerLog = @(Get-Content -LiteralPath $logMatch.Value -Encoding UTF8 -Tail 60 -ErrorAction SilentlyContinue)
        $blocking = @($installerLog | ForEach-Object { if ($_ -match '^\s*(\S+\.exe) \(PID \d+\)') { $Matches[1] } } | Select-Object -Unique)
        if ($blocking.Count -gt 0) {
            $reason += " The installer stopped because these programs were using it: $($blocking -join ', '). Close them and retry."
        }
        $reason += " Installer log: $($logMatch.Value)"
    }
    return @{ result = $result; reason = $reason }
}

function Get-ExecutionVerification {
    <#
    .SYNOPSIS
    Compares a run log with the plan built from a fresh audit after the run.
    An action that ran and no longer appears in the new plan is verified; one that is still planned is still pending.
    #>
    param(
        [Parameter(Mandatory)][psobject]$Log,
        [Parameter(Mandatory)][psobject]$NewPlan
    )

    $pending = @{}
    foreach ($action in @($NewPlan.actions)) { $pending[[string]$action.actionId] = $action }

    $entries = foreach ($entry in @($Log.actions)) {
        $still = $pending.ContainsKey([string]$entry.actionId)
        $verification = if ($entry.result -eq 'succeeded') {
            if ($still) { 'still-pending' } else { 'verified' }
        }
        elseif ($still) { 'still-pending' }
        else { 'resolved' }

        [pscustomobject][ordered]@{
            order          = $entry.order
            actionId       = $entry.actionId
            title          = $entry.title
            runResult      = $entry.result
            verification   = $verification
            currentVersion = $(if ($still) { $pending[[string]$entry.actionId].currentVersion } else { $null })
            targetVersion  = $(if ($still) { $pending[[string]$entry.actionId].targetVersion } else { $null })
        }
    }
    $entries = @($entries)

    return [pscustomobject][ordered]@{
        checkedAt           = [DateTimeOffset]::Now.ToString('o')
        reportGeneratedAt   = $NewPlan.report.generatedAt
        verifiedCount       = @($entries | Where-Object verification -eq 'verified').Count
        stillPendingCount   = @($entries | Where-Object verification -eq 'still-pending').Count
        resolvedCount       = @($entries | Where-Object verification -eq 'resolved').Count
        remainingPlanCount  = @($NewPlan.actions).Count
        actions             = $entries
    }
}

function Invoke-WorkstationUpdate {
    <#
    .SYNOPSIS
    Previews, or with -Apply runs, selected plan actions one at a time.
    .DESCRIPTION
    By default every action needs its own yes and the run stops at the first failure. With
    -ConfirmAll the whole list is shown first and confirmed once by typing the number of actions;
    failures are then recorded and the remaining, independent actions still run.
    .PARAMETER Confirmer
    Asks the operator about one action and returns $true to run it. Tests replace it; production prompts.
    .PARAMETER BatchConfirmer
    Asks the operator to confirm the whole batch (-ConfirmAll) and returns the typed text.
    .PARAMETER Runner
    Runs one validated call. Tests replace it; production uses Invoke-ExecutionCall.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Plan,
        [Parameter(Mandatory)][string]$PolicyDigest,
        [AllowEmptyCollection()][string[]]$Action = @(),
        [ValidateSet('', 'low', 'medium')][string]$Risk = '',
        [switch]$Apply,
        [switch]$ConfirmAll,
        [Parameter(Mandatory)][string]$LogDirectory,
        [scriptblock]$Confirmer,
        [scriptblock]$BatchConfirmer,
        [scriptblock]$Runner = { param($Call) Invoke-ExecutionCall -Call $Call },
        [scriptblock]$Elevated = { Test-ExecutionElevated },
        [scriptblock]$ProcessLister = { @(Get-Process | ForEach-Object ProcessName) },
        [scriptblock]$DownloaderCheck = { Get-WinGetDownloader },
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    Assert-ExecutablePlan -Plan $Plan -PolicyDigest $PolicyDigest -Now $Now
    $selected = @(Select-ExecutionAction -Plan $Plan -Action $Action -Risk $Risk)
    if ($selected.Count -eq 0) {
        throw 'No action selected. Choose actions with -Action <order or actionId> or -Risk low|medium.'
    }

    if ($null -eq $Confirmer) {
        $Confirmer = {
            param($Item, $Call)
            $answer = Read-Host "Run action $($Item.order)? [y/N]"
            return $answer -match '^(y|yes|s|si)$'
        }
    }
    if ($null -eq $BatchConfirmer) {
        $BatchConfirmer = { param($Count) Read-Host "Type $Count to run all $Count actions above (anything else cancels)" }
    }

    $directory = [IO.Path]::GetFullPath($LogDirectory)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $logPath = Join-Path $directory ($Now.ToString('yyyyMMdd-HHmmss') + $(if ($Apply) { '' } else { '-dry-run' }) + '.json')
    $log = [pscustomobject][ordered]@{
        startedAt  = $Now.ToString('o')
        mode       = $(if (-not $Apply) { 'dry-run' } elseif ($ConfirmAll) { 'apply-confirm-all' } else { 'apply' })
        planReport = $Plan.report.generatedAt
        policy     = $PolicyDigest
        actions    = @($selected | ForEach-Object {
                [pscustomobject][ordered]@{ order = $_.order; actionId = $_.actionId; title = $_.title; risk = $_.risk; command = $_.command; result = 'not-run'; reason = $null; exitCode = $null; startedAt = $null; finishedAt = $null; outputTail = $null }
            })
    }
    Write-ExecutionLog -Path $logPath -Log $log

    # 1. Validate every selected action before anything runs, and show what would run.
    $runnable = [System.Collections.Generic.List[object]]::new()
    $isElevated = $null
    for ($i = 0; $i -lt $selected.Count; $i++) {
        $item = $selected[$i]
        $entry = $log.actions[$i]

        if ($item.risk -eq 'high') { $entry.result = 'skipped'; $entry.reason = 'High-risk actions are always manual.'; continue }
        try { $call = ConvertTo-ExecutionCall -Action $item }
        catch { $entry.result = 'skipped'; $entry.reason = $_.Exception.Message; continue }

        if ($call.requiresElevation) {
            if ($null -eq $isElevated) { $isElevated = [bool](& $Elevated) }
            if (-not $isElevated) { $entry.result = 'skipped'; $entry.reason = 'Needs an elevated (administrator) shell; the executor never elevates itself.'; continue }
        }

        Write-Host ''
        Write-Host ("{0}. [{1}, {2}] {3}" -f $item.order, $item.risk, $(if ($item.reversible) { 'reversible' } else { 'not reversible' }), $item.title)
        if ($null -ne $item.currentVersion -or $null -ne $item.targetVersion) { Write-Host "   $($item.currentVersion) -> $($item.targetVersion)" }
        Write-Host "   Command: $($call.filePath) $($call.arguments -join ' ')"
        if ($call.acceptsAgreements) { Write-Host '   Running it accepts the package and source agreements of this WinGet package.' }
        if (-not $Apply) { $entry.reason = 'Dry run.' }
        $runnable.Add([pscustomobject]@{ item = $item; call = $call; entry = $entry })
    }

    # Preflight: what will make an action fail before it starts.
    $calls = @($runnable | ForEach-Object { $_.call })
    $log | Add-Member -NotePropertyName preflight -NotePropertyValue ([pscustomobject][ordered]@{ blockingApps = @(); winGetDownloader = $null })
    if ($calls.Count -gt 0) {
        $blockingApps = @(Get-ExecutionBlockingApps -Calls $calls -RunningProcesses @(& $ProcessLister))
        $log.preflight.blockingApps = $blockingApps
        if ($blockingApps.Count -gt 0) {
            Write-Host ''
            Write-Host 'Close these apps first, or their updates will fail:'
            foreach ($app in $blockingApps) { Write-Host "   - $($app.app) ($($app.packageId))" }
        }
        if (@($calls | Where-Object { $_.filePath -eq 'winget' }).Count -gt 0) {
            $downloader = & $DownloaderCheck
            $log.preflight.winGetDownloader = $downloader
            if ($downloader -ne 'wininet') {
                Write-Host ''
                Write-Host 'WinGet downloads through Delivery Optimization, which can stall at 0 bytes. To avoid it, run "winget settings" and add: "network": { "downloader": "wininet" }'
            }
        }
        Write-ExecutionLog -Path $logPath -Log $log
    }

    if ($Apply -and $ConfirmAll -and $runnable.Count -gt 0) {
        Write-Host ''
        Write-Host "$($runnable.Count) action(s) will run without asking again. Failures are recorded and the remaining actions still run."
        $typed = [string](& $BatchConfirmer $runnable.Count)
        if ($typed.Trim() -ne [string]$runnable.Count) {
            foreach ($candidate in $runnable) { $candidate.entry.result = 'skipped'; $candidate.entry.reason = 'Batch not confirmed by the operator.' }
            $runnable.Clear()
            Write-Host 'Batch not confirmed; nothing was run.'
        }
    }

    # 2. Run.
    if ($Apply) {
        foreach ($candidate in $runnable) {
            $item = $candidate.item
            $entry = $candidate.entry

            if (-not $ConfirmAll) {
                Write-Host ''
                Write-Host "$($item.order). $($item.title)"
                if (-not [bool](& $Confirmer $item $candidate.call)) { $entry.result = 'skipped'; $entry.reason = 'Declined by the operator.'; Write-ExecutionLog -Path $logPath -Log $log; continue }
            }
            else {
                Write-Host ''
                Write-Host "Running $($item.order). $($item.title)"
            }

            $entry.startedAt = [DateTimeOffset]::Now.ToString('o')
            $outcome = & $Runner $candidate.call
            $entry.finishedAt = [DateTimeOffset]::Now.ToString('o')
            $entry.exitCode = $outcome.exitCode
            $output = [string]$outcome.output
            $entry.outputTail = if ($output.Length -gt $script:OutputTailLength) { $output.Substring($output.Length - $script:OutputTailLength) } else { $output }

            if (-not $outcome.found) { $entry.result = 'failed'; $entry.reason = "Command '$($candidate.call.filePath)' was not found." }
            else {
                $detail = Get-ExecutionFailureDetail -Call $candidate.call -ExitCode $outcome.exitCode -TimedOut ([bool]$outcome.timedOut) -Output $output
                $entry.result = $detail.result
                $entry.reason = $detail.reason
            }

            Write-ExecutionLog -Path $logPath -Log $log
            if ($entry.result -ne 'failed') { Write-Host $(if ($entry.reason) { "   Done. $($entry.reason)" } else { '   Done.' }); continue }

            if ($ConfirmAll) {
                Write-Host "   Failed: $($entry.reason) Continuing with the next action."
                continue
            }
            Write-Host "   Failed: $($entry.reason) Stopping; later actions were not started."
            break
        }
    }

    Write-ExecutionLog -Path $logPath -Log $log
    return [pscustomobject][ordered]@{ logPath = $logPath; log = $log }
}

Export-ModuleMember -Function @(
    'ConvertTo-ExecutionCall',
    'ConvertTo-ExecutionArgumentString',
    'Assert-ExecutablePlan',
    'Select-ExecutionAction',
    'Get-ExecutionFileDigest',
    'Invoke-ExecutionCall',
    'Get-ExecutionFailureDetail',
    'Get-ExecutionBlockingApps',
    'Get-WinGetDownloader',
    'Set-WinGetDownloader',
    'Get-ExecutionVerification',
    'Write-ExecutionLog',
    'Invoke-WorkstationUpdate'
)
