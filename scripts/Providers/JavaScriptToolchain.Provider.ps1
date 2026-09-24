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
$versionCorePath = Join-Path $PSScriptRoot '..\Core\VersionIntelligence.Core.psm1'
$javascriptVersionCorePath = Join-Path $PSScriptRoot '..\Core\JavaScriptVersionIntelligence.Core.psm1'
Import-Module $corePath -Force
Import-Module $versionCorePath -Force
Import-Module $javascriptVersionCorePath -Force

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
        [AllowEmptyCollection()]
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
        [AllowEmptyCollection()]
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

function Get-FirstJsonPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Names
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($name in $Names) {
        $property = @(
            $InputObject.PSObject.Properties |
                Where-Object {
                    [string]::Equals(
                        [string]$_.Name,
                        $name,
                        [StringComparison]::OrdinalIgnoreCase
                    )
                } |
                Select-Object -First 1
        )

        if ($property.Count -gt 0) {
            return $property[0].Value
        }
    }

    foreach ($property in @($InputObject.PSObject.Properties)) {
        $value = $property.Value
        if ($null -eq $value -or $value -is [string]) {
            continue
        }

        $valueType = $value.GetType()
        if ($valueType.IsPrimitive -or $value -is [decimal]) {
            continue
        }

        if ($value -is [System.Collections.IEnumerable]) {
            foreach ($item in @($value)) {
                $found = Get-FirstJsonPropertyValue -InputObject $item -Names $Names
                if ($null -ne $found) {
                    return $found
                }
            }

            continue
        }

        $found = Get-FirstJsonPropertyValue -InputObject $value -Names $Names
        if ($null -ne $found) {
            return $found
        }
    }

    return $null
}

function Get-VersionRecordsFromText {
    param([AllowNull()][string]$Text)

    $versions = New-Object System.Collections.Generic.List[object]
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $versions.ToArray()
    }

    foreach ($match in [regex]::Matches(
        $Text,
        '(?i)(?<![0-9A-Za-z])v?(?<version>\d+\.\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)'
    )) {
        $record = Get-VersionRecordFromText -Text $match.Value
        Add-UniqueVersion -List $versions -Version $record
    }

    return $versions.ToArray()
}

