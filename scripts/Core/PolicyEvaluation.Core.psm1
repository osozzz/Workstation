Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Comparison.Core.psm1')

$script:EvaluationSchemaVersion = '1.0.0'
$script:PrereleasePattern = '(?i)-(alpha|beta|rc|preview|dev|pre|nightly|canary|next)\b'

function Get-PolicyValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    $value = $InputObject
    foreach ($name in $Path.Split('.')) {
        $value = Get-ComparisonOptionalPropertyValue -InputObject $value -Name $name
    }
    return $value
}

function ConvertTo-PolicyRuleId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PolicyKey)

    $kebab = [regex]::Replace($PolicyKey, '([a-z0-9])([A-Z])', '$1-$2').Replace('.', '-')
    return $kebab.ToLowerInvariant()
}

function Get-PolicyLeafKeys {
    <#
    .SYNOPSIS
    Flattens the policy document into dotted keys (schemaVersion excluded).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()][psobject]$Policy)

    $keys = foreach ($section in $Policy.PSObject.Properties) {
        if ($section.Name -eq 'schemaVersion') {
            continue
        }
        foreach ($setting in $section.Value.PSObject.Properties) {
            "$($section.Name).$($setting.Name)"
        }
    }
    return @($keys)
}

function Compare-PolicyVersion {
    <#
    .SYNOPSIS
    Returns -1, 0 or 1. Numeric parts compare numerically; a release sorts after its prereleases.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $parse = {
        param($Text)
        $parts = $Text.Split(@('-'), 2, [StringSplitOptions]::None)
        $core = $parts[0]
        $pre = if ($parts.Count -gt 1) { $parts[1] } else { $null }
        $numbers = @($core.Split('.') | ForEach-Object { $n = 0; [void][int]::TryParse(($_ -replace '\D.*$', ''), [ref]$n); $n })
        , @($numbers, $pre)
    }

    $l = & $parse $Left
    $r = & $parse $Right
    $length = [Math]::Max($l[0].Count, $r[0].Count)
    for ($i = 0; $i -lt $length; $i++) {
        $a = if ($i -lt $l[0].Count) { $l[0][$i] } else { 0 }
        $b = if ($i -lt $r[0].Count) { $r[0][$i] } else { 0 }
        if ($a -ne $b) {
            return [Math]::Sign($a - $b)
        }
    }

    if ($l[1] -eq $r[1]) { return 0 }
    if ($null -eq $l[1]) { return 1 }
    if ($null -eq $r[1]) { return -1 }
    # ponytail: prerelease labels compare ordinally (rc.9 > rc.10); split numeric identifiers if that ever matters.
    return [Math]::Sign([string]::CompareOrdinal($l[1], $r[1]))
}

function New-PolicyEvidenceReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderId,
        [AllowNull()][string]$ComponentId,
        [AllowNull()][string]$EvidenceId
    )

    return [pscustomobject][ordered]@{
        providerId  = $ProviderId
        componentId = if ([string]::IsNullOrEmpty($ComponentId)) { $null } else { $ComponentId }
        evidenceId  = if ([string]::IsNullOrEmpty($EvidenceId)) { $null } else { $EvidenceId }
    }
}

function New-PolicyFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PolicyKey,
        [Parameter(Mandatory)][ValidateSet('compliant', 'deviation', 'unknown', 'not-evaluable')][string]$Status,
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Observed,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][string]$ComponentId,
        [AllowNull()][string]$SubjectId,
        [AllowEmptyCollection()][object[]]$Evidence = @()
    )

    # Assigned from a variable: an if-expression would unroll the array into a scalar or $null.
    $references = @()
    if ($Status -ne 'not-evaluable') {
        $references = @($Evidence | Where-Object { $null -ne $_ })
    }

    return [pscustomobject][ordered]@{
        ruleId      = ConvertTo-PolicyRuleId -PolicyKey $PolicyKey
        policyKey   = $PolicyKey
        status      = $Status
        componentId = if ([string]::IsNullOrEmpty($ComponentId)) { $null } else { $ComponentId }
        subjectId   = if ([string]::IsNullOrEmpty($SubjectId)) { $null } else { $SubjectId }
        expected    = $Expected
        observed    = if ($Status -eq 'not-evaluable') { $null } else { $Observed }
        message     = $Message
        evidence    = $references
    }
}

function New-PolicyEvaluationContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()][psobject]$Report)

    $providers = @{}
    $components = @{}
    $evidence = @{}

    foreach ($provider in @(Get-ComparisonOptionalPropertyValue -InputObject $Report -Name 'providers')) {
        if ($null -eq $provider) { continue }
        $providerId = [string]$provider.providerId
        $providers[$providerId] = $provider

        foreach ($component in @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'components')) {
            if ($null -ne $component -and -not $components.ContainsKey([string]$component.componentId)) {
                $components[[string]$component.componentId] = [pscustomobject]@{ providerId = $providerId; component = $component }
            }
        }

        foreach ($item in @(Get-ComparisonOptionalPropertyValue -InputObject $provider -Name 'evidence')) {
            if ($null -ne $item -and -not $evidence.ContainsKey([string]$item.evidenceId)) {
                $evidence[[string]$item.evidenceId] = [pscustomobject]@{ providerId = $providerId; evidence = $item }
            }
        }
    }

    return [pscustomobject]@{
        providers  = $providers
        components = $components
        evidence   = $evidence
        projects   = @(Get-PolicyJavaScriptProjects -Evidence $evidence)
    }
}

