[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Describe')]
    [switch]$Describe,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [psobject]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Describe) {
    return [pscustomobject][ordered]@{
        providerId = 'projects.non-javascript'
        category   = 'projects'
        order      = 42
    }
}

$corePath = Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1'
Import-Module $corePath -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$hasPartial = $false

function Get-PreviousProvider {
    param([Parameter(Mandatory)][string]$ProviderId)

    return @(
        @($Context.PreviousProviderResults) |
            Where-Object providerId -eq $ProviderId |
            Select-Object -First 1
    )[0]
}

function Read-SafeText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 1048576)][int]$MaximumLength = 262144
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ state = 'missing'; value = $null }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ($raw.Length -gt $MaximumLength) {
            return [pscustomobject][ordered]@{ state = 'too-large'; value = $null }
        }

        return [pscustomobject][ordered]@{ state = 'read'; value = $raw }
    }
    catch {
        return [pscustomobject][ordered]@{ state = 'unreadable'; value = $null }
    }
}

function Read-SafeJson {
    param([Parameter(Mandatory)][string]$Path)

    $text = Read-SafeText -Path $Path -MaximumLength 1048576
    if ($text.state -ne 'read') {
        return [pscustomobject][ordered]@{ state = $text.state; value = $null }
    }

    try {
        return [pscustomobject][ordered]@{
            state = 'read'
            value = ($text.value | ConvertFrom-Json -ErrorAction Stop)
        }
    }
    catch {
        return [pscustomobject][ordered]@{ state = 'invalid'; value = $null }
    }
}

function Get-JsonProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-RegexValue {
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $match = [regex]::Match(
        $Text,
        $Pattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [Text.RegularExpressions.RegexOptions]::Multiline
    )

    if (-not $match.Success) { return $null }

    if ($match.Groups['value'].Success) {
        return $match.Groups['value'].Value.Trim()
    }

    return $match.Value.Trim()
}

function Add-Constraint {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory)][string]$Ecosystem,
        [Parameter(Mandatory)][string]$Source,
        [AllowNull()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return }

    $List.Add([pscustomobject][ordered]@{
        ecosystem = $Ecosystem
        source = $Source
        value = $Value.Trim()
    })
}

$projectsLocal = Get-PreviousProvider -ProviderId 'projects.local'

if ($null -eq $projectsLocal) {
    $evidence.Add((New-AuditEvidence -EvidenceId 'projects.non-javascript.summary' -Type derived -Source 'projects.local dependency' -Captured $null -Attributes @{
        dependencyAvailable = $false
        projectCount = 0
        readOnly = $true
        independentFilesystemTraversal = $false
        executesProjectCode = $false
        buildOrRestoreInvoked = $false
    }))

    return [pscustomobject][ordered]@{
        providerId = 'projects.non-javascript'
        category   = 'projects'
        status     = Get-AuditProviderStatus -Unavailable
        observedAt = $Context.ObservedAt
        components = @()
        warnings   = @()
        errors     = @()
        evidence   = $evidence.ToArray()
    }
}

$discoveryEvidence = @(
    $projectsLocal.evidence |
        Where-Object evidenceId -eq 'projects.local.discovery' |
        Select-Object -First 1
)[0]

$candidates = if ($null -ne $discoveryEvidence) {
    @($discoveryEvidence.attributes.candidates)
}
else {
    @()
}

$models = New-Object System.Collections.Generic.List[object]

