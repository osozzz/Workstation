Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comparison.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'PolicyEvaluation.Core.psm1')

$script:PlanSchemaVersion = '1.1.0'
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
    'python.windowsManager'            = @{ kind = 'install'; risk = 'low'; reversible = $true; title = 'Install the Python Install Manager'; command = { 'winget install --id Python.PythonInstallManager --exact' } }
    'python.defaultTrack'              = @{ kind = 'upgrade'; risk = 'medium'; reversible = $false; title = 'Upgrade Python to its policy track' }
    'dotnet.defaultTrack'              = @{ kind = 'upgrade'; risk = 'medium'; reversible = $false; title = 'Upgrade the .NET SDK to its policy track' }
    'rust.defaultTrack'                = @{ kind = 'upgrade'; risk = 'low'; reversible = $false; title = 'Upgrade the stable Rust toolchain'; command = { 'rustup update stable' } }
    'go.defaultTrack'                  = @{ kind = 'upgrade'; risk = 'medium'; reversible = $false; title = 'Upgrade Go to its policy track' }
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

# WinGet inventory display names of runtimes whose upgrades are manual; used to tell the operator
# which installer owns the installation.
$script:InstallerDisplayNames = @{
    'node'   = 'Node.js'
    'java'   = 'Java(TM) SE Development Kit'
    'python' = 'Python '
}

function Get-PlanInstallerNote {
    <#
    .SYNOPSIS
    Says whether WinGet manages a runtime, from the WinGet inventory; $null when that cannot be told.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Report,
        [AllowNull()][string]$ComponentId,
        [AllowNull()][string]$Version
    )

    if ([string]::IsNullOrEmpty($ComponentId) -or [string]::IsNullOrEmpty($Version) -or -not $script:InstallerDisplayNames.ContainsKey($ComponentId)) { return $null }
    $provider = @($Report.providers | Where-Object { $_.providerId -eq 'winget.baseline' }) | Select-Object -First 1
    if ($null -eq $provider) { return $null }
    $inventory = @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'evidence') | Where-Object { $null -ne $_ -and $_.evidenceId -eq 'winget.inventory.normalized' } | Select-Object -First 1
    if ($null -eq $inventory) { return $null }

    $prefix = $script:InstallerDisplayNames[$ComponentId]
    $package = @(Get-ComparisonOptionalPropertyValue -InputObject $inventory.attributes -Name 'packages') | Where-Object {
        $null -ne $_ -and ([string]$_.name).StartsWith($prefix, [StringComparison]::Ordinal) -and ([string]$_.installedVersion).StartsWith($Version, [StringComparison]::Ordinal)
    } | Sort-Object { if ([string]$_.source -eq 'winget') { 0 } else { 1 } } | Select-Object -First 1

    if ($null -eq $package) { return $null }
    if ([string]$package.source -eq 'winget') {
        return "WinGet package $($package.packageId) manages this installation; apply its WinGet upgrade when one is listed."
    }
    return 'This installation was not made with WinGet (vendor installer), so WinGet cannot upgrade it; use the vendor installer or the version manager the policy names.'
}