function Get-PolicyJavaScriptProjects {
    <#
    .SYNOPSIS
    JavaScript projects with the same path-safe identity the comparison uses; ambiguous identities are skipped.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Evidence)

    if (-not $Evidence.ContainsKey('projects.local.discovery')) {
        return @()
    }

    $candidates = @(Get-PolicyValue -InputObject $Evidence['projects.local.discovery'].evidence -Path 'attributes.candidates')
    $identities = @{}
    $counts = @{}
    for ($index = 0; $index -lt $candidates.Count; $index++) {
        if ($null -eq $candidates[$index]) { continue }
        $name = Get-ComparisonProjectLeafName -Path ([string](Get-ComparisonOptionalPropertyValue -InputObject $candidates[$index] -Name 'path')) -ProjectIndex $index
        $relativePath = ConvertTo-ComparisonProjectRelativePath -RelativePath ([string](Get-ComparisonOptionalPropertyValue -InputObject $candidates[$index] -Name 'relativePath'))
        $identities[$index] = [pscustomobject][ordered]@{ name = $name; relativePath = $relativePath }
        $counts["$name|$relativePath"] = 1 + [int]$counts["$name|$relativePath"]
    }

    $projects = foreach ($key in @($Evidence.Keys | Where-Object { $_ -like 'projects.javascript-web.project-*' })) {
        $project = Get-PolicyValue -InputObject $Evidence[$key].evidence -Path 'attributes.project'
        $index = Get-ComparisonOptionalPropertyValue -InputObject $project -Name 'projectIndex'
        if ($null -eq $index -or -not $identities.ContainsKey([int]$index)) { continue }
        $identity = $identities[[int]$index]
        if ($counts["$($identity.name)|$($identity.relativePath)"] -gt 1) { continue }

        [pscustomobject]@{
            subjectId  = 'project:' + (Get-ComparisonValueHash -CanonicalJson (ConvertTo-ComparisonCanonicalJson -Value $identity))
            evidenceId = [string]$key
            project    = $project
        }
    }
    return @($projects)
}

function Get-PolicyComponent {
    <#
    .SYNOPSIS
    The component entry when the report shows it installed; $null when absent or missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$ComponentId
    )

    if (-not $Context.components.ContainsKey($ComponentId)) { return $null }
    $entry = $Context.components[$ComponentId]
    if ([string]$entry.component.state -notin @('present', 'partial')) { return $null }
    return $entry
}

function Get-PolicyComponentReference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Entry)

    return New-PolicyEvidenceReference -ProviderId $Entry.providerId -ComponentId ([string]$Entry.component.componentId) -EvidenceId $null
}

function Get-PolicyEvidenceReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    if (-not $Context.evidence.ContainsKey($EvidenceId)) { return $null }
    return New-PolicyEvidenceReference -ProviderId $Context.evidence[$EvidenceId].providerId -ComponentId $null -EvidenceId $EvidenceId
}

function Get-PolicyActiveVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Component)

    $version = [string](Get-PolicyValue -InputObject $Component -Path 'activeVersion.normalized')
    if ([string]::IsNullOrWhiteSpace($version)) { return $null }
    return $version
}

