Set-StrictMode -Version Latest

$script:AuditEnvironmentAllowList = @(
    'NVM_HOME',
    'NVM_SYMLINK',
    'PNPM_HOME',
    'JAVA_HOME',
    'ANDROID_HOME',
    'ANDROID_SDK_ROOT',
    'FLUTTER_ROOT',
    'PUB_CACHE',
    'CARGO_HOME',
    'RUSTUP_HOME',
    'GOPATH',
    'GOROOT',
    'PYENV_ROOT'
)


function Get-AuditCommandTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo]$CommandInfo
    )

    $pathProperty = $CommandInfo.PSObject.Properties['Path']
    if ($pathProperty -and -not [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
        return [string]$pathProperty.Value
    }

    $definitionProperty = $CommandInfo.PSObject.Properties['Definition']
    if ($definitionProperty -and -not [string]::IsNullOrWhiteSpace([string]$definitionProperty.Value)) {
        return [string]$definitionProperty.Value
    }

    $sourceProperty = $CommandInfo.PSObject.Properties['Source']
    if ($sourceProperty -and -not [string]::IsNullOrWhiteSpace([string]$sourceProperty.Value)) {
        return [string]$sourceProperty.Value
    }

    return $CommandInfo.Name
}

function Limit-AuditCapturedText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text,

        [ValidateRange(1, 1048576)]
        [int]$MaximumLength = 32768
    )

    if ($null -eq $Text) {
        return [pscustomobject][ordered]@{
            Text      = $null
            Truncated = $false
        }
    }

    if ($Text.Length -le $MaximumLength) {
        return [pscustomobject][ordered]@{
            Text      = $Text
            Truncated = $false
        }
    }

    return [pscustomobject][ordered]@{
        Text      = $Text.Substring(0, $MaximumLength)
        Truncated = $true
    }
}

function New-AuditVersionRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Raw,

        [AllowNull()]
        [string]$Normalized,

        [AllowNull()]
        [string]$Channel
    )

    return [pscustomobject][ordered]@{
        raw        = $Raw
        normalized = $Normalized
        channel    = $Channel
    }
}

function Get-AuditCommandResolution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command
    )

    $items = @(Get-Command $Command -All -ErrorAction SilentlyContinue)
    $results = New-Object System.Collections.Generic.List[object]

    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $versionRecord = $null

        $versionProperty = $item.PSObject.Properties['Version']
        if ($versionProperty -and $versionProperty.Value) {
            $rawVersion = $versionProperty.Value.ToString()
            if (-not [string]::IsNullOrWhiteSpace($rawVersion) -and $rawVersion -ne '0.0') {
                $versionRecord = New-AuditVersionRecord -Raw $rawVersion -Normalized $rawVersion -Channel $null
            }
        }

        $path = Get-AuditCommandTarget -CommandInfo $item

        $results.Add([pscustomobject][ordered]@{
            command     = $Command
            path        = $path
            commandType = $item.CommandType.ToString()
            version     = $versionRecord
            precedence  = $index
            active      = ($index -eq 0)
        })
    }

    return $results.ToArray()
}

