Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comparison.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'PolicyEvaluation.Core.psm1')

$script:PlanSchemaVersion = '1.0.0'
$script:RiskRank = @{ low = 0; medium = 1; high = 2 }
$script:ActionIdPattern = '^[a-z]+(?:-[a-z]+)*:[0-9A-Za-z][0-9A-Za-z._+-]*$'

# How each policy deviation turns into an action. Command is a scriptblock over the finding, or $null
# when the operator must act (a migration, or a command that would need a user-specific path).
$script:PolicyActions = @{
    'windows.applicationManager'       = @{ kind = 'install'; risk = 'high'; reversible = $false; title = 'Install the Windows application manager' }
    'node.manager'                     = @{ kind = 'install'; risk = 'high'; reversible = $false; title = 'Migrate Node.js to the configured version manager' }
    'node.defaultTrack'                = @{ kind = 'upgrade'; risk = 'medium'; reversible = $false; title = 'Upgrade Node.js to its policy track' }
    'node.alsoInstallCurrent'          = @{ kind = 'install'; risk = 'low'; reversible = $true; title = 'Install the current Node.js release alongside LTS' }
    'node.projectVersionsMustBePinned' = @{ kind = 'configure'; risk = 'low'; reversible = $true; title = 'Pin the Node.js version in projects' }
    'javascript.primaryPackageManager' = @{ kind = 'install'; risk = 'low'; reversible = $true; title = 'Install pnpm'; command = { 'winget install --id pnpm.pnpm --exact' } }
    'javascript.globalPackageManager'  = @{ kind = 'cleanup'; risk = 'medium'; reversible = $true; title = 'Move global packages from npm to the policy package manager' }
    'javascript.projectDependencies'   = @{ kind = 'configure'; risk = 'low'; reversible = $true; title = 'Add a lockfile to projects' }
    'angular.globalCliTrack'           = @{ kind = 'upgrade'; risk = 'low'; reversible = $false; title = 'Upgrade the Angular CLI'; package = '@angular/cli' }
    'typescript.globalTrack'           = @{ kind = 'upgrade'; risk = 'low'; reversible = $false; title = 'Upgrade TypeScript'; package = 'typescript' }
    'prisma.globalTrack'               = @{ kind = 'upgrade'; risk = 'low'; reversible = $false; title = 'Upgrade the Prisma CLI'; package = 'prisma' }
    'flutter.channel'                  = @{ kind = 'configure'; risk = 'medium'; reversible = $true; title = 'Switch Flutter to its policy channel'; command = { param($Finding) "flutter channel $($Finding.expected)" } }
    'flutter.sdkTrack'                 = @{ kind = 'upgrade'; risk = 'low'; reversible = $false; title = 'Upgrade the Flutter SDK'; command = { 'flutter upgrade' } }
    'flutter.dartSource'               = @{ kind = 'configure'; risk = 'low'; reversible = $true; title = 'Use the Dart SDK bundled with Flutter' }
    'path.allowMissingEntries'         = @{ kind = 'cleanup'; risk = 'low'; reversible = $true; title = 'Remove missing PATH entries' }
    'path.allowDuplicateEntries'       = @{ kind = 'cleanup'; risk = 'low'; reversible = $true; title = 'Remove duplicate PATH entries' }
    'versioning.prereleasePolicy'      = @{ kind = 'upgrade'; risk = 'medium'; reversible = $false; title = 'Move a prerelease to a stable release' }
    'java.defaultTrack'                = @{ kind = 'upgrade'; risk = 'medium'; reversible = $false; title = 'Upgrade the Java runtime' }
    'android.preferAndroidHome'        = @{ kind = 'configure'; risk = 'low'; reversible = $true; title = 'Set ANDROID_HOME to the Android SDK folder' }
    'rust.manager'                     = @{ kind = 'install'; risk = 'high'; reversible = $false; title = 'Migrate Rust to rustup' }
}

function Get-PlanMajor {
    [CmdletBinding()]
    param([AllowNull()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    return ($Version -replace '^[^0-9]*', '').Split('.')[0]
}

function Get-PlanUpgradeRisk {
    <#
    .SYNOPSIS
    A major-version change can break callers, so it is medium risk; otherwise low.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Current, [AllowNull()][string]$Target)

    $from = Get-PlanMajor -Version $Current
    $to = Get-PlanMajor -Version $Target
    if ($null -ne $from -and $null -ne $to -and $from -ne $to) { return 'medium' }
    return 'low'
}

function New-PlanAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$SourceType,
        [AllowNull()][string]$PolicyKey,
        [AllowNull()][string]$ComponentId,
        [AllowNull()][string]$SubjectId,
        [Parameter(Mandatory)][string]$Title,
        [AllowNull()][string]$CurrentVersion,
        [AllowNull()][string]$TargetVersion,
        [AllowNull()][string]$Command,
        [Parameter(Mandatory)][string]$Risk,
        [Parameter(Mandatory)][bool]$Reversible,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][object[]]$Evidence
    )

    $nullIfEmpty = { param($Value) if ([string]::IsNullOrEmpty($Value)) { $null } else { $Value } }
    $references = @($Evidence | Where-Object { $null -ne $_ })

    return [pscustomobject][ordered]@{
        order          = 0
        actionId       = $ActionId
        kind           = $Kind
        source         = [pscustomobject][ordered]@{ type = $SourceType; policyKey = & $nullIfEmpty $PolicyKey }
        componentId    = & $nullIfEmpty $ComponentId
        subjectId      = & $nullIfEmpty $SubjectId
        title          = $Title
        currentVersion = & $nullIfEmpty $CurrentVersion
        targetVersion  = & $nullIfEmpty $TargetVersion
        command        = & $nullIfEmpty $Command
        risk           = $Risk
        reversible     = $Reversible
        message        = $Message
        evidence       = $references
    }
}

