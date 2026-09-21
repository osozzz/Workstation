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
        providerId = 'python.ecosystem'
        category   = 'runtime'
        order      = 24
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

function Get-VersionRecordFromText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match(
        $Text,
        '(?i)(?<![0-9A-Za-z])(?<version>\d+\.\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.-]+)?)'
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

    return New-AuditVersionRecord -Raw $raw -Normalized $normalized -Channel $null
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
        foreach ($property in @($InputObject.PSObject.Properties)) {
            if ([string]::Equals(
                [string]$property.Name,
                $name,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                return $property.Value
            }
        }
    }

    return $null
}

function Test-SafePythonExecutablePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if ($Path -match '(?i)\\Microsoft\\WindowsApps\\') {
        return $false
    }

    if ($Path -match '(?i)PythonSoftwareFoundation\.PythonManager') {
        return $false
    }

    $leaf = Split-Path -Leaf $Path
    if ($leaf -notmatch '(?i)^python(?:\d+(?:\.\d+)*)?\.exe$') {
        return $false
    }

    return Test-Path -LiteralPath $Path -PathType Leaf
}

function Get-PythonVersionFromExecutable {
    param([Parameter(Mandatory)][string]$Path)

    $result = Invoke-AuditCommand -Command $Path -Arguments @('--version') -TimeoutSeconds 15
    $version = if ($result.Status -eq 'success') {
        Get-VersionRecordFromText -Text $result.Captured
    }
    else {
        $null
    }

    return [pscustomobject][ordered]@{
        result  = $result
        version = $version
    }
}

function Add-PythonMapping {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,

        [AllowNull()][string]$Path,
        [AllowNull()][string]$Tag,
        [AllowNull()][string]$Company,
        [AllowNull()][string]$VersionText,
        [AllowNull()][bool]$Default,
        [Parameter(Mandatory)][string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    foreach ($existing in $List) {
        if (Test-PathEquals -Left ([string]$existing.path) -Right $Path) {
            if ($Default) {
                $existing.default = $true
            }
            return
        }
    }

    $version = if (-not [string]::IsNullOrWhiteSpace($VersionText)) {
        Get-VersionRecordFromText -Text $VersionText
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Tag)) {
        Get-VersionRecordFromText -Text $Tag
    }
    else {
        $null
    }

    $List.Add([pscustomobject][ordered]@{
        path    = $Path
        tag     = $Tag
        company = $Company
        version = $version
        default = [bool]$Default
        source  = $Source
    })
}

function Add-PyManagerJsonMappings {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List
    )

    if ($null -eq $InputObject) {
        return
    }

    if (
        $InputObject -is [System.Collections.IEnumerable] -and
        $InputObject -isnot [string] -and
        $InputObject.PSObject.Properties.Count -eq 0
    ) {
        foreach ($item in @($InputObject)) {
            Add-PyManagerJsonMappings -InputObject $item -List $List
        }
        return
    }

    $path = [string](Get-FirstJsonPropertyValue -InputObject $InputObject -Names @(
        'executable',
        'executablePath',
        'path',
        'runtime'
    ))

    if (-not [string]::IsNullOrWhiteSpace($path) -and $path -match '(?i)python.*\.exe$') {
        $tag = [string](Get-FirstJsonPropertyValue -InputObject $InputObject -Names @(
            'tag',
            'id',
            'displayName',
            'name'
        ))
        $company = [string](Get-FirstJsonPropertyValue -InputObject $InputObject -Names @(
            'company',
            'vendor',
            'provider'
        ))
        $versionText = [string](Get-FirstJsonPropertyValue -InputObject $InputObject -Names @(
            'version',
            'sysVersion',
            'runtimeVersion'
        ))
        $defaultValue = Get-FirstJsonPropertyValue -InputObject $InputObject -Names @(
            'default',
            'isDefault',
            'current'
        )

        Add-PythonMapping -List $List -Path $path -Tag $tag -Company $company -VersionText $versionText -Default ([bool]$defaultValue) -Source 'python-install-manager'
    }

    foreach ($property in @($InputObject.PSObject.Properties)) {
        $value = $property.Value
        if ($null -eq $value -or $value -is [string]) {
            continue
        }

        if (
            $value -is [System.Collections.IEnumerable] -and
            $value -isnot [string]
        ) {
            foreach ($item in @($value)) {
                Add-PyManagerJsonMappings -InputObject $item -List $List
            }
            continue
        }

        if ($value.PSObject.Properties.Count -gt 0) {
            Add-PyManagerJsonMappings -InputObject $value -List $List
        }
    }
}

