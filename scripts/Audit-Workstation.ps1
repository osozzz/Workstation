[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\reports'),
    [switch]$IncludeWingetInventory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Invoke-ToolText {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @()
    )

    $resolved = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $resolved) {
        return [pscustomobject]@{
            Found = $false
            ExitCode = $null
            Output = $null
        }
    }

    try {
        $global:LASTEXITCODE = 0
        $text = (& $Command @Arguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
        return [pscustomobject]@{
            Found = $true
            ExitCode = $code
            Output = $text
        }
    }
    catch {
        return [pscustomobject]@{
            Found = $true
            ExitCode = -1
            Output = $_.Exception.Message
        }
    }
}

function Get-CommandResolution {
    param([Parameter(Mandatory)][string]$Name)

    $items = @(Get-Command $Name -All -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { return @() }

    return @($items | ForEach-Object {
        $source = $_.Source
        if (-not $source -and $_.Path) { $source = $_.Path }
        [pscustomobject]@{
            CommandType = $_.CommandType.ToString()
            Name = $_.Name
            Source = $source
            Version = if ($_.Version) { $_.Version.ToString() } else { $null }
        }
    })
}

function Split-PathEntries {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
}

function Get-PathHealth {
    param(
        [Parameter(Mandatory)][string]$Scope,
        [AllowNull()][string]$RawPath
    )

    $entries = Split-PathEntries $RawPath
    $seen = @{}
    $details = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $entries) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry)
        $unresolved = $expanded -match '%[^%]+%'
        $key = $expanded.TrimEnd('\').ToLowerInvariant()
        $duplicate = $seen.ContainsKey($key)
        if (-not $duplicate) { $seen[$key] = $true }

        $exists = $null
        if (-not $unresolved) {
            try { $exists = Test-Path -LiteralPath $expanded } catch { $exists = $false }
        }

        $details.Add([pscustomobject]@{
            Entry = $entry
            Expanded = $expanded
            Exists = $exists
            Duplicate = $duplicate
            HasUnresolvedVariable = $unresolved
        })
    }

    [pscustomobject]@{
        Scope = $Scope
        EntryCount = $entries.Count
        DuplicateCount = @($details | Where-Object Duplicate).Count
        MissingCount = @($details | Where-Object { $_.Exists -eq $false }).Count
        UnresolvedVariableCount = @($details | Where-Object HasUnresolvedVariable).Count
        Entries = @($details)
    }
}

function Get-ToolRecord {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$VersionArguments = @('--version')
    )

    $result = Invoke-ToolText -Command $Command -Arguments $VersionArguments
    [pscustomobject]@{
        Label = $Label
        Command = $Command
        Installed = $result.Found
        ExitCode = $result.ExitCode
        VersionOutput = $result.Output
        Resolution = @(Get-CommandResolution $Command)
    }
}

function Convert-ToMarkdownSafe {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value.ToString() -replace '\|', '\|' -replace "`r?`n", '<br>')
}

Ensure-Directory $OutputDirectory
$timestamp = Get-Date
$stamp = $timestamp.ToString('yyyyMMdd-HHmmss')
$computerName = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($computerName)) { $computerName = 'Windows-PC' }
$safeComputerName = ($computerName -replace '[^A-Za-z0-9._-]', '_')

# Intentionally whitelisted environment variables only. This script never dumps all
# environment variables, because developer machines often contain secrets/tokens.
$envNames = @(
    'NVM_HOME','NVM_SYMLINK','PNPM_HOME','JAVA_HOME','ANDROID_HOME','ANDROID_SDK_ROOT',
    'FLUTTER_ROOT','PUB_CACHE','CARGO_HOME','RUSTUP_HOME','GOPATH','GOROOT','PYENV_ROOT'
)
$environment = foreach ($name in $envNames) {
    [pscustomobject]@{
        Name = $name
        Process = [Environment]::GetEnvironmentVariable($name, 'Process')
        User = [Environment]::GetEnvironmentVariable($name, 'User')
        Machine = [Environment]::GetEnvironmentVariable($name, 'Machine')
    }
}

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$processPath = [Environment]::GetEnvironmentVariable('Path', 'Process')

