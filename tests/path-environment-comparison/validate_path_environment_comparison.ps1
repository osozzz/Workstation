[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$corePath = Join-Path $root 'scripts\Core\Comparison.Core.psm1'

Import-Module $corePath -Force

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-SyntheticVersionIntelligence {
    return [pscustomobject][ordered]@{
        status        = 'not-applicable'
        latestStable  = $null
        latestLts     = $null
        latestCurrent = $null
        source        = $null
        checkedAt     = $null
        message       = $null
    }
}

function New-SyntheticPathEntry {
    param(
        [Parameter(Mandatory)][ValidateSet('machine','user','process')][string]$Scope,
        [Parameter(Mandatory)][int]$Position,
        [Parameter(Mandatory)][string]$PathKey,
        [AllowNull()][object]$Exists = $true,
        [bool]$Duplicate = $false,
        [AllowNull()][object]$FirstEquivalentPosition = $null,
        [bool]$Unresolved = $false
    )

    return [pscustomobject][ordered]@{
        scope                    = $Scope
        position                 = $Position
        entry                    = $PathKey
        original                 = $PathKey
        expanded                 = $PathKey
        normalized               = $PathKey
        comparisonKey            = $PathKey.ToLowerInvariant()
        exists                   = $Exists
        duplicate                = $Duplicate
        duplicateWithinScope     = $Duplicate
        firstEquivalentPosition  = $FirstEquivalentPosition
        hasUnresolvedVariable    = $Unresolved
        unresolvedVariables      = $(if ($Unresolved) { @('APPROVED_ROOT') } else { @() })
        unapprovedReferenceCount = 0
    }
}

function New-SyntheticPathHealthEvidence {
    param(
        [Parameter(Mandatory)][ValidateSet('machine','user','process')][string]$Scope,
        [Parameter(Mandatory)][object[]]$Entries
    )

    $entriesArray = @($Entries)
    return [pscustomobject][ordered]@{
        evidenceId = "path.$Scope.health"
        type       = 'path'
        source     = "$Scope PATH"
        exitCode   = $null
        captured   = $null
        redacted   = $false
        attributes = [pscustomobject][ordered]@{
            entryCount              = $entriesArray.Count
            duplicateCount          = @($entriesArray | Where-Object duplicateWithinScope).Count
            missingCount            = @($entriesArray | Where-Object { $_.exists -eq $false }).Count
            unresolvedVariableCount = @($entriesArray | Where-Object hasUnresolvedVariable).Count
            entries                 = $entriesArray
        }
    }
}

function New-SyntheticEnvironmentScope {
    param(
        [Parameter(Mandatory)][ValidateSet('process','user','machine')][string]$Scope,
        [AllowNull()][string]$PathKey,
        [ValidateSet('unset','empty','value')][string]$State = 'value',
        [AllowNull()][object]$Exists = $true
    )

    $configured = ($State -ne 'unset')
    $invalid = ($State -eq 'empty')
    $items = if ($State -eq 'value' -and -not [string]::IsNullOrWhiteSpace($PathKey)) {
        @(
            New-SyntheticPathEntry -Scope $Scope -Position 0 -PathKey $PathKey -Exists $Exists
        )
    }
    else {
        @()
    }

    return [pscustomobject][ordered]@{
        scope                    = $Scope
        state                    = $State
        raw                      = $(if ($State -eq 'unset') { $null } else { [string]$PathKey })
        expanded                 = $(if ($State -eq 'unset') { $null } else { [string]$PathKey })
        normalized               = $(if ($State -eq 'unset') { $null } else { [string]$PathKey })
        comparisonKey            = $(if ($State -eq 'value' -and -not [string]::IsNullOrWhiteSpace($PathKey)) { $PathKey.ToLowerInvariant() } else { $null })
        exists                   = $(if ($State -eq 'value') { $Exists } else { $null })
        pathItems                = $items
        missingPathCount         = @($items | Where-Object { $_.exists -eq $false }).Count
        hasUnresolvedVariable    = $false
        unresolvedVariables      = @()
        unapprovedReferenceCount = 0
        isConfigured             = $configured
        isInvalid                = $invalid
    }
}

function New-SyntheticEnvironmentEvidence {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ProcessPath
    )

    $process = New-SyntheticEnvironmentScope -Scope process -PathKey $ProcessPath
    $user = New-SyntheticEnvironmentScope -Scope user -PathKey $null -State unset -Exists $null
    $machine = New-SyntheticEnvironmentScope -Scope machine -PathKey $null -State unset -Exists $null

    return [pscustomobject][ordered]@{
        evidenceId = 'environment.' + $Name.ToLowerInvariant()
        type       = 'environment'
        source     = $Name
        exitCode   = $null
        captured   = $null
        redacted   = $false
        attributes = [pscustomobject][ordered]@{
            process                  = $ProcessPath
            user                     = $null
            machine                  = $null
            kind                     = 'path'
            filesystem               = $true
            configuredScopeCount     = 1
            valueScopeCount          = 1
            distinctValueCount       = 1
            scopeConflict            = $false
            emptyScopeCount          = 0
            invalidScopeCount        = 0
            missingPathCount         = 0
            unresolvedScopeCount     = 0
            unapprovedReferenceCount = 0
            scopes                   = @($process,$user,$machine)
        }
    }
}

