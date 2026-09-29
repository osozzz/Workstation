[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Sprint 7 (v0.9.0 Audit Hardening) release gate for parent issue #11. The area checks
# prove behavior; this gate proves the hardening surface is complete and consistent.

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$matrixPath = Join-Path $PSScriptRoot 'coverage-matrix.json'
$workflowPath = Join-Path $root '.github\workflows\validate.yml'

$expectedCriteria = @(
    'psscriptanalyzer-configured'
    'pester-core-provider-behavior'
    'report-schemas-validated'
    'fixtures-cover-installed-missing-conflicting-offline'
    'provider-failure-isolation'
    'powershell-runtime-compatibility'
    'stable-required-checks'
    'redaction-security-tested'
    'documentation-matches-coverage'
)

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-WorkflowJob {
    <# Minimal reader for the controlled validate.yml layout: two-space job keys under `jobs:`. #>
    param([Parameter(Mandatory)][string]$Text)

    $jobs = [ordered]@{}
    $current = $null
    $inJobs = $false

    foreach ($line in $Text -split '\r?\n') {
        if ($line -match '^jobs:\s*$') {
            $inJobs = $true
            continue
        }

        if (-not $inJobs) {
            continue
        }

        if ($line -match '^  ([a-z0-9-]+):\s*$') {
            $current = [ordered]@{ id = $Matches[1]; name = $null; if = $null; needs = @() }
            $jobs[$Matches[1]] = $current
        }
        elseif ($null -ne $current -and $line -match '^    name:\s*(.+?)\s*$') {
            $current.name = $Matches[1]
        }
        elseif ($null -ne $current -and $line -match '^    if:\s*(.+?)\s*$') {
            $current.if = $Matches[1]
        }
        elseif ($null -ne $current -and $line -match '^    needs:\s*\[(.*)\]\s*$') {
            $current.needs = @($Matches[1] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }

    return $jobs
}

function Test-CoverageMatrix {
    param(
        [Parameter(Mandatory)][psobject]$Matrix,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Jobs
    )

    $problems = New-Object System.Collections.Generic.List[string]

    if ($Matrix.issue -ne 11) {
        $problems.Add('Coverage matrix must target parent issue #11.')
    }

    $ids = @($Matrix.criteria | ForEach-Object { $_.id })
    if ((@($ids | Sort-Object) -join ',') -ne (@($expectedCriteria | Sort-Object) -join ',')) {
        $problems.Add("Acceptance criteria drift. Expected: $($expectedCriteria -join ', '). Found: $($ids -join ', ').")
    }

    foreach ($criterion in @($Matrix.criteria)) {
        if (@($criterion.evidence).Count -eq 0) {
            $problems.Add("Criterion '$($criterion.id)' has no evidence.")
        }

        foreach ($relativePath in @($criterion.evidence)) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $relativePath))) {
                $problems.Add("Criterion '$($criterion.id)' references missing evidence '$relativePath'.")
            }
        }

        if (@($criterion.checks).Count -eq 0) {
            $problems.Add("Criterion '$($criterion.id)' names no CI check.")
        }

        foreach ($check in @($criterion.checks)) {
            if (-not $Jobs.Contains($check)) {
                $problems.Add("Criterion '$($criterion.id)' references missing CI check '$check'.")
            }
        }
    }

    return $problems.ToArray()
}

$mutatingCommandPatterns = @{
    'setx'            = '.*'
    'install-module'  = '.*'
    'install-package' = '.*'
    'install-script'  = '.*'
    'update-module'   = '.*'
    'winget'          = '^(install|uninstall|remove|import|configure|pin|settings)\b|^upgrade\b.*(--all|--id|--name|--query|--accept-source-agreements|\s[^-\s])'
    'choco'           = '^(install|uninstall|upgrade|pin)\b'
    'npm'             = '^(install|i|add|uninstall|remove|rm|un|update|up|upgrade|link|unlink)\b.*(\s-g\b|--global|--location[= ]global)'
    'pnpm'            = '^(install|i|add|uninstall|remove|rm|un|update|up|upgrade|link|unlink)\b.*(\s-g\b|--global)'
    'yarn'            = '^global\b'
    'git'             = '\bconfig\b.*--(global|system)\b'
    'dotnet'          = '^(workload\s+(install|update|repair|uninstall|restore)|tool\s+(install|update|uninstall)\b.*(\s-g\b|--global))'
    'rustup'          = '^(install|update|uninstall|default|toolchain\s+(install|uninstall|link)|self\b|component\s+(add|remove)|target\s+(add|remove))'
    'cargo'           = '^(install|uninstall)\b'
    'flutter'         = '^(upgrade|downgrade|channel\s+\S|config\b)'
    'nvm'             = '^(install|uninstall|use|on|off|alias)\b'
    'pip'             = '^(install|uninstall)\b'
}

