[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\github.sync.json"),
    [switch]$PlanOnly,
    [switch]$SkipOptionalSecurity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Warning $Message
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

function Invoke-GhRaw {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & gh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw ("gh " + ($Arguments -join " ") + " failed with exit code " + $exitCode + "." + [Environment]::NewLine + $text)
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $text
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Invoke-GhApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Endpoint,
        $Body,
        [switch]$AllowFailure
    )

    $args = @(
        "api",
        "--method", $Method,
        "-H", "Accept: application/vnd.github+json",
        "-H", "X-GitHub-Api-Version: $($script:Config.githubApiVersion)",
        $Endpoint
    )

    $tempFile = $null
    try {
        if ($null -ne $Body) {
            $tempFile = [System.IO.Path]::GetTempFileName()
            $json = $Body | ConvertTo-Json -Depth 50
            Write-Utf8NoBom -Path $tempFile -Content $json
            $args += @("--input", $tempFile)
        }

        return (Invoke-GhRaw -Arguments $args -AllowFailure:$AllowFailure)
    }
    finally {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-GhGraphQL {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)]$Variables,
        [switch]$AllowFailure
    )

    $payload = @{
        query     = $Query
        variables = $Variables
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-Utf8NoBom -Path $tempFile -Content ($payload | ConvertTo-Json -Depth 50)
        return (Invoke-GhRaw -Arguments @("api", "graphql", "--input", $tempFile) -AllowFailure:$AllowFailure)
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Convert-JsonOrNull {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    return $Text | ConvertFrom-Json
}

function Escape-PathSegment {
    param([string]$Value)
    return [System.Uri]::EscapeDataString($Value)
}

function Get-RepositorySlug {
    return "$($script:Config.repository.owner)/$($script:Config.repository.name)"
}

function Get-ProjectSnapshot {
    param([int]$Number)

    $query = @'
query($login: String!, $number: Int!) {
  user(login: $login) {
    projectV2(number: $number) {
      id
      number
      title
      shortDescription
      public
      repositories(first: 100) {
        nodes { nameWithOwner }
      }
      fields(first: 100) {
        nodes {
          __typename
          ... on ProjectV2Field {
            id
            name
            dataType
          }
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
              color
              description
            }
          }
        }
      }
      views(first: 100) {
        nodes {
          id
          number
          name
          layout
          filter
          groupByFields(first: 10) {
            nodes {
              __typename
              ... on ProjectV2Field { id name }
              ... on ProjectV2SingleSelectField { id name }
            }
          }
          verticalGroupByFields(first: 10) {
            nodes {
              __typename
              ... on ProjectV2Field { id name }
              ... on ProjectV2SingleSelectField { id name }
            }
          }
        }
      }
    }
  }
}
'@

    $response = Invoke-GhGraphQL -Query $query -Variables @{
        login  = $script:Config.repository.owner
        number = $Number
    }

    $data = Convert-JsonOrNull $response.Output
    return $data.data.user.projectV2
}

function Find-ProjectByTitle {
    $query = @'
query($login: String!) {
  user(login: $login) {
    projectsV2(first: 100) {
      nodes {
        id
        number
        title
        closed
        public
      }
    }
  }
}
'@

    $response = Invoke-GhGraphQL -Query $query -Variables @{
        login = $script:Config.repository.owner
    }

    $data = Convert-JsonOrNull $response.Output
    return @($data.data.user.projectsV2.nodes | Where-Object { $_.title -eq $script:Config.project.title }) | Select-Object -First 1
}

