[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'javascript.precedence'
        category   = 'environment'
        order      = 31
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = [System.Collections.Generic.List[object]]::new()
$errors = [System.Collections.Generic.List[object]]::new()
$evidence = [System.Collections.Generic.List[object]]::new()
$hasPartial = $false

$previousProviderResults = if ($Context.PSObject.Properties['PreviousProviderResults']) {
    @($Context.PreviousProviderResults)
}
else {
    @()
}

function Get-PreviousProviderResult {
    param([Parameter(Mandatory)][string]$ProviderId)

    return @(
        $previousProviderResults |
            Where-Object { [string]$_.providerId -eq $ProviderId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Get-ProviderEvidence {
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    if ($null -eq $Provider) {
        return $null
    }

    return @(
        @($Provider.evidence) |
            Where-Object { [string]$_.evidenceId -eq $EvidenceId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Get-JavascriptComponent {
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory)][string]$ComponentId
    )

    if ($null -eq $Provider) {
        return $null
    }

    return @(
        @($Provider.components) |
            Where-Object { [string]$_.componentId -eq $ComponentId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Get-CommandPrecedenceEvidence {
    param(
        [AllowNull()][object]$Provider,
        [Parameter(Mandatory)][string]$Command
    )

    if ($null -eq $Provider) {
        return $null
    }

    return @(
        @($Provider.evidence) |
            Where-Object {
                [string]$_.evidenceId -like 'path-precedence.command.*' -and
                $null -ne $_.attributes -and
                [string]$_.attributes.command -eq $Command
            } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

function Get-EnvironmentPathState {
    param(
        [AllowNull()][object]$EnvironmentProvider,
        [AllowNull()][object]$ProcessPathEvidence,
        [Parameter(Mandatory)][string]$Name
    )

    $evidenceId = "environment.$($Name.ToLowerInvariant())"
    $variableEvidence = Get-ProviderEvidence -Provider $EnvironmentProvider -EvidenceId $evidenceId

    $result = [pscustomobject][ordered]@{
        name            = $Name
        evidenceId      = $evidenceId
        configured      = $false
        scope           = $null
        state           = 'unavailable'
        normalized      = $null
        comparisonKey   = $null
        exists          = $null
        invalid         = $false
        unresolved      = $false
        onProcessPath   = $false
        pathPositions   = @()
        firstPathPosition = $null
    }

    if ($null -eq $variableEvidence -or $null -eq $variableEvidence.attributes) {
        return $result
    }

    $scopes = @($variableEvidence.attributes.scopes)
    $selected = $null

    foreach ($scopeName in @('process', 'user', 'machine')) {
        $candidate = @(
            $scopes |
                Where-Object { [string]$_.scope -eq $scopeName } |
                Select-Object -First 1
        ) | Select-Object -First 1

        if ($null -eq $candidate) {
            continue
        }

        if ([string]$candidate.state -eq 'value' -and -not [bool]$candidate.isInvalid) {
            $selected = $candidate
            break
        }

        if ($null -eq $selected -and [bool]$candidate.isConfigured) {
            $selected = $candidate
        }
    }

    if ($null -eq $selected) {
        $result.state = 'unset'
        return $result
    }

    $result.configured = [bool]$selected.isConfigured
    $result.scope = [string]$selected.scope
    $result.state = [string]$selected.state
    $result.normalized = $selected.normalized
    $result.comparisonKey = $selected.comparisonKey
    $result.exists = $selected.exists
    $result.invalid = [bool]$selected.isInvalid
    $result.unresolved = [bool]$selected.hasUnresolvedVariable

    if (
        -not [string]::IsNullOrWhiteSpace([string]$result.comparisonKey) -and
        $null -ne $ProcessPathEvidence -and
        $null -ne $ProcessPathEvidence.attributes
    ) {
        $positions = @(
            @($ProcessPathEvidence.attributes.entries) |
                Where-Object {
                    [string]::Equals(
                        [string]$_.comparisonKey,
                        [string]$result.comparisonKey,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Sort-Object position |
                ForEach-Object { [int]$_.position }
        )

        $result.pathPositions = @($positions)
        $result.onProcessPath = ($positions.Count -gt 0)
        if ($positions.Count -gt 0) {
            $result.firstPathPosition = [int]$positions[0]
        }
    }

    return $result
}

function Get-CommandRelationship {
    param(
        [AllowNull()][object]$PathProvider,
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][object]$ExpectedPathState
    )

    $commandEvidence = Get-CommandPrecedenceEvidence -Provider $PathProvider -Command $Command

    $result = [pscustomobject][ordered]@{
        command                    = $Command
        evidenceId                 = $(if ($commandEvidence) { [string]$commandEvidence.evidenceId } else { $null })
        available                  = ($null -ne $commandEvidence)
        resolutionCount            = 0
        hasPathResolutionCollision = $false
        activePath                 = $null
        activePathDirectory        = $null
        activePathComparisonKey    = $null
        activePathPosition         = $null
        activePathMappingStatus    = $null
        activePathBased            = $false
        shadowedResolutions        = @()
        expectedPath               = $(if ($ExpectedPathState) { $ExpectedPathState.normalized } else { $null })
        expectedPathScope          = $(if ($ExpectedPathState) { $ExpectedPathState.scope } else { $null })
        expectedPathPosition       = $(if ($ExpectedPathState) { $ExpectedPathState.firstPathPosition } else { $null })
        expectedPathOnProcessPath  = $(if ($ExpectedPathState) { [bool]$ExpectedPathState.onProcessPath } else { $false })
        relationship               = 'not-configured'
    }

    if ($null -eq $commandEvidence -or $null -eq $commandEvidence.attributes) {
        $result.relationship = 'command-analysis-unavailable'
        return $result
    }

    $attributes = $commandEvidence.attributes
    $result.resolutionCount = [int]$attributes.resolutionCount
    $result.hasPathResolutionCollision = [bool]$attributes.hasPathResolutionCollision
    $result.shadowedResolutions = @($attributes.shadowedResolutions)

    $active = $attributes.activeResolution
    if ($null -eq $active) {
        $result.relationship = 'no-active-resolution'
        return $result
    }

    $result.activePath = $active.path
    $result.activePathDirectory = $active.pathDirectory
    $result.activePathComparisonKey = $active.pathComparisonKey
    $result.activePathPosition = $active.pathPosition
    $result.activePathMappingStatus = $active.pathMappingStatus
    $result.activePathBased = [bool]$active.pathBased

    if ($null -eq $ExpectedPathState -or -not $ExpectedPathState.configured) {
        $result.relationship = 'not-configured'
        return $result
    }

    if (
        [string]::IsNullOrWhiteSpace([string]$ExpectedPathState.comparisonKey) -or
        $ExpectedPathState.invalid -or
        $ExpectedPathState.unresolved
    ) {
        $result.relationship = 'expected-path-unusable'
        return $result
    }

    if (-not $result.activePathBased) {
        $result.relationship = 'active-resolution-not-path-based'
        return $result
    }

    if ([string]::IsNullOrWhiteSpace([string]$result.activePathComparisonKey)) {
        $result.relationship = 'active-origin-unproven'
        return $result
    }

    if (
        [string]::Equals(
            [string]$result.activePathComparisonKey,
            [string]$ExpectedPathState.comparisonKey,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $result.relationship = 'aligned'
    }
    else {
        $result.relationship = 'mismatch'
    }

    return $result
}

function Format-PathPosition {
    param([AllowNull()][object]$Position)

    if ($null -eq $Position) {
        return 'PATH[unknown]'
    }

    return "PATH[$Position]"
}

function Add-CommandCollisionFinding {
    param(
        [Parameter(Mandatory)][object]$Relationship,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    if (-not $Relationship.available -or -not $Relationship.hasPathResolutionCollision) {
        return
    }

    $activePosition = Format-PathPosition -Position $Relationship.activePathPosition
    $shadowedText = @(
        @($Relationship.shadowedResolutions) |
            Where-Object { [bool]$_.pathBased } |
            ForEach-Object {
                "'$($_.path)' at $(Format-PathPosition -Position $_.pathPosition)"
            }
    ) -join '; '

    $warnings.Add((New-AuditIssue -Code $Code -Message "JavaScript command '$($Relationship.command)' resolves actively to '$($Relationship.activePath)' at $activePosition and shadows: $shadowedText." -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
}

$javascriptProvider = Get-PreviousProviderResult -ProviderId 'javascript.toolchain'
$pathProvider = Get-PreviousProviderResult -ProviderId 'path.precedence'
$environmentProvider = Get-PreviousProviderResult -ProviderId 'environment.baseline'

$dependencyStates = [ordered]@{
    javascriptToolchain = ($null -ne $javascriptProvider)
    pathPrecedence      = ($null -ne $pathProvider)
    environmentBaseline = ($null -ne $environmentProvider)
}

foreach ($dependencyName in @($dependencyStates.Keys)) {
    if (-not [bool]$dependencyStates[$dependencyName]) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'JAVASCRIPT_PRECEDENCE_DEPENDENCY_MISSING' -Message "JavaScript precedence analysis could not find required prior provider '$dependencyName'." -Severity warning -EvidenceIds @('javascript-precedence.summary')))
    }
}

foreach ($dependency in @($javascriptProvider, $pathProvider, $environmentProvider)) {
    if ($null -ne $dependency -and [string]$dependency.status -eq 'failed') {
        $hasPartial = $true
    }
}

$processPathEvidence = Get-ProviderEvidence -Provider $environmentProvider -EvidenceId 'path.process.health'

$nvmHome = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -ProcessPathEvidence $processPathEvidence -Name 'NVM_HOME'
$nvmSymlink = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -ProcessPathEvidence $processPathEvidence -Name 'NVM_SYMLINK'
$pnpmHome = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -ProcessPathEvidence $processPathEvidence -Name 'PNPM_HOME'

$nvmComponent = Get-JavascriptComponent -Provider $javascriptProvider -ComponentId 'nvm-windows'
$nodeComponent = Get-JavascriptComponent -Provider $javascriptProvider -ComponentId 'node'
$npmComponent = Get-JavascriptComponent -Provider $javascriptProvider -ComponentId 'npm'
$pnpmComponent = Get-JavascriptComponent -Provider $javascriptProvider -ComponentId 'pnpm'

$nvmPresent = ($null -ne $nvmComponent -and [string]$nvmComponent.state -eq 'present')
$nodePresent = ($null -ne $nodeComponent -and [string]$nodeComponent.state -eq 'present')
$npmPresent = ($null -ne $npmComponent -and [string]$npmComponent.state -eq 'present')
$pnpmPresent = ($null -ne $pnpmComponent -and [string]$pnpmComponent.state -eq 'present')

$nodeRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'node' -ExpectedPathState $nvmSymlink
$npmRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'npm' -ExpectedPathState $nvmSymlink
$pnpmRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'pnpm' -ExpectedPathState $pnpmHome

$nvmPathOrder = 'not-comparable'
if ($nvmHome.onProcessPath -and $nvmSymlink.onProcessPath) {
    if ($nvmHome.firstPathPosition -lt $nvmSymlink.firstPathPosition) {
        $nvmPathOrder = 'home-before-symlink'
    }
    elseif ($nvmSymlink.firstPathPosition -lt $nvmHome.firstPathPosition) {
        $nvmPathOrder = 'symlink-before-home'
    }
    else {
        $nvmPathOrder = 'same-position'
    }
}

$environmentEvidenceId = 'javascript-precedence.environment'
$evidence.Add((New-AuditEvidence -EvidenceId $environmentEvidenceId -Type derived -Source 'JavaScript environment/PATH relationships' -Captured $null -Attributes @{
    nvmHome = $nvmHome
    nvmSymlink = $nvmSymlink
    pnpmHome = $pnpmHome
    nvmPathOrder = $nvmPathOrder
    nvmPresent = $nvmPresent
    pnpmPresent = $pnpmPresent
}))

foreach ($state in @(
    [pscustomobject]@{ item=$nvmHome; code='NVM_HOME_STALE_PATH'; label='NVM_HOME'; component='nvm-windows' },
    [pscustomobject]@{ item=$nvmSymlink; code='NVM_SYMLINK_STALE_PATH'; label='NVM_SYMLINK'; component='nvm-windows' },
    [pscustomobject]@{ item=$pnpmHome; code='PNPM_HOME_STALE_PATH'; label='PNPM_HOME'; component='pnpm' }
)) {
    if ($state.item.configured -and $state.item.exists -eq $false) {
        $warnings.Add((New-AuditIssue -Code $state.code -Message "$($state.label) points to '$($state.item.normalized)', which does not exist." -Severity warning -ComponentId $state.component -EvidenceIds @($environmentEvidenceId)))
    }
}

if (
    $nvmPresent -and
    $nvmHome.configured -and
    -not $nvmHome.invalid -and
    -not $nvmHome.unresolved -and
    $nvmHome.exists -ne $false -and
    -not $nvmHome.onProcessPath
) {
    $warnings.Add((New-AuditIssue -Code 'NVM_HOME_NOT_ON_PROCESS_PATH' -Message "NVM_HOME is configured as '$($nvmHome.normalized)' but no equivalent entry exists in the effective Process PATH." -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @($environmentEvidenceId)))
}

if (
    $nvmPresent -and
    $nvmSymlink.configured -and
    -not $nvmSymlink.invalid -and
    -not $nvmSymlink.unresolved -and
    $nvmSymlink.exists -ne $false -and
    -not $nvmSymlink.onProcessPath
) {
    $warnings.Add((New-AuditIssue -Code 'NVM_SYMLINK_NOT_ON_PROCESS_PATH' -Message "NVM_SYMLINK is configured as '$($nvmSymlink.normalized)' but no equivalent entry exists in the effective Process PATH." -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @($environmentEvidenceId)))
}

if (
    $pnpmPresent -and
    $pnpmHome.configured -and
    -not $pnpmHome.invalid -and
    -not $pnpmHome.unresolved -and
    $pnpmHome.exists -ne $false -and
    -not $pnpmHome.onProcessPath
) {
    $warnings.Add((New-AuditIssue -Code 'PNPM_HOME_NOT_ON_PROCESS_PATH' -Message "PNPM_HOME is configured as '$($pnpmHome.normalized)' but no equivalent entry exists in the effective Process PATH." -Severity warning -ComponentId 'pnpm' -EvidenceIds @($environmentEvidenceId)))
}

$nodeEvidenceId = 'javascript-precedence.command.node'
$evidence.Add((New-AuditEvidence -EvidenceId $nodeEvidenceId -Type derived -Source 'Node.js PATH/environment precedence' -Captured $null -Attributes @{
    componentPresent = $nodePresent
    nvmPresent = $nvmPresent
    relationship = $nodeRelationship
}))

$npmEvidenceId = 'javascript-precedence.command.npm'
$evidence.Add((New-AuditEvidence -EvidenceId $npmEvidenceId -Type derived -Source 'npm PATH precedence' -Captured $null -Attributes @{
    componentPresent = $npmPresent
    relationship = $npmRelationship
}))

$pnpmEvidenceId = 'javascript-precedence.command.pnpm'
$evidence.Add((New-AuditEvidence -EvidenceId $pnpmEvidenceId -Type derived -Source 'pnpm PATH/environment precedence' -Captured $null -Attributes @{
    componentPresent = $pnpmPresent
    relationship = $pnpmRelationship
}))

Add-CommandCollisionFinding -Relationship $nodeRelationship -Code 'NODE_PATH_COLLISION' -ComponentId 'node' -EvidenceId $nodeEvidenceId
Add-CommandCollisionFinding -Relationship $npmRelationship -Code 'NPM_PATH_COLLISION' -ComponentId 'npm' -EvidenceId $npmEvidenceId
Add-CommandCollisionFinding -Relationship $pnpmRelationship -Code 'PNPM_PATH_COLLISION' -ComponentId 'pnpm' -EvidenceId $pnpmEvidenceId

if (
    $nvmPresent -and
    $nodePresent -and
    $nvmSymlink.configured -and
    $nvmSymlink.onProcessPath -and
    $nodeRelationship.relationship -eq 'mismatch' -and
    [string]$nodeRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'NODE_BYPASSES_NVM_SYMLINK' -Message "NVM is present and NVM_SYMLINK '$($nvmSymlink.normalized)' is at $(Format-PathPosition -Position $nvmSymlink.firstPathPosition), but active Node.js resolves to '$($nodeRelationship.activePath)' at $(Format-PathPosition -Position $nodeRelationship.activePathPosition)." -Severity warning -ComponentId 'node' -EvidenceIds @($environmentEvidenceId, $nodeEvidenceId)))
}

if (
    $pnpmPresent -and
    $pnpmHome.configured -and
    $pnpmHome.onProcessPath -and
    $pnpmRelationship.relationship -eq 'mismatch' -and
    [string]$pnpmRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'PNPM_HOME_PRECEDENCE_MISMATCH' -Message "PNPM_HOME '$($pnpmHome.normalized)' is at $(Format-PathPosition -Position $pnpmHome.firstPathPosition), but active pnpm resolves to '$($pnpmRelationship.activePath)' at $(Format-PathPosition -Position $pnpmRelationship.activePathPosition)." -Severity warning -ComponentId 'pnpm' -EvidenceIds @($environmentEvidenceId, $pnpmEvidenceId)))
}

$summaryEvidenceId = 'javascript-precedence.summary'
$evidence.Insert(0, (New-AuditEvidence -EvidenceId $summaryEvidenceId -Type derived -Source 'JavaScript PATH/environment precedence summary' -Captured $null -Attributes @{
    dependencies = [pscustomobject]$dependencyStates
    nvmPresent = $nvmPresent
    nodePresent = $nodePresent
    npmPresent = $npmPresent
    pnpmPresent = $pnpmPresent
    nvmHomeConfigured = $nvmHome.configured
    nvmSymlinkConfigured = $nvmSymlink.configured
    pnpmHomeConfigured = $pnpmHome.configured
    nodeRelationship = $nodeRelationship.relationship
    pnpmRelationship = $pnpmRelationship.relationship
    warningCount = $warnings.Count
    readOnly = $true
    duplicatedRuntimeDiscovery = $false
}))

$status = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial

return [pscustomobject][ordered]@{
    providerId = 'javascript.precedence'
    category   = 'environment'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
