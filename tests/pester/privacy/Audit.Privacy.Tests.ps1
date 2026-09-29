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
    ) | Where-Object { $_.Executable -and (Test-Path -LiteralPath $_.Executable -PathType Leaf) }
}

BeforeAll {
    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))

    # Values that would only reach output through a privacy defect. A fresh suffix per
    # run guarantees a match cannot come from anywhere else.
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $script:canary = [ordered]@{
        'environment variable name'  = "WORKSTATION_PRIVACY_CANARY_$suffix"
        'environment variable value' = "envsecret$suffix"
        'Git remote user'            = "remoteuser$suffix"
        'Git remote token'           = "remotetoken$suffix"
        'Git credential helper'      = "helper$suffix"
        'package.json secret'        = "pkgtoken$suffix"
        '.npmrc auth token'          = "npmrctoken$suffix"
        'untracked file name'        = "filename$suffix.txt"
        'Git author email'           = "author$suffix@example.invalid"
    }

    # Contract: https://example.invalid is RFC 2606 reserved and never resolves.
    $script:remoteHost = "example.invalid/org-$suffix"

    $script:secretPatterns = [ordered]@{
        'GitHub token'          = '\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{22,}'
        'npm token'             = '\bnpm_[A-Za-z0-9]{36}\b'
        'AWS access key'        = '\bAKIA[0-9A-Z]{16}\b'
        'private key'           = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        'JSON Web Token'        = '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
        'Slack token'           = '\bxox[abprs]-[A-Za-z0-9-]{10,}'
        'URL credentials'       = '[a-z][a-z0-9+.-]*://[^/\s:@''"]+:[^/\s@''"]+@(?![^/\s''"]*\.(?:invalid|example|test)\b)'
        'secret assignment'     = '(?i)\b(?:password|passwd|pwd|secret|api[_-]?key|auth[_-]?token|access[_-]?token)\b\s*[:=]\s*[''"]?[A-Za-z0-9/+_\-]{12,}'
        'user profile path'     = '(?i)[a-z]:\\users\\(?!<|\$|%|\{|public\\|default\\|runneradmin\\)[a-z0-9._-]+\\'
        'personal email'        = '(?i)\b[a-z0-9._%+-]+@(?![a-z0-9.-]*\.(?:invalid|example|test)\b|example\.(?:com|org)\b|users\.noreply\.github\.com\b)[a-z0-9.-]+\.[a-z]{2,}\b'
    }

    function Find-SecretMarker {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

        return @($secretPatterns.Keys | Where-Object { $Text -match $secretPatterns[$_] })
    }

    function Find-EnvironmentEnumeration {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

        $enumerationCommands = @('Get-ChildItem', 'gci', 'dir', 'ls', 'Get-Item', 'gi')

        return @(
            $Ast.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                        $node.Member.Extent.Text -eq 'GetEnvironmentVariables') -or
                    ($node -is [System.Management.Automation.Language.CommandAst] -and
                        $node.GetCommandName() -in $enumerationCommands -and
                        @($node.CommandElements | Select-Object -Skip 1 | Where-Object { $_.Extent.Text -match '^[''"]?env:' }).Count -gt 0)
                }, $true)
        )
    }

    # A synthetic development root whose only project carries every planted secret.
    $developmentRoot = Join-Path $TestDrive 'development'
    $script:projectPath = Join-Path $developmentRoot 'canary-app'
    New-Item -ItemType Directory -Path $projectPath -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $projectPath 'package.json') -Encoding UTF8 -Value (
        '{"name":"canary-app","version":"1.0.0","config":{"token":"' + $canary['package.json secret'] + '"},"engines":{"node":">=20"}}'
    )
    Set-Content -LiteralPath (Join-Path $projectPath '.npmrc') -Encoding UTF8 -Value (
        '//registry.npmjs.org/:_authToken=' + $canary['.npmrc auth token']
    )

    function Invoke-SetupGit {
        param([Parameter(Mandatory)][string[]]$Arguments)

        # Windows PowerShell 5.1 turns redirected git stderr into terminating errors under Stop.
        $ErrorActionPreference = 'Continue'
        $output = & git -C $projectPath @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Privacy fixture setup failed: git $($Arguments -join ' ') | $($output -join ' ')"
        }

        return @($output)
    }

    Invoke-SetupGit -Arguments @('init', '--quiet') | Out-Null
    Invoke-SetupGit -Arguments @('config', 'user.name', 'Privacy Fixture') | Out-Null
    Invoke-SetupGit -Arguments @('config', 'user.email', $canary['Git author email']) | Out-Null
    Invoke-SetupGit -Arguments @('config', 'credential.helper', $canary['Git credential helper']) | Out-Null
    Invoke-SetupGit -Arguments @('add', 'package.json') | Out-Null
    Invoke-SetupGit -Arguments @('commit', '--quiet', '-m', 'privacy fixture') | Out-Null
    Invoke-SetupGit -Arguments @('remote', 'add', 'origin', ('https://{0}:{1}@example.invalid/org-{2}/canary-app.git' -f $canary['Git remote user'], $canary['Git remote token'], $suffix)) | Out-Null
    $script:commitSha = (Invoke-SetupGit -Arguments @('rev-parse', 'HEAD') | Select-Object -Last 1).ToString().Trim()
    Set-Content -LiteralPath (Join-Path $projectPath $canary['untracked file name']) -Value 'untracked' -Encoding UTF8

    $script:localConfigurationPath = Join-Path $TestDrive 'workstation.local.json'
    @{
        schemaVersion = '1.0'
        projects      = @{ developmentRoots = @($developmentRoot); maxDiscoveryDepth = 3 }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $localConfigurationPath -Encoding UTF8

    $script:developmentRoot = $developmentRoot
    $script:gitDirectory = Split-Path -Parent (Get-Command git -CommandType Application | Select-Object -First 1).Source

    $script:runnerPath = Join-Path $TestDrive 'Invoke-PrivacyAudit.ps1'
    @'
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$LocalConfigurationPath,
    [Parameter(Mandatory)][string]$GitDirectory,
    [Parameter(Mandatory)][string]$CanaryName,
    [Parameter(Mandatory)][string]$CanaryValue
)

