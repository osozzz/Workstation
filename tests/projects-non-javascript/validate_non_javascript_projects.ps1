[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$localProvider = Join-Path $root 'scripts\Providers\ProjectsLocal.Provider.ps1'
$provider = Join-Path $root 'scripts\Providers\NonJavaScriptProjects.Provider.ps1'

$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$tempRoot = Join-Path $tempBase "workstation-non-js-projects-$([guid]::NewGuid().ToString('N'))"

function Write-Text {
    param([string]$Path,[string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Write-Json {
    param([string]$Path,[object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $flutter = Join-Path $tempRoot 'FlutterApp'
    Write-Text (Join-Path $flutter 'pubspec.yaml') @'
name: synthetic_flutter
environment:
  sdk: ">=3.5.0 <4.0.0"
flutter:
  uses-material-design: true
'@
    Write-Json (Join-Path $flutter '.fvmrc') @{ flutter = '3.35.0' }

    $dart = Join-Path $tempRoot 'DartPackage'
    Write-Text (Join-Path $dart 'pubspec.yaml') @'
name: synthetic_dart
environment:
  sdk: "^3.5.0"
'@

    $python = Join-Path $tempRoot 'PythonPkg'
    Write-Text (Join-Path $python 'pyproject.toml') @'
[project]
name = "synthetic-python"
requires-python = ">=3.12"
'@
    Write-Text (Join-Path $python '.python-version') '3.13.1'

    $rust = Join-Path $tempRoot 'RustCrate'
    Write-Text (Join-Path $rust 'Cargo.toml') @'
[package]
name = "synthetic-rust"
version = "0.1.0"
'@
    Write-Text (Join-Path $rust 'rust-toolchain.toml') @'
[toolchain]
channel = "stable"
'@

    $go = Join-Path $tempRoot 'GoModule'
    Write-Text (Join-Path $go 'go.mod') @'
module synthetic.example/go

go 1.25.0
toolchain go1.25.1
'@

    $dotnet = Join-Path $tempRoot 'DotNetApp'
    Write-Text (Join-Path $dotnet 'Synthetic.csproj') '<Project Sdk="Microsoft.NET.Sdk"></Project>'
    Write-Json (Join-Path $dotnet 'global.json') @{ sdk = @{ version = '10.0.100' } }

    $maven = Join-Path $tempRoot 'MavenApp'
    Write-Text (Join-Path $maven 'pom.xml') @'
<project>
  <properties>
    <maven.compiler.release>21</maven.compiler.release>
  </properties>
</project>
'@
    Write-Text (Join-Path $maven '.mvn\wrapper\maven-wrapper.properties') 'distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.11/apache-maven-3.9.11-bin.zip'

    $gradle = Join-Path $tempRoot 'GradleApp'
    Write-Text (Join-Path $gradle 'build.gradle.kts') 'plugins { java }'
    Write-Text (Join-Path $gradle 'gradle\wrapper\gradle-wrapper.properties') 'distributionUrl=https\://services.gradle.org/distributions/gradle-9.1.0-bin.zip'

    $mixed = Join-Path $tempRoot 'MixedRepo'
    Write-Text (Join-Path $mixed 'go.mod') @'
module synthetic.example/mixed

go 1.24
'@
    Write-Text (Join-Path $mixed 'pyproject.toml') @'
[project]
name = "synthetic-mixed"
requires-python = ">=3.11"
'@

    $ambiguous = Join-Path $tempRoot 'AmbiguousDotNet'
    Write-Text (Join-Path $ambiguous 'global.json') '{ definitely-not-json }'

    $localContext = [pscustomobject][ordered]@{
        ObservedAt               = (Get-Date).ToString('o')
        LocalConfigurationState  = 'loaded'
        LocalConfigurationSource = 'workstation.local.json'
        LocalConfigurationError  = $null
        DevelopmentRoots         = @($tempRoot)
        ProjectDiscoveryMaxDepth = 4
        PreviousProviderResults  = @()
    }

    $local = & $localProvider -Context $localContext
    $context = [pscustomobject][ordered]@{
        ObservedAt = (Get-Date).ToString('o')
        PreviousProviderResults = @($local)
    }

    $result = & $provider -Context $context

    if ($result.providerId -ne 'projects.non-javascript') {
        throw 'Unexpected non-JavaScript provider id.'
    }

    if (@($result.components).Count -ne 0) {
        throw 'Non-JavaScript project provider must remain evidence-only.'
    }

    if ($result.status -ne 'partial') {
        throw "Expected partial provider status because one canonical config is intentionally invalid; got '$($result.status)'."
    }

    $summary = @($result.evidence | Where-Object evidenceId -eq 'projects.non-javascript.summary')[0]
    if (-not $summary) {
        throw 'Missing non-JavaScript summary evidence.'
    }

    $expectedCounts = @{
        projectCount         = 10
        flutterProjectCount  = 1
        dartProjectCount     = 2
        pythonProjectCount   = 2
        rustProjectCount     = 1
        goProjectCount       = 2
        dotnetProjectCount   = 2
        mavenProjectCount    = 1
        gradleProjectCount   = 1
        mixedProjectCount    = 2
        partialProjectCount  = 1
    }

    foreach ($name in $expectedCounts.Keys) {
        $actual = [int]$summary.attributes.$name
        $expected = [int]$expectedCounts[$name]
        if ($actual -ne $expected) {
            throw ("Unexpected {0}: expected {1}, got {2}." -f $name, $expected, $actual)
        }
    }

    foreach ($flag in @('readOnly','reusedProjectsLocalDiscovery','canonicalFilesOnly')) {
        if ($summary.attributes.$flag -ne $true) {
            throw "Expected $flag=true."
        }
    }

    foreach ($flag in @(
        'independentFilesystemTraversal',
        'executesProjectCode',
        'buildOrRestoreInvoked',
        'dependencyResolutionInvoked',
        'environmentCreated',
        'packageInstallationInvoked',
        'globalRuntimeEvidenceModified'
    )) {
        if ($summary.attributes.$flag -ne $false) {
            throw "Expected $flag=false."
        }
    }

    $projects = @($summary.attributes.projects)
    $allTypes = @($projects | ForEach-Object { @($_.types) })

    foreach ($requiredType in @('flutter','dart','python','rust','go','dotnet','maven','gradle')) {
        if ($allTypes -notcontains $requiredType) {
            throw "Missing non-JavaScript project type '$requiredType'."
        }
    }

    $mixedProject = @($projects | Where-Object { $_.path -eq $mixed })[0]
    if (@($mixedProject.types).Count -ne 2 -or
        @($mixedProject.types) -notcontains 'go' -or
        @($mixedProject.types) -notcontains 'python') {
        throw 'Mixed project must preserve both Go and Python classifications.'
    }

    $constraintPairs = @(
        $projects |
            ForEach-Object { @($_.constraints) } |
            ForEach-Object { "$($_.ecosystem)|$($_.source)|$($_.value)" }
    )

    foreach ($fragment in @(
        'dart|pubspec.yaml#environment.sdk|>=3.5.0 <4.0.0',
        'flutter|.fvmrc#flutter|3.35.0',
        'python|.python-version|3.13.1',
        'python|pyproject.toml#requires-python|>=3.12',
        'rust|rust-toolchain.toml#toolchain.channel|stable',
        'go|go.mod#go|1.25.0',
        'go|go.mod#toolchain|go1.25.1',
        'dotnet|global.json#sdk.version|10.0.100',
        'java|pom.xml#maven.compiler.release|21',
        'maven|.mvn/wrapper/maven-wrapper.properties#distributionUrl|3.9.11',
        'gradle|gradle/wrapper/gradle-wrapper.properties#distributionUrl|9.1.0'
    )) {
        if ($constraintPairs -notcontains $fragment) {
            throw "Missing canonical project constraint '$fragment'."
        }
    }

    $ambiguousProject = @($projects | Where-Object { $_.path -eq $ambiguous })[0]
    if (-not $ambiguousProject.ambiguous -or @($ambiguousProject.types) -notcontains 'dotnet') {
        throw 'Invalid global.json must remain a partial .NET project classification.'
    }

    $warningCodes = @($result.warnings | ForEach-Object code)
    if ($warningCodes -notcontains 'NON_JS_PROJECT_CANONICAL_EVIDENCE_PARTIAL') {
        throw 'Expected partial canonical-evidence warning.'
    }

    $source = Get-Content -LiteralPath $provider -Raw
    foreach ($forbidden in @(
        'dotnet restore',
        'dotnet build',
        'flutter pub',
        'dart pub',
        'pip install',
        'poetry install',
        'cargo build',
        'go get',
        'go mod download',
        'mvn ',
        'gradle ',
        'Invoke-AuditCommand'
    )) {
        if ($source -match [Regex]::Escape($forbidden)) {
            throw "Provider source contains forbidden execution marker '$forbidden'."
        }
    }

    Write-Host 'Non-JavaScript project detection validation passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