function Get-PlanFindingVersions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Finding)

    $observed = $Finding.observed
    $current = Get-ComparisonOptionalPropertyValue -InputObject $observed -Name 'installed'
    if ($current -isnot [string]) { $current = Get-ComparisonOptionalPropertyValue -InputObject $observed -Name 'version' }
    $target = $null
    foreach ($name in @('latestLts', 'latestStable', 'latest')) {
        $value = Get-ComparisonOptionalPropertyValue -InputObject $observed -Name $name
        if ($value -is [string]) { $target = $value; break }
    }
    return [pscustomobject]@{ current = $(if ($current -is [string]) { $current } else { $null }); target = $target }
}

function Get-PlanPolicyActions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Evaluation)

    $deviations = @($Evaluation.findings | Where-Object status -eq 'deviation')
    foreach ($group in @($deviations | Group-Object policyKey)) {
        $policyKey = [string]$group.Name
        $spec = if ($script:PolicyActions.ContainsKey($policyKey)) { $script:PolicyActions[$policyKey] } else {
            @{ kind = 'configure'; risk = 'medium'; reversible = $false; title = "Resolve the $policyKey deviation" }
        }

        # Project rules yield one finding per project; one action covers them all.
        $perProject = @($group.Group | Where-Object { [string]$_.subjectId -like 'project:*' })
        $batches = [System.Collections.Generic.List[object]]::new()
        if ($perProject.Count -gt 0) {
            $batches.Add(@($group.Group))
        }
        else {
            foreach ($item in @($group.Group)) { $batches.Add(@($item)) }
        }

        foreach ($batch in $batches) {
            $finding = $batch[0]
            $evidence = @($batch | ForEach-Object { $_.evidence } | Where-Object { $null -ne $_ })
            $versions = Get-PlanFindingVersions -Finding $finding
            $componentId = [string]$finding.componentId

            $command = $null
            if ($spec.ContainsKey('command')) {
                $command = [string](& $spec.command $finding)
            }
            elseif ($spec.ContainsKey('package') -and $null -ne $versions.target) {
                # Global JavaScript CLIs are installed with the policy's global package manager.
                $command = "pnpm add -g $($spec.package)@$($versions.target)"
            }

            $risk = $spec.risk
            if ($spec.kind -eq 'upgrade' -and $risk -eq 'low') {
                $risk = Get-PlanUpgradeRisk -Current $versions.current -Target $versions.target
            }

            $actionId = "policy:$policyKey"
            $title = $spec.title
            $message = $finding.message
            if ($perProject.Count -gt 0) {
                $title = "$title ($($batch.Count))"
                $message = "$($batch.Count) project(s): $($finding.message)"
            }
            elseif (@($group.Group).Count -gt 1 -and -not [string]::IsNullOrEmpty($componentId)) {
                $actionId = "policy:$policyKey.$componentId"
            }

            New-PlanAction -ActionId $actionId -Kind $spec.kind -SourceType policy -PolicyKey $policyKey `
                -ComponentId $(if ($perProject.Count -gt 0) { $null } else { $componentId }) -SubjectId $null `
                -Title $title -CurrentVersion $versions.current -TargetVersion $versions.target -Command $command `
                -Risk $risk -Reversible $spec.reversible -Message $message -Evidence $evidence
        }
    }
}

function Get-PlanWinGetActions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Report)

    $provider = @($Report.providers | Where-Object { $_.providerId -eq 'winget.baseline' }) | Select-Object -First 1
    if ($null -eq $provider) { return }
    $evidence = @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'evidence') | Where-Object { $null -ne $_ -and $_.evidenceId -eq 'winget.upgrades.normalized' } | Select-Object -First 1
    if ($null -eq $evidence) { return }

    $reference = [pscustomobject][ordered]@{ providerId = 'winget.baseline'; componentId = 'winget'; evidenceId = 'winget.upgrades.normalized' }
    foreach ($upgrade in @(Get-ComparisonOptionalPropertyValue -InputObject $evidence.attributes -Name 'upgrades')) {
        if ($null -eq $upgrade -or (Get-ComparisonOptionalPropertyValue -InputObject $upgrade -Name 'identityReliable') -ne $true) { continue }
        $packageId = [string]$upgrade.packageId
        $actionId = "winget-upgrade:$packageId"
        # ponytail: IDs outside the contract's charset are skipped rather than escaped; none seen in real reports.
        if ($actionId -notmatch $script:ActionIdPattern) { continue }

        $current = [string](Get-ComparisonOptionalPropertyValue -InputObject $upgrade -Name 'installedVersion')
        $target = [string](Get-ComparisonOptionalPropertyValue -InputObject $upgrade -Name 'availableVersion')
        $name = [string](Get-ComparisonOptionalPropertyValue -InputObject $upgrade -Name 'name')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $packageId }

        New-PlanAction -ActionId $actionId -Kind upgrade -SourceType winget -PolicyKey $null -ComponentId $null `
            -SubjectId "winget:$packageId" -Title "Upgrade $name" -CurrentVersion $current -TargetVersion $target `
            -Command "winget upgrade --id $packageId --exact" -Risk (Get-PlanUpgradeRisk -Current $current -Target $target) `
            -Reversible $false -Message 'WinGet reports a newer version.' -Evidence @($reference)
    }
}