function New-SyntheticAllowlistBoundary {
    param([string[]]$Names)

    return [pscustomobject][ordered]@{
        evidenceId = 'environment.allowlist.boundary'
        type       = 'derived'
        source     = 'Approved environment-variable allowlist'
        exitCode   = $null
        captured   = $null
        redacted   = $false
        attributes = [pscustomobject][ordered]@{
            approvedNames                = @($Names)
            inspectedCount               = @($Names).Count
            arbitraryEnumeration         = $false
            unapprovedReferenceExpansion = $false
        }
    }
}

function New-SyntheticCrossScopeEvidence {
    param(
        [object[]]$Duplicates = @()
    )

    return [pscustomobject][ordered]@{
        evidenceId = 'path.persistent.cross-scope-duplicates'
        type       = 'derived'
        source     = 'Machine/User PATH equivalence analysis'
        exitCode   = $null
        captured   = $null
        redacted   = $false
        attributes = [pscustomobject][ordered]@{
            duplicateCount       = @($Duplicates).Count
            duplicates           = @($Duplicates)
            processScopeExcluded = $true
        }
    }
}

function New-SyntheticPrecedenceResolution {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][int]$Precedence,
        [Parameter(Mandatory)][bool]$Active,
        [Parameter(Mandatory)][string]$PathKey,
        [Parameter(Mandatory)][int]$PathPosition
    )

    return [pscustomobject][ordered]@{
        command                = $Command
        path                   = "$PathKey\$Command.exe"
        commandType            = 'Application'
        precedence             = $Precedence
        active                 = $Active
        pathBased              = $true
        pathDirectory          = $PathKey
        pathComparisonKey      = $PathKey.ToLowerInvariant()
        pathMappingStatus      = 'mapped'
        pathPosition           = $PathPosition
        candidatePathPositions = @($PathPosition)
    }
}

function New-SyntheticPrecedenceEvidence {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][object[]]$Resolutions
    )

    $all = @($Resolutions)
    $active = @($all | Where-Object active | Select-Object -First 1)
    $shadowed = @($all | Where-Object { -not $_.active })

    return [pscustomobject][ordered]@{
        evidenceId = "path-precedence.command.$Command"
        type       = 'derived'
        source     = "command PATH precedence: $Command"
        exitCode   = $null
        captured   = $null
        redacted   = $false
        attributes = [pscustomobject][ordered]@{
            command                     = $Command
            resolutionCount             = $all.Count
            pathBasedResolutionCount    = $all.Count
            mappedResolutionCount       = $all.Count
            unmappedPathResolutionCount = 0
            hasResolutionCollision      = ($all.Count -gt 1)
            hasPathResolutionCollision  = ($all.Count -gt 1)
            hasPathOrderConflict        = ($all.Count -gt 1)
            fullyMapped                 = $true
            activeResolution            = $(if ($active.Count -gt 0) { $active[0] } else { $null })
            shadowedResolutions         = $shadowed
            resolutions                 = $all
            sources                     = @()
        }
    }
}

