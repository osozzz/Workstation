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
        providerId = 'rust-go.toolchains'
        category   = 'runtime'
        order      = 26
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$components = New-Object System.Collections.Generic.List[object]
$hasPartial = $false

function New-NotApplicableVersionIntelligence {
    return [pscustomobject][ordered]@{
        status        = 'not-applicable'
        latestStable  = $null
        latestLts     = $null
        latestCurrent = $null
        source        = $null
        checkedAt     = $null
        message       = $null
    }
}

function Get-VersionRecordFromText {
    param(
        [AllowNull()][string]$Text,
        [AllowNull()][string]$Channel
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match(
        $Text,
        '(?i)(?<![0-9A-Za-z])v?(?<version>\d+\.\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.-]+)?)'
    )

    if (-not $match.Success) {
        return $null
    }

    return New-AuditVersionRecord -Raw $match.Value -Normalized $match.Groups['version'].Value -Channel $Channel
}

function Test-PathEquals {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        $leftPath = [IO.Path]::GetFullPath($Left).TrimEnd('\')
        $rightPath = [IO.Path]::GetFullPath($Right).TrimEnd('\')
        return [string]::Equals(
            $leftPath,
            $rightPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return [string]::Equals(
            $Left.Trim().TrimEnd('\'),
            $Right.Trim().TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
}

function Get-EffectiveEnvironmentValue {
    param(
        [Parameter(Mandatory)][object[]]$Snapshot,
        [Parameter(Mandatory)][string]$Name
    )

    $entry = @($Snapshot | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
    if ($entry.Count -eq 0) {
        return $null
    }

    foreach ($scope in @('process', 'user', 'machine')) {
        $value = [string]$entry[0].$scope
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $null
}

function Add-UniqueVersion {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,

        [AllowNull()][object]$Version
    )

    if ($null -eq $Version) {
        return
    }

    $key = if (-not [string]::IsNullOrWhiteSpace([string]$Version.normalized)) {
        [string]$Version.normalized
    }
    else {
        [string]$Version.raw
    }

    foreach ($existing in $List) {
        $existingKey = if (-not [string]::IsNullOrWhiteSpace([string]$existing.normalized)) {
            [string]$existing.normalized
        }
        else {
            [string]$existing.raw
        }

        if ([string]::Equals($existingKey, $key, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $List.Add($Version)
}

function Add-UniqueInstallation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,

        [AllowNull()][string]$Path,
        [AllowNull()][object]$Version,
        [bool]$Active = $false,

        [Parameter(Mandatory)]
        [ValidateSet('command', 'registry', 'filesystem', 'environment', 'configuration', 'package-manager', 'unknown')]
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    foreach ($existing in $List) {
        if (Test-PathEquals -Left ([string]$existing.path) -Right $Path) {
            if ($Active) {
                $existing.active = $true
            }
            if ($null -eq $existing.version -and $null -ne $Version) {
                $existing.version = $Version
            }
            return
        }
    }

    $List.Add([pscustomobject][ordered]@{
        path    = $Path
        version = $Version
        active  = $Active
        source  = $Source
    })
}

function Get-ActiveResolutionPath {
    param([Parameter(Mandatory)][object[]]$Resolutions)

    $active = @($Resolutions | Where-Object active | Select-Object -First 1)
    if ($active.Count -eq 0) {
        return $null
    }

    return [string]$active[0].path
}

function Test-SameCommandDirectory {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        return Test-PathEquals -Left (Split-Path -Parent $Left) -Right (Split-Path -Parent $Right)
    }
    catch {
        return $false
    }
}

function Parse-RustupToolchains {
    param([AllowNull()][string]$Text)

    $items = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $items.ToArray()
    }

    foreach ($line in @($Text -split '\r?\n')) {
        $trimmed = $line.Trim()

        if (
            [string]::IsNullOrWhiteSpace($trimmed) -or
            $trimmed -match '(?i)^no installed toolchains'
        ) {
            continue
        }

        $match = [regex]::Match(
            $trimmed,
            '^(?<name>.+?)(?:\s+\((?<flags>[^)]+)\))?$'
        )

        if (-not $match.Success) {
            continue
        }

        $name = $match.Groups['name'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $flags = @(
            $match.Groups['flags'].Value -split ',' |
                ForEach-Object { $_.Trim().ToLowerInvariant() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $channel = $null
        if ($name -match '^(stable|beta|nightly)(?:-|$)') {
            $channel = $Matches[1].ToLowerInvariant()
        }

        $version = $null
        $versionMatch = [regex]::Match(
            $name,
            '^(?<version>\d+\.\d+(?:\.\d+)?)'
        )
        if ($versionMatch.Success) {
            $version = Get-VersionRecordFromText -Text $versionMatch.Groups['version'].Value -Channel $null
        }

        $items.Add([pscustomobject][ordered]@{
            name    = $name
            active  = ($flags -contains 'active')
            default = ($flags -contains 'default')
            channel = $channel
            version = $version
        })
    }

    return $items.ToArray()
}

function New-CommandVersionComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$EvidenceId,
        [bool]$AllowExecute = $true,
        [AllowNull()][string]$BlockedWarningCode,
        [AllowNull()][string]$BlockedWarningMessage
    )

    $resolutions = @(Get-AuditCommandResolution -Command $Command)

    if ($resolutions.Count -eq 0) {
        return [pscustomobject][ordered]@{
            componentId         = $ComponentId
            name                = $Name
            state               = 'missing'
            installed           = $false
            activeVersion       = $null
            discoveredVersions  = @()
            installations       = @()
            commandResolutions  = @()
            versionIntelligence = New-NotApplicableVersionIntelligence
        }
    }

    if ($resolutions.Count -gt 1) {
        $script:hasPartial = $true
        $warnings.Add((New-AuditIssue -Code "$($ComponentId.ToUpperInvariant().Replace('-', '_'))_COMMAND_COLLISION" -Message "Multiple '$Command' command resolutions were detected. Precedence is preserved instead of silently collapsing them." -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
    }

    if (-not $AllowExecute) {
        $script:hasPartial = $true
        if (-not [string]::IsNullOrWhiteSpace($BlockedWarningCode)) {
            $warnings.Add((New-AuditIssue -Code $BlockedWarningCode -Message $BlockedWarningMessage -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
        }

        $evidence.Add((New-AuditEvidence -EvidenceId $EvidenceId -Type command -Source "$Command resolution inspected; version execution skipped for rustup proxy safety" -Captured $null -Attributes @{
            executionSkipped = $true
            resolutionCount = $resolutions.Count
        }))

        return [pscustomobject][ordered]@{
            componentId         = $ComponentId
            name                = $Name
            state               = 'partial'
            installed           = $true
            activeVersion       = $null
            discoveredVersions  = @()
            installations       = @(
                $resolutions |
                    ForEach-Object {
                        [pscustomobject][ordered]@{
                            path    = $_.path
                            version = $_.version
                            active  = [bool]$_.active
                            source  = 'command'
                        }
                    }
            )
            commandResolutions  = $resolutions
            versionIntelligence = New-NotApplicableVersionIntelligence
        }
    }

    $result = Invoke-AuditCommand -Command $Command -Arguments $Arguments -TimeoutSeconds 20
    $version = if ($result.Status -eq 'success') {
        Get-VersionRecordFromText -Text $result.Captured -Channel $null
    }
    else {
        $null
    }

    $evidence.Add((New-AuditEvidence -EvidenceId $EvidenceId -Type command -Source ((@($Command) + @($Arguments)) -join ' ') -ExitCode $result.ExitCode -Captured $result.Captured -Redacted:$result.Redacted -Attributes @{
        status          = $result.Status
        timedOut        = $result.TimedOut
        truncated       = $result.Truncated
        resolutionCount = @($result.Resolutions).Count
        executionSkipped = $false
    }))

    $state = 'present'
    if ($result.Status -ne 'success' -or $null -eq $version) {
        $state = 'partial'
        $script:hasPartial = $true
        $warnings.Add((New-AuditIssue -Code "$($ComponentId.ToUpperInvariant().Replace('-', '_'))_VERSION_INCOMPLETE" -Message "Version detection for '$Name' was incomplete." -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
    }

    $installations = New-Object System.Collections.Generic.List[object]
    foreach ($resolution in @($result.Resolutions)) {
        Add-UniqueInstallation -List $installations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $version } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
    }

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = $Name
        state               = $state
        installed           = $true
        activeVersion       = $version
        discoveredVersions  = $(if ($null -ne $version) { @($version) } else { @() })
        installations       = $installations.ToArray()
        commandResolutions  = @($result.Resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    }
}

$environmentSnapshot = Get-AuditEnvironmentSnapshot -Names @(
    'RUSTUP_HOME',
    'CARGO_HOME',
    'GOROOT',
    'GOPATH'
)

$rustupHome = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'RUSTUP_HOME'
$cargoHome = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'CARGO_HOME'
$gorootConfigured = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'GOROOT'
$gopathConfigured = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'GOPATH'

$evidence.Add((New-AuditEvidence -EvidenceId 'rust-go.environment' -Type environment -Source 'RUSTUP_HOME/CARGO_HOME/GOROOT/GOPATH' -Captured $null -Attributes @{
    variables = @($environmentSnapshot)
    rustupHomeConfigured = -not [string]::IsNullOrWhiteSpace($rustupHome)
    cargoHomeConfigured = -not [string]::IsNullOrWhiteSpace($cargoHome)
    gorootConfigured = -not [string]::IsNullOrWhiteSpace($gorootConfigured)
    gopathConfigured = -not [string]::IsNullOrWhiteSpace($gopathConfigured)
}))

$rustupResult = Invoke-AuditCommand -Command 'rustup' -Arguments @('--version') -TimeoutSeconds 20
$rustupVersion = if ($rustupResult.Found -and $rustupResult.Status -eq 'success') {
    Get-VersionRecordFromText -Text $rustupResult.Captured -Channel $null
}
else {
    $null
}

$rustupResolutions = @($rustupResult.Resolutions)
$rustupState = if (-not $rustupResult.Found) {
    'missing'
}
elseif ($rustupResult.Status -eq 'success' -and $null -ne $rustupVersion) {
    'present'
}
else {
    'partial'
}

if ($rustupResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'rust.rustup.version' -Type command -Source 'rustup --version' -ExitCode $rustupResult.ExitCode -Captured $rustupResult.Captured -Redacted:$rustupResult.Redacted -Attributes @{
        status = $rustupResult.Status
        resolutionCount = $rustupResolutions.Count
    }))

    if ($rustupResolutions.Count -gt 1) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'RUSTUP_COMMAND_COLLISION' -Message 'Multiple rustup command resolutions were detected.' -Severity warning -ComponentId 'rustup' -EvidenceIds @('rust.rustup.version')))
    }

    if ($rustupState -eq 'partial') {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'RUSTUP_VERSION_INCOMPLETE' -Message 'rustup is resolvable, but its version could not be determined reliably.' -Severity warning -ComponentId 'rustup' -EvidenceIds @('rust.rustup.version')))
    }
}

$rustupInstallations = @(
    $rustupResolutions |
        ForEach-Object {
            [pscustomobject][ordered]@{
                path = $_.path
                version = $(if ($_.active) { $rustupVersion } else { $_.version })
                active = [bool]$_.active
                source = 'command'
            }
        }
)

$components.Add([pscustomobject][ordered]@{
    componentId         = 'rustup'
    name                = 'rustup'
    state               = $rustupState
    installed           = $(if ($rustupResult.Found) { $true } else { $false })
    activeVersion       = $rustupVersion
    discoveredVersions  = $(if ($null -ne $rustupVersion) { @($rustupVersion) } else { @() })
    installations       = $rustupInstallations
    commandResolutions  = $rustupResolutions
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$rustToolchains = @()
$toolchainListResult = $null

if ($rustupResult.Found) {
    $toolchainListResult = Invoke-AuditCommand -Command 'rustup' -Arguments @('toolchain', 'list') -TimeoutSeconds 20

    if ($toolchainListResult.Status -eq 'success') {
        $rustToolchains = @(Parse-RustupToolchains -Text $toolchainListResult.Captured)
    }
    else {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'RUSTUP_TOOLCHAIN_LIST_FAILED' -Message 'rustup is available, but installed toolchains could not be enumerated.' -Severity warning -ComponentId 'rust-toolchains' -EvidenceIds @('rust.toolchains')))
    }

    $evidence.Add((New-AuditEvidence -EvidenceId 'rust.toolchains' -Type command -Source 'rustup toolchain list' -ExitCode $toolchainListResult.ExitCode -Captured $toolchainListResult.Captured -Redacted:$toolchainListResult.Redacted -Attributes @{
        status = $toolchainListResult.Status
        toolchainCount = $rustToolchains.Count
        toolchains = @(
            $rustToolchains |
                ForEach-Object {
                    [pscustomobject][ordered]@{
                        name = $_.name
                        active = $_.active
                        default = $_.default
                        channel = $_.channel
                        version = $(if ($null -ne $_.version) { $_.version.normalized } else { $null })
                        path = $(if (-not [string]::IsNullOrWhiteSpace($rustupHome)) { Join-Path $rustupHome (Join-Path 'toolchains' $_.name) } else { $null })
                    }
                }
        )
    }))
}
else {
    $evidence.Add((New-AuditEvidence -EvidenceId 'rust.toolchains' -Type derived -Source 'rustup not detected; managed toolchain enumeration unavailable' -Captured $null -Attributes @{
        status = 'not-applicable'
        toolchainCount = 0
        toolchains = @()
    }))
}

$activeManagedToolchains = @($rustToolchains | Where-Object active)
$rustToolchainState = if (-not $rustupResult.Found) {
    'missing'
}
elseif ($toolchainListResult.Status -ne 'success') {
    'partial'
}
elseif ($rustToolchains.Count -eq 0) {
    'partial'
}
else {
    'present'
}

if ($rustupResult.Found -and $toolchainListResult.Status -eq 'success' -and $rustToolchains.Count -eq 0) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'RUSTUP_NO_INSTALLED_TOOLCHAINS' -Message 'rustup is installed, but no Rust toolchains were reported.' -Severity warning -ComponentId 'rust-toolchains' -EvidenceIds @('rust.toolchains')))
}

$toolchainInstallations = New-Object System.Collections.Generic.List[object]
if (-not [string]::IsNullOrWhiteSpace($rustupHome)) {
    foreach ($toolchain in $rustToolchains) {
        Add-UniqueInstallation -List $toolchainInstallations -Path (Join-Path $rustupHome (Join-Path 'toolchains' $toolchain.name)) -Version $toolchain.version -Active ([bool]$toolchain.active) -Source environment
    }
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'rust-toolchains'
    name                = 'Rust Toolchains'
    state               = $rustToolchainState
    installed           = $(if ($rustToolchains.Count -gt 0) { $true } elseif ($rustupResult.Found) { $false } else { $false })
    activeVersion       = $null
    discoveredVersions  = @(
        $rustToolchains |
            Where-Object { $null -ne $_.version } |
            ForEach-Object { $_.version }
    )
    installations       = $toolchainInstallations.ToArray()
    commandResolutions  = @()
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$rustupPath = Get-ActiveResolutionPath -Resolutions $rustupResolutions
$rustcResolutions = @(Get-AuditCommandResolution -Command 'rustc')
$cargoResolutions = @(Get-AuditCommandResolution -Command 'cargo')
$rustcPath = Get-ActiveResolutionPath -Resolutions $rustcResolutions
$cargoPath = Get-ActiveResolutionPath -Resolutions $cargoResolutions

$rustcIsRustupProxy = $rustupResult.Found -and (Test-SameCommandDirectory -Left $rustupPath -Right $rustcPath)
$cargoIsRustupProxy = $rustupResult.Found -and (Test-SameCommandDirectory -Left $rustupPath -Right $cargoPath)
$managedToolchainActive = ($activeManagedToolchains.Count -gt 0)

$allowRustcExecution = -not $rustcIsRustupProxy -or $managedToolchainActive
$allowCargoExecution = -not $cargoIsRustupProxy -or $managedToolchainActive

$rustcComponent = New-CommandVersionComponent -ComponentId 'rustc' -Name 'Rust Compiler' -Command 'rustc' -Arguments @('--version') -EvidenceId 'rust.rustc.version' -AllowExecute:$allowRustcExecution -BlockedWarningCode 'RUSTC_PROXY_NOT_EXECUTED' -BlockedWarningMessage 'rustc resolves through rustup, but no active installed toolchain was proven. Version execution was skipped to avoid rustup auto-install side effects.'
$cargoComponent = New-CommandVersionComponent -ComponentId 'cargo' -Name 'Cargo' -Command 'cargo' -Arguments @('--version') -EvidenceId 'rust.cargo.version' -AllowExecute:$allowCargoExecution -BlockedWarningCode 'CARGO_PROXY_NOT_EXECUTED' -BlockedWarningMessage 'cargo resolves through rustup, but no active installed toolchain was proven. Version execution was skipped to avoid rustup auto-install side effects.'

$components.Add($rustcComponent)
$components.Add($cargoComponent)

if ($rustupResult.Found -and $rustToolchains.Count -gt 0 -and $activeManagedToolchains.Count -eq 0) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'RUSTUP_ACTIVE_TOOLCHAIN_UNPROVEN' -Message 'rustup toolchains are installed, but none was marked active for the current audit context.' -Severity warning -ComponentId 'rust-toolchains' -EvidenceIds @('rust.toolchains')))
}

if (-not $rustupResult.Found -and ($rustcComponent.state -in @('present', 'partial') -or $cargoComponent.state -in @('present', 'partial'))) {
    $warnings.Add((New-AuditIssue -Code 'RUST_STANDALONE_WITHOUT_RUSTUP' -Message 'Rust tooling is available without a detected rustup manager. Ownership is left unclassified rather than inferred.' -Severity info -ComponentId 'rustup' -EvidenceIds @('rust.toolchains')))
}

if (($rustcComponent.state -eq 'missing') -xor ($cargoComponent.state -eq 'missing')) {
    $hasPartial = $true
    $partialEvidenceIds = @()
    if ($rustcComponent.state -ne 'missing') {
        $partialEvidenceIds += 'rust.rustc.version'
    }
    if ($cargoComponent.state -ne 'missing') {
        $partialEvidenceIds += 'rust.cargo.version'
    }

    $warnings.Add((New-AuditIssue -Code 'RUST_TOOLCHAIN_PARTIAL' -Message 'Only one of rustc or Cargo is resolvable.' -Severity warning -ComponentId 'rust-toolchains' -EvidenceIds $partialEvidenceIds))
}

$goResult = Invoke-AuditCommand -Command 'go' -Arguments @('version') -TimeoutSeconds 20 -EnvironmentOverrides @{ GOTOOLCHAIN = 'local' }
$goVersion = if ($goResult.Found -and $goResult.Status -eq 'success') {
    $match = [regex]::Match($goResult.Captured, '(?i)\bgo(?<version>\d+\.\d+(?:\.\d+)?)\b')
    if ($match.Success) {
        New-AuditVersionRecord -Raw ("go" + $match.Groups['version'].Value) -Normalized $match.Groups['version'].Value -Channel $null
    }
    else {
        Get-VersionRecordFromText -Text $goResult.Captured -Channel $null
    }
}
else {
    $null
}

$goResolutions = @($goResult.Resolutions)
if ($goResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'go.version' -Type command -Source 'go version' -ExitCode $goResult.ExitCode -Captured $goResult.Captured -Redacted:$goResult.Redacted -Attributes @{
        status = $goResult.Status
        resolutionCount = $goResolutions.Count
        GOTOOLCHAIN = 'local'
    }))

    if ($goResolutions.Count -gt 1) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'GO_COMMAND_COLLISION' -Message 'Multiple go command resolutions were detected. Precedence is preserved.' -Severity warning -ComponentId 'go' -EvidenceIds @('go.version')))
    }
}