function Get-KnownGlobalPackageInventory {
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$ListArguments,
        [Parameter(Mandatory)][string[]]$RootArguments,
        [Parameter(Mandatory)][string[]]$PackageNames,
        [Parameter(Mandatory)][string]$EvidencePrefix
    )

    $listResult = Invoke-AuditCommand -Command $Command -Arguments $ListArguments -TimeoutSeconds 45
    if (-not $listResult.Found) {
        return @()
    }

    $packageMatches = New-Object System.Collections.Generic.List[object]
    $parseSucceeded = $false

    if (-not [string]::IsNullOrWhiteSpace($listResult.Captured)) {
        try {
            $parsed = $listResult.Captured | ConvertFrom-Json -ErrorAction Stop

            foreach ($container in @($parsed)) {
                foreach ($collectionName in @('dependencies', 'devDependencies', 'optionalDependencies')) {
                    $collectionProperty = $container.PSObject.Properties[$collectionName]
                    if ($null -eq $collectionProperty -or $null -eq $collectionProperty.Value) {
                        continue
                    }

                    foreach ($packageName in $PackageNames) {
                        $packageProperty = $collectionProperty.Value.PSObject.Properties[$packageName]
                        if ($null -eq $packageProperty) {
                            continue
                        }

                        $packageValue = $packageProperty.Value
                        $versionText = $null
                        $packagePath = $null

                        if ($packageValue -is [string]) {
                            $versionText = [string]$packageValue
                        }
                        else {
                            $versionProperty = $packageValue.PSObject.Properties['version']
                            if ($versionProperty -and $versionProperty.Value) {
                                $versionText = [string]$versionProperty.Value
                            }

                            $pathProperty = $packageValue.PSObject.Properties['path']
                            if ($pathProperty -and $pathProperty.Value) {
                                $packagePath = [string]$pathProperty.Value
                            }
                        }

                        $versionRecord = Get-VersionRecordFromText -Text $versionText

                        $alreadyRecorded = @(
                            $packageMatches |
                                Where-Object {
                                    $_.packageName -eq $packageName -and
                                    (
                                        ($null -eq $_.version -and $null -eq $versionRecord) -or
                                        (
                                            $null -ne $_.version -and
                                            $null -ne $versionRecord -and
                                            $_.version.normalized -eq $versionRecord.normalized
                                        )
                                    )
                                }
                        ).Count -gt 0

                        if (-not $alreadyRecorded) {
                            $packageMatches.Add([pscustomobject][ordered]@{
                                packageName = $packageName
                                manager     = $Manager
                                version     = $versionRecord
                                path        = $packagePath
                            })
                        }
                    }
                }
            }

            $parseSucceeded = $true
        }
        catch {
            $parseSucceeded = $false
        }
    }

    $rootResult = $null
    $rootPath = $null

    if ($packageMatches.Count -gt 0 -and @($packageMatches | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.path) }).Count -gt 0) {
        $rootResult = Invoke-AuditCommand -Command $Command -Arguments $RootArguments -TimeoutSeconds 20

        if ($rootResult.Found -and $rootResult.Status -eq 'success' -and -not [string]::IsNullOrWhiteSpace($rootResult.Captured)) {
            $rootPath = @(
                $rootResult.Captured -split '\r?\n' |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -First 1
            )

            if ($rootPath.Count -gt 0) {
                $rootPath = ([string]$rootPath[0]).Trim()
            }
            else {
                $rootPath = $null
            }
        }

        $evidence.Add((New-AuditEvidence -EvidenceId "$EvidencePrefix.global-root" -Type command -Source ((@($Command) + @($RootArguments)) -join ' ') -ExitCode $rootResult.ExitCode -Captured $rootResult.Captured -Sensitive -Attributes @{
            status    = $rootResult.Status
            truncated = $rootResult.Truncated
            timedOut  = $rootResult.TimedOut
            resolved  = -not [string]::IsNullOrWhiteSpace([string]$rootPath)
        }))
    }

    foreach ($match in $packageMatches) {
        if ([string]::IsNullOrWhiteSpace([string]$match.path) -and -not [string]::IsNullOrWhiteSpace([string]$rootPath)) {
            $relativePackagePath = ([string]$match.packageName).Replace('/', [IO.Path]::DirectorySeparatorChar)
            $match.path = Join-Path $rootPath $relativePackagePath
        }
    }

    $matchedAttributes = @(
        $packageMatches |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    packageName = $_.packageName
                    manager     = $_.manager
                    version     = if ($null -ne $_.version) { $_.version.normalized } else { $null }
                    pathKnown   = -not [string]::IsNullOrWhiteSpace([string]$_.path)
                }
            }
    )

    $evidence.Add((New-AuditEvidence -EvidenceId "$EvidencePrefix.global-inventory" -Type command -Source ((@($Command) + @($ListArguments)) -join ' ') -ExitCode $listResult.ExitCode -Captured $listResult.Captured -Sensitive -Attributes @{
        status          = $listResult.Status
        truncated       = $listResult.Truncated
        timedOut        = $listResult.TimedOut
        parseSucceeded  = $parseSucceeded
        matchedPackages = $matchedAttributes
    }))

    return $packageMatches.ToArray()
}