function Invoke-PolicyPresenceRule {
    <#
    .SYNOPSIS
    Compliant when the preferred component is installed; skipped when the governed tool is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$PolicyKey,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$GovernedComponentId,
        [Parameter(Mandatory)][string]$PreferredComponentId
    )

    $governed = Get-PolicyComponent -Context $Context -ComponentId $GovernedComponentId
    if ($null -eq $governed) { return }

    $preferred = Get-PolicyComponent -Context $Context -ComponentId $PreferredComponentId
    $installed = $null -ne $preferred
    $reference = if ($installed) { Get-PolicyComponentReference -Entry $preferred } else { Get-PolicyComponentReference -Entry $governed }
    $status = if ($installed) { 'compliant' } else { 'deviation' }
    $message = if ($installed) { "$PreferredComponentId is installed." } else { "$GovernedComponentId is installed but $PreferredComponentId is not." }

    New-PolicyFinding -PolicyKey $PolicyKey -Status $status -Expected $Expected -ComponentId $PreferredComponentId -Message $message `
        -Observed ([pscustomobject][ordered]@{ installed = $installed }) -Evidence @($reference)
}

function Invoke-PolicyTrackRule {
    <#
    .SYNOPSIS
    Compares the active version with the release the configured track points to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$PolicyKey,
        [Parameter(Mandatory)][string]$Track,
        [Parameter(Mandatory)][string]$ComponentId
    )

    $entry = Get-PolicyComponent -Context $Context -ComponentId $ComponentId
    if ($null -eq $entry) { return }

    $installed = Get-PolicyActiveVersion -Component $entry.component
    $intelligence = Get-ComparisonOptionalPropertyValue -InputObject $entry.component -Name 'versionIntelligence'
    $targetName = if ($Track -eq 'lts') { 'latestLts' } else { 'latestStable' }
    $target = [string](Get-PolicyValue -InputObject $intelligence -Path "$targetName.normalized")
    if ($Track -eq 'release-candidate-allowed') {
        # The newest of the stable and prerelease channels; either may be unpublished.
        $current = [string](Get-PolicyValue -InputObject $intelligence -Path 'latestCurrent.normalized')
        if (-not [string]::IsNullOrWhiteSpace($current) -and ([string]::IsNullOrWhiteSpace($target) -or (Compare-PolicyVersion -Left $current -Right $target) -gt 0)) {
            $target = $current
        }
        $targetName = 'latest'
    }

    if ([string](Get-ComparisonOptionalPropertyValue -InputObject $intelligence -Name 'status') -ne 'known' -or
        [string]::IsNullOrWhiteSpace($target) -or $null -eq $installed) {
        New-PolicyFinding -PolicyKey $PolicyKey -Status unknown -Expected $Track -ComponentId $ComponentId -Observed $null `
            -Message "Latest-version information for $ComponentId was unavailable in this report."
        return
    }

    $comparison = Compare-PolicyVersion -Left $installed -Right $target
    $compliant = $comparison -ge 0
    if ($Track -eq 'lts') {
        # An LTS track is only met on the LTS major line, not by a newer Current release.
        $compliant = $compliant -and $installed.Split('.')[0] -eq $target.Split('.')[0]
    }

    $message = if ($compliant) { "$ComponentId $installed meets the $Track track ($target)." } else { "$ComponentId $installed does not meet the $Track track ($target)." }
    $observed = [pscustomobject][ordered]@{ installed = $installed; $targetName = $target }
    $status = if ($compliant) { 'compliant' } else { 'deviation' }

    New-PolicyFinding -PolicyKey $PolicyKey -Status $status -Expected $Track -ComponentId $ComponentId -Observed $observed `
        -Message $message -Evidence @(Get-PolicyComponentReference -Entry $entry)
}

function Get-PolicyEnvironmentConfigured {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    if (-not $Context.evidence.ContainsKey($EvidenceId)) { return $false }
    $scopes = @(Get-PolicyValue -InputObject $Context.evidence[$EvidenceId].evidence -Path 'attributes.scopes')
    return @($scopes | Where-Object { $null -ne $_ -and (Get-ComparisonOptionalPropertyValue -InputObject $_ -Name 'isConfigured') -eq $true }).Count -gt 0
}

function Invoke-PolicyPathCountRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Context,
        [Parameter(Mandatory)][string]$PolicyKey,
        [Parameter(Mandatory)][bool]$Allowed,
        [Parameter(Mandatory)][string]$CountName,
        [Parameter(Mandatory)][string]$ObservedName,
        [Parameter(Mandatory)][string]$Noun,
        [Parameter(Mandatory)][string[]]$EvidenceIds
    )

    $references = @()
    $total = 0
    foreach ($evidenceId in $EvidenceIds) {
        if (-not $Context.evidence.ContainsKey($evidenceId)) { continue }
        $total += [int](Get-PolicyValue -InputObject $Context.evidence[$evidenceId].evidence -Path "attributes.$CountName")
        $references += Get-PolicyEvidenceReference -Context $Context -EvidenceId $evidenceId
    }

    if ($references.Count -eq 0) {
        New-PolicyFinding -PolicyKey $PolicyKey -Status unknown -Expected $Allowed -Observed $null -Message 'PATH health evidence was not collected.'
        return
    }

    $compliant = $Allowed -or $total -eq 0
    $status = if ($compliant) { 'compliant' } else { 'deviation' }
    New-PolicyFinding -PolicyKey $PolicyKey -Status $status -Expected $Allowed -Evidence $references `
        -Observed ([pscustomobject][ordered]@{ $ObservedName = $total }) `
        -Message "Persistent PATH has $total $Noun entr$(if ($total -eq 1) { 'y' } else { 'ies' })."
}

$script:ComponentTrackKeys = [ordered]@{
    'node'        = 'node.defaultTrack'
    'angular-cli' = 'angular.globalCliTrack'
    'typescript'  = 'typescript.globalTrack'
    'prisma'      = 'prisma.globalTrack'
    'flutter'     = 'flutter.sdkTrack'
    'java'        = 'java.defaultTrack'
}

# Every policy key has exactly one rule. A string is the reason the key is not evaluable from a report.
$script:PolicyRules = [ordered]@{
    'windows.applicationManager' = {
        param($Context, $Expected, $Policy)
        $entry = Get-PolicyComponent -Context $Context -ComponentId $Expected
        if ($null -eq $entry) {
            $reference = Get-PolicyEvidenceReference -Context $Context -EvidenceId 'winget.version'
            if ($null -eq $reference) {
                New-PolicyFinding -PolicyKey 'windows.applicationManager' -Status unknown -Expected $Expected -ComponentId $Expected -Observed $null -Message 'The application manager was not audited.'
                return
            }
            New-PolicyFinding -PolicyKey 'windows.applicationManager' -Status deviation -Expected $Expected -ComponentId $Expected -Message "$Expected is not available." `
                -Observed ([pscustomobject][ordered]@{ installed = $false }) -Evidence @($reference)
            return
        }
        New-PolicyFinding -PolicyKey 'windows.applicationManager' -Status compliant -Expected $Expected -ComponentId $Expected -Message "$Expected is available." `
            -Observed ([pscustomobject][ordered]@{ installed = $true }) -Evidence @(Get-PolicyComponentReference -Entry $entry)
    }
    'windows.updatePolicy' = 'Update workflow is an operator process; the audit never upgrades.'
    'node.manager' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyPresenceRule -Context $Context -PolicyKey 'node.manager' -Expected $Expected -GovernedComponentId 'node' -PreferredComponentId $Expected
    }
    'node.defaultTrack' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyTrackRule -Context $Context -PolicyKey 'node.defaultTrack' -Track $Expected -ComponentId 'node'
    }
    'node.alsoInstallCurrent' = {
        param($Context, $Expected, $Policy)
        $entry = Get-PolicyComponent -Context $Context -ComponentId 'node'
        if ($null -eq $entry -or -not $Expected) { return }
        $current = [string](Get-PolicyValue -InputObject $entry.component -Path 'versionIntelligence.latestCurrent.normalized')
        if ([string]::IsNullOrWhiteSpace($current)) {
            New-PolicyFinding -PolicyKey 'node.alsoInstallCurrent' -Status unknown -Expected $Expected -ComponentId 'node' -Observed $null -Message 'The latest Node Current release was unavailable in this report.'
            return
        }
        $major = $current.Split('.')[0]
        $found = @(@(Get-ComparisonOptionalPropertyValue -InputObject $entry.component -Name 'discoveredVersions') |
                Where-Object { $null -ne $_ -and ([string]$_.normalized).Split('.')[0] -eq $major }).Count -gt 0
        $status = if ($found) { 'compliant' } else { 'deviation' }
        New-PolicyFinding -PolicyKey 'node.alsoInstallCurrent' -Status $status -Expected $Expected -ComponentId 'node' `
            -Observed ([pscustomobject][ordered]@{ currentMajor = [int]$major; installed = $found }) -Evidence @(Get-PolicyComponentReference -Entry $entry) `
            -Message $(if ($found) { "A Node $major.x (Current) installation is present." } else { "No Node $major.x (Current) installation is present." })
    }
    'node.projectVersionsMustBePinned' = {
        param($Context, $Expected, $Policy)
        if (-not $Expected) { return }
        foreach ($project in $Context.projects) {
            $pins = @(Get-ComparisonOptionalPropertyValue -InputObject $project.project -Name 'nodePins' | Where-Object { $null -ne $_ })
            $status = if ($pins.Count -gt 0) { 'compliant' } else { 'deviation' }
            New-PolicyFinding -PolicyKey 'node.projectVersionsMustBePinned' -Status $status -Expected $Expected -SubjectId $project.subjectId `
                -Observed ([pscustomobject][ordered]@{ nodePinCount = $pins.Count }) `
                -Evidence @(Get-PolicyEvidenceReference -Context $Context -EvidenceId $project.evidenceId) `
                -Message $(if ($pins.Count -gt 0) { 'Project declares a Node version pin.' } else { 'Project declares no Node version pin.' })
        }
    }
    'node.managerTrack' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyTrackRule -Context $Context -PolicyKey 'node.managerTrack' -Track $Expected -ComponentId ([string]$Policy.node.manager)
    }
    'node.legacyManagerPolicy' = 'Migration guidance for legacy Node managers; no single report value decides it.'
    'javascript.primaryPackageManager' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyPresenceRule -Context $Context -PolicyKey 'javascript.primaryPackageManager' -Expected $Expected -GovernedComponentId 'node' -PreferredComponentId $Expected
    }
    'javascript.globalPackageManager' = {
        param($Context, $Expected, $Policy)
        if ($Expected -eq 'npm' -or -not $Context.evidence.ContainsKey('javascript.npm.global-inventory')) { return }
        $inventory = Get-PolicyValue -InputObject $Context.evidence['javascript.npm.global-inventory'].evidence -Path 'attributes'
        if ([string](Get-ComparisonOptionalPropertyValue -InputObject $inventory -Name 'status') -ne 'success') {
            New-PolicyFinding -PolicyKey 'javascript.globalPackageManager' -Status unknown -Expected $Expected -Observed $null -Message 'The npm global inventory could not be read.'
            return
        }
        $count = @(Get-ComparisonOptionalPropertyValue -InputObject $inventory -Name 'matchedPackages' | Where-Object { $null -ne $_ }).Count
        $status = if ($count -eq 0) { 'compliant' } else { 'deviation' }
        New-PolicyFinding -PolicyKey 'javascript.globalPackageManager' -Status $status -Expected $Expected `
            -Observed ([pscustomobject][ordered]@{ npmGlobalPackageCount = $count }) `
            -Evidence @(Get-PolicyEvidenceReference -Context $Context -EvidenceId 'javascript.npm.global-inventory') `
            -Message "$count tracked global package(s) are installed with npm instead of $Expected."
    }
    'javascript.npmRole' = 'npm role is a usage convention; the report cannot tell fallback use from primary use.'
    'javascript.projectDependencies' = {
        param($Context, $Expected, $Policy)
        foreach ($project in $Context.projects) {
            $lockfiles = @(Get-ComparisonOptionalPropertyValue -InputObject $project.project -Name 'lockfiles' | Where-Object { $null -ne $_ })
            $status = if ($lockfiles.Count -gt 0) { 'compliant' } else { 'deviation' }
            New-PolicyFinding -PolicyKey 'javascript.projectDependencies' -Status $status -Expected $Expected -SubjectId $project.subjectId `
                -Observed ([pscustomobject][ordered]@{ lockfileCount = $lockfiles.Count }) `
                -Evidence @(Get-PolicyEvidenceReference -Context $Context -EvidenceId $project.evidenceId) `
                -Message $(if ($lockfiles.Count -gt 0) { 'Project dependencies are pinned by a lockfile.' } else { 'Project has no lockfile.' })
        }
    }
    'angular.globalCliTrack' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyTrackRule -Context $Context -PolicyKey 'angular.globalCliTrack' -Track $Expected -ComponentId 'angular-cli'
    }
    'angular.projectMajorUpgradesRequireExplicitMigration' = 'Upgrade process rule; the audit never upgrades projects.'
    'typescript.globalTrack' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyTrackRule -Context $Context -PolicyKey 'typescript.globalTrack' -Track $Expected -ComponentId 'typescript'
    }
    'typescript.projectsMustUseLocalCompatibleVersion' = 'Project-local TypeScript versions are not inspected (node_modules is never read).'
    'prisma.globalTrack' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyTrackRule -Context $Context -PolicyKey 'prisma.globalTrack' -Track $Expected -ComponentId 'prisma'
    }
    'prisma.projectsMustUseLocalPinnedVersion' = 'Project-local Prisma versions are not inspected (node_modules is never read).'
    'flutter.channel' = {
        param($Context, $Expected, $Policy)
        $entry = Get-PolicyComponent -Context $Context -ComponentId 'flutter'
        if ($null -eq $entry) { return }
        $channel = [string](Get-PolicyValue -InputObject $entry.component -Path 'activeVersion.channel')
        if ([string]::IsNullOrWhiteSpace($channel)) {
            New-PolicyFinding -PolicyKey 'flutter.channel' -Status unknown -Expected $Expected -ComponentId 'flutter' -Observed $null -Message 'The Flutter channel was not reported.'
            return
        }
        $status = if ($channel -eq $Expected) { 'compliant' } else { 'deviation' }
        New-PolicyFinding -PolicyKey 'flutter.channel' -Status $status -Expected $Expected -ComponentId 'flutter' -Message "Flutter is on the $channel channel." `
            -Observed ([pscustomobject][ordered]@{ channel = $channel }) -Evidence @(Get-PolicyComponentReference -Entry $entry)
    }
    'flutter.sdkTrack' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyTrackRule -Context $Context -PolicyKey 'flutter.sdkTrack' -Track $Expected -ComponentId 'flutter'
    }
    'flutter.dartSource' = {
        param($Context, $Expected, $Policy)
        if ($null -eq (Get-PolicyComponent -Context $Context -ComponentId 'dart') -or -not $Context.evidence.ContainsKey('mobile.dart.relationship')) { return }
        $source = [string](Get-PolicyValue -InputObject $Context.evidence['mobile.dart.relationship'].evidence -Path 'attributes.activeSource')
        $status = if ($Expected -ne 'flutter-sdk-preferred' -or $source -eq 'flutter-bundled') { 'compliant' } else { 'deviation' }
        New-PolicyFinding -PolicyKey 'flutter.dartSource' -Status $status -Expected $Expected -ComponentId 'dart' -Message "The active Dart comes from: $source." `
            -Observed ([pscustomobject][ordered]@{ activeSource = $source }) -Evidence @(Get-PolicyEvidenceReference -Context $Context -EvidenceId 'mobile.dart.relationship')
    }
    'path.allowMissingEntries' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyPathCountRule -Context $Context -PolicyKey 'path.allowMissingEntries' -Allowed $Expected -CountName 'missingCount' -ObservedName 'missingEntryCount' -Noun 'missing' `
            -EvidenceIds @('path.machine.health', 'path.user.health')
    }
    'path.allowDuplicateEntries' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyPathCountRule -Context $Context -PolicyKey 'path.allowDuplicateEntries' -Allowed $Expected -CountName 'duplicateCount' -ObservedName 'duplicateEntryCount' -Noun 'duplicate' `
            -EvidenceIds @('path.machine.health', 'path.user.health', 'path.persistent.cross-scope-duplicates')
    }
    'path.auditCommandCollisions' = {
        param($Context, $Expected, $Policy)
        if (-not $Expected) { return }
        if (-not $Context.providers.ContainsKey('path.precedence') -or [string]$Context.providers['path.precedence'].status -in @('failed', 'unavailable')) {
            New-PolicyFinding -PolicyKey 'path.auditCommandCollisions' -Status unknown -Expected $Expected -Observed $null -Message 'Command precedence was not audited.'
            return
        }
        $count = @(@(Get-ComparisonOptionalPropertyValue -InputObject $Context.providers['path.precedence'] -Name 'warnings') |
                Where-Object { $null -ne $_ -and $_.code -eq 'COMMAND_PATH_PRECEDENCE_CONFLICT' }).Count
        New-PolicyFinding -PolicyKey 'path.auditCommandCollisions' -Status compliant -Expected $Expected `
            -Observed ([pscustomobject][ordered]@{ collisionCount = $count }) -Evidence @(New-PolicyEvidenceReference -ProviderId 'path.precedence' -ComponentId $null -EvidenceId $null) `
            -Message "Command collisions were audited; $count conflict(s) reported."
    }
    'versioning.globalDefaultTrack' = 'Applied through each component track rule.'
    'versioning.prereleasePolicy' = {
        param($Context, $Expected, $Policy)
        $prereleases = @(foreach ($componentId in @($Context.components.Keys | Sort-Object)) {
                $entry = Get-PolicyComponent -Context $Context -ComponentId $componentId
                if ($null -eq $entry) { continue }
                $version = Get-PolicyActiveVersion -Component $entry.component
                if ($null -ne $version -and $version -match $script:PrereleasePattern) {
                    [pscustomobject]@{ entry = $entry; version = $version }
                }
            })

        if ($prereleases.Count -eq 0) {
            $references = @($Context.components.Values | Where-Object { $null -ne (Get-PolicyActiveVersion -Component $_.component) } |
                    Sort-Object { $_.component.componentId } | Select-Object -First 1 | ForEach-Object { Get-PolicyComponentReference -Entry $_ })
            if ($references.Count -eq 0) { return }
            New-PolicyFinding -PolicyKey 'versioning.prereleasePolicy' -Status compliant -Expected $Expected -Evidence $references `
                -Observed ([pscustomobject][ordered]@{ prereleaseCount = 0 }) -Message 'No installed component is on a prerelease version.'
            return
        }

        foreach ($item in $prereleases) {
            $componentId = [string]$item.entry.component.componentId
            $trackKey = if ($script:ComponentTrackKeys.Contains($componentId)) { $script:ComponentTrackKeys[$componentId] } else { 'versioning.globalDefaultTrack' }
            $track = [string](Get-PolicyValue -InputObject $Policy -Path $trackKey)
            $optedIn = $Expected -ne 'explicit-opt-in-only' -or $track -eq 'release-candidate-allowed'
            $status = if ($optedIn) { 'compliant' } else { 'deviation' }
            New-PolicyFinding -PolicyKey 'versioning.prereleasePolicy' -Status $status -Expected $Expected -ComponentId $componentId -SubjectId "component:$componentId" `
                -Observed ([pscustomobject][ordered]@{ version = $item.version; track = $track }) -Evidence @(Get-PolicyComponentReference -Entry $item.entry) `
                -Message $(if ($optedIn) { "$componentId $($item.version) is a prerelease allowed by $trackKey." } else { "$componentId $($item.version) is a prerelease without an explicit opt-in." })
        }
    }
    'versioning.projectCompatibilityOverridesGlobal' = 'Precedence principle for interpreting other rules; not a machine state.'
    'java.defaultTrack' = {
        param($Context, $Expected, $Policy)
        Invoke-PolicyTrackRule -Context $Context -PolicyKey 'java.defaultTrack' -Track $Expected -ComponentId 'java'
    }
    'java.projectsMustUseLocalCompatibleVersion' = 'Project-level Java compatibility is not inspected.'
    'android.sdkToolsTrack' = 'No latest-version source exists for Android SDK tools.'
    'android.platformToolsTrack' = 'No latest-version source exists for Android platform tools.'
    'android.preferAndroidHome' = {
        param($Context, $Expected, $Policy)
        if (-not $Expected -or $null -eq (Get-PolicyComponent -Context $Context -ComponentId 'android-sdk')) { return }
        $reference = Get-PolicyEvidenceReference -Context $Context -EvidenceId 'environment.android_home'
        if ($null -eq $reference) {
            New-PolicyFinding -PolicyKey 'android.preferAndroidHome' -Status unknown -Expected $Expected -Observed $null -Message 'Android environment variables were not audited.'
            return
        }
        $androidHome = Get-PolicyEnvironmentConfigured -Context $Context -EvidenceId 'environment.android_home'
        $sdkRoot = Get-PolicyEnvironmentConfigured -Context $Context -EvidenceId 'environment.android_sdk_root'
        $status = if ($androidHome) { 'compliant' } else { 'deviation' }
        New-PolicyFinding -PolicyKey 'android.preferAndroidHome' -Status $status -Expected $Expected -Evidence @($reference) `
            -Observed ([pscustomobject][ordered]@{ androidHomeConfigured = $androidHome; androidSdkRootConfigured = $sdkRoot }) `
            -Message $(if ($androidHome) { 'ANDROID_HOME is configured.' } else { 'An Android SDK is installed but ANDROID_HOME is not configured.' })
    }
    'android.acceptLicensesDuringAudit' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
    'python.defaultTrack' = 'No latest-version source exists for Python yet.'
    'python.windowsManager' = {
        param($Context, $Expected, $Policy)
        if ($null -eq (Get-PolicyComponent -Context $Context -ComponentId 'python') -or $Expected -ne 'python-install-manager') { return }
        if (-not $Context.evidence.ContainsKey('winget.inventory.normalized')) {
            New-PolicyFinding -PolicyKey 'python.windowsManager' -Status unknown -Expected $Expected -ComponentId 'python' -Observed $null -Message 'The WinGet inventory was not collected, so the Python manager is unknown.'
            return
        }
        $packages = @(Get-PolicyValue -InputObject $Context.evidence['winget.inventory.normalized'].evidence -Path 'attributes.packages')
        $installed = @($packages | Where-Object { $null -ne $_ -and ([string]$_.packageId -eq 'Python.PythonInstallManager' -or [string]$_.name -eq 'Python Install Manager') }).Count -gt 0
        $status = if ($installed) { 'compliant' } else { 'deviation' }
        New-PolicyFinding -PolicyKey 'python.windowsManager' -Status $status -Expected $Expected -ComponentId 'python' `
            -Observed ([pscustomobject][ordered]@{ installManagerInstalled = $installed }) `
            -Evidence @(Get-PolicyEvidenceReference -Context $Context -EvidenceId 'winget.inventory.normalized') `
            -Message $(if ($installed) { 'The Python Install Manager is installed.' } else { 'Python is installed without the Python Install Manager.' })
    }
    'python.projectsMustUseLocalCompatibleVersion' = 'Project-level Python compatibility is not inspected.'
    'python.virtualEnvironments' = 'Virtual environments are not inspected.'
    'python.packageToolsTrack' = 'No latest-version source exists for Python package tools.'
    'dotnet.defaultTrack' = 'No latest-version source exists for .NET yet.'
    'dotnet.projectsMustUseLocalCompatibleVersion' = 'Project-level .NET compatibility is not inspected.'
    'dotnet.workloadsTrack' = 'No latest-version source exists for .NET workloads.'
    'dotnet.inspectWorkloadsReadOnly' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
    'rust.manager' = {
        param($Context, $Expected, $Policy)
        $toolchain = @('rustc', 'cargo') | Where-Object { $null -ne (Get-PolicyComponent -Context $Context -ComponentId $_) } | Select-Object -First 1
        if ($null -eq $toolchain) { return }
        Invoke-PolicyPresenceRule -Context $Context -PolicyKey 'rust.manager' -Expected $Expected -GovernedComponentId $toolchain -PreferredComponentId $Expected
    }
    'rust.defaultChannel' = 'The active Rust channel is not normalized in the report yet.'
    'rust.defaultTrack' = 'No latest-version source exists for Rust yet.'
    'rust.managerTrack' = 'No latest-version source exists for rustup yet.'
    'rust.projectsMayPinToolchain' = 'Permission, not a requirement; nothing to verify.'
    'rust.autoInstallDuringAudit' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
    'rust.minimumSafeInspectionVersion' = 'Audit-safety threshold applied by the Rust provider before inspection.'
    'rust.legacyManagerPolicy' = 'Migration guidance for legacy Rust installs; no single report value decides it.'
    'go.defaultTrack' = 'No latest-version source exists for Go yet.'
    'go.projectsMustUseLocalCompatibleVersion' = 'Project-level Go compatibility is not inspected.'
    'go.inspectEnvironmentReadOnly' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
    'developerClis.defaultTrack' = 'No latest-version source exists for developer CLIs yet.'
    'developerClis.inspectAuthenticationState' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
    'developerClis.inspectAccountState' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
    'developerClis.inspectGitConfiguration' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
    'developerClis.inspectDockerDaemon' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
    'developerClis.inspectDockerContexts' = 'Audit-safety setting enforced by the audit itself; no machine evidence applies.'
}