$registryWriteCommands = @('set-itemproperty', 'new-itemproperty', 'remove-itemproperty', 'rename-itemproperty', 'new-item', 'remove-item', 'set-item')

function Get-LiteralArgumentText {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Node)

    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $Node.Value
    }

    if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst] -or $Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        return (@($Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value }) -join ' ')
    }

    return $Node.Extent.Text
}

function Find-WorkstationMutation {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

    $findings = New-Object System.Collections.Generic.List[string]

    $environmentWrites = $Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Member.Extent.Text -eq 'SetEnvironmentVariable' -and
            @($node.Arguments).Count -ge 3
        }, $true)

    foreach ($node in $environmentWrites) {
        if ($node.Arguments[2].Extent.Text -match '(?i)user|machine') {
            $findings.Add("line $($node.Extent.StartLineNumber): persistent environment write")
        }
    }

    foreach ($command in $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $commandName = $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) {
            continue
        }

        $name = [IO.Path]::GetFileNameWithoutExtension($commandName).ToLowerInvariant()
        $elements = @($command.CommandElements | Select-Object -Skip 1)

        # Commands routed through the audit runtime are checked by their literal target and arguments.
        if ($name -eq 'invoke-auditcommand') {
            $target = $null
            $argumentText = ''
            for ($index = 0; $index -lt $elements.Count; $index++) {
                $element = $elements[$index]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $index + 1 -lt $elements.Count) {
                    if ($element.ParameterName -eq 'Command') { $target = Get-LiteralArgumentText -Node $elements[$index + 1] }
                    if ($element.ParameterName -eq 'Arguments') { $argumentText = Get-LiteralArgumentText -Node $elements[$index + 1] }
                }
            }

            if ([string]::IsNullOrWhiteSpace($target)) {
                continue
            }

            $name = [IO.Path]::GetFileNameWithoutExtension($target).ToLowerInvariant()
        }
        else {
            $argumentText = (@($elements | ForEach-Object { Get-LiteralArgumentText -Node $_ }) -join ' ')
        }

        $argumentText = $argumentText.Trim()

        if ($mutatingCommandPatterns.ContainsKey($name) -and $argumentText -match $mutatingCommandPatterns[$name]) {
            $findings.Add("line $($command.Extent.StartLineNumber): $name $argumentText")
        }

        if ($name -in $registryWriteCommands -and $argumentText -match '(?i)\b(HKCU|HKLM|HKCR|HKU):|Registry::') {
            $findings.Add("line $($command.Extent.StartLineNumber): registry write via $name")
        }
    }

    return $findings.ToArray()
}

# 1. Coverage matrix maps every #11 acceptance criterion to existing evidence and CI checks.
$workflowText = [IO.File]::ReadAllText($workflowPath)
$jobs = Get-WorkflowJob -Text $workflowText
$matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
$matrixProblems = @(Test-CoverageMatrix -Matrix $matrix -Jobs $jobs)
Assert-True ($matrixProblems.Count -eq 0) ("Coverage matrix is invalid:`n" + ($matrixProblems -join "`n"))

$brokenMatrix = $matrix | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$brokenMatrix.criteria[0].evidence = @('tests/sprint7-integration/does-not-exist.ps1')
$brokenMatrix.criteria[1].checks = @('missing-check')
$brokenMatrix.criteria = @($brokenMatrix.criteria | Select-Object -SkipLast 1)
Assert-True (@(Test-CoverageMatrix -Matrix $brokenMatrix -Jobs $jobs).Count -eq 3) 'Coverage matrix validation must reject missing evidence, unknown checks, and dropped criteria.'