function Get-PackageManagerInstallations {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Inventory,

        [Parameter(Mandatory)][string[]]$PackageNames
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($item in @($Inventory)) {
        $packageName = [string](Get-OptionalPropertyValue -InputObject $item -Name 'packageName')
        if ([string]::IsNullOrWhiteSpace($packageName) -or $packageName -notin $PackageNames) {
            continue
        }

        $results.Add([pscustomobject][ordered]@{
            path    = Get-OptionalPropertyValue -InputObject $item -Name 'path'
            version = Get-OptionalPropertyValue -InputObject $item -Name 'version'
            active  = $false
            source  = 'package-manager'
        })
    }

    return $results.ToArray()
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
            $candidatePath = Get-OptionalPropertyValue -InputObject $candidate -Name 'path'
            $candidateVersion = Get-OptionalPropertyValue -InputObject $candidate -Name 'version'
            $candidateActive = [bool](Get-OptionalPropertyValue -InputObject $candidate -Name 'active')
            $candidateSource = [string](Get-OptionalPropertyValue -InputObject $candidate -Name 'source')

            if ([string]::IsNullOrWhiteSpace($candidateSource)) {
                $candidateSource = 'unknown'
            }

            Add-UniqueInstallation -List $installations -Path ([string]$candidatePath) -Version $candidateVersion -Active $candidateActive -Source $candidateSource
            Add-UniqueVersion -List $versions -Version $candidateVersion
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
        $candidatePath = Get-OptionalPropertyValue -InputObject $candidate -Name 'path'
        $candidateVersion = Get-OptionalPropertyValue -InputObject $candidate -Name 'version'
        $candidateActive = [bool](Get-OptionalPropertyValue -InputObject $candidate -Name 'active')
        $candidateSource = [string](Get-OptionalPropertyValue -InputObject $candidate -Name 'source')

        if ([string]::IsNullOrWhiteSpace($candidateSource)) {
            $candidateSource = 'unknown'
        }

        Add-UniqueVersion -List $versions -Version $candidateVersion
        Add-UniqueInstallation -List $installations -Path ([string]$candidatePath) -Version $candidateVersion -Active $candidateActive -Source $candidateSource
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

$evidence.Add((New-AuditEvidence -EvidenceId 'javascript.environment' -Type environment -Source 'PNPM_HOME plus legacy NVM_HOME/NVM_SYMLINK' -Captured $null -Attributes @{
    variables = @($environmentSnapshot)
    pnpmHomeConfigured = -not [string]::IsNullOrWhiteSpace($pnpmHome)
    legacyNvmEnvironmentConfigured = (
        -not [string]::IsNullOrWhiteSpace($nvmHome) -or
        -not [string]::IsNullOrWhiteSpace($nvmSymlink)
    )
}))

$nvmVersionResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('version') -TimeoutSeconds 15
$nvmVersion = $null
$nvmMajorVersion = $null
$nvmCurrentVersion = $null
$nvmRoot = $null
$nvmMode = $null
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
    elseif ([string]$nvmVersion.normalized -match '^(?<major>\d+)') {
        $nvmMajorVersion = [int]$Matches['major']
    }

    foreach ($resolution in $nvmResolutions) {
        Add-UniqueInstallation -List $nvmInstallations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $nvmVersion } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
    }

    if ($null -ne $nvmMajorVersion -and $nvmMajorVersion -ge 2) {
        $nvmEnvResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('env', '--json') -TimeoutSeconds 20
        $nvmEnvParsed = $null

        if ($nvmEnvResult.Status -eq 'success' -and -not [string]::IsNullOrWhiteSpace($nvmEnvResult.Captured)) {
            try {
                $nvmEnvParsed = $nvmEnvResult.Captured | ConvertFrom-Json -ErrorAction Stop
                $candidateMode = Get-FirstJsonPropertyValue -InputObject $nvmEnvParsed -Names @('mode', 'operatingMode', 'operating_mode')
                $candidateRoot = Get-FirstJsonPropertyValue -InputObject $nvmEnvParsed -Names @('root', 'installRoot', 'install_root', 'installsRoot', 'installs_root')
                $candidateActive = Get-FirstJsonPropertyValue -InputObject $nvmEnvParsed -Names @('activeVersion', 'active_version', 'default')

                if (-not [string]::IsNullOrWhiteSpace([string]$candidateMode)) {
                    $nvmMode = [string]$candidateMode
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$candidateRoot)) {
                    $nvmRoot = [string]$candidateRoot
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$candidateActive)) {
                    $nvmCurrentVersion = Get-VersionRecordFromText -Text ([string]$candidateActive)
                }
            }
            catch {
                $nvmState = 'partial'
                $hasPartial = $true
                $warnings.Add((New-AuditIssue -Code 'NVM_V2_ENV_PARSE_FAILED' -Message 'NVM for Windows v2 environment JSON could not be parsed.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.env-v2')))
            }
        }
        elseif ($nvmEnvResult.Status -ne 'success') {
            $nvmState = 'partial'
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'NVM_V2_ENV_QUERY_FAILED' -Message 'NVM for Windows v2 environment query did not complete successfully.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.env-v2')))
        }

        $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.env-v2' -Type command -Source 'nvm env --json' -ExitCode $nvmEnvResult.ExitCode -Captured $nvmEnvResult.Captured -Sensitive -Attributes @{
            status = $nvmEnvResult.Status
            truncated = $nvmEnvResult.Truncated
            timedOut = $nvmEnvResult.TimedOut
            parsed = $null -ne $nvmEnvParsed
            mode = $nvmMode
            rootConfigured = -not [string]::IsNullOrWhiteSpace($nvmRoot)
        }))

        $nvmConfigResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('config', 'list', '--json') -TimeoutSeconds 20
        $nvmConfigParsed = $null

        if ($nvmConfigResult.Status -eq 'success' -and -not [string]::IsNullOrWhiteSpace($nvmConfigResult.Captured)) {
            try {
                $nvmConfigParsed = $nvmConfigResult.Captured | ConvertFrom-Json -ErrorAction Stop
                $configRoot = Get-FirstJsonPropertyValue -InputObject $nvmConfigParsed -Names @('root')
                $configMode = Get-FirstJsonPropertyValue -InputObject $nvmConfigParsed -Names @('mode')

                if (-not [string]::IsNullOrWhiteSpace([string]$configRoot)) {
                    $nvmRoot = [string]$configRoot
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$configMode)) {
                    $nvmMode = [string]$configMode
                }
            }
            catch {
                $nvmState = 'partial'
                $hasPartial = $true
                $warnings.Add((New-AuditIssue -Code 'NVM_V2_CONFIG_PARSE_FAILED' -Message 'NVM for Windows v2 configuration JSON could not be parsed.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.config-v2')))
            }
        }
        elseif ($nvmConfigResult.Status -ne 'success') {
            $nvmState = 'partial'
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'NVM_V2_CONFIG_QUERY_FAILED' -Message 'NVM for Windows v2 configuration query did not complete successfully.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.config-v2')))
        }

        $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.config-v2' -Type command -Source 'nvm config list --json' -ExitCode $nvmConfigResult.ExitCode -Captured $nvmConfigResult.Captured -Sensitive -Attributes @{
            status = $nvmConfigResult.Status
            truncated = $nvmConfigResult.Truncated
            timedOut = $nvmConfigResult.TimedOut
            parsed = $null -ne $nvmConfigParsed
            mode = $nvmMode
            rootConfigured = -not [string]::IsNullOrWhiteSpace($nvmRoot)
        }))

        $nvmDefaultResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('default', '--json') -TimeoutSeconds 15
        $nvmDefaultParsed = $null

        if ($nvmDefaultResult.Status -eq 'success' -and -not [string]::IsNullOrWhiteSpace($nvmDefaultResult.Captured)) {
            try {
                $nvmDefaultParsed = $nvmDefaultResult.Captured | ConvertFrom-Json -ErrorAction Stop
                $defaultValue = Get-FirstJsonPropertyValue -InputObject $nvmDefaultParsed -Names @('default')
                if (-not [string]::IsNullOrWhiteSpace([string]$defaultValue)) {
                    $nvmCurrentVersion = Get-VersionRecordFromText -Text ([string]$defaultValue)
                }
            }
            catch {
                $nvmState = 'partial'
                $hasPartial = $true
                $warnings.Add((New-AuditIssue -Code 'NVM_V2_DEFAULT_PARSE_FAILED' -Message 'NVM for Windows v2 default-version JSON could not be parsed.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.default-v2')))
            }
        }
        elseif ($nvmDefaultResult.Status -ne 'success') {
            $nvmState = 'partial'
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'NVM_V2_DEFAULT_QUERY_FAILED' -Message 'NVM for Windows v2 default-version query did not complete successfully.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.default-v2')))
        }

        $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.default-v2' -Type command -Source 'nvm default --json' -ExitCode $nvmDefaultResult.ExitCode -Captured $nvmDefaultResult.Captured -Redacted:$nvmDefaultResult.Redacted -Attributes @{
            status = $nvmDefaultResult.Status
            truncated = $nvmDefaultResult.Truncated
            timedOut = $nvmDefaultResult.TimedOut
            parsed = $null -ne $nvmDefaultParsed
        }))

        $nvmListResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('list', '--json') -TimeoutSeconds 20
        if ($nvmListResult.Status -eq 'success') {
            foreach ($versionRecord in @(Get-VersionRecordsFromText -Text $nvmListResult.Captured)) {
                Add-UniqueVersion -List $nvmListedNodeVersions -Version $versionRecord
            }
        }
        else {
            $nvmState = 'partial'
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'NVM_V2_LIST_QUERY_FAILED' -Message 'NVM for Windows v2 installed-version query did not complete successfully.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.list-v2')))
        }

        $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.list-v2' -Type command -Source 'nvm list --json' -ExitCode $nvmListResult.ExitCode -Captured $nvmListResult.Captured -Sensitive -Attributes @{
            status = $nvmListResult.Status
            truncated = $nvmListResult.Truncated
            timedOut = $nvmListResult.TimedOut
            discoveredVersionCount = $nvmListedNodeVersions.Count
        }))
    }
    elseif ($null -ne $nvmMajorVersion -and $nvmMajorVersion -lt 2) {
        $nvmState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NVM_LEGACY_VERSION' -Message 'NVM for Windows 1.x was detected. Workstation targets the current NVM for Windows v2 line.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.version')))

        $nvmCurrentResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('current') -TimeoutSeconds 15
        $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.current-legacy' -Type command -Source 'nvm current' -ExitCode $nvmCurrentResult.ExitCode -Captured $nvmCurrentResult.Captured -Redacted:$nvmCurrentResult.Redacted -Attributes @{
            status = $nvmCurrentResult.Status
            truncated = $nvmCurrentResult.Truncated
            timedOut = $nvmCurrentResult.TimedOut
        }))

        if ($nvmCurrentResult.Status -eq 'success') {
            $nvmCurrentVersion = Get-VersionRecordFromText -Text $nvmCurrentResult.Captured
        }

        $nvmListResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('list') -TimeoutSeconds 20
        $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.list-legacy' -Type command -Source 'nvm list' -ExitCode $nvmListResult.ExitCode -Captured $nvmListResult.Captured -Redacted:$nvmListResult.Redacted -Attributes @{
            status = $nvmListResult.Status
            truncated = $nvmListResult.Truncated
            timedOut = $nvmListResult.TimedOut
        }))

        if ($nvmListResult.Status -eq 'success') {
            foreach ($versionRecord in @(Get-VersionRecordsFromText -Text $nvmListResult.Captured)) {
                Add-UniqueVersion -List $nvmListedNodeVersions -Version $versionRecord
            }
        }

        $nvmRoot = $nvmHome
        $nvmRootResult = Invoke-AuditCommand -Command 'nvm' -Arguments @('root') -TimeoutSeconds 15
        if ([string]::IsNullOrWhiteSpace($nvmRoot) -and $nvmRootResult.Status -eq 'success') {
            $rootMatch = [regex]::Match($nvmRootResult.Captured, '(?im)Current\s+Root:\s*(?<root>.+)$')
            if ($rootMatch.Success) {
                $nvmRoot = $rootMatch.Groups['root'].Value.Trim()
            }
        }

        $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.nvm-windows.root-legacy' -Type command -Source 'nvm root' -ExitCode $nvmRootResult.ExitCode -Captured $nvmRootResult.Captured -Sensitive -Attributes @{
            status = $nvmRootResult.Status
            truncated = $nvmRootResult.Truncated
            timedOut = $nvmRootResult.TimedOut
            rootConfigured = -not [string]::IsNullOrWhiteSpace($nvmRoot)
        }))
    }
    else {
        $nvmState = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NVM_MAJOR_VERSION_UNKNOWN' -Message 'NVM for Windows was detected, but its major version could not be determined.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.nvm-windows.version')))
    }
}
else {
    $legacyNvmExe = if (-not [string]::IsNullOrWhiteSpace($nvmHome)) {
        Join-Path $nvmHome 'nvm.exe'
    }
    else {
        $null
    }

    if (-not [string]::IsNullOrWhiteSpace($legacyNvmExe) -and (Test-Path -LiteralPath $legacyNvmExe -PathType Leaf)) {
        $nvmInstalled = $true
        $nvmState = 'partial'
        $hasPartial = $true
        $nvmFileVersion = Get-ExecutableVersionRecord -Path $legacyNvmExe
        Add-UniqueInstallation -List $nvmInstallations -Path $legacyNvmExe -Version $nvmFileVersion -Active $false -Source filesystem
        $nvmVersion = $nvmFileVersion
        $warnings.Add((New-AuditIssue -Code 'NVM_LEGACY_COMMAND_UNRESOLVED' -Message 'A legacy NVM for Windows installation is visible through NVM_HOME but the nvm command is not resolvable. Workstation targets NVM v2.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.environment')))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($nvmHome) -or -not [string]::IsNullOrWhiteSpace($nvmSymlink)) {
        $nvmState = 'partial'
        $nvmInstalled = $null
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NVM_LEGACY_CONFIGURATION_DETECTED' -Message 'Legacy NVM_HOME/NVM_SYMLINK configuration exists but a current NVM for Windows v2 installation could not be confirmed.' -Severity warning -ComponentId 'nvm-windows' -EvidenceIds @('javascript.environment')))
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

        $warnings.Add((New-AuditIssue -Code 'NVM_ROOT_ENUMERATION_FAILED' -Message 'NVM root version directories could not be enumerated completely; nvm list evidence was retained.' -Severity warning -ComponentId 'node' -EvidenceIds @('javascript.nvm-windows.list')))
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

$npmComponent = New-CommandComponent -ComponentId 'npm' -Name 'npm' -Command 'npm' -Arguments @('--version')
$pnpmComponent = New-CommandComponent -ComponentId 'pnpm' -Name 'pnpm' -Command 'pnpm' -Arguments @('--version')
$corepackComponent = New-CommandComponent -ComponentId 'corepack' -Name 'Corepack' -Command 'corepack' -Arguments @('--version')

$versionIntelligenceOffline = $false
$offlineProperty = $Context.PSObject.Properties['VersionIntelligenceOffline']
if ($offlineProperty -and $null -ne $offlineProperty.Value) {
    $versionIntelligenceOffline = [bool]$offlineProperty.Value
}

$versionIntelligenceTransport = $null
$transportProperty = $Context.PSObject.Properties['VersionIntelligenceTransport']
if ($transportProperty -and $transportProperty.Value -is [scriptblock]) {
    $versionIntelligenceTransport = [scriptblock]$transportProperty.Value
}

try {
    $versionCheckedAt = [DateTimeOffset]::Parse([string]$Context.ObservedAt)
}
catch {
    $versionCheckedAt = [DateTimeOffset]::UtcNow
}

function Get-JavaScriptVersionSource {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$EvidenceId
    )

    $parameters = @{
        Source = $Source
        Uri = $Uri
        CheckedAt = $versionCheckedAt
        Offline = $versionIntelligenceOffline
    }

    if ($null -ne $versionIntelligenceTransport) {
        $parameters['Transport'] = $versionIntelligenceTransport
    }

    $sourceResult = Invoke-AuditVersionSource @parameters
    $evidence.Add((New-AuditEvidence -EvidenceId $EvidenceId -Type api -Source $Source -Captured $null -Attributes (Get-AuditVersionSourceEvidenceAttributes -SourceResult $sourceResult)))
    return ConvertFrom-AuditVersionSourceJson -SourceResult $sourceResult
}