function Get-PolicyEvaluationRuleKeys {
    [CmdletBinding()]
    param()

    return @($script:PolicyRules.Keys)
}

function New-WorkstationPolicyEvaluation {
    <#
    .SYNOPSIS
    Evaluates a normalized audit report against the workstation policy. Pure: reads nothing, changes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Report,
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Policy,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$PolicyDigest
    )

    $null = Assert-WorkstationComparisonReport -Report $Report -Role reference

    $policyKeys = Get-PolicyLeafKeys -Policy $Policy
    $missingRules = @($policyKeys | Where-Object { -not $script:PolicyRules.Contains($_) })
    if ($missingRules.Count -gt 0) {
        throw "Policy keys have no evaluation rule: $($missingRules -join ', ')"
    }

    $context = New-PolicyEvaluationContext -Report $Report
    $findings = [System.Collections.Generic.List[object]]::new()

    foreach ($key in $policyKeys) {
        $expected = Get-PolicyValue -InputObject $Policy -Path $key
        $rule = $script:PolicyRules[$key]
        if ($rule -is [string]) {
            $findings.Add((New-PolicyFinding -PolicyKey $key -Status not-evaluable -Expected $expected -Observed $null -Message $rule))
            continue
        }
        foreach ($finding in @(& $rule $context $expected $Policy)) {
            if ($null -ne $finding) { $findings.Add($finding) }
        }
    }

    # Ordinal order so PowerShell and the Python contract validator agree.
    $sortKey = { param($Finding) '{0}{3}{1}{3}{2}' -f $Finding.policyKey, $Finding.ruleId, [string]$Finding.subjectId, [char]1 }
    $findings.Sort([Comparison[object]] { param($a, $b) [string]::CompareOrdinal((& $sortKey $a), (& $sortKey $b)) })
    $items = $findings.ToArray()

    $count = { param($Status) @($items | Where-Object status -eq $Status).Count }
    $deviations = & $count 'deviation'
    $unknown = & $count 'unknown'

    return [pscustomobject][ordered]@{
        schemaVersion    = $script:EvaluationSchemaVersion
        auditSchemaMajor = 1
        policy           = [pscustomobject][ordered]@{
            schemaVersion = [string]$Policy.schemaVersion
            digest        = $PolicyDigest
        }
        report           = New-ComparisonEndpointDescriptor -Report $Report
        summary          = [pscustomobject][ordered]@{
            status            = if ($deviations -gt 0) { 'deviations' } elseif ($unknown -gt 0) { 'incomplete' } else { 'compliant' }
            findingCount      = $items.Count
            compliantCount    = & $count 'compliant'
            deviationCount    = $deviations
            unknownCount      = $unknown
            notEvaluableCount = & $count 'not-evaluable'
        }
        findings         = @($items)
    }
}

