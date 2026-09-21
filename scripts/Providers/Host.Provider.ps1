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
        providerId = 'host.system'
        category   = 'host'
        order      = 10
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

function Get-NormalizedSemanticVersion {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $match = [regex]::Match($Value, '\d+(?:\.\d+){1,3}')
    if ($match.Success) {
        return $match.Value
    }

    return $null
}

function Get-FirstOutputLine {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    return (($Text -split '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
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

        if ($existingKey -eq $key) {
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
            [string]::Equals([string]$existing.path, $Path, [StringComparison]::OrdinalIgnoreCase)
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

function Get-PowerShellComponent {
    param(
        [Parameter(Mandatory)]
        [string]$ComponentId,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$VersionArguments,

        [object[]]$AdditionalInstallations = @()
    )

    $versionResult = Invoke-AuditCommand -Command $Command -Arguments $VersionArguments -TimeoutSeconds 15
    $resolutions = if ($versionResult.Found) {
        @($versionResult.Resolutions)
    }
    else {
        @(Get-AuditCommandResolution -Command $Command)
    }

    $versions = New-Object System.Collections.Generic.List[object]
    $installations = New-Object System.Collections.Generic.List[object]
    $activeVersion = $null
    $state = 'missing'
    $installed = $false

    if ($versionResult.Found) {
        $installed = $true
        $state = 'present'

        $evidenceId = "host.$ComponentId.version"
        $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type command -Source (($Command) + ' ' + ($VersionArguments -join ' ')) -ExitCode $versionResult.ExitCode -Captured $versionResult.Captured -Redacted:$versionResult.Redacted -Attributes @{
            status    = $versionResult.Status
            truncated = $versionResult.Truncated
            timedOut  = $versionResult.TimedOut
        }))

        $rawVersion = Get-FirstOutputLine -Text $versionResult.Captured
        if (-not [string]::IsNullOrWhiteSpace($rawVersion)) {
            $normalized = Get-NormalizedSemanticVersion -Value $rawVersion
            $activeVersion = New-AuditVersionRecord -Raw $rawVersion -Normalized $normalized -Channel $null
            Add-UniqueVersion -List $versions -Version $activeVersion
        }

        if ($versionResult.Status -ne 'success' -or $null -eq $activeVersion) {
            $script:hasPartial = $true
            $state = 'partial'

            $warningCode = if ($versionResult.Status -eq 'timed-out') {
                'POWERSHELL_VERSION_TIMEOUT'
            }
            elseif ($versionResult.Status -eq 'non-zero') {
                'POWERSHELL_VERSION_NONZERO'
            }
            elseif ($versionResult.Status -eq 'failed') {
                'POWERSHELL_VERSION_FAILED'
            }
            else {
                'POWERSHELL_VERSION_UNKNOWN'
            }

            $warnings.Add((New-AuditIssue -Code $warningCode -Message "Version detection for '$Name' was incomplete." -Severity warning -ComponentId $ComponentId -EvidenceIds @($evidenceId)))
        }
    }

    $activeResolutionPath = $null
    $activeResolution = @($resolutions | Where-Object { $_.active } | Select-Object -First 1)
    if ($activeResolution.Count -gt 0) {
        $activeResolutionPath = [string]$activeResolution[0].path
    }

    foreach ($resolution in $resolutions) {
        Add-UniqueInstallation -List $installations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $activeVersion } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
    }

    foreach ($candidate in @($AdditionalInstallations)) {
        $candidateVersion = $candidate.version
        if ($null -ne $candidateVersion) {
            Add-UniqueVersion -List $versions -Version $candidateVersion
        }

        $candidateActive = $false
        if (
            -not [string]::IsNullOrWhiteSpace($activeResolutionPath) -and
            -not [string]::IsNullOrWhiteSpace([string]$candidate.path)
        ) {
            $candidateActive = [string]::Equals(
                [IO.Path]::GetFullPath([string]$candidate.path),
                [IO.Path]::GetFullPath($activeResolutionPath),
                [StringComparison]::OrdinalIgnoreCase
            )
        }

        Add-UniqueInstallation -List $installations -Path ([string]$candidate.path) -Version $candidateVersion -Active $candidateActive -Source ([string]$candidate.source)
    }

    if (-not $installed -and $installations.Count -gt 0) {
        $installed = $true
        $state = 'partial'
        $script:hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'POWERSHELL_COMMAND_UNRESOLVED' -Message "'$Name' installation evidence was found but '$Command' was not resolvable." -Severity warning -ComponentId $ComponentId))
    }

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = $Name
        state               = $state
        installed           = $installed
        activeVersion       = $activeVersion
        discoveredVersions  = $versions.ToArray()
        installations       = $installations.ToArray()
        commandResolutions  = @($resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    }
}

