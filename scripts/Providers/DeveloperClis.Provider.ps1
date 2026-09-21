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
        providerId = 'developer.clis'
        category   = 'runtime'
        order      = 27
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
        '(?i)(?<![0-9A-Za-z])v?(?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)'
    )

    if (-not $match.Success) {
        return $null
    }

    return New-AuditVersionRecord -Raw $match.Value -Normalized $match.Groups['version'].Value -Channel $null
}

function Get-VersionRecordFromPattern {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match(
        $Text,
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )

    if (-not $match.Success) {
        return $null
    }

    $versionText = if ($match.Groups['version'].Success) {
        $match.Groups['version'].Value
    }
    else {
        $match.Value
    }

    return New-AuditVersionRecord -Raw $versionText -Normalized $versionText.TrimStart('v') -Channel $null
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
        if (
            [string]::Equals(
                ([string]$existing.path).TrimEnd('\'),
                $Path.TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase
            )
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

function New-VersionCommandComponent {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$EvidenceId,
        [AllowNull()][string]$VersionPattern
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

    $version = if ($result.Status -eq 'success') {
        if (-not [string]::IsNullOrWhiteSpace($VersionPattern)) {
            Get-VersionRecordFromPattern -Text $result.Captured -Pattern $VersionPattern
        }
        else {
            Get-VersionRecordFromText -Text $result.Captured
        }
    }
    else {
        $null
    }

    $evidence.Add((New-AuditEvidence -EvidenceId $EvidenceId -Type command -Source ((@($Command) + @($Arguments)) -join ' ') -ExitCode $result.ExitCode -Captured $result.Captured -Redacted:$result.Redacted -Attributes @{
        status          = $result.Status
        timedOut        = $result.TimedOut
        truncated       = $result.Truncated
        resolutionCount = @($result.Resolutions).Count
    }))

    if (@($result.Resolutions).Count -gt 1) {
        $script:hasPartial = $true
        $warnings.Add((New-AuditIssue -Code "$($ComponentId.ToUpperInvariant().Replace('-', '_'))_COMMAND_COLLISION" -Message "Multiple '$Command' command resolutions were detected. Precedence is preserved instead of silently collapsing them." -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
    }

    $state = 'present'
    if ($result.Status -ne 'success' -or $null -eq $version) {
        $state = 'partial'
        $script:hasPartial = $true
        $warnings.Add((New-AuditIssue -Code "$($ComponentId.ToUpperInvariant().Replace('-', '_'))_VERSION_INCOMPLETE" -Message "Version detection for '$Name' was incomplete." -Severity warning -ComponentId $ComponentId -EvidenceIds @($EvidenceId)))
    }

    $versions = New-Object System.Collections.Generic.List[object]
    Add-UniqueVersion -List $versions -Version $version

    $installations = New-Object System.Collections.Generic.List[object]
    foreach ($resolution in @($result.Resolutions)) {
        Add-UniqueInstallation -List $installations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $version } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
        Add-UniqueVersion -List $versions -Version $resolution.version
    }

    return [pscustomobject][ordered]@{
        componentId         = $ComponentId
        name                = $Name
        state               = $state
        installed           = $true
        activeVersion       = $version
        discoveredVersions  = $versions.ToArray()
        installations       = $installations.ToArray()
        commandResolutions  = @($result.Resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    }
}

$specs = @(
    @{
        ComponentId    = 'git'
        Name           = 'Git'
        Command        = 'git'
        Arguments      = @('--version')
        EvidenceId     = 'developer.git.version'
        VersionPattern = 'git version (?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)'
    },
    @{
        ComponentId    = 'github-cli'
        Name           = 'GitHub CLI'
        Command        = 'gh'
        Arguments      = @('--version')
        EvidenceId     = 'developer.github-cli.version'
        VersionPattern = 'gh version (?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)'
    },
    @{
        ComponentId    = 'docker'
        Name           = 'Docker CLI'
        Command        = 'docker'
        Arguments      = @('--version')
        EvidenceId     = 'developer.docker.version'
        VersionPattern = 'Docker version (?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)'
    },
    @{
        ComponentId    = 'supabase-cli'
        Name           = 'Supabase CLI'
        Command        = 'supabase'
        Arguments      = @('--version')
        EvidenceId     = 'developer.supabase.version'
        VersionPattern = '^(?:Supabase CLI\s+)?v?(?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)\s*$'
    },
    @{
        ComponentId    = 'vercel-cli'
        Name           = 'Vercel CLI'
        Command        = 'vercel'
        Arguments      = @('--version')
        EvidenceId     = 'developer.vercel.version'
        VersionPattern = 'Vercel CLI (?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)'
    },
    @{
        ComponentId    = 'heroku-cli'
        Name           = 'Heroku CLI'
        Command        = 'heroku'
        Arguments      = @('--version')
        EvidenceId     = 'developer.heroku.version'
        VersionPattern = 'heroku/(?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)'
    }
)

foreach ($spec in $specs) {
    $components.Add((New-VersionCommandComponent @spec))
}

$dockerComponent = @($components | Where-Object componentId -eq 'docker' | Select-Object -First 1)
$dockerFound = ($dockerComponent.Count -gt 0 -and $dockerComponent[0].installed -eq $true)

$composeResult = $null
$composeVersion = $null
if ($dockerFound) {
    $composeResult = Invoke-AuditCommand -Command 'docker' -Arguments @('compose', 'version') -TimeoutSeconds 20
    if ($composeResult.Status -eq 'success') {
        $composeVersion = Get-VersionRecordFromPattern -Text $composeResult.Captured -Pattern 'Docker Compose version v?(?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)'
    }
}

$legacyComposeResult = Invoke-AuditCommand -Command 'docker-compose' -Arguments @('--version') -TimeoutSeconds 20
$legacyComposeVersion = if ($legacyComposeResult.Found -and $legacyComposeResult.Status -eq 'success') {
    Get-VersionRecordFromPattern -Text $legacyComposeResult.Captured -Pattern '(?:docker-compose|Docker Compose) version v?(?<version>\d+(?:\.\d+)+(?:[.-][0-9A-Za-z]+)*)'
}
else {
    $null
}

$composeEvidenceIds = New-Object System.Collections.Generic.List[string]

if ($null -ne $composeResult) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'developer.docker-compose.plugin' -Type command -Source 'docker compose version' -ExitCode $composeResult.ExitCode -Captured $composeResult.Captured -Redacted:$composeResult.Redacted -Attributes @{
        status = $composeResult.Status
        timedOut = $composeResult.TimedOut
        mode = 'plugin'
        resolutionCount = @($composeResult.Resolutions).Count
    }))
    $composeEvidenceIds.Add('developer.docker-compose.plugin')
}

if ($legacyComposeResult.Found) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'developer.docker-compose.legacy' -Type command -Source 'docker-compose --version' -ExitCode $legacyComposeResult.ExitCode -Captured $legacyComposeResult.Captured -Redacted:$legacyComposeResult.Redacted -Attributes @{
        status = $legacyComposeResult.Status
        timedOut = $legacyComposeResult.TimedOut
        mode = 'legacy-command'
        resolutionCount = @($legacyComposeResult.Resolutions).Count
    }))
    $composeEvidenceIds.Add('developer.docker-compose.legacy')
}

