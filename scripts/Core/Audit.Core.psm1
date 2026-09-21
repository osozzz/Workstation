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
    'PYENV_ROOT',
    'DOTNET_ROOT',
    'DOTNET_ROOT_X64',
    'DOTNET_ROOT_X86'
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
    $results = [System.Collections.Generic.List[object]]::new()

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

        [System.Collections.IDictionary]$EnvironmentOverrides = @{},

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

    $useIsolatedJob = ($TimeoutSeconds -gt 0 -or $EnvironmentOverrides.Count -gt 0)

    if ($useIsolatedJob) {
        $environmentPairs = @(
            $EnvironmentOverrides.GetEnumerator() |
                ForEach-Object {
                    [pscustomobject]@{
                        Name  = [string]$_.Key
                        Value = $(if ($null -eq $_.Value) { $null } else { [string]$_.Value })
                    }
                }
        )

        $jobInput = [pscustomobject]@{
            Target           = $target
            Arguments        = @($Arguments)
            EnvironmentPairs = $environmentPairs
        }

        $job = $null
        try {
            $job = Start-Job -ScriptBlock {
                param($Invocation)

                $global:LASTEXITCODE = 0

                try {
                    foreach ($pair in @($Invocation.EnvironmentPairs)) {
                        [Environment]::SetEnvironmentVariable(
                            [string]$pair.Name,
                            $pair.Value,
                            'Process'
                        )
                    }

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

            $completedJob = if ($TimeoutSeconds -gt 0) {
                Wait-Job -Job $job -Timeout $TimeoutSeconds
            }
            else {
                Wait-Job -Job $job
            }

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

    $results = [System.Collections.Generic.List[object]]::new()

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



function ConvertTo-AuditPathEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('machine', 'user', 'process')]
        [string]$Scope,

        [Parameter(Mandatory)]
        [ValidateRange(0, 1048576)]
        [int]$Position,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Entry,

        [AllowNull()]
        [string[]]$AllowedEnvironmentReferenceNames
    )

    $original = $Entry
    $entryValue = $Entry.Trim()

    if (
        $entryValue.Length -ge 2 -and
        $entryValue.StartsWith('"') -and
        $entryValue.EndsWith('"')
    ) {
        $entryValue = $entryValue.Substring(1, $entryValue.Length - 2).Trim()
    }

    $expanded = $entryValue
    $unresolvedVariables = [System.Collections.Generic.List[string]]::new()

    for ($pass = 0; $pass -lt 8; $pass++) {
        $matches = @([regex]::Matches($expanded, '%(?<name>[^%]+)%'))
        if ($matches.Count -eq 0) {
            break
        }

        $changed = $false

        foreach ($match in $matches) {
            $name = [string]$match.Groups['name'].Value

            if (
                $null -ne $AllowedEnvironmentReferenceNames -and
                $AllowedEnvironmentReferenceNames -notcontains $name
            ) {
                if (-not $unresolvedVariables.Contains($name)) {
                    $unresolvedVariables.Add($name)
                }
                continue
            }

            $value = [Environment]::GetEnvironmentVariable($name, 'Process')

            if ([string]::IsNullOrEmpty($value)) {
                if (-not $unresolvedVariables.Contains($name)) {
                    $unresolvedVariables.Add($name)
                }
                continue
            }

            $expanded = $expanded.Replace($match.Value, $value)
            $changed = $true
        }

        if (-not $changed) {
            break
        }
    }

    $hasUnresolvedVariable = (
        $unresolvedVariables.Count -gt 0 -or
        $expanded -match '%[^%]+%'
    )

    $normalized = $expanded.Trim()
    if (
        $normalized.Length -ge 2 -and
        $normalized.StartsWith('"') -and
        $normalized.EndsWith('"')
    ) {
        $normalized = $normalized.Substring(1, $normalized.Length - 2).Trim()
    }

    $normalized = $normalized.Replace('/', '\')

    if ($normalized.StartsWith('\\')) {
        $uncTail = $normalized.Substring(2) -replace '\\{2,}', '\'
        $normalized = "\\$uncTail"
    }
    else {
        $normalized = $normalized -replace '\\{2,}', '\'
    }

    if (-not [string]::IsNullOrWhiteSpace($normalized)) {
        $root = $null
        try {
            $root = [IO.Path]::GetPathRoot($normalized)
        }
        catch {
            $root = $null
        }

        if (
            -not [string]::IsNullOrWhiteSpace($root) -and
            -not [string]::Equals(
                $normalized,
                $root,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $normalized = $normalized.TrimEnd('\')
        }
        elseif ([string]::IsNullOrWhiteSpace($root)) {
            $normalized = $normalized.TrimEnd('\')
        }
    }

    $comparisonKey = if ([string]::IsNullOrWhiteSpace($normalized)) {
        $null
    }
    else {
        $normalized.ToLowerInvariant()
    }

    $exists = $null
    if (
        -not $hasUnresolvedVariable -and
        -not [string]::IsNullOrWhiteSpace($normalized)
    ) {
        try {
            $exists = Test-Path -LiteralPath $normalized
        }
        catch {
            $exists = $false
        }
    }

    return [pscustomobject][ordered]@{
        scope                   = $Scope
        position                = $Position
        entry                   = $entryValue
        original                = $original
        expanded                = $expanded
        normalized              = $normalized
        comparisonKey           = $comparisonKey
        exists                  = $exists
        duplicate               = $false
        duplicateWithinScope    = $false
        firstEquivalentPosition = $null
        hasUnresolvedVariable   = $hasUnresolvedVariable
        unresolvedVariables     = $unresolvedVariables.ToArray()
    }
}


function Get-AuditPathScopeModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('machine', 'user', 'process')]
        [string]$Scope,

        [AllowNull()]
        [string]$RawPath
    )

    $rawEntries = if ([string]::IsNullOrWhiteSpace($RawPath)) {
        @()
    }
    else {
        @($RawPath -split ';')
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    for ($rawIndex = 0; $rawIndex -lt $rawEntries.Count; $rawIndex++) {
        $rawEntry = [string]$rawEntries[$rawIndex]
        if ([string]::IsNullOrWhiteSpace($rawEntry)) {
            continue
        }

        $entry = ConvertTo-AuditPathEntry -Scope $Scope -Position $entries.Count -Entry $rawEntry
        $key = [string]$entry.comparisonKey

        if (-not [string]::IsNullOrWhiteSpace($key)) {
            if ($seen.ContainsKey($key)) {
                $entry.duplicate = $true
                $entry.duplicateWithinScope = $true
                $entry.firstEquivalentPosition = [int]$seen[$key]
            }
            else {
                $seen[$key] = [int]$entry.position
            }
        }

        $entries.Add($entry)
    }

    return [pscustomobject][ordered]@{
        scope                    = $Scope
        entryCount               = $entries.Count
        duplicateCount           = @($entries | Where-Object { $_.duplicateWithinScope }).Count
        missingCount             = @($entries | Where-Object { $_.exists -eq $false }).Count
        unresolvedVariableCount  = @($entries | Where-Object { $_.hasUnresolvedVariable }).Count
        entries                  = $entries.ToArray()
    }
}


function Get-AuditPathModel {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$MachinePath,
        [AllowNull()][string]$UserPath,
        [AllowNull()][string]$ProcessPath
    )

    $machine = Get-AuditPathScopeModel -Scope machine -RawPath $MachinePath
    $user = Get-AuditPathScopeModel -Scope user -RawPath $UserPath
    $process = Get-AuditPathScopeModel -Scope process -RawPath $ProcessPath

    $persistentOccurrences = @{}

    foreach ($scopeModel in @($machine, $user)) {
        foreach ($entry in @($scopeModel.entries)) {
            $key = [string]$entry.comparisonKey
            if ([string]::IsNullOrWhiteSpace($key)) {
                continue
            }

            if (-not $persistentOccurrences.ContainsKey($key)) {
                $persistentOccurrences[$key] = [System.Collections.Generic.List[object]]::new()
            }

            $persistentOccurrences[$key].Add([pscustomobject][ordered]@{
                scope      = $entry.scope
                position   = $entry.position
                normalized = $entry.normalized
            })
        }
    }

    $crossScopeDuplicates = [System.Collections.Generic.List[object]]::new()
    foreach ($key in @($persistentOccurrences.Keys | Sort-Object)) {
        $occurrences = @($persistentOccurrences[$key])
        $distinctScopes = @($occurrences | Select-Object -ExpandProperty scope -Unique)

        if ($distinctScopes.Count -gt 1) {
            $crossScopeDuplicates.Add([pscustomobject][ordered]@{
                comparisonKey = $key
                normalized    = $occurrences[0].normalized
                scopes        = $distinctScopes
                occurrences   = $occurrences
            })
        }
    }

    return [pscustomobject][ordered]@{
        scopes                   = @($machine, $user, $process)
        crossScopeDuplicateCount = $crossScopeDuplicates.Count
        crossScopeDuplicates     = $crossScopeDuplicates.ToArray()
    }
}

function ConvertTo-AuditEnvironmentPathValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('process', 'user', 'machine')]
        [string]$Scope,

        [AllowNull()]
        [string]$Value
    )

    if ($script:AuditEnvironmentAllowList -notcontains $Name) {
        throw "Environment variable '$Name' is not in the audit allowlist."
    }

    $state = if ($null -eq $Value) {
        'unset'
    }
    elseif ($Value.Length -eq 0) {
        'empty'
    }
    else {
        'present'
    }

    $pathValues = [System.Collections.Generic.List[object]]::new()

    if ($state -eq 'present') {
        $segments = if ($Name -eq 'GOPATH') {
            @($Value -split [regex]::Escape([IO.Path]::PathSeparator.ToString()))
        }
        else {
            @($Value)
        }

        foreach ($segment in $segments) {
            if ([string]::IsNullOrWhiteSpace([string]$segment)) {
                continue
            }

            $pathValues.Add((ConvertTo-AuditPathEntry -Scope $Scope -Position $pathValues.Count -Entry ([string]$segment) -AllowedEnvironmentReferenceNames $script:AuditEnvironmentAllowList))
        }
    }

    $missingCount = @($pathValues | Where-Object { $_.exists -eq $false }).Count
    $unresolvedVariableCount = @($pathValues | Where-Object { $_.hasUnresolvedVariable }).Count

    $normalizedValue = if ($state -eq 'present') {
        if ($Name -eq 'GOPATH') {
            (@($pathValues | ForEach-Object { $_.normalized }) -join [IO.Path]::PathSeparator)
        }
        elseif ($pathValues.Count -gt 0) {
            [string]$pathValues[0].normalized
        }
        else {
            ''
        }
    }
    elseif ($state -eq 'empty') {
        ''
    }
    else {
        $null
    }

    $comparisonKey = if ($state -eq 'present' -and -not [string]::IsNullOrWhiteSpace($normalizedValue)) {
        $normalizedValue.ToLowerInvariant()
    }
    elseif ($state -eq 'empty') {
        ''
    }
    else {
        $null
    }

    return [pscustomobject][ordered]@{
        name                    = $Name
        scope                   = $Scope
        state                   = $state
        original                = $Value
        normalized              = $normalizedValue
        comparisonKey           = $comparisonKey
        pathCount               = $pathValues.Count
        missingPathCount        = $missingCount
        unresolvedVariableCount = $unresolvedVariableCount
        paths                   = $pathValues.ToArray()
    }
}


function Get-AuditEnvironmentVariableModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [AllowNull()][string]$ProcessValue,
        [AllowNull()][string]$UserValue,
        [AllowNull()][string]$MachineValue
    )

    if ($script:AuditEnvironmentAllowList -notcontains $Name) {
        throw "Environment variable '$Name' is not in the audit allowlist."
    }

    $process = ConvertTo-AuditEnvironmentPathValue -Name $Name -Scope process -Value $ProcessValue
    $user = ConvertTo-AuditEnvironmentPathValue -Name $Name -Scope user -Value $UserValue
    $machine = ConvertTo-AuditEnvironmentPathValue -Name $Name -Scope machine -Value $MachineValue

    $scopes = @($process, $user, $machine)
    $configuredScopes = @($scopes | Where-Object { $_.state -in @('present', 'empty') })
    $presentScopes = @($scopes | Where-Object { $_.state -eq 'present' })

    $distinctValues = @(
        $presentScopes |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.comparisonKey) } |
            Select-Object -ExpandProperty comparisonKey -Unique
    )

    $missingPathCount = (@($scopes | ForEach-Object { [int]$_.missingPathCount }) | Measure-Object -Sum).Sum
    if ($null -eq $missingPathCount) { $missingPathCount = 0 }

    $unresolvedVariableCount = (@($scopes | ForEach-Object { [int]$_.unresolvedVariableCount }) | Measure-Object -Sum).Sum
    if ($null -eq $unresolvedVariableCount) { $unresolvedVariableCount = 0 }

    return [pscustomobject][ordered]@{
        name                       = $Name
        configuredScopeCount       = $configuredScopes.Count
        presentScopeCount          = $presentScopes.Count
        unsetScopeCount            = @($scopes | Where-Object { $_.state -eq 'unset' }).Count
        emptyScopeCount            = @($scopes | Where-Object { $_.state -eq 'empty' }).Count
        distinctPresentValueCount  = $distinctValues.Count
        hasScopeDrift              = ($distinctValues.Count -gt 1)
        hasEmptyConfiguredScope    = @($configuredScopes | Where-Object { $_.state -eq 'empty' }).Count -gt 0
        missingPathCount           = [int]$missingPathCount
        unresolvedVariableCount    = [int]$unresolvedVariableCount
        scopes                     = $scopes
    }
}


function Get-AuditEnvironmentIntelligence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Snapshot
    )

    $models = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Snapshot)) {
        $name = [string]$item.name
        if ($script:AuditEnvironmentAllowList -notcontains $name) {
            throw "Environment variable '$name' is not in the audit allowlist."
        }

        $models.Add((Get-AuditEnvironmentVariableModel -Name $name -ProcessValue $item.process -UserValue $item.user -MachineValue $item.machine))
    }

    return $models.ToArray()
}

Export-ModuleMember -Function @(
    'New-AuditVersionRecord',
    'Get-AuditCommandResolution',
    'Invoke-AuditCommand',
    'New-AuditEvidence',
    'New-AuditIssue',
    'Get-AuditProviderStatus',
    'Get-AuditEnvironmentSnapshot',
    'ConvertTo-AuditPathEntry',
    'Get-AuditPathScopeModel',
    'Get-AuditPathModel',
    'ConvertTo-AuditEnvironmentPathValue',
    'Get-AuditEnvironmentVariableModel',
    'Get-AuditEnvironmentIntelligence'
)