function New-WorkstationUpdatePlan {
    <#
    .SYNOPSIS
    Builds the ordered, read-only update plan for one audit report. Pure: runs nothing, changes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Report,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Policy,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$PolicyDigest
    )

    $evaluation = New-WorkstationPolicyEvaluation -Report $Report -Policy $Policy -PolicyDigest $PolicyDigest

    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($action in @(Get-PlanPolicyActions -Evaluation $evaluation) + @(Get-PlanWinGetActions -Report $Report)) {
        if ($null -ne $action) { $actions.Add($action) }
    }

    # Ordinal order so PowerShell and the Python contract validator agree.
    $actions.Sort([Comparison[object]] {
            param($a, $b)
            $byRisk = $script:RiskRank[$a.risk].CompareTo($script:RiskRank[$b.risk])
            if ($byRisk -ne 0) { return $byRisk }
            return [string]::CompareOrdinal($a.actionId, $b.actionId)
        })
    $items = $actions.ToArray()
    for ($i = 0; $i -lt $items.Count; $i++) { $items[$i].order = $i + 1 }

    $count = { param($Filter) @($items | Where-Object $Filter).Count }

    return [pscustomobject][ordered]@{
        schemaVersion    = $script:PlanSchemaVersion
        auditSchemaMajor = 1
        policy           = $evaluation.policy
        report           = $evaluation.report
        summary          = [pscustomobject][ordered]@{
            actionCount     = $items.Count
            lowRiskCount    = & $count { $_.risk -eq 'low' }
            mediumRiskCount = & $count { $_.risk -eq 'medium' }
            highRiskCount   = & $count { $_.risk -eq 'high' }
            reversibleCount = & $count { $_.reversible }
            manualCount     = & $count { $null -eq $_.command }
        }
        actions          = @($items)
    }
}

function ConvertTo-WorkstationUpdatePlanText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()][psobject]$Plan)

    $s = $Plan.summary
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Workstation update plan: $($s.actionCount) action(s) (low $($s.lowRiskCount), medium $($s.mediumRiskCount), high $($s.highRiskCount); manual $($s.manualCount))")
    $lines.Add("Host: $($Plan.report.host.name) | report $($Plan.report.generatedAt) | tool $($Plan.report.audit.toolVersion)")
    $lines.Add('Nothing has been run. Review each action before applying it.')

    foreach ($action in $Plan.actions) {
        $lines.Add('')
        $versions = if ($null -ne $action.currentVersion -or $null -ne $action.targetVersion) { " ($($action.currentVersion) -> $($action.targetVersion))" } else { '' }
        $undo = if ($action.reversible) { 'reversible' } else { 'not reversible' }
        $lines.Add("$($action.order). [$($action.risk), $undo] $($action.title)$versions")
        $lines.Add("   $($action.message)")
        $lines.Add($(if ($null -ne $action.command) { "   Command: $($action.command)" } else { '   Manual: see the audit report for details.' }))
    }

    return (($lines -join [string][char]10) + [string][char]10)
}

function Write-WorkstationUpdatePlanOutputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Plan,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory
    )

    $directory = [IO.Path]::GetFullPath($OutputDirectory)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $structuredPath = Join-Path $directory 'update-plan.json'
    $humanReadablePath = Join-Path $directory 'update-plan.txt'

    $json = ConvertTo-WorkstationOutputJson -InputObject $Plan
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($structuredPath, $json, $utf8NoBom)
    [IO.File]::WriteAllText($humanReadablePath, (ConvertTo-WorkstationUpdatePlanText -Plan $Plan), $utf8NoBom)

    return [pscustomobject][ordered]@{
        structuredPath    = $structuredPath
        humanReadablePath = $humanReadablePath
    }
}

Export-ModuleMember -Function @(
    'New-WorkstationUpdatePlan',
    'ConvertTo-WorkstationUpdatePlanText',
    'Write-WorkstationUpdatePlanOutputs'
)
