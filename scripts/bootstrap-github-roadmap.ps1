#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstraps the CareerOps GitHub roadmap: labels, milestones, tracker issues,
    and implementation issues, idempotently, from the repository documentation.

.DESCRIPTION
    Dry-run by default. Pass -Apply to mutate GitHub. Existing records are
    detected via the hidden <!-- careerops-roadmap-id: MXX-YY --> marker
    (primary) and exact title (secondary) and are skipped unless
    -UpdateExisting is passed. Never closes or deletes issues.

    Preflight validation runs before any mutation and stops the script on
    duplicate roadmap IDs, duplicate titles, unknown labels or milestones,
    missing dependencies or parents, dependency cycles, or an active milestone
    depending on a later milestone.

.NOTES
    Source-of-truth: docs/planning/ROADMAP.md (delivery sequencing authority).
    Requires: GitHub CLI (gh) authenticated with repo scope. Nothing else.

.EXAMPLE
    gh auth status

    # Preview only
    .\scripts\bootstrap-github-roadmap.ps1 -Repo "Moonchichiii/careerops"

    # Create labels, milestones and issues
    .\scripts\bootstrap-github-roadmap.ps1 -Repo "Moonchichiii/careerops" -Apply

    # Reconcile existing roadmap records
    .\scripts\bootstrap-github-roadmap.ps1 -Repo "Moonchichiii/careerops" -Apply -UpdateExisting

    # Apply only one milestone
    .\scripts\bootstrap-github-roadmap.ps1 -Repo "Moonchichiii/careerops" -OnlyMilestone "M03 - Integrations and Capture Slice 1" -Apply
#>

param(
    [string]$Repo = "Moonchichiii/careerops",
    [switch]$Apply,
    [switch]$UpdateExisting,
    [string]$OnlyMilestone,
    [int]$DelayMilliseconds = 750
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartTime = Get-Date
$script:ManagedLabelPrefixes = @("type:", "area:", "priority:", "size:")
$script:Summary = [ordered]@{
    LabelsCreated = 0; LabelsUpdated = 0; LabelsPlanned = 0
    MilestonesCreated = 0; MilestonesUpdated = 0; MilestonesPlanned = 0
    IssuesCreated = 0; IssuesUpdated = 0; IssuesSkipped = 0; IssuesPlanned = 0
    TrackerUrls = [System.Collections.Generic.List[string]]::new()
    UnresolvedDependencyLinks = [System.Collections.Generic.List[string]]::new()
    OutsidePartialRunLinks = [System.Collections.Generic.List[string]]::new()
    FailedMutations = 0
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-DryRun { param([string]$Message) Write-Host "    [DRY-RUN] $Message" -ForegroundColor Yellow }
function Write-Done { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "    [SKIP] $Message" -ForegroundColor DarkGray }
function Write-Note { param([string]$Message) Write-Host "    [NOTE] $Message" -ForegroundColor DarkYellow }

# ---------------------------------------------------------------------------
# Environment assertions
# ---------------------------------------------------------------------------

function Assert-CommandAvailable {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not installed or not on PATH."
    }
}

function Assert-GitHubAuthentication {
    Write-Step "Verifying GitHub CLI authentication"
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "gh auth status failed. Run 'gh auth login' first."
    }
    Write-Done "Authenticated."
}

function Get-RepositoryMetadata {
    param([string]$Repository)
    Write-Step "Validating repository $Repository"
    $raw = (& gh api "repos/$Repository" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot access repository '$Repository'. Check the name and your permissions. gh said: $raw"
    }
    $meta = $raw | ConvertFrom-Json
    if ($meta.full_name -ne $Repository) {
        throw "Repository name mismatch: asked for '$Repository', API returned '$($meta.full_name)'."
    }
    if ($meta.fork) {
        throw "Repository '$Repository' is a fork. This script targets the standalone repository only."
    }
    if (-not $meta.has_issues) {
        throw "Issues are disabled on '$Repository'. Enable Issues in repository settings first."
    }
    Write-Done "Repository OK (default branch: $($meta.default_branch))."
    return $meta
}

# ---------------------------------------------------------------------------
# Preflight roadmap validation (runs before ANY mutation)
# ---------------------------------------------------------------------------

function Test-RoadmapDefinitions {
    param(
        [object[]]$Labels,
        [object[]]$Milestones,
        [object[]]$Trackers,
        [object[]]$Issues
    )
    Write-Step "Preflight validation of roadmap definitions"
    $problems = [System.Collections.Generic.List[string]]::new()

    $labelNames = @($Labels | ForEach-Object { $_.Name })
    $milestoneTitles = @($Milestones | ForEach-Object { $_.Title })

    foreach ($duplicate in ($labelNames | Group-Object | Where-Object { $_.Count -gt 1 })) {
        $problems.Add("Duplicate label name: $($duplicate.Name)")
    }
    foreach ($duplicate in ($milestoneTitles | Group-Object | Where-Object { $_.Count -gt 1 })) {
        $problems.Add("Duplicate milestone title: $($duplicate.Name)")
    }
    foreach ($label in $Labels) {
        if ($label.Color -notmatch '^[0-9A-Fa-f]{6}$') {
            $problems.Add("Label '$($label.Name)' has invalid colour '$($label.Color)'")
        }
    }

    $milestoneOrder = @{}
    for ($i = 0; $i -lt $milestoneTitles.Count; $i++) { $milestoneOrder[$milestoneTitles[$i]] = $i }

    $allDefs = @($Trackers) + @($Issues)

    # Duplicate roadmap IDs and titles
    $idSeen = @{}
    $titleSeen = @{}
    foreach ($def in $allDefs) {
        if ($idSeen.ContainsKey($def.RoadmapId)) { $problems.Add("Duplicate roadmap ID: $($def.RoadmapId)") }
        $idSeen[$def.RoadmapId] = $true
        if ($titleSeen.ContainsKey($def.Title)) { $problems.Add("Duplicate issue title: $($def.Title)") }
        $titleSeen[$def.Title] = $true
    }

    $trackerIds = @{}
    $trackerMilestones = @{}
    foreach ($t in $Trackers) {
        $trackerIds[$t.RoadmapId] = $true
        $trackerMilestones[$t.RoadmapId] = $t.Milestone
    }
    foreach ($milestoneTitle in $milestoneTitles) {
        $trackerCount = @($Trackers | Where-Object { $_.Milestone -eq $milestoneTitle }).Count
        if ($trackerCount -ne 1) {
            $problems.Add("Milestone '$milestoneTitle' must have exactly one tracker; found $trackerCount")
        }
    }

    $issueMilestone = @{}
    foreach ($def in $allDefs) { $issueMilestone[$def.RoadmapId] = $def.Milestone }

    $depGraph = @{}
    foreach ($def in $allDefs) {
        # Unknown milestone
        if (-not $milestoneOrder.ContainsKey($def.Milestone)) {
            $problems.Add("$($def.RoadmapId): unknown milestone title '$($def.Milestone)'")
        }
        # Unknown labels
        foreach ($lbl in $def.Labels) {
            if ($labelNames -notcontains $lbl) {
                $problems.Add("$($def.RoadmapId): unknown label '$lbl'")
            }
        }
        # Parent tracker exists
        if ($def.PSObject.Properties['ParentRoadmapId'] -and $def.ParentRoadmapId) {
            if (-not $trackerIds.ContainsKey($def.ParentRoadmapId)) {
                $problems.Add("$($def.RoadmapId): missing parent tracker '$($def.ParentRoadmapId)'")
            }
            elseif ($trackerMilestones[$def.ParentRoadmapId] -ne $def.Milestone) {
                $problems.Add("$($def.RoadmapId): parent tracker '$($def.ParentRoadmapId)' belongs to a different milestone")
            }
        }
        # Dependencies exist; no active milestone depends on a later milestone
        $deps = @()
        if ($def.PSObject.Properties['DependsOnIds']) { $deps = @($def.DependsOnIds) }
        $depGraph[$def.RoadmapId] = $deps
        foreach ($dep in $deps) {
            if (-not $idSeen.ContainsKey($dep)) {
                $problems.Add("$($def.RoadmapId): dependency '$dep' does not exist")
                continue
            }
            $thisMs = $def.Milestone
            $depMs = $issueMilestone[$dep]
            if ($milestoneOrder.ContainsKey($thisMs) -and $milestoneOrder.ContainsKey($depMs)) {
                if ($milestoneOrder[$depMs] -gt $milestoneOrder[$thisMs]) {
                    $problems.Add("$($def.RoadmapId) (in '$thisMs') depends on '$dep' in later milestone '$depMs'")
                }
            }
        }
    }

    # Cycle detection (iterative DFS, three-colour)
    $state = @{}
    foreach ($node in $depGraph.Keys) {
        if ($state.ContainsKey($node)) { continue }
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push(@($node, 0))
        while ($stack.Count -gt 0) {
            $frame = $stack.Peek()
            $cur = $frame[0]
            $idx = $frame[1]
            if ($idx -eq 0) { $state[$cur] = "grey" }
            $deps = $depGraph[$cur]
            if ($idx -lt $deps.Count) {
                $stack.Pop() | Out-Null
                $stack.Push(@($cur, ($idx + 1)))
                $next = $deps[$idx]
                if (-not $depGraph.ContainsKey($next)) { continue }
                if ($state.ContainsKey($next)) {
                    if ($state[$next] -eq "grey") {
                        $problems.Add("Dependency cycle detected involving '$cur' -> '$next'")
                    }
                    continue
                }
                $stack.Push(@($next, 0))
            }
            else {
                $state[$cur] = "black"
                $stack.Pop() | Out-Null
            }
        }
    }

    if ($problems.Count -gt 0) {
        Write-Host ""
        Write-Host "PREFLIGHT VALIDATION FAILED:" -ForegroundColor Red
        foreach ($p in ($problems | Select-Object -Unique)) { Write-Host "  - $p" -ForegroundColor Red }
        throw "Roadmap definitions are invalid. No mutation was attempted."
    }
    Write-Done "Validation passed: $($Trackers.Count) trackers, $($Issues.Count) implementation issues, $($Milestones.Count) milestones, $($Labels.Count) labels."
}

# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------

function Invoke-GhApiPaginated {
    param([string]$Path)
    $results = [System.Collections.Generic.List[object]]::new()
    $page = 1
    while ($true) {
        $sep = if ($Path.Contains("?")) { "&" } else { "?" }
        $raw = (& gh api "$Path${sep}per_page=100&page=$page" 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "gh api failed for '$Path' page ${page}: $raw" }
        $batch = @($raw | ConvertFrom-Json)
        if ($batch.Count -eq 0) { break }
        foreach ($item in $batch) { $results.Add($item) }
        if ($batch.Count -lt 100) { break }
        $page++
    }
    return , $results
}

function Get-ExistingLabels {
    param([string]$Repository)
    return Invoke-GhApiPaginated -Path "repos/$Repository/labels"
}

function Sync-Label {
    param([string]$Repository, [pscustomobject]$Label, [object[]]$Existing)
    $found = $Existing | Where-Object { $_.name -eq $Label.Name } | Select-Object -First 1
    if ($found -and -not $UpdateExisting) {
        Write-Skip "Label exists: $($Label.Name)"
        return
    }
    $action = if ($found) { "Update" } else { "Create" }
    if (-not $Apply) {
        Write-DryRun "$action label '$($Label.Name)' (#$($Label.Color))"
        $script:Summary.LabelsPlanned++
        return
    }
    & gh label create $Label.Name --repo $Repository --color $Label.Color --description $Label.Description --force | Out-Null
    if ($LASTEXITCODE -ne 0) { $script:Summary.FailedMutations++; throw "Failed to sync label '$($Label.Name)'." }
    if ($found) { $script:Summary.LabelsUpdated++ } else { $script:Summary.LabelsCreated++ }
    Write-Done "$action label: $($Label.Name)"
}

function Get-ExistingMilestones {
    param([string]$Repository)
    return Invoke-GhApiPaginated -Path "repos/$Repository/milestones?state=all"
}

function Sync-Milestone {
    param([string]$Repository, [pscustomobject]$Milestone, [object[]]$Existing)
    $found = $Existing | Where-Object { $_.title -eq $Milestone.Title } | Select-Object -First 1
    if ($found) {
        if (-not $UpdateExisting) {
            Write-Skip "Milestone exists: $($Milestone.Title) (#$($found.number))"
            return $found.number
        }
        if (-not $Apply) {
            Write-DryRun "Update milestone '$($Milestone.Title)'"
            $script:Summary.MilestonesPlanned++
            return $found.number
        }
        & gh api -X PATCH "repos/$Repository/milestones/$($found.number)" `
            -f "title=$($Milestone.Title)" -f "description=$($Milestone.Description)" | Out-Null
        if ($LASTEXITCODE -ne 0) { $script:Summary.FailedMutations++; throw "Failed to update milestone '$($Milestone.Title)'." }
        $script:Summary.MilestonesUpdated++
        Write-Done "Updated milestone: $($Milestone.Title)"
        return $found.number
    }
    if (-not $Apply) {
        Write-DryRun "Create milestone '$($Milestone.Title)'"
        $script:Summary.MilestonesPlanned++
        return $null
    }
    $raw = (& gh api -X POST "repos/$Repository/milestones" `
        -f "title=$($Milestone.Title)" -f "description=$($Milestone.Description)" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { $script:Summary.FailedMutations++; throw "Failed to create milestone '$($Milestone.Title)': $raw" }
    $created = $raw | ConvertFrom-Json
    $script:Summary.MilestonesCreated++
    Write-Done "Created milestone: $($Milestone.Title) (#$($created.number))"
    return $created.number
}

function Get-ExistingIssues {
    param([string]$Repository)
    Write-Step "Fetching existing issues (open and closed, excluding pull requests)"
    $all = Invoke-GhApiPaginated -Path "repos/$Repository/issues?state=all"
    $issuesOnly = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $all) {
        if (-not $item.PSObject.Properties['pull_request']) { $issuesOnly.Add($item) }
    }
    Write-Done "$($issuesOnly.Count) existing issues found."
    return , $issuesOnly
}

function Find-IssueByRoadmapId {
    param([object]$Existing, [string]$RoadmapId, [string]$Title)
    $marker = "<!-- careerops-roadmap-id: $RoadmapId -->"
    foreach ($issue in $Existing) {
        $body = ""
        if ($issue.PSObject.Properties['body'] -and $null -ne $issue.body) { $body = [string]$issue.body }
        if ($body.Contains($marker)) { return $issue }
    }
    foreach ($issue in $Existing) {
        if ($issue.title -eq $Title) { return $issue }
    }
    return $null
}

function Test-GhSupportsParentFlag {
    $help = (& gh issue create --help 2>&1) -join "`n"
    return ($help -match "--parent")
}

# ---------------------------------------------------------------------------
# Body rendering
# ---------------------------------------------------------------------------

