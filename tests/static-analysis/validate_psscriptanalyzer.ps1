[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$settingsPath = Join-Path $repositoryRoot 'PSScriptAnalyzerSettings.psd1'
$scriptsRoot = Join-Path $repositoryRoot 'scripts'
$requiredAnalyzerVersion = [Version]'1.25.0'

$module = Get-Module -ListAvailable -Name PSScriptAnalyzer |
    Where-Object { $_.Version -eq $requiredAnalyzerVersion } |
    Select-Object -First 1

if (-not $module) {
    throw "PSScriptAnalyzer $requiredAnalyzerVersion is required."
}

Import-Module $module.Path -Force

if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "PSScriptAnalyzer settings file was not found: $settingsPath"
}

if (-not (Test-Path -LiteralPath $scriptsRoot -PathType Container)) {
    throw "Production scripts directory was not found: $scriptsRoot"
}

function Assert-NoAnalyzerFindings {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Diagnostics,

        [Parameter(Mandatory)]
        [string]$Context
    )

    if ($Diagnostics.Count -eq 0) {
        return
    }

    $Diagnostics |
        Sort-Object ScriptName, Line, Column, RuleName |
        ForEach-Object {
            Write-Host (
                '{0}:{1}:{2} [{3}] {4}' -f
                $_.ScriptName,
                $_.Line,
                $_.Column,
                $_.RuleName,
                $_.Message
            )
        }

    throw "PSScriptAnalyzer gate failed for $Context with $($Diagnostics.Count) finding(s)."
}

# Prove the gate can fail by analyzing a controlled in-memory violation.
$negativeAnalysisArgs = @{
    ScriptDefinition = "Invoke-Expression 'Get-Date'"
    Settings = $settingsPath
}
$negativeDiagnostics = @(Invoke-ScriptAnalyzer @negativeAnalysisArgs)

if (-not ($negativeDiagnostics | Where-Object RuleName -eq 'PSAvoidUsingInvokeExpression')) {
    throw 'Controlled negative analysis did not produce PSAvoidUsingInvokeExpression.'
}

$negativeGateFailed = $false
try {
    Assert-NoAnalyzerFindings -Diagnostics $negativeDiagnostics -Context 'controlled negative fixture'
}
catch {
    $negativeGateFailed = $true
}

if (-not $negativeGateFailed) {
    throw 'Controlled negative fixture did not prove that analyzer findings fail the gate.'
}

$productionFiles = @(
    Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') } |
        Sort-Object FullName
)

if ($productionFiles.Count -eq 0) {
    throw 'No production PowerShell files were discovered under scripts/.'
}

$productionDiagnostics = @()

foreach ($file in $productionFiles) {
    $productionAnalysisArgs = @{
        Path = $file.FullName
        Settings = $settingsPath
    }
    $productionDiagnostics += @(Invoke-ScriptAnalyzer @productionAnalysisArgs)
}

$productionGateArgs = @{
    Diagnostics = $productionDiagnostics
    Context = "$($productionFiles.Count) production PowerShell file(s)"
}
Assert-NoAnalyzerFindings @productionGateArgs

Write-Host "PSScriptAnalyzer gate passed for $($productionFiles.Count) production PowerShell file(s)."
Write-Host 'Controlled negative fixture produced the expected failing diagnostic.'
