[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$providerPath = Join-Path $root 'scripts\Providers\PythonDotNetRustGoPrecedence.Provider.ps1'
$pythonProviderPath = Join-Path $root 'scripts\Providers\PythonEcosystem.Provider.ps1'
$dotnetProviderPath = Join-Path $root 'scripts\Providers\DotNetToolchain.Provider.ps1'
$rustGoProviderPath = Join-Path $root 'scripts\Providers\RustGoToolchains.Provider.ps1'
$pathProviderPath = Join-Path $root 'scripts\Providers\PathPrecedence.Provider.ps1'
$environmentProviderPath = Join-Path $root 'scripts\Providers\EnvironmentBaseline.Provider.ps1'
$jvmMobileProviderPath = Join-Path $root 'scripts\Providers\JvmMobilePrecedence.Provider.ps1'
$fixturePath = Join-Path $PSScriptRoot 'runtime-precedence-cases.json'

Import-Module $corePath -Force
$fixture = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json

function Get-OptionalPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function New-UnsetScopeValue {
    param([Parameter(Mandatory)][string]$Scope)

    return [pscustomobject][ordered]@{
        scope = $Scope
        state = 'unset'
        raw = $null
        expanded = $null
        normalized = $null
        comparisonKey = $null
        exists = $null
        pathItems = @()
        missingPathCount = 0
        hasUnresolvedVariable = $false
        unresolvedVariables = @()
        unapprovedReferenceCount = 0
        isConfigured = $false
        isInvalid = $false
    }
}

function New-EnvironmentVariableEvidence {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Definition
    )

    $processScope = New-UnsetScopeValue -Scope 'process'

    if ($null -ne $Definition) {
        $value = [string](Get-OptionalPropertyValue -InputObject $Definition -Name 'value')
        $existsValue = Get-OptionalPropertyValue -InputObject $Definition -Name 'exists'
        $segments = if ($Name -eq 'GOPATH') { @($value -split ';') } else { @($value) }
        $pathItems = [System.Collections.Generic.List[object]]::new()

        foreach ($segment in $segments) {
            if ([string]::IsNullOrWhiteSpace([string]$segment)) {
                continue
            }

            $pathItems.Add((ConvertTo-AuditPathEntry -Scope process -Position $pathItems.Count -Entry ([string]$segment) -EnvironmentValues @{}))
        }

        $normalized = @($pathItems | ForEach-Object { $_.normalized }) -join ';'
        $comparisonKey = if ([string]::IsNullOrWhiteSpace($normalized)) { $null } else { $normalized.ToLowerInvariant() }

        $processScope = [pscustomobject][ordered]@{
            scope = 'process'
            state = 'value'
            raw = $value
            expanded = @($pathItems | ForEach-Object { $_.expanded }) -join ';'
            normalized = $normalized
            comparisonKey = $comparisonKey
            exists = $(if ($Name -eq 'GOPATH') { $null } elseif ($null -eq $existsValue) { $null } else { [bool]$existsValue })
            pathItems = $pathItems.ToArray()
            missingPathCount = $(if ($existsValue -eq $false) { $pathItems.Count } else { 0 })
            hasUnresolvedVariable = $false
            unresolvedVariables = @()
            unapprovedReferenceCount = 0
            isConfigured = $true
            isInvalid = ($pathItems.Count -eq 0)
        }
    }

    return New-AuditEvidence -EvidenceId "environment.$($Name.ToLowerInvariant())" -Type environment -Source $Name -Captured $null -Attributes @{
        scopes = @(
            $processScope,
            (New-UnsetScopeValue -Scope 'user'),
            (New-UnsetScopeValue -Scope 'machine')
        )
    }
}

function New-SyntheticEnvironmentProvider {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][object]$PathModel
    )

    $environmentEvidence = [System.Collections.Generic.List[object]]::new()

    foreach ($name in @(
        'PYENV_ROOT',
        'DOTNET_ROOT',
        'DOTNET_ROOT_X64',
        'DOTNET_ROOT_X86',
        'CARGO_HOME',
        'RUSTUP_HOME',
        'GOROOT',
        'GOPATH'
    )) {
        $definition = Get-OptionalPropertyValue -InputObject $Case.environment -Name $name
        $environmentEvidence.Add((New-EnvironmentVariableEvidence -Name $name -Definition $definition))
    }

    $environmentEvidence.Add((New-AuditEvidence -EvidenceId 'path.process.health' -Type path -Source 'process PATH' -Captured $null -Attributes @{
        entryCount = $PathModel.entryCount
        duplicateCount = $PathModel.duplicateCount
        missingCount = $PathModel.missingCount
        unresolvedVariableCount = $PathModel.unresolvedVariableCount
        entries = $PathModel.entries
    }))

    return [pscustomobject][ordered]@{
        providerId = 'environment.baseline'
        category = 'environment'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @()
        warnings = @()
        errors = @()
        evidence = $environmentEvidence.ToArray()
    }
}

