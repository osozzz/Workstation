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
        providerId = 'windows.update'
        category   = 'host'
        order      = 12
    }
}

Import-Module (Join-Path $PSScriptRoot '..\Core\Audit.Core.psm1') -Force

$warnings = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]
$offlineProperty = $Context.PSObject.Properties['VersionIntelligenceOffline']
$offline = $null -ne $offlineProperty -and [bool]$offlineProperty.Value

# Tests replace the search with a scriptblock returning update records.
$searchProperty = $Context.PSObject.Properties['WindowsUpdateSearch']
$search = if ($null -ne $searchProperty -and $searchProperty.Value -is [scriptblock]) { [scriptblock]$searchProperty.Value } else {
    {
        param([bool]$Online)
        # Read-only: the Windows Update Agent searches for applicable updates and installs nothing.
        # It runs in a job so a slow Windows Update service cannot hang the audit.
        $job = Start-Job -ArgumentList $Online -ScriptBlock {
            param($Online)
            $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            $searcher.Online = $Online
            $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
            for ($i = 0; $i -lt $result.Updates.Count; $i++) {
                $update = $result.Updates.Item($i)
                [pscustomobject]@{
                    updateId      = [string]$update.Identity.UpdateID
                    title         = [string]$update.Title
                    kb            = @($update.KBArticleIDs | ForEach-Object { [string]$_ })
                    type          = $(if ($update.Type -eq 2) { 'driver' } else { 'software' })
                    isMandatory   = [bool]$update.IsMandatory
                    mayReboot     = ([int]$update.InstallationBehavior.RebootBehavior -ne 0)
                    categories    = @(for ($c = 0; $c -lt $update.Categories.Count; $c++) { [string]$update.Categories.Item($c).Name })
                }
            }
        }
        try {
            if (-not (Wait-Job -Job $job -Timeout 300)) { throw 'The Windows Update search did not finish within 300 seconds.' }
            return @(Receive-Job -Job $job -ErrorAction Stop)
        }
        finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

$updates = @()
$searchStatus = 'known'
$searchMessage = $null
try {
    $updates = @(& $search (-not $offline) | Where-Object { $null -ne $_ })
}
catch {
    $searchStatus = 'unavailable'
    $searchMessage = $_.Exception.Message
    $warnings.Add((New-AuditIssue -Code 'WINDOWS_UPDATE_SEARCH_FAILED' -Message "The Windows Update search did not complete: $searchMessage" -Severity warning -ComponentId 'windows-update' -EvidenceIds @('windows.update.pending')))
}

$evidence.Add((New-AuditEvidence -EvidenceId 'windows.update.pending' -Type derived -Source 'Windows Update Agent search (IsInstalled=0 and IsHidden=0)' -Captured $null -Attributes @{
    status      = $searchStatus
    online      = -not $offline
    message     = $searchMessage
    updateCount = $updates.Count
    updates     = @($updates | ForEach-Object {
            [pscustomobject][ordered]@{
                updateId    = [string]$_.updateId
                title       = [string]$_.title
                kb          = @($_.kb)
                type        = [string]$_.type
                isMandatory = [bool]$_.isMandatory
                mayReboot   = [bool]$_.mayReboot
                categories  = @($_.categories)
            }
        })
    reviewOnly  = $true
}))

$component = [pscustomobject][ordered]@{
    componentId         = 'windows-update'
    name                = 'Windows Update'
    state               = $(if ($searchStatus -eq 'known') { 'present' } else { 'partial' })
    installed           = $true
    activeVersion       = $null
    discoveredVersions  = @()
    installations       = @()
    commandResolutions  = @()
    versionIntelligence = [pscustomobject][ordered]@{ status = 'not-applicable'; latestStable = $null; latestLts = $null; latestCurrent = $null; source = $null; checkedAt = $null; message = $null }
}

return [pscustomobject][ordered]@{
    providerId = 'windows.update'
    category   = 'host'
    status     = Get-AuditProviderStatus -Warnings $warnings.ToArray() -Errors $errors.ToArray() -Partial:($searchStatus -ne 'known')
    observedAt = $Context.ObservedAt
    components = @($component)
    warnings   = $warnings.ToArray()
    errors     = $errors.ToArray()
    evidence   = $evidence.ToArray()
}