function Ensure-RepositorySettings {
    Write-Step "Repository metadata and merge settings"

    if ($PlanOnly) {
        Write-Info "Would sync repository description, topics, merge policy, branch update policy, and feature toggles."
        return
    }

    $body = @{
        description                  = $script:Config.repository.description
        homepage                     = $script:Config.repository.homepage
        has_issues                   = [bool]$script:Config.repository.settings.has_issues
        has_projects                 = [bool]$script:Config.repository.settings.has_projects
        has_wiki                     = [bool]$script:Config.repository.settings.has_wiki
        has_discussions              = [bool]$script:Config.repository.settings.has_discussions
        allow_squash_merge           = [bool]$script:Config.repository.settings.allow_squash_merge
        allow_merge_commit           = [bool]$script:Config.repository.settings.allow_merge_commit
        allow_rebase_merge           = [bool]$script:Config.repository.settings.allow_rebase_merge
        allow_auto_merge             = [bool]$script:Config.repository.settings.allow_auto_merge
        delete_branch_on_merge       = [bool]$script:Config.repository.settings.delete_branch_on_merge
        allow_update_branch          = [bool]$script:Config.repository.settings.allow_update_branch
        squash_merge_commit_title    = [string]$script:Config.repository.settings.squash_merge_commit_title
        squash_merge_commit_message  = [string]$script:Config.repository.settings.squash_merge_commit_message
    }

    Invoke-GhApi -Method PATCH -Endpoint "repos/$(Get-RepositorySlug)" -Body $body | Out-Null
    Write-Info "Repository settings synced."

    Invoke-GhApi -Method PUT -Endpoint "repos/$(Get-RepositorySlug)/topics" -Body @{
        names = @($script:Config.repository.topics)
    } | Out-Null
    Write-Info "Repository topics synced."
}

function Ensure-RepositorySecurity {
    Write-Step "Repository security settings"

    if ($SkipOptionalSecurity) {
        Write-Info "Optional security synchronization skipped."
        return
    }

    if ($PlanOnly) {
        Write-Info "Would enable private vulnerability reporting, vulnerability alerts, secret scanning, and push protection when available."
        return
    }

    if ($script:Config.repository.security.enablePrivateVulnerabilityReporting) {
        $result = Invoke-GhApi -Method PUT -Endpoint "repos/$(Get-RepositorySlug)/private-vulnerability-reporting" -Body $null -AllowFailure
        if ($result.ExitCode -ne 0) {
            Write-Warn "Private vulnerability reporting could not be enabled automatically: $($result.Output)"
        }
        else {
            Write-Info "Private vulnerability reporting enabled."
        }
    }

    if ($script:Config.repository.security.enableVulnerabilityAlerts) {
        $result = Invoke-GhApi -Method PUT -Endpoint "repos/$(Get-RepositorySlug)/vulnerability-alerts" -Body $null -AllowFailure
        if ($result.ExitCode -ne 0) {
            Write-Warn "Vulnerability alerts could not be enabled automatically: $($result.Output)"
        }
        else {
            Write-Info "Vulnerability alerts enabled."
        }
    }

    $securityBody = @{
        security_and_analysis = @{}
    }

    if ($script:Config.repository.security.enableSecretScanning) {
        $securityBody.security_and_analysis.secret_scanning = @{ status = "enabled" }
    }
    if ($script:Config.repository.security.enablePushProtection) {
        $securityBody.security_and_analysis.secret_scanning_push_protection = @{ status = "enabled" }
    }

    if ($securityBody.security_and_analysis.Count -gt 0) {
        $result = Invoke-GhApi -Method PATCH -Endpoint "repos/$(Get-RepositorySlug)" -Body $securityBody -AllowFailure
        if ($result.ExitCode -ne 0) {
            Write-Warn "Secret-scanning settings could not be synchronized automatically. This can depend on repository/account feature availability. $($result.Output)"
        }
        else {
            Write-Info "Secret scanning and push protection synchronized."
        }
    }
}