function New-SyntheticProvider {
    param(
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][ValidateSet('success','warning','partial','failed','unavailable','not-applicable')][string]$Status,
        [object[]]$Evidence = @()
    )

    return [pscustomobject][ordered]@{
        providerId = $ProviderId
        category   = $Category
        status     = $Status
        observedAt = '2026-09-24T00:00:00Z'
        components = @()
        warnings   = @()
        errors     = @()
        evidence   = @($Evidence)
    }
}

function New-SyntheticReport {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][object[]]$Providers
    )

    return [pscustomobject][ordered]@{
        schemaVersion = '1.0.0'
        generatedAt   = '2026-09-24T00:00:00Z'
        audit         = [pscustomobject][ordered]@{
            mode        = 'read-only'
            toolVersion = '0.7.0'
        }
        host = [pscustomobject][ordered]@{
            name         = $HostName
            platform     = 'windows'
            architecture = 'x64'
        }
        summary = [pscustomobject][ordered]@{
            status             = 'success'
            providerCount      = @($Providers).Count
            successCount       = 0
            warningCount       = 0
            partialCount       = 0
            failedCount        = 0
            unavailableCount   = 0
            notApplicableCount = 0
        }
        providers = @($Providers)
        warnings  = @()
        errors    = @()
    }
}

$referenceMachineEntries = @(
    (New-SyntheticPathEntry -Scope machine -Position 0 -PathKey 'C:\Tools'),
    (New-SyntheticPathEntry -Scope machine -Position 1 -PathKey 'C:\TOOLS' -Duplicate $true -FirstEquivalentPosition 0)
)
$targetMachineEntries = @(
    (New-SyntheticPathEntry -Scope machine -Position 0 -PathKey 'C:\Tools')
)

$referenceUserEntries = @(
    (New-SyntheticPathEntry -Scope user -Position 0 -PathKey 'C:\Missing' -Exists $false)
)
$targetUserEntries = @(
    (New-SyntheticPathEntry -Scope user -Position 0 -PathKey 'C:\Missing' -Exists $true)
)

$referenceProcessEntries = @(
    (New-SyntheticPathEntry -Scope process -Position 0 -PathKey 'C:\Primary'),
    (New-SyntheticPathEntry -Scope process -Position 1 -PathKey 'C:\Secondary')
)
$targetProcessEntries = @(
    (New-SyntheticPathEntry -Scope process -Position 0 -PathKey 'C:\Secondary'),
    (New-SyntheticPathEntry -Scope process -Position 1 -PathKey 'C:\Primary')
)

$crossDuplicate = [pscustomobject][ordered]@{
    comparisonKey = 'c:\tools'
    normalized    = 'C:\Tools'
    scopes        = @('machine','user')
    occurrences   = @(
        [pscustomobject][ordered]@{ scope='machine'; position=0; normalized='C:\Tools' },
        [pscustomobject][ordered]@{ scope='user'; position=0; normalized='C:\Tools' }
    )
}

$referenceEnvironmentEvidence = @(
    (New-SyntheticAllowlistBoundary -Names @('JAVA_HOME','PNPM_HOME')),
    (New-SyntheticEnvironmentEvidence -Name 'JAVA_HOME' -ProcessPath 'C:\Java\21'),
    (New-SyntheticEnvironmentEvidence -Name 'PNPM_HOME' -ProcessPath 'C:\Pnpm'),
    (New-SyntheticPathHealthEvidence -Scope machine -Entries $referenceMachineEntries),
    (New-SyntheticPathHealthEvidence -Scope user -Entries $referenceUserEntries),
    (New-SyntheticPathHealthEvidence -Scope process -Entries $referenceProcessEntries),
    (New-SyntheticCrossScopeEvidence -Duplicates @($crossDuplicate)),
    [pscustomobject][ordered]@{
        evidenceId='environment.secret_token'
        type='environment'
        source='SECRET_TOKEN'
        exitCode=$null
        captured=$null
        redacted=$false
        attributes=[pscustomobject][ordered]@{
            process='super-secret-reference'
            scopes=@()
        }
    }
)