function Get-RegistryPythonMappings {
    $mappings = New-Object System.Collections.Generic.List[object]
    $roots = @(
        'HKCU:\SOFTWARE\Python',
        'HKLM:\SOFTWARE\Python',
        'HKLM:\SOFTWARE\WOW6432Node\Python'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        try {
            foreach ($companyKey in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
                foreach ($tagKey in @(Get-ChildItem -LiteralPath $companyKey.PSPath -ErrorAction SilentlyContinue)) {
                    $installPathKey = Join-Path $tagKey.PSPath 'InstallPath'
                    if (-not (Test-Path -LiteralPath $installPathKey)) {
                        continue
                    }

                    $registryItem = Get-Item -LiteralPath $installPathKey -ErrorAction SilentlyContinue
                    if ($null -eq $registryItem) {
                        continue
                    }

                    $rootPath = [string]$registryItem.GetValue('')
                    $executablePath = [string]$registryItem.GetValue('ExecutablePath')

                    if ([string]::IsNullOrWhiteSpace($executablePath) -and -not [string]::IsNullOrWhiteSpace($rootPath)) {
                        $candidate = Join-Path $rootPath 'python.exe'
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                            $executablePath = $candidate
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($executablePath)) {
                        continue
                    }

                    Add-PythonMapping -List $mappings -Path $executablePath -Tag $tagKey.PSChildName -Company $companyKey.PSChildName -VersionText $tagKey.PSChildName -Default $false -Source 'registry'
                }
            }
        }
        catch {
            $script:hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'PYTHON_REGISTRY_ENUMERATION_PARTIAL' -Message "Python registry source '$root' could not be enumerated completely." -Severity warning -ComponentId 'python' -EvidenceIds @('python.registry')))
        }
    }

    return $mappings.ToArray()
}

function New-SimpleCommandComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $result = Invoke-AuditCommand -Command $Command -Arguments $Arguments -TimeoutSeconds 20

    if (-not $result.Found) {
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

    $evidenceId = "python.$ComponentId.version"
    $version = if ($result.Status -eq 'success') {
        Get-VersionRecordFromText -Text $result.Captured
    }
    else {
        $null
    }

    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type command -Source ((@($Command) + @($Arguments)) -join ' ') -ExitCode $result.ExitCode -Captured $result.Captured -Redacted:$result.Redacted -Attributes @{
        status          = $result.Status
        truncated       = $result.Truncated
        timedOut        = $result.TimedOut
        resolutionCount = @($result.Resolutions).Count
    }))

    $state = 'present'
    if ($result.Status -ne 'success' -or $null -eq $version) {
        $state = 'partial'
        $script:hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'PYTHON_TOOL_VERSION_INCOMPLETE' -Message "Version detection for '$Name' was incomplete." -Severity warning -ComponentId $ComponentId -EvidenceIds @($evidenceId)))
    }

    $installations = @(
        $result.Resolutions |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path    = $_.path
                    version = $(if ($_.active) { $version } else { $_.version })
                    active  = [bool]$_.active
                    source  = 'command'
                }
            }
    )

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = $Name
        state               = $state
        installed           = $true
        activeVersion       = $version
        discoveredVersions  = $(if ($null -ne $version) { @($version) } else { @() })
        installations       = $installations
        commandResolutions  = @($result.Resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    }
}

