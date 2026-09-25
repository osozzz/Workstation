Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredVersion = [version]'6.2.0'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$settingsPath = Join-Path $repositoryRoot 'PesterConfiguration.psd1'
$testPath = Join-Path $repositoryRoot 'tests\pester'

$module = Get-Module -ListAvailable -Name Pester |
    Where-Object Version -eq $requiredVersion |
    Select-Object -First 1

if (-not $module) {
    throw "Pester $requiredVersion is required for the test gate."
}

Import-Module -Name $module.Path -Force

if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Pester configuration was not found: $settingsPath"
}

if (-not (Test-Path -LiteralPath $testPath -PathType Container)) {
    throw "Pester test directory was not found: $testPath"
}

$settings = Import-PowerShellDataFile -LiteralPath $settingsPath
$configuration = New-PesterConfiguration -Hashtable $settings
$configuration.Run.Path = @($testPath)
$configuration.Run.Exit = $false
$configuration.Run.PassThru = $true

$result = Invoke-Pester -Configuration $configuration

if ($result.Result -ne 'Passed' -or $result.FailedCount -ne 0) {
    throw "Pester suite failed. Result=$($result.Result) Failed=$($result.FailedCount)."
}

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    $env:RUNNER_TEMP
}
else {
    [IO.Path]::GetTempPath()
}

$negativeDirectory = Join-Path $tempRoot ("workstation-pester-negative-" + [guid]::NewGuid().ToString('N'))
$negativeTestPath = Join-Path $negativeDirectory 'ControlledFailure.Tests.ps1'
$negativeRunnerPath = Join-Path $negativeDirectory 'Run-ControlledFailure.ps1'

New-Item -ItemType Directory -Path $negativeDirectory -Force | Out-Null

try {
    @'
Describe 'Controlled failing assertion' {
    It 'must fail' {
        1 | Should -Be 2
    }
}
'@ | Set-Content -LiteralPath $negativeTestPath -Encoding UTF8

    $runnerTemplate = @'
Import-Module Pester -RequiredVersion 6.2.0 -Force
$negativeResult = Invoke-Pester -Path '__NEGATIVE_TEST_PATH__' -PassThru
if ($negativeResult.Result -eq 'Passed' -and $negativeResult.FailedCount -eq 0) {
    exit 0
}
exit 1
'@

    $escapedNegativeTestPath = $negativeTestPath.Replace("'", "''")
    $runnerContent = $runnerTemplate.Replace('__NEGATIVE_TEST_PATH__', $escapedNegativeTestPath)
    Set-Content -LiteralPath $negativeRunnerPath -Value $runnerContent -Encoding UTF8

    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) {
        throw "Could not resolve the current PowerShell executable: $pwshPath"
    }

    $nativePreferenceExists = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    if ($nativePreferenceExists) {
        $previousNativePreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        & $pwshPath -NoLogo -NoProfile -NonInteractive -File $negativeRunnerPath
        $negativeExitCode = $LASTEXITCODE
    }
    finally {
        if ($nativePreferenceExists) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($negativeExitCode -eq 0) {
        throw 'The controlled failing Pester assertion did not produce a failing child test run.'
    }

    # The child failure is expected evidence. Reset the native exit code so the
    # parent CI step reflects the validator result rather than the child result.
    $global:LASTEXITCODE = 0
}
finally {
    if (Test-Path -LiteralPath $negativeDirectory) {
        Remove-Item -LiteralPath $negativeDirectory -Recurse -Force
    }
}

if (Test-Path -LiteralPath $negativeDirectory) {
    throw 'Pester negative-test temporary state was not cleaned up.'
}

Write-Host "Pester gate passed: $($result.PassedCount) tests passed and the controlled failing assertion produced a non-zero child result."
