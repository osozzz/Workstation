[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\WinGetUpgradeIntelligence.Core.psm1'
$providerPath = Join-Path $root 'scripts\Providers\WinGetBaseline.Provider.ps1'

Import-Module $corePath -Force

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-WinGetLine {
    param(
        [string]$Name,
        [string]$Id,
        [string]$Version,
        [string]$Available,
        [string]$Source
    )

    return ('{0,-28}{1,-28}{2,-14}{3,-14}{4}' -f $Name, $Id, $Version, $Available, $Source).TrimEnd()
}

$checkedAt = '2026-09-23T18:10:00.0000000+00:00'
$header = New-WinGetLine -Name 'Name' -Id 'Id' -Version 'Version' -Available 'Available' -Source 'Source'
$separator = '-' * $header.Length

$inventoryText = @(
    '',
    '   ',
    $header,
    $separator,
    (New-WinGetLine -Name 'Git' -Id 'Git.Git' -Version '2.53.0' -Available '2.54.0' -Source 'winget'),
    (New-WinGetLine -Name 'PowerShell' -Id 'Microsoft.PowerShell' -Version '7.5.2' -Available '' -Source 'winget'),
    (New-WinGetLine -Name 'Long App' -Id 'Vendor.ReallyLongPackage…' -Version '1.0.0' -Available '1.1.0' -Source 'winget')
) -join [Environment]::NewLine

$inventoryTable = ConvertFrom-WinGetTable -Text $inventoryText
$inventoryRecords = @(ConvertTo-WinGetPackageRecords -Table $inventoryTable -Mode inventory -CheckedAt $checkedAt)

Assert-True ($inventoryTable.tableFound -eq $true) 'Inventory table must be detected.'
Assert-True ($inventoryRecords.Count -eq 3) 'Inventory must preserve all synthetic installed applications.'
Assert-True ($inventoryRecords[0].packageId -eq 'Git.Git') 'Inventory package identity must be preserved.'
Assert-True ($inventoryRecords[0].installedVersion -eq '2.53.0') 'Installed version must be preserved.'
Assert-True ($inventoryRecords[0].availableVersion -eq '2.54.0') 'Available version from list output must be preserved where present.'
Assert-True ($inventoryRecords[0].source -eq 'winget') 'Package source must be preserved.'
Assert-True ($inventoryRecords[0].checkedAt -eq $checkedAt) 'Inventory checkedAt must be explicit.'
Assert-True ($inventoryRecords[2].identityReliable -eq $false) 'Truncated WinGet package IDs must be marked unreliable.'

$upgradeText = @(
    $header,
    $separator,
    (New-WinGetLine -Name 'Git' -Id 'Git.Git' -Version '2.53.0' -Available '2.54.0' -Source 'winget'),
    (New-WinGetLine -Name 'Long App' -Id 'Vendor.ReallyLongPackage…' -Version '1.0.0' -Available '1.1.0' -Source 'winget'),
    '',
    '2 upgrades available.'
) -join [Environment]::NewLine

$upgradeTable = ConvertFrom-WinGetTable -Text $upgradeText
$upgradeRecords = @(ConvertTo-WinGetPackageRecords -Table $upgradeTable -Mode upgrade -CheckedAt $checkedAt)
$upgradeState = Get-WinGetUpgradeLookupState -CommandStatus success -Output $upgradeText -Table $upgradeTable -UpgradeRecords $upgradeRecords

Assert-True ($upgradeRecords.Count -eq 2) 'Upgrade fixture must preserve two available upgrades.'
Assert-True ($upgradeState -eq 'upgrades-available') 'Upgrade fixture must classify as upgrades-available.'
Assert-True ($upgradeRecords[0].availableVersionReliable -eq $true) 'Available version reliability must be explicit.'
Assert-True ($upgradeRecords[1].identityReliable -eq $false) 'Truncated upgrade identities must not be treated as reliable.'

$currentText = 'No applicable upgrade found.'
$currentTable = ConvertFrom-WinGetTable -Text $currentText
$currentRecords = @(ConvertTo-WinGetPackageRecords -Table $currentTable -Mode upgrade -CheckedAt $checkedAt)
$currentState = Get-WinGetUpgradeLookupState -CommandStatus success -Output $currentText -Table $currentTable -UpgradeRecords $currentRecords

Assert-True ($currentState -eq 'current') 'No applicable upgrade must be distinguishable as current.'
Assert-True ($currentRecords.Count -eq 0) 'Current state must not fabricate upgrade records.'

$sourceUnavailableText = 'Failed when searching source: winget. Data required by the source is missing. 0x8a15000f'
$sourceUnavailableTable = ConvertFrom-WinGetTable -Text $sourceUnavailableText
$sourceUnavailableState = Get-WinGetUpgradeLookupState -CommandStatus 'non-zero' -Output $sourceUnavailableText -Table $sourceUnavailableTable -UpgradeRecords @()

Assert-True ($sourceUnavailableState -eq 'source-unavailable') 'Unavailable source must be distinct from fully current.'

$agreementText = 'The following source agreements must be accepted before using this source. Use --accept-source-agreements to continue.'
$agreementTable = ConvertFrom-WinGetTable -Text $agreementText
$agreementState = Get-WinGetUpgradeLookupState -CommandStatus 'non-zero' -Output $agreementText -Table $agreementTable -UpgradeRecords @()

Assert-True ($agreementState -eq 'agreement-required') 'Agreement-required output must be normalized explicitly.'

$failureText = 'Unexpected WinGet command failure.'
$failureTable = ConvertFrom-WinGetTable -Text $failureText
$failureState = Get-WinGetUpgradeLookupState -CommandStatus failed -Output $failureText -Table $failureTable -UpgradeRecords @()

Assert-True ($failureState -eq 'command-failed') 'Generic command failures must remain distinct from source failures.'

$spanishHeader = ('{0,-28}{1,-28}{2,-14}{3,-14}{4}' -f 'Nombre', 'Id', 'Versión', 'Disponible', 'Origen').TrimEnd()
$spanishText = @(
    $spanishHeader,
    ('-' * $spanishHeader.Length),
    (New-WinGetLine -Name 'Git' -Id 'Git.Git' -Version '2.53.0' -Available '2.54.0' -Source 'winget')
) -join [Environment]::NewLine

$spanishTable = ConvertFrom-WinGetTable -Text $spanishText
$spanishRecords = @(ConvertTo-WinGetPackageRecords -Table $spanishTable -Mode upgrade -CheckedAt $checkedAt)

Assert-True ($spanishTable.tableFound -eq $true) 'Localized Spanish WinGet headers must remain parseable.'
Assert-True ($spanishRecords.Count -eq 1) 'Localized table must preserve the upgrade record.'
Assert-True ($spanishRecords[0].packageId -eq 'Git.Git') 'Localized table must preserve package identity.'

$providerSource = Get-Content -LiteralPath $providerPath -Raw

foreach ($marker in @(
    'WinGetUpgradeIntelligence.Core.psm1',
    'winget list --disable-interactivity',
    'winget upgrade --disable-interactivity',
    'winget.inventory.normalized',
    'winget.upgrades.normalized',
    'WINGET_UPGRADE_AGREEMENT_REQUIRED',
    'WINGET_UPGRADE_SOURCE_UNAVAILABLE',
    'WINGET_UPGRADE_QUERY_FAILED',
    'reviewOnly'
)) {
    if ($providerSource -notmatch [Regex]::Escape($marker)) {
        throw "Missing WinGet provider marker: $marker"
    }
}

foreach ($forbidden in @(
    '--accept-source-agreements',
    '--accept-package-agreements',
    "'install'",
    "'uninstall'",
    "'repair'"
)) {
    if ($providerSource -match [Regex]::Escape($forbidden)) {
        throw "Forbidden WinGet mutation marker: $forbidden"
    }
}

if ($providerSource -match "(?is)'upgrade'\s*,[\s\S]{0,120}'--all'") {
    throw 'Forbidden WinGet bulk-upgrade mutation marker: --all'
}

Write-Host 'WinGet upgrade intelligence validation passed.'