function Ensure-Labels {
    Write-Step "Repository labels"

    $existingResponse = Invoke-GhApi -Method GET -Endpoint "repos/$(Get-RepositorySlug)/labels?per_page=100" -Body $null
    $existing = @(Convert-JsonOrNull $existingResponse.Output)

    foreach ($label in $script:Config.labels) {
        $current = @($existing | Where-Object { $_.name -eq $label.name }) | Select-Object -First 1

        if ($PlanOnly) {
            Write-Info "Would ensure label '$($label.name)'."
            continue
        }

        if ($null -eq $current) {
            Invoke-GhApi -Method POST -Endpoint "repos/$(Get-RepositorySlug)/labels" -Body @{
                name        = [string]$label.name
                color       = [string]$label.color
                description = [string]$label.description
            } | Out-Null
            Write-Info "Created label '$($label.name)'."
        }
        elseif (($current.color -ne $label.color) -or ($current.description -ne $label.description)) {
            $encoded = Escape-PathSegment $label.name
            Invoke-GhApi -Method PATCH -Endpoint "repos/$(Get-RepositorySlug)/labels/$encoded" -Body @{
                new_name    = [string]$label.name
                color       = [string]$label.color
                description = [string]$label.description
            } | Out-Null
            Write-Info "Updated label '$($label.name)'."
        }
        else {
            Write-Info "Label '$($label.name)' already matches."
        }
    }
}

function Ensure-Milestones {
    Write-Step "Release milestones"

    $response = Invoke-GhApi -Method GET -Endpoint "repos/$(Get-RepositorySlug)/milestones?state=all&per_page=100" -Body $null
    $existing = @(Convert-JsonOrNull $response.Output)

    foreach ($milestone in $script:Config.milestones) {
        $current = @($existing | Where-Object { $_.title -eq $milestone.title }) | Select-Object -First 1

        if ($PlanOnly) {
            Write-Info "Would ensure milestone '$($milestone.title)'."
            continue
        }

        if ($null -eq $current) {
            Invoke-GhApi -Method POST -Endpoint "repos/$(Get-RepositorySlug)/milestones" -Body @{
                title       = [string]$milestone.title
                state       = "open"
                description = [string]$milestone.description
            } | Out-Null
            Write-Info "Created milestone '$($milestone.title)'."
        }
        elseif (($current.description -ne $milestone.description) -or ($current.state -ne "open")) {
            Invoke-GhApi -Method PATCH -Endpoint "repos/$(Get-RepositorySlug)/milestones/$($current.number)" -Body @{
                title       = [string]$milestone.title
                state       = "open"
                description = [string]$milestone.description
            } | Out-Null
            Write-Info "Updated milestone '$($milestone.title)'."
        }
        else {
            Write-Info "Milestone '$($milestone.title)' already matches."
        }
    }
}

function Update-SingleSelectField {
    param(
        [Parameter(Mandatory = $true)]$CurrentField,
        [Parameter(Mandatory = $true)]$DesiredField
    )

    $options = @()
    foreach ($desiredOption in $DesiredField.options) {
        $existingOption = @($CurrentField.options | Where-Object { $_.name -eq $desiredOption.name }) | Select-Object -First 1

        $option = @{
            name        = [string]$desiredOption.name
            color       = [string]$desiredOption.color
            description = [string]$desiredOption.description
        }

        if ($null -ne $existingOption) {
            $option.id = [string]$existingOption.id
        }

        $options += $option
    }

    $mutation = @'
mutation($input: UpdateProjectV2FieldInput!) {
  updateProjectV2Field(input: $input) {
    projectV2Field {
      ... on ProjectV2SingleSelectField {
        id
        name
      }
    }
  }
}
'@

    Invoke-GhGraphQL -Query $mutation -Variables @{
        input = @{
            fieldId             = [string]$CurrentField.id
            singleSelectOptions = $options
        }
    } | Out-Null
}

function Create-SingleSelectField {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)]$DesiredField
    )

    $mutation = @'
mutation($input: CreateProjectV2FieldInput!) {
  createProjectV2Field(input: $input) {
    projectV2Field {
      ... on ProjectV2SingleSelectField {
        id
        name
      }
    }
  }
}
'@

    $options = @()
    foreach ($option in $DesiredField.options) {
        $options += @{
            name        = [string]$option.name
            color       = [string]$option.color
            description = [string]$option.description
        }
    }

    Invoke-GhGraphQL -Query $mutation -Variables @{
        input = @{
            projectId           = $ProjectId
            dataType            = "SINGLE_SELECT"
            name                = [string]$DesiredField.name
            singleSelectOptions = $options
        }
    } | Out-Null
}