function Get-PlanPolicyActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Evaluation,
        [Parameter(Mandatory)][psobject]$Report
    )

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

            if ($null -eq $command -and $spec.kind -eq 'upgrade') {
                $note = Get-PlanInstallerNote -Report $Report -ComponentId $componentId -Version $versions.current
                if ($null -ne $note) { $message = "$message $note" }
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

        # Microsoft Store IDs (for example XP89DCGQ3K6VLD) are only unambiguous within the msstore source.
        $command = "winget upgrade --id $packageId --exact"
        $message = 'WinGet reports a newer version.'
        if ([string](Get-ComparisonOptionalPropertyValue -InputObject $upgrade -Name 'source') -eq 'msstore') {
            $command += ' --source msstore'
            $name += ' (Microsoft Store)'
            $message = 'The Microsoft Store reports a newer version through WinGet.'
        }

        New-PlanAction -ActionId $actionId -Kind upgrade -SourceType winget -PolicyKey $null -ComponentId $null `
            -SubjectId "winget:$packageId" -Title "Upgrade $name" -CurrentVersion $current -TargetVersion $target `
            -Command $command -Risk (Get-PlanUpgradeRisk -Current $current -Target $target) `
            -Reversible $false -Message $message -Evidence @($reference)
    }
}

function Get-PlanChocolateyActions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Report)

    $provider = @($Report.providers | Where-Object { $_.providerId -eq 'chocolatey.baseline' }) | Select-Object -First 1
    if ($null -eq $provider) { return }
    $evidence = @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'evidence') | Where-Object { $null -ne $_ -and $_.evidenceId -eq 'chocolatey.outdated.normalized' } | Select-Object -First 1
    if ($null -eq $evidence) { return }

    $reference = [pscustomobject][ordered]@{ providerId = 'chocolatey.baseline'; componentId = 'chocolatey'; evidenceId = 'chocolatey.outdated.normalized' }
    foreach ($upgrade in @(Get-ComparisonOptionalPropertyValue -InputObject $evidence.attributes -Name 'upgrades')) {
        # A pinned package is held on purpose by the operator.
        if ($null -eq $upgrade -or (Get-ComparisonOptionalPropertyValue -InputObject $upgrade -Name 'pinned') -eq $true) { continue }
        $packageId = [string]$upgrade.packageId
        $actionId = "choco-upgrade:$packageId"
        if ($actionId -notmatch $script:ActionIdPattern) { continue }

        $current = [string]$upgrade.installedVersion
        $target = [string]$upgrade.availableVersion
        $message = 'Chocolatey reports a newer version. Chocolatey upgrades need an elevated (administrator) shell.'
        if ($packageId -match '^python3?\d*$') {
            # Chocolatey's Python installer puts its folder first in the machine PATH, which can change
            # the active python (3.13 replaced 3.14 on PC #1).
            $message += ' Its installer moves its Python folder to the front of the machine PATH, which can change which python is active.'
        }
        New-PlanAction -ActionId $actionId -Kind upgrade -SourceType chocolatey -PolicyKey $null -ComponentId $null `
            -SubjectId "choco:$packageId" -Title "Upgrade $packageId (Chocolatey)" -CurrentVersion $current -TargetVersion $target `
            -Command "choco upgrade $packageId -y" -Risk (Get-PlanUpgradeRisk -Current $current -Target $target) `
            -Reversible $false -Message $message -Evidence @($reference)
    }
}

function Get-PlanWslActions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Report)

    $provider = @($Report.providers | Where-Object { $_.providerId -eq 'wsl.baseline' }) | Select-Object -First 1
    if ($null -eq $provider) { return }
    $wsl = @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'components') | Where-Object { $null -ne $_ -and $_.componentId -eq 'wsl' -and $_.state -in @('present', 'partial') } | Select-Object -First 1
    if ($null -eq $wsl) { return }

    $current = [string](Get-ComparisonOptionalPropertyValue -InputObject (Get-ComparisonOptionalPropertyValue -InputObject $wsl -Name 'activeVersion') -Name 'normalized')
    $intelligence = Get-ComparisonOptionalPropertyValue -InputObject $wsl -Name 'versionIntelligence'
    $target = [string](Get-ComparisonOptionalPropertyValue -InputObject (Get-ComparisonOptionalPropertyValue -InputObject $intelligence -Name 'latestStable') -Name 'normalized')
    if ([string]::IsNullOrWhiteSpace($current) -or [string]::IsNullOrWhiteSpace($target) -or (Compare-PolicyVersion -Left $current -Right $target) -ge 0) { return }

    New-PlanAction -ActionId 'wsl-update:wsl' -Kind upgrade -SourceType wsl -PolicyKey $null -ComponentId 'wsl' -SubjectId $null `
        -Title 'Update the Windows Subsystem for Linux' -CurrentVersion $current -TargetVersion $target -Command 'wsl --update' `
        -Risk (Get-PlanUpgradeRisk -Current $current -Target $target) -Reversible $false `
        -Message 'A newer WSL release is available. Running distributions are shut down while WSL updates.' `
        -Evidence @([pscustomobject][ordered]@{ providerId = 'wsl.baseline'; componentId = 'wsl'; evidenceId = $null })
}