$toolSpecs = @(
    @{ Label='Node.js'; Command='node'; Args=@('--version') },
    @{ Label='npm'; Command='npm'; Args=@('--version') },
    @{ Label='pnpm'; Command='pnpm'; Args=@('--version') },
    @{ Label='NVM for Windows'; Command='nvm'; Args=@('--version') },
    @{ Label='Angular CLI'; Command='ng'; Args=@('version') },
    @{ Label='TypeScript'; Command='tsc'; Args=@('--version') },
    @{ Label='Prisma'; Command='prisma'; Args=@('--version') },
    @{ Label='Nodemon'; Command='nodemon'; Args=@('--version') },
    @{ Label='Rimraf'; Command='rimraf'; Args=@('--version') },
    @{ Label='Zoho Extension Toolkit'; Command='zet'; Args=@('-v') },
    @{ Label='Zoho Catalyst CLI'; Command='catalyst'; Args=@('--version') },
    @{ Label='Heroku CLI'; Command='heroku'; Args=@('--version') },
    @{ Label='Redis Commander'; Command='redis-commander'; Args=@('--version') },
    @{ Label='Flutter'; Command='flutter'; Args=@('--version') },
    @{ Label='Dart'; Command='dart'; Args=@('--version') },
    @{ Label='Python'; Command='python'; Args=@('--version') },
    @{ Label='Python Launcher'; Command='py'; Args=@('--version') },
    @{ Label='pip'; Command='pip'; Args=@('--version') },
    @{ Label='pipx'; Command='pipx'; Args=@('--version') },
    @{ Label='uv'; Command='uv'; Args=@('--version') },
    @{ Label='Java'; Command='java'; Args=@('-version') },
    @{ Label='Javac'; Command='javac'; Args=@('-version') },
    @{ Label='Maven'; Command='mvn'; Args=@('-version') },
    @{ Label='Gradle'; Command='gradle'; Args=@('--version') },
    @{ Label='.NET SDK'; Command='dotnet'; Args=@('--version') },
    @{ Label='Rust'; Command='rustc'; Args=@('--version') },
    @{ Label='Cargo'; Command='cargo'; Args=@('--version') },
    @{ Label='Rustup'; Command='rustup'; Args=@('--version') },
    @{ Label='Go'; Command='go'; Args=@('version') },
    @{ Label='Git'; Command='git'; Args=@('--version') },
    @{ Label='GitHub CLI'; Command='gh'; Args=@('--version') },
    @{ Label='Docker'; Command='docker'; Args=@('--version') },
    @{ Label='Docker Compose'; Command='docker'; Args=@('compose','version') },
    @{ Label='ADB'; Command='adb'; Args=@('--version') },
    @{ Label='Supabase CLI'; Command='supabase'; Args=@('--version') },
    @{ Label='Vercel CLI'; Command='vercel'; Args=@('--version') },
    @{ Label='WinGet'; Command='winget'; Args=@('--version') }
)

$tools = foreach ($spec in $toolSpecs) {
    Get-ToolRecord -Label $spec.Label -Command $spec.Command -VersionArguments $spec.Args
}

# Detect command collisions by distinct source directories. Multiple shims (.ps1/.cmd)
# in the same directory are treated as one installation location.
$collisionNames = @('node','npm','pnpm','nvm','ng','tsc','prisma','zet','catalyst','heroku','flutter','dart','python','java','git','gh','docker')
$collisions = foreach ($name in $collisionNames) {
    $resolution = @(Get-CommandResolution $name)
    $dirs = @($resolution | ForEach-Object {
        if ($_.Source) { Split-Path -Parent $_.Source }
    } | Where-Object { $_ } | Sort-Object -Unique)

    [pscustomobject]@{
        Command = $name
        InstallationLocationCount = $dirs.Count
        HasCollision = $dirs.Count -gt 1
        Directories = $dirs
        Resolution = $resolution
    }
}