$environmentSnapshot = Get-AuditEnvironmentSnapshot -Names @('PYENV_ROOT')
$pyenvRoot = Get-EffectiveEnvironmentValue -Snapshot $environmentSnapshot -Name 'PYENV_ROOT'

$evidence.Add((New-AuditEvidence -EvidenceId 'python.environment' -Type environment -Source 'PYENV_ROOT' -Captured $null -Attributes @{
    variables = @($environmentSnapshot)
    pyenvRootConfigured = -not [string]::IsNullOrWhiteSpace($pyenvRoot)
}))

$pythonResolutions = @(Get-AuditCommandResolution -Command 'python')
$pythonInstallations = New-Object System.Collections.Generic.List[object]
$pythonVersions = New-Object System.Collections.Generic.List[object]
$activePythonVersion = $null
$activePythonPath = $null
$unsafePythonResolutions = New-Object System.Collections.Generic.List[object]

foreach ($resolution in $pythonResolutions) {
    $path = [string]$resolution.path
    if (-not (Test-SafePythonExecutablePath -Path $path)) {
        $unsafePythonResolutions.Add($resolution)
        continue
    }

    $probe = Get-PythonVersionFromExecutable -Path $path
    $version = $probe.version

    if ($resolution.active) {
        $activePythonPath = $path
        $activePythonVersion = $version
    }

    Add-UniqueInstallation -List $pythonInstallations -Path $path -Version $version -Active ([bool]$resolution.active) -Source command
    Add-UniqueVersion -List $pythonVersions -Version $version
}

$evidence.Add((New-AuditEvidence -EvidenceId 'python.command-resolution' -Type command -Source 'Get-Command python -All plus safe direct --version probes' -Captured $null -Attributes @{
    resolutionCount = $pythonResolutions.Count
    safeResolutionCount = $pythonInstallations.Count
    unsafeResolutionCount = $unsafePythonResolutions.Count
    unsafeResolutions = @(
        $unsafePythonResolutions |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path = $_.path
                    commandType = $_.commandType
                    precedence = $_.precedence
                    active = $_.active
                }
            }
    )
}))

$pyResolutions = @(Get-AuditCommandResolution -Command 'py')
$pyMappings = New-Object System.Collections.Generic.List[object]
$pyListMode = $null
$pyListResult = $null

if ($pyResolutions.Count -gt 0) {
    $modernList = Invoke-AuditCommand -Command 'py' -Arguments @('list', '--format=json') -TimeoutSeconds 20

    if ($modernList.Status -eq 'success' -and -not [string]::IsNullOrWhiteSpace($modernList.Captured)) {
        try {
            $parsed = $modernList.Captured | ConvertFrom-Json -ErrorAction Stop
            Add-PyManagerJsonMappings -InputObject $parsed -List $pyMappings
            $pyListMode = 'modern-json'
            $pyListResult = $modernList
        }
        catch {
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'PY_MANAGER_LIST_JSON_PARSE_FAILED' -Message 'Python install manager runtime JSON could not be parsed.' -Severity warning -ComponentId 'python-launcher' -EvidenceIds @('python.launcher-list')))
        }
    }

    if ($null -eq $pyListMode) {
        $legacyList = Invoke-AuditCommand -Command 'py' -Arguments @('-0p') -TimeoutSeconds 20
        if ($legacyList.Status -eq 'success') {
            foreach ($line in @($legacyList.Captured -split '\r?\n')) {
                $match = [regex]::Match(
                    $line,
                    '^\s*-(?:V:)?(?<tag>[^\s*]+)\s*(?<default>\*)?\s*(?<path>[A-Za-z]:\\.+?python(?:\d+(?:\.\d+)*)?\.exe)\s*$',
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
                if (-not $match.Success) {
                    continue
                }

                Add-PythonMapping -List $pyMappings -Path $match.Groups['path'].Value.Trim() -Tag $match.Groups['tag'].Value.Trim() -Company $null -VersionText $match.Groups['tag'].Value.Trim() -Default $match.Groups['default'].Success -Source 'legacy-launcher'
            }

            $pyListMode = 'legacy-0p'
            $pyListResult = $legacyList
        }
        elseif ($modernList.Found) {
            $hasPartial = $true
            $warnings.Add((New-AuditIssue -Code 'PY_LAUNCHER_LIST_FAILED' -Message 'The py command is resolvable, but installed runtime enumeration failed in both modern and legacy read-only modes.' -Severity warning -ComponentId 'python-launcher' -EvidenceIds @('python.launcher-list')))
            $pyListResult = $modernList
        }
    }

    if ($null -ne $pyListResult) {
        $evidence.Add((New-AuditEvidence -EvidenceId 'python.launcher-list' -Type command -Source $(if ($pyListMode -eq 'modern-json') { 'py list --format=json' } elseif ($pyListMode -eq 'legacy-0p') { 'py -0p' } else { 'py list --format=json / py -0p fallback' }) -ExitCode $pyListResult.ExitCode -Captured $pyListResult.Captured -Sensitive -Attributes @{
            status = $pyListResult.Status
            mode = $pyListMode
            mappingCount = $pyMappings.Count
        }))
    }
}

