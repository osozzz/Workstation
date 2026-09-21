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
        providerId = 'javascript.toolchain'
        category   = 'runtime'
        order      = 20
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
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match(
        $Text,
        '(?i)(?<![0-9A-Za-z])v?(?<version>\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?)'
    )

    if (-not $match.Success) {
        return $null
    }

    $normalized = $match.Groups['version'].Value
    $rawLine = @(
        $Text -split '\r?\n' |
            Where-Object { $_ -match [regex]::Escape($match.Value) } |
            Select-Object -First 1
    )

    $raw = if ($rawLine.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$rawLine[0])) {
        ([string]$rawLine[0]).Trim()
    }
    else {
        $match.Value
    }

    $channel = $null
    $channelMatch = [regex]::Match($normalized, '-(?<channel>[0-9A-Za-z.-]+)$')
    if ($channelMatch.Success) {
        $channel = $channelMatch.Groups['channel'].Value
    }

    return New-AuditVersionRecord -Raw $raw -Normalized $normalized -Channel $channel
}

function Add-UniqueVersion {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$List,

        [AllowNull()]
        [object]$Version
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
        return [string]::Equals($leftPath, $rightPath, [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return [string]::Equals(
            $Left.Trim().TrimEnd('\'),
            $Right.Trim().TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase
        )
    }
}

function Add-UniqueInstallation {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$List,

        [AllowNull()]
        [string]$Path,

        [AllowNull()]
        [object]$Version,

        [bool]$Active = $false,

        [Parameter(Mandatory)]
        [ValidateSet('command', 'registry', 'filesystem', 'environment', 'configuration', 'package-manager', 'unknown')]
        [string]$Source
    )

    foreach ($existing in $List) {
        if (
            -not [string]::IsNullOrWhiteSpace($Path) -and
            -not [string]::IsNullOrWhiteSpace([string]$existing.path) -and
            (Test-PathEquals -Left ([string]$existing.path) -Right $Path)
        ) {
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

function Get-ExecutableVersionRecord {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $rawVersion = [string]$item.VersionInfo.ProductVersion

        if ([string]::IsNullOrWhiteSpace($rawVersion)) {
            $rawVersion = [string]$item.VersionInfo.FileVersion
        }

        return Get-VersionRecordFromText -Text $rawVersion
    }
    catch {
        return $null
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

function New-CommandComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$EvidencePrefix = 'javascript',
        [object[]]$AdditionalInstallations = @()
    )

    $result = Invoke-AuditCommand -Command $Command -Arguments $Arguments -TimeoutSeconds 20

    if (-not $result.Found) {
        $installations = New-Object System.Collections.Generic.List[object]
        $versions = New-Object System.Collections.Generic.List[object]

        foreach ($candidate in @($AdditionalInstallations)) {
            Add-UniqueInstallation -List $installations -Path ([string]$candidate.path) -Version $candidate.version -Active ([bool]$candidate.active) -Source ([string]$candidate.source)
            Add-UniqueVersion -List $versions -Version $candidate.version
        }

        $state = if ($installations.Count -gt 0) { 'partial' } else { 'missing' }
        $installed = if ($installations.Count -gt 0) { $true } else { $false }

        if ($installations.Count -gt 0) {
            $script:hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'JAVASCRIPT_COMMAND_UNRESOLVED' -Message "'$Name' installation evidence exists but '$Command' is not resolvable." -Severity warning -ComponentId $ComponentId))
        }

        return [pscustomobject][ordered]@{
            componentId         = $ComponentId
            name                = $Name
            state               = $state
            installed           = $installed
            activeVersion       = $null
            discoveredVersions  = $versions.ToArray()
            installations       = $installations.ToArray()
            commandResolutions  = @()
            versionIntelligence = New-NotApplicableVersionIntelligence
        }
    }

    $evidenceId = "$EvidencePrefix.$ComponentId.version"
    $source = (@($Command) + @($Arguments)) -join ' '
    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type command -Source $source -ExitCode $result.ExitCode -Captured $result.Captured -Redacted:$result.Redacted -Attributes @{
        status          = $result.Status
        truncated       = $result.Truncated
        timedOut        = $result.TimedOut
        resolutionCount = @($result.Resolutions).Count
    }))

    $activeVersion = Get-VersionRecordFromText -Text $result.Captured
    $versions = New-Object System.Collections.Generic.List[object]
    Add-UniqueVersion -List $versions -Version $activeVersion

    $installations = New-Object System.Collections.Generic.List[object]
    foreach ($resolution in @($result.Resolutions)) {
        $resolutionVersion = if ($resolution.active) {
            $activeVersion
        }
        elseif ($null -ne $resolution.version) {
            $resolution.version
        }
        else {
            Get-ExecutableVersionRecord -Path ([string]$resolution.path)
        }

        Add-UniqueVersion -List $versions -Version $resolutionVersion
        Add-UniqueInstallation -List $installations -Path ([string]$resolution.path) -Version $resolutionVersion -Active ([bool]$resolution.active) -Source command
    }

    foreach ($candidate in @($AdditionalInstallations)) {
        Add-UniqueVersion -List $versions -Version $candidate.version
        Add-UniqueInstallation -List $installations -Path ([string]$candidate.path) -Version $candidate.version -Active ([bool]$candidate.active) -Source ([string]$candidate.source)
    }

    $state = 'present'
    if ($result.Status -ne 'success' -or $null -eq $activeVersion) {
        $state = 'partial'
        $script:hasPartial = $true

        $code = switch ($result.Status) {
            'timed-out' { 'JAVASCRIPT_VERSION_TIMEOUT' }
            'non-zero' { 'JAVASCRIPT_VERSION_NONZERO' }
            'failed' { 'JAVASCRIPT_VERSION_FAILED' }
            default { 'JAVASCRIPT_VERSION_UNKNOWN' }
        }

        $warnings.Add((New-AuditIssue -Code $code -Message "Version detection for '$Name' was incomplete." -Severity warning -ComponentId $ComponentId -EvidenceIds @($evidenceId)))
    }

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = $Name
        state               = $state
        installed           = $true
        activeVersion       = $activeVersion
        discoveredVersions  = $versions.ToArray()
        installations       = $installations.ToArray()
        commandResolutions  = @($result.Resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    }
}