function Ensure-Project {
    Write-Step "GitHub Project and planning fields"

    if ($PlanOnly) {
        Write-Info "Would ensure project '$($script:Config.project.title)', fields, views, repository link, and issue field values."
        return $null
    }

    $project = Find-ProjectByTitle

    if ($null -eq $project) {
        Invoke-GhRaw -Arguments @(
            "project", "create",
            "--owner", $script:Config.repository.owner,
            "--title", $script:Config.project.title,
            "--format", "json"
        ) | Out-Null
        Write-Info "Created project '$($script:Config.project.title)'."

        $project = Find-ProjectByTitle
        if ($null -eq $project) {
            throw "Project was created but could not be reloaded."
        }
    }
    else {
        Write-Info "Project '$($script:Config.project.title)' already exists."
    }

    Invoke-GhRaw -Arguments @(
        "project", "edit", "$($project.number)",
        "--owner", $script:Config.repository.owner,
        "--title", $script:Config.project.title,
        "--description", $script:Config.project.description,
        "--visibility", $script:Config.project.visibility
    ) | Out-Null

    $snapshot = Get-ProjectSnapshot -Number $project.number
    $repoSlug = Get-RepositorySlug
    $linked = @($snapshot.repositories.nodes | Where-Object { $_.nameWithOwner -eq $repoSlug }).Count -gt 0

    if (-not $linked) {
        Invoke-GhRaw -Arguments @(
            "project", "link", "$($project.number)",
            "--owner", $script:Config.repository.owner,
            "--repo", $repoSlug
        ) | Out-Null
        Write-Info "Linked project to $repoSlug."
    }

    $snapshot = Get-ProjectSnapshot -Number $project.number

    foreach ($desiredField in $script:Config.project.fields) {
        $currentField = @($snapshot.fields.nodes | Where-Object { $_.name -eq $desiredField.name }) | Select-Object -First 1

        if ($null -eq $currentField) {
            $isBuiltIn = ($desiredField.PSObject.Properties.Name -contains "builtIn") -and [bool]$desiredField.builtIn
            if ($isBuiltIn) {
                throw "Expected built-in project field '$($desiredField.name)' was not found."
            }

            Create-SingleSelectField -ProjectId $snapshot.id -DesiredField $desiredField
            Write-Info "Created project field '$($desiredField.name)'."
            $snapshot = Get-ProjectSnapshot -Number $project.number
            $currentField = @($snapshot.fields.nodes | Where-Object { $_.name -eq $desiredField.name }) | Select-Object -First 1
        }

        if ($currentField.__typename -ne "ProjectV2SingleSelectField") {
            throw "Project field '$($desiredField.name)' is not SINGLE_SELECT."
        }

        Update-SingleSelectField -CurrentField $currentField -DesiredField $desiredField
        Write-Info "Synchronized project field '$($desiredField.name)'."
    }

    Ensure-ProjectViews -ProjectNumber $project.number
    return (Find-ProjectByTitle)
}