if ($nodeComponent.state -in @('present', 'partial')) {
    $nodeSource = Get-JavaScriptVersionSource -Source 'nodejs-release-index' -Uri 'https://nodejs.org/dist/index.json' -EvidenceId 'javascript.version-intelligence.node-source'
    $nodeVersionResult = Resolve-NodeVersionIntelligence -DecodedSource $nodeSource -InstalledVersion $nodeComponent.activeVersion
    $nodeComponent.versionIntelligence = $nodeVersionResult.intelligence

    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.version-intelligence.node' -Type derived -Source 'Node release-channel interpretation' -Captured $null -Attributes @{
        installedVersion = $(if ($nodeComponent.activeVersion) { $nodeComponent.activeVersion.normalized } else { $null })
        latestLts = $(if ($nodeVersionResult.latestLts) { $nodeVersionResult.latestLts.normalized } else { $null })
        latestCurrent = $(if ($nodeVersionResult.latestCurrent) { $nodeVersionResult.latestCurrent.normalized } else { $null })
        installedBehindLts = $nodeVersionResult.installedBehindLts
        installedBehindCurrent = $nodeVersionResult.installedBehindCurrent
        policyDefaultChannel = $nodeVersionResult.policyDefaultChannel
        currentIsMandatoryReplacement = $nodeVersionResult.currentIsMandatoryReplacement
    }))
}

