Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Remove-WinGetControlSequences {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $escape = [regex]::Escape([string][char]27)
    $withoutAnsi = [regex]::Replace($Text, "$escape\[[0-9;?]*[ -/]*[@-~]", '')
    return $withoutAnsi.Replace([string][char]13, '')
}

function Get-WinGetHeaderColumns {
    param([Parameter(Mandatory)][string]$Header)

    $definitions = @(
        [pscustomobject]@{ key = 'name';      pattern = '(?i)(?:^|\s)(Name|Nombre)(?=\s|$)' },
        [pscustomobject]@{ key = 'id';        pattern = '(?i)(?:^|\s)Id(?=\s|$)' },
        [pscustomobject]@{ key = 'version';   pattern = '(?i)(?:^|\s)(Version|Versi[oó]n)(?=\s|$)' },
        [pscustomobject]@{ key = 'available'; pattern = '(?i)(?:^|\s)(Available|Disponible)(?=\s|$)' },
        [pscustomobject]@{ key = 'source';    pattern = '(?i)(?:^|\s)(Source|Origen|Fuente)(?=\s|$)' }
    )

    $columns = @()
    foreach ($definition in $definitions) {
        $match = [regex]::Match($Header, $definition.pattern)
        if (-not $match.Success) {
            continue
        }

        $valueMatch = [regex]::Match($match.Value, '(?i)(Name|Nombre|Id|Version|Versi[oó]n|Available|Disponible|Source|Origen|Fuente)')
        if (-not $valueMatch.Success) {
            continue
        }

        $columns += [pscustomobject][ordered]@{
            key = $definition.key
            start = $match.Index + $valueMatch.Index
        }
    }

    return @($columns | Sort-Object start)
}

function Get-WinGetColumnValue {
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][object[]]$Columns,
        [Parameter(Mandatory)][int]$Index
    )

    $start = [int]$Columns[$Index].start
    if ($start -ge $Line.Length) {
        return $null
    }

    $end = if ($Index -lt ($Columns.Count - 1)) {
        [Math]::Min([int]$Columns[$Index + 1].start, $Line.Length)
    }
    else {
        $Line.Length
    }

    $length = [Math]::Max(0, $end - $start)
    if ($length -eq 0) {
        return $null
    }

    $value = $Line.Substring($start, $length).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function ConvertFrom-WinGetTable {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    $clean = Remove-WinGetControlSequences -Text $Text
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return [pscustomobject][ordered]@{
            tableFound = $false
            columns = @()
            rows = @()
        }
    }

    $lines = @($clean -split '\n')
    $headerIndex = -1
    $columns = @()

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $candidateColumns = @(Get-WinGetHeaderColumns -Header $lines[$index])
        $keys = @($candidateColumns | ForEach-Object key)

        if (
            $candidateColumns.Count -ge 3 -and
            $keys -contains 'id' -and
            $keys -contains 'version'
        ) {
            $separatorIndex = $index + 1
            while (
                $separatorIndex -lt $lines.Count -and
                [string]::IsNullOrWhiteSpace($lines[$separatorIndex])
            ) {
                $separatorIndex++
            }

            if (
                $separatorIndex -lt $lines.Count -and
                $lines[$separatorIndex].Trim() -match '^-{5,}$'
            ) {
                $headerIndex = $separatorIndex
                $columns = $candidateColumns
                break
            }
        }
    }

    if ($headerIndex -lt 0) {
        return [pscustomobject][ordered]@{
            tableFound = $false
            columns = @()
            rows = @()
        }
    }

    $rows = @()
    for ($index = $headerIndex + 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $trimmed = $line.Trim()
        if (
            $trimmed -match '(?i)^(No applicable upgrade found|No se encontr[oó] ninguna actualizaci[oó]n aplicable)' -or
            $trimmed -match '(?i)^\d+\s+(upgrades?|actualizaciones?)\s+(available|disponibles?)' -or
            $trimmed -match '(?i)^(The following packages have|Los siguientes paquetes)'
        ) {
            continue
        }

        $values = [ordered]@{}
        for ($columnIndex = 0; $columnIndex -lt $columns.Count; $columnIndex++) {
            $values[[string]$columns[$columnIndex].key] = Get-WinGetColumnValue -Line $line -Columns $columns -Index $columnIndex
        }

        if (
            [string]::IsNullOrWhiteSpace([string]$values['id']) -or
            [string]::IsNullOrWhiteSpace([string]$values['version'])
        ) {
            continue
        }

        $rows += [pscustomobject]$values
    }

    return [pscustomobject][ordered]@{
        tableFound = $true
        columns = @($columns | ForEach-Object key)
        rows = $rows
    }
}