function Get-PlanNpmRegistryActions {
    <#
    .SYNOPSIS
    pnpm itself and global CLIs without a policy track, from the npm-registry evidence of javascript.toolchain.
    npm is not planned: the policy treats it as the copy bundled with Node.js, updated with Node.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Report)

    $provider = @($Report.providers | Where-Object { $_.providerId -eq 'javascript.toolchain' }) | Select-Object -First 1
    if ($null -eq $provider) { return }

    foreach ($item in @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'evidence')) {
        if ($null -eq $item) { continue }
        $attributes = Get-ComparisonOptionalPropertyValue -InputObject $item -Name 'attributes'
        if ((Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name 'updateAvailable') -ne $true) { continue }
        $current = [string](Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name 'installedVersion')
        $target = [string](Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name 'latestStable')
        $reference = [pscustomobject][ordered]@{ providerId = 'javascript.toolchain'; componentId = $null; evidenceId = [string]$item.evidenceId }

        if ($item.evidenceId -eq 'javascript.version-intelligence.pnpm') {
            $reference.componentId = 'pnpm'
            New-PlanAction -ActionId 'pnpm-self-update:pnpm' -Kind upgrade -SourceType npm-registry -PolicyKey $null -ComponentId 'pnpm' -SubjectId 'npm:pnpm' `
                -Title 'Upgrade pnpm' -CurrentVersion $current -TargetVersion $target -Command 'pnpm self-update' `
                -Risk (Get-PlanUpgradeRisk -Current $current -Target $target) -Reversible $false -Message 'The npm registry reports a newer pnpm.' -Evidence @($reference)
            continue
        }

        if ([string]$item.evidenceId -notlike 'javascript.version-intelligence.global.*') { continue }
        $packageName = [string](Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name 'packageName')
        $manager = [string](Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name 'manager')
        $componentId = [string](Get-ComparisonOptionalPropertyValue -InputObject $attributes -Name 'componentId')
        if ($packageName -notmatch '^[a-z0-9][a-z0-9._-]*$' -or [string]::IsNullOrWhiteSpace($target)) { continue }

        # Upgrade with the manager that installed the package, so it is not duplicated under the other one.
        $command = switch ($manager) {
            'pnpm' { "pnpm add -g $packageName@$target" }
            'npm' { "npm install -g $packageName@$target" }
            default { $null }
        }
        $reference.componentId = $(if ([string]::IsNullOrEmpty($componentId)) { $null } else { $componentId })
        New-PlanAction -ActionId "npm-global-upgrade:$packageName" -Kind upgrade -SourceType npm-registry -PolicyKey $null -ComponentId $componentId -SubjectId "npm:$packageName" `
            -Title "Upgrade the $packageName CLI" -CurrentVersion $current -TargetVersion $target -Command $command `
            -Risk (Get-PlanUpgradeRisk -Current $current -Target $target) -Reversible $false `
            -Message "The npm registry reports a newer $packageName, installed globally with $(if ($manager) { $manager } else { 'an unknown package manager' })." -Evidence @($reference)
    }
}

# Developer tools updated by their own commands; versions come from each tool's latest-version source.
$script:ToolActions = @(
    @{ ProviderId = 'python.ecosystem'; ComponentId = 'pip'; Title = 'Upgrade pip for the active Python'; Command = 'python -m pip install pip=={target}' }
    @{ ProviderId = 'python.ecosystem'; ComponentId = 'uv'; Title = 'Upgrade uv'; Command = 'uv self update'; RequiresEvidence = 'python.uv.install-kind' }
    @{ ProviderId = 'mobile.flutter-android'; ComponentId = 'adb'; Title = 'Upgrade Android SDK platform-tools'; Command = 'sdkmanager platform-tools' }
    # sdkmanager cannot replace the cmdline-tools it runs from (its own jars are locked); Android Studio can.
    @{ ProviderId = 'mobile.flutter-android'; ComponentId = 'sdkmanager'; Title = 'Upgrade Android SDK command-line tools'; Command = $null; Note = 'sdkmanager cannot update the command-line tools it runs from; update them in Android Studio > SDK Manager > SDK Tools.' }
)

function Get-PlanToolActions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Report)

    foreach ($spec in $script:ToolActions) {
        $provider = @($Report.providers | Where-Object { $_.providerId -eq $spec.ProviderId }) | Select-Object -First 1
        if ($null -eq $provider) { continue }
        $component = @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'components') | Where-Object { $null -ne $_ -and $_.componentId -eq $spec.ComponentId -and $_.state -in @('present', 'partial') } | Select-Object -First 1
        if ($null -eq $component) { continue }

        $current = [string](Get-ComparisonOptionalPropertyValue -InputObject (Get-ComparisonOptionalPropertyValue -InputObject $component -Name 'activeVersion') -Name 'normalized')
        $target = [string](Get-ComparisonOptionalPropertyValue -InputObject (Get-ComparisonOptionalPropertyValue -InputObject (Get-ComparisonOptionalPropertyValue -InputObject $component -Name 'versionIntelligence') -Name 'latestStable') -Name 'normalized')
        # A numeric suffix is a build number (adb 37.0.0-14910828), not a prerelease.
        $comparable = $current -replace '-\d+$', ''
        if ([string]::IsNullOrWhiteSpace($comparable) -or [string]::IsNullOrWhiteSpace($target) -or (Compare-PolicyVersion -Left $comparable -Right $target) -ge 0) { continue }

        # Pin the version the plan reviewed; an unpinned upgrade resolves against whatever index the
        # interpreter sees at run time (it downgraded pip 26.2.1 to 25.3 on PC #1).
        $command = if ($null -ne $spec.Command) { $spec.Command.Replace('{target}', $target) } else { $null }
        $message = "A newer $($spec.ComponentId) release is available."
        if ($spec.ContainsKey('Note')) { $message = "$message $($spec.Note)" }
        if ($spec.ContainsKey('RequiresEvidence')) {
            $kind = @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'evidence') | Where-Object { $null -ne $_ -and $_.evidenceId -eq $spec.RequiresEvidence } | Select-Object -First 1
            if ($null -eq $kind -or (Get-ComparisonOptionalPropertyValue -InputObject $kind.attributes -Name 'selfUpdateSupported') -ne $true) {
                $command = $null
                $message = "$message It was not installed with its standalone installer, so update it with the package manager that installed it."
            }
        }

        New-PlanAction -ActionId "tool-upgrade:$($spec.ComponentId)" -Kind upgrade -SourceType toolchain -PolicyKey $null -ComponentId $spec.ComponentId -SubjectId $null `
            -Title $spec.Title -CurrentVersion $current -TargetVersion $target -Command $command `
            -Risk (Get-PlanUpgradeRisk -Current $comparable -Target $target) -Reversible $false -Message $message `
            -Evidence @([pscustomobject][ordered]@{ providerId = $spec.ProviderId; componentId = $spec.ComponentId; evidenceId = $null })
    }
}