$ErrorActionPreference = 'Stop'

# The canary exists only in this process, outside the approved environment allowlist.
[Environment]::SetEnvironmentVariable($CanaryName, $CanaryValue, 'Process')

# Keep the run fast and deterministic: only the OS, PowerShell, and Git are resolvable.
$env:PATH = @("$env:SystemRoot\System32", $env:SystemRoot, $PSHOME, $GitDirectory) -join ';'

$audit = & (Join-Path $Repository 'scripts\Audit-Workstation.ps1') `
    -OutputDirectory $OutputDirectory `
    -LocalConfigurationPath $LocalConfigurationPath `
    -OfflineVersionIntelligence `
    -PassThru 6>$null

$comparisonDirectory = Join-Path $OutputDirectory 'comparison'
& (Join-Path $Repository 'scripts\Compare-Workstations.ps1') -Reference $audit.JsonPath -Target $audit.JsonPath -OutputDirectory $comparisonDirectory | Out-Null

$projects = $audit.Report.providers | Where-Object providerId -eq 'projects.javascript-web'
$gitHealth = $audit.Report.providers | Where-Object providerId -eq 'git.repository-health'

[pscustomobject]@{
    reportJson       = $audit.JsonPath
    reportMarkdown   = $audit.MarkdownPath
    comparisonJson   = Join-Path $comparisonDirectory 'comparison.json'
    comparisonText   = Join-Path $comparisonDirectory 'comparison.txt'
    projectsStatus   = $projects.status
    gitHealthStatus  = $gitHealth.status
} | ConvertTo-Json -Compress
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8

    function Invoke-PrivacyAudit {
        param(
            [Parameter(Mandatory)][string]$Executable,
            [Parameter(Mandatory)][string]$Name
        )

        $outputDirectory = Join-Path $TestDrive ('reports-' + ($Name -replace '[^A-Za-z0-9]', ''))
        $output = & $Executable -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runnerPath `
            -Repository $repositoryRoot `
            -OutputDirectory $outputDirectory `
            -LocalConfigurationPath $localConfigurationPath `
            -GitDirectory $gitDirectory `
            -CanaryName $canary['environment variable name'] `
            -CanaryValue $canary['environment variable value'] 2>&1
        $exitCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0

        if ($exitCode -ne 0) {
            throw "Privacy audit failed under ${Name}: $($output | Out-String)"
        }

        return (@($output)[-1] | ConvertFrom-Json)
    }

    function Get-OutputText {
        param([Parameter(Mandatory)][string]$Path)

        # JSON escapes backslashes; compare against the decoded form as well.
        $text = [IO.File]::ReadAllText($Path)
        return $text + [Environment]::NewLine + $text.Replace('\\', '\')
    }
}