$osVersion = [Environment]::OSVersion.Version.ToString()
$osCaption = 'Windows'
$osBuild = [Environment]::OSVersion.Version.Build.ToString()
$osArchitecture = if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
$displayVersion = $null
$editionId = $null
$ubr = $null
$cimCaptionAvailable = $false
$registryProductName = $null

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($os.Caption) {
        $osCaption = [string]$os.Caption
        $cimCaptionAvailable = $true
    }
    if ($os.Version) { $osVersion = [string]$os.Version }
    if ($os.BuildNumber) { $osBuild = [string]$os.BuildNumber }
    if ($os.OSArchitecture) { $osArchitecture = [string]$os.OSArchitecture }

    $evidence.Add((New-AuditEvidence -EvidenceId 'host.windows.cim' -Type derived -Source 'Win32_OperatingSystem' -Captured $osVersion -Attributes @{
        caption      = $osCaption
        build        = $osBuild
        architecture = $osArchitecture
    }))
}
catch {
    $warnings.Add((New-AuditIssue -Code 'HOST_CIM_UNAVAILABLE' -Message 'Win32_OperatingSystem details could not be read; environment and registry fallbacks were used.' -Severity warning))
}

try {
    $windowsRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $windowsRegistry = Get-ItemProperty -LiteralPath $windowsRegistryPath -ErrorAction Stop

    if ($windowsRegistry.ProductName) {
        $registryProductName = [string]$windowsRegistry.ProductName
        if (-not $cimCaptionAvailable) {
            $osCaption = $registryProductName
        }
    }
    if ($windowsRegistry.DisplayVersion) { $displayVersion = [string]$windowsRegistry.DisplayVersion }
    if ($windowsRegistry.EditionID) { $editionId = [string]$windowsRegistry.EditionID }
    if ($windowsRegistry.CurrentBuildNumber) { $osBuild = [string]$windowsRegistry.CurrentBuildNumber }
    if ($null -ne $windowsRegistry.UBR) { $ubr = [string]$windowsRegistry.UBR }

    $evidence.Add((New-AuditEvidence -EvidenceId 'host.windows.registry' -Type registry -Source $windowsRegistryPath -Captured $null -Attributes @{
        productName    = $registryProductName
        displayVersion = $displayVersion
        editionId      = $editionId
        build           = $osBuild
        ubr             = $ubr
    }))
}
catch {
    $warnings.Add((New-AuditIssue -Code 'HOST_WINDOWS_REGISTRY_UNAVAILABLE' -Message 'Windows CurrentVersion registry details could not be read.' -Severity warning))
}

$normalizedWindowsVersion = Get-NormalizedSemanticVersion -Value $osVersion
$windowsVersion = New-AuditVersionRecord -Raw $osVersion -Normalized $normalizedWindowsVersion -Channel $displayVersion