for ($index = 0; $index -lt $candidates.Count; $index++) {
    $candidate = $candidates[$index]
    $projectPath = [string]$candidate.path

    if ([string]::IsNullOrWhiteSpace($projectPath) -or -not (Test-Path -LiteralPath $projectPath -PathType Container)) {
        continue
    }

    $types = New-Object System.Collections.Generic.List[string]
    $constraints = New-Object System.Collections.Generic.List[object]
    $markers = New-Object System.Collections.Generic.List[string]
    $ambiguous = $false

    # Flutter / Dart
    $pubspecPath = Join-Path $projectPath 'pubspec.yaml'
    $pubspec = Read-SafeText -Path $pubspecPath
    if ($pubspec.state -eq 'read') {
        $types.Add('dart')
        $markers.Add('pubspec.yaml')

        $dartConstraint = Get-RegexValue -Text $pubspec.value -Pattern '(?ms)^environment\s*:\s*\r?\n(?:[ \t]+[^\r\n]+\r?\n)*?[ \t]+sdk\s*:\s*[''"]?(?<value>[^''"\r\n#]+)'
        Add-Constraint -List $constraints -Ecosystem 'dart' -Source 'pubspec.yaml#environment.sdk' -Value $dartConstraint

        if (
            $pubspec.value -match '(?m)^[ \t]*flutter\s*:' -or
            (Test-Path -LiteralPath (Join-Path $projectPath '.metadata') -PathType Leaf)
        ) {
            $types.Add('flutter')
        }
    }
    elseif ($pubspec.state -in @('too-large','unreadable')) {
        $ambiguous = $true
    }

    $flutterVersion = Read-SafeText -Path (Join-Path $projectPath '.flutter-version') -MaximumLength 4096
    if ($flutterVersion.state -eq 'read') {
        Add-Constraint -List $constraints -Ecosystem 'flutter' -Source '.flutter-version' -Value $flutterVersion.value
    }

    $fvm = Read-SafeJson -Path (Join-Path $projectPath '.fvmrc')
    if ($fvm.state -eq 'read') {
        $fvmFlutter = [string](Get-JsonProperty -Object $fvm.value -Name 'flutter')
        Add-Constraint -List $constraints -Ecosystem 'flutter' -Source '.fvmrc#flutter' -Value $fvmFlutter
    }
    elseif ($fvm.state -in @('invalid','too-large','unreadable')) {
        $ambiguous = $true
    }

    # Python
    $pythonMarkerNames = @('pyproject.toml','requirements.txt','Pipfile','poetry.lock','uv.lock','setup.cfg','setup.py')
    foreach ($name in $pythonMarkerNames) {
        if (Test-Path -LiteralPath (Join-Path $projectPath $name) -PathType Leaf) {
            if (-not $types.Contains('python')) { $types.Add('python') }
            $markers.Add($name)
        }
    }

    $pythonVersion = Read-SafeText -Path (Join-Path $projectPath '.python-version') -MaximumLength 4096
    if ($pythonVersion.state -eq 'read') {
        Add-Constraint -List $constraints -Ecosystem 'python' -Source '.python-version' -Value $pythonVersion.value
    }

    $runtimeTxt = Read-SafeText -Path (Join-Path $projectPath 'runtime.txt') -MaximumLength 4096
    if ($runtimeTxt.state -eq 'read') {
        Add-Constraint -List $constraints -Ecosystem 'python' -Source 'runtime.txt' -Value $runtimeTxt.value
    }

    $pyproject = Read-SafeText -Path (Join-Path $projectPath 'pyproject.toml')
    if ($pyproject.state -eq 'read') {
        $requiresPython = Get-RegexValue -Text $pyproject.value -Pattern '(?m)^[ \t]*requires-python[ \t]*=[ \t]*[''"](?<value>[^''"]+)[''"]'
        Add-Constraint -List $constraints -Ecosystem 'python' -Source 'pyproject.toml#requires-python' -Value $requiresPython
    }
    elseif ($pyproject.state -in @('too-large','unreadable')) {
        $ambiguous = $true
    }

    # Rust
    $cargoPath = Join-Path $projectPath 'Cargo.toml'
    if (Test-Path -LiteralPath $cargoPath -PathType Leaf) {
        $types.Add('rust')
        $markers.Add('Cargo.toml')
    }

    $rustToolchainToml = Read-SafeText -Path (Join-Path $projectPath 'rust-toolchain.toml')
    if ($rustToolchainToml.state -eq 'read') {
        $channel = Get-RegexValue -Text $rustToolchainToml.value -Pattern '(?m)^[ \t]*channel[ \t]*=[ \t]*[''"](?<value>[^''"]+)[''"]'
        Add-Constraint -List $constraints -Ecosystem 'rust' -Source 'rust-toolchain.toml#toolchain.channel' -Value $channel
    }
    elseif ($rustToolchainToml.state -in @('too-large','unreadable')) {
        $ambiguous = $true
    }

    $rustToolchain = Read-SafeText -Path (Join-Path $projectPath 'rust-toolchain') -MaximumLength 4096
    if ($rustToolchain.state -eq 'read') {
        Add-Constraint -List $constraints -Ecosystem 'rust' -Source 'rust-toolchain' -Value $rustToolchain.value
    }

    # Go
    foreach ($goName in @('go.mod','go.work')) {
        $goFile = Read-SafeText -Path (Join-Path $projectPath $goName)
        if ($goFile.state -eq 'read') {
            if (-not $types.Contains('go')) { $types.Add('go') }
            $markers.Add($goName)
            $goVersion = Get-RegexValue -Text $goFile.value -Pattern '(?m)^go[ \t]+(?<value>[^\s#]+)'
            $goToolchain = Get-RegexValue -Text $goFile.value -Pattern '(?m)^toolchain[ \t]+(?<value>[^\s#]+)'
            Add-Constraint -List $constraints -Ecosystem 'go' -Source "$goName#go" -Value $goVersion
            Add-Constraint -List $constraints -Ecosystem 'go' -Source "$goName#toolchain" -Value $goToolchain
        }
        elseif ($goFile.state -in @('too-large','unreadable')) {
            $ambiguous = $true
        }
    }

    # .NET
    $dotnetFiles = @(
        Get-ChildItem -LiteralPath $projectPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)\.(sln|csproj|fsproj|vbproj)$' }
    )
    if ($dotnetFiles.Count -gt 0) {
        $types.Add('dotnet')
        foreach ($file in $dotnetFiles) { $markers.Add([string]$file.Name) }
    }

    $globalJson = Read-SafeJson -Path (Join-Path $projectPath 'global.json')
    if ($globalJson.state -eq 'read') {
        if (-not $types.Contains('dotnet')) { $types.Add('dotnet') }
        $markers.Add('global.json')
        $sdk = Get-JsonProperty -Object $globalJson.value -Name 'sdk'
        $sdkVersion = [string](Get-JsonProperty -Object $sdk -Name 'version')
        Add-Constraint -List $constraints -Ecosystem 'dotnet' -Source 'global.json#sdk.version' -Value $sdkVersion
    }
    elseif ($globalJson.state -in @('invalid','too-large','unreadable')) {
        $ambiguous = $true
    }

    # Maven
    $pomPath = Join-Path $projectPath 'pom.xml'
    $pom = Read-SafeText -Path $pomPath
    if ($pom.state -eq 'read') {
        $types.Add('maven')
        $markers.Add('pom.xml')
        $release = Get-RegexValue -Text $pom.value -Pattern '<maven\.compiler\.release>\s*(?<value>[^<]+)\s*</maven\.compiler\.release>'
        Add-Constraint -List $constraints -Ecosystem 'java' -Source 'pom.xml#maven.compiler.release' -Value $release
    }
    elseif ($pom.state -in @('too-large','unreadable')) {
        $ambiguous = $true
    }

    $mavenWrapper = Read-SafeText -Path (Join-Path $projectPath '.mvn\wrapper\maven-wrapper.properties')
    if ($mavenWrapper.state -eq 'read') {
        if (-not $types.Contains('maven')) { $types.Add('maven') }
        $wrapperVersion = Get-RegexValue -Text $mavenWrapper.value -Pattern 'apache-maven-(?<value>[0-9][0-9A-Za-z.\-]+)-bin'
        Add-Constraint -List $constraints -Ecosystem 'maven' -Source '.mvn/wrapper/maven-wrapper.properties#distributionUrl' -Value $wrapperVersion
    }

    # Gradle
    $gradleMarker = $false
    foreach ($gradleName in @('build.gradle','build.gradle.kts','settings.gradle','settings.gradle.kts','gradlew','gradlew.bat')) {
        if (Test-Path -LiteralPath (Join-Path $projectPath $gradleName)) {
            $gradleMarker = $true
            $markers.Add($gradleName)
        }
    }

    $gradleWrapper = Read-SafeText -Path (Join-Path $projectPath 'gradle\wrapper\gradle-wrapper.properties')
    if ($gradleWrapper.state -eq 'read') {
        $gradleMarker = $true
        $markers.Add('gradle/wrapper/gradle-wrapper.properties')
        $gradleVersion = Get-RegexValue -Text $gradleWrapper.value -Pattern 'gradle-(?<value>[0-9][0-9A-Za-z.\-]+)-(?:bin|all)\.zip'
        Add-Constraint -List $constraints -Ecosystem 'gradle' -Source 'gradle/wrapper/gradle-wrapper.properties#distributionUrl' -Value $gradleVersion
    }

    if ($gradleMarker) {
        $types.Add('gradle')
    }

    $uniqueTypes = @($types.ToArray() | Sort-Object -Unique)
    if ($uniqueTypes.Count -eq 0) {
        continue
    }

    $uniqueMarkers = @($markers.ToArray() | Sort-Object -Unique)
    $model = [pscustomobject][ordered]@{
        projectIndex = $index
        path = $projectPath
        repositoryMarker = [bool]$candidate.repositoryMarker
        types = $uniqueTypes
        markers = $uniqueMarkers
        constraints = $constraints.ToArray()
        ambiguous = $ambiguous
    }

    $models.Add($model)

    $evidenceId = "projects.non-javascript.project-$index"
    $evidence.Add((New-AuditEvidence -EvidenceId $evidenceId -Type filesystem -Source 'projects.local candidate' -Captured $null -Attributes @{
        project = $model
        canonicalFilesOnly = $true
        projectCodeExecuted = $false
        buildRestoreInvoked = $false
        dependencyResolutionInvoked = $false
        environmentCreated = $false
        packageInstallationInvoked = $false
    }))

    if ($ambiguous) {
        $hasPartial = $true
        $warnings.Add((New-AuditIssue -Code 'NON_JS_PROJECT_CANONICAL_EVIDENCE_PARTIAL' -Message "Non-JavaScript project candidate index $index contains canonical configuration that could not be fully parsed." -Severity warning -EvidenceIds @($evidenceId)))
    }
}

