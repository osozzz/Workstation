Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ComparisonOutputPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }

    return $null
}

function Test-ComparisonOutputHasProperty {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $false
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        return $InputObject.Contains($Name)
    }

    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Assert-WorkstationComparisonOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Comparison
    )

    foreach ($required in @('schemaVersion', 'direction', 'reference', 'target', 'summary', 'differences')) {
        if (-not (Test-ComparisonOutputHasProperty -InputObject $Comparison -Name $required)) {
            throw "Comparison output is missing required property '$required'."
        }
    }

    if ([string]$Comparison.direction -ne 'reference-to-target') {
        throw "Comparison output direction must be 'reference-to-target'."
    }

    if (-not (Test-ComparisonOutputHasProperty -InputObject $Comparison.reference -Name 'host') -or
        -not (Test-ComparisonOutputHasProperty -InputObject $Comparison.target -Name 'host')) {
        throw 'Comparison output must include reference and target host descriptors.'
    }
}

function ConvertTo-WorkstationComparisonJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Comparison
    )

    Assert-WorkstationComparisonOutput -Comparison $Comparison

    $lf = [string][char]10
    $crlf = ([string][char]13) + ([string][char]10)
    $json = $Comparison | ConvertTo-Json -Depth 100 -Compress
    $json = $json.Replace($crlf, $lf)
    return ($json.TrimEnd() + $lf)
}

function ConvertTo-ComparisonDisplayValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value) {
        return '<none>'
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrEmpty($Value)) {
            return '""'
        }

        return $Value.Replace([string][char]13, '\r').Replace([string][char]10, '\n')
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [ValueType]) {
        return [string]$Value
    }

    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    return $json.Replace([string][char]13, '').Replace([string][char]10, '')
}

function ConvertTo-ComparisonEndpointText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Endpoint
    )

    $host = $Endpoint.host
    $audit = $Endpoint.audit

    return (
        '{0} ({1}/{2}; audit {3}; schema {4})' -f
        [string]$host.name,
        [string]$host.platform,
        [string]$host.architecture,
        [string]$audit.toolVersion,
        [string]$Endpoint.schemaVersion
    )
}

function ConvertTo-ComparisonDifferenceText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Difference
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("- [$([string]$Difference.relation)] $([string]$Difference.kind)")

    foreach ($entry in @(
        @('provider', 'providerId'),
        @('component', 'componentId'),
        @('subject', 'subjectId')
    )) {
        $value = [string](Get-ComparisonOutputPropertyValue -InputObject $Difference -Name $entry[1])
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $parts.Add("$($entry[0])=$value")
        }
    }

    $referenceState = [string](Get-ComparisonOutputPropertyValue -InputObject $Difference -Name 'referenceState')
    $targetState = [string](Get-ComparisonOutputPropertyValue -InputObject $Difference -Name 'targetState')

    if (-not [string]::IsNullOrWhiteSpace($referenceState)) {
        $parts.Add("referenceState=$referenceState")
    }
    if (-not [string]::IsNullOrWhiteSpace($targetState)) {
        $parts.Add("targetState=$targetState")
    }

    $referenceValue = Get-ComparisonOutputPropertyValue -InputObject $Difference -Name 'referenceValue'
    $targetValue = Get-ComparisonOutputPropertyValue -InputObject $Difference -Name 'targetValue'

    if ($null -ne $referenceValue -or $null -ne $targetValue) {
        $parts.Add("reference=$(ConvertTo-ComparisonDisplayValue -Value $referenceValue)")
        $parts.Add("target=$(ConvertTo-ComparisonDisplayValue -Value $targetValue)")
    }

    return ($parts -join ' | ')
}

function ConvertTo-WorkstationComparisonText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Comparison
    )

    Assert-WorkstationComparisonOutput -Comparison $Comparison

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Workstation Comparison')
    $lines.Add('======================')
    $lines.Add('Direction: reference -> target')
    $lines.Add("Reference: $(ConvertTo-ComparisonEndpointText -Endpoint $Comparison.reference)")
    $lines.Add("Target: $(ConvertTo-ComparisonEndpointText -Endpoint $Comparison.target)")
    $lines.Add("Status: $([string]$Comparison.summary.status)")
    $lines.Add("Differences: $([int]$Comparison.summary.differenceCount)")
    $lines.Add(
        'Semantic states: unavailable={0}, unknown={1}, not-applicable={2}' -f
        [int]$Comparison.summary.unavailableCount,
        [int]$Comparison.summary.unknownCount,
        [int]$Comparison.summary.notApplicableCount
    )
    $lines.Add('')

    $groups = @(
        [pscustomobject][ordered]@{
            title      = 'Components and versions'
            categories = @('provider', 'component', 'version')
        },
        [pscustomobject][ordered]@{
            title      = 'PATH and environment'
            categories = @('path', 'environment')
        },
        [pscustomobject][ordered]@{
            title      = 'Applications'
            categories = @('application')
        },
        [pscustomobject][ordered]@{
            title      = 'Projects and runtime constraints'
            categories = @('project')
        },
        [pscustomobject][ordered]@{
            title      = 'Git health'
            categories = @('git')
        }
    )

    foreach ($group in $groups) {
        $lines.Add($group.title)
        $lines.Add(('-' * $group.title.Length))

        $differences = @(
            @($Comparison.differences) |
                Where-Object { [string]$_.category -in $group.categories } |
                Sort-Object category, providerId, componentId, subjectId, kind
        )

        if ($differences.Count -eq 0) {
            $lines.Add('- No differences.')
        }
        else {
            foreach ($difference in $differences) {
                $lines.Add((ConvertTo-ComparisonDifferenceText -Difference $difference))
            }
        }

        $lines.Add('')
    }

    $lf = [string][char]10
    return (($lines -join $lf).TrimEnd() + $lf)
}

function Write-WorkstationComparisonOutputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Comparison,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory
    )

    Assert-WorkstationComparisonOutput -Comparison $Comparison

    $directory = [IO.Path]::GetFullPath($OutputDirectory)
    [IO.Directory]::CreateDirectory($directory) | Out-Null

    $structuredPath = Join-Path $directory 'comparison.json'
    $humanReadablePath = Join-Path $directory 'comparison.txt'

    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText(
        $structuredPath,
        (ConvertTo-WorkstationComparisonJson -Comparison $Comparison),
        $utf8NoBom
    )
    [IO.File]::WriteAllText(
        $humanReadablePath,
        (ConvertTo-WorkstationComparisonText -Comparison $Comparison),
        $utf8NoBom
    )

    return [pscustomobject][ordered]@{
        structuredPath    = $structuredPath
        humanReadablePath = $humanReadablePath
    }
}

Export-ModuleMember -Function @(
    'Assert-WorkstationComparisonOutput',
    'ConvertTo-WorkstationComparisonJson',
    'ConvertTo-WorkstationComparisonText',
    'Write-WorkstationComparisonOutputs'
)
