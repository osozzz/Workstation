Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredVersion = [version]'1.25.0'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$settingsPath = Join-Path $repositoryRoot 'PSScriptAnalyzerSettings.psd1'
$scriptsPath = Join-Path $repositoryRoot 'scripts'

$module = Get-Module -ListAvailable -Name PSScriptAnalyzer |
    Where-Object Version -eq $requiredVersion |
    Select-Object -First 1

if (-not $module) {
    throw "PSScriptAnalyzer $requiredVersion is required for the static-analysis gate."
}

Import-Module -Name $module.Path -Force

if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "PSScriptAnalyzer settings file was not found: $settingsPath"
}

if (-not (Test-Path -LiteralPath $scriptsPath -PathType Container)) {
    throw "Production PowerShell source directory was not found: $scriptsPath"
}

$productionAnalyzerArgs = @{
    Path = $scriptsPath
    Recurse = $true
    Settings = $settingsPath
}

$productionDiagnostics = @(
    Invoke-ScriptAnalyzer @productionAnalyzerArgs
)

if ($productionDiagnostics.Count -gt 0) {
    $productionDiagnostics |
        Sort-Object ScriptPath, Line, RuleName |
        Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize |
        Out-String |
        Write-Host

    throw "PSScriptAnalyzer found $($productionDiagnostics.Count) production diagnostic(s)."
}

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $env:RUNNER_TEMP
}
else {
    [IO.Path]::GetTempPath()
}

$negativeFixtureDirectory = Join-Path $tempRoot ("workstation-pssa-negative-" + [guid]::NewGuid().ToString('N'))
$negativeFixturePath = Join-Path $negativeFixtureDirectory 'InvokeExpression.Bad.ps1'

New-Item -ItemType Directory -Path $negativeFixtureDirectory -Force | Out-Null

try {
    "Invoke-Expression 'Get-Date'" |
        Set-Content -LiteralPath $negativeFixturePath -Encoding UTF8

    $negativeAnalyzerArgs = @{
        Path = $negativeFixturePath
        Settings = $settingsPath
    }

    $negativeDiagnostics = @(
        Invoke-ScriptAnalyzer @negativeAnalyzerArgs
    )

    $expectedDiagnostic = @(
        $negativeDiagnostics |
        Where-Object RuleName -eq 'PSAvoidUsingInvokeExpression'
    )

    if ($expectedDiagnostic.Count -ne 1) {
        throw 'The controlled negative fixture did not trigger PSAvoidUsingInvokeExpression exactly once.'
    }
}
finally {
    if (Test-Path -LiteralPath $negativeFixtureDirectory) {
        Remove-Item -LiteralPath $negativeFixtureDirectory -Recurse -Force
    }
}

if (Test-Path -LiteralPath $negativeFixtureDirectory) {
    throw 'Static-analysis temporary state was not cleaned up.'
}

Write-Host 'PSScriptAnalyzer gate passed for production scripts and controlled negative fixture.'
