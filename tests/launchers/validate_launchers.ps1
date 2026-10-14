[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The operator runbook tells maintainers to use Run-Audit.cmd, Run-Compare.cmd and Run-Evaluate.cmd,
# so every launcher must point at real scripts and the report launchers must work end to end.

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture = Join-Path $root 'tests\fixtures\reports\mixed-provider-report.json'
$comparisonDirectory = Join-Path $root 'reports\comparison'
$evaluationDirectory = Join-Path $root 'reports\evaluation'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($launcher in @('Run-Audit.cmd', 'Run-Compare.cmd', 'Run-Evaluate.cmd')) {
    $text = [IO.File]::ReadAllText((Join-Path $root $launcher))
    $scripts = @([regex]::Matches($text, '%~dp0(scripts\\[A-Za-z-]+\.ps1)') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($scripts.Count -ge 1) "$launcher must launch a repository script."
    foreach ($script in $scripts) {
        Assert-True (Test-Path -LiteralPath (Join-Path $root $script) -PathType Leaf) "$launcher points at missing script '$script'."
    }
    Assert-True ($text -match 'powershell\.exe') "$launcher must use Windows PowerShell 5.1, the supported launcher host."
}

$reportsRoot = Join-Path $root 'reports'
$existed = Test-Path -LiteralPath $reportsRoot

try {
    # Run-Audit.cmd passes no paths, so the audit must work with its default paths on the
    # launcher host. (Run-Audit.cmd itself is not run: it queries live sources online.)
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $auditOutput = & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\Audit-Workstation.ps1') -OfflineVersionIntelligence 2>&1
    $auditExitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    Assert-True ($auditExitCode -eq 0) "The audit with default paths failed on Windows PowerShell 5.1: $($auditOutput | Out-String)"
    Assert-True (@(Get-ChildItem -LiteralPath $reportsRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -ge 1) 'The audit with default paths must write its JSON report under reports\.'

    # `< NUL` answers the launcher's closing `pause` without user input.
    $output = cmd.exe /d /c "`"$(Join-Path $root 'Run-Compare.cmd')`" `"$fixture`" `"$fixture`" < NUL" 2>&1
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0

    Assert-True ($exitCode -eq 0) "Run-Compare.cmd failed: $($output | Out-String)"
    Assert-True (($output -join "`n") -match 'Status: equal') 'Run-Compare.cmd must print the human-readable comparison.'
    Assert-True (Test-Path -LiteralPath (Join-Path $comparisonDirectory 'comparison.json') -PathType Leaf) 'Run-Compare.cmd must write comparison.json under reports\comparison.'

    $usage = cmd.exe /d /c "`"$(Join-Path $root 'Run-Compare.cmd')`" < NUL" 2>&1
    $usageExitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    Assert-True ($usageExitCode -eq 2 -and ($usage -join "`n") -match 'Usage:') 'Run-Compare.cmd without reports must print usage and exit 2.'

    $output = cmd.exe /d /c "`"$(Join-Path $root 'Run-Evaluate.cmd')`" `"$fixture`" < NUL" 2>&1
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    Assert-True ($exitCode -eq 0) "Run-Evaluate.cmd failed: $($output | Out-String)"
    Assert-True (($output -join "`n") -match 'Workstation policy evaluation: ') 'Run-Evaluate.cmd must print the human-readable evaluation.'

    # Windows PowerShell 5.1 (the launcher) and PowerShell 7 must write the same evaluation bytes.
    $pwshDirectory = Join-Path $evaluationDirectory 'pwsh'
    & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $root 'scripts\Evaluate-Workstation.ps1') -Report $fixture -OutputDirectory $pwshDirectory | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Evaluate-Workstation.ps1 failed on PowerShell 7.'
    $global:LASTEXITCODE = 0
    $launcherHash = (Get-FileHash -LiteralPath (Join-Path $evaluationDirectory 'evaluation.json')).Hash
    $pwshHash = (Get-FileHash -LiteralPath (Join-Path $pwshDirectory 'evaluation.json')).Hash
    Assert-True ($launcherHash -eq $pwshHash) 'Policy evaluation output differs between Windows PowerShell 5.1 and PowerShell 7.'

    $usage = cmd.exe /d /c "`"$(Join-Path $root 'Run-Evaluate.cmd')`" < NUL" 2>&1
    $usageExitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    Assert-True ($usageExitCode -eq 2 -and ($usage -join "`n") -match 'Usage:') 'Run-Evaluate.cmd without a report must print usage and exit 2.'

    Push-Location $root
    try {
        & git check-ignore --quiet --no-index 'reports/evaluation/evaluation.json'
        Assert-True ($LASTEXITCODE -eq 0) 'Launcher output under reports\evaluation must stay ignored by Git.'
        $global:LASTEXITCODE = 0
        & git check-ignore --quiet --no-index 'reports/comparison/comparison.json'
        Assert-True ($LASTEXITCODE -eq 0) 'Launcher output under reports\comparison must stay ignored by Git.'
        $global:LASTEXITCODE = 0
    }
    finally {
        Pop-Location
    }
}
finally {
    # Remove the reports folder only when this validation created it; an operator's existing
    # reports are never touched.
    if (-not $existed -and (Test-Path -LiteralPath $reportsRoot)) {
        Remove-Item -LiteralPath $reportsRoot -Recurse -Force
    }
}

Write-Host 'Launcher validation passed for Run-Audit.cmd, Run-Compare.cmd and Run-Evaluate.cmd.'