function Ensure-ProjectViews {
    param([Parameter(Mandatory = $true)][int]$ProjectNumber)

    Write-Step "GitHub Project views"

    $userResponse = Invoke-GhApi -Method GET -Endpoint "users/$($script:Config.repository.owner)" -Body $null
    $user = Convert-JsonOrNull $userResponse.Output
    $projectSnapshot = Get-ProjectSnapshot -Number $ProjectNumber

    $fieldResponse = Invoke-GhApi -Method GET -Endpoint "users/$($script:Config.repository.owner)/projectsV2/$ProjectNumber/fields" -Body $null
    $restFields = @(Convert-JsonOrNull $fieldResponse.Output)

    foreach ($desiredView in $script:Config.project.views) {
        $existing = @($projectSnapshot.views.nodes | Where-Object { $_.name -eq $desiredView.name }) | Select-Object -First 1

        $groupByName = $null
        if ($desiredView.PSObject.Properties.Name -contains "groupBy") {
            $groupByName = [string]$desiredView.groupBy
        }

        $verticalGroupByName = $null
        if ($desiredView.PSObject.Properties.Name -contains "verticalGroupBy") {
            $verticalGroupByName = [string]$desiredView.verticalGroupBy
        }

        $existingGroup = @()
        $existingVertical = @()
        if ($null -ne $existing) {
            $existingGroup = @($existing.groupByFields.nodes | Select-Object -ExpandProperty name -ErrorAction SilentlyContinue)
            $existingVertical = @($existing.verticalGroupByFields.nodes | Select-Object -ExpandProperty name -ErrorAction SilentlyContinue)
        }

        $groupDrift = $false
        if ($groupByName) {
            $groupDrift = -not ($existingGroup -contains $groupByName)
        }
        elseif ($existingGroup.Count -gt 0) {
            $groupDrift = $true
        }

        $verticalDrift = $false
        if ($verticalGroupByName) {
            $verticalDrift = -not ($existingVertical -contains $verticalGroupByName)
        }
        elseif ($existingVertical.Count -gt 0) {
            $verticalDrift = $true
        }

        if ($null -ne $existing -and ($groupDrift -or $verticalDrift)) {
            $deleteMutation = @'
mutation($input: DeleteProjectV2ViewInput!) {
  deleteProjectV2View(input: $input) {
    projectV2View { id }
  }
}
'@
            Invoke-GhGraphQL -Query $deleteMutation -Variables @{
                input = @{ viewId = [string]$existing.id }
            } | Out-Null
            Write-Info "Recreating view '$($desiredView.name)' to enforce grouping."
            $existing = $null
        }

        if ($null -eq $existing) {
            $body = @{
                name   = [string]$desiredView.name
                layout = [string]$desiredView.layout
                filter = [string]$desiredView.filter
            }

            if ($groupByName) {
                $field = @($restFields | Where-Object { $_.name -eq $groupByName }) | Select-Object -First 1
                if ($null -eq $field) {
                    throw "Cannot create view '$($desiredView.name)': group field '$groupByName' was not found."
                }
                $body.group_by = @([int64]$field.id)
            }

            if ($verticalGroupByName) {
                $field = @($restFields | Where-Object { $_.name -eq $verticalGroupByName }) | Select-Object -First 1
                if ($null -eq $field) {
                    throw "Cannot create view '$($desiredView.name)': vertical group field '$verticalGroupByName' was not found."
                }
                $body.vertical_group_by = @([int64]$field.id)
            }

            Invoke-GhApi -Method POST -Endpoint "users/$($user.id)/projectsV2/$ProjectNumber/views" -Body $body | Out-Null
            Write-Info "Created project view '$($desiredView.name)'."
        }
        else {
            $updateMutation = @'
mutation($input: UpdateProjectV2ViewInput!) {
  updateProjectV2View(input: $input) {
    projectV2View { id name }
  }
}
'@
            Invoke-GhGraphQL -Query $updateMutation -Variables @{
                input = @{
                    viewId = [string]$existing.id
                    name   = [string]$desiredView.name
                    layout = ([string]$desiredView.layout).ToUpperInvariant()
                    filter = [string]$desiredView.filter
                }
            } | Out-Null
            Write-Info "Updated project view '$($desiredView.name)'."
        }

        $projectSnapshot = Get-ProjectSnapshot -Number $ProjectNumber
    }
}

