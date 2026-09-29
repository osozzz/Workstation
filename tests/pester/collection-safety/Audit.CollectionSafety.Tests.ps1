BeforeDiscovery {
    $pwshCommand = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

    $script:auditHosts = @(
        @{
            Name       = 'Windows PowerShell 5.1'
            Executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        @{
            Name       = 'PowerShell 7'
            Executable = if ($pwshCommand) { $pwshCommand.Source } else { $null }
        }
    )
}

BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
    $scriptsRoot = Join-Path $repositoryRoot 'scripts'

    function Get-UnsafeCollectionIdiom {
        $findings = New-Object System.Collections.Generic.List[string]

        foreach ($file in Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Include '*.ps1', '*.psm1') {
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            $relativePath = $file.FullName.Substring($repositoryRoot.Length + 1)

            # `$x = if (...) { @(...) }` unrolls the if output: $x becomes $null or a
            # scalar, and `.Count` throws under StrictMode. Use `$x = @(if (...) { ... })`.
            $ifAssignments = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Right -is [System.Management.Automation.Language.IfStatementAst]
                }, $true)

            foreach ($assignment in $ifAssignments) {
                $blocks = @($assignment.Right.Clauses | ForEach-Object { $_.Item2 })
                if ($assignment.Right.ElseClause) {
                    $blocks += $assignment.Right.ElseClause
                }

                $returnsArray = @(
                    $blocks |
                        ForEach-Object { $_.Statements } |
                        Where-Object {
                            $_ -is [System.Management.Automation.Language.PipelineAst] -and
                            $_.PipelineElements.Count -eq 1 -and
                            $_.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
                            $_.PipelineElements[0].Expression -is [System.Management.Automation.Language.ArrayExpressionAst]
                        }
                ).Count -gt 0

                if ($returnsArray) {
                    $findings.Add("${relativePath}:$($assignment.Extent.StartLineNumber) assigns an if statement that returns @(...)")
                }
            }

            # `@(...)[0]` throws `Index was outside the bounds` under StrictMode when the
            # pipeline is empty. Use `... | Select-Object -First 1`.
            $arrayIndexes = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.IndexExpressionAst] -and
                    $node.Target -is [System.Management.Automation.Language.ArrayExpressionAst]
                }, $true)

            foreach ($index in $arrayIndexes) {
                $findings.Add("${relativePath}:$($index.Extent.StartLineNumber) indexes an @(...) expression")
            }
        }

        return $findings.ToArray()
    }
}

Describe 'Collection-safe PowerShell idioms' {
    It 'keeps StrictMode-unsafe collection idioms out of production scripts' {
        $findings = @(Get-UnsafeCollectionIdiom)

        $findings -join [Environment]::NewLine | Should -BeNullOrEmpty
    }
}

Describe 'Built-in providers on a workstation without developer tools' {
    It 'completes every provider under <Name>' -ForEach $auditHosts {
        if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
            Set-ItResult -Skipped -Because "$Name is not installed"
            return
        }

        $outputDirectory = Join-Path $TestDrive ($Name -replace '[^A-Za-z0-9]', '')
        $runnerPath = Join-Path $TestDrive 'Invoke-MinimalAudit.ps1'

        @'
param(
    [Parameter(Mandatory)][string]$AuditScript,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

# Only the operating system and the current PowerShell host remain on PATH, so
# every developer tool looks absent to command resolution.
$env:PATH = @("$env:SystemRoot\System32", $env:SystemRoot, $PSHOME) -join ';'

$result = & $AuditScript `
    -OutputDirectory $OutputDirectory `
    -LocalConfigurationPath (Join-Path $OutputDirectory 'workstation.local.missing.json') `
    -OfflineVersionIntelligence `
    -PassThru 6>$null

$failed = @(
    $result.Report.providers |
        Where-Object status -eq 'failed' |
        ForEach-Object { '{0}: {1}' -f $_.providerId, (@($_.errors)[0].message) }
)

# An installation with no path, no version, and an unknown source carries no evidence;
# it can only come from a null collection element turned into a record.
$phantomInstallations = @(
    foreach ($provider in $result.Report.providers) {
        foreach ($component in @($provider.components)) {
            foreach ($installation in @($component.installations)) {
                if ([string]::IsNullOrEmpty([string]$installation.path) -and $null -eq $installation.version -and $installation.source -eq 'unknown') {
                    '{0}/{1}' -f $provider.providerId, $component.componentId
                }
            }
        }
    }
)

[pscustomobject]@{
    providerCount = $result.Report.summary.providerCount
    reportErrors  = @($result.Report.errors | ForEach-Object { $_.code })
    failed        = $failed
    phantoms      = $phantomInstallations
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8

        $auditScript = Join-Path $repositoryRoot 'scripts\Audit-Workstation.ps1'
        $output = & $Executable -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runnerPath -AuditScript $auditScript -OutputDirectory $outputDirectory 2>&1
        $exitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0

        $exitCode | Should -Be 0 -Because ($output | Out-String)
        $summary = @($output)[-1] | ConvertFrom-Json

        $summary.providerCount | Should -BeGreaterThan 0
        @($summary.reportErrors) | Should -HaveCount 0
        @($summary.failed) -join [Environment]::NewLine | Should -BeNullOrEmpty
        @($summary.phantoms) -join ', ' | Should -BeNullOrEmpty -Because 'absent tools must not produce empty installation records'
    }
}
