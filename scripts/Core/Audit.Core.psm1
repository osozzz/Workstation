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

$script:AuditEnvironmentVariableDefinitions = @{
    'NVM_HOME'         = @{ kind = 'path'; filesystem = $true }
    'NVM_SYMLINK'      = @{ kind = 'path'; filesystem = $true }
    'PNPM_HOME'        = @{ kind = 'path'; filesystem = $true }
    'JAVA_HOME'        = @{ kind = 'path'; filesystem = $true }
    'ANDROID_HOME'     = @{ kind = 'path'; filesystem = $true }
    'ANDROID_SDK_ROOT' = @{ kind = 'path'; filesystem = $true }
    'FLUTTER_ROOT'     = @{ kind = 'path'; filesystem = $true }
    'PUB_CACHE'        = @{ kind = 'path'; filesystem = $true }
    'CARGO_HOME'       = @{ kind = 'path'; filesystem = $true }
    'RUSTUP_HOME'      = @{ kind = 'path'; filesystem = $true }
    'GOPATH'           = @{ kind = 'path-list'; filesystem = $true }
    'GOROOT'           = @{ kind = 'path'; filesystem = $true }
    'PYENV_ROOT'       = @{ kind = 'path'; filesystem = $true }
    'DOTNET_ROOT'      = @{ kind = 'path'; filesystem = $true }
    'DOTNET_ROOT_X64'  = @{ kind = 'path'; filesystem = $true }
    'DOTNET_ROOT_X86'  = @{ kind = 'path'; filesystem = $true }
}


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



function Get-AuditEnvironmentVariableDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if ($script:AuditEnvironmentAllowList -notcontains $Name) {
        throw "Environment variable '$Name' is not in the audit allowlist."
    }

    $definition = $script:AuditEnvironmentVariableDefinitions[$Name]
    if ($null -eq $definition) {
        throw "Environment variable '$Name' does not have an audit definition."
    }

    return [pscustomobject][ordered]@{
        name       = $Name
        kind       = [string]$definition.kind
        filesystem = [bool]$definition.filesystem
    }
}


function Resolve-AuditEnvironmentReferences {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value,

        [System.Collections.IDictionary]$ReferenceValues = @{}
    )

    if ($null -eq $Value) {
        return [pscustomobject][ordered]@{
            expanded            = $null
            hasUnresolved       = $false
            unresolvedVariables = @()
            unapprovedReferenceCount = 0
        }
    }

    $expanded = $Value
    $unresolved = [System.Collections.Generic.List[string]]::new()
    $unapprovedReferences = [System.Collections.Generic.List[string]]::new()

    for ($pass = 0; $pass -lt 8; $pass++) {
        $matches = @([regex]::Matches($expanded, '%(?<name>[^%]+)%'))
        if ($matches.Count -eq 0) {
            break
        }

        $changed = $false

        foreach ($match in $matches) {
            $referenceName = [string]$match.Groups['name'].Value
            $foundReference = $false
            $referenceValue = $null

            foreach ($key in @($ReferenceValues.Keys)) {
                if ([string]::Equals([string]$key, $referenceName, [StringComparison]::OrdinalIgnoreCase)) {
                    $foundReference = $true
                    $referenceValue = $ReferenceValues[$key]
                    break
                }
            }

            if (-not $foundReference) {
                if ($script:AuditEnvironmentAllowList -contains $referenceName) {
                    if (-not $unresolved.Contains($referenceName)) {
                        $unresolved.Add($referenceName)
                    }
                }
                else {
                    $unapprovedKey = $referenceName.ToLowerInvariant()
                    if (-not $unapprovedReferences.Contains($unapprovedKey)) {
                        $unapprovedReferences.Add($unapprovedKey)
                    }
                }
                continue
            }

            if ($null -eq $referenceValue -or [string]::IsNullOrEmpty([string]$referenceValue)) {
                if (-not $unresolved.Contains($referenceName)) {
                    $unresolved.Add($referenceName)
                }
                continue
            }

            $replacement = [string]$referenceValue
            $next = $expanded.Replace($match.Value, $replacement)
            if ($next -ne $expanded) {
                $expanded = $next
                $changed = $true
            }
        }

        if (-not $changed) {
            break
        }
    }

    foreach ($match in @([regex]::Matches($expanded, '%(?<name>[^%]+)%'))) {
        $referenceName = [string]$match.Groups['name'].Value

        if ($script:AuditEnvironmentAllowList -contains $referenceName) {
            if (-not $unresolved.Contains($referenceName)) {
                $unresolved.Add($referenceName)
            }
        }
        else {
            $unapprovedKey = $referenceName.ToLowerInvariant()
            if (-not $unapprovedReferences.Contains($unapprovedKey)) {
                $unapprovedReferences.Add($unapprovedKey)
            }
        }
    }

    return [pscustomobject][ordered]@{
        expanded                 = $expanded
        hasUnresolved            = ($unresolved.Count -gt 0 -or $unapprovedReferences.Count -gt 0)
        unresolvedVariables      = $unresolved.ToArray()
        unapprovedReferenceCount = $unapprovedReferences.Count
    }
}


function ConvertTo-AuditEnvironmentScopeValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('process', 'user', 'machine')]
        [string]$Scope,

        [AllowNull()]
        [object]$Value,

        [System.Collections.IDictionary]$ReferenceValues = @{}
    )

    $definition = Get-AuditEnvironmentVariableDefinition -Name $Name

    if ($null -eq $Value) {
        return [pscustomobject][ordered]@{
            scope                 = $Scope
            state                 = 'unset'
            raw                   = $null
            expanded              = $null
            normalized            = $null
            comparisonKey         = $null
            exists                = $null
            pathItems             = @()
            missingPathCount      = 0
            hasUnresolvedVariable = $false
            unresolvedVariables   = @()
            unapprovedReferenceCount = 0
            isConfigured          = $false
            isInvalid             = $false
        }
    }

    $textValue = [string]$Value

    if ($textValue.Length -eq 0) {
        return [pscustomobject][ordered]@{
            scope                 = $Scope
            state                 = 'empty'
            raw                   = ''
            expanded              = ''
            normalized            = ''
            comparisonKey         = $null
            exists                = $null
            pathItems             = @()
            missingPathCount      = 0
            hasUnresolvedVariable = $false
            unresolvedVariables   = @()
            unapprovedReferenceCount = 0
            isConfigured          = $true
            isInvalid             = $true
        }
    }

    $pathItems = [System.Collections.Generic.List[object]]::new()

    if ($definition.kind -eq 'path-list') {
        $segments = @($textValue -split ';')
        foreach ($segment in $segments) {
            if ([string]::IsNullOrWhiteSpace([string]$segment)) {
                continue
            }

            $pathItems.Add((ConvertTo-AuditPathEntry -Scope $Scope -Position $pathItems.Count -Entry ([string]$segment) -EnvironmentValues $ReferenceValues))
        }
    }
    else {
        $pathItems.Add((ConvertTo-AuditPathEntry -Scope $Scope -Position 0 -Entry $textValue -EnvironmentValues $ReferenceValues))
    }

    $normalizedParts = @(
        $pathItems |
            ForEach-Object { $_.normalized } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $expandedParts = @($pathItems | ForEach-Object { $_.expanded })
    $unresolvedVariables = @(
        $pathItems |
            ForEach-Object { @($_.unresolvedVariables) } |
            Select-Object -Unique
    )
    $missingPathCount = @($pathItems | Where-Object { $_.exists -eq $false }).Count
    $unapprovedReferenceCount = 0
    foreach ($pathItem in @($pathItems)) {
        $unapprovedReferenceCount += [int]$pathItem.unapprovedReferenceCount
    }
    $hasUnresolvedVariable = @(
        $pathItems |
            Where-Object { $_.hasUnresolvedVariable }
    ).Count -gt 0

    $normalized = if ($definition.kind -eq 'path-list') {
        $normalizedParts -join ';'
    }
    elseif ($normalizedParts.Count -gt 0) {
        [string]$normalizedParts[0]
    }
    else {
        ''
    }

    $expanded = if ($definition.kind -eq 'path-list') {
        $expandedParts -join ';'
    }
    elseif ($expandedParts.Count -gt 0) {
        [string]$expandedParts[0]
    }
    else {
        ''
    }

    $comparisonKey = if ([string]::IsNullOrWhiteSpace($normalized)) {
        $null
    }
    else {
        $normalized.ToLowerInvariant()
    }

    $exists = if ($definition.kind -eq 'path' -and $pathItems.Count -eq 1) {
        $pathItems[0].exists
    }
    else {
        $null
    }

    $isInvalid = ($pathItems.Count -eq 0 -or [string]::IsNullOrWhiteSpace($normalized))

    return [pscustomobject][ordered]@{
        scope                 = $Scope
        state                 = 'value'
        raw                   = $textValue
        expanded              = $expanded
        normalized            = $normalized
        comparisonKey         = $comparisonKey
        exists                = $exists
        pathItems             = $pathItems.ToArray()
        missingPathCount      = $missingPathCount
        hasUnresolvedVariable = $hasUnresolvedVariable
        unresolvedVariables   = @($unresolvedVariables)
        unapprovedReferenceCount = $unapprovedReferenceCount
        isConfigured          = $true
        isInvalid             = $isInvalid
    }
}


