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

$osVersion = [Environment]::OSVersion.Version.ToString()
$osCaption = 'Windows'
$osBuild = $null
$osArchitecture = $null

try {
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.Caption) { $osCaption = $os.Caption }
    if ($os.Version) { $osVersion = $os.Version }
    if ($os.BuildNumber) { $osBuild = $os.BuildNumber }
    if ($os.OSArchitecture) { $osArchitecture = $os.OSArchitecture }
}
catch {
    $warnings.Add((New-AuditIssue -Code 'HOST_CIM_UNAVAILABLE' -Message 'Win32_OperatingSystem details could not be read; environment fallbacks were used.' -Severity warning))
}

$windowsVersion = New-AuditVersionRecord -Raw $osVersion -Normalized $osVersion -Channel $null
$evidence.Add((New-AuditEvidence -EvidenceId 'host.windows.version' -Type derived -Source 'Windows operating system' -Captured $osVersion -Attributes @{
    caption = $osCaption
    build = $osBuild
    architecture = $osArchitecture
}))

$components.Add([pscustomobject][ordered]@{
    componentId        = 'windows'
    name               = $osCaption
    state              = 'present'
    installed          = $true
    activeVersion      = $windowsVersion
    discoveredVersions = @($windowsVersion)
    installations      = @()
    commandResolutions = @()
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$powerShellVersionRaw = $PSVersionTable.PSVersion.ToString()
$powerShellVersion = New-AuditVersionRecord -Raw $powerShellVersionRaw -Normalized $powerShellVersionRaw -Channel $null
$evidence.Add((New-AuditEvidence -EvidenceId 'host.powershell.version' -Type derived -Source '$PSVersionTable' -Captured $powerShellVersionRaw -Attributes @{
    edition = $PSVersionTable.PSEdition
}))

$components.Add([pscustomobject][ordered]@{
    componentId        = 'powershell'
    name               = 'PowerShell'
    state              = 'present'
    installed          = $true
    activeVersion      = $powerShellVersion
    discoveredVersions = @($powerShellVersion)
    installations      = @()
    commandResolutions = @()
    versionIntelligence = New-NotApplicableVersionIntelligence
})

return [pscustomobject][ordered]@{
    providerId = 'host.system'
    category   = 'host'
    status     = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray()
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
