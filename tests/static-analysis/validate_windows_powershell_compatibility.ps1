Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Production scripts must run on Windows PowerShell 5.1 (Run-Audit.cmd) as well as
# PowerShell 7. This gate rejects .NET Core-only types/members, PowerShell 7-only
# command parameters, and PowerShell 7-only syntax.

$requiredVersion = [version]'1.25.0'
$targetProfile = 'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$scriptsPath = Join-Path $repositoryRoot 'scripts'

$module = Get-Module -ListAvailable -Name PSScriptAnalyzer |
    Where-Object Version -eq $requiredVersion |
    Select-Object -First 1

if (-not $module) {
    throw "PSScriptAnalyzer $requiredVersion is required for the Windows PowerShell compatibility gate."
}

Import-Module -Name $module.Path -Force

$settings = @{
    IncludeRules = @('PSUseCompatibleTypes', 'PSUseCompatibleCommands', 'PSUseCompatibleSyntax')
    Rules        = @{
        PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @($targetProfile) }
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @($targetProfile) }
        PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1') }
    }
}

function Expand-TypeNames {
    <#
    PSUseCompatibleTypes only recognizes full type names, so [IO.Path]::GetRelativePath
    would pass while [System.IO.Path]::GetRelativePath fails. Rewrite short names in a
    scratch copy; names never span lines, so reported line numbers stay accurate.
    #>
    param([Parameter(Mandatory)][string]$Path)

    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Include '*.ps1', '*.psm1') {
        $text = [IO.File]::ReadAllText($file.FullName)
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)

        $typeNodes = @(
            $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TypeExpressionAst] -or
                    $node -is [System.Management.Automation.Language.TypeConstraintAst]
                }, $true) |
                Sort-Object { $_.Extent.StartOffset } -Descending
        )

        foreach ($node in $typeNodes) {
            $name = $node.TypeName.FullName
            if ($name -match '[\[\],]') {
                continue
            }

            $resolved = $name -as [type]
            if ($null -eq $resolved -or $resolved.IsGenericType -or $resolved.FullName -eq $name) {
                continue
            }

            $extent = $node.Extent
            $original = $text.Substring($extent.StartOffset, $extent.EndOffset - $extent.StartOffset)
            $text = $text.Substring(0, $extent.StartOffset) + $original.Replace($name, $resolved.FullName) + $text.Substring($extent.EndOffset)
        }

        [IO.File]::WriteAllText($file.FullName, $text)
    }
}

function Get-CompatibilityDiagnostic {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$ScratchPath
    )

    Copy-Item -LiteralPath $SourcePath -Destination $ScratchPath -Recurse
    Expand-TypeNames -Path $ScratchPath
    return @(Invoke-ScriptAnalyzer -Path $ScratchPath -Recurse -Settings $settings)
}

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$scratchRoot = Join-Path $tempRoot ('workstation-compat-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null

try {
    $productionDiagnostics = @(Get-CompatibilityDiagnostic -SourcePath $scriptsPath -ScratchPath (Join-Path $scratchRoot 'scripts'))

    if ($productionDiagnostics.Count -gt 0) {
        $productionDiagnostics |
            Sort-Object ScriptName, Line |
            ForEach-Object { '{0}:{1} {2}: {3}' -f $_.ScriptName, $_.Line, $_.RuleName, $_.Message } |
            Out-String |
            Write-Host

        throw "Found $($productionDiagnostics.Count) Windows PowerShell 5.1 compatibility diagnostic(s) in production scripts."
    }

    # Controlled negative fixture: every construct that has broken Windows PowerShell 5.1
    # in this repository, written the way production code writes them (short type names).
    $fixtureSource = Join-Path $scratchRoot 'fixture-source'
    New-Item -ItemType Directory -Path $fixtureSource -Force | Out-Null
    @(
        '$relative = [IO.Path]::GetRelativePath(''C:\a'', ''C:\a\b'')'
        '$hex = [Convert]::ToHexString([byte[]](1, 2))'
        '$data = ''{}'' | ConvertFrom-Json -Depth 5'
        '$response = Invoke-WebRequest -Uri ''https://example.invalid'' -SkipHttpErrorCheck'
        '$value = $null ?? ''fallback'''
    ) | Set-Content -LiteralPath (Join-Path $fixtureSource 'ControlledIncompatibilities.Bad.ps1') -Encoding UTF8

    $fixtureDiagnostics = @(Get-CompatibilityDiagnostic -SourcePath $fixtureSource -ScratchPath (Join-Path $scratchRoot 'fixture'))

    foreach ($line in 1..5) {
        if (@($fixtureDiagnostics | Where-Object Line -eq $line).Count -lt 1) {
            throw "The controlled negative fixture did not report the Windows PowerShell 5.1 incompatibility on line $line."
        }
    }
}
finally {
    if (Test-Path -LiteralPath $scratchRoot) {
        Remove-Item -LiteralPath $scratchRoot -Recurse -Force
    }
}

if (Test-Path -LiteralPath $scratchRoot) {
    throw 'Compatibility-gate temporary state was not cleaned up.'
}

Write-Host 'Windows PowerShell 5.1 compatibility gate passed for production scripts and the controlled negative fixture.'
