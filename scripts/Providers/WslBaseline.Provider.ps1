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
        providerId = 'wsl.baseline'
        category   = 'host'
        order      = 15
    }
}

Import-Module (Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Core\VersionIntelligence.Core.psm1') -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$components = New-Object System.Collections.Generic.List[object]
$hasPartial = $false

$offlineProperty = $Context.PSObject.Properties['VersionIntelligenceOffline']
$offline = $null -ne $offlineProperty -and [bool]$offlineProperty.Value
$transportProperty = $Context.PSObject.Properties['VersionIntelligenceTransport']
$transport = if ($null -ne $transportProperty -and $transportProperty.Value -is [scriptblock]) { [scriptblock]$transportProperty.Value } else { $null }
try { $checkedAt = [DateTimeOffset]::Parse([string]$Context.ObservedAt) } catch { $checkedAt = [DateTimeOffset]::UtcNow }

$notApplicable = New-AuditVersionIntelligence -Status not-applicable -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $null -CheckedAt $null -Message $null

function Invoke-WslCommand {
    <#
    .SYNOPSIS
    wsl.exe writes UTF-16 unless WSL_UTF8 is set; the variable applies only to this child and is restored.
    #>
    param([string[]]$Arguments)

    $previous = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try {
        return Invoke-AuditCommand -Command 'wsl' -Arguments $Arguments -TimeoutSeconds 30
    }
    finally {
        $env:WSL_UTF8 = $previous
    }
}

# --version is answered by the WSL service and never starts a distribution.
$versionResult = Invoke-WslCommand -Arguments @('--version')

if (-not $versionResult.Found -or $versionResult.Status -ne 'success') {
    # Inbox WSL 1 on old Windows has no --version; without it there is nothing to update through wsl --update.
    if ($versionResult.Found) {
        $evidence.Add((New-AuditEvidence -EvidenceId 'wsl.version' -Type command -Source 'wsl --version' -ExitCode $versionResult.ExitCode -Captured $versionResult.Captured -Redacted:$versionResult.Redacted -Attributes @{
            status    = $versionResult.Status
            truncated = $versionResult.Truncated
            timedOut  = $versionResult.TimedOut
        }))
    }

    $components.Add([pscustomobject][ordered]@{
        componentId         = 'wsl'
        name                = 'Windows Subsystem for Linux'
        state               = 'missing'
        installed           = $false
        activeVersion       = $null
        discoveredVersions  = @()
        installations       = @()
        commandResolutions  = @()
        versionIntelligence = $notApplicable
    })
}
else {
    $evidence.Add((New-AuditEvidence -EvidenceId 'wsl.version' -Type command -Source 'wsl --version' -ExitCode $versionResult.ExitCode -Captured $versionResult.Captured -Redacted:$versionResult.Redacted -Attributes @{
        status    = $versionResult.Status
        truncated = $versionResult.Truncated
        timedOut  = $versionResult.TimedOut
    }))

    # Labels are localized ("WSL version", "Version de WSL"); the first line always carries the WSL version.
    $firstLine = @(([string]$versionResult.Captured) -split '\r?\n' | Where-Object { $_ -match '\d+\.\d+' } | Select-Object -First 1)
    $activeVersion = $null
    if ($firstLine.Count -gt 0) {
        $number = [regex]::Match($firstLine[0], '\d+(?:\.\d+){1,3}').Value
        $activeVersion = New-AuditVersionRecord -Raw $firstLine[0].Trim() -Normalized $number -Channel $null
    }

    $state = 'present'
    if ($null -eq $activeVersion) {
        $state = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'WSL_VERSION_UNKNOWN' -Message 'The WSL version could not be read.' -Severity warning -ComponentId 'wsl' -EvidenceIds @('wsl.version')))
    }

    # Lists distributions and their state without starting any of them.
    $listResult = Invoke-WslCommand -Arguments @('--list', '--verbose')
    $evidence.Add((New-AuditEvidence -EvidenceId 'wsl.distributions' -Type command -Source 'wsl --list --verbose' -ExitCode $listResult.ExitCode -Captured $listResult.Captured -Redacted:$listResult.Redacted -Attributes @{
        status    = $listResult.Status
        truncated = $listResult.Truncated
        timedOut  = $listResult.TimedOut
    }))

    $distributions = New-Object System.Collections.Generic.List[object]
    if ($listResult.Status -eq 'success') {
        foreach ($line in @(([string]$listResult.Captured) -split '\r?\n' | Select-Object -Skip 1)) {
            $match = [regex]::Match($line, '^\s*(\*?)\s*(\S+)\s+(\S+)\s+(\d+)\s*$')
            if ($match.Success) {
                $distributions.Add([pscustomobject][ordered]@{
                    name       = $match.Groups[2].Value
                    default    = $match.Groups[1].Value -eq '*'
                    state      = $match.Groups[3].Value
                    wslVersion = [int]$match.Groups[4].Value
                })
            }
        }
    }
    $evidence.Add((New-AuditEvidence -EvidenceId 'wsl.distributions.normalized' -Type derived -Source 'normalized wsl --list --verbose output' -Captured $null -Attributes @{
        status            = $(if ($listResult.Status -eq 'success') { 'known' } else { 'unavailable' })
        distributionCount = $distributions.Count
        distributions     = $distributions.ToArray()
    }))

    # Latest stable WSL release from GitHub; prereleases are excluded by the releases/latest endpoint.
    $sourceParameters = @{
        Source               = 'github-releases:microsoft/WSL'
        Uri                  = 'https://api.github.com/repos/microsoft/WSL/releases/latest'
        CheckedAt            = $checkedAt
        Offline              = $offline
        MaximumResponseBytes = 262144
    }
    if ($null -ne $transport) { $sourceParameters['Transport'] = $transport }
    $sourceResult = Invoke-AuditVersionSource @sourceParameters
    $evidence.Add((New-AuditEvidence -EvidenceId 'wsl.version-intelligence.source' -Type api -Source 'github-releases:microsoft/WSL' -Captured $null -Attributes (Get-AuditVersionSourceEvidenceAttributes -SourceResult $sourceResult)))
    $parsed = ConvertFrom-AuditVersionSourceJson -SourceResult $sourceResult

    $intelligence = $null
    $tag = if ($parsed.status -eq 'known' -and $null -ne $parsed.data.PSObject.Properties['tag_name']) { [string]$parsed.data.tag_name } else { '' }
    if ($parsed.status -eq 'known' -and $tag -match '^v?(\d+(?:\.\d+){1,3})$') {
        $latest = New-AuditVersionRecord -Raw $tag -Normalized $Matches[1] -Channel 'stable'
        $intelligence = New-AuditVersionIntelligence -Status known -LatestStable $latest -LatestLts $null -LatestCurrent $null -Source $parsed.source -CheckedAt $parsed.checkedAt -Message 'Latest stable WSL release; wsl --update installs it.'
    }
    else {
        $status = if ($parsed.status -eq 'known') { 'unknown' } else { $parsed.status }
        $message = if ($parsed.status -eq 'known') { 'The latest WSL release tag was not a version.' } else { $parsed.message }
        $intelligence = New-AuditVersionIntelligence -Status $status -LatestStable $null -LatestLts $null -LatestCurrent $null -Source $parsed.source -CheckedAt $parsed.checkedAt -Message $message
    }

    $components.Add([pscustomobject][ordered]@{
        componentId         = 'wsl'
        name                = 'Windows Subsystem for Linux'
        state               = $state
        installed           = $true
        activeVersion       = $activeVersion
        discoveredVersions  = @(if ($null -ne $activeVersion) { $activeVersion })
        installations       = @()
        commandResolutions  = @($versionResult.Resolutions)
        versionIntelligence = $intelligence
    })
}

$status = if ($components[0].state -eq 'missing') { 'unavailable' } else { Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial }

return [pscustomobject][ordered]@{
    providerId = 'wsl.baseline'
    category   = 'host'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