$composeVersions = New-Object System.Collections.Generic.List[object]
Add-UniqueVersion -List $composeVersions -Version $composeVersion
Add-UniqueVersion -List $composeVersions -Version $legacyComposeVersion

$composeInstallations = New-Object System.Collections.Generic.List[object]
$composeResolutions = New-Object System.Collections.Generic.List[object]

if ($null -ne $composeResult -and $composeResult.Status -eq 'success') {
    foreach ($resolution in @($composeResult.Resolutions)) {
        $composeResolutions.Add($resolution)
    }
}

if ($legacyComposeResult.Found) {
    foreach ($resolution in @($legacyComposeResult.Resolutions)) {
        Add-UniqueInstallation -List $composeInstallations -Path ([string]$resolution.path) -Version $(if ($resolution.active) { $legacyComposeVersion } else { $resolution.version }) -Active ([bool]$resolution.active) -Source command
        $composeResolutions.Add($resolution)
    }
}

$composeState = 'missing'
$composeInstalled = $false
$composeActiveVersion = $null

if ($null -ne $composeResult -and $composeResult.Status -eq 'success' -and $null -ne $composeVersion) {
    $composeState = 'present'
    $composeInstalled = $true
    $composeActiveVersion = $composeVersion
}
elseif ($legacyComposeResult.Found -and $legacyComposeResult.Status -eq 'success' -and $null -ne $legacyComposeVersion) {
    $composeState = 'present'
    $composeInstalled = $true
    $composeActiveVersion = $legacyComposeVersion
    $warnings.Add((New-AuditIssue -Code 'DOCKER_COMPOSE_LEGACY_ONLY' -Message 'Docker Compose is available only through the legacy docker-compose command; the modern docker compose plugin was not proven functional.' -Severity info -ComponentId 'docker-compose' -EvidenceIds $composeEvidenceIds.ToArray()))
}
elseif ($dockerFound -or $legacyComposeResult.Found) {
    $composeState = 'partial'
    $composeInstalled = $null
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DOCKER_COMPOSE_VERSION_INCOMPLETE' -Message 'Docker/Compose tooling is resolvable, but a functional Compose version could not be determined.' -Severity warning -ComponentId 'docker-compose' -EvidenceIds $composeEvidenceIds.ToArray()))
}

if (@($legacyComposeResult.Resolutions).Count -gt 1) {
    $hasPartial = $true
    $warnings.Add((New-AuditIssue -Code 'DOCKER_COMPOSE_LEGACY_COMMAND_COLLISION' -Message 'Multiple legacy docker-compose command resolutions were detected.' -Severity warning -ComponentId 'docker-compose' -EvidenceIds @('developer.docker-compose.legacy')))
}

$components.Add([pscustomobject][ordered]@{
    componentId         = 'docker-compose'
    name                = 'Docker Compose'
    state               = $composeState
    installed           = $composeInstalled
    activeVersion       = $composeActiveVersion
    discoveredVersions  = $composeVersions.ToArray()
    installations       = $composeInstallations.ToArray()
    commandResolutions  = $composeResolutions.ToArray()
    versionIntelligence = New-NotApplicableVersionIntelligence
})

$evidence.Add((New-AuditEvidence -EvidenceId 'developer.safety-boundary' -Type derived -Source 'developer CLI audit boundary' -Captured $null -Attributes @{
    authenticationStateCollected = $false
    accountStateCollected = $false
    gitConfigurationCollected = $false
    dockerDaemonInspected = $false
    dockerContextsCollected = $false
    servicesStartedOrStopped = $false
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
    providerId = 'developer.clis'
    category   = 'runtime'
    status     = $status
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