if ($npmComponent.state -in @('present', 'partial')) {
    $npmSource = Get-JavaScriptVersionSource -Source 'npm-registry:npm' -Uri 'https://registry.npmjs.org/npm/latest' -EvidenceId 'javascript.version-intelligence.npm-source'
    $npmVersionResult = Resolve-NpmPackageVersionIntelligence -PackageName npm -DecodedSource $npmSource -InstalledVersion $npmComponent.activeVersion
    $npmComponent.versionIntelligence = $npmVersionResult.intelligence

    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.version-intelligence.npm' -Type derived -Source 'npm stable-version interpretation' -Captured $null -Attributes @{
        installedVersion = $(if ($npmComponent.activeVersion) { $npmComponent.activeVersion.normalized } else { $null })
        latestStable = $(if ($npmVersionResult.latestStable) { $npmVersionResult.latestStable.normalized } else { $null })
        updateAvailable = $npmVersionResult.updateAvailable
    }))
}

if ($pnpmComponent.state -in @('present', 'partial')) {
    $pnpmSource = Get-JavaScriptVersionSource -Source 'npm-registry:pnpm' -Uri 'https://registry.npmjs.org/pnpm/latest' -EvidenceId 'javascript.version-intelligence.pnpm-source'
    $pnpmVersionResult = Resolve-NpmPackageVersionIntelligence -PackageName pnpm -DecodedSource $pnpmSource -InstalledVersion $pnpmComponent.activeVersion
    $pnpmComponent.versionIntelligence = $pnpmVersionResult.intelligence

    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.version-intelligence.pnpm' -Type derived -Source 'pnpm stable-version interpretation' -Captured $null -Attributes @{
        installedVersion = $(if ($pnpmComponent.activeVersion) { $pnpmComponent.activeVersion.normalized } else { $null })
        latestStable = $(if ($pnpmVersionResult.latestStable) { $pnpmVersionResult.latestStable.normalized } else { $null })
        updateAvailable = $pnpmVersionResult.updateAvailable
    }))
}