$wingetUpgrade = Invoke-ToolText -Command 'winget' -Arguments @('upgrade','--accept-source-agreements','--disable-interactivity')
$wingetList = $null
if ($IncludeWingetInventory) {
    $wingetList = Invoke-ToolText -Command 'winget' -Arguments @('list','--accept-source-agreements','--disable-interactivity')
}

$npmGlobals = Invoke-ToolText -Command 'npm' -Arguments @('list','-g','--depth=0','--json')
$pnpmGlobals = Invoke-ToolText -Command 'pnpm' -Arguments @('list','-g','--depth=0','--json')
$pnpmOutdated = Invoke-ToolText -Command 'pnpm' -Arguments @('outdated','-g')
$flutterDoctor = Invoke-ToolText -Command 'flutter' -Arguments @('doctor','-v')

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

$report = [ordered]@{
    SchemaVersion = '1.0'
    GeneratedAt = $timestamp.ToString('o')
    Computer = [ordered]@{
        Name = $computerName
        Manufacturer = $cs.Manufacturer
        Model = $cs.Model
        SystemType = $cs.SystemType
        TotalPhysicalMemoryBytes = [int64]$cs.TotalPhysicalMemory
        Processor = $cpu.Name
    }
    Windows = [ordered]@{
        Caption = $os.Caption
        Version = $os.Version
        BuildNumber = $os.BuildNumber
        Architecture = $os.OSArchitecture
    }
    PowerShell = [ordered]@{
        Edition = $PSVersionTable.PSEdition
        Version = $PSVersionTable.PSVersion.ToString()
    }
    Tools = @($tools)
    CommandCollisions = @($collisions)
    PathHealth = [ordered]@{
        Machine = Get-PathHealth -Scope 'Machine' -RawPath $machinePath
        User = Get-PathHealth -Scope 'User' -RawPath $userPath
        Process = Get-PathHealth -Scope 'Process' -RawPath $processPath
    }
    EnvironmentVariables = @($environment)
    PackageManagers = [ordered]@{
        NpmGlobalListJson = $npmGlobals.Output
        PnpmGlobalListJson = $pnpmGlobals.Output
        PnpmOutdatedGlobal = $pnpmOutdated.Output
        WinGetUpgrades = $wingetUpgrade.Output
        WinGetList = if ($wingetList) { $wingetList.Output } else { $null }
    }
    FlutterDoctor = $flutterDoctor.Output
}