foreach ($mapping in $pyMappings) {
    Add-UniqueInstallation -List $pythonInstallations -Path ([string]$mapping.path) -Version $mapping.version -Active $(if (-not [string]::IsNullOrWhiteSpace($activePythonPath)) { Test-PathEquals -Left ([string]$mapping.path) -Right $activePythonPath } else { [bool]$mapping.default }) -Source package-manager
    Add-UniqueVersion -List $pythonVersions -Version $mapping.version

    if ($null -eq $activePythonVersion -and $mapping.default) {
        $activePythonVersion = $mapping.version
    }
}

$registryMappings = @(Get-RegistryPythonMappings)
foreach ($mapping in $registryMappings) {
    Add-UniqueInstallation -List $pythonInstallations -Path ([string]$mapping.path) -Version $mapping.version -Active $(if (-not [string]::IsNullOrWhiteSpace($activePythonPath)) { Test-PathEquals -Left ([string]$mapping.path) -Right $activePythonPath } else { $false }) -Source registry
    Add-UniqueVersion -List $pythonVersions -Version $mapping.version
}

$evidence.Add((New-AuditEvidence -EvidenceId 'python.registry' -Type registry -Source 'PEP 514 Python registry registrations' -Captured $null -Attributes @{
    mappingCount = $registryMappings.Count
    mappings = @(
        $registryMappings |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path = $_.path
                    tag = $_.tag
                    company = $_.company
                    version = $(if ($null -ne $_.version) { $_.version.normalized } else { $null })
                }
            }
    )
}))

if ($pythonResolutions.Count -gt 1) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'PYTHON_COMMAND_COLLISION' -Message 'Multiple python command resolutions were detected. Precedence is preserved instead of silently collapsing them.' -Severity warning -ComponentId 'python' -EvidenceIds @('python.command-resolution')))
}

if (@($unsafePythonResolutions | Where-Object active).Count -gt 0) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'PYTHON_ACTIVE_ALIAS_NOT_EXECUTED' -Message 'The active python resolution is a Windows app/manager alias and was intentionally not executed to avoid automatic installation side effects.' -Severity warning -ComponentId 'python' -EvidenceIds @('python.command-resolution', 'python.launcher-list')))
}

$pythonState = if ($null -ne $activePythonVersion -and $unsafePythonResolutions.Count -eq 0) {
    'present'
}
elseif ($pythonInstallations.Count -gt 0 -or $pythonResolutions.Count -gt 0) {
    'partial'
}
else {
    'missing'
}