$components.Add($nodeComponent)
$components.Add($npmComponent)
$components.Add($pnpmComponent)
$components.Add($corepackComponent)

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
    @{ Id = 'angular-cli'; Label = 'Angular CLI'; Command = 'ng'; Args = @('version'); Packages = @('@angular/cli') },
    @{ Id = 'typescript'; Label = 'TypeScript'; Command = 'tsc'; Args = @('--version'); Packages = @('typescript') },
    @{ Id = 'prisma'; Label = 'Prisma'; Command = 'prisma'; Args = @('--version'); Packages = @('prisma') },
    @{ Id = 'nodemon'; Label = 'Nodemon'; Command = 'nodemon'; Args = @('--version'); Packages = @('nodemon') },
    @{ Id = 'rimraf'; Label = 'Rimraf'; Command = 'rimraf'; Args = @('--version'); Packages = @('rimraf') },
    @{ Id = 'zoho-extension-toolkit'; Label = 'Zoho Extension Toolkit'; Command = 'zet'; Args = @('-v'); Packages = @('zoho-extension-toolkit') },
    @{ Id = 'zoho-catalyst-cli'; Label = 'Zoho Catalyst CLI'; Command = 'catalyst'; Args = @('--version'); Packages = @('zcatalyst-cli', 'zoho-catalyst-cli') },
    @{ Id = 'redis-commander'; Label = 'Redis Commander'; Command = 'redis-commander'; Args = @('--version'); Packages = @('redis-commander') }
)