# Tools that more than one package manager can own. Each manager's package IDs are matched by
# anchored patterns so unrelated packages never count.
$script:SharedTools = @(
    @{ Id = 'python'; Name = 'Python'; Chocolatey = '^python3?\d*$'; WinGet = '^Python\.Python\.\d'; Arp = 'pymanager-pythoncore' }
    @{ Id = 'visual-studio-build-tools-2019'; Name = 'Visual Studio Build Tools 2019'; Chocolatey = '^visualstudio2019buildtools$'; WinGet = '^Microsoft\.VisualStudio\.2019\.BuildTools$' }
    @{ Id = 'visual-studio-build-tools-2022'; Name = 'Visual Studio Build Tools 2022'; Chocolatey = '^visualstudio2022buildtools$'; WinGet = '^Microsoft\.VisualStudio\.2022\.BuildTools$' }
    @{ Id = 'vcredist-2015-plus'; Name = 'Visual C++ Redistributable 2015+'; Chocolatey = '^vcredist(140|2015)$'; WinGet = '^Microsoft\.VCRedist\.2015\+\.' }
    @{ Id = 'git'; Name = 'Git'; Chocolatey = '^git(\.install)?$'; WinGet = '^Git\.Git$' }
    @{ Id = 'nodejs'; Name = 'Node.js'; Chocolatey = '^nodejs(-lts|\.install)?$'; WinGet = '^OpenJS\.NodeJS' }
    @{ Id = 'vscode'; Name = 'Visual Studio Code'; Chocolatey = '^vscode(\.install)?$'; WinGet = '^Microsoft\.VisualStudioCode$' }
    @{ Id = 'jdk'; Name = 'Java Development Kit'; Chocolatey = '^(openjdk|temurin|oraclejdk|jdk)\d*$'; WinGet = '^(Oracle\.JDK|EclipseAdoptium\.Temurin|Microsoft\.OpenJDK)\.' }
)