function Get-CaseCommandResolutions {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][string]$Command
    )

    $value = Get-OptionalPropertyValue -InputObject $Case.resolutions -Name $Command
    if ($null -eq $value) {
        return @()
    }

    return @($value)
}

function New-SyntheticComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$State,
        [AllowNull()][string]$Command,
        [Parameter(Mandatory)][object]$Case
    )

    return [pscustomobject][ordered]@{
        componentId = $ComponentId
        state = $State
        commandResolutions = $(if ([string]::IsNullOrWhiteSpace($Command)) { @() } else { @(Get-CaseCommandResolutions -Case $Case -Command $Command) })
    }
}

function New-SyntheticPythonProvider {
    param([Parameter(Mandatory)][object]$Case)

    return [pscustomobject][ordered]@{
        providerId = 'python.ecosystem'
        category = 'runtime'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @(
            (New-SyntheticComponent -ComponentId 'python' -State ([string]$Case.components.python) -Command 'python' -Case $Case),
            (New-SyntheticComponent -ComponentId 'pyenv-win' -State ([string]$Case.components.'pyenv-win') -Command 'pyenv' -Case $Case)
        )
        warnings = @()
        errors = @()
        evidence = @()
    }
}

function New-SyntheticDotNetProvider {
    param([Parameter(Mandatory)][object]$Case)

    return [pscustomobject][ordered]@{
        providerId = 'dotnet.toolchain'
        category = 'runtime'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @(
            (New-SyntheticComponent -ComponentId 'dotnet-sdk' -State ([string]$Case.components.'dotnet-sdk') -Command 'dotnet' -Case $Case)
        )
        warnings = @()
        errors = @()
        evidence = @()
    }
}

function New-SyntheticRustGoProvider {
    param([Parameter(Mandatory)][object]$Case)

    $toolchainPaths = @($Case.rustToolchainPaths)
    $toolchains = @(
        $toolchainPaths |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    name = 'synthetic'
                    active = $true
                    default = $true
                    override = $false
                    channel = 'stable'
                    version = '1.0.0'
                    path = [string]$_
                }
            }
    )

    $goObserved = Get-OptionalPropertyValue -InputObject $Case -Name 'goObserved'
    $goEvidenceAttributes = if ($null -eq $goObserved) {
        @{
            status = 'not-applicable'
            GOROOT = $null
            GOPATH = $null
            GOTOOLCHAIN = 'local'
            rawOutputRetained = $false
        }
    }
    else {
        @{
            status = [string]$goObserved.status
            GOROOT = $goObserved.GOROOT
            GOPATH = $goObserved.GOPATH
            GOTOOLCHAIN = $goObserved.GOTOOLCHAIN
            rawOutputRetained = $false
        }
    }

    return [pscustomobject][ordered]@{
        providerId = 'rust-go.toolchains'
        category = 'runtime'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @(
            (New-SyntheticComponent -ComponentId 'rustup' -State ([string]$Case.components.rustup) -Command 'rustup' -Case $Case),
            (New-SyntheticComponent -ComponentId 'rustc' -State ([string]$Case.components.rustc) -Command 'rustc' -Case $Case),
            (New-SyntheticComponent -ComponentId 'cargo' -State ([string]$Case.components.cargo) -Command 'cargo' -Case $Case),
            (New-SyntheticComponent -ComponentId 'go' -State ([string]$Case.components.go) -Command 'go' -Case $Case)
        )
        warnings = @()
        errors = @()
        evidence = @(
            (New-AuditEvidence -EvidenceId 'rust.toolchains' -Type derived -Source 'synthetic rust toolchains' -Captured $null -Attributes @{
                status = $(if ($toolchains.Count -gt 0) { 'success' } else { 'not-applicable' })
                toolchainCount = $toolchains.Count
                toolchains = $toolchains
            }),
            (New-AuditEvidence -EvidenceId 'go.environment' -Type derived -Source 'synthetic go environment' -Captured $null -Attributes $goEvidenceAttributes)
        )
    }
}