$knownGlobalPackages = @(
    $javascriptCliSpecs |
        ForEach-Object { @($_.Packages) } |
        Select-Object -Unique
)

$globalPackageInventory = New-Object System.Collections.Generic.List[object]

if ($npmComponent.state -in @('present', 'partial')) {
    foreach ($item in @(Get-KnownGlobalPackageInventory -Manager 'npm' -Command 'npm' -ListArguments @('list', '--global', '--depth=0', '--json') -RootArguments @('root', '--global') -PackageNames $knownGlobalPackages -EvidencePrefix 'javascript.npm')) {
        $globalPackageInventory.Add($item)
    }
}

if ($pnpmComponent.state -in @('present', 'partial')) {
    foreach ($item in @(Get-KnownGlobalPackageInventory -Manager 'pnpm' -Command 'pnpm' -ListArguments @('list', '--global', '--depth=0', '--json') -RootArguments @('root', '--global') -PackageNames $knownGlobalPackages -EvidencePrefix 'javascript.pnpm')) {
        $globalPackageInventory.Add($item)
    }
}

foreach ($spec in $javascriptCliSpecs) {
    $packageManagerInstallations = Get-PackageManagerInstallations -Inventory $globalPackageInventory.ToArray() -PackageNames @($spec.Packages)

    $components.Add((New-CommandComponent -ComponentId $spec.Id -Name $spec.Label -Command $spec.Command -Arguments $spec.Args -EvidencePrefix 'javascript.cli' -AdditionalInstallations $packageManagerInstallations))
}

