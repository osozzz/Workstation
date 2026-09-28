[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outputModulePath = Join-Path $root 'scripts\Core\Comparison.Output.psm1'
$comparisonScriptPath = Join-Path $root 'scripts\Compare-Workstations.ps1'
$gitignorePath = Join-Path $root '.gitignore'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'
$expectedStructuredPath = Join-Path $fixtureRoot 'expected-comparison.json'
$expectedHumanPath = Join-Path $fixtureRoot 'expected-comparison.txt'

Import-Module (Join-Path $root 'scripts\Core\Comparison.Core.psm1') -Force
Import-Module $outputModulePath -Force

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Normalize-Newlines {
    param([Parameter(Mandatory)][string]$Value)

    $lf = [string][char]10
    $crlf = ([string][char]13) + ([string][char]10)
    return $Value.Replace($crlf, $lf)
}

$expectedStructured = Normalize-Newlines -Value ([IO.File]::ReadAllText($expectedStructuredPath))
$expectedHuman = Normalize-Newlines -Value ([IO.File]::ReadAllText($expectedHumanPath))
$comparison = ConvertFrom-WorkstationJson -Json $expectedStructured

# PowerShell 7.0-7.4 cannot keep date-time text while parsing; the fallback must restore
# RFC 3339 strings for the same instant anywhere in the object graph.
$utcInstant = [datetime]::new(2026, 9, 24, 12, 0, 0, [DateTimeKind]::Utc)
$fallback = ConvertTo-ComparisonDateText -Value ([pscustomobject]@{
        generatedAt = $utcInstant
        nested      = @([pscustomobject]@{ checkedAt = $utcInstant; label = 'kept' })
    })
Assert-True ($fallback.generatedAt -ceq '2026-09-24T12:00:00.0000000Z') 'Date-time fallback must emit RFC 3339 text for top-level values.'
Assert-True ($fallback.nested[0].checkedAt -ceq '2026-09-24T12:00:00.0000000Z' -and $fallback.nested[0].label -ceq 'kept') 'Date-time fallback must convert nested array values and keep other values.'

$actualStructured = ConvertTo-WorkstationComparisonJson -Comparison $comparison
Assert-True ($actualStructured -eq $expectedStructured) 'Structured comparison snapshot must be deterministic and validated before human rendering.'

$actualHuman = ConvertTo-WorkstationComparisonText -Comparison $comparison
if ($actualHuman -ne $expectedHuman) {
    $expectedLines = @($expectedHuman -split [char]10)
    $actualLines = @($actualHuman -split [char]10)
    $maximumLineCount = [Math]::Max($expectedLines.Count, $actualLines.Count)
    $mismatchLine = 0
    $expectedLine = '<missing>'
    $actualLine = '<missing>'

    for ($lineIndex = 0; $lineIndex -lt $maximumLineCount; $lineIndex++) {
        $candidateExpected = if ($lineIndex -lt $expectedLines.Count) { [string]$expectedLines[$lineIndex] } else { '<missing>' }
        $candidateActual = if ($lineIndex -lt $actualLines.Count) { [string]$actualLines[$lineIndex] } else { '<missing>' }

        if ($candidateExpected -ne $candidateActual) {
            $mismatchLine = $lineIndex + 1
            $expectedLine = $candidateExpected
            $actualLine = $candidateActual
            break
        }
    }

    throw "Human-readable comparison snapshot mismatch at line $mismatchLine. Expected: '$expectedLine' Actual: '$actualLine'"
}

foreach ($requiredHeading in @(
    'Components and versions',
    'PATH and environment',
    'Applications',
    'Projects and runtime constraints',
    'Git health'
)) {
    Assert-True ($actualHuman.Contains($requiredHeading)) "Human-readable comparison is missing required group '$requiredHeading'."
}

foreach ($requiredSemantic in @(
    '[unavailable]',
    '[unknown]',
    '[not-applicable]',
    'Reference: SYNTHETIC-REFERENCE',
    'Target: SYNTHETIC-TARGET',
    'Direction: reference -> target'
)) {
    Assert-True ($actualHuman.Contains($requiredSemantic)) "Human-readable comparison is missing semantic marker '$requiredSemantic'."
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('workstation-comparison-output-' + [guid]::NewGuid().ToString('N'))
$outputDirectory = Join-Path $tempRoot 'reports\comparisons'
$entryOutputDirectory = Join-Path $tempRoot 'entrypoint-output'

try {
    $writeResult = Write-WorkstationComparisonOutputs -Comparison $comparison -OutputDirectory $outputDirectory

    Assert-True (Test-Path -LiteralPath $writeResult.structuredPath -PathType Leaf) 'Structured comparison file must be written.'
    Assert-True (Test-Path -LiteralPath $writeResult.humanReadablePath -PathType Leaf) 'Human-readable comparison file must be written.'
    Assert-True ((Normalize-Newlines -Value ([IO.File]::ReadAllText($writeResult.structuredPath))) -eq $expectedStructured) 'Written structured output must match the structured snapshot.'
    Assert-True ((Normalize-Newlines -Value ([IO.File]::ReadAllText($writeResult.humanReadablePath))) -eq $expectedHuman) 'Written human-readable output must match the human snapshot.'

    $structuredBytes = [IO.File]::ReadAllBytes($writeResult.structuredPath)
    $hasUtf8Bom = (
        $structuredBytes.Length -ge 3 -and
        $structuredBytes[0] -eq 0xEF -and
        $structuredBytes[1] -eq 0xBB -and
        $structuredBytes[2] -eq 0xBF
    )
    Assert-True (-not $hasUtf8Bom) 'Structured comparison output must use deterministic UTF-8 without BOM.'

    $referenceAudit = [pscustomobject][ordered]@{
        schemaVersion = '1.0.0'
        # A non-UTC offset exposes host time-zone rewriting even on a UTC runner.
        generatedAt   = '2026-09-24T12:00:00+05:00'
        audit         = [pscustomobject][ordered]@{
            mode        = 'read-only'
            toolVersion = '0.8.0'
        }
        host          = [pscustomobject][ordered]@{
            name         = 'ENTRY-REFERENCE'
            platform     = 'windows'
            architecture = 'x64'
        }
        summary       = [pscustomobject][ordered]@{
            status             = 'success'
            providerCount      = 1
            successCount       = 1
            warningCount       = 0
            partialCount       = 0
            failedCount        = 0
            unavailableCount   = 0
            notApplicableCount = 0
        }
        providers     = @(
            [pscustomobject][ordered]@{
                providerId = 'synthetic.equal'
                category   = 'synthetic'
                status     = 'success'
                observedAt = '2026-09-24T12:00:00+00:00'
                components = @(
                    [pscustomobject][ordered]@{
                        componentId         = 'equal-component'
                        name                = 'Synthetic equal component'
                        state               = 'present'
                        installed           = $true
                        activeVersion       = [pscustomobject][ordered]@{
                            raw        = '1.0.0'
                            normalized = '1.0.0'
                            channel    = 'stable'
                        }
                        discoveredVersions  = @()
                        installations       = @()
                        commandResolutions  = @()
                        versionIntelligence = [pscustomobject][ordered]@{
                            status        = 'not-applicable'
                            latestStable  = $null
                            latestLts     = $null
                            latestCurrent = $null
                            source        = $null
                            checkedAt     = $null
                            message       = $null
                        }
                    }
                )
                warnings   = @()
                errors     = @()
                evidence   = @()
            }
        )
        warnings      = @()
        errors        = @()
    }
    $targetAudit = ConvertFrom-WorkstationJson -Json ($referenceAudit | ConvertTo-Json -Depth 20)
    $targetAudit.host.name = 'ENTRY-TARGET'

    $referencePath = Join-Path $tempRoot 'reference.json'
    $targetPath = Join-Path $tempRoot 'target.json'
    $referenceAudit | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $referencePath -Encoding UTF8
    $targetAudit | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $targetPath -Encoding UTF8

    $entryComparison = & $comparisonScriptPath -Reference $referencePath -Target $targetPath -OutputDirectory $entryOutputDirectory
    Assert-True ($entryComparison.summary.status -eq 'equal') 'Comparison entrypoint must continue returning the normalized comparison object.'
    Assert-True (Test-Path -LiteralPath (Join-Path $entryOutputDirectory 'comparison.json') -PathType Leaf) 'Entrypoint must write structured output when OutputDirectory is supplied.'
    Assert-True (Test-Path -LiteralPath (Join-Path $entryOutputDirectory 'comparison.txt') -PathType Leaf) 'Entrypoint must write human-readable output when OutputDirectory is supplied.'

    $entryHosts = @(
        @{ Name = 'current host'; OutputDirectory = $entryOutputDirectory }
    )

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
        $legacyOutputDirectory = Join-Path $tempRoot 'entrypoint-output-5.1'
        $legacyOutput = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $comparisonScriptPath -Reference $referencePath -Target $targetPath -OutputDirectory $legacyOutputDirectory 2>&1
        $legacyExitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        Assert-True ($legacyExitCode -eq 0) "Comparison entrypoint must run under Windows PowerShell 5.1: $($legacyOutput | Out-String)"
        $entryHosts += @{ Name = 'Windows PowerShell 5.1'; OutputDirectory = $legacyOutputDirectory }
    }

    foreach ($entryHost in $entryHosts) {
        $written = ConvertFrom-WorkstationJson -Json ([IO.File]::ReadAllText((Join-Path $entryHost.OutputDirectory 'comparison.json')))
        foreach ($endpoint in @($written.reference, $written.target)) {
            Assert-True ($endpoint.generatedAt -is [string] -and $endpoint.generatedAt -eq $referenceAudit.generatedAt) "Comparison output on $($entryHost.Name) must preserve report timestamps exactly; got '$($endpoint.generatedAt)'."
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Assert-True (-not (Test-Path -LiteralPath $tempRoot)) 'Synthetic output directory must be deleted after validation.'

$gitignoreLines = @(Get-Content -LiteralPath $gitignorePath)
Assert-True ($gitignoreLines -contains 'reports/') 'Machine-specific audit and comparison outputs must remain ignored by Git.'

$outputSource = Get-Content -LiteralPath $outputModulePath -Raw
foreach ($forbiddenMutation in @(
    'SetEnvironmentVariable',
    'winget install',
    'winget upgrade',
    'npm install',
    'pnpm add',
    'git checkout',
    'git reset',
    'git clean',
    'git branch -D'
)) {
    Assert-True ($outputSource -notmatch [Regex]::Escape($forbiddenMutation)) "Output generation must not contain workstation mutation marker '$forbiddenMutation'."
}

Write-Host 'Normalized comparison report output validation passed.'