$pythonInstalled = if ($pythonInstallations.Count -gt 0) {
    $true
}
elseif ($pythonResolutions.Count -gt 0) {
    $null
}
else {
    $false
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'python'
    name                = 'Python'
    state               = $pythonState
    installed           = $pythonInstalled
    activeVersion       = $activePythonVersion
    discoveredVersions  = $pythonVersions.ToArray()
    installations       = $pythonInstallations.ToArray()
    commandResolutions  = $pythonResolutions
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$launcherVersions = New-Object System.Collections.Generic.List[object]
foreach ($mapping in $pyMappings) {
    Add-UniqueVersion -List $launcherVersions -Version $mapping.version
}

$launcherInstallations = @(
    $pyResolutions |
        ForEach-Object {
            [pscustomobject][ordered]@{
                path = $_.path
                version = $null
                active = [bool]$_.active
                source = 'command'
            }
        }
)

$launcherState = if ($pyResolutions.Count -gt 0 -and $null -ne $pyListMode) {
    'present'
}
elseif ($pyResolutions.Count -gt 0) {
    'partial'
}
else {
    'missing'
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'python-launcher'
    name                = 'Python Windows Launcher / Install Manager'
    state               = $launcherState
    installed           = $(if ($pyResolutions.Count -gt 0) { $true } else { $false })
    activeVersion       = $null
    discoveredVersions  = $launcherVersions.ToArray()
    installations       = $launcherInstallations
    commandResolutions  = $pyResolutions
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$directPipResult = Invoke-AuditCommand -Command 'pip' -Arguments @('--version') -TimeoutSeconds 20
$modulePipResult = $null
$modulePipVersion = $null

if (-not [string]::IsNullOrWhiteSpace($activePythonPath) -and (Test-SafePythonExecutablePath -Path $activePythonPath)) {
    $modulePipResult = Invoke-AuditCommand -Command $activePythonPath -Arguments @('-m', 'pip', '--version') -TimeoutSeconds 20
    if ($modulePipResult.Status -eq 'success') {
        $modulePipVersion = Get-VersionRecordFromText -Text $modulePipResult.Captured
    }

    $evidence.Add((New-AuditEvidence -EvidenceId 'python.pip-module.version' -Type command -Source 'active python -m pip --version' -ExitCode $modulePipResult.ExitCode -Captured $modulePipResult.Captured -Redacted:$modulePipResult.Redacted -Attributes @{
        status = $modulePipResult.Status
        timedOut = $modulePipResult.TimedOut
    }))
}

$directPipVersion = if ($directPipResult.Found -and $directPipResult.Status -eq 'success') {
    Get-VersionRecordFromText -Text $directPipResult.Captured
}
else {
    $null
}

if ($directPipResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'python.pip.version' -Type command -Source 'pip --version' -ExitCode $directPipResult.ExitCode -Captured $directPipResult.Captured -Redacted:$directPipResult.Redacted -Attributes @{
        status = $directPipResult.Status
        resolutionCount = @($directPipResult.Resolutions).Count
    }))
}

$pipVersion = if ($null -ne $directPipVersion) { $directPipVersion } else { $modulePipVersion }
$pipVersions = New-Object System.Collections.Generic.List[object]
Add-UniqueVersion -List $pipVersions -Version $directPipVersion
Add-UniqueVersion -List $pipVersions -Version $modulePipVersion

$pipInstallations = New-Object System.Collections.Generic.List[object]
foreach ($resolution in @($directPipResult.Resolutions)) {
    Add-UniqueInstallation -List $pipInstallations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $directPipVersion } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
}

$pipState = if ($null -ne $pipVersion) {
    'present'
}
elseif ($directPipResult.Found -or $null -ne $modulePipResult) {
    'partial'
}
else {
    'missing'
}

if ($pythonState -in @('present', 'partial') -and $pipState -eq 'missing') {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'PIP_MISSING_FOR_PYTHON' -Message 'Python is available, but pip could not be detected for the active interpreter or as a command.' -Severity warning -ComponentId 'pip' -EvidenceIds @('python.command-resolution')))
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'pip'
    name                = 'pip'
    state               = $pipState
    installed           = $(if ($pipState -eq 'missing') { $false } else { $true })
    activeVersion       = $pipVersion
    discoveredVersions  = $pipVersions.ToArray()
    installations       = $pipInstallations.ToArray()
    commandResolutions  = @($directPipResult.Resolutions)
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$components.Add((New-SimpleCommandComponent -ComponentId 'pipx' -Name 'pipx' -Command 'pipx' -Arguments @('--version')))
$components.Add((New-SimpleCommandComponent -ComponentId 'uv' -Name 'uv' -Command 'uv' -Arguments @('--version')))