$angularComponents = @($components | Where-Object { $_.componentId -eq 'angular-cli' } | Select-Object -First 1)
if ($angularComponents.Count -eq 1 -and $angularComponents[0].state -in @('present', 'partial')) {
    $angularSource = Get-JavaScriptVersionSource -Source 'npm-registry-dist-tags:@angular/cli' -Uri 'https://registry.npmjs.org/-/package/@angular%2fcli/dist-tags' -EvidenceId 'javascript.version-intelligence.angular-cli-source'
    $angularVersionResult = Resolve-AngularCliVersionIntelligence -DecodedSource $angularSource -InstalledVersion $angularComponents[0].activeVersion
    $angularComponents[0].versionIntelligence = $angularVersionResult.intelligence

    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.version-intelligence.angular-cli' -Type derived -Source 'Angular CLI stable-channel interpretation' -Captured $null -Attributes @{
        installedVersion = $(if ($angularComponents[0].activeVersion) { $angularComponents[0].activeVersion.normalized } else { $null })
        latestStable = $(if ($angularVersionResult.latestStable) { $angularVersionResult.latestStable.normalized } else { $null })
        updateAvailable = $angularVersionResult.updateAvailable
        majorMigrationRequiresExplicitAction = $angularVersionResult.majorMigrationRequiresExplicitAction
        projectCompatibilityOverridesGlobal = $angularVersionResult.projectCompatibilityOverridesGlobal
    }))
}

$typescriptComponents = @($components | Where-Object { $_.componentId -eq 'typescript' } | Select-Object -First 1)
if ($typescriptComponents.Count -eq 1 -and $typescriptComponents[0].state -in @('present', 'partial')) {
    $typescriptSource = Get-JavaScriptVersionSource -Source 'npm-registry-dist-tags:typescript' -Uri 'https://registry.npmjs.org/-/package/typescript/dist-tags' -EvidenceId 'javascript.version-intelligence.typescript-source'
    $typescriptVersionResult = Resolve-TypeScriptVersionIntelligence -DecodedSource $typescriptSource -InstalledVersion $typescriptComponents[0].activeVersion
    $typescriptComponents[0].versionIntelligence = $typescriptVersionResult.intelligence

    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.version-intelligence.typescript' -Type derived -Source 'TypeScript stable and prerelease channel interpretation' -Captured $null -Attributes @{
        installedVersion = $(if ($typescriptComponents[0].activeVersion) { $typescriptComponents[0].activeVersion.normalized } else { $null })
        latestStable = $(if ($typescriptVersionResult.latestStable) { $typescriptVersionResult.latestStable.normalized } else { $null })
        latestPrerelease = $(if ($typescriptVersionResult.latestPrerelease) { $typescriptVersionResult.latestPrerelease.normalized } else { $null })
        prereleaseTag = $typescriptVersionResult.prereleaseTag
        stableUpdateAvailable = $typescriptVersionResult.stableUpdateAvailable
        prereleaseRequiresExplicitOptIn = $typescriptVersionResult.prereleaseRequiresExplicitOptIn
        projectCompatibilityOverridesGlobal = $typescriptVersionResult.projectCompatibilityOverridesGlobal
    }))
}

$prismaComponents = @($components | Where-Object { $_.componentId -eq 'prisma' } | Select-Object -First 1)
if ($prismaComponents.Count -eq 1 -and $prismaComponents[0].state -in @('present', 'partial')) {
    $prismaSource = Get-JavaScriptVersionSource -Source 'npm-registry-dist-tags:prisma' -Uri 'https://registry.npmjs.org/-/package/prisma/dist-tags' -EvidenceId 'javascript.version-intelligence.prisma-source'
    $prismaVersionResult = Resolve-PrismaVersionIntelligence -DecodedSource $prismaSource -InstalledVersion $prismaComponents[0].activeVersion
    $prismaComponents[0].versionIntelligence = $prismaVersionResult.intelligence

    $evidence.Add((New-AuditEvidence -EvidenceId 'javascript.version-intelligence.prisma' -Type derived -Source 'Prisma stable and release-candidate channel interpretation' -Captured $null -Attributes @{
        installedVersion = $(if ($prismaComponents[0].activeVersion) { $prismaComponents[0].activeVersion.normalized } else { $null })
        latestStable = $(if ($prismaVersionResult.latestStable) { $prismaVersionResult.latestStable.normalized } else { $null })
        latestReleaseCandidate = $(if ($prismaVersionResult.latestReleaseCandidate) { $prismaVersionResult.latestReleaseCandidate.normalized } else { $null })
        releaseCandidateTag = $prismaVersionResult.releaseCandidateTag
        stableUpdateAvailable = $prismaVersionResult.stableUpdateAvailable
        releaseCandidateRequiresExplicitOptIn = $prismaVersionResult.releaseCandidateRequiresExplicitOptIn
        projectPinsOverrideGlobal = $prismaVersionResult.projectPinsOverrideGlobal
    }))
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