$environmentSnapshot = Get-AuditEnvironmentSnapshot -Names @('NVM_HOME', 'NVM_SYMLINK', 'PNPM_HOME')
$nvmHome = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'NVM_HOME'
$nvmSymlink = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'NVM_SYMLINK'
$pnpmHome = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'PNPM_HOME'

$evidence.Add((New-AuditEvidence -EvidenceId 'javascript.environment' -Type environment -Source 'NVM_HOME/NVM_SYMLINK/PNPM_HOME' -Captured $null -Attributes @{
    variables = @($environmentSnapshot)
    pnpmHomeConfigured = -not [string]::IsNullOrWhiteSpace($pnpmHome)
}))

$nvmVersionResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('version') -TimeoutSeconds 15
$nvmCurrentResult = $null
$nvmListResult = $null
$nvmRootResult = $null
$nvmVersion = $null
$nvmCurrentVersion = $null
$nvmRoot = $nvmHome
$nvmResolutions = @()
$nvmInstallations = New-Object System.Collections.Generic.List[object]
$nvmDiscoveredVersions = New-Object System.Collections.Generic.List[object]
$nvmListedNodeVersions = New-Object System.Collections.Generic.List[object]
$nvmState = 'missing'
$nvmInstalled = $false

if ($nvmVersionResult.Found) {
    $nvmInstalled = $true
    $nvmState = 'present'
    $nvmResolutions = @($nvmVersionResult.Resolutions)
    $nvmVersion = Get-VersionRecordFromText -Text $nvmVersionResult.Captured

    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.version' -Type command -Source 'nvm version' -ExitCode $nvmVersionResult.ExitCode -Captured $nvmVersionResult.Captured -Redacted:$nvmVersionResult.Redacted -Attributes @{
        status = $nvmVersionResult.Status
        truncated = $nvmVersionResult.Truncated
        timedOut = $nvmVersionResult.TimedOut
    }))

    if ($nvmVersionResult.Status -ne 'success' -or $null -eq $nvmVersion) {
        $nvmState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NVM_VERSION_INCOMPLETE' -Message 'NVM for Windows version detection was incomplete.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.version')))
    }

    foreach ($resolution in $nvmResolutions) {
        Add-UniqueInstallation -List $nvmInstallations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $nvmVersion } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
    }

    $nvmCurrentResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('current') -TimeoutSeconds 15
    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.current' -Type command -Source 'nvm current' -ExitCode $nvmCurrentResult.ExitCode -Captured $nvmCurrentResult.Captured -Redacted:$nvmCurrentResult.Redacted -Attributes @{
        status = $nvmCurrentResult.Status
        truncated = $nvmCurrentResult.Truncated
        timedOut = $nvmCurrentResult.TimedOut
    }))

    if ($nvmCurrentResult.Status -eq 'success') {
        $nvmCurrentVersion = Get-VersionRecordFromText -Text $nvmCurrentResult.Captured
    }
    else {
        $nvmState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NVM_CURRENT_QUERY_FAILED' -Message 'NVM for Windows current-version query did not complete successfully.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.current')))
    }

    $nvmListResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('list') -TimeoutSeconds 20
    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.list' -Type command -Source 'nvm list' -ExitCode $nvmListResult.ExitCode -Captured $nvmListResult.Captured -Redacted:$nvmListResult.Redacted -Attributes @{
        status = $nvmListResult.Status
        truncated = $nvmListResult.Truncated
        timedOut = $nvmListResult.TimedOut
    }))

    if ($nvmListResult.Status -eq 'success' -and -not [string]::IsNullOrWhiteSpace($nvmListResult.Captured)) {
        foreach ($line in @($nvmListResult.Captured -split '\r?\n')) {
            $match = [regex]::Match(
                $line,
                '^\s*(?<active>\*\s*)?(?<version>v?\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?)'
            )

            if (-not $match.Success) {
                continue
            }

            $versionRecord = Get-VersionRecordFromText -Text $match.Groups['version'].Value
            Add-UniqueVersion -List $nvmListedNodeVersions -Version $versionRecord
        }
    }
    elseif ($nvmListResult.Status -ne 'success') {
        $nvmState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NVM_LIST_QUERY_FAILED' -Message 'NVM for Windows installed-version query did not complete successfully.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.list')))
    }

    $nvmRootResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('root') -TimeoutSeconds 15
    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.root' -Type command -Source 'nvm root' -ExitCode $nvmRootResult.ExitCode -Captured $nvmRootResult.Captured -Sensitive -Attributes @{
        status = $nvmRootResult.Status
        truncated = $nvmRootResult.Truncated
        timedOut = $nvmRootResult.TimedOut
    }))

    if ([string]::IsNullOrWhiteSpace($nvmRoot) -and $nvmRootResult.Status -eq 'success') {
        $rootMatch = [regex]::Match($nvmRootResult.Captured, '(?im)Current\s+Root:\s*(?<root>.+)$')
        if ($rootMatch.Success) {
            $nvmRoot = $rootMatch.Groups['root'].Value.Trim()
        }
    }
}
else {
    $nvmExe = if (-not [string]::IsNullOrWhiteSpace($nvmHome)) {
        Join-Path $nvmHome 'nvm.exe'
    }
    else {
        $null
    }

    if (-not [string]::IsNullOrWhiteSpace($nvmExe) -and (Test-Path -LiteralPath $nvmExe -PathType Leaf)) {
        $nvmInstalled = $true
        $nvmState = 'partial'
        $hasPartial = $true
        $nvmFileVersion = Get-ExecutableVersionRecord -Path $nvmExe
        Add-UniqueInstallation -List $nvmInstallations -Path $nvmExe -Version $nvmFileVersion -Active $false -Source filesystem
        $nvmVersion = $nvmFileVersion
        $warnings.Add((New-AuditIssue -Code 'NVM_COMMAND_UNRESOLVED' -Message 'NVM for Windows is installed but the nvm command is not resolvable.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.environment')))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($nvmHome) -or -not [string]::IsNullOrWhiteSpace($nvmSymlink)) {
        $nvmState = 'partial'
        $nvmInstalled = $null
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NVM_CONFIGURATION_PARTIAL' -Message 'NVM environment configuration exists but an NVM installation could not be confirmed.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.environment')))
    }
}