$pyenvResult = Invoke-AuditCommand -Command 'pyenv' -Arguments @('--version') -TimeoutSeconds 20
$pyenvVersion = if ($pyenvResult.Found -and $pyenvResult.Status -eq 'success') {
    Get-VersionRecordFromText -Text $pyenvResult.Captured
}
else {
    $null
}

$pyenvVersionsResult = $null
if ($pyenvResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'python.pyenv.version' -Type command -Source 'pyenv --version' -ExitCode $pyenvResult.ExitCode -Captured $pyenvResult.Captured -Redacted:$pyenvResult.Redacted -Attributes @{
        status = $pyenvResult.Status
        resolutionCount = @($pyenvResult.Resolutions).Count
    }))

    $pyenvVersionsResult = Invoke-AuditCommand -Command 'pyenv' -Arguments @('versions', '--bare') -TimeoutSeconds 20
    $evidence.Add((New-AuditEvidence -EvidenceId 'python.pyenv.versions' -Type command -Source 'pyenv versions --bare' -ExitCode $pyenvVersionsResult.ExitCode -Captured $pyenvVersionsResult.Captured -Redacted:$pyenvVersionsResult.Redacted -Attributes @{
        status = $pyenvVersionsResult.Status
    }))
}

$pyenvState = if ($pyenvResult.Found -and $pyenvResult.Status -eq 'success') {
    'present'
}
elseif ($pyenvResult.Found -or -not [string]::IsNullOrWhiteSpace($pyenvRoot)) {
    'partial'
}
else {
    'missing'
}

if (-not $pyenvResult.Found -and -not [string]::IsNullOrWhiteSpace($pyenvRoot)) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'PYENV_ROOT_COMMAND_UNRESOLVED' -Message 'PYENV_ROOT is configured, but the pyenv command is not resolvable.' -Severity warning -ComponentId 'pyenv-win' -EvidenceIds @('python.environment')))
}

$pyenvInstallations = @(
    $pyenvResult.Resolutions |
        ForEach-Object {
            [pscustomobject][ordered]@{
                path = $_.path
                version = $(if ($_.active) { $pyenvVersion } else { $_.version })
                active = [bool]$_.active
                source = 'command'
            }
        }
)

$components.Add([pscustomobject][ordered]@{
    componentId         = 'pyenv-win'
    name                = 'pyenv-win'
    state               = $pyenvState
    installed           = $(if ($pyenvResult.Found) { $true } elseif (-not [string]::IsNullOrWhiteSpace($pyenvRoot)) { $null } else { $false })
    activeVersion       = $pyenvVersion
    discoveredVersions  = $(if ($null -ne $pyenvVersion) { @($pyenvVersion) } else { @() })
    installations       = $pyenvInstallations
    commandResolutions  = @($pyenvResult.Resolutions)
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$evidence.Add((New-AuditEvidence -EvidenceId 'python.installations' -Type derived -Source 'normalized Python interpreter inventory' -Captured $null -Attributes @{
    installations = @(
        $pythonInstallations |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path = $_.path
                    version = $(if ($null -ne $_.version) { $_.version.normalized } else { $null })
                    active = $_.active
                    source = $_.source
                }
            }
    )
    launcherMappings = @(
        $pyMappings |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    path = $_.path
                    tag = $_.tag
                    company = $_.company
                    version = $(if ($null -ne $_.version) { $_.version.normalized } else { $null })
                    default = $_.default
                    source = $_.source
                }
            }
    )
}))

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
    providerId = 'python.ecosystem'
    category   = 'runtime'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
