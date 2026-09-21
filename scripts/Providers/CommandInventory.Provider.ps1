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
        providerId = 'inventory.commands'
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

function Get-FirstOutputLine {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    return (($Text -split [Environment]::NewLine) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
}

$toolSpecs = @(
    @{ Id='heroku-cli'; Label='Heroku CLI'; Command='heroku'; Args=@('--version') },
    @{ Id='git'; Label='Git'; Command='git'; Args=@('--version') },
    @{ Id='github-cli'; Label='GitHub CLI'; Command='gh'; Args=@('--version') },
    @{ Id='docker'; Label='Docker'; Command='docker'; Args=@('--version') },
    @{ Id='docker-compose'; Label='Docker Compose'; Command='docker'; Args=@('compose','version') },
    @{ Id='supabase-cli'; Label='Supabase CLI'; Command='supabase'; Args=@('--version') },
    @{ Id='vercel-cli'; Label='Vercel CLI'; Command='vercel'; Args=@('--version') }
)

foreach ($spec in $toolSpecs) {
    $result = Invoke-AuditCommand -Command $spec.Command -Arguments $spec.Args -TimeoutSeconds 15

    if (-not $result.Found) {
        $components.Add([pscustomobject][ordered]@{
            componentId        = $spec.Id
            name               = $spec.Label
            state              = 'missing'
            installed          = $false
            activeVersion      = $null
            discoveredVersions = @()
            installations      = @()
            commandResolutions = @()
            versionIntelligence = New-NotApplicableVersionIntelligence
        })
        continue
    }

    $evidenceId = "command.$($spec.Id).version"
    $source = (@($spec.Command) + @($spec.Args)) -join ' '
    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type command -Source $source -ExitCode $result.ExitCode -Captured $result.Captured -Redacted:$result.Redacted -Attributes @{
        status = $result.Status
        truncated = $result.Truncated
        timedOut = $result.TimedOut
    }))

    $rawVersion = Get-FirstOutputLine -Text $result.Captured
    $activeVersion = $null
    if (-not [string]::IsNullOrWhiteSpace($rawVersion)) {
        $activeVersion = New-AuditVersionRecord -Raw $rawVersion -Normalized $null -Channel $null
    }

    $state = 'present'
    if ($result.Status -ne 'success') {
        $state = 'partial'
        $hasPartial = $true

        $code = switch ($result.Status) {
            'non-zero' { 'COMMAND_VERSION_NONZERO' }
            'timed-out' { 'COMMAND_VERSION_TIMEOUT' }
            default { 'COMMAND_VERSION_FAILED' }
        }

        $message = switch ($result.Status) {
            'non-zero' { "Version command for '$($spec.Label)' returned exit code $($result.ExitCode)." }
            'timed-out' { "Version command for '$($spec.Label)' exceeded the configured timeout." }
            default { "Version command for '$($spec.Label)' could not be executed successfully." }
        }

        $warnings.Add((New-AuditIssue -Code $code -Message $message -Severity warning -ComponentId $spec.Id -EvidenceIds @($evidenceId)))
    }

    $components.Add([pscustomobject][ordered]@{
        componentId        = $spec.Id
        name               = $spec.Label
        state              = $state
        installed          = $true
        activeVersion      = $activeVersion
        discoveredVersions = $(if ($activeVersion) { @($activeVersion) } else { @() })
        installations      = @()
        commandResolutions = @($result.Resolutions)
        versionIntelligence = New-NotApplicableVersionIntelligence
    })
}

return [pscustomobject][ordered]@{
    providerId = 'inventory.commands'
    category   = 'runtime'
    status     = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial
    observedAt = $Context.ObservedAt
    components = $components.ToArray()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