function ConvertTo-WorkstationPolicyEvaluationText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()][psobject]$Evaluation)

    $s = $Evaluation.summary
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Workstation policy evaluation: $($s.status)")
    $lines.Add("Host: $($Evaluation.report.host.name) | report $($Evaluation.report.generatedAt) | tool $($Evaluation.report.audit.toolVersion)")
    $lines.Add("Findings: $($s.findingCount) (compliant $($s.compliantCount), deviation $($s.deviationCount), unknown $($s.unknownCount), not evaluable $($s.notEvaluableCount))")

    foreach ($status in @('deviation', 'unknown', 'compliant')) {
        $group = @($Evaluation.findings | Where-Object status -eq $status)
        if ($group.Count -eq 0) { continue }
        $lines.Add('')
        $lines.Add("[$status]")
        foreach ($finding in $group) {
            $subject = if ($null -ne $finding.subjectId) { " ($($finding.subjectId))" } else { '' }
            $lines.Add("  $($finding.policyKey)$subject - $($finding.message)")
        }
    }

    $lines.Add('')
    $lines.Add("Not evaluable from a report: $($s.notEvaluableCount) policy key(s); see the JSON output for reasons.")
    return (($lines -join [string][char]10) + [string][char]10)
}

function ConvertTo-WorkstationOutputJson {
    <#
    .SYNOPSIS
    Compact LF-terminated JSON with the same bytes on Windows PowerShell 5.1 and PowerShell 7.
    5.1 escapes < > & ' as < and friends; 7 writes them literally.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNull()][psobject]$InputObject)

    $lf = [string][char]10
    $json = ($InputObject | ConvertTo-Json -Depth 100 -Compress).Replace(([string][char]13) + $lf, $lf).TrimEnd()
    # Only unescape when the backslash itself is not escaped (an even run of backslashes precedes it).
    $json = [regex]::Replace($json, '(?<!\\)((?:\\\\)*)\\u00(3c|3e|26|27)', {
            param($m)
            $m.Groups[1].Value + [string][char][Convert]::ToInt32($m.Groups[2].Value, 16)
        })
    return $json + $lf
}

function Write-WorkstationPolicyEvaluationOutputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Evaluation,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory
    )

    $directory = [IO.Path]::GetFullPath($OutputDirectory)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $structuredPath = Join-Path $directory 'evaluation.json'
    $humanReadablePath = Join-Path $directory 'evaluation.txt'

    $json = ConvertTo-WorkstationOutputJson -InputObject $Evaluation
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($structuredPath, $json, $utf8NoBom)
    [IO.File]::WriteAllText($humanReadablePath, (ConvertTo-WorkstationPolicyEvaluationText -Evaluation $Evaluation), $utf8NoBom)

    return [pscustomobject][ordered]@{
        structuredPath    = $structuredPath
        humanReadablePath = $humanReadablePath
    }
}

Export-ModuleMember -Function @(
    'Compare-PolicyVersion',
    'Get-PolicyLeafKeys',
    'Get-PolicyEvaluationRuleKeys',
    'New-WorkstationPolicyEvaluation',
    'ConvertTo-WorkstationPolicyEvaluationText',
    'ConvertTo-WorkstationOutputJson',
    'Write-WorkstationPolicyEvaluationOutputs'
)