$components.Add([pscustomobject][ordered]@{
    componentId         = 'windows'
    name                = $osCaption
    state               = 'present'
    installed           = $true
    activeVersion       = $windowsVersion
    discoveredVersions  = @($windowsVersion)
    installations       = @()
    commandResolutions  = @()
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$evidence.Add((New-AuditEvidence -EvidenceId 'host.powershell.current' -Type derived -Source '$PSVersionTable' -Captured $PSVersionTable.PSVersion.ToString() -Attributes @{
    edition = [string]$PSVersionTable.PSEdition
}))

$windowsPowerShellInstallations = New-Object System.Collections.Generic.List[object]
$windowsDirectory = [Environment]::GetFolderPath('Windows')
if (-not [string]::IsNullOrWhiteSpace($windowsDirectory)) {
    foreach ($candidatePath in @(
        (Join-Path $windowsDirectory 'System32\WindowsPowerShell\v1.0\powershell.exe'),
        (Join-Path $windowsDirectory 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe')
    )) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $windowsPowerShellInstallations.Add([pscustomobject]@{
                path    = $candidatePath
                version = $null
                source  = 'filesystem'
            })
        }
    }
}

$windowsPowerShell = Get-PowerShellComponent -ComponentId 'powershell.windows' -Name 'Windows PowerShell' -Command 'powershell.exe' -VersionArguments @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '$PSVersionTable.PSVersion.ToString()'
) -AdditionalInstallations $windowsPowerShellInstallations.ToArray()

$components.Add($windowsPowerShell)

$coreInstallations = New-Object System.Collections.Generic.List[object]
$coreRegistryRecords = New-Object System.Collections.Generic.List[object]

foreach ($registryRoot in @(
    'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\PowerShellCore\InstalledVersions'
)) {
    if (-not (Test-Path -LiteralPath $registryRoot)) {
        continue
    }

    try {
        foreach ($key in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction Stop)) {
            $record = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $semanticVersion = if ($record.SemanticVersion) {
                [string]$record.SemanticVersion
            }
            elseif ($record.Version) {
                [string]$record.Version
            }
            else {
                $null
            }

            $versionRecord = $null
            if (-not [string]::IsNullOrWhiteSpace($semanticVersion)) {
                $versionRecord = New-AuditVersionRecord -Raw $semanticVersion -Normalized (Get-NormalizedSemanticVersion -Value $semanticVersion) -Channel $null
            }

            $installPath = $null
            if ($record.InstallLocation) {
                $installRoot = [string]$record.InstallLocation
                $pwshPath = Join-Path $installRoot 'pwsh.exe'
                $installPath = if (Test-Path -LiteralPath $pwshPath -PathType Leaf) { $pwshPath } else { $installRoot }
            }

            $coreInstallations.Add([pscustomobject]@{
                path    = $installPath
                version = $versionRecord
                source  = 'registry'
            })

            $coreRegistryRecords.Add([pscustomobject]@{
                key             = [string]$key.PSChildName
                semanticVersion = $semanticVersion
                installLocation = if ($record.InstallLocation) { [string]$record.InstallLocation } else { $null }
            })
        }
    }
    catch {
        $warnings.Add((New-AuditIssue -Code 'POWERSHELL_CORE_REGISTRY_PARTIAL' -Message "PowerShell Core registry discovery under '$registryRoot' was incomplete." -Severity warning -ComponentId 'powershell.core'))
        $hasPartial = $true
    }
}

if ($coreRegistryRecords.Count -gt 0) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'host.powershell.core.registry' -Type registry -Source 'PowerShell Core InstalledVersions registry' -Captured $null -Attributes @{
        installations = $coreRegistryRecords.ToArray()
    }))
}

$powerShellCore = Get-PowerShellComponent -ComponentId 'powershell.core' -Name 'PowerShell' -Command 'pwsh.exe' -VersionArguments @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '$PSVersionTable.PSVersion.ToString()'
) -AdditionalInstallations $coreInstallations.ToArray()

$components.Add($powerShellCore)

return [pscustomobject][ordered]@{
    providerId = 'host.system'
    category   = 'host'
    status     = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