function New-SyntheticPathProvider {
    param(
        [Parameter(Mandatory)][object]$Case,
        [Parameter(Mandatory)][object]$PathModel
    )

    $pathEvidence = [System.Collections.Generic.List[object]]::new()

    foreach ($commandProperty in @($Case.resolutions.PSObject.Properties)) {
        $command = [string]$commandProperty.Name
        $resolutions = @($commandProperty.Value)
        if ($resolutions.Count -eq 0) {
            continue
        }

        $analysis = Get-AuditCommandPathAnalysis -CommandResolutions $resolutions -ProcessPathEntries @($PathModel.entries)

        $pathEvidence.Add((New-AuditEvidence -EvidenceId "path-precedence.command.$command" -Type derived -Source "synthetic command PATH precedence: $command" -Captured $null -Attributes @{
            command = $analysis.command
            resolutionCount = $analysis.resolutionCount
            pathBasedResolutionCount = $analysis.pathBasedResolutionCount
            mappedResolutionCount = $analysis.mappedResolutionCount
            unmappedPathResolutionCount = $analysis.unmappedPathResolutionCount
            hasResolutionCollision = $analysis.hasResolutionCollision
            hasPathResolutionCollision = $analysis.hasPathResolutionCollision
            hasPathOrderConflict = $analysis.hasPathOrderConflict
            fullyMapped = $analysis.fullyMapped
            activeResolution = $analysis.activeResolution
            shadowedResolutions = $analysis.shadowedResolutions
            resolutions = $analysis.resolutions
        }))
    }

    return [pscustomobject][ordered]@{
        providerId = 'path.precedence'
        category = 'environment'
        status = 'success'
        observedAt = '2026-09-21T00:00:00Z'
        components = @()
        warnings = @()
        errors = @()
        evidence = $pathEvidence.ToArray()
    }
}

