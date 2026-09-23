[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$auditCore = Join-Path $root 'scripts\Core\Audit.Core.psm1'
$versionCore = Join-Path $root 'scripts\Core\VersionIntelligence.Core.psm1'
$jsVersionCore = Join-Path $root 'scripts\Core\JavaScriptVersionIntelligence.Core.psm1'
$providerPath = Join-Path $root 'scripts\Providers\JavaScriptToolchain.Provider.ps1'

Import-Module $auditCore -Force
Import-Module $versionCore -Force
Import-Module $jsVersionCore -Force

function New-TestVersionRecord {
    param(
        [Parameter(Mandatory)][string]$Version,
        [AllowNull()][string]$Channel
    )

    [pscustomobject][ordered]@{
        raw = $Version
        normalized = $Version.TrimStart('v', 'V')
        channel = $Channel
    }
}

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-Decoded {
    param([string]$Source,[object]$Data,[string]$Status='known')
    [pscustomobject][ordered]@{
        status=$Status
        source=$Source
        checkedAt='2026-09-23T15:00:00.0000000+00:00'
        data=$(if($Status -eq 'known'){$Data}else{$null})
        message=$(if($Status -eq 'known'){$null}else{'synthetic unavailable'})
    }
}

$nodeData = @(
    [pscustomobject]@{version='v26.2.0';lts=$false},
    [pscustomobject]@{version='v24.12.0';lts='Krypton'},
    [pscustomobject]@{version='v24.11.0';lts='Krypton'},
    [pscustomobject]@{version='v23.9.0';lts=$false},
    [pscustomobject]@{version='v22.20.0';lts='Jod'}
)
$installedNode = New-TestVersionRecord -Version 'v24.10.0' -Channel lts
$node = Resolve-NodeVersionIntelligence -DecodedSource (New-Decoded -Source 'nodejs-release-index' -Data $nodeData) -InstalledVersion $installedNode

Assert-True ($node.intelligence.status -eq 'known') 'Node intelligence must be known.'
Assert-True ($node.latestLts.normalized -eq '24.12.0') 'Expected newest LTS release.'
Assert-True ($node.latestCurrent.normalized -eq '26.2.0') 'Expected newest Current release.'
Assert-True ($node.policyDefaultChannel -eq 'lts') 'Node policy default must remain LTS.'
Assert-True ($node.currentIsMandatoryReplacement -eq $false) 'Node Current must not be a mandatory replacement.'
Assert-True ($node.installedBehindLts -eq $true) 'Synthetic Node install should be behind LTS.'
Assert-True ($node.intelligence.message -match 'not a mandatory replacement') 'Node message must preserve LTS-default semantics.'

$currentNode = Resolve-NodeVersionIntelligence -DecodedSource (New-Decoded -Source 'nodejs-release-index' -Data $nodeData) -InstalledVersion (New-TestVersionRecord -Version '24.12.0' -Channel lts)
Assert-True ($currentNode.installedBehindLts -eq $false) 'Already-current LTS must not be reported behind LTS.'

$npm = Resolve-NpmPackageVersionIntelligence -PackageName npm -DecodedSource (New-Decoded -Source 'npm-registry:npm' -Data ([pscustomobject]@{version='11.20.0'})) -InstalledVersion (New-TestVersionRecord -Version '11.19.1' -Channel $null)
Assert-True ($npm.intelligence.latestStable.normalized -eq '11.20.0') 'Expected npm latest stable.'
Assert-True ($npm.updateAvailable -eq $true) 'Expected npm update available.'

$pnpm = Resolve-NpmPackageVersionIntelligence -PackageName pnpm -DecodedSource (New-Decoded -Source 'npm-registry:pnpm' -Data ([pscustomobject]@{version='12.4.2'})) -InstalledVersion (New-TestVersionRecord -Version '12.4.2' -Channel $null)
Assert-True ($pnpm.updateAvailable -eq $false) 'Already-current pnpm must not report an update.'

$offlineNode = Resolve-NodeVersionIntelligence -DecodedSource (New-Decoded -Source 'nodejs-release-index' -Data $null -Status unavailable) -InstalledVersion $installedNode
Assert-True ($offlineNode.intelligence.status -eq 'unavailable') 'Offline Node intelligence must be unavailable.'
Assert-True ($offlineNode.latestLts -eq $null) 'Offline Node intelligence must not fabricate LTS.'

$offlineNpm = Resolve-NpmPackageVersionIntelligence -PackageName npm -DecodedSource (New-Decoded -Source 'npm-registry:npm' -Data $null -Status unavailable) -InstalledVersion $npm.intelligence.latestStable
Assert-True ($offlineNpm.intelligence.status -eq 'unavailable') 'Offline npm intelligence must be unavailable.'

$transport = {
    param($request)
    switch ($request.source) {
        'nodejs-release-index' {
            return [pscustomobject]@{statusCode=200;contentType='application/json';body='[{"version":"v26.2.0","lts":false},{"version":"v24.12.0","lts":"Krypton"}]'}
        }
        'npm-registry:npm' {
            return [pscustomobject]@{statusCode=200;contentType='application/json';body='{"version":"11.20.0"}'}
        }
        'npm-registry:pnpm' {
            return [pscustomobject]@{statusCode=200;contentType='application/json';body='{"version":"12.4.2"}'}
        }
        default { throw "Unexpected source $($request.source)" }
    }
}

$context = [pscustomobject][ordered]@{
    ObservedAt='2026-09-23T15:00:00+00:00'
    EnvironmentVariableNames=@('NVM_HOME','NVM_SYMLINK','PNPM_HOME')
    VersionIntelligenceOffline=$false
    VersionIntelligenceTransport=$transport
    PreviousProviderResults=@()
}

$result = & $providerPath -Context $context
if ($result.status -eq 'failed') { throw 'JavaScript provider failed with synthetic version transport.' }

foreach ($id in @('node','npm','pnpm')) {
    $component = @($result.components | Where-Object componentId -eq $id | Select-Object -First 1)
    if ($component.Count -ne 1) { throw "Missing component $id." }
    if ($component[0].state -in @('present','partial') -and $component[0].versionIntelligence.status -notin @('known','unknown','unavailable')) {
        throw "$id must expose normalized version intelligence when installed."
    }
}

$offlineContext = $context | Select-Object *
$offlineContext.VersionIntelligenceOffline = $true
$offlineContext.VersionIntelligenceTransport = { param($request) throw 'Offline mode must not invoke transport.' }
$offlineResult = & $providerPath -Context $offlineContext
if ($offlineResult.status -eq 'failed') { throw 'JavaScript local detection must survive offline version intelligence.' }

foreach ($id in @('node','npm','pnpm')) {
    $component = @($offlineResult.components | Where-Object componentId -eq $id | Select-Object -First 1)
    if ($component.Count -eq 1 -and $component[0].state -in @('present','partial')) {
        if ($component[0].versionIntelligence.status -ne 'unavailable') {
            throw "$id must expose unavailable version intelligence in offline mode."
        }
    }
}

$source = Get-Content -LiteralPath $providerPath -Raw
foreach ($marker in @(
    'https://nodejs.org/dist/index.json',
    'https://registry.npmjs.org/npm/latest',
    'https://registry.npmjs.org/pnpm/latest',
    'currentIsMandatoryReplacement',
    'VersionIntelligenceOffline'
)) {
    if ($source -notmatch [Regex]::Escape($marker)) { throw "Missing provider marker: $marker" }
}

foreach ($forbidden in @(
    'nvm install',
    'nvm use',
    'npm install -g',
    'npm update -g',
    'pnpm add -g',
    'pnpm update -g',
    'corepack enable'
)) {
    if ($source -match [Regex]::Escape($forbidden)) { throw "Forbidden mutation marker: $forbidden" }
}

Write-Host 'Node npm pnpm version intelligence validation passed.'