$nodeAdditionalInstallations = New-Object System.Collections.Generic.List[object]

if ([string]::IsNullOrWhiteSpace($nvmRoot) -or -not (Test-Path -LiteralPath $nvmRoot -PathType Container)) {
    foreach ($versionRecord in $nvmListedNodeVersions) {
        $active = $false
        if ($null -ne $nvmCurrentVersion -and $null -ne $versionRecord) {
            $active = [string]::Equals(
                [string]$nvmCurrentVersion.normalized,
                [string]$versionRecord.normalized,
                [StringComparison]::OrdinalIgnoreCase
            )
        }

        Add-UniqueInstallation -List $nodeAdditionalInstallations -Path $null -Version $versionRecord -Active $active -Source configuration
    }
}

if (-not [string]::IsNullOrWhiteSpace($nvmRoot) -and (Test-Path -LiteralPath $nvmRoot -PathType Container)) {
    try {
        foreach ($directory in @(Get-ChildItem -LiteralPath $nvmRoot -Directory -ErrorAction Stop)) {
            $versionMatch = [regex]::Match($directory.Name, '^v?(?<version>\d+(?:\.\d+){1,3}(?:[-+][0-9A-Za-z.-]+)?)$')
            if (-not $versionMatch.Success) {
                continue
            }

            $nodePath = Join-Path $directory.FullName 'node.exe'
            if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
                continue
            }

            $versionRecord = Get-VersionRecordFromText -Text $versionMatch.Groups['version'].Value
            Add-UniqueVersion -List $nvmListedNodeVersions -Version $versionRecord

            $active = $false
            if ($null -ne $nvmCurrentVersion -and $null -ne $versionRecord) {
                $active = [string]::Equals(
                    [string]$nvmCurrentVersion.normalized,
                    [string]$versionRecord.normalized,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }

            Add-UniqueInstallation -List $nodeAdditionalInstallations -Path $nodePath -Version $versionRecord -Active $active -Source filesystem
        }

        $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.node.nvm-installations' -Type filesystem -Source 'NVM root version directories' -Captured $null -Attributes @{
            rootConfigured = $true
            installationCount = $nodeAdditionalInstallations.Count
        }))
    }
    catch {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NVM_ROOT_ENUMERATION_FAILED' -Message 'NVM root version directories could not be enumerated completely.' -Severity warning -ComponentId 'node'))
    }
}