AfterAll {
    # Git stores objects read-only, which Pester's TestDrive cleanup cannot delete.
    Remove-Item -LiteralPath (Join-Path $projectPath '.git') -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Report privacy boundary on <Name>' -ForEach $auditHosts {
    BeforeAll {
        $script:run = Invoke-PrivacyAudit -Executable $Executable -Name $Name
    }

    It 'inspects the synthetic project and repository, so absence checks are meaningful' {
        $run.projectsStatus | Should -Be 'success'
        $run.gitHealthStatus | Should -BeIn @('success', 'warning')
    }

    It 'keeps every planted secret out of <File>' -ForEach @(
        @{ File = 'the JSON report'; Property = 'reportJson' }
        @{ File = 'the Markdown report'; Property = 'reportMarkdown' }
        @{ File = 'comparison.json'; Property = 'comparisonJson' }
        @{ File = 'comparison.txt'; Property = 'comparisonText' }
    ) {
        $text = Get-OutputText -Path $run.$Property
        $leaks = @($canary.Keys | Where-Object { $text.Contains($canary[$_]) })

        $leaks -join ', ' | Should -BeNullOrEmpty
    }

    It 'keeps machine-specific Git and path details out of <File>' -ForEach @(
        @{ File = 'comparison.json'; Property = 'comparisonJson' }
        @{ File = 'comparison.txt'; Property = 'comparisonText' }
    ) {
        $text = Get-OutputText -Path $run.$Property
        $details = [ordered]@{
            'commit SHA'           = $commitSha
            'development root'     = $developmentRoot
            'repository path'      = $projectPath
            'remote host'          = $remoteHost
        }
        $leaks = @($details.Keys | Where-Object { $text.Contains($details[$_]) })

        $leaks -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Committed source privacy' {
    BeforeAll {
        Push-Location $repositoryRoot
        try {
            $script:committedFiles = @(git ls-files | Where-Object { $_ -notmatch '\.(?:png|jpe?g|gif|ico|zip)$' })
        }
        finally {
            Pop-Location
        }
    }

    It 'contains no secret-like markers in committed files' {
        $findings = foreach ($file in $committedFiles) {
            $text = [IO.File]::ReadAllText((Join-Path $repositoryRoot $file))
            foreach ($marker in Find-SecretMarker -Text $text) {
                "${file}: $marker"
            }
        }

        @($findings) -join [Environment]::NewLine | Should -BeNullOrEmpty
    }

    It 'contains no marker of the machine running the tests' {
        $machineMarkers = @($env:USERNAME, $env:COMPUTERNAME) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Length -ge 4 }

        # Detector sources list CI identities such as 'runneradmin' on purpose.
        $detectorFiles = @(
            'tests/hardening-contract/validate_hardening_fixtures.py'
            'tests/pester/privacy/Audit.Privacy.Tests.ps1'
        )

        $findings = foreach ($file in $committedFiles | Where-Object { $_ -notin $detectorFiles }) {
            $text = [IO.File]::ReadAllText((Join-Path $repositoryRoot $file))
            foreach ($marker in $machineMarkers) {
                if ($text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    "${file}: $marker"
                }
            }
        }

        @($findings) -join [Environment]::NewLine | Should -BeNullOrEmpty
    }

    It 'keeps <Path> ignored by Git' -ForEach @(
        @{ Path = 'reports/workstation-audit.json' }
        @{ Path = 'reports/comparison/comparison.json' }
        @{ Path = 'config/workstation.local.json' }
    ) {
        Push-Location $repositoryRoot
        try {
            & git check-ignore --quiet --no-index $Path
            $ignored = $LASTEXITCODE -eq 0
            $global:LASTEXITCODE = 0
        }
        finally {
            Pop-Location
        }

        $ignored | Should -BeTrue
    }

    It 'never enumerates the whole environment in production scripts' {
        $findings = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts') -Recurse -File -Include '*.ps1', '*.psm1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($node in Find-EnvironmentEnumeration -Ast $ast) {
                '{0}:{1}' -f $file.Name, $node.Extent.StartLineNumber
            }
        }

        @($findings) -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Privacy detectors' {
    It 'detects a controlled <Marker> example' -ForEach @(
        # Assembled at runtime so this file never contains a literal secret-like value.
        @{ Marker = 'GitHub token'; Sample = 'gh' + 'p_' + ('A1b2' * 9) }
        @{ Marker = 'npm token'; Sample = 'np' + 'm_' + ('Z9y8' * 9) }
        @{ Marker = 'AWS access key'; Sample = 'AK' + 'IA' + ('QWERTY12' * 2) }
        @{ Marker = 'private key'; Sample = '-----BEGIN ' + 'RSA PRIVATE KEY-----' }
        @{ Marker = 'JSON Web Token'; Sample = 'ey' + 'JhbGciOiJIUzI1NiJ9.ey' + 'JzdWIiOiIxMjM0NTY3ODkwIn0.' + 'abcdefghijklmnop' }
        @{ Marker = 'Slack token'; Sample = 'xo' + 'xb-' + '1234567890-abcdef' }
        @{ Marker = 'URL credentials'; Sample = 'https://' + 'deploy:' + 'hunter2hunter2@' + 'git.contoso.com/repo.git' }
        @{ Marker = 'secret assignment'; Sample = 'api_' + 'key = "' + 'Zx81Kq02Lm93Pv' + '"' }
        @{ Marker = 'user profile path'; Sample = 'C:' + '\Users\' + 'alice\projects' }
        @{ Marker = 'personal email'; Sample = 'alice' + '@' + 'contoso.com' }
    ) {
        Find-SecretMarker -Text "prefix $Sample suffix" | Should -Contain $Marker
    }

    It 'accepts reserved synthetic values used by the fixtures' {
        Find-SecretMarker -Text 'https://user:pass@example.invalid/repo.git synthetic@example.invalid C:\Users\<user>\' | Should -BeNullOrEmpty
    }

    It 'detects <Case> environment enumeration' -ForEach @(
        @{ Case = 'drive'; Source = 'Get-ChildItem Env:' }
        @{ Case = 'wildcard drive'; Source = 'dir env:*' }
        @{ Case = '.NET'; Source = '[Environment]::GetEnvironmentVariables()' }
    ) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$null)
        @(Find-EnvironmentEnumeration -Ast $ast) | Should -HaveCount 1
    }

    It 'allows reading a single named environment variable' {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput('$env:PATH; [Environment]::GetEnvironmentVariable(''JAVA_HOME'', ''User'')', [ref]$null, [ref]$null)
        @(Find-EnvironmentEnumeration -Ast $ast) | Should -HaveCount 0
    }
}
