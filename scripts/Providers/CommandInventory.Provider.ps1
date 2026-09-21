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

function Get-FirstOutputLine {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    return (($Text -split [Environment]::NewLine) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
}

$toolSpecs = @(
    @{ Id='node'; Label='Node.js'; Command='node'; Args=@('--version') },
    @{ Id='npm'; Label='npm'; Command='npm'; Args=@('--version') },
    @{ Id='pnpm'; Label='pnpm'; Command='pnpm'; Args=@('--version') },
    @{ Id='nvm-windows'; Label='NVM for Windows'; Command='nvm'; Args=@('--version') },
    @{ Id='angular-cli'; Label='Angular CLI'; Command='ng'; Args=@('version') },
    @{ Id='typescript'; Label='TypeScript'; Command='tsc'; Args=@('--version') },
    @{ Id='prisma'; Label='Prisma'; Command='prisma'; Args=@('--version') },
    @{ Id='nodemon'; Label='Nodemon'; Command='nodemon'; Args=@('--version') },
    @{ Id='rimraf'; Label='Rimraf'; Command='rimraf'; Args=@('--version') },
    @{ Id='zoho-extension-toolkit'; Label='Zoho Extension Toolkit'; Command='zet'; Args=@('-v') },
    @{ Id='zoho-catalyst-cli'; Label='Zoho Catalyst CLI'; Command='catalyst'; Args=@('--version') },
    @{ Id='heroku-cli'; Label='Heroku CLI'; Command='heroku'; Args=@('--version') },
    @{ Id='redis-commander'; Label='Redis Commander'; Command='redis-commander'; Args=@('--version') },
    @{ Id='flutter'; Label='Flutter'; Command='flutter'; Args=@('--version') },
    @{ Id='dart'; Label='Dart'; Command='dart'; Args=@('--version') },
    @{ Id='python'; Label='Python'; Command='python'; Args=@('--version') },
    @{ Id='python-launcher'; Label='Python Launcher'; Command='py'; Args=@('--version') },
    @{ Id='pip'; Label='pip'; Command='pip'; Args=@('--version') },
    @{ Id='pipx'; Label='pipx'; Command='pipx'; Args=@('--version') },
    @{ Id='uv'; Label='uv'; Command='uv'; Args=@('--version') },
    @{ Id='java'; Label='Java'; Command='java'; Args=@('-version') },
    @{ Id='javac'; Label='Javac'; Command='javac'; Args=@('-version') },
    @{ Id='maven'; Label='Maven'; Command='mvn'; Args=@('-version') },
    @{ Id='gradle'; Label='Gradle'; Command='gradle'; Args=@('--version') },
    @{ Id='dotnet-sdk'; Label='.NET SDK'; Command='dotnet'; Args=@('--version') },
    @{ Id='rust'; Label='Rust'; Command='rustc'; Args=@('--version') },
    @{ Id='cargo'; Label='Cargo'; Command='cargo'; Args=@('--version') },
    @{ Id='rustup'; Label='Rustup'; Command='rustup'; Args=@('--version') },
    @{ Id='go'; Label='Go'; Command='go'; Args=@('version') },
    @{ Id='git'; Label='Git'; Command='git'; Args=@('--version') },
    @{ Id='github-cli'; Label='GitHub CLI'; Command='gh'; Args=@('--version') },
    @{ Id='docker'; Label='Docker'; Command='docker'; Args=@('--version') },
    @{ Id='docker-compose'; Label='Docker Compose'; Command='docker'; Args=@('compose','version') },
    @{ Id='adb'; Label='ADB'; Command='adb'; Args=@('--version') },
    @{ Id='supabase-cli'; Label='Supabase CLI'; Command='supabase'; Args=@('--version') },
    @{ Id='vercel-cli'; Label='Vercel CLI'; Command='vercel'; Args=@('--version') },
    @{ Id='winget'; Label='WinGet'; Command='winget'; Args=@('--version') }
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
