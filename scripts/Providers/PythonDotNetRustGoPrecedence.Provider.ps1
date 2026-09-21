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
        providerId = 'python-dotnet-rust-go.precedence'
        category   = 'environment'
        order      = 33
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

function Get-ProviderComponent {
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

function ConvertTo-ComparisonPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $normalized = $Path.Trim().Trim('"').Replace('/', '\')
    if ($normalized.StartsWith('\\')) {
        $tail = $normalized.Substring(2) -replace '\\{2,}', '\'
        $normalized = "\\$tail"
    }
    else {
        $normalized = $normalized -replace '\\{2,}', '\'
    }

    if ($normalized.Length -gt 3) {
        $normalized = $normalized.TrimEnd('\')
    }

    return $normalized.ToLowerInvariant()
}

function Get-EnvironmentPathState {
    param(
        [AllowNull()][object]$EnvironmentProvider,
        [Parameter(Mandatory)][string]$Name
    )

    $evidenceId = "environment.$($Name.ToLowerInvariant())"
    $variableEvidence = Get-ProviderEvidence -Provider $EnvironmentProvider -EvidenceId $evidenceId

    $result = [pscustomobject][ordered]@{
        name              = $Name
        evidenceId        = $evidenceId
        configured        = $false
        scope             = $null
        state             = 'unavailable'
        normalized        = $null
        comparisonKey     = $null
        exists            = $null
        invalid           = $false
        unresolved        = $false
        pathItems         = @()
        missingPathCount  = 0
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
    $result.pathItems = @($selected.pathItems)
    $result.missingPathCount = [int]$selected.missingPathCount

    return $result
}

function Get-ChildPathState {
    param(
        [AllowNull()][object]$RootState,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $result = [pscustomobject][ordered]@{
        rootName      = $(if ($RootState) { $RootState.name } else { $null })
        configured    = $(if ($RootState) { [bool]$RootState.configured } else { $false })
        scope         = $(if ($RootState) { $RootState.scope } else { $null })
        normalized    = $null
        comparisonKey = $null
        invalid       = $(if ($RootState) { [bool]$RootState.invalid } else { $false })
        unresolved    = $(if ($RootState) { [bool]$RootState.unresolved } else { $false })
    }

    if (
        $null -eq $RootState -or
        -not $RootState.configured -or
        $RootState.invalid -or
        $RootState.unresolved -or
        [string]::IsNullOrWhiteSpace([string]$RootState.normalized)
    ) {
        return $result
    }

    $root = ([string]$RootState.normalized).TrimEnd('\', '/')
    $relative = $RelativePath.Trim('\', '/').Replace('/', '\')
    $result.normalized = "$root\$relative"
    $result.comparisonKey = ConvertTo-ComparisonPath -Path $result.normalized
    return $result
}

function Get-CommandRelationship {
    param(
        [AllowNull()][object]$PathProvider,
        [Parameter(Mandatory)][string]$Command,
        [AllowNull()][string[]]$ExpectedComparisonKeys = @()
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
        expectedComparisonKeys     = @($ExpectedComparisonKeys)
        matchedExpectedKey         = $null
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

    $expected = @(
        $ExpectedComparisonKeys |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique
    )

    if ($expected.Count -eq 0) {
        $result.relationship = 'not-configured'
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

    foreach ($expectedKey in $expected) {
        if ([string]::Equals(
            [string]$result.activePathComparisonKey,
            [string]$expectedKey,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $result.matchedExpectedKey = [string]$expectedKey
            $result.relationship = 'aligned'
            return $result
        }
    }

    $result.relationship = 'mismatch'
    return $result
}

function Test-PathUnderRoot {
    param(
        [AllowNull()][string]$Path,
        [AllowNull()][string]$Root,
        [AllowNull()][string]$RequiredChild
    )

    $pathKey = ConvertTo-ComparisonPath -Path $Path
    $rootKey = ConvertTo-ComparisonPath -Path $Root

    if (
        [string]::IsNullOrWhiteSpace($pathKey) -or
        [string]::IsNullOrWhiteSpace($rootKey)
    ) {
        return $null
    }

    $prefix = $rootKey.TrimEnd('\') + '\'
    if (-not [string]::IsNullOrWhiteSpace($RequiredChild)) {
        $prefix += $RequiredChild.Trim('\', '/').Replace('/', '\').ToLowerInvariant().TrimEnd('\') + '\'
    }

    return $pathKey.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
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

    $shadowedText = @(
        @($Relationship.shadowedResolutions) |
            Where-Object { [bool]$_.pathBased } |
            ForEach-Object {
                "'$($_.path)' at $(Format-PathPosition -Position $_.pathPosition)"
            }
    ) -join '; '

    $warnings.Add((New-AuditIssue -Code $Code -Message "Command '$($Relationship.command)' resolves actively to '$($Relationship.activePath)' at $(Format-PathPosition -Position $Relationship.activePathPosition) and shadows: $shadowedText." -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
}

$pythonProvider = Get-PreviousProviderResult -ProviderId 'python.ecosystem'
$dotnetProvider = Get-PreviousProviderResult -ProviderId 'dotnet.toolchain'
$rustGoProvider = Get-PreviousProviderResult -ProviderId 'rust-go.toolchains'
$pathProvider = Get-PreviousProviderResult -ProviderId 'path.precedence'
$environmentProvider = Get-PreviousProviderResult -ProviderId 'environment.baseline'

$dependencyStates = [ordered]@{
    pythonEcosystem      = ($null -ne $pythonProvider)
    dotnetToolchain      = ($null -ne $dotnetProvider)
    rustGoToolchains     = ($null -ne $rustGoProvider)
    pathPrecedence       = ($null -ne $pathProvider)
    environmentBaseline  = ($null -ne $environmentProvider)
}

foreach ($dependencyName in @($dependencyStates.Keys)) {
    if (-not [bool]$dependencyStates[$dependencyName]) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'RUNTIME_PRECEDENCE_DEPENDENCY_MISSING' -Message "Python/.NET/Rust/Go precedence analysis could not find required prior provider '$dependencyName'." -Severity warning -EvidenceIds @('python-dotnet-rust-go-precedence.summary')))
    }
}

foreach ($dependency in @($pythonProvider, $dotnetProvider, $rustGoProvider, $pathProvider, $environmentProvider)) {
    if ($null -ne $dependency -and [string]$dependency.status -eq 'failed') {
        $hasPartial = $true
    }
}

$pyenvRoot = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -Name 'PYENV_ROOT'
$dotnetRoot = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -Name 'DOTNET_ROOT'
$dotnetRootX64 = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -Name 'DOTNET_ROOT_X64'
$dotnetRootX86 = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -Name 'DOTNET_ROOT_X86'
$cargoHome = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -Name 'CARGO_HOME'
$rustupHome = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -Name 'RUSTUP_HOME'
$goRoot = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -Name 'GOROOT'
$goPath = Get-EnvironmentPathState -EnvironmentProvider $environmentProvider -Name 'GOPATH'

$pyenvBin = Get-ChildPathState -RootState $pyenvRoot -RelativePath 'bin'
$cargoBin = Get-ChildPathState -RootState $cargoHome -RelativePath 'bin'
$goBin = Get-ChildPathState -RootState $goRoot -RelativePath 'bin'

$pythonComponent = Get-ProviderComponent -Provider $pythonProvider -ComponentId 'python'
$pyenvComponent = Get-ProviderComponent -Provider $pythonProvider -ComponentId 'pyenv-win'
$dotnetComponent = Get-ProviderComponent -Provider $dotnetProvider -ComponentId 'dotnet-sdk'
$rustupComponent = Get-ProviderComponent -Provider $rustGoProvider -ComponentId 'rustup'
$rustcComponent = Get-ProviderComponent -Provider $rustGoProvider -ComponentId 'rustc'
$cargoComponent = Get-ProviderComponent -Provider $rustGoProvider -ComponentId 'cargo'
$goComponent = Get-ProviderComponent -Provider $rustGoProvider -ComponentId 'go'

function Test-ComponentPresent {
    param([AllowNull()][object]$Component)

    return (
        $null -ne $Component -and
        [string]$Component.state -in @('present', 'partial')
    )
}

$pythonPresent = Test-ComponentPresent -Component $pythonComponent
$pyenvPresent = Test-ComponentPresent -Component $pyenvComponent
$dotnetPresent = Test-ComponentPresent -Component $dotnetComponent
$rustupPresent = Test-ComponentPresent -Component $rustupComponent
$rustcPresent = Test-ComponentPresent -Component $rustcComponent
$cargoPresent = Test-ComponentPresent -Component $cargoComponent
$goPresent = Test-ComponentPresent -Component $goComponent

$pythonRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'python'
$pyenvRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'pyenv' -ExpectedComparisonKeys @($pyenvBin.comparisonKey)

$dotnetRootStates = @($dotnetRoot, $dotnetRootX64, $dotnetRootX86)
$usableDotnetRoots = @(
    $dotnetRootStates |
        Where-Object {
            $_.configured -and
            -not $_.invalid -and
            -not $_.unresolved -and
            -not [string]::IsNullOrWhiteSpace([string]$_.comparisonKey)
        }
)
$dotnetExpectedKeys = @($usableDotnetRoots | ForEach-Object { $_.comparisonKey })
$dotnetRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'dotnet' -ExpectedComparisonKeys $dotnetExpectedKeys

$rustupRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'rustup' -ExpectedComparisonKeys @($cargoBin.comparisonKey)
$rustcRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'rustc' -ExpectedComparisonKeys @($cargoBin.comparisonKey)
$cargoRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'cargo' -ExpectedComparisonKeys @($cargoBin.comparisonKey)
$goRelationship = Get-CommandRelationship -PathProvider $pathProvider -Command 'go' -ExpectedComparisonKeys @($goBin.comparisonKey)

$pythonInsidePyenv = $null
if (
    $pyenvRoot.configured -and
    $pythonRelationship.activePathBased -and
    -not [string]::IsNullOrWhiteSpace([string]$pythonRelationship.activePath)
) {
    $pythonInsidePyenv = Test-PathUnderRoot -Path $pythonRelationship.activePath -Root $pyenvRoot.normalized -RequiredChild 'versions'
}

$dotnetMatches = @()
if (-not [string]::IsNullOrWhiteSpace([string]$dotnetRelationship.matchedExpectedKey)) {
    $dotnetMatches = @(
        $usableDotnetRoots |
            Where-Object {
                [string]::Equals(
                    [string]$_.comparisonKey,
                    [string]$dotnetRelationship.matchedExpectedKey,
                    [StringComparison]::OrdinalIgnoreCase
                )
            } |
            ForEach-Object { $_.name }
    )
}

$rustToolchainEvidence = Get-ProviderEvidence -Provider $rustGoProvider -EvidenceId 'rust.toolchains'
$rustToolchainPaths = @()
if ($null -ne $rustToolchainEvidence -and $null -ne $rustToolchainEvidence.attributes) {
    $rustToolchainPaths = @(
        @($rustToolchainEvidence.attributes.toolchains) |
            ForEach-Object { [string]$_.path } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

$rustToolchainRootRelationship = 'not-configured'
$rustToolchainOutsidePaths = @()
if (
    $rustupHome.configured -and
    -not $rustupHome.invalid -and
    -not $rustupHome.unresolved -and
    $rustToolchainPaths.Count -gt 0
) {
    $outside = [System.Collections.Generic.List[string]]::new()
    foreach ($toolchainPath in $rustToolchainPaths) {
        $inside = Test-PathUnderRoot -Path $toolchainPath -Root $rustupHome.normalized -RequiredChild 'toolchains'
        if ($inside -eq $false) {
            $outside.Add($toolchainPath)
        }
    }

    $rustToolchainOutsidePaths = $outside.ToArray()
    $rustToolchainRootRelationship = if ($outside.Count -eq 0) { 'aligned' } else { 'mismatch' }
}
elseif ($rustToolchainPaths.Count -gt 0) {
    $rustToolchainRootRelationship = 'root-not-configured'
}

$goEnvironmentEvidence = Get-ProviderEvidence -Provider $rustGoProvider -EvidenceId 'go.environment'
$observedGoRoot = $null
$observedGoPath = $null
$goEnvironmentStatus = 'unavailable'
$goToolchainGuard = $null
if ($null -ne $goEnvironmentEvidence -and $null -ne $goEnvironmentEvidence.attributes) {
    $observedGoRoot = $goEnvironmentEvidence.attributes.GOROOT
    $observedGoPath = $goEnvironmentEvidence.attributes.GOPATH
    $goEnvironmentStatus = [string]$goEnvironmentEvidence.attributes.status
    $goToolchainGuard = $goEnvironmentEvidence.attributes.GOTOOLCHAIN
}

$goRootObservedRelationship = 'not-configured'
if (
    $goRoot.configured -and
    -not [string]::IsNullOrWhiteSpace([string]$observedGoRoot)
) {
    $goRootObservedRelationship = if (
        [string]::Equals(
            [string](ConvertTo-ComparisonPath -Path $goRoot.normalized),
            [string](ConvertTo-ComparisonPath -Path ([string]$observedGoRoot)),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) { 'aligned' } else { 'mismatch' }
}

$goPathObservedRelationship = 'not-configured'
if (
    $goPath.configured -and
    -not [string]::IsNullOrWhiteSpace([string]$observedGoPath)
) {
    $configuredGoPath = ([string]$goPath.normalized).ToLowerInvariant()
    $observedGoPathKey = @(
        ([string]$observedGoPath -split ';') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { ConvertTo-ComparisonPath -Path $_ }
    ) -join ';'

    $goPathObservedRelationship = if (
        [string]::Equals(
            $configuredGoPath,
            $observedGoPathKey,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) { 'aligned' } else { 'mismatch' }
}

$environmentEvidenceId = 'python-dotnet-rust-go-precedence.environment'
$evidence.Add((New-AuditEvidence -EvidenceId $environmentEvidenceId -Type derived -Source 'Python/.NET/Rust/Go approved environment relationships' -Captured $null -Attributes @{
    pyenvRoot = $pyenvRoot
    pyenvBin = $pyenvBin
    dotnetRoots = @($dotnetRootStates)
    usableDotnetRootCount = $usableDotnetRoots.Count
    cargoHome = $cargoHome
    cargoBin = $cargoBin
    rustupHome = $rustupHome
    rustupHomePathRequired = $false
    goRoot = $goRoot
    goBin = $goBin
    goPath = $goPath
    goPathRequiredOnProcessPath = $false
}))

$pythonEvidenceId = 'python-dotnet-rust-go-precedence.command.python'
$evidence.Add((New-AuditEvidence -EvidenceId $pythonEvidenceId -Type derived -Source 'PYENV_ROOT and Python command relationship' -Captured $null -Attributes @{
    componentPresent = $pythonPresent
    pyenvPresent = $pyenvPresent
    relationship = $pythonRelationship
    insideConfiguredPyenvVersions = $pythonInsidePyenv
}))

$pyenvEvidenceId = 'python-dotnet-rust-go-precedence.command.pyenv'
$evidence.Add((New-AuditEvidence -EvidenceId $pyenvEvidenceId -Type derived -Source 'PYENV_ROOT and pyenv PATH precedence' -Captured $null -Attributes @{
    componentPresent = $pyenvPresent
    relationship = $pyenvRelationship
}))

$dotnetEvidenceId = 'python-dotnet-rust-go-precedence.command.dotnet'
$evidence.Add((New-AuditEvidence -EvidenceId $dotnetEvidenceId -Type derived -Source '.NET root variables and dotnet PATH precedence' -Captured $null -Attributes @{
    componentPresent = $dotnetPresent
    relationship = $dotnetRelationship
    configuredRootNames = @($usableDotnetRoots | ForEach-Object { $_.name })
    matchedRootNames = @($dotnetMatches)
    architectureAssumed = $false
}))

$rustEvidenceId = 'python-dotnet-rust-go-precedence.rust'
$evidence.Add((New-AuditEvidence -EvidenceId $rustEvidenceId -Type derived -Source 'CARGO_HOME/RUSTUP_HOME and Rust command/toolchain relationships' -Captured $null -Attributes @{
    rustupPresent = $rustupPresent
    rustcPresent = $rustcPresent
    cargoPresent = $cargoPresent
    rustupRelationship = $rustupRelationship
    rustcRelationship = $rustcRelationship
    cargoRelationship = $cargoRelationship
    rustToolchainRootRelationship = $rustToolchainRootRelationship
    rustToolchainPaths = @($rustToolchainPaths)
    rustToolchainOutsidePaths = @($rustToolchainOutsidePaths)
}))

$goEvidenceId = 'python-dotnet-rust-go-precedence.go'
$evidence.Add((New-AuditEvidence -EvidenceId $goEvidenceId -Type derived -Source 'GOROOT/GOPATH and active Go relationships' -Captured $null -Attributes @{
    componentPresent = $goPresent
    commandRelationship = $goRelationship
    environmentStatus = $goEnvironmentStatus
    observedGOROOT = $observedGoRoot
    observedGOPATH = $observedGoPath
    gorootObservedRelationship = $goRootObservedRelationship
    gopathObservedRelationship = $goPathObservedRelationship
    GOTOOLCHAIN = $goToolchainGuard
    autoDownloadAllowed = $false
}))

Add-CommandCollisionFinding -Relationship $pythonRelationship -Code 'PYTHON_PATH_COLLISION' -ComponentId 'python' -EvidenceId $pythonEvidenceId
Add-CommandCollisionFinding -Relationship $pyenvRelationship -Code 'PYENV_PATH_COLLISION' -ComponentId 'pyenv-win' -EvidenceId $pyenvEvidenceId
Add-CommandCollisionFinding -Relationship $dotnetRelationship -Code 'DOTNET_PATH_COLLISION' -ComponentId 'dotnet-sdk' -EvidenceId $dotnetEvidenceId
Add-CommandCollisionFinding -Relationship $rustupRelationship -Code 'RUSTUP_PATH_COLLISION' -ComponentId 'rustup' -EvidenceId $rustEvidenceId
Add-CommandCollisionFinding -Relationship $rustcRelationship -Code 'RUSTC_PATH_COLLISION' -ComponentId 'rustc' -EvidenceId $rustEvidenceId
Add-CommandCollisionFinding -Relationship $cargoRelationship -Code 'CARGO_PATH_COLLISION' -ComponentId 'cargo' -EvidenceId $rustEvidenceId
Add-CommandCollisionFinding -Relationship $goRelationship -Code 'GO_PATH_COLLISION' -ComponentId 'go' -EvidenceId $goEvidenceId

if (
    $pyenvPresent -and
    $pyenvRoot.configured -and
    $pyenvRelationship.relationship -eq 'mismatch' -and
    [string]$pyenvRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'PYENV_ROOT_PRECEDENCE_MISMATCH' -Message "PYENV_ROOT expects pyenv under '$($pyenvBin.normalized)', but active pyenv resolves to '$($pyenvRelationship.activePath)' at $(Format-PathPosition -Position $pyenvRelationship.activePathPosition)." -Severity warning -ComponentId 'pyenv-win' -EvidenceIds @($environmentEvidenceId, $pyenvEvidenceId)))
}

if (
    $pyenvPresent -and
    $pythonPresent -and
    $pyenvRoot.configured -and
    $pythonInsidePyenv -eq $false -and
    [string]$pythonRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'PYTHON_BYPASSES_PYENV_ROOT' -Message "pyenv is present with PYENV_ROOT '$($pyenvRoot.normalized)', but active Python resolves to '$($pythonRelationship.activePath)' at $(Format-PathPosition -Position $pythonRelationship.activePathPosition), outside the configured pyenv versions tree." -Severity warning -ComponentId 'python' -EvidenceIds @($environmentEvidenceId, $pythonEvidenceId)))
}

if (
    $dotnetPresent -and
    $usableDotnetRoots.Count -gt 0 -and
    $dotnetRelationship.relationship -eq 'mismatch' -and
    [string]$dotnetRelationship.activePathMappingStatus -like 'mapped*'
) {
    $rootDescription = @(
        $usableDotnetRoots |
            ForEach-Object { "$($_.name)='$($_.normalized)'" }
    ) -join ', '

    $warnings.Add((New-AuditIssue -Code 'DOTNET_ROOT_PRECEDENCE_MISMATCH' -Message "Active dotnet resolves to '$($dotnetRelationship.activePath)' at $(Format-PathPosition -Position $dotnetRelationship.activePathPosition), outside all configured .NET roots ($rootDescription). No architecture-specific root was assumed." -Severity warning -ComponentId 'dotnet-sdk' -EvidenceIds @($environmentEvidenceId, $dotnetEvidenceId)))
}

foreach ($rustCommand in @(
    [pscustomobject]@{ Present=$rustupPresent; Relationship=$rustupRelationship; Code='RUSTUP_CARGO_HOME_PRECEDENCE_MISMATCH'; Component='rustup'; Label='rustup' },
    [pscustomobject]@{ Present=$rustcPresent; Relationship=$rustcRelationship; Code='RUSTC_CARGO_HOME_PRECEDENCE_MISMATCH'; Component='rustc'; Label='rustc' },
    [pscustomobject]@{ Present=$cargoPresent; Relationship=$cargoRelationship; Code='CARGO_HOME_PRECEDENCE_MISMATCH'; Component='cargo'; Label='cargo' }
)) {
    if (
        $rustCommand.Present -and
        $cargoHome.configured -and
        $rustCommand.Relationship.relationship -eq 'mismatch' -and
        [string]$rustCommand.Relationship.activePathMappingStatus -like 'mapped*'
    ) {
        $warnings.Add((New-AuditIssue -Code $rustCommand.Code -Message "CARGO_HOME expects $($rustCommand.Label) under '$($cargoBin.normalized)', but active $($rustCommand.Label) resolves to '$($rustCommand.Relationship.activePath)' at $(Format-PathPosition -Position $rustCommand.Relationship.activePathPosition)." -Severity warning -ComponentId $rustCommand.Component -EvidenceIds @($environmentEvidenceId, $rustEvidenceId)))
    }
}

if ($rustToolchainRootRelationship -eq 'mismatch') {
    $warnings.Add((New-AuditIssue -Code 'RUSTUP_HOME_TOOLCHAIN_MISMATCH' -Message "RUSTUP_HOME is '$($rustupHome.normalized)', but one or more discovered rustup-managed toolchains fall outside its 'toolchains' subtree: $($rustToolchainOutsidePaths -join ', ')." -Severity warning -ComponentId 'rust-toolchains' -EvidenceIds @($environmentEvidenceId, $rustEvidenceId)))
}

if (
    $goPresent -and
    $goRoot.configured -and
    $goRelationship.relationship -eq 'mismatch' -and
    [string]$goRelationship.activePathMappingStatus -like 'mapped*'
) {
    $warnings.Add((New-AuditIssue -Code 'GO_GOROOT_PRECEDENCE_MISMATCH' -Message "GOROOT expects go under '$($goBin.normalized)', but active go resolves to '$($goRelationship.activePath)' at $(Format-PathPosition -Position $goRelationship.activePathPosition)." -Severity warning -ComponentId 'go' -EvidenceIds @($environmentEvidenceId, $goEvidenceId)))
}

$summaryEvidenceId = 'python-dotnet-rust-go-precedence.summary'
$evidence.Insert(0, (New-AuditEvidence -EvidenceId $summaryEvidenceId -Type derived -Source 'Python/.NET/Rust/Go PATH and environment precedence summary' -Captured $null -Attributes @{
    dependencies = [pscustomobject]$dependencyStates
    pythonPresent = $pythonPresent
    pyenvPresent = $pyenvPresent
    dotnetPresent = $dotnetPresent
    rustupPresent = $rustupPresent
    rustcPresent = $rustcPresent
    cargoPresent = $cargoPresent
    goPresent = $goPresent
    pyenvRootConfigured = $pyenvRoot.configured
    dotnetConfiguredRootCount = $usableDotnetRoots.Count
    cargoHomeConfigured = $cargoHome.configured
    rustupHomeConfigured = $rustupHome.configured
    gorootConfigured = $goRoot.configured
    gopathConfigured = $goPath.configured
    dotnetArchitectureAssumed = $false
    rustupHomePathRequired = $false
    gopathPathRequired = $false
    goToolchainAutoDownloadAllowed = $false
    warningCount = $warnings.Count
    readOnly = $true
    duplicatedRuntimeDiscovery = $false
    directEnvironmentAccess = $false
    filesystemProbes = $false
}))

$status = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial

return [pscustomobject][ordered]@{
    providerId = 'python-dotnet-rust-go.precedence'
    category   = 'environment'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