$targetEnvironmentEvidence = @(
    (New-SyntheticAllowlistBoundary -Names @('JAVA_HOME','PNPM_HOME')),
    (New-SyntheticEnvironmentEvidence -Name 'JAVA_HOME' -ProcessPath 'C:\Java\22'),
    (New-SyntheticEnvironmentEvidence -Name 'PNPM_HOME' -ProcessPath 'C:\Pnpm'),
    (New-SyntheticPathHealthEvidence -Scope machine -Entries $targetMachineEntries),
    (New-SyntheticPathHealthEvidence -Scope user -Entries $targetUserEntries),
    (New-SyntheticPathHealthEvidence -Scope process -Entries $targetProcessEntries),
    (New-SyntheticCrossScopeEvidence -Duplicates @()),
    [pscustomobject][ordered]@{
        evidenceId='environment.secret_token'
        type='environment'
        source='SECRET_TOKEN'
        exitCode=$null
        captured=$null
        redacted=$false
        attributes=[pscustomobject][ordered]@{
            process='super-secret-target'
            scopes=@()
        }
    }
)

$referencePrecedenceEvidence = New-SyntheticPrecedenceEvidence -Command node -Resolutions @(
    (New-SyntheticPrecedenceResolution -Command node -Precedence 0 -Active $true -PathKey 'C:\Primary' -PathPosition 0),
    (New-SyntheticPrecedenceResolution -Command node -Precedence 1 -Active $false -PathKey 'C:\Secondary' -PathPosition 1)
)

$targetPrecedenceEvidence = New-SyntheticPrecedenceEvidence -Command node -Resolutions @(
    (New-SyntheticPrecedenceResolution -Command node -Precedence 0 -Active $true -PathKey 'C:\Secondary' -PathPosition 0),
    (New-SyntheticPrecedenceResolution -Command node -Precedence 1 -Active $false -PathKey 'C:\Primary' -PathPosition 1)
)

$referenceEnvironmentProvider = New-SyntheticProvider -ProviderId 'environment.baseline' -Category environment -Status warning -Evidence $referenceEnvironmentEvidence
$targetEnvironmentProvider = New-SyntheticProvider -ProviderId 'environment.baseline' -Category environment -Status warning -Evidence $targetEnvironmentEvidence

$referencePrecedenceProvider = New-SyntheticProvider -ProviderId 'path.precedence' -Category environment -Status partial -Evidence @($referencePrecedenceEvidence)
$targetPrecedenceProvider = New-SyntheticProvider -ProviderId 'path.precedence' -Category environment -Status partial -Evidence @($targetPrecedenceEvidence)

$referenceReport = New-SyntheticReport -HostName 'SYNTHETIC-REFERENCE' -Providers @(
    $referenceEnvironmentProvider,
    $referencePrecedenceProvider
)
$targetReport = New-SyntheticReport -HostName 'SYNTHETIC-TARGET' -Providers @(
    $targetEnvironmentProvider,
    $targetPrecedenceProvider
)

$comparison = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport

Assert-True ($comparison.schemaVersion -eq '1.1.0') 'PATH/environment comparison must preserve comparison schema 1.1.0.'

$machineDuplicates = @($comparison.differences | Where-Object {
    $_.category -eq 'path' -and $_.kind -eq 'duplicate-entries' -and $_.subjectId -eq 'machine'
})
Assert-True ($machineDuplicates.Count -eq 1) 'Machine duplicate PATH drift must be explicit.'

$userMissing = @($comparison.differences | Where-Object {
    $_.category -eq 'path' -and $_.kind -eq 'missing-entries' -and $_.subjectId -eq 'user'
})
Assert-True ($userMissing.Count -eq 1) 'Missing PATH drift must be explicit and separate from duplicate drift.'

$processOrder = @($comparison.differences | Where-Object {
    $_.category -eq 'path' -and $_.kind -eq 'scope-order' -and $_.subjectId -eq 'process'
})
Assert-True ($processOrder.Count -eq 1) 'Process PATH order drift must be explicit.'
Assert-True ($processOrder[0].referenceValue[0].pathKey -eq 'c:\primary') 'Reference Process PATH first entry mismatch.'
Assert-True ($processOrder[0].targetValue[0].pathKey -eq 'c:\secondary') 'Target Process PATH first entry mismatch.'

$crossScope = @($comparison.differences | Where-Object {
    $_.category -eq 'path' -and $_.kind -eq 'persistent-cross-scope-duplicates'
})
Assert-True ($crossScope.Count -eq 1) 'Persistent Machine/User duplicate drift must be explicit.'