$programFilesRoots = @(
    $env:ProgramFiles,
    [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
)

foreach ($root in $programFilesRoots) {
    if ([string]::IsNullOrWhiteSpace($root)) {
        continue
    }

    $nodePath = Join-Path $root 'nodejs\node.exe'
    if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf)) {
        continue
    }

    if (-not [string]::IsNullOrWhiteSpace($nvmSymlink)) {
        $candidateDirectory = Split-Path -Parent $nodePath
        if (Test-PathEquals -Left $candidateDirectory -Right $nvmSymlink) {
            continue
        }
    }

    $versionRecord = Get-ExecutableVersionRecord -Path $nodePath
    Add-UniqueInstallation -List $nodeAdditionalInstallations -Path $nodePath -Version $versionRecord -Active $false -Source filesystem
}

$nodeComponent = New-CommandComponent -ComponentId 'node' -Name 'Node.js' -Command 'node' -Arguments @('--version') -AdditionalInstallations $nodeAdditionalInstallations.ToArray()

if ($null -ne $nvmCurrentVersion -and $null -ne $nodeComponent.activeVersion) {
    if (-not [string]::Equals(
        [string]$nvmCurrentVersion.normalized,
        [string]$nodeComponent.activeVersion.normalized,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        $hasPartial = $true
        if ($nodeComponent.state -eq 'present') {
            $nodeComponent.state = 'partial'
        }
        $warnings.Add((New-AuditIssue -Code 'NVM_NODE_VERSION_MISMATCH' -Message 'NVM reports a current Node.js version that differs from the active node command.' -Severity warning -ComponentId 'node' -EvidenceIds @('javascript.nvm-windows.current', 'javascript.node.version')))
    }
}

$components.Add($nodeComponent)
$components.Add((New-CommandComponent -ComponentId 'npm' -Name 'npm' -Command 'npm' -Arguments @('--version')))
$components.Add((New-CommandComponent -ComponentId 'pnpm' -Name 'pnpm' -Command 'pnpm' -Arguments @('--version')))
$components.Add((New-CommandComponent -ComponentId 'corepack' -Name 'Corepack' -Command 'corepack' -Arguments @('--version')))

if ($null -ne $nvmVersion) {
    Add-UniqueVersion -List $nvmDiscoveredVersions -Version $nvmVersion
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'nvm-windows'
    name                = 'NVM for Windows'
    state               = $nvmState
    installed           = $nvmInstalled
    activeVersion       = $nvmVersion
    discoveredVersions  = $nvmDiscoveredVersions.ToArray()
    installations       = $nvmInstallations.ToArray()
    commandResolutions  = @($nvmResolutions)
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$javascriptCliSpecs = @(
    @{ Id = 'angular-cli'; Label = 'Angular CLI'; Command = 'ng'; Args = @('version') },
    @{ Id = 'typescript'; Label = 'TypeScript'; Command = 'tsc'; Args = @('--version') },
    @{ Id = 'prisma'; Label = 'Prisma'; Command = 'prisma'; Args = @('--version') },
    @{ Id = 'nodemon'; Label = 'Nodemon'; Command = 'nodemon'; Args = @('--version') },
    @{ Id = 'rimraf'; Label = 'Rimraf'; Command = 'rimraf'; Args = @('--version') },
    @{ Id = 'zoho-extension-toolkit'; Label = 'Zoho Extension Toolkit'; Command = 'zet'; Args = @('-v') },
    @{ Id = 'zoho-catalyst-cli'; Label = 'Zoho Catalyst CLI'; Command = 'catalyst'; Args = @('--version') },
    @{ Id = 'redis-commander'; Label = 'Redis Commander'; Command = 'redis-commander'; Args = @('--version') }
)

foreach ($spec in $javascriptCliSpecs) {
    $components.Add((New-CommandComponent -ComponentId $spec.Id -Name $spec.Label -Command $spec.Command -Arguments $spec.Args -EvidencePrefix 'javascript.cli'))
}

$primaryComponents = @(
    $components |
        Where-Object { $_.componentId -in @('node', 'npm', 'pnpm', 'corepack', 'nvm-windows') }
)

$anyPrimaryPresent = @(
    $primaryComponents |
        Where-Object { $_.state -in @('present', 'partial') }
).Count -gt 0

$anyCliPresent = @(
    $components |
        Where-Object {
            $_.componentId -notin @('node', 'npm', 'pnpm', 'corepack', 'nvm-windows') -and
            $_.state -in @('present', 'partial')
        }
).Count -gt 0

$status = if (-not $anyPrimaryPresent -and -not $anyCliPresent) {
    'unavailable'
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial
}

return [pscustomobject][ordered]@{
    providerId = 'javascript.toolchain'
    category   = 'runtime'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
