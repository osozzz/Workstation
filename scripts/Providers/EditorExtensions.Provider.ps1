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
        providerId = 'editors.extensions'
        category   = 'editor'
        order      = 45
    }
}

Import-Module (Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1') -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$components = New-Object System.Collections.Generic.List[object]
$hasPartial = $false

$notApplicable = [pscustomobject][ordered]@{
    status        = 'not-applicable'
    latestStable  = $null
    latestLts     = $null
    latestCurrent = $null
    source        = $null
    checkedAt     = $null
    message       = $null
}

# VS Code and its forks share the same CLI: --version, --list-extensions --show-versions, --update-extensions.
$editors = @(
    @{ Id = 'vscode'; Name = 'Visual Studio Code'; Cli = 'code' }
    @{ Id = 'cursor'; Name = 'Cursor'; Cli = 'cursor' }
    @{ Id = 'windsurf'; Name = 'Windsurf'; Cli = 'windsurf' }
    @{ Id = 'trae'; Name = 'Trae'; Cli = 'trae' }
)

foreach ($editor in $editors) {
    $versionResult = Invoke-AuditCommand -Command $editor.Cli -Arguments @('--version') -TimeoutSeconds 60
    if (-not $versionResult.Found) {
        $components.Add([pscustomobject][ordered]@{
            componentId         = $editor.Id
            name                = $editor.Name
            state               = 'missing'
            installed           = $false
            activeVersion       = $null
            discoveredVersions  = @()
            installations       = @()
            commandResolutions  = @()
            versionIntelligence = $notApplicable
        })
        continue
    }

    $versionEvidenceId = "editors.$($editor.Id).version"
    $evidence.Add((New-AuditEvidence -EvidenceId $versionEvidenceId -Type command -Source "$($editor.Cli) --version" -ExitCode $versionResult.ExitCode -Captured $versionResult.Captured -Redacted:$versionResult.Redacted -Attributes @{
        status    = $versionResult.Status
        truncated = $versionResult.Truncated
        timedOut  = $versionResult.TimedOut
    }))
    $firstLine = @(([string]$versionResult.Captured) -split '\r?\n' | Where-Object { $_ -match '^\s*\d+\.\d+' } | Select-Object -First 1)
    $activeVersion = $null
    if ($firstLine.Count -gt 0) {
        $activeVersion = New-AuditVersionRecord -Raw $firstLine[0].Trim() -Normalized ([regex]::Match($firstLine[0], '\d+(?:\.\d+){1,3}').Value) -Channel $null
    }

    $listResult = Invoke-AuditCommand -Command $editor.Cli -Arguments @('--list-extensions', '--show-versions') -TimeoutSeconds 120 -MaximumCaptureLength 262144
    $listEvidenceId = "editors.$($editor.Id).extensions"
    $evidence.Add((New-AuditEvidence -EvidenceId $listEvidenceId -Type command -Source "$($editor.Cli) --list-extensions --show-versions" -ExitCode $listResult.ExitCode -Captured $listResult.Captured -Redacted:$listResult.Redacted -Attributes @{
        status    = $listResult.Status
        truncated = $listResult.Truncated
        timedOut  = $listResult.TimedOut
    }))

    $extensions = New-Object System.Collections.Generic.List[object]
    if ($listResult.Status -eq 'success') {
        foreach ($line in ([string]$listResult.Captured -split '\r?\n')) {
            $match = [regex]::Match($line.Trim(), '^(?<id>[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9._-]*)@(?<version>\S+)$')
            if ($match.Success) { $extensions.Add([pscustomobject][ordered]@{ id = $match.Groups['id'].Value; version = $match.Groups['version'].Value }) }
        }
    }
    $evidence.Add((New-AuditEvidence -EvidenceId "$listEvidenceId.normalized" -Type derived -Source "normalized $($editor.Cli) extension list" -Captured $null -Attributes @{
        status         = $(if ($listResult.Status -eq 'success') { 'known' } else { 'unavailable' })
        extensionCount = $extensions.Count
        extensions     = $extensions.ToArray()
    }))

    $state = 'present'
    if ($null -eq $activeVersion -or $listResult.Status -ne 'success') {
        $state = 'partial'
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'EDITOR_EXTENSIONS_UNKNOWN' -Message "$($editor.Name) was found, but its version or extension list could not be read." -Severity warning -ComponentId $editor.Id -EvidenceIds @($versionEvidenceId, $listEvidenceId)))
    }

    $components.Add([pscustomobject][ordered]@{
        componentId         = $editor.Id
        name                = $editor.Name
        state               = $state
        installed           = $true
        activeVersion       = $activeVersion
        discoveredVersions  = @(if ($null -ne $activeVersion) { $activeVersion })
        installations       = @(foreach ($resolution in @($versionResult.Resolutions)) {
                [pscustomobject][ordered]@{ path = [string]$resolution.path; version = $activeVersion; active = [bool]$resolution.active; source = 'command' }
            })
        commandResolutions  = @($versionResult.Resolutions)
        versionIntelligence = $notApplicable
    })
}

$anyPresent = @($components | Where-Object { $_.state -in @('present', 'partial') }).Count -gt 0
$status = if (-not $anyPresent) { 'unavailable' } else { Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial }

return [pscustomobject][ordered]@{
    providerId = 'editors.extensions'
    category   = 'editor'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