function New-IssueBody {
    param(
        [string]$RoadmapId, [string]$Objective, [string]$Context,
        [string[]]$Scope, [string[]]$Acceptance, [string[]]$Validation,
        [string]$DocsImpact, [string[]]$OutOfScope, [string[]]$Dependencies,
        [bool]$Migration = $false
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("### Objective")
    [void]$sb.AppendLine($Objective); [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Context")
    [void]$sb.AppendLine($Context); [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Scope")
    foreach ($s in $Scope) { [void]$sb.AppendLine("- $s") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Acceptance criteria")
    foreach ($a in $Acceptance) { [void]$sb.AppendLine("- [ ] $a") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Validation")
    foreach ($v in $Validation) { [void]$sb.AppendLine("- $v") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Documentation impact")
    [void]$sb.AppendLine($DocsImpact); [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Out of scope")
    foreach ($o in $OutOfScope) { [void]$sb.AppendLine("- $o") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Dependencies")
    if ($Dependencies.Count -eq 0) { [void]$sb.AppendLine("- None") }
    else { foreach ($d in $Dependencies) { [void]$sb.AppendLine("- $d") } }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Definition of done")
    [void]$sb.AppendLine("- [ ] Implementation complete")
    [void]$sb.AppendLine("- [ ] Tests complete")
    [void]$sb.AppendLine("- [ ] Strict typing (mypy) passes")
    [void]$sb.AppendLine("- [ ] Ruff lint and format pass")
    if ($Migration) { [void]$sb.AppendLine("- [ ] Migration drift check passes") }
    [void]$sb.AppendLine("- [ ] Security implications reviewed")
    [void]$sb.AppendLine("- [ ] Relevant documentation updated")
    [void]$sb.AppendLine("- [ ] CI green")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("<!-- careerops-roadmap-id: $RoadmapId -->")
    return $sb.ToString()
}

function New-TrackerBody {
    param(
        [string]$RoadmapId, [string]$Purpose, [string]$Completion,
        [string[]]$Children, [string]$DependsOn, [string[]]$Excluded, [string[]]$DocLinks
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("### Milestone purpose")
    [void]$sb.AppendLine($Purpose); [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Completion definition")
    [void]$sb.AppendLine($Completion); [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Ordered work")
    foreach ($c in $Children) { [void]$sb.AppendLine("- [ ] $c") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Dependencies")
    [void]$sb.AppendLine($DependsOn); [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Explicitly deferred or excluded")
    foreach ($e in $Excluded) { [void]$sb.AppendLine("- $e") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("### Documentation")
    foreach ($d in $DocLinks) { [void]$sb.AppendLine("- $d") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("<!-- careerops-roadmap-id: $RoadmapId -->")
    return $sb.ToString()
}
# ---------------------------------------------------------------------------
# Issue mutation
# ---------------------------------------------------------------------------

function Get-ManagedLabelSet {
    param([string[]]$LabelNames)
    $managed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $LabelNames) {
        foreach ($prefix in $script:ManagedLabelPrefixes) {
            if ($name.StartsWith($prefix)) { $managed.Add($name); break }
        }
    }
    return , $managed
}

function Create-RoadmapIssue {
    param(
        [string]$Repository, [pscustomobject]$Definition,
        [System.Collections.Generic.List[object]]$Existing,
        [hashtable]$IssueNumbers, [bool]$SupportsParent, [hashtable]$TrackerNumbers
    )
    $found = Find-IssueByRoadmapId -Existing $Existing -RoadmapId $Definition.RoadmapId -Title $Definition.Title
    if ($found) {
        $IssueNumbers[$Definition.RoadmapId] = $found.number
        if ($Definition.RoadmapId -like "*-TRACKER") {
            $TrackerNumbers[$Definition.RoadmapId] = $found.number
            if ($found.PSObject.Properties['html_url'] -and $found.html_url) {
                $script:Summary.TrackerUrls.Add([string]$found.html_url)
            }
        }
        if (-not $UpdateExisting) {
            Write-Skip "Issue exists: [$($Definition.RoadmapId)] $($Definition.Title) (#$($found.number))"
            $script:Summary.IssuesSkipped++
            return
        }
        Update-RoadmapIssue -Repository $Repository -Definition $Definition -ExistingIssue $found
        return
    }
    if (-not $Apply) {
        Write-DryRun "Create issue [$($Definition.RoadmapId)] $($Definition.Title) -> milestone '$($Definition.Milestone)', labels: $($Definition.Labels -join ', ')"
        $script:Summary.IssuesPlanned++
        return
    }
    $ghArgs = @(
        "issue", "create", "--repo", $Repository,
        "--title", $Definition.Title,
        "--body", $Definition.Body,
        "--milestone", $Definition.Milestone
    )
    foreach ($label in $Definition.Labels) { $ghArgs += @("--label", $label) }
    if ($SupportsParent -and $Definition.PSObject.Properties['ParentRoadmapId'] -and $Definition.ParentRoadmapId) {
        if ($TrackerNumbers.ContainsKey($Definition.ParentRoadmapId)) {
            $ghArgs += @("--parent", "$($TrackerNumbers[$Definition.ParentRoadmapId])")
        }
    }
    $output = (& gh @ghArgs 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        $script:Summary.FailedMutations++
        throw "Failed to create issue [$($Definition.RoadmapId)] '$($Definition.Title)': $output"
    }
    $url = ($output.Trim() -split "`n")[-1].Trim()
    $number = [int](($url -split "/")[-1])
    $IssueNumbers[$Definition.RoadmapId] = $number
    $script:Summary.IssuesCreated++
    Write-Done "Created [$($Definition.RoadmapId)] #${number}: $($Definition.Title)"
    if ($Definition.RoadmapId -like "*-TRACKER") {
        $script:Summary.TrackerUrls.Add($url)
        $TrackerNumbers[$Definition.RoadmapId] = $number
    }
    # Refresh in-memory state so duplicate protection holds within this run.
    $Existing.Add([pscustomobject]@{ number = $number; title = $Definition.Title; body = $Definition.Body })
    Start-Sleep -Milliseconds $DelayMilliseconds
}

function Update-RoadmapIssue {
    param([string]$Repository, [pscustomobject]$Definition, [object]$ExistingIssue)
    if (-not $Apply) {
        Write-DryRun "Update issue [$($Definition.RoadmapId)] #$($ExistingIssue.number) (title, body, milestone, labels)"
        $script:Summary.IssuesPlanned++
        return
    }
    $ghArgs = @(
        "issue", "edit", "$($ExistingIssue.number)", "--repo", $Repository,
        "--title", $Definition.Title,
        "--body", $Definition.Body,
        "--milestone", $Definition.Milestone
    )
    # Reconcile managed labels: remove obsolete managed labels, add desired ones.
    $currentLabels = @()
    if ($ExistingIssue.PSObject.Properties['labels'] -and $null -ne $ExistingIssue.labels) {
        $currentLabels = @($ExistingIssue.labels | ForEach-Object { $_.name })
    }
    $currentManaged = Get-ManagedLabelSet -LabelNames $currentLabels
    $desiredManaged = Get-ManagedLabelSet -LabelNames $Definition.Labels
    foreach ($obsolete in $currentManaged) {
        if ($desiredManaged -notcontains $obsolete) { $ghArgs += @("--remove-label", $obsolete) }
    }
    foreach ($label in $Definition.Labels) { $ghArgs += @("--add-label", $label) }
    & gh @ghArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { $script:Summary.FailedMutations++; throw "Failed to update issue #$($ExistingIssue.number)." }
    $script:Summary.IssuesUpdated++
    Write-Done "Updated [$($Definition.RoadmapId)] #$($ExistingIssue.number)"
    Start-Sleep -Milliseconds $DelayMilliseconds
}

# ---------------------------------------------------------------------------
# Dependency linking (second pass)
# ---------------------------------------------------------------------------

function Link-IssueDependencies {
    param(
        [string]$Repository, [object[]]$Definitions, [hashtable]$IssueNumbers,
        [System.Collections.Generic.HashSet[string]]$SelectedIds
    )
    Write-Step "Linking issue dependencies (second pass)"
    foreach ($def in $Definitions) {
        $deps = @()
        if ($def.PSObject.Properties['DependsOnIds']) { $deps = @($def.DependsOnIds) }
        if ($deps.Count -eq 0) { continue }

        foreach ($depId in $deps) {
            # During a partial (-OnlyMilestone) run, dependencies outside the
            # selection remain documented in the body and are not failures.
            if ($OnlyMilestone -and -not $SelectedIds.Contains($depId)) {
                $script:Summary.OutsidePartialRunLinks.Add("$($def.RoadmapId) blocked-by $depId (outside partial run; documented in body)")
                continue
            }

            # A dry-run validates roadmap IDs before reaching this function.
            # Issue numbers do not exist for planned records, so report the
            # relationship as planned rather than falsely calling it unresolved.
            if (-not $Apply) {
                Write-DryRun "Plan dependency $($def.RoadmapId) blocked-by $depId"
                continue
            }

            $thisNumber = $null
            if ($IssueNumbers.ContainsKey($def.RoadmapId)) { $thisNumber = $IssueNumbers[$def.RoadmapId] }
            if (-not $thisNumber) {
                $script:Summary.UnresolvedDependencyLinks.Add("$($def.RoadmapId) blocked-by $depId (issue number unknown)")
                continue
            }

            $depNumber = $null
            if ($IssueNumbers.ContainsKey($depId)) { $depNumber = $IssueNumbers[$depId] }
            if (-not $depNumber) {
                $script:Summary.UnresolvedDependencyLinks.Add("$($def.RoadmapId) blocked-by $depId (dependency issue number unknown)")
                continue
            }

            $depRaw = (& gh api "repos/$Repository/issues/$depNumber" 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) {
                $script:Summary.FailedMutations++
                throw "Dependency lookup failed for issue #${depNumber}: $depRaw"
            }
            $depIssueId = [int64](($depRaw | ConvertFrom-Json).id)

            # Query first so rerunning -Apply is genuinely idempotent.
            $existingRaw = (& gh api "repos/$Repository/issues/$thisNumber/dependencies/blocked_by?per_page=100" 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) {
                if ($existingRaw -match "404" -or $existingRaw -match "Not Found" -or $existingRaw -match "not supported") {
                    $script:Summary.UnresolvedDependencyLinks.Add("$($def.RoadmapId) blocked-by $depId (dependencies API unavailable; body reference retained)")
                    continue
                }
                $script:Summary.FailedMutations++
                throw "Existing dependency lookup failed for issue #${thisNumber}: $existingRaw"
            }

            $existingDependencies = @($existingRaw | ConvertFrom-Json)
            $alreadyLinked = $false
            foreach ($existingDependency in $existingDependencies) {
                if ([int64]$existingDependency.id -eq $depIssueId) {
                    $alreadyLinked = $true
                    break
                }
            }
            if ($alreadyLinked) {
                Write-Skip "#$thisNumber already blocked-by #$depNumber"
                continue
            }

            $linkRaw = (& gh api -X POST "repos/$Repository/issues/$thisNumber/dependencies/blocked_by" `
                -F "issue_id=$depIssueId" 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) {
                # Only a missing/unsupported endpoint is a legitimate fallback.
                if ($linkRaw -match "404" -or $linkRaw -match "Not Found" -or $linkRaw -match "not supported") {
                    $script:Summary.UnresolvedDependencyLinks.Add("$($def.RoadmapId) blocked-by $depId (dependencies API unavailable; body reference retained)")
                }
                elseif ($linkRaw -match "already" -and $linkRaw -match "depend") {
                    Write-Skip "#$thisNumber already blocked-by #$depNumber"
                }
                else {
                    $script:Summary.FailedMutations++
                    throw "Dependency link failed for #$thisNumber blocked-by #${depNumber}: $linkRaw"
                }
            }
            else {
                Write-Done "#$thisNumber blocked-by #$depNumber"
                Start-Sleep -Milliseconds $DelayMilliseconds
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

function Write-ExecutionSummary {
    $elapsed = (Get-Date) - $script:StartTime
    Write-Host ""
    Write-Host "================ SUMMARY ================" -ForegroundColor Cyan
    Write-Host ("Mode:                 {0}" -f ($(if ($Apply) { "APPLY" } else { "DRY-RUN" })))
    if (-not $Apply) {
        Write-Host ("Labels planned:       {0}" -f $script:Summary.LabelsPlanned)
        Write-Host ("Milestones planned:   {0}" -f $script:Summary.MilestonesPlanned)
        Write-Host ("Issues planned:       {0}" -f $script:Summary.IssuesPlanned)
    }
    Write-Host ("Labels created:       {0}" -f $script:Summary.LabelsCreated)
    Write-Host ("Labels updated:       {0}" -f $script:Summary.LabelsUpdated)
    Write-Host ("Milestones created:   {0}" -f $script:Summary.MilestonesCreated)
    Write-Host ("Milestones updated:   {0}" -f $script:Summary.MilestonesUpdated)
    Write-Host ("Issues created:       {0}" -f $script:Summary.IssuesCreated)
    Write-Host ("Issues updated:       {0}" -f $script:Summary.IssuesUpdated)
    Write-Host ("Issues skipped:       {0}" -f $script:Summary.IssuesSkipped)
    Write-Host "Tracker URLs:"
    foreach ($u in $script:Summary.TrackerUrls) { Write-Host "  $u" }
    if ($script:Summary.OutsidePartialRunLinks.Count -gt 0) {
        Write-Host "Dependencies outside partial run (informational):" -ForegroundColor DarkYellow
        foreach ($l in $script:Summary.OutsidePartialRunLinks) { Write-Host "  $l" }
    }
    if ($script:Summary.UnresolvedDependencyLinks.Count -gt 0) {
        Write-Host "Unresolved dependency links:" -ForegroundColor Yellow
        foreach ($l in $script:Summary.UnresolvedDependencyLinks) { Write-Host "  $l" }
    }
    else {
        Write-Host "Unresolved dependency links: none"
    }
    Write-Host ("Failed mutations:     {0}" -f $script:Summary.FailedMutations)
    Write-Host ("Total execution time: {0:mm\:ss}" -f $elapsed)
    Write-Host "=========================================" -ForegroundColor Cyan
}
# ---------------------------------------------------------------------------
# Labels (27)
# ---------------------------------------------------------------------------

$Labels = @(
    [pscustomobject]@{ Name = "type:feature";            Color = "1D76DB"; Description = "New capability" }
    [pscustomobject]@{ Name = "type:chore";              Color = "BFD4F2"; Description = "Build, tooling, or maintenance" }
    [pscustomobject]@{ Name = "type:docs";               Color = "0075CA"; Description = "Documentation change" }
    [pscustomobject]@{ Name = "type:test";               Color = "5319E7"; Description = "Test-focused work" }
    [pscustomobject]@{ Name = "type:security";           Color = "B60205"; Description = "Security control or hardening" }
    [pscustomobject]@{ Name = "type:architecture";       Color = "6F42C1"; Description = "Boundary or contract work" }
    [pscustomobject]@{ Name = "type:decision";           Color = "D4C5F9"; Description = "Records a decision gate" }
    [pscustomobject]@{ Name = "type:spike";              Color = "C2E0C6"; Description = "Time-boxed investigation or benchmark" }
    [pscustomobject]@{ Name = "area:web";                Color = "0E8A16"; Description = "Server-rendered UI and assets" }
    [pscustomobject]@{ Name = "area:accounts";           Color = "006B75"; Description = "Authentication and identity" }
    [pscustomobject]@{ Name = "area:workspaces";         Color = "0052CC"; Description = "Tenancy and authorization" }
    [pscustomobject]@{ Name = "area:integrations";       Color = "FBCA04"; Description = "Data Bridge and capture channels" }
    [pscustomobject]@{ Name = "area:job-registry";       Color = "E99695"; Description = "Observations through canonical jobs" }
    [pscustomobject]@{ Name = "area:candidate-evidence"; Color = "F9D0C4"; Description = "Evidence and provenance" }
    [pscustomobject]@{ Name = "area:matching";           Color = "D93F0B"; Description = "Requirements, scoring, retrieval, explanation" }
    [pscustomobject]@{ Name = "area:application-ops";    Color = "1D3557"; Description = "Application lifecycle" }
    [pscustomobject]@{ Name = "area:analytics";          Color = "0366D6"; Description = "Outcome analytics and analytical read models" }
    [pscustomobject]@{ Name = "area:platform";           Color = "555555"; Description = "Shared mechanisms: outbox, operations, idempotency, audit" }
    [pscustomobject]@{ Name = "area:ci";                 Color = "2B2D42"; Description = "Pipelines and quality gates" }
    [pscustomobject]@{ Name = "area:observability";      Color = "8D99AE"; Description = "Metrics, traces, dashboards" }
    [pscustomobject]@{ Name = "priority:p0";             Color = "B60205"; Description = "Critical path" }
    [pscustomobject]@{ Name = "priority:p1";             Color = "D93F0B"; Description = "Important, near-term" }
    [pscustomobject]@{ Name = "priority:p2";             Color = "FBCA04"; Description = "Normal" }
    [pscustomobject]@{ Name = "priority:p3";             Color = "C5DEF5"; Description = "Deferred-track decisions" }
    [pscustomobject]@{ Name = "size:S";                  Color = "C2E0C6"; Description = "Half a day or less" }
    [pscustomobject]@{ Name = "size:M";                  Color = "FEF2C0"; Description = "Half a day to 1.5 days" }
    [pscustomobject]@{ Name = "size:L";                  Color = "F9C513"; Description = "1.5 to 3 days" }
)

# ---------------------------------------------------------------------------
# Milestones (10)
# ---------------------------------------------------------------------------

$Milestones = @(
    [pscustomobject]@{ Title = "M01 - Web Asset Foundation and Application Shell"
        Description = "Completes the remaining ROADMAP Milestone 1 items: Tailwind/HTMX/TypeScript asset foundation, Docker development and production images, plus a CSP-compatible server-rendered application shell. Source: docs/planning/ROADMAP.md Milestone 1." }
    [pscustomobject]@{ Title = "M02 - Accounts, Workspaces, and Authorization"
        Description = "Session authentication on the shell, the workspace tenant boundary with memberships and roles, the authorized-selector foundation, and the append-only audit mechanism. Prerequisite of ROADMAP Milestone 2: capture is authenticated and workspace-scoped." }
    [pscustomobject]@{ Title = "M03 - Integrations and Capture Slice 1"
        Description = "Exactly three capture transports (HTMX, browser extension, CSV) through inbound envelopes, versioned contracts, transport idempotency, and operation status, including the browser-extension client itself. Covers the Integrations half of ROADMAP Milestone 2. Mobile, email, feeds, and connected accounts remain deferred per docs/domain/INTEGRATIONS.md." }
    [pscustomobject]@{ Title = "M04 - Job Registry and Identity Resolution"
        Description = "Immutable observations, versioned normalization, the transactional outbox, Celery/RabbitMQ workflow, and the atomic identity-resolution transaction ending at existing/new/ambiguous outcomes with full telemetry. Covers the registry half of ROADMAP Milestone 2." }
    [pscustomobject]@{ Title = "M05 - Candidate Evidence and Provenance"
        Description = "Versioned, attributable candidate evidence with the provenance taxonomy and export/deletion boundaries. ROADMAP Milestone 3." }
    [pscustomobject]@{ Title = "M06 - Deterministic Opportunity Matching"
        Description = "Versioned requirements, rule-based scoring, chunk-level match evidence, supersession, and evaluation fixtures. ROADMAP Milestone 4. No LLM scoring." }
    [pscustomobject]@{ Title = "M07 - Retrieval and Evidence-Grounded Explanation"
        Description = "Labelled evaluation set first, then measured full-text retrieval, a pgvector adoption spike, and advisory explanation with claim citations and human review. ROADMAP Milestone 5. Generation never becomes the scoring or decision authority." }
    [pscustomobject]@{ Title = "M08 - Application Operations"
        Description = "Controlled application lifecycle with append-only transition history, interviews, contacts, follow-ups, and evidence-version linkage. ROADMAP Milestone 6." }
    [pscustomobject]@{ Title = "M09 - Observability, Analytics, and Production Readiness"
        Description = "Deployment-target decision, service-level indicators, alerting, conversion analytics from PostgreSQL, production deployment with exercised rollback, and a hardening pass. ROADMAP Milestone 7." }
    [pscustomobject]@{ Title = "M10 - Deferred Decisions and Benchmark Gates"
        Description = "Deferred gates only: native mobile activation, the Rust benchmark gate (if retained), and DuckDB analytical-export entry. Contains no implementation work. Source: ROADMAP Deferred Delivery Tracks and Open Decisions." }
)

# ---------------------------------------------------------------------------
# Tracker issues (created before implementation issues)
# ---------------------------------------------------------------------------

$Trackers = @(
    [pscustomobject]@{ RoadmapId = "M01-TRACKER"; Milestone = "M01 - Web Asset Foundation and Application Shell"
        Title = "Tracker: M01 Web Asset Foundation and Application Shell"
        Labels = @("type:docs", "area:web", "priority:p0"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M01-TRACKER" `
            -Purpose "Finish the unchecked ROADMAP Milestone 1 items and stand up the CSP-compatible server-rendered shell every later journey builds on." `
            -Completion "All three child issues closed; ROADMAP Milestone 1 checklist fully checked; base layout renders with strict assets and no inline script." `
            -Children @("M01-01 Tailwind, TypeScript, and Vite asset pipeline", "M01-02 Base application shell and HTMX foundation", "M01-03 Docker development and production images") `
            -DependsOn "None. Baseline scaffold (settings, health, CI quality gates, uv.lock under Python 3.14) is already complete and verified." `
            -Excluded @("No SPA framework", "No component library", "No mobile assets", "No authentication flows (M02)") `
            -DocLinks @("docs/planning/ROADMAP.md (Milestone 1)", "docs/engineering/ENGINEERING_STANDARDS.md", "docs/security/SECURITY_MODEL.md (Browser Security)")) }
    [pscustomobject]@{ RoadmapId = "M02-TRACKER"; Milestone = "M02 - Accounts, Workspaces, and Authorization"
        Title = "Tracker: M02 Accounts, Workspaces, and Authorization"
        Labels = @("type:docs", "area:workspaces", "priority:p0"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M02-TRACKER" `
            -Purpose "Establish who the user is and which workspace scopes every read and write, before any capture exists." `
            -Completion "An authenticated user operates inside a workspace; selectors compose authorization; roles enforced; audit records append inside acting transactions." `
            -Children @("M02-01 Session authentication flows on the shell", "M02-02 Workspace and membership aggregates", "M02-03 Workspace resolution and authorized selector foundation", "M02-04 Roles and object-level permission checks", "M02-05 Append-only audit event mechanism") `
            -DependsOn "M01 (application shell)." `
            -Excluded @("No OAuth or social login", "No MFA in this milestone", "No API credentials (arrive with the extension in M03)") `
            -DocLinks @("docs/security/SECURITY_MODEL.md", "docs/domain/DOMAIN_GLOSSARY.md (Workspace, Audit event)", "docs/engineering/ENGINEERING_STANDARDS.md (QuerySets and selectors)")) }
    [pscustomobject]@{ RoadmapId = "M03-TRACKER"; Milestone = "M03 - Integrations and Capture Slice 1"
        Title = "Tracker: M03 Integrations and Capture Slice 1"
        Labels = @("type:docs", "area:integrations", "priority:p0"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M03-TRACKER" `
            -Purpose "Prove three genuinely different transports (same-origin HTMX, cross-origin API with its real extension client, file batch) through envelopes, contracts, idempotency, and operation status." `
            -Completion "All three channels accept a capture end-to-end to the observation handoff, with envelope replay protection, idempotent retries, observable operation state, and a working extension client a user can install locally." `
            -Children @("M03-01 Inbound envelope with provenance and replay protection", "M03-02 Transport idempotency records", "M03-03 Operations resource and status fragment", "M03-04 Versioned capture contract v1", "M03-05 HTMX manual capture journey", "M03-06 CSV batch import with import-run semantics", "M03-07 Browser-extension capture API", "M03-08 Browser-extension capture client") `
            -DependsOn "M02 (authenticated, workspace-scoped requests)." `
            -Excluded @("Native mobile share-sheet capture (deferred track, gate M10-01)", "Email forwarding and connected inboxes", "RSS/Atom and scheduled feeds", "Sync cursors (no pull-based source in slice 1)") `
            -DocLinks @("docs/domain/INTEGRATIONS.md", "docs/planning/ROADMAP.md (Milestone 2)", "docs/architecture/diagrams/capture-sequence.mmd")) }
    [pscustomobject]@{ RoadmapId = "M04-TRACKER"; Milestone = "M04 - Job Registry and Identity Resolution"
        Title = "Tracker: M04 Job Registry and Identity Resolution"
        Labels = @("type:docs", "area:job-registry", "priority:p0"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M04-TRACKER" `
            -Purpose "Turn accepted evidence into canonical jobs: immutable observations, versioned normalization, the outbox, and the atomic resolution transaction with the ambiguous outcome as a first-class result." `
            -Completion "A captured job reaches an existing/new/ambiguous outcome asynchronously with trace-complete telemetry, concurrency protection proven under test, and no external side effect inside a transaction." `
            -Children @("M04-01 JobObservation aggregate and source-replay detection", "M04-02 Transactional outbox and dispatcher", "M04-03 Celery and RabbitMQ workflow foundation", "M04-04 Versioned normalization with Python baseline", "M04-05 Identity resolution transaction", "M04-06 Capture slice telemetry and failure validation") `
            -DependsOn "M03 (envelopes and contracts feeding the registry)." `
            -Excluded @("No requirement extraction beyond identity signals", "No opportunity matching", "No Rust processor (benchmark-gated, M10-02)") `
            -DocLinks @("docs/architecture/ARCHITECTURE.md (Identity Resolution Transaction)", "docs/architecture/diagrams/resolution-transaction.mmd", "docs/domain/DOMAIN_GLOSSARY.md (Duplicate Conditions)")) }
    [pscustomobject]@{ RoadmapId = "M05-TRACKER"; Milestone = "M05 - Candidate Evidence and Provenance"
        Title = "Tracker: M05 Candidate Evidence and Provenance"
        Labels = @("type:docs", "area:candidate-evidence", "priority:p1"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M05-TRACKER" `
            -Purpose "Model attributable candidate evidence whose provenance distinctions protect all later matching and generation from inventing professional claims." `
            -Completion "Evidence documents version and supersede correctly; chunks carry chunker versions and workspace scope; provenance taxonomy is constrained; export and deletion work with audit." `
            -Children @("M05-01 Candidate profile and versioned evidence documents", "M05-02 Evidence chunks with chunker versioning", "M05-03 Provenance taxonomy enforcement", "M05-04 Evidence export and deletion boundaries") `
            -DependsOn "M02 (workspace scope). Runs independently of M04 internals." `
            -Excluded @("No retrieval or embeddings", "No GitHub or connected-account import (deferred)", "No generation") `
            -DocLinks @("docs/planning/ROADMAP.md (Milestone 3)", "docs/domain/DOMAIN_GLOSSARY.md (Candidate and Matching)", "docs/domain/INTEGRATIONS.md (Candidate Evidence Provenance)")) }
    [pscustomobject]@{ RoadmapId = "M06-TRACKER"; Milestone = "M06 - Deterministic Opportunity Matching"
        Title = "Tracker: M06 Deterministic Opportunity Matching"
        Labels = @("type:docs", "area:matching", "priority:p1"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M06-TRACKER" `
            -Purpose "Produce inspectable requirement coverage and scoring before any semantic layer exists, so the deterministic baseline defines correctness." `
            -Completion "Match results with chunk-level evidence, supported/partial/unsupported/insufficient outcomes, supersession on recalculation, and evaluation fixtures encoding the hard boundary cases." `
            -Children @("M06-01 Versioned requirement extraction", "M06-02 Rule-based scoring components", "M06-03 Chunk-level match evidence", "M06-04 Recalculation and supersession", "M06-05 Matching evaluation fixtures") `
            -DependsOn "M04 (canonical jobs) and M05 (evidence chunks)." `
            -Excluded @("No LLM in the scoring path", "No semantic retrieval (M07)") `
            -DocLinks @("docs/planning/ROADMAP.md (Milestone 4)", "docs/domain/DOMAIN_GLOSSARY.md (Opportunity matching)")) }
    [pscustomobject]@{ RoadmapId = "M07-TRACKER"; Milestone = "M07 - Retrieval and Evidence-Grounded Explanation"
        Title = "Tracker: M07 Retrieval and Evidence-Grounded Explanation"
        Labels = @("type:docs", "area:matching", "priority:p2"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M07-TRACKER" `
            -Purpose "Add measured retrieval and advisory explanation, in that order: the labelled set defines working before anything is tuned, and generation explains rather than decides." `
            -Completion "Retrieval quality is a number against a gold set; pgvector adopted or re-deferred with evidence; explanations carry claim classification and pass human review before use." `
            -Children @("M07-01 Labelled retrieval evaluation dataset", "M07-02 Full-text retrieval with workspace filtering", "M07-03 pgvector adoption spike", "M07-04 Evidence-grounded explanation with citations") `
            -DependsOn "M06 (deterministic baseline and fixtures)." `
            -Excluded @("Generation never scores or transitions state", "No dedicated vector database") `
            -DocLinks @("docs/planning/ROADMAP.md (Milestone 5)", "docs/architecture/diagrams/future-rag-boundary.mmd", "docs/security/SECURITY_MODEL.md (External Content and Generation)")) }
    [pscustomobject]@{ RoadmapId = "M08-TRACKER"; Milestone = "M08 - Application Operations"
        Title = "Tracker: M08 Application Operations"
        Labels = @("type:docs", "area:application-ops", "priority:p1"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M08-TRACKER" `
            -Purpose "Deliver the controlled application lifecycle: valid transitions with append-only history as the authority and current state as a same-transaction read optimization." `
            -Completion "Applications move through valid transitions only; interviews, contacts, and follow-ups operate; the pipeline UI is keyboard-complete." `
            -Children @("M08-01 Application aggregate with append-only transitions", "M08-02 Interviews, contacts, and follow-ups", "M08-03 CV and evidence version linkage", "M08-04 Application pipeline HTMX journey") `
            -DependsOn "M04 (canonical jobs), M02 (workspace scope), M05 (evidence versions for M08-03)." `
            -Excluded @("No calendar synchronization (outbound-first when it arrives, deferred)", "No automated application submission") `
            -DocLinks @("docs/planning/ROADMAP.md (Milestone 6)", "docs/architecture/diagrams/application-state.mmd")) }
    [pscustomobject]@{ RoadmapId = "M09-TRACKER"; Milestone = "M09 - Observability, Analytics, and Production Readiness"
        Title = "Tracker: M09 Observability, Analytics, and Production Readiness"
        Labels = @("type:docs", "area:observability", "priority:p2"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M09-TRACKER" `
            -Purpose "Operational objectives and career-outcome analysis against real workflows, and a production environment with exercised rollback, starting from the deployment-target decision." `
            -Completion "Deployment target decided and recorded; SLIs alert on objectives; conversion analytics answer real questions from PostgreSQL; production deployment, smoke tests, and rollback are demonstrated; the security baseline is verified in production." `
            -Children @("M09-01 Decision: select the initial deployment target", "M09-02 Service-level indicators and alerting", "M09-03 Conversion analytics read models", "M09-04 Production deployment with smoke tests and rollback", "M09-05 Production security hardening") `
            -DependsOn "M04 through M08 (real workflows to observe)." `
            -Excluded @("No PostHog (no product question requires it yet)", "No DuckDB (gate M10-03)", "No Kubernetes") `
            -DocLinks @("docs/planning/ROADMAP.md (Milestone 7)", "docs/planning/TECHNOLOGY_DECISIONS.md")) }
    [pscustomobject]@{ RoadmapId = "M10-TRACKER"; Milestone = "M10 - Deferred Decisions and Benchmark Gates"
        Title = "Tracker: M10 Deferred Decisions and Benchmark Gates"
        Labels = @("type:docs", "area:platform", "priority:p3"); DependsOnIds = @()
        Body = (New-TrackerBody -RoadmapId "M10-TRACKER" `
            -Purpose "Hold the genuinely deferred gates from ROADMAP: mobile activation, the Rust benchmark (if retained), and DuckDB entry, so deferred work stays visible without becoming premature implementation." `
            -Completion "Each gate closes with a recorded outcome: activated with an entry milestone, or re-deferred with reasoning." `
            -Children @("M10-01 Decision gate: activate the native mobile delivery track", "M10-02 Benchmark gate: evaluate Rust content processing if retained", "M10-03 Decision gate: introduce DuckDB for a real analytical export") `
            -DependsOn "Varies per gate; see each issue." `
            -Excluded @("This milestone contains no implementation issues by definition") `
            -DocLinks @("docs/planning/ROADMAP.md (Deferred Delivery Tracks, Open Decisions)", "docs/planning/TECHNOLOGY_DECISIONS.md (Deferred)")) }
)
# ---------------------------------------------------------------------------
# Implementation issues (47)
# ---------------------------------------------------------------------------

$Issues = @(
    # ----- M01 (3) -----
    [pscustomobject]@{ RoadmapId = "M01-01"; Milestone = "M01 - Web Asset Foundation and Application Shell"; ParentRoadmapId = "M01-TRACKER"
        Title = "Tailwind, TypeScript, and Vite asset pipeline"
        Labels = @("type:feature", "area:web", "priority:p0", "size:M"); DependsOnIds = @()
        Body = (New-IssueBody -RoadmapId "M01-01" `
            -Objective "A working asset pipeline producing versioned CSS and JavaScript bundles that Django serves as static files, with strict TypeScript checking as a separate CI step." `
            -Context "ROADMAP Milestone 1 lists the Tailwind, HTMX, and TypeScript asset foundation as unchecked. Every later browser journey depends on it, and the strict CSP direction requires external bundles rather than inline script." `
            -Scope @("Tailwind CSS configured and built into Django static assets", "TypeScript project with strict mode and the agreed compiler flags", "Vite build producing hashed bundles consumed via Django staticfiles", "Separate tsc type-check step (Vite transpiles; it does not type-check)", "CI job extension for frontend lint, type-check, and build") `
            -Acceptance @("Vite build produces bundles Django serves in local development", "tsc --noEmit passes in strict mode", "No inline script or style required by the pipeline", "CI runs frontend checks on pull requests") `
            -Validation @("uv run python manage.py collectstatic succeeds with built assets", "CI frontend job green on a PR touching assets", "Rendered page loads bundles with no console errors") `
            -DocsImpact "ROADMAP.md Milestone 1 checkbox; ENGINEERING_STANDARDS.md if any asset rule is refined." `
            -OutOfScope @("No React or SPA framework", "No browser-extension build (M03-08)", "No mobile assets (deferred track)") `
            -Dependencies @("None")) }
    [pscustomobject]@{ RoadmapId = "M01-02"; Milestone = "M01 - Web Asset Foundation and Application Shell"; ParentRoadmapId = "M01-TRACKER"
        Title = "Base application shell and HTMX foundation"
        Labels = @("type:feature", "area:web", "priority:p0", "size:M"); DependsOnIds = @("M01-01")
        Body = (New-IssueBody -RoadmapId "M01-02" `
            -Objective "A CSP-compatible base layout with Django 6 native partials and HTMX wired in, ready to host authenticated journeys." `
            -Context "The shell is the rendering foundation for every HTMX journey. Building it before authentication keeps M02 focused on auth logic rather than layout." `
            -Scope @("Base template with blocks, navigation region, and message rendering", "HTMX loaded from self-hosted assets with eval-free configuration", "Django native template partial demonstrated with one shared fragment", "Security-header tests extended to cover rendered pages") `
            -Acceptance @("Base layout renders with zero inline scripts and zero CSP violations", "An HTMX request swaps a partial rendered by the same view as the full page", "Existing security-header tests pass against rendered templates") `
            -Validation @("pytest security-header and template tests green", "Manual check: browser console clean on the shell page") `
            -DocsImpact "None." `
            -OutOfScope @("No login form logic (M02-01)", "No domain pages") `
            -Dependencies @("M01-01")) }
    [pscustomobject]@{ RoadmapId = "M01-03"; Milestone = "M01 - Web Asset Foundation and Application Shell"; ParentRoadmapId = "M01-TRACKER"
        Title = "Docker development and production images"
        Labels = @("type:chore", "area:ci", "priority:p1", "size:M"); DependsOnIds = @("M01-01")
        Body = (New-IssueBody -RoadmapId "M01-03" `
            -Objective "Reproducible development and production container images built with uv, integrated into compose for the full local stack." `
            -Context "ROADMAP Milestone 1 lists Docker development and production images as unchecked. compose.yaml currently provides PostgreSQL only." `
            -Scope @("Multi-stage production Dockerfile using uv sync --locked", "Development image or compose service for the Django app", "compose.yaml extended to run the application against PostgreSQL", "Image build added to CI") `
            -Acceptance @("Production image builds in CI", "docker compose up serves the application locally", "Image contains no development dependencies") `
            -Validation @("CI image-build job green", "Local smoke: health endpoint responds from the containerized app") `
            -DocsImpact "README.md Local Development section gains real, verified commands." `
            -OutOfScope @("No deployment target work (M09-01 decides; M09-04 implements)", "No Kubernetes manifests") `
            -Dependencies @("M01-01")) }

    # ----- M02 (5) -----
    [pscustomobject]@{ RoadmapId = "M02-01"; Milestone = "M02 - Accounts, Workspaces, and Authorization"; ParentRoadmapId = "M02-TRACKER"
        Title = "Session authentication flows on the shell"
        Labels = @("type:feature", "area:accounts", "priority:p0", "size:M"); DependsOnIds = @("M01-02")
        Body = (New-IssueBody -RoadmapId "M02-01" `
            -Objective "Login and logout on the application shell using Django sessions, secure cookies, CSRF protection, and login throttling." `
            -Context "SECURITY_MODEL.md fixes session authentication for the first-party interface. The custom email-based user model already exists; the flows do not." `
            -Scope @("Login and logout views on the base shell", "Secure session and CSRF cookie settings verified by tests", "Login throttling baseline", "Authenticated-versus-anonymous shell states") `
            -Acceptance @("A user can log in and out through the shell", "Session cookies are Secure, HttpOnly, and SameSite-configured in production settings", "Repeated failed logins are throttled") `
            -Validation @("pytest auth-flow and cookie-attribute tests green", "Playwright login journey once browser gates activate (M03-05)") `
            -DocsImpact "SECURITY_MODEL.md Verification Status row for session authentication." `
            -OutOfScope @("No registration or invitation flows beyond what testing requires", "No MFA", "No OAuth") `
            -Dependencies @("M01-02")) }
    [pscustomobject]@{ RoadmapId = "M02-02"; Milestone = "M02 - Accounts, Workspaces, and Authorization"; ParentRoadmapId = "M02-TRACKER"
        Title = "Workspace and membership aggregates"
        Labels = @("type:feature", "area:workspaces", "priority:p0", "size:M"); DependsOnIds = @()
        Body = (New-IssueBody -RoadmapId "M02-02" -Migration $true `
            -Objective "Workspace and membership models matching the conceptual ERD, with database-enforced uniqueness and constraint tests." `
            -Context "The workspace is the tenant boundary every later record scopes to. The ERD defines workspaces and workspace_memberships with a unique (workspace, user) pair." `
            -Scope @("Workspace and WorkspaceMembership models with UUID keys", "Unique membership constraint enforced by PostgreSQL", "Role field using the membership_role values from the ERD", "Migrations plus constraint tests that assert database-level rejection") `
            -Acceptance @("Duplicate membership insertion fails at the database", "Migration applies to a fresh database", "Constraint tests run against PostgreSQL, not SQLite") `
            -Validation @("pytest constraint tests green under PostgreSQL", "Migration drift check green") `
            -DocsImpact "None (implements accepted ERD)." `
            -OutOfScope @("No invitation UI", "No role-permission logic (M02-04)") `
            -Dependencies @("None")) }
    [pscustomobject]@{ RoadmapId = "M02-03"; Milestone = "M02 - Accounts, Workspaces, and Authorization"; ParentRoadmapId = "M02-TRACKER"
        Title = "Workspace resolution and authorized selector foundation"
        Labels = @("type:architecture", "area:workspaces", "priority:p0", "size:M"); DependsOnIds = @("M02-01", "M02-02")
        Body = (New-IssueBody -RoadmapId "M02-03" `
            -Objective "The selector layer that establishes workspace visibility before composing query vocabulary, plus request-level workspace resolution for the web interface." `
            -Context "ENGINEERING_STANDARDS.md fixes the rule: QuerySets never see users; selectors always establish authorization first. This issue creates that foundation and the first query-budget test, activating the selector CI gate." `
            -Scope @("require_workspace_access service guard with domain exceptions", "Active-workspace resolution for authenticated requests", "First authorized selector with an explicit query budget test", "Architecture test asserting QuerySet methods accept no user argument") `
            -Acceptance @("A request outside the workspace of the user is rejected with the domain exception", "Query-budget test asserts the exact query count", "Architecture test fails if a QuerySet method takes a user parameter") `
            -Validation @("pytest selector, budget, and architecture tests green") `
            -DocsImpact "ENGINEERING_STANDARDS.md CI Gate table: query-budget gate marked active." `
            -OutOfScope @("No role matrix (M02-04)", "No extension credentials (M03-07)") `
            -Dependencies @("M02-01", "M02-02")) }
    [pscustomobject]@{ RoadmapId = "M02-04"; Milestone = "M02 - Accounts, Workspaces, and Authorization"; ParentRoadmapId = "M02-TRACKER"
        Title = "Roles and object-level permission checks"
        Labels = @("type:security", "area:workspaces", "priority:p1", "size:M"); DependsOnIds = @("M02-03")
        Body = (New-IssueBody -RoadmapId "M02-04" `
            -Objective "Role-based permission checks composed in the selector and service layer, with a regression test per role boundary." `
            -Context "SECURITY_MODEL.md requires authorization and workspace isolation before capture accepts data on behalf of a workspace." `
            -Scope @("Permission policy for the five ERD roles", "Object-level checks in services for mutating operations", "Regression tests for each role on representative read and write paths") `
            -Acceptance @("A viewer cannot mutate; an owner can administer; each boundary has a failing-then-passing test", "Permission failures raise domain exceptions translated at the view boundary") `
            -Validation @("pytest role-matrix tests green") `
            -DocsImpact "SECURITY_MODEL.md Verification Status for authorization." `
            -OutOfScope @("No API scopes (single external consumer; mobile gate M10-01)", "No admin UI for role management") `
            -Dependencies @("M02-03")) }
    [pscustomobject]@{ RoadmapId = "M02-05"; Milestone = "M02 - Accounts, Workspaces, and Authorization"; ParentRoadmapId = "M02-TRACKER"
        Title = "Append-only audit event mechanism"
        Labels = @("type:feature", "area:platform", "priority:p1", "size:M"); DependsOnIds = @("M02-02")
        Body = (New-IssueBody -RoadmapId "M02-05" -Migration $true `
            -Objective "The shared audit-event mechanism: append-only records written inside the transaction of the action they describe, with polymorphic target references as the ERD accepts." `
            -Context "Audit records are required inside the capture and resolution transactions (M03, M04). Building the mechanism now keeps those milestones focused on their domains." `
            -Scope @("AuditEvent model per the ERD with workspace scope and actor", "AuditEvent.record service API used inside transactions", "Sensitive-value redaction on state deltas", "Tests asserting audit rows commit and roll back with their transaction") `
            -Acceptance @("An audited action rolled back leaves no audit row", "Redaction verified for a representative sensitive field", "Polymorphic target survives target deletion") `
            -Validation @("pytest transactional audit tests green under PostgreSQL") `
            -DocsImpact "None (implements accepted design)." `
            -OutOfScope @("No audit browsing UI", "No retention automation") `
            -Dependencies @("M02-02")) }

    # ----- M03 (8) -----
    [pscustomobject]@{ RoadmapId = "M03-01"; Milestone = "M03 - Integrations and Capture Slice 1"; ParentRoadmapId = "M03-TRACKER"
        Title = "Inbound envelope with provenance and replay protection"
        Labels = @("type:feature", "area:integrations", "priority:p0", "size:L"); DependsOnIds = @("M02-03")
        Body = (New-IssueBody -RoadmapId "M03-01" -Migration $true `
            -Objective "The InboundEnvelope aggregate: transport evidence persisted with provenance, payload hashing, envelope-level replay protection keyed on transport context, and explicit size and content-type limits." `
            -Context "INTEGRATIONS.md defines the envelope as the durability point of the bridge: what arrived, from where, safely received. It exists before and independently of any JobObservation, and envelope replay is a distinct duplicate layer from transport retry and source replay." `
            -Scope @("InboundEnvelope model with provider, transport, payload hash, and correlation identifiers", "Envelope replay identity combining workspace, provider or transport, external identity when available, and payload hash (payload hash alone is too broad: identical job text can legitimately arrive through different providers)", "Request body, payload size, content-type, and JSON-depth limits enforced at acceptance", "Rejection and quarantine states with preserved diagnostics") `
            -Acceptance @("Identical payload resubmitted through the same provider context references the existing envelope", "The same payload arriving through a different provider context creates a distinct envelope", "An oversized payload is rejected with a diagnostic envelope state, not an unhandled error", "Limits are named constants with tests at the boundary values") `
            -Validation @("pytest envelope constraint and limit tests green", "Replay tests cover same-context and cross-context cases under PostgreSQL") `
            -DocsImpact "INTEGRATIONS.md Data Model Status section updated from conceptual to implemented for the envelope; replay-identity definition recorded." `
            -OutOfScope @("No sync cursors (no pull source in slice 1)", "No object-storage offload yet; record the threshold as follow-up if payloads approach limits") `
            -Dependencies @("M02-03")) }
    [pscustomobject]@{ RoadmapId = "M03-02"; Milestone = "M03 - Integrations and Capture Slice 1"; ParentRoadmapId = "M03-TRACKER"
        Title = "Transport idempotency records"
        Labels = @("type:feature", "area:platform", "priority:p0", "size:M"); DependsOnIds = @()
        Body = (New-IssueBody -RoadmapId "M03-02" -Migration $true `
            -Objective "Transport idempotency: a retried request returns the original acceptance envelope; a reused key with a different payload is rejected; expiry semantics follow the recorded open-decision position." `
            -Context "The extension retries over unreliable networks. The glossary fixes the idempotency record as storing the acceptance envelope, not the terminal result, because operation state is mutable. ROADMAP sets expiry behaviour: expired keys may create a new operation, with source-replay protection as the independent domain layer." `
            -Scope @("IdempotencyRecord per the ERD with the four-part unique key", "Replay returns the stored acceptance with the operation reference", "Same key with a different request hash rejected with a conflict error", "Expiry honoured; post-expiry retry treated as new, documented in the error contract") `
            -Acceptance @("Retry with identical key and payload returns the original operation reference", "Key reuse with a different payload returns the documented conflict error", "Expired-key behaviour matches the recorded decision and is tested") `
            -Validation @("pytest idempotency contract tests green, including a concurrency test for simultaneous first requests") `
            -DocsImpact "ROADMAP.md Open Decisions: idempotency expiry marked resolved at implementation." `
            -OutOfScope @("No rollout beyond capture endpoints", "No idempotency on read endpoints") `
            -Dependencies @("None")) }
    [pscustomobject]@{ RoadmapId = "M03-03"; Milestone = "M03 - Integrations and Capture Slice 1"; ParentRoadmapId = "M03-TRACKER"
        Title = "Operations resource and status fragment"
        Labels = @("type:feature", "area:platform", "priority:p1", "size:M"); DependsOnIds = @()
        Body = (New-IssueBody -RoadmapId "M03-03" -Migration $true `
            -Objective "The Operation resource making asynchronous work addressable, with an HTMX status fragment for the web interface." `
            -Context "Capture returns an operation reference rather than blocking on resolution. Both the HTMX journey and the extension poll this resource." `
            -Scope @("Operation model per the ERD with status, progress, result reference, and error fields", "Service API for creating and advancing operations", "HTMX polling fragment rendering pending, processing, completed, failed, cancelled states", "Operation lookup scoped to the workspace") `
            -Acceptance @("An operation advances through states via the service only", "The HTMX fragment reflects state changes on poll", "Cross-workspace operation lookup is denied") `
            -Validation @("pytest operation lifecycle and authorization tests green") `
            -DocsImpact "None." `
            -OutOfScope @("No push updates or SSE; polling only", "No operation cancellation UI") `
            -Dependencies @("None")) }
    [pscustomobject]@{ RoadmapId = "M03-04"; Milestone = "M03 - Integrations and Capture Slice 1"; ParentRoadmapId = "M03-TRACKER"
        Title = "Versioned capture contract v1"
        Labels = @("type:architecture", "area:integrations", "priority:p1", "size:M"); DependsOnIds = @("M03-01")
        Body = (New-IssueBody -RoadmapId "M03-04" `
            -Objective "The provider-neutral careerops.job-capture.v1 contract: schema-validated, workspace-scoped, traceable to the original payload, produced by every adapter." `
            -Context "INTEGRATIONS.md fixes the anti-corruption rule: provider schemas stop at the adapter boundary; domain services receive only versioned internal contracts." `
            -Scope @("Typed contract definition with schema validation", "Adapter protocol producing the contract from an envelope", "HTMX, extension, and CSV adapters share this single contract", "Contract tests: valid, invalid, and version-mismatch cases") `
            -Acceptance @("A malformed contract is rejected before any domain service is called", "All three slice-1 adapters emit the identical contract shape", "Contract version is asserted, not assumed") `
            -Validation @("pytest contract validation suite green", "Architecture test: no domain module imports provider adapter types") `
            -DocsImpact "INTEGRATIONS.md Versioned Contracts section marked implemented for v1." `
            -OutOfScope @("No v2 or deprecation machinery (single version exists)", "No outbound contracts") `
            -Dependencies @("M03-01")) }
    [pscustomobject]@{ RoadmapId = "M03-05"; Milestone = "M03 - Integrations and Capture Slice 1"; ParentRoadmapId = "M03-TRACKER"
        Title = "HTMX manual capture journey"
        Labels = @("type:feature", "area:web", "priority:p0", "size:L"); DependsOnIds = @("M03-01", "M03-02", "M03-03", "M03-04")
        Body = (New-IssueBody -RoadmapId "M03-05" `
            -Objective "The complete first-party capture journey: authenticated form submission through envelope, contract, and observation handoff, returning an operation the user watches to a terminal state." `
            -Context "This is the first real browser journey and therefore activates the browser CI gates: Playwright, axe-core, HTML validation, keyboard navigation, runtime CSP collection, and console-error detection." `
            -Scope @("Capture form view calling the capture service with the same selector and context for full and partial responses", "Envelope acceptance, contract production, and observation-service handoff wired end-to-end", "Operation status fragment integrated into the journey", "Playwright critical journey, axe checks, HTML validation, and CSP runtime collection added to CI") `
            -Acceptance @("A user submits a URL and content and reaches a visible terminal operation state", "The journey is keyboard-complete with zero serious or critical axe violations", "Zero CSP violations and zero console errors across the tested journey", "Browser gates block merges from this issue onward") `
            -Validation @("Playwright journey green in CI", "axe, HTML validation, and CSP collection jobs green") `
            -DocsImpact "ENGINEERING_STANDARDS.md CI Gate table: browser gates marked active." `
            -OutOfScope @("No observation processing beyond acceptance (M04 owns normalization and resolution)", "No draft-saving or edit-after-submit") `
            -Dependencies @("M03-01", "M03-02", "M03-03", "M03-04")) }
    [pscustomobject]@{ RoadmapId = "M03-06"; Milestone = "M03 - Integrations and Capture Slice 1"; ParentRoadmapId = "M03-TRACKER"
        Title = "CSV batch import with import-run semantics"
        Labels = @("type:feature", "area:integrations", "priority:p1", "size:M"); DependsOnIds = @("M03-04")
        Body = (New-IssueBody -RoadmapId "M03-06" -Migration $true `
            -Objective "CSV batch capture with an ImportRun recording received, accepted, replayed, rejected, and failed counts per run." `
            -Context "CSV is the third slice-1 transport and the only batch path, exercising the import-run semantics INTEGRATIONS.md defines for operational visibility." `
            -Scope @("CSV upload with size, row-count, and column validation", "Per-row envelope and contract production with per-row failure isolation", "ImportRun model tracking counts and terminal status", "Import status surfaced through the Operation resource") `
            -Acceptance @("A mixed-validity CSV yields correct per-category counts", "One bad row does not abort the run", "Replayed rows are counted as replayed, not accepted twice") `
            -Validation @("pytest import-run tests with a mixed fixture file green") `
            -DocsImpact "None." `
            -OutOfScope @("No Excel or JSON import", "No column-mapping UI; a documented fixed layout") `
            -Dependencies @("M03-04")) }
    [pscustomobject]@{ RoadmapId = "M03-07"; Milestone = "M03 - Integrations and Capture Slice 1"; ParentRoadmapId = "M03-TRACKER"
        Title = "Browser-extension capture API"
        Labels = @("type:feature", "area:integrations", "priority:p1", "size:L"); DependsOnIds = @("M03-02", "M03-04")
        Body = (New-IssueBody -RoadmapId "M03-07" -Migration $true `
            -Objective "The versioned DRF capture endpoint for the extension: workspace-scoped revocable credentials, the structured error envelope, idempotent creation, operation status, and OpenAPI with generated TypeScript types." `
            -Context "The extension is the first real DRF consumer and the reason DRF exists. This issue activates the API gates: OpenAPI generation and validation, generated-types freshness, error-contract and idempotency contract tests." `
            -Scope @("DRF foundation and the /api/v1/ capture endpoint reusing the capture service", "Workspace-scoped, revocable extension credentials with explicit expiry, rotation, last-used tracking, and auditability; do not adopt generic permanent DRF TokenAuthentication tokens", "Structured error envelope with field-level codes and a request identifier", "OpenAPI schema generation, validation, and TypeScript type generation in CI", "Idempotency-Key handling wired to M03-02") `
            -Acceptance @("A capture request with a valid credential succeeds and returns an operation reference", "A revoked or expired credential is rejected and the rejection is audited", "Validation failures return the documented envelope with field codes", "Stale generated types fail CI", "Retried capture returns the original operation") `
            -Validation @("API contract test suite green, including credential revocation and expiry cases", "OpenAPI and type-generation CI jobs green") `
            -DocsImpact "ENGINEERING_STANDARDS.md CI Gate table: API gates marked active. ARCHITECTURE.md External Clients status. SECURITY_MODEL.md extension-credential row." `
            -OutOfScope @("No mobile client and no additional external consumers", "No API scopes (single consumer; mobile gate M10-01)") `
            -Dependencies @("M03-02", "M03-04")) }
    [pscustomobject]@{ RoadmapId = "M03-08"; Milestone = "M03 - Integrations and Capture Slice 1"; ParentRoadmapId = "M03-TRACKER"
        Title = "Browser-extension capture client"
        Labels = @("type:feature", "area:integrations", "priority:p1", "size:L"); DependsOnIds = @("M03-07")
        Body = (New-IssueBody -RoadmapId "M03-08" `
            -Objective "The actual browser-extension client: explicit user-triggered capture of the current page URL, title, and selected text, submitted through the versioned API with operation-status feedback, packaged and runnable locally." `
            -Context "The API alone does not prove browser-extension capture as one of the three slice-1 transports. The extension is part of CareerOps and lives in the repository client structure; it is the consumer that makes the DRF contract real." `
            -Scope @("Extension manifest and entry points in the repository client structure", "Explicit user-triggered capture only: current-page URL, page title, and user-selected text", "Submission through the generated typed client with an idempotency key generated before send", "Operation-status feedback in the extension UI", "Authentication-failure and contract-error handling with clear user-facing states", "Contract tests against the generated API schema", "Local development and packaging instructions", "No browsing-history collection, no background crawling, no automatic scraping") `
            -Acceptance @("A user explicitly triggers capture and sees the operation reach a terminal state in the extension", "The extension collects nothing without an explicit user action", "An expired or revoked credential produces a clear re-authentication state, not a silent failure", "Contract tests fail when the client drifts from the generated schema", "The extension builds and loads locally following the documented instructions") `
            -Validation @("Extension contract test suite green in CI", "Manual install-and-capture walkthrough recorded in the closing comment") `
            -DocsImpact "INTEGRATIONS.md Browser-extension capture section marked implemented; README repository structure updated with the client location." `
            -OutOfScope @("No store publication in this issue", "No mobile client", "No capture of pages the user did not explicitly act on") `
            -Dependencies @("M03-07")) }

    # ----- M04 (6) -----
    [pscustomobject]@{ RoadmapId = "M04-01"; Milestone = "M04 - Job Registry and Identity Resolution"; ParentRoadmapId = "M04-TRACKER"
        Title = "JobObservation aggregate and source-replay detection"
        Labels = @("type:feature", "area:job-registry", "priority:p0", "size:L"); DependsOnIds = @("M03-01")
        Body = (New-IssueBody -RoadmapId "M04-01" -Migration $true `
            -Objective "The immutable JobObservation aggregate: evidence fields frozen after acceptance, the processing state machine, and exact source-replay detection via the unique index from the ERD." `
            -Context "The observation is the immutable evidence layer of the domain, distinct from the transport envelope. The glossary fixes the split: the observed fact is immutable; processing knowledge advances. Source replay is a domain-layer duplicate condition independent of transport idempotency." `
            -Scope @("JobObservation model with immutable evidence fields and mutable state", "Immutability enforced: a service-level guard plus a test that updates to evidence fields fail", "Exact source-replay detection using workspace, source, source identity, and payload hash", "State machine transitions validated in the service; invalid transitions raise", "Acceptance service consuming the capture contract, writing audit and outbox rows in-transaction") `
            -Acceptance @("Replayed source content references the existing observation", "Evidence-field mutation attempts fail under test", "Invalid state transitions are rejected", "Observation acceptance commits observation, audit, and outbox rows atomically") `
            -Validation @("pytest constraint, immutability, and state-machine tests green under PostgreSQL") `
            -DocsImpact "None (implements accepted design)." `
            -OutOfScope @("No normalization (M04-04)", "No resolution (M04-05)") `
            -Dependencies @("M03-01")) }
    [pscustomobject]@{ RoadmapId = "M04-02"; Milestone = "M04 - Job Registry and Identity Resolution"; ParentRoadmapId = "M04-TRACKER"
        Title = "Transactional outbox and dispatcher"
        Labels = @("type:feature", "area:platform", "priority:p0", "size:L"); DependsOnIds = @()
        Body = (New-IssueBody -RoadmapId "M04-02" -Migration $true `
            -Objective "The transactional outbox: events written in the producing transaction, published by a dispatcher whose durable polling is the correctness mechanism and whose on_commit nudge is a latency optimisation only." `
            -Context "ARCHITECTURE.md fixes the rule: no durable dispatch before commit. The outbox closes the dual-write gap between committed state and message publication for every later context integration." `
            -Scope @("OutboxEvent model per the ERD with versioned topics and attempt tracking", "Dispatcher with durable polling, publish confirmation, and attempt increment", "on_commit nudge wired but non-essential: a dropped-nudge test still delivers", "Delivery, redelivery, and rollback tests (a rolled-back transaction publishes nothing)") `
            -Acceptance @("An event in a rolled-back transaction is never published", "A killed nudge still results in delivery via polling", "Redelivery after dispatcher restart does not duplicate downstream effects (consumer idempotency contract documented)") `
            -Validation @("pytest outbox delivery suite green, including the dropped-nudge and rollback cases") `
            -DocsImpact "ENGINEERING_STANDARDS.md CI Gate table: outbox delivery gate active." `
            -OutOfScope @("No RabbitMQ topology beyond what dispatch requires (M04-03)", "No customer-facing webhooks") `
            -Dependencies @("None")) }
    [pscustomobject]@{ RoadmapId = "M04-03"; Milestone = "M04 - Job Registry and Identity Resolution"; ParentRoadmapId = "M04-TRACKER"
        Title = "Celery and RabbitMQ workflow foundation"
        Labels = @("type:feature", "area:platform", "priority:p1", "size:M"); DependsOnIds = @("M04-02")
        Body = (New-IssueBody -RoadmapId "M04-03" `
            -Objective "The asynchronous execution foundation: Celery on RabbitMQ with idempotent, time-bounded, retried, and trace-propagated tasks, routed by workload type." `
            -Context "Normalization and resolution run asynchronously. ENGINEERING_STANDARDS.md fixes task properties: idempotent, retry-safe, time-bounded, observable, explicit about terminal failure." `
            -Scope @("Celery app configuration with the RabbitMQ broker in compose and CI", "Task base with idempotency-by-argument convention, hard and soft limits, and retry backoff", "Trace-context propagation from the originating request into tasks", "Queue routing for registry workloads", "Worker service in compose") `
            -Acceptance @("A task retries with backoff and reaches an observable terminal failure state", "Trace identifiers connect a request to its task execution in logs", "Duplicate task delivery is a no-op for an already-processed argument set") `
            -Validation @("pytest task idempotency, retry, and routing tests green with a real broker in CI") `
            -DocsImpact "ENGINEERING_STANDARDS.md CI Gate table: Celery reliability gates active." `
            -OutOfScope @("No Flower or dashboarding (M09)", "No queue-per-context proliferation without operational evidence") `
            -Dependencies @("M04-02")) }
    [pscustomobject]@{ RoadmapId = "M04-04"; Milestone = "M04 - Job Registry and Identity Resolution"; ParentRoadmapId = "M04-TRACKER"
        Title = "Versioned normalization with Python baseline"
        Labels = @("type:feature", "area:job-registry", "priority:p1", "size:M"); DependsOnIds = @("M04-01", "M04-03")
        Body = (New-IssueBody -RoadmapId "M04-04" -Migration $true `
            -Objective "JobNormalization records: versioned interpretations produced asynchronously by a Python baseline normalizer, unique per workspace, observation, and normalizer version." `
            -Context "The glossary fixes normalization as versioned interpretation that never mutates evidence. The Python implementation is also the benchmark baseline any future Rust proposal must beat (gate M10-02)." `
            -Scope @("JobNormalization model with the uniqueness and identity fingerprint from the ERD", "Python normalizer: title, company, location, and salary extraction with warnings", "Celery task consuming observation-accepted outbox events", "Reprocessing path: a new normalizer version creates a new record") `
            -Acceptance @("Two normalizer versions coexist for one observation", "Parsing failures produce a failed observation state with diagnostics, not silent loss", "The baseline records throughput on a fixture set for future benchmark comparison") `
            -Validation @("pytest normalization rule and versioning tests green", "Fixture-set timing recorded in the issue on completion") `
            -DocsImpact "None." `
            -OutOfScope @("No LLM extraction", "No Rust (benchmark-gated, M10-02)") `
            -Dependencies @("M04-01", "M04-03")) }
    [pscustomobject]@{ RoadmapId = "M04-05"; Milestone = "M04 - Job Registry and Identity Resolution"; ParentRoadmapId = "M04-TRACKER"
        Title = "Identity resolution transaction"
        Labels = @("type:feature", "area:job-registry", "priority:p0", "size:L"); DependsOnIds = @("M04-04")
        Body = (New-IssueBody -RoadmapId "M04-05" -Migration $true `
            -Objective "The atomic identity-resolution service: advisory-lock bucket, candidate recheck, append-only JobResolution, CanonicalJob creation or traceable enrichment, observation terminal state, audit, and outbox, in one short transaction, with ambiguous as a first-class outcome." `
            -Context "ARCHITECTURE.md specifies this as the one workflow permitted to coordinate multiple aggregates atomically, because the observation outcome, resolution decision, and canonical identity must never contradict one another. The recheck inside the lock is the correctness mechanism." `
            -Scope @("Resolution service with a transaction-scoped PostgreSQL advisory lock on workspace and resolution bucket", "Candidate recheck inside the protected section", "JobResolution append with outcome, score, evidence, algorithm version, and supersession support", "CanonicalJob create or enrich with the versioned changed-fields event payload", "Ambiguous outcome: structured candidate evidence recorded, no canonical association forced", "Concurrency test: two workers, same opportunity, one canonical job") `
            -Acceptance @("Concurrent resolution of the same opportunity produces exactly one canonical job", "An ambiguous result preserves the observation with structured candidate scores", "Every canonical creation has a recorded originating resolution in the same transaction", "Canonical enrichment emits the changed-fields event with before and after values and a reason") `
            -Validation @("pytest concurrency test with real PostgreSQL advisory locks green", "Resolution outcome matrix tests green for all five outcomes") `
            -DocsImpact "ARCHITECTURE.md Architecture Status: resolution transaction marked implemented." `
            -OutOfScope @("No canonical merge workflow (recorded as eventually necessary)", "No requirement extraction (M06-01)") `
            -Dependencies @("M04-04")) }
    [pscustomobject]@{ RoadmapId = "M04-06"; Milestone = "M04 - Job Registry and Identity Resolution"; ParentRoadmapId = "M04-TRACKER"
        Title = "Capture slice telemetry and failure validation"
        Labels = @("type:test", "area:observability", "priority:p1", "size:M"); DependsOnIds = @("M04-05")
        Body = (New-IssueBody -RoadmapId "M04-06" `
            -Objective "End-to-end validation of the capture slice: trace-complete telemetry from request to resolution outcome, structured logs with correlation identifiers, baseline metrics, and failure-path tests." `
            -Context "ROADMAP Milestone 2 closes with logs, metrics, traces, and failure tests. This issue proves the slice as a system rather than as parts." `
            -Scope @("OpenTelemetry spans connecting request, envelope, observation, normalization task, and resolution transaction", "Structured logs carrying request, correlation, workspace, and trace identifiers with secret redaction", "Prometheus counters for envelopes received, accepted, rejected, and replayed, and for resolution outcomes", "Failure tests: normalization failure, resolution failure, broker unavailability behaviour") `
            -Acceptance @("One trace identifier follows a capture from HTTP request to resolution outcome", "Each failure path lands in an observable terminal state", "Metrics expose the INTEGRATIONS.md observability counters for slice-1 flows") `
            -Validation @("Trace-propagation test green", "Failure-injection tests green") `
            -DocsImpact "ROADMAP.md Milestone 2 outcome verified; INTEGRATIONS.md Observability marked implemented for slice 1." `
            -OutOfScope @("No dashboards or alert rules (M09-02)", "No SLO definitions yet") `
            -Dependencies @("M04-05")) }

    # ----- M05 (4) -----
    [pscustomobject]@{ RoadmapId = "M05-01"; Milestone = "M05 - Candidate Evidence and Provenance"; ParentRoadmapId = "M05-TRACKER"
        Title = "Candidate profile and versioned evidence documents"
        Labels = @("type:feature", "area:candidate-evidence", "priority:p1", "size:M"); DependsOnIds = @("M02-03")
        Body = (New-IssueBody -RoadmapId "M05-01" -Migration $true `
            -Objective "CandidateProfile and EvidenceDocument aggregates with versioning and supersession per the ERD." `
            -Context "Evidence is the substrate of matching and later retrieval. Versioning from the start means matching results can state exactly which evidence version they used." `
            -Scope @("CandidateProfile unique per workspace and user", "EvidenceDocument with type, content hash, version, and supersession", "Create and supersede services with audit", "Constraint tests for uniqueness and supersession chains") `
            -Acceptance @("Superseding a document preserves the prior version", "Document types match the evidence_type enum from the ERD", "All records workspace-scoped and selector-authorized") `
            -Validation @("pytest constraint and supersession tests green") `
            -DocsImpact "None." `
            -OutOfScope @("No file upload parsing (documents accept text content in this issue)", "No chunking (M05-02)") `
            -Dependencies @("M02-03")) }
    [pscustomobject]@{ RoadmapId = "M05-02"; Milestone = "M05 - Candidate Evidence and Provenance"; ParentRoadmapId = "M05-TRACKER"
        Title = "Evidence chunks with chunker versioning"
        Labels = @("type:feature", "area:candidate-evidence", "priority:p1", "size:M"); DependsOnIds = @("M05-01")
        Body = (New-IssueBody -RoadmapId "M05-02" -Migration $true `
            -Objective "Workspace-scoped EvidenceChunk records with sequence uniqueness and chunker versioning, so retrieval and citation have a stable target and granularity is revisable." `
            -Context "Chunk granularity is a recorded open decision resolved by retrieval tests (M07). Versioning the chunker lets granularity change without destroying existing citations." `
            -Scope @("EvidenceChunk model per the ERD including denormalized workspace scope", "Initial deterministic chunker with a recorded version", "Re-chunking path producing new-version chunks alongside old", "Sequence uniqueness per document tested") `
            -Acceptance @("Chunks carry workspace scope directly (no join required for tenant filtering)", "Two chunker versions coexist for one document", "Sequence collisions rejected by the database") `
            -Validation @("pytest chunking and constraint tests green") `
            -DocsImpact "ROADMAP.md Open Decisions: chunk size remains open, resolution point unchanged (M07 retrieval tests)." `
            -OutOfScope @("No embeddings", "No retrieval (M07-02)") `
            -Dependencies @("M05-01")) }
    [pscustomobject]@{ RoadmapId = "M05-03"; Milestone = "M05 - Candidate Evidence and Provenance"; ParentRoadmapId = "M05-TRACKER"
        Title = "Provenance taxonomy enforcement"
        Labels = @("type:feature", "area:candidate-evidence", "priority:p1", "size:M"); DependsOnIds = @("M05-01")
        Body = (New-IssueBody -RoadmapId "M05-03" -Migration $true `
            -Objective "The provenance taxonomy on evidence: professional experience, project experience, education, demonstrated knowledge, user assertion, and verified external evidence, constrained at the database and surfaced in services." `
            -Context "INTEGRATIONS.md and the glossary fix this distinction as the upstream protection against later systems presenting project work as professional experience. It must arrive with the evidence model, not be retrofitted at generation time." `
            -Scope @("Provenance field with constrained values on evidence documents", "Service-level requirement that provenance is explicit on creation", "Selector vocabulary for provenance-filtered reads", "Tests asserting project evidence is never returned as professional") `
            -Acceptance @("Evidence cannot be created without a provenance classification", "A provenance-filtered selector returns only the requested classes", "The professional-versus-project boundary has an explicit regression test") `
            -Validation @("pytest provenance constraint and selector tests green") `
            -DocsImpact "DOMAIN_GLOSSARY.md Candidate evidence entry marked implemented." `
            -OutOfScope @("No verification workflow for the verified class (recorded as future)", "No connected-account imports") `
            -Dependencies @("M05-01")) }
    [pscustomobject]@{ RoadmapId = "M05-04"; Milestone = "M05 - Candidate Evidence and Provenance"; ParentRoadmapId = "M05-TRACKER"
        Title = "Evidence export and deletion boundaries"
        Labels = @("type:security", "area:candidate-evidence", "priority:p2", "size:M"); DependsOnIds = @("M05-01")
        Body = (New-IssueBody -RoadmapId "M05-04" `
            -Objective "User-controlled export and deletion of candidate evidence with audit records and defined cascade behaviour." `
            -Context "ROADMAP Milestone 3 lists export and deletion boundaries. Evidence is the most personal data in the system; its lifecycle must be explicit before matching results start referencing it." `
            -Scope @("Workspace evidence export via the Operation resource using iterator-based streaming", "Deletion service with defined behaviour for chunks and later match references", "Audit records for export and deletion", "Deletion boundary documented against future match-evidence references") `
            -Acceptance @("An export operation completes and is downloadable by an authorized member", "Deletion removes evidence and chunks and is audited", "Large-corpus export does not materialize the full set in memory") `
            -Validation @("pytest export and deletion tests green, including memory behaviour on a large fixture") `
            -DocsImpact "SECURITY_MODEL.md Audit and Retention verification row." `
            -OutOfScope @("No account-level deletion (workspace evidence only)", "No retention automation") `
            -Dependencies @("M05-01")) }
    # ----- M06 (5) -----
    [pscustomobject]@{ RoadmapId = "M06-01"; Milestone = "M06 - Deterministic Opportunity Matching"; ParentRoadmapId = "M06-TRACKER"
        Title = "Versioned requirement extraction"
        Labels = @("type:feature", "area:matching", "priority:p1", "size:M"); DependsOnIds = @("M04-05")
        Body = (New-IssueBody -RoadmapId "M06-01" -Migration $true `
            -Objective "Deterministic, versioned JobRequirement extraction from canonical jobs, consuming canonical outbox events." `
            -Context "Requirements are versioned interpretations, like normalizations: extractors improve without destroying earlier results, and match results state which extraction version they scored against." `
            -Scope @("JobRequirement model with requirement type, importance, and extraction version", "Deterministic extractor from canonical description and structured fields", "Celery consumer for canonical-job created and updated events", "Re-extraction path creating new-version requirements") `
            -Acceptance @("Requirements regenerate on canonical updates without deleting prior versions", "Extraction is deterministic: identical input yields identical requirements", "Consumer is idempotent under event redelivery") `
            -Validation @("pytest extraction determinism and consumer idempotency tests green") `
            -DocsImpact "None." `
            -OutOfScope @("No LLM extraction", "No scoring (M06-02)") `
            -Dependencies @("M04-05")) }
    [pscustomobject]@{ RoadmapId = "M06-02"; Milestone = "M06 - Deterministic Opportunity Matching"; ParentRoadmapId = "M06-TRACKER"
        Title = "Rule-based scoring components"
        Labels = @("type:feature", "area:matching", "priority:p1", "size:L"); DependsOnIds = @("M06-01", "M05-02")
        Body = (New-IssueBody -RoadmapId "M06-02" -Migration $true `
            -Objective "The deterministic OpportunityMatch: rule-based score components producing supported, partially supported, unsupported, and insufficient-evidence outcomes per requirement, with a versioned breakdown." `
            -Context "The score must be inspectable and reproducible. Insufficient evidence is a valid outcome; the system does not invent coverage to complete a match. Generation later explains this score; it never produces it." `
            -Scope @("OpportunityMatch model with scoring version, total, and component breakdown", "Per-requirement outcome computation against provenance-aware evidence", "Explicit component weights recorded in the breakdown", "Match service triggered by requirement or evidence changes") `
            -Acceptance @("Identical inputs yield identical scores across runs", "Insufficient evidence appears as its own outcome, never as zero-score unsupported", "Project-provenance evidence contributes according to explicit, tested rules distinct from professional evidence") `
            -Validation @("pytest scoring matrix tests green across the four outcomes") `
            -DocsImpact "None." `
            -OutOfScope @("No semantic similarity (M07)", "No explanation text (M07-04)") `
            -Dependencies @("M05-02", "M06-01")) }
    [pscustomobject]@{ RoadmapId = "M06-03"; Milestone = "M06 - Deterministic Opportunity Matching"; ParentRoadmapId = "M06-TRACKER"
        Title = "Chunk-level match evidence"
        Labels = @("type:feature", "area:matching", "priority:p1", "size:M"); DependsOnIds = @("M06-02")
        Body = (New-IssueBody -RoadmapId "M06-03" -Migration $true `
            -Objective "MatchEvidence records citing evidence chunks per requirement, with the unique match, requirement, and chunk constraint from the ERD." `
            -Context "Chunk-level citation is what makes a match explainable: the supporting passage is explicit and the parent document derivable. The ERD deliberately collapsed this to a single non-null chunk reference." `
            -Scope @("MatchEvidence model with support level, score, and explanation text field", "Population during scoring with duplicate-citation protection", "Selector returning the citations of a requirement with chunk content, budgeted") `
            -Acceptance @("Duplicate citations for the same match, requirement, and chunk are rejected by the database", "Every supported or partial outcome carries at least one citation", "Citation reads respect an explicit query budget") `
            -Validation @("pytest citation constraint and budget tests green") `
            -DocsImpact "None." `
            -OutOfScope @("No generated explanation prose (M07-04)") `
            -Dependencies @("M06-02")) }
    [pscustomobject]@{ RoadmapId = "M06-04"; Milestone = "M06 - Deterministic Opportunity Matching"; ParentRoadmapId = "M06-TRACKER"
        Title = "Recalculation and supersession"
        Labels = @("type:feature", "area:matching", "priority:p2", "size:M"); DependsOnIds = @("M06-02")
        Body = (New-IssueBody -RoadmapId "M06-04" `
            -Objective "Match recalculation on evidence, requirement, or scoring-version change, superseding rather than silently replacing prior results." `
            -Context "Supersession keeps match history honest: a user can see that a score changed and why, matching the append-only pattern used for resolutions." `
            -Scope @("Supersession field and service path on OpportunityMatch", "Recalculation triggers from evidence and requirement events", "Selector defaulting to current matches with history available") `
            -Acceptance @("A recalculated match links to and supersedes its predecessor", "No code path updates a match score in place", "Event-triggered recalculation is idempotent") `
            -Validation @("pytest supersession chain tests green") `
            -DocsImpact "None." `
            -OutOfScope @("No scheduled bulk recalculation") `
            -Dependencies @("M06-02")) }
    [pscustomobject]@{ RoadmapId = "M06-05"; Milestone = "M06 - Deterministic Opportunity Matching"; ParentRoadmapId = "M06-TRACKER"
        Title = "Matching evaluation fixtures"
        Labels = @("type:test", "area:matching", "priority:p1", "size:M"); DependsOnIds = @("M06-02")
        Body = (New-IssueBody -RoadmapId "M06-05" `
            -Objective "A labelled fixture set encoding the hard matching boundary cases, run in CI as the regression contract of the deterministic baseline and the seed for the M07 retrieval gold set." `
            -Context "ROADMAP Milestone 4 requires evaluation fixtures. The boundary cases that matter are exactly the ones the glossary protects: project-versus-professional provenance and insufficient evidence as a positive result." `
            -Scope @("Fixture corpus: requirements paired with evidence and expected outcomes", "Boundary cases: project-only evidence against professional requirements, genuinely absent evidence, partial coverage", "CI job running the fixture matrix", "Fixture documentation stating what each case protects") `
            -Acceptance @("The fixture matrix runs in CI and blocks merges on regression", "Provenance and insufficient-evidence boundary cases are present and passing", "Fixtures are honest: no case is tuned to pass by weakening the expectation") `
            -Validation @("CI fixture job green; a deliberately broken rule fails the matrix") `
            -DocsImpact "None." `
            -OutOfScope @("No retrieval metrics (recall and precision belong to M07-01)") `
            -Dependencies @("M06-02")) }

    # ----- M07 (4) -----
    [pscustomobject]@{ RoadmapId = "M07-01"; Milestone = "M07 - Retrieval and Evidence-Grounded Explanation"; ParentRoadmapId = "M07-TRACKER"
        Title = "Labelled retrieval evaluation dataset"
        Labels = @("type:feature", "area:matching", "priority:p1", "size:M"); DependsOnIds = @("M06-05")
        Body = (New-IssueBody -RoadmapId "M07-01" `
            -Objective "The gold-standard retrieval dataset: requirements mapped to expected-relevant and expected-irrelevant evidence chunks, with a recall and precision measurement harness, before any retrieval tuning." `
            -Context "ROADMAP Milestone 5 activates retrieval only after a labelled evaluation set exists. The set defines what working means; retrieval tuned by inspection is the failure mode this ordering prevents." `
            -Scope @("Gold-set schema: query, relevant chunks, irrelevant chunks, allowed and forbidden conclusions", "Hand-labelled initial corpus seeded from M06-05 fixtures", "Measurement harness for recall and precision at k", "Honest qualification recorded: set size and single-corpus scope") `
            -Acceptance @("The harness produces recall and precision numbers for any retriever", "Metrics reports carry the dataset-size qualification", "The set includes at least one insufficient-evidence query whose correct answer is nothing") `
            -Validation @("Harness run against a trivial keyword retriever produces sane baseline numbers") `
            -DocsImpact "None." `
            -OutOfScope @("No retriever implementation (M07-02)", "No LLM-generated labels") `
            -Dependencies @("M06-05")) }
    [pscustomobject]@{ RoadmapId = "M07-02"; Milestone = "M07 - Retrieval and Evidence-Grounded Explanation"; ParentRoadmapId = "M07-TRACKER"
        Title = "Full-text retrieval with workspace filtering"
        Labels = @("type:feature", "area:matching", "priority:p1", "size:L"); DependsOnIds = @("M07-01")
        Body = (New-IssueBody -RoadmapId "M07-02" -Migration $true `
            -Objective "PostgreSQL full-text retrieval over evidence chunks with workspace and metadata filtering applied before ranking, measured against the gold set." `
            -Context "PostgreSQL FTS is the accepted first retriever; pgvector enters only if it demonstrates value beyond this (M07-03). Workspace filtering precedes ranking: the retriever never sees the chunks of another tenant." `
            -Scope @("Search vector and GIN index on chunk content", "Retrieval selector: workspace and provenance filters, then ranking", "RetrievalRun record for auditability of what was retrieved and why", "Gold-set measurement wired into CI as an informational job") `
            -Acceptance @("Retrieval respects workspace scope structurally (filter precedes rank, tested)", "Recall and precision at 5 recorded against the gold set with qualification", "Query plan reviewed for the indexed search path") `
            -Validation @("Gold-set harness numbers recorded in the issue", "EXPLAIN output for the search query attached") `
            -DocsImpact "ARCHITECTURE.md Architecture Status: retrieval row updated." `
            -OutOfScope @("No pgvector (M07-03 decides)", "No generation (M07-04)") `
            -Dependencies @("M07-01")) }
    [pscustomobject]@{ RoadmapId = "M07-03"; Milestone = "M07 - Retrieval and Evidence-Grounded Explanation"; ParentRoadmapId = "M07-TRACKER"
        Title = "pgvector adoption spike"
        Labels = @("type:spike", "area:matching", "priority:p2", "size:M"); DependsOnIds = @("M07-02")
        Body = (New-IssueBody -RoadmapId "M07-03" `
            -Objective "A time-boxed, measured comparison of hybrid FTS-plus-pgvector retrieval against the FTS baseline on the gold set, closing with an adopt or re-defer decision recorded in TECHNOLOGY_DECISIONS.md." `
            -Context "TECHNOLOGY_DECISIONS.md defers pgvector until retrieval evaluation shows value beyond full-text search. This spike is that evaluation, with the decision criteria written before the work." `
            -Scope @("Pre-committed adoption threshold recorded in this issue before implementation begins", "Embedding of the gold-set corpus with a versioned model", "Hybrid retrieval measured with the M07-01 harness", "Decision record: adopt with entry conditions, or re-defer with numbers") `
            -Acceptance @("The adoption threshold was written down before measurement", "Both retrievers measured on the identical gold set", "TECHNOLOGY_DECISIONS.md updated with the outcome and its evidence") `
            -Validation @("Harness outputs for both retrievers attached to the closing comment") `
            -DocsImpact "TECHNOLOGY_DECISIONS.md pgvector row; ROADMAP.md if adopted." `
            -OutOfScope @("No dedicated vector database under any outcome", "No production embedding pipeline unless adopted") `
            -Dependencies @("M07-02")) }
    [pscustomobject]@{ RoadmapId = "M07-04"; Milestone = "M07 - Retrieval and Evidence-Grounded Explanation"; ParentRoadmapId = "M07-TRACKER"
        Title = "Evidence-grounded explanation with citations"
        Labels = @("type:feature", "area:matching", "priority:p2", "size:L"); DependsOnIds = @("M07-02")
        Body = (New-IssueBody -RoadmapId "M07-04" -Migration $true `
            -Objective "Advisory explanation generation over retrieved evidence: claim-level citations, conservative support classification, unsupported-claim rejection from any user-facing draft, and mandatory human review." `
            -Context "SECURITY_MODEL.md fixes the boundary: generated output never authorizes, scores, resolves identity, or writes domain state; a successful prompt injection changes a reviewed suggestion, not a database row. The blast radius is architectural, not textual." `
            -Scope @("Generation and citation records per the audit-trail chain from the ERD", "Claim classification with a conservative default toward unsupported", "Schema validation of model output; out-of-schema responses rejected", "Human-review gate before any explanation reaches a draft or export", "Unsupported-claim rate metric") `
            -Acceptance @("Every claim in an explanation carries a citation or an unsupported classification", "Unsupported claims are structurally excluded from draft output", "Out-of-schema model output is rejected and observable", "No code path allows generated output to write domain state") `
            -Validation @("pytest schema-rejection and claim-classification tests green", "Architecture test: the generation module has no import path to domain write services") `
            -DocsImpact "SECURITY_MODEL.md External Content and Generation verification row." `
            -OutOfScope @("No application-letter drafting product feature (this is the mechanism)", "No autonomy: generation never triggers actions") `
            -Dependencies @("M07-02")) }

    # ----- M08 (4) -----
    [pscustomobject]@{ RoadmapId = "M08-01"; Milestone = "M08 - Application Operations"; ParentRoadmapId = "M08-TRACKER"
        Title = "Application aggregate with append-only transitions"
        Labels = @("type:feature", "area:application-ops", "priority:p1", "size:L"); DependsOnIds = @("M04-05")
        Body = (New-IssueBody -RoadmapId "M08-01" -Migration $true `
            -Objective "The Application aggregate: valid state transitions only, append-only transition history as the authority, and current status updated exclusively in the same transaction as its transition." `
            -Context "The glossary fixes the pattern: history is authoritative; current status is a read optimization that may only be written by the service that appends the transition. A status write without a transition row is the corruption this design prevents." `
            -Scope @("Application and ApplicationTransition models per the ERD", "Transition service validating the state machine and writing both records atomically", "Architecture test: no code path writes current status outside the transition service", "Audit and outbox events on transitions") `
            -Acceptance @("Invalid transitions are rejected with domain exceptions", "Current status always equals the latest transition target under a consistency test", "Transition history is append-only; no update or delete path exists") `
            -Validation @("pytest state-machine and consistency tests green", "Concurrency test: simultaneous transitions on one application serialize correctly") `
            -DocsImpact "None." `
            -OutOfScope @("No pipeline UI (M08-04)", "No reminders or notifications") `
            -Dependencies @("M04-05")) }
    [pscustomobject]@{ RoadmapId = "M08-02"; Milestone = "M08 - Application Operations"; ParentRoadmapId = "M08-TRACKER"
        Title = "Interviews, contacts, and follow-ups"
        Labels = @("type:feature", "area:application-ops", "priority:p2", "size:M"); DependsOnIds = @("M08-01")
        Body = (New-IssueBody -RoadmapId "M08-02" -Migration $true `
            -Objective "Interview, contact, and follow-up records attached to applications, with ownership, due and completion times." `
            -Context "ROADMAP Milestone 6 scope. These records feed conversion analytics (M09-03) and are the substrate for any later outbound calendar integration, which remains deferred." `
            -Scope @("Follow-up model per the ERD with assignment and completion", "Interview and contact records scoped to applications", "Services with audit; selectors with budgets", "Due and overdue selector vocabulary") `
            -Acceptance @("A follow-up completes exactly once and is audited", "Overdue selection is correct across timezone boundaries", "All reads selector-authorized and budget-tested") `
            -Validation @("pytest lifecycle and timezone tests green") `
            -DocsImpact "None." `
            -OutOfScope @("No calendar synchronization (deferred, outbound-first when it arrives)", "No notification delivery") `
            -Dependencies @("M08-01")) }
    [pscustomobject]@{ RoadmapId = "M08-03"; Milestone = "M08 - Application Operations"; ParentRoadmapId = "M08-TRACKER"
        Title = "CV and evidence version linkage"
        Labels = @("type:feature", "area:application-ops", "priority:p2", "size:M"); DependsOnIds = @("M08-01", "M05-01")
        Body = (New-IssueBody -RoadmapId "M08-03" -Migration $true `
            -Objective "Applications record exactly which CV and evidence document versions were used, surviving later supersession of those documents." `
            -Context "Which CV version produced interviews is a core analytics question (ROADMAP Milestone 7). It is only answerable if the linkage points at immutable versions, not at current documents." `
            -Scope @("Version-pinned references from applications to evidence documents", "Linkage set at application creation or preparation, audited on change", "Selector answering which applications used a given version") `
            -Acceptance @("Superseding a CV does not alter what an existing application records", "The version-usage selector is budget-tested") `
            -Validation @("pytest linkage immutability tests green") `
            -DocsImpact "None." `
            -OutOfScope @("No performance analytics computation (M09-03)") `
            -Dependencies @("M05-01", "M08-01")) }
    [pscustomobject]@{ RoadmapId = "M08-04"; Milestone = "M08 - Application Operations"; ParentRoadmapId = "M08-TRACKER"
        Title = "Application pipeline HTMX journey"
        Labels = @("type:feature", "area:web", "priority:p2", "size:L"); DependsOnIds = @("M08-01")
        Body = (New-IssueBody -RoadmapId "M08-04" `
            -Objective "The pipeline interface: applications by stage with keyboard-complete stage transitions through HTMX, one view serving full and partial renders." `
            -Context "The pipeline is the daily-use surface of application operations. Standards apply in full: same selector for both render targets, keyboard completeness, TypeScript only if drag-and-drop accessibility genuinely requires it." `
            -Scope @("Pipeline view grouping applications by status with budgeted selectors", "Stage-transition interaction calling the M08-01 service, HTMX-swapped", "Keyboard-operable transition controls; drag-and-drop only as progressive enhancement with an ADR if TypeScript is introduced", "Playwright journey and axe coverage extended") `
            -Acceptance @("A stage change round-trips through the transition service and re-renders the affected columns", "The journey is fully keyboard-operable without drag-and-drop", "Zero serious or critical axe violations; zero CSP violations") `
            -Validation @("Playwright pipeline journey green", "Query budget test for the board view green") `
            -DocsImpact "None, unless TypeScript drag-and-drop is added (then an ADR)." `
            -OutOfScope @("No bulk operations", "No saved views or filters beyond stage grouping") `
            -Dependencies @("M08-01")) }

    # ----- M09 (5) -----
    [pscustomobject]@{ RoadmapId = "M09-01"; Milestone = "M09 - Observability, Analytics, and Production Readiness"; ParentRoadmapId = "M09-TRACKER"
        Title = "Decision: select the initial deployment target"
        Labels = @("type:decision", "area:ci", "priority:p1", "size:S"); DependsOnIds = @()
        Body = (New-IssueBody -RoadmapId "M09-01" `
            -Objective "Select and record the production deployment target, resolving the ROADMAP open decision, so production deployment (M09-04) has a concrete platform." `
            -Context "ROADMAP lists the deployment target as open. Deciding it inside M09 keeps the deployment milestone self-contained and removes any dependency on the deferred-gates milestone." `
            -Scope @("Evaluate candidate targets against operating cost, managed PostgreSQL, RabbitMQ, and Redis availability, and solo-operability", "Record the decision with alternatives considered in TECHNOLOGY_DECISIONS.md", "Update ROADMAP Open Decisions") `
            -Acceptance @("A target is named with recorded alternatives and reasoning", "ROADMAP and TECHNOLOGY_DECISIONS.md updated in the same change") `
            -Validation @("Documentation review; no code change expected") `
            -DocsImpact "TECHNOLOGY_DECISIONS.md and ROADMAP.md." `
            -OutOfScope @("No infrastructure provisioning (M09-04)") `
            -Dependencies @("None")) }
    [pscustomobject]@{ RoadmapId = "M09-02"; Milestone = "M09 - Observability, Analytics, and Production Readiness"; ParentRoadmapId = "M09-TRACKER"
        Title = "Service-level indicators and alerting"
        Labels = @("type:feature", "area:observability", "priority:p2", "size:L"); DependsOnIds = @("M04-06")
        Body = (New-IssueBody -RoadmapId "M09-02" `
            -Objective "SLIs for the capture and resolution workflows with Grafana dashboards and alert rules, each panel tied to an objective, an investigation, or a release decision." `
            -Context "ROADMAP Milestone 7. The M04-06 baseline metrics exist; this issue turns them into objectives with alerts. A panel with no decision behind it is decoration and is not built." `
            -Scope @("SLI definitions: capture acceptance latency, resolution completion time, queue oldest-age, outbox publication lag, ambiguous-rate", "Alert rules with thresholds derived from measured baselines, not guesses", "Dashboards provisioned as code in the repository", "Alert-rule tests where the stack supports them") `
            -Acceptance @("Each dashboard panel names its objective or decision in its description", "Alerts fire correctly against injected threshold breaches in a test environment", "Dashboard and alert definitions are version-controlled") `
            -Validation @("Threshold-breach injection produces the expected alert", "Dashboard provisioning reviewed in the PR") `
            -DocsImpact "First alert-response runbook content enters the repository, now non-fictional." `
            -OutOfScope @("No paging integration", "No capacity planning") `
            -Dependencies @("M04-06")) }
    [pscustomobject]@{ RoadmapId = "M09-03"; Milestone = "M09 - Observability, Analytics, and Production Readiness"; ParentRoadmapId = "M09-TRACKER"
        Title = "Conversion analytics read models"
        Labels = @("type:feature", "area:analytics", "priority:p2", "size:M"); DependsOnIds = @("M08-01")
        Body = (New-IssueBody -RoadmapId "M09-03" `
            -Objective "Career-outcome analytics from PostgreSQL: response rate, interview and offer conversion, time to first response, source performance, and CV-version performance." `
            -Context "ROADMAP Milestone 7. These are the questions the product exists to answer, computed from the transition history and version linkages, with materialized views only where measured need justifies them. This work belongs to the Analytics context, not Matching." `
            -Scope @("Analytics selectors over transition history, source attribution, and version linkage", "Materialized view for any query that measurably needs one, with a refresh strategy", "Analytics page on the shell with budgeted reads", "Deterministic tests with fixture timelines") `
            -Acceptance @("Conversion numbers match hand-computed fixture expectations exactly", "Source and CV-version breakdowns respect workspace scope", "Any materialized view has a documented refresh trigger and staleness bound") `
            -Validation @("pytest analytics fixture tests green; EXPLAIN review for the heaviest query") `
            -DocsImpact "None." `
            -OutOfScope @("No DuckDB or Parquet export (gate M10-03)", "No product behavioural analytics (PostHog remains deferred)") `
            -Dependencies @("M08-01")) }
    [pscustomobject]@{ RoadmapId = "M09-04"; Milestone = "M09 - Observability, Analytics, and Production Readiness"; ParentRoadmapId = "M09-TRACKER"
        Title = "Production deployment with smoke tests and rollback"
        Labels = @("type:feature", "area:ci", "priority:p2", "size:L"); DependsOnIds = @("M09-01")
        Body = (New-IssueBody -RoadmapId "M09-04" `
            -Objective "A production environment on the decided target: build-once image promotion, migration handling, smoke tests, and an exercised, documented rollback." `
            -Context "Depends on the M09-01 deployment-target decision. Rollback is exercised, not described: a deliberate bad deployment is rolled back as part of acceptance." `
            -Scope @("Deployment workflow with OIDC (no long-lived credentials), immutable image digests, and environment protection", "Managed PostgreSQL, RabbitMQ, and Redis per the decision, with backup verification for PostgreSQL", "Migration job separated from application rollout", "Smoke tests post-deploy; documented and demonstrated rollback") `
            -Acceptance @("The same image digest promotes from staging to production without rebuild", "A deliberately broken deploy is rolled back using the documented procedure", "PostgreSQL backup restore verified into a scratch environment") `
            -Validation @("Deployment workflow run links attached; rollback exercise recorded") `
            -DocsImpact "Production deployment runbook and backup-restore runbook enter the repository (previously deferred, now non-fictional)." `
            -OutOfScope @("No Kubernetes", "No multi-region") `
            -Dependencies @("M09-01")) }
    [pscustomobject]@{ RoadmapId = "M09-05"; Milestone = "M09 - Observability, Analytics, and Production Readiness"; ParentRoadmapId = "M09-TRACKER"
        Title = "Production security hardening"
        Labels = @("type:security", "area:platform", "priority:p2", "size:M"); DependsOnIds = @("M09-04")
        Body = (New-IssueBody -RoadmapId "M09-05" `
            -Objective "Verification that the security baseline holds in the production environment: deploy checks, headers, CSP enforcement, scan gates, and secret handling." `
            -Context "The Verification Status column of SECURITY_MODEL.md exists for this moment: controls described as planned get verified against the running system or explicitly re-scoped." `
            -Scope @("manage.py check --deploy clean against production settings", "Header and CSP verification against the production origin", "Container and dependency scan gates enforced on the release path", "Secret rotation procedure documented and exercised once", "SECURITY_MODEL.md verification column updated row by row") `
            -Acceptance @("Deploy checks report no warnings", "Production responses carry the full header contract with enforced CSP", "Every SECURITY_MODEL.md row reads verified, re-scoped, or deferred with a milestone") `
            -Validation @("Header test suite run against the production origin; scan reports attached") `
            -DocsImpact "SECURITY_MODEL.md verification status updated throughout." `
            -OutOfScope @("No penetration test engagement", "No MFA rollout unless already present") `
            -Dependencies @("M09-04")) }

    # ----- M10 (3) -----
    [pscustomobject]@{ RoadmapId = "M10-01"; Milestone = "M10 - Deferred Decisions and Benchmark Gates"; ParentRoadmapId = "M10-TRACKER"
        Title = "Decision gate: activate the native mobile delivery track"
        Labels = @("type:decision", "area:integrations", "priority:p2", "size:S"); DependsOnIds = @("M03-08")
        Body = (New-IssueBody -RoadmapId "M10-01" `
            -Objective "Decide whether to activate the native mobile delivery track as the second DRF consumer, after the extension client has proven the capture and operation-status contracts in real use." `
            -Context "ROADMAP names native mobile as the preferred future second consumer, gated on stable extension contracts. The share-sheet workflow, offline-safe retry, and secure storage capabilities are the first meaningful mobile deliverables if activated." `
            -Scope @("Assess extension contract stability: breaking changes since release, error-contract fitness, idempotency behaviour in the field", "Assess capacity against the remaining roadmap", "Record activation with an entry milestone, or re-deferral with reasoning, in ROADMAP and TECHNOLOGY_DECISIONS.md") `
            -Acceptance @("A recorded decision exists with reasoning", "If activated, an entry milestone and first-capability scope are named", "If re-deferred, the re-evaluation condition is stated") `
            -Validation @("Documentation review; no code change expected") `
            -DocsImpact "ROADMAP.md Deferred Delivery Tracks and Open Decisions; TECHNOLOGY_DECISIONS.md Expo and React Native row." `
            -OutOfScope @("No mobile implementation in this issue under any outcome") `
            -Dependencies @("M03-08")) }
    [pscustomobject]@{ RoadmapId = "M10-02"; Milestone = "M10 - Deferred Decisions and Benchmark Gates"; ParentRoadmapId = "M10-TRACKER"
        Title = "Benchmark gate: evaluate Rust content processing if retained"
        Labels = @("type:spike", "area:job-registry", "priority:p3", "size:M"); DependsOnIds = @("M04-04")
        Body = (New-IssueBody -RoadmapId "M10-02" `
            -Objective "If a real content-processing constraint emerges, benchmark a Rust processor against the Python normalization baseline with pre-committed thresholds, and retain or reject it on the numbers." `
            -Context "ROADMAP gates Rust on the Python baseline demonstrating a measurable CPU, memory, latency, or isolation constraint. The thresholds are written before the work so sunk cost cannot negotiate them afterwards. The realistic outcome that Python is sufficient and Rust is rejected is a valid and well-documented result." `
            -Scope @("Entry check: confirm a measured constraint exists in the M04-04 baseline under production-like load; if none exists, close this gate as re-deferred with the numbers", "Pre-committed retention thresholds recorded in this issue before any Rust work", "Identical fixture set run against both implementations", "Decision record: retain behind versioned messages, or reject and delete, in TECHNOLOGY_DECISIONS.md") `
            -Acceptance @("Thresholds were recorded before measurement", "Both implementations measured on identical fixtures, or the gate closed at the entry check with baseline numbers", "TECHNOLOGY_DECISIONS.md updated with the outcome and its evidence") `
            -Validation @("Benchmark outputs or entry-check numbers attached to the closing comment") `
            -DocsImpact "TECHNOLOGY_DECISIONS.md Rust content worker row; ROADMAP.md Deferred Delivery Tracks." `
            -OutOfScope @("No Rust code merged before thresholds exist", "No Rust writes to CareerOps domain state under any outcome") `
            -Dependencies @("M04-04")) }
    [pscustomobject]@{ RoadmapId = "M10-03"; Milestone = "M10 - Deferred Decisions and Benchmark Gates"; ParentRoadmapId = "M10-TRACKER"
        Title = "Decision gate: introduce DuckDB for a real analytical export"
        Labels = @("type:decision", "area:analytics", "priority:p3", "size:S"); DependsOnIds = @("M09-03")
        Body = (New-IssueBody -RoadmapId "M10-03" `
            -Objective "Decide whether a real analytical export or offline reporting workflow justifies introducing DuckDB, after PostgreSQL conversion analytics exist." `
            -Context "ROADMAP gates DuckDB on a real Parquet or offline reporting workflow. PostgreSQL analytics (M09-03) must exist first, both to serve the need and to prove whether a need beyond PostgreSQL remains." `
            -Scope @("Assess whether an export, offline report, or reproducible analytical dataset exceeds what PostgreSQL serves well", "If yes: record adoption with the first concrete workflow and an entry milestone", "If no: re-defer with the evaluation recorded") `
            -Acceptance @("A recorded decision exists with the workload evidence either way", "TECHNOLOGY_DECISIONS.md and ROADMAP updated") `
            -Validation @("Documentation review; no code change expected") `
            -DocsImpact "TECHNOLOGY_DECISIONS.md DuckDB row; ROADMAP.md Deferred Delivery Tracks." `
            -OutOfScope @("No DuckDB implementation in this issue under any outcome", "DuckDB never becomes transactional storage") `
            -Dependencies @("M09-03")) }
)

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

try {
    # 1. Preflight validation of the FULL definition set (before any filtering
    #    and before any mutation).
    Test-RoadmapDefinitions -Labels $Labels -Milestones $Milestones -Trackers $Trackers -Issues $Issues

    # 2. OnlyMilestone filtering (labels always sync; records filter).
    $SelectedIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($def in (@($Trackers) + @($Issues))) { [void]$SelectedIds.Add($def.RoadmapId) }
    if ($OnlyMilestone) {
        $matchingMilestones = @($Milestones | Where-Object { $_.Title -eq $OnlyMilestone })
        if ($matchingMilestones.Count -ne 1) {
            $known = ($Milestones | ForEach-Object { $_.Title }) -join "; "
            throw "Unknown milestone '$OnlyMilestone'. Use an exact milestone title. Known: $known"
        }
        $Milestones = $matchingMilestones
        $Trackers = @($Trackers | Where-Object { $_.Milestone -eq $OnlyMilestone })
        $Issues = @($Issues | Where-Object { $_.Milestone -eq $OnlyMilestone })

        $selectedLabelNames = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($def in (@($Trackers) + @($Issues))) {
            foreach ($labelName in $def.Labels) { [void]$selectedLabelNames.Add($labelName) }
        }
        $Labels = @($Labels | Where-Object { $selectedLabelNames.Contains($_.Name) })

        $SelectedIds.Clear()
        foreach ($def in (@($Trackers) + @($Issues))) { [void]$SelectedIds.Add($def.RoadmapId) }
        Write-Step "Partial run restricted to milestone: $OnlyMilestone ($($Trackers.Count) tracker, $($Issues.Count) issues, $($Labels.Count) labels)"
    }

    # 3. Environment and repository checks.
    Assert-CommandAvailable -Name "gh"
    Assert-GitHubAuthentication
    $null = Get-RepositoryMetadata -Repository $Repo

    if (-not $Apply) {
        Write-Host ""
        Write-Host "DRY-RUN MODE: no GitHub mutation will occur. Pass -Apply to execute." -ForegroundColor Yellow
        Write-Host ""
    }

    # 4. Labels.
    Write-Step "Synchronizing labels"
    $existingLabels = Get-ExistingLabels -Repository $Repo
    foreach ($label in $Labels) {
        Sync-Label -Repository $Repo -Label $label -Existing $existingLabels
    }

    # 5. Milestones.
    Write-Step "Synchronizing milestones"
    $existingMilestones = Get-ExistingMilestones -Repository $Repo
    foreach ($milestone in $Milestones) {
        $null = Sync-Milestone -Repository $Repo -Milestone $milestone -Existing $existingMilestones
    }

    # 6. Existing issues, parent-flag feature detection.
    $existingIssues = Get-ExistingIssues -Repository $Repo
    $supportsParent = Test-GhSupportsParentFlag
    if ($supportsParent) { Write-Done "gh supports --parent: sub-issue relationships will be used." }
    else { Write-Note "gh does not support --parent: tracker checklists remain the linkage (already present in bodies)." }

    $issueNumbers = @{}
    $trackerNumbers = @{}

    # 7. Trackers first, then implementation issues.
    Write-Step "Creating milestone tracker issues"
    foreach ($tracker in $Trackers) {
        Create-RoadmapIssue -Repository $Repo -Definition $tracker -Existing $existingIssues `
            -IssueNumbers $issueNumbers -SupportsParent $supportsParent -TrackerNumbers $trackerNumbers
    }
    Write-Step "Creating implementation issues"
    foreach ($issue in $Issues) {
        Create-RoadmapIssue -Repository $Repo -Definition $issue -Existing $existingIssues `
            -IssueNumbers $issueNumbers -SupportsParent $supportsParent -TrackerNumbers $trackerNumbers
    }

    # 8. Dependency links, second pass.
    Link-IssueDependencies -Repository $Repo -Definitions $Issues -IssueNumbers $issueNumbers -SelectedIds $SelectedIds

    # 9. Summary and exit code.
    Write-ExecutionSummary
    if ($script:Summary.FailedMutations -gt 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ""
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-ExecutionSummary
    exit 1
}
