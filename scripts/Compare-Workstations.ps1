[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Reference,
    [Parameter(Mandatory)][string]$Target
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ref = Get-Content -LiteralPath $Reference -Raw | ConvertFrom-Json
$tar = Get-Content -LiteralPath $Target -Raw | ConvertFrom-Json

function ToolMap($report) {
    $map = @{}
    foreach ($tool in $report.Tools) { $map[$tool.Label] = $tool }
    return $map
}

$refTools = ToolMap $ref
$tarTools = ToolMap $tar
$labels = @($refTools.Keys + $tarTools.Keys | Sort-Object -Unique)

Write-Host "Reference: $($ref.Computer.Name)  [$($ref.GeneratedAt)]" -ForegroundColor Cyan
Write-Host "Target:    $($tar.Computer.Name)  [$($tar.GeneratedAt)]" -ForegroundColor Cyan
Write-Host ''

$rows = foreach ($label in $labels) {
    $a = $refTools[$label]
    $b = $tarTools[$label]
    $aVersion = if ($a) { $a.VersionOutput } else { $null }
    $bVersion = if ($b) { $b.VersionOutput } else { $null }
    [pscustomobject]@{
        Tool = $label
        ReferenceInstalled = if ($a) { $a.Installed } else { $false }
        TargetInstalled = if ($b) { $b.Installed } else { $false }
        SameVersionOutput = ($aVersion -eq $bVersion)
        ReferenceVersion = $aVersion
        TargetVersion = $bVersion
    }
}

$rows | Format-Table Tool,ReferenceInstalled,TargetInstalled,SameVersionOutput -AutoSize

Write-Host ''
Write-Host 'Differences:' -ForegroundColor Yellow
$diffs = @($rows | Where-Object { -not $_.SameVersionOutput -or $_.ReferenceInstalled -ne $_.TargetInstalled })
if ($diffs.Count -eq 0) {
    Write-Host 'No tool-version differences found.' -ForegroundColor Green
} else {
    foreach ($d in $diffs) {
        Write-Host "`n[$($d.Tool)]" -ForegroundColor Yellow
        Write-Host "  Reference: $($d.ReferenceVersion)"
        Write-Host "  Target:    $($d.TargetVersion)"
    }
}

Write-Host ''
Write-Host 'PATH health:' -ForegroundColor Yellow
foreach ($scope in @('Machine','User','Process')) {
    $r = $ref.PathHealth.$scope
    $t = $tar.PathHealth.$scope
    Write-Host ("{0,-8} Reference dup/missing: {1}/{2} | Target: {3}/{4}" -f $scope,$r.DuplicateCount,$r.MissingCount,$t.DuplicateCount,$t.MissingCount)
}