function Get-EvidenceById {
    param(
        [Parameter(Mandatory)][object]$ProviderResult,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    return @(
        @($ProviderResult.evidence) |
            Where-Object { [string]$_.evidenceId -eq $EvidenceId } |
            Select-Object -First 1
    ) | Select-Object -First 1
}

$providerDescription = & $providerPath -Describe
$dependencyDescriptions = @(
    (& $pythonProviderPath -Describe),
    (& $dotnetProviderPath -Describe),
    (& $rustGoProviderPath -Describe),
    (& $pathProviderPath -Describe),
    (& $environmentProviderPath -Describe),
    (& $jvmMobileProviderPath -Describe)
)

if ($providerDescription.providerId -ne 'python-dotnet-rust-go.precedence') {
    throw 'Python/.NET/Rust/Go precedence provider id changed unexpectedly.'
}

foreach ($dependencyDescription in $dependencyDescriptions) {
    if ([int]$providerDescription.order -le [int]$dependencyDescription.order) {
        throw "Python/.NET/Rust/Go precedence provider must run after '$($dependencyDescription.providerId)'."
    }
}

$providerSource = Get-Content -LiteralPath $providerPath -Raw
foreach ($forbiddenPattern in @(
    '(?i)\bGet-Command\b',
    '(?i)\bInvoke-AuditCommand\b',
    '(?i)GetEnvironmentVariable',
    '(?i)SetEnvironmentVariable',
    '(?i)\bTest-Path\b',
    '(?i)\bpyenv\s+(install|uninstall|global|local)\b',
    '(?i)\bdotnet\s+(new|tool\s+install|workload\s+install|workload\s+update)\b',
    '(?i)\brustup\s+(install|update|default|toolchain\s+install)\b',
    '(?i)\bcargo\s+(install|update)\b',
    '(?i)\bgo\s+(install|get|env\s+-w)\b'
)) {
    if ($providerSource -match $forbiddenPattern) {
        throw "Python/.NET/Rust/Go precedence provider contains forbidden discovery/mutation pattern: $forbiddenPattern"
    }
}

$results = @{}

foreach ($caseProperty in @($fixture.cases.PSObject.Properties)) {
    $caseName = [string]$caseProperty.Name
    $case = $caseProperty.Value

    $pathModel = Get-AuditPathScopeModel -Scope process -RawPath ([string]$case.processPath)
    $context = [pscustomobject][ordered]@{
        ObservedAt = '2026-09-21T00:00:00Z'
        PreviousProviderResults = @(
            (New-SyntheticPythonProvider -Case $case),
            (New-SyntheticDotNetProvider -Case $case),
            (New-SyntheticRustGoProvider -Case $case),
            (New-SyntheticPathProvider -Case $case -PathModel $pathModel),
            (New-SyntheticEnvironmentProvider -Case $case -PathModel $pathModel)
        )
    }

    $result = & $providerPath -Context $context
    $results[$caseName] = $result

    if ($result.providerId -ne 'python-dotnet-rust-go.precedence') {
        throw "$caseName returned unexpected provider id '$($result.providerId)'."
    }

    if (@($result.components).Count -ne 0) {
        throw ("{0}: derived precedence provider must own zero components." -f $caseName)
    }

    $summary = Get-EvidenceById -ProviderResult $result -EvidenceId 'python-dotnet-rust-go-precedence.summary'
    if ($null -eq $summary) {
        throw ("{0}: missing precedence summary evidence." -f $caseName)
    }

    if (
        $summary.attributes.readOnly -ne $true -or
        $summary.attributes.duplicatedRuntimeDiscovery -ne $false -or
        $summary.attributes.directEnvironmentAccess -ne $false -or
        $summary.attributes.filesystemProbes -ne $false -or
        $summary.attributes.dotnetArchitectureAssumed -ne $false -or
        $summary.attributes.goToolchainAutoDownloadAllowed -ne $false
    ) {
        throw ("{0}: summary violates the read-only/evidence-only boundary." -f $caseName)
    }

    foreach ($dependencyName in @(
        'pythonEcosystem',
        'dotnetToolchain',
        'rustGoToolchains',
        'pathPrecedence',
        'environmentBaseline'
    )) {
        if ($summary.attributes.dependencies.$dependencyName -ne $true) {
            throw ("{0}: expected dependency '{1}' to be available." -f $caseName, $dependencyName)
        }
    }

    $actualCodes = @($result.warnings | ForEach-Object { [string]$_.code } | Sort-Object)
    $expectedCodes = @($case.expectedWarningCodes | ForEach-Object { [string]$_ } | Sort-Object)

    if (($actualCodes -join '|') -ne ($expectedCodes -join '|')) {
        throw "$caseName warning mismatch. Expected '$($expectedCodes -join ', ')', got '$($actualCodes -join ', ')'."
    }

    if ($expectedCodes.Count -eq 0 -and $result.status -ne 'success') {
        throw "$caseName must remain successful when no conflict is expected; status=$($result.status)."
    }

    if ($expectedCodes.Count -gt 0 -and $result.status -ne 'warning') {
        throw "$caseName must report warning status when conflicts are present; status=$($result.status)."
    }
}

$aligned = $results['alignedAll']
$alignedPython = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'python-dotnet-rust-go-precedence.command.python'
$alignedPyenv = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'python-dotnet-rust-go-precedence.command.pyenv'
$alignedDotnet = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'python-dotnet-rust-go-precedence.command.dotnet'
$alignedRust = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'python-dotnet-rust-go-precedence.rust'
$alignedGo = Get-EvidenceById -ProviderResult $aligned -EvidenceId 'python-dotnet-rust-go-precedence.go'

if ($alignedPython.attributes.insideConfiguredPyenvVersions -ne $true) {
    throw 'Aligned Python must resolve inside PYENV_ROOT versions.'
}
if ($alignedPyenv.attributes.relationship.relationship -ne 'aligned') {
    throw 'Aligned pyenv must resolve from PYENV_ROOT bin.'
}
if (
    $alignedDotnet.attributes.relationship.relationship -ne 'aligned' -or
    $alignedDotnet.attributes.architectureAssumed -ne $false
) {
    throw 'Aligned dotnet must match a configured root without assuming architecture.'
}
if (
    $alignedRust.attributes.rustToolchainRootRelationship -ne 'aligned' -or
    $alignedRust.attributes.rustupRelationship.relationship -ne 'aligned' -or
    $alignedRust.attributes.rustcRelationship.relationship -ne 'aligned' -or
    $alignedRust.attributes.cargoRelationship.relationship -ne 'aligned'
) {
    throw 'Aligned Rust layout must match CARGO_HOME and RUSTUP_HOME relationships.'
}
if (
    $alignedGo.attributes.commandRelationship.relationship -ne 'aligned' -or
    $alignedGo.attributes.gorootObservedRelationship -ne 'aligned' -or
    $alignedGo.attributes.gopathObservedRelationship -ne 'aligned' -or
    $alignedGo.attributes.GOTOOLCHAIN -ne 'local' -or
    $alignedGo.attributes.autoDownloadAllowed -ne $false
) {
    throw 'Aligned Go layout must preserve configured/observed roots and GOTOOLCHAIN=local safety.'
}

$pyenvConflict = $results['pyenvConflict']
$pyenvConflictPython = Get-EvidenceById -ProviderResult $pyenvConflict -EvidenceId 'python-dotnet-rust-go-precedence.command.python'
$pyenvConflictManager = Get-EvidenceById -ProviderResult $pyenvConflict -EvidenceId 'python-dotnet-rust-go-precedence.command.pyenv'
if (
    $pyenvConflictPython.attributes.insideConfiguredPyenvVersions -ne $false -or
    $pyenvConflictPython.attributes.relationship.activePathPosition -ne 0 -or
    $pyenvConflictManager.attributes.relationship.relationship -ne 'mismatch' -or
    $pyenvConflictManager.attributes.relationship.activePathPosition -ne 1
) {
    throw 'pyenv conflict must prove active Python/pyenv origins and precedence.'
}

$dotnetAligned = $results['dotnetAmbiguousAligned']
$dotnetAlignedEvidence = Get-EvidenceById -ProviderResult $dotnetAligned -EvidenceId 'python-dotnet-rust-go-precedence.command.dotnet'
if (
    $dotnetAlignedEvidence.attributes.relationship.relationship -ne 'aligned' -or
    $dotnetAlignedEvidence.attributes.matchedRootNames -notcontains 'DOTNET_ROOT_X64' -or
    $dotnetAlignedEvidence.attributes.architectureAssumed -ne $false
) {
    throw '.NET multi-root alignment must identify the matching root without architecture inference.'
}

$dotnetConflict = $results['dotnetOutsideRoots']
$dotnetConflictEvidence = Get-EvidenceById -ProviderResult $dotnetConflict -EvidenceId 'python-dotnet-rust-go-precedence.command.dotnet'
if (
    $dotnetConflictEvidence.attributes.relationship.relationship -ne 'mismatch' -or
    $dotnetConflictEvidence.attributes.relationship.activePathPosition -ne 0
) {
    throw '.NET outside-root conflict must preserve active PATH precedence.'
}

$rustConflict = $results['rustRootsConflict']
$rustConflictEvidence = Get-EvidenceById -ProviderResult $rustConflict -EvidenceId 'python-dotnet-rust-go-precedence.rust'
if (
    $rustConflictEvidence.attributes.rustToolchainRootRelationship -ne 'mismatch' -or
    $rustConflictEvidence.attributes.cargoRelationship.relationship -ne 'mismatch' -or
    $rustConflictEvidence.attributes.rustupRelationship.relationship -ne 'mismatch' -or
    $rustConflictEvidence.attributes.rustcRelationship.relationship -ne 'mismatch'
) {
    throw 'Rust conflict must preserve CARGO_HOME and RUSTUP_HOME mismatches.'
}

$goConflict = $results['goConflict']
$goConflictEvidence = Get-EvidenceById -ProviderResult $goConflict -EvidenceId 'python-dotnet-rust-go-precedence.go'
if (
    $goConflictEvidence.attributes.commandRelationship.relationship -ne 'mismatch' -or
    $goConflictEvidence.attributes.gorootObservedRelationship -ne 'mismatch' -or
    $goConflictEvidence.attributes.gopathObservedRelationship -ne 'mismatch' -or
    $goConflictEvidence.attributes.GOTOOLCHAIN -ne 'local' -or
    $goConflictEvidence.attributes.autoDownloadAllowed -ne $false
) {
    throw 'Go conflict must preserve command/root mismatches without enabling toolchain downloads.'
}

$missing = $results['missingOptionalTooling']
$missingSummary = Get-EvidenceById -ProviderResult $missing -EvidenceId 'python-dotnet-rust-go-precedence.summary'
if (
    $missingSummary.attributes.pyenvRootConfigured -ne $false -or
    $missingSummary.attributes.dotnetConfiguredRootCount -ne 0 -or
    $missingSummary.attributes.cargoHomeConfigured -ne $false -or
    $missingSummary.attributes.rustupHomeConfigured -ne $false -or
    $missingSummary.attributes.gorootConfigured -ne $false -or
    $missingSummary.attributes.gopathConfigured -ne $false -or
    @($missing.warnings).Count -ne 0
) {
    throw 'Missing optional roots/tooling must remain neutral.'
}

Write-Host 'Python/.NET/Rust/Go PATH and environment precedence validation passed.'