$jsonPath = Join-Path $OutputDirectory "$safeComputerName-$stamp.json"
$mdPath = Join-Path $OutputDirectory "$safeComputerName-$stamp.md"
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$warnings = New-Object System.Collections.Generic.List[string]
foreach ($scopeName in @('Machine','User','Process')) {
    $health = $report.PathHealth[$scopeName]
    if ($health.DuplicateCount -gt 0) { $warnings.Add("$scopeName PATH has $($health.DuplicateCount) duplicate entr$(if($health.DuplicateCount -eq 1){'y'}else{'ies'}).") }
    if ($health.MissingCount -gt 0) { $warnings.Add("$scopeName PATH has $($health.MissingCount) missing/nonexistent entr$(if($health.MissingCount -eq 1){'y'}else{'ies'}).") }
}
foreach ($collision in $collisions | Where-Object HasCollision) {
    $warnings.Add("Command '$($collision.Command)' resolves from $($collision.InstallationLocationCount) different directories.")
}

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Developer Workstation Audit')
$md.Add('')
$md.Add("- **Computer:** $computerName")
$md.Add("- **Generated:** $($timestamp.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
$md.Add("- **Windows:** $($os.Caption) $($os.Version) (build $($os.BuildNumber))")
$md.Add("- **PowerShell:** $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)")
$md.Add('')
$md.Add('> Read-only audit. This report intentionally captures only a safe whitelist of environment variables and does not dump secrets/tokens.')
$md.Add('')
$md.Add('## Summary warnings')
$md.Add('')
if ($warnings.Count -eq 0) { $md.Add('- No PATH/collision warnings detected by the baseline checks.') }
else { foreach ($w in $warnings) { $md.Add("- ⚠ $w") } }
$md.Add('')
$md.Add('## Toolchain inventory')
$md.Add('')
$md.Add('| Tool | Installed | Version / result | First resolution |')
$md.Add('|---|:---:|---|---|')
foreach ($tool in $tools) {
    $first = if ($tool.Resolution.Count -gt 0) { $tool.Resolution[0].Source } else { '' }
    $version = if ($tool.VersionOutput) { $tool.VersionOutput } else { '' }
    $md.Add("| $(Convert-ToMarkdownSafe $tool.Label) | $(if($tool.Installed){'Yes'}else{'No'}) | $(Convert-ToMarkdownSafe $version) | $(Convert-ToMarkdownSafe $first) |")
}
$md.Add('')
$md.Add('## PATH health')
$md.Add('')
$md.Add('| Scope | Entries | Duplicates | Missing | Unresolved variables |')
$md.Add('|---|---:|---:|---:|---:|')
foreach ($health in @($report.PathHealth.Machine,$report.PathHealth.User,$report.PathHealth.Process)) {
    $md.Add("| $($health.Scope) | $($health.EntryCount) | $($health.DuplicateCount) | $($health.MissingCount) | $($health.UnresolvedVariableCount) |")
}
$md.Add('')
$md.Add('## Command collisions')
$md.Add('')
$md.Add('| Command | Distinct directories | Collision | Directories |')
$md.Add('|---|---:|:---:|---|')
foreach ($collision in $collisions) {
    $dirs = ($collision.Directories -join '<br>')
    $md.Add("| $($collision.Command) | $($collision.InstallationLocationCount) | $(if($collision.HasCollision){'⚠ Yes'}else{'No'}) | $(Convert-ToMarkdownSafe $dirs) |")
}
$md.Add('')
$md.Add('## Selected environment variables')
$md.Add('')
$md.Add('| Variable | User | Machine |')
$md.Add('|---|---|---|')
foreach ($item in $environment) {
    $md.Add("| $($item.Name) | $(Convert-ToMarkdownSafe $item.User) | $(Convert-ToMarkdownSafe $item.Machine) |")
}
$md.Add('')
$md.Add('## WinGet upgrades')
$md.Add('')
$md.Add('```text')
$md.Add($(if ($wingetUpgrade.Output) { $wingetUpgrade.Output } else { 'WinGet unavailable or no output.' }))
$md.Add('```')
$md.Add('')
$md.Add('## pnpm global outdated')
$md.Add('')
$md.Add('```text')
$md.Add($(if ($pnpmOutdated.Output) { $pnpmOutdated.Output } else { 'pnpm unavailable or no outdated global packages reported.' }))
$md.Add('```')
$md.Add('')
$md.Add('## Flutter doctor')
$md.Add('')
$md.Add('```text')
$md.Add($(if ($flutterDoctor.Output) { $flutterDoctor.Output } else { 'Flutter unavailable or no output.' }))
$md.Add('```')

$md -join "`r`n" | Set-Content -LiteralPath $mdPath -Encoding UTF8

Write-Host ''
Write-Host 'Audit complete.' -ForegroundColor Green
Write-Host "JSON: $jsonPath"
Write-Host "Markdown: $mdPath"
Write-Host ''
Write-Host "Warnings detected: $($warnings.Count)"
foreach ($w in $warnings) { Write-Host " - $w" -ForegroundColor Yellow }