function Ensure-IssueMetadata {
    param([Parameter(Mandatory = $true)][int]$ProjectNumber)

    Write-Step "Issue labels, milestones, project membership, and project fields"

    foreach ($issue in $script:Config.issues) {
        $issueNumber = [int]$issue.number
        $issueUrl = "https://github.com/$(Get-RepositorySlug)/issues/$issueNumber"

        $args = @(
            "issue", "edit", "$issueNumber",
            "--repo", (Get-RepositorySlug),
            "--add-assignee", $script:Config.repository.owner,
            "--milestone", [string]$issue.milestone
        )

        if (@($issue.labels).Count -gt 0) {
            $args += @("--add-label", (@($issue.labels) -join ","))
        }

        Invoke-GhRaw -Arguments $args | Out-Null

        $addResult = Invoke-GhRaw -Arguments @(
            "project", "item-add", "$ProjectNumber",
            "--owner", $script:Config.repository.owner,
            "--url", $issueUrl,
            "--format", "json"
        ) -AllowFailure

        if ($addResult.ExitCode -ne 0 -and $addResult.Output -notmatch "already") {
            throw "Could not add issue #$issueNumber to project: $($addResult.Output)"
        }

        $fieldValues = @{
            Status   = [string]$issue.status
            Priority = [string]$issue.priority
            Area     = [string]$issue.area
            Risk     = [string]$issue.risk
        }

        foreach ($fieldName in $fieldValues.Keys) {
            Invoke-GhRaw -Arguments @(
                "project", "item-edit", "$ProjectNumber",
                "--owner", $script:Config.repository.owner,
                "--url", $issueUrl,
                "--field", $fieldName,
                "--value", $fieldValues[$fieldName]
            ) | Out-Null
        }

        Write-Info "Issue #$issueNumber metadata synchronized."
    }
}

function Ensure-IssueRelationships {
    Write-Step "Native parent/sub-issue and blocking relationships"

    $parentIssue = [int]$script:Config.relationships.parentIssue

    foreach ($childNumber in @($script:Config.relationships.subIssues)) {
        $view = Invoke-GhRaw -Arguments @(
            "issue", "view", "$childNumber",
            "--repo", (Get-RepositorySlug),
            "--json", "parent"
        )
        $json = Convert-JsonOrNull $view.Output
        $currentParent = $null
        if ($null -ne $json.parent) {
            $currentParent = $json.parent.number
        }

        if ($currentParent -ne $parentIssue) {
            Invoke-GhRaw -Arguments @(
                "issue", "edit", "$childNumber",
                "--repo", (Get-RepositorySlug),
                "--parent", "$parentIssue"
            ) | Out-Null
            Write-Info "Set #$parentIssue as parent of #$childNumber."
        }
    }

    foreach ($issue in $script:Config.issues) {
        if (-not ($issue.PSObject.Properties.Name -contains "blockedBy")) {
            continue
        }

        $issueNumber = [int]$issue.number
        $view = Invoke-GhRaw -Arguments @(
            "issue", "view", "$issueNumber",
            "--repo", (Get-RepositorySlug),
            "--json", "blockedBy"
        )
        $json = Convert-JsonOrNull $view.Output
        $existing = @($json.blockedBy | Select-Object -ExpandProperty number -ErrorAction SilentlyContinue)

        foreach ($dependency in @($issue.blockedBy)) {
            if (-not ($existing -contains [int]$dependency)) {
                Invoke-GhRaw -Arguments @(
                    "issue", "edit", "$issueNumber",
                    "--repo", (Get-RepositorySlug),
                    "--add-blocked-by", "$dependency"
                ) | Out-Null
                Write-Info "Added blocked-by relationship: #$issueNumber <- #$dependency."
            }
        }
    }
}

function Ensure-Ruleset {
    Write-Step "main branch ruleset"

    if ($PlanOnly) {
        Write-Info "Would ensure active main ruleset with PR-only squash workflow, linear history, required validate check, no force-push, and no deletion."
        return
    }

    $response = Invoke-GhApi -Method GET -Endpoint "repos/$(Get-RepositorySlug)/rulesets" -Body $null
    $rulesets = @(Convert-JsonOrNull $response.Output)
    $current = @($rulesets | Where-Object { $_.name -eq $script:Config.ruleset.name }) | Select-Object -First 1

    $body = @{
        name        = [string]$script:Config.ruleset.name
        target      = [string]$script:Config.ruleset.target
        enforcement = [string]$script:Config.ruleset.enforcement
        conditions  = $script:Config.ruleset.conditions
        rules       = @($script:Config.ruleset.rules)
    }

    if ($null -eq $current) {
        Invoke-GhApi -Method POST -Endpoint "repos/$(Get-RepositorySlug)/rulesets" -Body $body | Out-Null
        Write-Info "Created ruleset '$($script:Config.ruleset.name)'."
    }
    else {
        Invoke-GhApi -Method PUT -Endpoint "repos/$(Get-RepositorySlug)/rulesets/$($current.id)" -Body $body | Out-Null
        Write-Info "Updated ruleset '$($script:Config.ruleset.name)'."
    }
}

