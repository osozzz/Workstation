[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The operator runbook tells maintainers to use Run-Audit.cmd, Run-Compare.cmd, Run-Evaluate.cmd and Run-Plan.cmd,
# so every launcher must point at real scripts and the report launchers must work end to end.

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixture = Join-Path $root 'tests\fixtures\reports\mixed-provider-report.json'
$comparisonDirectory = Join-Path $root 'reports\comparison'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

foreach ($launcher in @('Run-Audit.cmd', 'Run-Compare.cmd', 'Run-Evaluate.cmd', 'Run-Plan.cmd')) {
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

# The validation writes into the operator's reports folder (default paths are what it tests), so
# it moves existing launcher outputs aside and restores them afterwards, and it deletes the offline
# audit reports it creates so they are never mistaken for real audits.
$launcherFolders = @('comparison', 'evaluation', 'update-plan')
$backupRoot = Join-Path ([IO.Path]::GetTempPath()) ('workstation-launchers-' + [guid]::NewGuid().ToString('N'))
$filesBefore = @()
if ($existed) {
    $filesBefore = @(Get-ChildItem -LiteralPath $reportsRoot -File | ForEach-Object Name)
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($folder in $launcherFolders) {
        $path = Join-Path $reportsRoot $folder
        if (Test-Path -LiteralPath $path) {
            Move-Item -LiteralPath $path -Destination (Join-Path $backupRoot $folder)
        }
    }
}

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

    # Single-report launchers: Windows PowerShell 5.1 (the launcher) and PowerShell 7 must write the same bytes.
    foreach ($spec in @(
            @{ Launcher = 'Run-Evaluate.cmd'; Script = 'Evaluate-Workstation.ps1'; Folder = 'evaluation'; File = 'evaluation.json'; Banner = 'Workstation policy evaluation: ' }
            @{ Launcher = 'Run-Plan.cmd'; Script = 'Plan-WorkstationUpdate.ps1'; Folder = 'update-plan'; File = 'update-plan.json'; Banner = 'Workstation update plan: ' }
        )) {
        $launcherPath = Join-Path $root $spec.Launcher
        $outputDirectory = Join-Path $root ('reports\' + $spec.Folder)
        $output = cmd.exe /d /c "`"$launcherPath`" `"$fixture`" < NUL" 2>&1
        $exitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        Assert-True ($exitCode -eq 0) "$($spec.Launcher) failed: $($output | Out-String)"
        Assert-True (($output -join "`n") -match $spec.Banner) "$($spec.Launcher) must print its human-readable output."

        $pwshDirectory = Join-Path $outputDirectory 'pwsh'
        & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $root ('scripts\' + $spec.Script)) -Report $fixture -OutputDirectory $pwshDirectory | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "$($spec.Script) failed on PowerShell 7."
        $global:LASTEXITCODE = 0
        $launcherHash = (Get-FileHash -LiteralPath (Join-Path $outputDirectory $spec.File)).Hash
        $pwshHash = (Get-FileHash -LiteralPath (Join-Path $pwshDirectory $spec.File)).Hash
        Assert-True ($launcherHash -eq $pwshHash) "$($spec.File) differs between Windows PowerShell 5.1 and PowerShell 7."

        $usage = cmd.exe /d /c "`"$launcherPath`" < NUL" 2>&1
        $usageExitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        Assert-True ($usageExitCode -eq 2 -and ($usage -join "`n") -match 'Usage:') "$($spec.Launcher) without a report must print usage and exit 2."
    }

    Push-Location $root
    try {
        foreach ($output in @('reports/comparison/comparison.json', 'reports/evaluation/evaluation.json', 'reports/update-plan/update-plan.json')) {
            & git check-ignore --quiet --no-index $output
            Assert-True ($LASTEXITCODE -eq 0) "Launcher output $output must stay ignored by Git."
            $global:LASTEXITCODE = 0
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if (-not $existed) {
        if (Test-Path -LiteralPath $reportsRoot) {
            Remove-Item -LiteralPath $reportsRoot -Recurse -Force
        }
    }
    else {
        Get-ChildItem -LiteralPath $reportsRoot -File | Where-Object { $_.Name -notin $filesBefore } | Remove-Item -Force
        foreach ($folder in $launcherFolders) {
            $path = Join-Path $reportsRoot $folder
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
            $backup = Join-Path $backupRoot $folder
            if (Test-Path -LiteralPath $backup) {
                Move-Item -LiteralPath $backup -Destination $path
            }
        }
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'Launcher validation passed for Run-Audit.cmd, Run-Compare.cmd, Run-Evaluate.cmd and Run-Plan.cmd.'