function Invoke-AuditCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [string[]]$Arguments = @(),

        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0,

        [ValidateRange(1, 1048576)]
        [int]$MaximumCaptureLength = 32768,

        [switch]$SensitiveOutput
    )

    $startedAt = Get-Date
    $resolved = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $resolved) {
        return [pscustomobject][ordered]@{
            command      = $Command
            arguments    = @($Arguments)
            found        = $false
            status       = 'not-found'
            exitCode     = $null
            captured     = $null
            redacted     = $false
            truncated    = $false
            errorMessage = $null
            timedOut     = $false
            startedAt    = $startedAt.ToString('o')
            durationMs   = [int64]((Get-Date) - $startedAt).TotalMilliseconds
            resolutions  = @()
        }
    }

    $target = Get-AuditCommandTarget -CommandInfo $resolved
    $execution = $null

    if ($TimeoutSeconds -gt 0) {
        $jobInput = [pscustomobject]@{
            Target    = $target
            Arguments = @($Arguments)
        }

        $job = $null
        try {
            $job = Start-Job -ScriptBlock {
                param($Invocation)

                $global:LASTEXITCODE = 0

                try {
                    $text = (& $Invocation.Target @($Invocation.Arguments) 2>&1 | Out-String).Trim()
                    $exitCode = $LASTEXITCODE
                    if ($null -eq $exitCode) {
                        $exitCode = 0
                    }

                    [pscustomobject]@{
                        Status       = $(if ($exitCode -eq 0) { 'success' } else { 'non-zero' })
                        ExitCode     = [int]$exitCode
                        Captured     = $text
                        ErrorMessage = $null
                    }
                }
                catch {
                    [pscustomobject]@{
                        Status       = 'failed'
                        ExitCode     = $null
                        Captured     = $null
                        ErrorMessage = $_.Exception.Message
                    }
                }
            } -ArgumentList $jobInput

            $completedJob = Wait-Job -Job $job -Timeout $TimeoutSeconds
            if (-not $completedJob) {
                Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
                return [pscustomobject][ordered]@{
                    command      = $Command
                    arguments    = @($Arguments)
                    found        = $true
                    status       = 'timed-out'
                    exitCode     = $null
                    captured     = $null
                    redacted     = $false
                    truncated    = $false
                    errorMessage = "Command exceeded the $($TimeoutSeconds)-second timeout."
                    timedOut     = $true
                    startedAt    = $startedAt.ToString('o')
                    durationMs   = [int64]((Get-Date) - $startedAt).TotalMilliseconds
                    resolutions  = @(Get-AuditCommandResolution -Command $Command)
                }
            }

            $execution = Receive-Job -Job $job -ErrorAction Stop | Select-Object -Last 1
        }
        catch {
            $execution = [pscustomobject]@{
                Status       = 'failed'
                ExitCode     = $null
                Captured     = $null
                ErrorMessage = $_.Exception.Message
            }
        }
        finally {
            if ($job) {
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        try {
            $global:LASTEXITCODE = 0
            $text = (& $target @Arguments 2>&1 | Out-String).Trim()
            $exitCode = $LASTEXITCODE
            if ($null -eq $exitCode) {
                $exitCode = 0
            }

            $execution = [pscustomobject]@{
                Status       = $(if ($exitCode -eq 0) { 'success' } else { 'non-zero' })
                ExitCode     = [int]$exitCode
                Captured     = $text
                ErrorMessage = $null
            }
        }
        catch {
            $execution = [pscustomobject]@{
                Status       = 'failed'
                ExitCode     = $null
                Captured     = $null
                ErrorMessage = $_.Exception.Message
            }
        }
    }

    $limited = Limit-AuditCapturedText -Text $execution.Captured -MaximumLength $MaximumCaptureLength
    $captured = $limited.Text
    $redacted = $false

    if ($SensitiveOutput -and $null -ne $captured) {
        $captured = $null
        $redacted = $true
    }

    return [pscustomobject][ordered]@{
        command      = $Command
        arguments    = @($Arguments)
        found        = $true
        status       = $execution.Status
        exitCode     = $execution.ExitCode
        captured     = $captured
        redacted     = $redacted
        truncated    = $limited.Truncated
        errorMessage = $execution.ErrorMessage
        timedOut     = $false
        startedAt    = $startedAt.ToString('o')
        durationMs   = [int64]((Get-Date) - $startedAt).TotalMilliseconds
        resolutions  = @(Get-AuditCommandResolution -Command $Command)
    }
}

function New-AuditEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:[._-][a-z0-9]+)*$')]
        [string]$EvidenceId,

        [Parameter(Mandatory)]
        [ValidateSet('command', 'path', 'environment', 'registry', 'filesystem', 'api', 'configuration', 'derived')]
        [string]$Type,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [AllowNull()]
        [string]$Captured,

        [System.Collections.IDictionary]$Attributes = @{},

        [switch]$Redacted,

        [switch]$Sensitive,

        [ValidateRange(1, 1048576)]
        [int]$MaximumCaptureLength = 32768
    )

    $limited = Limit-AuditCapturedText -Text $Captured -MaximumLength $MaximumCaptureLength
    $finalCaptured = $limited.Text
    $isRedacted = [bool]$Redacted

    if ($Sensitive) {
        $finalCaptured = $null
        $isRedacted = $true
    }

    $normalizedAttributes = [ordered]@{}
    if ($Attributes) {
        foreach ($key in $Attributes.Keys) {
            $normalizedAttributes[[string]$key] = $Attributes[$key]
        }
    }

    if ($limited.Truncated) {
        $normalizedAttributes['truncated'] = $true
    }

    return [pscustomobject][ordered]@{
        evidenceId = $EvidenceId
        type       = $Type
        source     = $Source
        exitCode   = $ExitCode
        captured   = $finalCaptured
        redacted   = $isRedacted
        attributes = [pscustomobject]$normalizedAttributes
    }
}

function New-AuditIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z0-9_]+$')]
        [string]$Code,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet('info', 'warning', 'error')]
        [string]$Severity,

        [AllowNull()]
        [string]$ComponentId,

        [string[]]$EvidenceIds = @()
    )

    return [pscustomobject][ordered]@{
        code        = $Code
        message     = $Message
        severity    = $Severity
        componentId = $ComponentId
        evidenceIds = @($EvidenceIds | Select-Object -Unique)
    }
}

function Get-AuditProviderStatus {
    [CmdletBinding()]
    param(
        [object[]]$Warnings = @(),

        [object[]]$Errors = @(),

        [switch]$Partial,

        [switch]$Failed,

        [switch]$Unavailable,

        [switch]$NotApplicable
    )

    if ($NotApplicable) {
        return 'not-applicable'
    }

    if ($Failed) {
        return 'failed'
    }

    if ($Unavailable) {
        return 'unavailable'
    }

    if ($Partial -or @($Errors).Count -gt 0) {
        return 'partial'
    }

    if (@($Warnings).Count -gt 0) {
        return 'warning'
    }

    return 'success'
}

function Get-AuditEnvironmentSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Names
    )

    $requestedNames = @($Names | Select-Object -Unique)

    foreach ($name in $requestedNames) {
        if ($script:AuditEnvironmentAllowList -notcontains $name) {
            throw "Environment variable '$name' is not in the audit allowlist."
        }
    }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($name in $requestedNames) {
        $results.Add([pscustomobject][ordered]@{
            name    = $name
            process = [Environment]::GetEnvironmentVariable($name, 'Process')
            user    = [Environment]::GetEnvironmentVariable($name, 'User')
            machine = [Environment]::GetEnvironmentVariable($name, 'Machine')
        })
    }

    return $results.ToArray()
}

Export-ModuleMember -Function @(
    'New-AuditVersionRecord',
    'Get-AuditCommandResolution',
    'Invoke-AuditCommand',
    'New-AuditEvidence',
    'New-AuditIssue',
    'Get-AuditProviderStatus',
    'Get-AuditEnvironmentSnapshot'
)