function Remove-MergedBranches {
    Write-Step "Merged branch cleanup"

    foreach ($branch in @($script:Config.repository.mergedBranchesToDelete)) {
        if ($PlanOnly) {
            Write-Info "Would remove merged branch '$branch' if a merged PR exists."
            continue
        }

        $encodedBranch = Escape-PathSegment $branch
        $branchCheck = Invoke-GhRaw -Arguments @(
            "api", "repos/$(Get-RepositorySlug)/branches/$encodedBranch"
        ) -AllowFailure

        if ($branchCheck.ExitCode -ne 0) {
            Write-Info "Branch '$branch' is already absent."
            continue
        }

        $prResult = Invoke-GhRaw -Arguments @(
            "pr", "list",
            "--repo", (Get-RepositorySlug),
            "--head", $branch,
            "--state", "merged",
            "--limit", "1",
            "--json", "number"
        )

        $prs = @(Convert-JsonOrNull $prResult.Output)
        if ($prs.Count -eq 0) {
            Write-Warn "Branch '$branch' exists but no merged PR was found. It was not deleted."
            continue
        }

        $deleteResult = Invoke-GhApi -Method DELETE -Endpoint "repos/$(Get-RepositorySlug)/git/refs/heads/$encodedBranch" -Body $null -AllowFailure
        if ($deleteResult.ExitCode -ne 0) {
            Write-Warn "Could not delete merged branch '$branch': $($deleteResult.Output)"
        }
        else {
            Write-Info "Deleted merged branch '$branch'."
        }
    }
}

function Test-Preconditions {
    Write-Step "Preflight"

    Assert-Command "gh"

    $configResolved = Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop
    $script:Config = Get-Content -LiteralPath $configResolved -Raw | ConvertFrom-Json

    $repoSlug = Get-RepositorySlug

    $auth = Invoke-GhRaw -Arguments @("auth", "status", "--hostname", "github.com") -AllowFailure
    if ($auth.ExitCode -ne 0) {
        throw "GitHub CLI is not authenticated. Run: gh auth login"
    }

    $viewer = Invoke-GhRaw -Arguments @(
        "repo", "view", $repoSlug,
        "--json", "viewerCanAdminister",
        "--jq", ".viewerCanAdminister"
    )
    if ($viewer.Output.Trim().ToLowerInvariant() -ne "true") {
        throw "The authenticated GitHub user is not an administrator of $repoSlug."
    }

    $issueHelp = Invoke-GhRaw -Arguments @("issue", "edit", "--help")
    if ($issueHelp.Output -notmatch "--parent" -or $issueHelp.Output -notmatch "--add-blocked-by") {
        throw "The installed GitHub CLI is too old for native issue relationships. Update gh and rerun."
    }

    $projectProbe = Invoke-GhRaw -Arguments @(
        "project", "list",
        "--owner", $script:Config.repository.owner,
        "--limit", "1",
        "--format", "json"
    ) -AllowFailure

    if ($projectProbe.ExitCode -ne 0) {
        throw ("GitHub Project access is unavailable. Run 'gh auth refresh -s project' and rerun." + [Environment]::NewLine + $projectProbe.Output)
    }

    Write-Info "Authenticated admin access confirmed for $repoSlug."
}

Test-Preconditions

if ($PlanOnly) {
    Write-Step "Plan"
    Write-Info "Plan-only mode: no GitHub state will be changed."
}

Ensure-RepositorySettings
Ensure-RepositorySecurity
Ensure-Labels
Ensure-Milestones

$project = Ensure-Project
if (-not $PlanOnly) {
    Ensure-IssueMetadata -ProjectNumber ([int]$project.number)
    Ensure-IssueRelationships
}

Ensure-Ruleset
Remove-MergedBranches

Write-Step "Complete"
if ($PlanOnly) {
    Write-Info "Plan generated successfully."
}
else {
    Write-Info "GitHub repository state synchronized successfully."
}