$goEnvResult = $null
$goRootObserved = $null
$goPathObserved = $null

if ($goResult.Found) {
    $goEnvResult = Invoke-AuditCommand -Command 'go' -Arguments @('env', '-json', 'GOROOT', 'GOPATH') -TimeoutSeconds 20 -EnvironmentOverrides @{ GOTOOLCHAIN = 'local' }

    if ($goEnvResult.Status -eq 'success') {
        try {
            $goEnv = $goEnvResult.Captured | ConvertFrom-Json -ErrorAction Stop
            $goRootObserved = [string]$goEnv.GOROOT
            $goPathObserved = [string]$goEnv.GOPATH
        }
        catch {
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'GO_ENV_JSON_PARSE_FAILED' -Message 'go env returned JSON that could not be parsed.' -Severity warning -ComponentId 'go' -EvidenceIds @('go.environment')))
        }
    }
    else {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'GO_ENV_FAILED' -Message 'Go is available, but GOROOT/GOPATH could not be inspected.' -Severity warning -ComponentId 'go' -EvidenceIds @('go.environment')))
    }

    $evidence.Add((New-AuditEvidence -EvidenceId 'go.environment' -Type command -Source 'go env -json GOROOT GOPATH' -ExitCode $goEnvResult.ExitCode -Captured $null -Attributes @{
        status = $goEnvResult.Status
        GOTOOLCHAIN = 'local'
        GOROOT = $goRootObserved
        GOPATH = $goPathObserved
        rawOutputRetained = $false
    }))

    if (
        -not [string]::IsNullOrWhiteSpace($gorootConfigured) -and
        -not [string]::IsNullOrWhiteSpace($goRootObserved) -and
        -not (Test-PathEquals -Left $gorootConfigured -Right $goRootObserved)
    ) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'GOROOT_ENV_MISMATCH' -Message 'Configured GOROOT differs from the GOROOT reported by the active Go toolchain.' -Severity warning -ComponentId 'go' -EvidenceIds @('rust-go.environment', 'go.environment')))
    }

    if (
        -not [string]::IsNullOrWhiteSpace($gopathConfigured) -and
        -not [string]::IsNullOrWhiteSpace($goPathObserved) -and
        -not (Test-PathEquals -Left $gopathConfigured -Right $goPathObserved)
    ) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'GOPATH_ENV_MISMATCH' -Message 'Configured GOPATH differs from the GOPATH reported by the active Go toolchain.' -Severity warning -ComponentId 'go' -EvidenceIds @('rust-go.environment', 'go.environment')))
    }
}
else {
    $evidence.Add((New-AuditEvidence -EvidenceId 'go.environment' -Type derived -Source 'Go CLI not detected; GOROOT/GOPATH command inspection unavailable' -Captured $null -Attributes @{
        status = 'not-applicable'
        GOROOT = $null
        GOPATH = $null
        rawOutputRetained = $false
    }))
}

$goState = if (-not $goResult.Found) {
    'missing'
}
elseif ($goResult.Status -eq 'success' -and $null -ne $goVersion -and $null -ne $goEnvResult -and $goEnvResult.Status -eq 'success') {
    'present'
}
else {
    'partial'
}

if ($goResult.Found -and $goState -eq 'partial') {
    $hasPartial = $true
}

$goInstallations = New-Object System.Collections.Generic.List[object]
foreach ($resolution in $goResolutions) {
    Add-UniqueInstallation -List $goInstallations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $goVersion } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'go'
    name                = 'Go'
    state               = $goState
    installed           = $(if ($goResult.Found) { $true } else { $false })
    activeVersion       = $goVersion
    discoveredVersions  = $(if ($null -ne $goVersion) { @($goVersion) } else { @() })
    installations       = $goInstallations.ToArray()
    commandResolutions  = $goResolutions
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$anyPresent = @(
    $components |
        Where-Object { $_.state -in @('present', 'partial') }
).Count -gt 0

$status = if (-not $anyPresent) {
    'unavailable'
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial
}

return [pscustomobject][ordered]@{
    providerId = 'rust-go.toolchains'
    category   = 'runtime'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