$summaryId = 'projects.non-javascript.summary'
$evidence.Add((New-AuditEvidence -EvidenceId $summaryId -Type derived -Source 'projects.local discovery evidence' -Captured $null -Attributes @{
    dependencyAvailable = $true
    candidateCount = $candidates.Count
    projectCount = $models.Count
    flutterProjectCount = @($models | Where-Object { $_.types -contains 'flutter' }).Count
    dartProjectCount = @($models | Where-Object { $_.types -contains 'dart' }).Count
    pythonProjectCount = @($models | Where-Object { $_.types -contains 'python' }).Count
    rustProjectCount = @($models | Where-Object { $_.types -contains 'rust' }).Count
    goProjectCount = @($models | Where-Object { $_.types -contains 'go' }).Count
    dotnetProjectCount = @($models | Where-Object { $_.types -contains 'dotnet' }).Count
    mavenProjectCount = @($models | Where-Object { $_.types -contains 'maven' }).Count
    gradleProjectCount = @($models | Where-Object { $_.types -contains 'gradle' }).Count
    mixedProjectCount = @($models | Where-Object { @($_.types).Count -gt 1 }).Count
    partialProjectCount = @($models | Where-Object ambiguous).Count
    projects = $models.ToArray()
    readOnly = $true
    reusedProjectsLocalDiscovery = $true
    independentFilesystemTraversal = $false
    canonicalFilesOnly = $true
    executesProjectCode = $false
    buildOrRestoreInvoked = $false
    dependencyResolutionInvoked = $false
    environmentCreated = $false
    packageInstallationInvoked = $false
    globalRuntimeEvidenceModified = $false
}))

$status = if ($models.Count -eq 0 -and $warnings.Count -eq 0) {
    Get-AuditProviderStatus -NotApplicable
}
else {
    Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:$hasPartial
}

return [pscustomobject][ordered]@{
    providerId = 'projects.non-javascript'
    category   = 'projects'
    status     = $status
    observedAt = $Context.ObservedAt
    components = @()
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