function Get-PlanInventoryPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Report,
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    $provider = @($Report.providers | Where-Object { $_.providerId -eq $ProviderId }) | Select-Object -First 1
    if ($null -eq $provider) { return @() }
    $inventory = @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'evidence') | Where-Object { $null -ne $_ -and $_.evidenceId -eq $EvidenceId } | Select-Object -First 1
    if ($null -eq $inventory) { return @() }
    return @(Get-ComparisonOptionalPropertyValue -InputObject $inventory.attributes -Name 'packages' | Where-Object { $null -ne $_ })
}

function Get-PlanConsolidationActions {
    <#
    .SYNOPSIS
    One manual action per tool that several package managers own; upgrading it through each of them conflicts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Report,
        [AllowNull()][string]$PreferredManager,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$DeferredChocolateyIds
    )

    $chocolatey = Get-PlanInventoryPackages -Report $Report -ProviderId 'chocolatey.baseline' -EvidenceId 'chocolatey.inventory.normalized'
    $winget = Get-PlanInventoryPackages -Report $Report -ProviderId 'winget.baseline' -EvidenceId 'winget.inventory.normalized'

    foreach ($tool in $script:SharedTools) {
        $owners = [System.Collections.Generic.List[string]]::new()
        $evidence = [System.Collections.Generic.List[object]]::new()

        $chocoIds = @($chocolatey | ForEach-Object { [string]$_.packageId } | Where-Object { $_ -match $tool.Chocolatey } | Sort-Object -Unique)
        if ($chocoIds.Count -gt 0) {
            $owners.Add("Chocolatey ($($chocoIds -join ', '))")
            $evidence.Add([pscustomobject][ordered]@{ providerId = 'chocolatey.baseline'; componentId = 'chocolatey'; evidenceId = 'chocolatey.inventory.normalized' })
        }

        $wingetIds = @($winget | Where-Object { [string]$_.source -eq 'winget' } | ForEach-Object { [string]$_.packageId } | Where-Object { $_ -match $tool.WinGet } | Sort-Object -Unique)
        $managedByInstallManager = $tool.ContainsKey('Arp') -and @($winget | Where-Object { ([string]$_.packageId).Contains($tool.Arp) }).Count -gt 0
        if ($wingetIds.Count -gt 0) { $owners.Add("WinGet ($($wingetIds -join ', '))") }
        if ($managedByInstallManager) { $owners.Add('Python Install Manager') }
        if ($wingetIds.Count -gt 0 -or $managedByInstallManager) {
            $evidence.Add([pscustomobject][ordered]@{ providerId = 'winget.baseline'; componentId = 'winget'; evidenceId = 'winget.inventory.normalized' })
        }

        if ($owners.Count -lt 2) { continue }
        $message = "$($tool.Name) is managed by $($owners -join ' and '). Upgrading it through more than one of them can install side-by-side copies; apply only one manager's upgrade and remove the package from the others."
        # The policy names WinGet as the application manager, so the plan upgrades shared tools
        # through WinGet only and leaves the Chocolatey upgrades out.
        $deferred = @($chocoIds)
        if ($tool.Id -eq 'python') {
            # Python is side-by-side per minor version: defer python3NN only when WinGet manages 3.NN;
            # the unversioned python/python3 packages follow the newest Python and are always deferred.
            $wingetMinors = @($wingetIds | ForEach-Object { if ($_ -match '^Python\.Python\.3\.(\d+)$') { $Matches[1] } })
            $deferred = @($chocoIds | Where-Object { $_ -notmatch '^python3(\d+)$' -or ($_ -match '^python3(\d+)$' -and $Matches[1] -in $wingetMinors) })
        }
        if ($PreferredManager -eq 'winget' -and $wingetIds.Count -gt 0 -and $deferred.Count -gt 0) {
            foreach ($id in $deferred) { [void]$DeferredChocolateyIds.Add($id) }
            $message = "$($tool.Name) is managed by $($owners -join ' and '). WinGet is the policy's application manager, so this plan upgrades it through WinGet and leaves out the Chocolatey upgrades of $($deferred -join ', '). To finish consolidating, remove those from Chocolatey without uninstalling the program: choco uninstall $($deferred -join ' ') -n."
        }
        New-PlanAction -ActionId "consolidate-managers:$($tool.Id)" -Kind cleanup -SourceType consolidation -PolicyKey $null -ComponentId $null -SubjectId $null `
            -Title "Manage $($tool.Name) with a single package manager" -CurrentVersion $null -TargetVersion $null -Command $null `
            -Risk medium -Reversible $false -Message $message -Evidence $evidence.ToArray()
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

    $deferredChocolatey = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $preferredManager = [string](Get-ComparisonOptionalPropertyValue -InputObject (Get-ComparisonOptionalPropertyValue -InputObject $Policy -Name 'windows') -Name 'applicationManager')
    $consolidation = @(Get-PlanConsolidationActions -Report $Report -PreferredManager $preferredManager -DeferredChocolateyIds $deferredChocolatey)

    $candidates = @(Get-PlanPolicyActions -Evaluation $evaluation -Report $Report) + @(Get-PlanWinGetActions -Report $Report) + @(Get-PlanChocolateyActions -Report $Report) +
        @(Get-PlanWslActions -Report $Report) + @(Get-PlanNpmRegistryActions -Report $Report) + @(Get-PlanToolActions -Report $Report) + $consolidation
    $hasWslUpdate = @($candidates | Where-Object { $null -ne $_ -and $_.actionId -eq 'wsl-update:wsl' }).Count -gt 0

    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($action in $candidates) {
        if ($null -eq $action) { continue }
        # Shared tools are upgraded through the policy's application manager only.
        if ($action.source.type -eq 'chocolatey' -and $deferredChocolatey.Contains(([string]$action.actionId).Substring('choco-upgrade:'.Length))) { continue }
        # wsl --update installs the latest release; WinGet's Microsoft.WSL package lags and would conflict.
        if ($hasWslUpdate -and $action.actionId -eq 'winget-upgrade:Microsoft.WSL') { continue }
        $actions.Add($action)
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
