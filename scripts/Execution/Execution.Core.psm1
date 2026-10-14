Set-StrictMode -Version Latest

# The only code in the toolkit allowed to change a workstation. Every rule here comes from
# docs/policies/update-execution-safety.md; change the policy first, then this module.

Import-Module (Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1')

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
    if ($command -cnotmatch '^[A-Za-z0-9 ._+@/;:-]+$') { throw "The command contains characters outside the allow-list: $command" }

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
        $arguments = if ($match.Groups['manager'].Value -eq 'pnpm add') { @('add', '-g', "$package@$version") } else { @('install', '-g', "$package@$version") }
        return & $call ($match.Groups['manager'].Value.Split(' ')[0]) $arguments
    }

    $exact = @{
        'wsl --update'                        = @('wsl', @('--update'))
        'flutter upgrade'                     = @('flutter', @('upgrade'))
        'flutter channel stable'              = @('flutter', @('channel', 'stable'))
        'flutter channel beta'                = @('flutter', @('channel', 'beta'))
        'flutter channel master'              = @('flutter', @('channel', 'master'))
        'pnpm self-update'                    = @('pnpm', @('self-update'))
        'python -m pip install --upgrade pip' = @('python', @('-m', 'pip', 'install', '--upgrade', 'pip'))
        'uv self update'                      = @('uv', @('self', 'update'))
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

function Invoke-ExecutionCall {
    <#
    .SYNOPSIS
    Runs one validated call; the default runner for Invoke-WorkstationUpdate.
    #>
    param([Parameter(Mandatory)][psobject]$Call)

    $result = Invoke-AuditCommand -Command $Call.filePath -Arguments $Call.arguments -TimeoutSeconds $script:ActionTimeoutSeconds -MaximumCaptureLength 1048576
    return [pscustomobject][ordered]@{
        exitCode = $result.ExitCode
        timedOut = [bool]$result.TimedOut
        found    = [bool]$result.Found
        output   = [string]$result.Captured
    }
}

function Write-ExecutionLog {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][psobject]$Log)

    $json = ($Log | ConvertTo-Json -Depth 20).Replace("`r`n", "`n")
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Invoke-WorkstationUpdate {
    <#
    .SYNOPSIS
    Previews, or with -Apply runs, selected plan actions one at a time with per-action confirmation.
    .PARAMETER Confirmer
    Asks the operator about one action and returns $true to run it. Tests replace it; production prompts.
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
        [Parameter(Mandatory)][string]$LogDirectory,
        [scriptblock]$Confirmer,
        [scriptblock]$Runner = { param($Call) Invoke-ExecutionCall -Call $Call },
        [scriptblock]$Elevated = { Test-ExecutionElevated },
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

    $directory = [IO.Path]::GetFullPath($LogDirectory)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $logPath = Join-Path $directory ($Now.ToString('yyyyMMdd-HHmmss') + $(if ($Apply) { '' } else { '-dry-run' }) + '.json')
    $log = [pscustomobject][ordered]@{
        startedAt  = $Now.ToString('o')
        mode       = $(if ($Apply) { 'apply' } else { 'dry-run' })
        planReport = $Plan.report.generatedAt
        policy     = $PolicyDigest
        actions    = @($selected | ForEach-Object {
                [pscustomobject][ordered]@{ order = $_.order; actionId = $_.actionId; title = $_.title; risk = $_.risk; command = $_.command; result = 'not-run'; reason = $null; exitCode = $null; startedAt = $null; finishedAt = $null; outputTail = $null }
            })
    }
    Write-ExecutionLog -Path $logPath -Log $log

    $isElevated = $null
    $stopped = $false
    for ($i = 0; $i -lt $selected.Count; $i++) {
        $item = $selected[$i]
        $entry = $log.actions[$i]
        if ($stopped) { break }

        if ($item.risk -eq 'high') { $entry.result = 'skipped'; $entry.reason = 'High-risk actions are always manual.'; continue }
        try { $call = ConvertTo-ExecutionCall -Action $item }
        catch { $entry.result = 'skipped'; $entry.reason = $_.Exception.Message; continue }

        if ($call.requiresElevation) {
            if ($null -eq $isElevated) { $isElevated = [bool](& $Elevated) }
            if (-not $isElevated) { $entry.result = 'skipped'; $entry.reason = 'Needs an elevated (administrator) shell; the executor never elevates itself.'; continue }
        }

        $display = "$($call.filePath) $($call.arguments -join ' ')"
        Write-Host ''
        Write-Host ("{0}. [{1}, {2}] {3}" -f $item.order, $item.risk, $(if ($item.reversible) { 'reversible' } else { 'not reversible' }), $item.title)
        if ($null -ne $item.currentVersion -or $null -ne $item.targetVersion) { Write-Host "   $($item.currentVersion) -> $($item.targetVersion)" }
        Write-Host "   Command: $display"
        if ($call.acceptsAgreements) { Write-Host '   Running it accepts the package and source agreements of this WinGet package.' }

        if (-not $Apply) { $entry.result = 'not-run'; $entry.reason = 'Dry run.'; continue }
        if (-not [bool](& $Confirmer $item $call)) { $entry.result = 'skipped'; $entry.reason = 'Declined by the operator.'; Write-ExecutionLog -Path $logPath -Log $log; continue }

        $entry.startedAt = [DateTimeOffset]::Now.ToString('o')
        $outcome = & $Runner $call
        $entry.finishedAt = [DateTimeOffset]::Now.ToString('o')
        $entry.exitCode = $outcome.exitCode
        $output = [string]$outcome.output
        $entry.outputTail = if ($output.Length -gt $script:OutputTailLength) { $output.Substring($output.Length - $script:OutputTailLength) } else { $output }

        if ($outcome.timedOut) { $entry.result = 'failed'; $entry.reason = "Timed out after $($script:ActionTimeoutSeconds) seconds." }
        elseif (-not $outcome.found) { $entry.result = 'failed'; $entry.reason = "Command '$($call.filePath)' was not found." }
        elseif ($outcome.exitCode -ne 0) { $entry.result = 'failed'; $entry.reason = "Exit code $($outcome.exitCode)." }
        else { $entry.result = 'succeeded' }

        Write-ExecutionLog -Path $logPath -Log $log
        if ($entry.result -eq 'failed') {
            Write-Host "   Failed: $($entry.reason) Stopping; later actions were not started."
            $stopped = $true
        }
        else {
            Write-Host '   Done.'
        }
    }

    Write-ExecutionLog -Path $logPath -Log $log
    return [pscustomobject][ordered]@{ logPath = $logPath; log = $log }
}

Export-ModuleMember -Function @(
    'ConvertTo-ExecutionCall',
    'Assert-ExecutablePlan',
    'Select-ExecutionAction',
    'Get-ExecutionFileDigest',
    'Invoke-WorkstationUpdate'
)