function Get-AuditEnvironmentModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Snapshot
    )

    $items = @($Snapshot)
    $seenNames = @{}
    $scopeMaps = @{
        process = @{}
        user    = @{}
        machine = @{}
    }

    foreach ($item in $items) {
        if ($null -eq $item.PSObject.Properties['name']) {
            throw 'Environment snapshot item is missing name.'
        }

        $name = [string]$item.name
        Get-AuditEnvironmentVariableDefinition -Name $name | Out-Null

        $key = $name.ToUpperInvariant()
        if ($seenNames.ContainsKey($key)) {
            throw "Environment snapshot contains duplicate variable '$name'."
        }
        $seenNames[$key] = $true

        foreach ($scope in @('process', 'user', 'machine')) {
            $property = $item.PSObject.Properties[$scope]
            $scopeMaps[$scope][$name] = $(if ($property) { $property.Value } else { $null })
        }
    }

    $variables = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $items) {
        $name = [string]$item.name
        $definition = Get-AuditEnvironmentVariableDefinition -Name $name
        $scopeValues = [System.Collections.Generic.List[object]]::new()

        foreach ($scope in @('process', 'user', 'machine')) {
            $property = $item.PSObject.Properties[$scope]
            $value = $(if ($property) { $property.Value } else { $null })
            $scopeValues.Add((ConvertTo-AuditEnvironmentScopeValue -Name $name -Scope $scope -Value $value -ReferenceValues $scopeMaps[$scope]))
        }

        $configuredScopes = @($scopeValues | Where-Object { $_.isConfigured })
        $valueScopes = @($scopeValues | Where-Object { $_.state -eq 'value' })
        $distinctValues = @(
            $valueScopes |
                ForEach-Object { $_.comparisonKey } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                Select-Object -Unique
        )
        $emptyScopeCount = @($scopeValues | Where-Object { $_.state -eq 'empty' }).Count
        $invalidScopeCount = @($scopeValues | Where-Object { $_.isInvalid }).Count
        $missingMeasure = @($scopeValues | Measure-Object -Property missingPathCount -Sum)
        $missingPathCount = if ($missingMeasure.Count -gt 0 -and $null -ne $missingMeasure[0].Sum) { [int]$missingMeasure[0].Sum } else { 0 }
        $unresolvedScopeCount = @($scopeValues | Where-Object { $_.hasUnresolvedVariable }).Count
        $unapprovedReferenceCount = 0
        foreach ($scopeValue in @($scopeValues)) {
            $unapprovedReferenceCount += [int]$scopeValue.unapprovedReferenceCount
        }

        $variables.Add([pscustomobject][ordered]@{
            name                 = $name
            kind                 = $definition.kind
            filesystem           = $definition.filesystem
            configuredScopeCount = $configuredScopes.Count
            valueScopeCount      = $valueScopes.Count
            distinctValueCount   = $distinctValues.Count
            scopeConflict        = ($distinctValues.Count -gt 1)
            emptyScopeCount      = $emptyScopeCount
            invalidScopeCount    = $invalidScopeCount
            missingPathCount     = $missingPathCount
            unresolvedScopeCount = $unresolvedScopeCount
            unapprovedReferenceCount = $unapprovedReferenceCount
            scopes               = $scopeValues.ToArray()
        })
    }

    return [pscustomobject][ordered]@{
        variableCount = $variables.Count
        variables     = $variables.ToArray()
    }
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
        [System.Collections.IDictionary]$EnvironmentValues
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

    $referenceValues = $EnvironmentValues
    if ($null -eq $referenceValues) {
        $referenceValues = @{}
        foreach ($allowedName in $script:AuditEnvironmentAllowList) {
            $referenceValues[$allowedName] = [Environment]::GetEnvironmentVariable($allowedName, 'Process')
        }
    }

    $referenceResolution = Resolve-AuditEnvironmentReferences -Value $entryValue -ReferenceValues $referenceValues

    $expanded = $referenceResolution.expanded
    $unresolvedVariables = @($referenceResolution.unresolvedVariables)
    $unapprovedReferenceCount = [int]$referenceResolution.unapprovedReferenceCount
    $hasUnresolvedVariable = [bool]$referenceResolution.hasUnresolved

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
        unresolvedVariables     = @($unresolvedVariables)
        unapprovedReferenceCount = $unapprovedReferenceCount
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

Export-ModuleMember -Function @(
    'New-AuditVersionRecord',
    'Get-AuditCommandResolution',
    'Invoke-AuditCommand',
    'New-AuditEvidence',
    'New-AuditIssue',
    'Get-AuditProviderStatus',
    'Get-AuditEnvironmentSnapshot',
    'Get-AuditEnvironmentVariableDefinition',
    'Resolve-AuditEnvironmentReferences',
    'ConvertTo-AuditEnvironmentScopeValue',
    'Get-AuditEnvironmentModel',
    'ConvertTo-AuditPathEntry',
    'Get-AuditPathScopeModel',
    'Get-AuditPathModel'
)