# 2. Stable checks: every job has a stable name and the required aggregator gates on all of them.
Assert-True ($jobs.Contains('validate')) 'The workflow must keep the validate check required by the main ruleset.'
$areaJobs = @($jobs.Keys | Where-Object { $_ -ne 'validate' })
Assert-True ($areaJobs.Count -ge 5) 'The workflow must expose separate hardening area checks.'
foreach ($job in $jobs.Values) {
    Assert-True ($job.name -eq $job.id) "CI job '$($job.id)' must use its id as a stable check name."
}
Assert-True ($jobs['validate'].if -eq 'always()') 'The validate aggregator must run even when an area fails.'
Assert-True ((@($jobs['validate'].needs | Sort-Object) -join ',') -eq (@($areaJobs | Sort-Object) -join ',')) 'The validate aggregator must depend on every area check.'
Assert-True ($workflowText -match "result -ne 'success'") 'The validate aggregator must fail on any non-success area result.'

# 3. Documentation index lists every audit and policy document, and coverage docs reference real files.
$docsIndex = [IO.File]::ReadAllText((Join-Path $root 'docs\README.md'))
foreach ($document in Get-ChildItem -Path (Join-Path $root 'docs\audit'), (Join-Path $root 'docs\policies') -Filter '*.md' -File) {
    $relative = '{0}/{1}' -f $document.Directory.Name, $document.Name
    Assert-True ($docsIndex.Contains("``$relative``")) "docs/README.md must list '$relative'."
}

$coverageDoc = [IO.File]::ReadAllText((Join-Path $root 'docs\audit\ci-coverage.md'))
foreach ($job in $areaJobs) {
    Assert-True ($coverageDoc.Contains("``$job``")) "docs/audit/ci-coverage.md must document the '$job' check."
}
foreach ($link in [regex]::Matches($coverageDoc, '`((?:\.\./)?[a-z-]+(?:/[a-z-]+)*\.md)`')) {
    $target = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'docs\audit') $link.Groups[1].Value))
    Assert-True (Test-Path -LiteralPath $target -PathType Leaf) "docs/audit/ci-coverage.md references missing document '$($link.Groups[1].Value)'."
}

# 4. No validation or production path mutates the workstation.
$mutationFindings = foreach ($file in Get-ChildItem -Path (Join-Path $root 'scripts'), (Join-Path $root 'tests') -Recurse -File -Include '*.ps1', '*.psm1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    foreach ($finding in Find-WorkstationMutation -Ast $ast) {
        '{0} {1}' -f $file.FullName.Substring($root.Length + 1), $finding
    }
}
Assert-True (@($mutationFindings).Count -eq 0) ("Workstation mutation found:`n" + (@($mutationFindings) -join "`n"))

$prohibitedSamples = @(
    "setx PATH 'C:\tools'"
    "[Environment]::SetEnvironmentVariable('JAVA_HOME', 'C:\jdk', 'User')"
    "[Environment]::SetEnvironmentVariable('PATH', 'x', [EnvironmentVariableTarget]::Machine)"
    "winget install --id Git.Git"
    "winget upgrade --all"
    "Invoke-AuditCommand -Command 'winget' -Arguments @('upgrade', 'Git.Git')"
    "npm install -g typescript"
    "pnpm add --global prisma"
    "git config --global user.name 'x'"
    "nvm use 22.0.0"
    "Invoke-AuditCommand -Command 'rustup' -Arguments @('default', 'stable')"
    "Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value 'x'"
    "Install-Module Pester"
)
foreach ($sample in $prohibitedSamples) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($sample, [ref]$null, [ref]$null)
    Assert-True (@(Find-WorkstationMutation -Ast $ast).Count -eq 1) "The mutation guard must reject: $sample"
}

$allowedSamples = @(
    "[Environment]::SetEnvironmentVariable('CANARY', 'x', 'Process')"
    "Invoke-AuditCommand -Command 'winget' -Arguments @('upgrade', '--disable-interactivity')"
    "Invoke-AuditCommand -Command 'nvm' -Arguments @('list', '--json')"
    "Invoke-AuditCommand -Command 'dotnet' -Arguments @('workload', 'list', '--machine-readable')"
    "git -C `$repo config user.name 'Synthetic'"
    "npm install"
    "`$sources = @('winget install', 'npm install -g')"
)
foreach ($sample in $allowedSamples) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($sample, [ref]$null, [ref]$null)
    Assert-True (@(Find-WorkstationMutation -Ast $ast).Count -eq 0) "The mutation guard must allow: $sample"
}

Write-Host "Sprint 7 Audit Hardening integration gate passed: $($matrix.criteria.Count) criteria mapped to evidence and $($areaJobs.Count) area checks behind validate."