$javaHome = @($comparison.differences | Where-Object {
    $_.category -eq 'environment' -and $_.kind -eq 'allowlisted-variable' -and $_.subjectId -eq 'java_home'
})
Assert-True ($javaHome.Count -eq 1) 'Allowlisted JAVA_HOME drift must be compared.'
Assert-True ($javaHome[0].referenceValue.scopes[0].pathKey -eq 'c:\java\21') 'Reference JAVA_HOME normalized path mismatch.'
Assert-True ($javaHome[0].targetValue.scopes[0].pathKey -eq 'c:\java\22') 'Target JAVA_HOME normalized path mismatch.'

$pnpmHome = @($comparison.differences | Where-Object {
    $_.category -eq 'environment' -and $_.subjectId -eq 'pnpm_home'
})
Assert-True ($pnpmHome.Count -eq 0) 'Equal allowlisted PNPM_HOME must not emit drift.'

$precedence = @($comparison.differences | Where-Object {
    $_.category -eq 'path' -and $_.kind -eq 'command-precedence'
})
Assert-True ($precedence.Count -eq 1) 'Effective command precedence drift must be surfaced.'
Assert-True ($precedence[0].referenceValue.activeResolution.pathKey -eq 'c:\primary') 'Reference active PATH precedence mismatch.'
Assert-True ($precedence[0].targetValue.activeResolution.pathKey -eq 'c:\secondary') 'Target active PATH precedence mismatch.'

$serialized = $comparison | ConvertTo-Json -Depth 40 -Compress
Assert-True ($serialized -notmatch 'secret_token') 'Unapproved environment evidence identifier leaked into comparison output.'
Assert-True ($serialized -notmatch 'super-secret') 'Unapproved environment evidence value leaked into comparison output.'

$repeat = New-WorkstationComparison -ReferenceReport $referenceReport -TargetReport $targetReport
Assert-True (
    ($comparison | ConvertTo-Json -Depth 40 -Compress) -eq
    ($repeat | ConvertTo-Json -Depth 40 -Compress)
) 'PATH/environment comparison output must be deterministic.'

$unavailableReference = New-SyntheticProvider -ProviderId 'path.precedence' -Category environment -Status unavailable -Evidence @()
$unavailableComparison = New-WorkstationComparison -ReferenceReport (
    New-SyntheticReport -HostName 'UNAVAILABLE-REFERENCE' -Providers @($referenceEnvironmentProvider,$unavailableReference)
) -TargetReport $targetReport

$unavailableProviderDifference = @($unavailableComparison.differences | Where-Object {
    $_.category -eq 'provider' -and $_.providerId -eq 'path.precedence'
})
Assert-True ($unavailableProviderDifference.Count -eq 1) 'Unavailable path.precedence provider must remain explicit.'
Assert-True ($unavailableProviderDifference[0].relation -eq 'unavailable') 'Unavailable provider relation must remain unavailable.'

$unavailableSpecialized = @($unavailableComparison.differences | Where-Object {
    $_.category -eq 'path' -and $_.providerId -eq 'path.precedence'
})
Assert-True ($unavailableSpecialized.Count -eq 0) 'Unavailable provider must not fabricate specialized PATH drift.'

$coreSource = Get-Content -LiteralPath $corePath -Raw

foreach ($requiredMarker in @(
    'environment.allowlist.boundary',
    'path.$scope.health',
    'path.persistent.cross-scope-duplicates',
    'path-precedence.command.*',
    'allowlisted-variable',
    'command-precedence',
    'duplicate-entries',
    'missing-entries'
)) {
    if ($coreSource -notmatch [Regex]::Escape($requiredMarker)) {
        throw "PATH/environment comparison core is missing required marker '$requiredMarker'."
    }
}

foreach ($forbiddenMarker in @(
    'GetEnvironmentVariables(',
    'Environment]::GetEnvironmentVariable',
    'SECRET_TOKEN',
    'connection string',
    'credential'
)) {
    if ($coreSource -match [Regex]::Escape($forbiddenMarker)) {
        throw "PATH/environment comparison core contains forbidden data-expansion marker '$forbiddenMarker'."
    }
}

Write-Host 'Normalized PATH and environment comparison validation passed.'