function Test-WinGetIdentityReliable {
    param([AllowNull()][string]$PackageId)

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        return $false
    }

    if ($PackageId -match '…|\.\.\.') {
        return $false
    }

    return $true
}

function Test-WinGetVersionReliable {
    param([AllowNull()][string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $false
    }

    if ($Version -match '(?i)^(Unknown|Desconocida|Desconocido)$') {
        return $false
    }

    return $true
}

function ConvertTo-WinGetPackageRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Table,
        [Parameter(Mandatory)][ValidateSet('inventory','upgrade')][string]$Mode,
        [Parameter(Mandatory)][string]$CheckedAt
    )

    $records = @()
    foreach ($row in @($Table.rows)) {
        $packageId = [string]$row.id
        $installedVersion = [string]$row.version
        $availableVersion = if ($row.PSObject.Properties['available']) {
            [string]$row.available
        }
        else {
            $null
        }

        if (
            $Mode -eq 'upgrade' -and
            [string]::IsNullOrWhiteSpace($availableVersion)
        ) {
            continue
        }

        $source = if ($row.PSObject.Properties['source']) {
            [string]$row.source
        }
        else {
            $null
        }

        $records += [pscustomobject][ordered]@{
            name = $(if ($row.PSObject.Properties['name']) { [string]$row.name } else { $null })
            packageId = $packageId
            identityReliable = Test-WinGetIdentityReliable -PackageId $packageId
            installedVersion = $installedVersion
            installedVersionReliable = Test-WinGetVersionReliable -Version $installedVersion
            availableVersion = $(if ([string]::IsNullOrWhiteSpace($availableVersion)) { $null } else { $availableVersion })
            availableVersionReliable = $(if ([string]::IsNullOrWhiteSpace($availableVersion)) { $null } else { Test-WinGetVersionReliable -Version $availableVersion })
            source = $(if ([string]::IsNullOrWhiteSpace($source)) { $null } else { $source })
            checkedAt = $CheckedAt
        }
    }

    return $records
}

function Get-WinGetUpgradeLookupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandStatus,
        [AllowNull()][string]$Output,
        [Parameter(Mandatory)][psobject]$Table,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$UpgradeRecords
    )

    $clean = Remove-WinGetControlSequences -Text $Output

    if (
        $clean -match '(?i)(source agreements?|source agreement.*required|agreements? must be accepted|accept-source-agreements|terms of transaction|acuerdos?.*origen|debe aceptar.*acuerdo)'
    ) {
        return 'agreement-required'
    }

    if (
        $clean -match '(?i)(failed when (opening|searching) source|source .* unavailable|source.*not available|data required by the source is missing|0x8a15000f|0x8a15000c|origen .* no est[aá] disponible|error.*origen)'
    ) {
        return 'source-unavailable'
    }

    if ($CommandStatus -ne 'success') {
        return 'command-failed'
    }

    if ($UpgradeRecords.Count -gt 0) {
        return 'upgrades-available'
    }

    if (
        $clean -match '(?i)(No applicable upgrade found|No se encontr[oó] ninguna actualizaci[oó]n aplicable)'
    ) {
        return 'current'
    }

    if ($Table.tableFound) {
        return 'current'
    }

    return 'unknown'
}

Export-ModuleMember -Function @(
    'ConvertFrom-WinGetTable',
    'ConvertTo-WinGetPackageRecords',
    'Get-WinGetUpgradeLookupState'
)
