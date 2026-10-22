<#
.SYNOPSIS
    AVD Current State Drift -- compares a live landing zone with what avd-landing-zone last deployed,
    attributes every change, and reports it. Read-only: it changes nothing.

.DESCRIPTION
    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    Design: docs/drift-spec.md. One run:
      1. Health check: an Az context, the reads it needs, and (in GitHub Actions) a private repository.
      2. Reads, through Resource Graph and REST GETs only: the subscription's deployment records, the
         collector's rebuild scope (rebuild/scope.json), the Resource Graph change log (14 days) and the
         Activity Log for the types the change log doesn't cover.
      3. Compares the deployment's parameters with the landing zone host pool's rebuild map.
      4. Attributes each change: a landing zone deployment (by correlation ID), the landing zone's own
         automation (drift/expected-actors.json), run-time state (drift/runtime-paths.json), or
         unexplained. A rule hides changes only while its exact digest is approved (section 3.6).
      5. Writes drift-report.md, drift-results.json and manifest.json to -OutputPath and exits
         2 (couldn't check), 1 (findings) or 0 (clean). Only 0 may close the drift issue.

    Fixes never come from here: they go through the landing zone's deploy workflow after a person
    approves (section 3.4). The report holds names and values and belongs in a private place.

.PARAMETER SubscriptionId
    The landing zone's subscription. Defaults to the current Az context's.

.PARAMETER Environment
    The landing zone environment (dev, test, prod), when the subscription holds more than one.

.PARAMETER DeploymentName
    A specific subscription deployment to treat as the declared state, instead of the latest avdlz-* one.

.PARAMETER BaselinePath
    A committed baseline (avd-current-state-drift-baseline/v1) to use as the declared state for an estate
    the landing zone didn't deploy, or when the deployment records can't be read.

.PARAMETER ProposeBaseline
    Writes drift-baseline.proposed.json for each host pool (every found or derived value) for a person to
    review and commit, then exits. Compares nothing.

.PARAMETER ConfigPath
    The operator's private folder with drift-exceptions.json, drift-approvals.json and drift-values.json.
    Missing files count as empty: with no approvals, no rule hides anything.

.PARAMETER LastSuccess
    When the last successful run finished (the workflow reads it from its run history). Older than 14 days
    is reported as a window gap and the Activity Log covers the span back to it, up to 90 days.

.PARAMETER Digest
    Adds the weekly digest of suppression rules to the report.

.PARAMETER ShowSuppressionDigest
    Prints each rule's digest, its approval state and a ready-to-paste approval line, then exits. Offline.

.EXAMPLE
    pwsh -NoLogo -File ./avd_current_state_drift.ps1 -Environment dev -ConfigPath ~/avd-private/drift

.EXAMPLE
    pwsh -NoLogo -File ./avd_current_state_drift.ps1 -ConfigPath ~/avd-private/drift -ShowSuppressionDigest
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [ValidateSet('dev', 'test', 'prod')] [string]$Environment,
    [string]$DeploymentName,
    [string]$BaselinePath,
    [switch]$ProposeBaseline,
    [string]$ConfigPath,
    [string]$OutputPath = (Join-Path (Get-Location).Path 'output'),
    [string]$LastSuccess,
    [switch]$Digest,
    [int]$DigestThreshold = 50,
    [switch]$ShowSuppressionDigest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# An unexpected error is a run that couldn't check (exit 2), never findings (1) or clean (0).
trap {
    Write-Host "[drift] Stopped by an error, so this run couldn't check: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    Write-Host '[drift] RESULT COULDNT-CHECK (exit 2)'
    exit 2
}

Import-Module (Join-Path $PSScriptRoot 'lib/AvdRebuild.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdRebuildMap.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdDrift.psm1') -Force

$now = [datetime]::UtcNow
$findings = [System.Collections.Generic.List[object]]::new()
# The log shows counts, not names, when it runs in GitHub Actions (spec section 3.3); the report holds the rest.
$quiet = $env:GITHUB_ACTIONS -eq 'true'

function Write-Step { param([string]$Message) Write-Host "[drift] $Message" }

function Read-DriftJson {
    param([string]$Path, [string]$Schema)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($Schema -and "$(Get-RebuildValue $doc 'schema' '')" -ne $Schema) { throw "$Path is not $Schema." }
    return $doc
}

function Add-CouldNotCheck {
    param([string]$Subject, [string]$Message)
    $findings.Add((Get-DriftFinding -Check 'drift-couldnt-check' -Kind 'couldnt-check' -Subject $Subject -Message $Message -Action 'investigate'))
    if ($quiet) { Write-Step "COULDN'T CHECK ($Subject): see the report." } else { Write-Step "COULDN'T CHECK: $Message" }
}

# ---------------------------------------------------------------- rules and private settings
$config = @{ exceptions = @(); approvals = @(); values = @{} }
if ($ConfigPath) {
    $ex = Read-DriftJson (Join-Path $ConfigPath 'drift-exceptions.json') 'avd-current-state-drift-exceptions/v1'
    $ap = Read-DriftJson (Join-Path $ConfigPath 'drift-approvals.json') 'avd-current-state-drift-approvals/v1'
    $va = Read-DriftJson (Join-Path $ConfigPath 'drift-values.json') 'avd-current-state-drift-values/v1'
    if ($ex) { $config.exceptions = @(Get-RebuildValue $ex 'exceptions' @()) }
    if ($ap) { $config.approvals = @(Get-RebuildValue $ap 'approvals' @()) }
    if ($va) { foreach ($p in @((Get-RebuildValue $va 'values').PSObject.Properties)) { $config.values[$p.Name] = "$($p.Value)" } }
}
$ruleSets = @{}
$rules = @()
foreach ($file in 'expected-actors.json', 'runtime-paths.json') {
    $doc = Read-DriftJson (Join-Path $PSScriptRoot "drift/$file") 'avd-current-state-drift-rules/v1'
    $resolved = @(foreach ($r in @($doc.rules)) { $x = Resolve-DriftRule -Rule $r -Values $config.values; [pscustomobject]@{ File = $file; Rule = $x.Rule; Missing = $x.Missing } })
    $ruleSets[$file] = @($resolved | ForEach-Object { $_.Rule })
    $rules += $resolved
}
$approval = Get-DriftSuppressionApproval -Rules $rules -Approvals $config.approvals -Now $now
$approvalState = @{}; foreach ($a in $approval) { $approvalState[$a.id] = $a.state }
Write-Step "Suppression rules: $(@($approval).Count), approved $(@($approval | Where-Object { $_.state -eq 'approved' }).Count). Exceptions: $(@($config.exceptions).Count)."

if ($ShowSuppressionDigest) {
    foreach ($a in $approval) {
        Write-Host ''
        Write-Host "$($a.id) ($($a.file)): $($a.state)$(if ($a.expires) { ", expires $($a.expires.ToString('yyyy-MM-dd'))" })"
        Write-Host "  digest $($a.digest)"
        if (@($a.missing).Count -gt 0) { Write-Host "  needs a value in drift-values.json for: $(@($a.missing) -join ', ')" }
        elseif ($a.state -ne 'approved') { Write-Host "  to approve, add to drift-approvals.json by a pull request: $(Get-DriftApprovalLine -Approval $a -Now $now)" }
    }
    exit 0
}

# ---------------------------------------------------------------- health check (decision 0026)
Write-Step 'Health check ...'
if ($env:GITHUB_ACTIONS -eq 'true' -and $env:DRIFT_REPO_PRIVATE -ne 'true') {
    Write-Step "Stopped: in GitHub Actions the drift report runs only in a private repository. The workflow's health step sets DRIFT_REPO_PRIVATE from the repository API (samples/drift.yml)."
    exit 2
}
if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) {
    Write-Step 'Stopped: Invoke-AzRestMethod is missing. Fix: Install-Module Az.Accounts -Scope CurrentUser'
    exit 2
}
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Step 'Stopped: no Azure sign-in. Fix: Connect-AzAccount (in GitHub Actions, azure/login with the reader identity).'
    exit 2
}
if (-not $SubscriptionId) { $SubscriptionId = "$($context.Subscription.Id)" }
if ($SubscriptionId -notmatch '^[0-9a-fA-F-]{36}$') { Write-Step 'Stopped: no subscription. Pass -SubscriptionId.'; exit 2 }

# Throttling and transient errors are retried with backoff; anything else is reported in full (lesson 0012).
$retry = {
    param([scriptblock]$Call)
    $delays = @(2, 4, 8, 16)
    for ($i = 0; ; $i++) {
        $r = & $Call
        $code = [int]$r.StatusCode
        if (($code -eq 429 -or $code -ge 500) -and $i -lt $delays.Count) {
            Write-Step "  HTTP $code, retrying in $($delays[$i]) s ..."
            Start-Sleep -Seconds $delays[$i]
            continue
        }
        if ($r.PSObject.Properties['Headers'] -and $r.Headers) {
            $left = @($r.Headers.GetEnumerator() | Where-Object { "$($_.Key)" -eq 'x-ms-user-quota-remaining' } | ForEach-Object { "$($_.Value)" })
            if ($left.Count -gt 0) { $script:QuotaLeft = $left[0] }
        }
        return @{ StatusCode = $code; Content = $r.Content }
    }
}
$graph = { param($body) $payload = $body | ConvertTo-Json -Depth 5 -Compress; & $retry { Invoke-AzRestMethod -Method POST -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Payload $payload }.GetNewClosure() }
$rest = { param($path) $target = "$path"; & $retry { Invoke-AzRestMethod -Method GET -Path $target }.GetNewClosure() }
$script:QuotaLeft = ''

# ---------------------------------------------------------------- the declared side
$sub = "/subscriptions/$SubscriptionId"
Write-Step 'Reading the subscription deployment records ...'
$dep = Invoke-RebuildRestRead -Path "$sub/providers/Microsoft.Resources/deployments?api-version=2021-04-01" -Invoker $rest
$deployments = @($dep.Items)
if ($dep.Status -eq 'failed') { Write-Step "  Deployment records unreadable: $($dep.Error)" } else { Write-Step "  $($deployments.Count) deployment record(s)." }

$declared = $null
if ($BaselinePath) {
    $b = Read-DriftJson $BaselinePath 'avd-current-state-drift-baseline/v1'
    if (-not $b) { Write-Step "Stopped: $BaselinePath not found."; exit 2 }
    $values = [ordered]@{}; foreach ($p in @((Get-RebuildValue $b 'parameters').PSObject.Properties)) { $values[$p.Name] = $p.Value }
    $hpName = (("$(Get-RebuildValue $b 'hostPool' '')") -split '/')[-1]
    $declared = [ordered]@{ source = 'baseline'; deployment = (Split-Path $BaselinePath -Leaf); timestamp = $null; correlationId = ''; names = @{ hostPool = $hpName; resourceGroupPrefix = '' }; parameters = $values; secure = @() }
} elseif ($dep.Status -ne 'failed') {
    $declared = Get-DriftDeclaredState -Deployments $deployments -Environment $Environment -DeploymentName $DeploymentName
}
if (-not $declared -and -not $ProposeBaseline) {
    if ($dep.Status -eq 'failed') { Add-CouldNotCheck 'declared' 'The deployment records could not be read. The reader needs Reader on the subscription (spec section 5), or pass -BaselinePath.' }
    else { Add-CouldNotCheck 'declared' 'No successful avdlz-* deployment with namePrefix and environmentName was found. Pass -DeploymentName or -BaselinePath, or -ProposeBaseline for an estate the landing zone did not deploy.' }
}
if ($declared) {
    if ($quiet) { Write-Step "Declared state: $($declared.source), $(@($declared.parameters.Keys).Count) parameter(s)." }
    else { Write-Step "Declared state: $($declared.source) $($declared.deployment), host pool $($declared.names.hostPool), $(@($declared.parameters.Keys).Count) parameter(s)." }
}

# ---------------------------------------------------------------- the live side
$scope = Get-RebuildScope -Path (Join-Path $PSScriptRoot 'rebuild/scope.json')
$lzParameters = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'rebuild/lz-parameters.json') -Raw | ConvertFrom-Json
$rows = @{}
$readFailures = 0
if ($declared -or $ProposeBaseline) {
    Write-Step "Reading $(@($scope.resourceGraph).Count) Resource Graph types and $(@($scope.rest).Count) REST reads ..."
    foreach ($t in @($scope.resourceGraph)) {
        try { $rows[$t.type] = @((ConvertTo-RebuildSafeObject -InputObject @(Invoke-RebuildGraphQuery -Query (Get-RebuildQuery -Table $t.table -Type $t.type) -SubscriptionId $SubscriptionId -Invoker $graph)).Object) }
        catch { $rows[$t.type] = @(); $readFailures++; Write-Step "  $($t.type) failed: $($_.Exception.Message)" }
    }
    $restData = @{}
    $vmIds = @{}
    foreach ($sh in @($rows['microsoft.desktopvirtualization/hostpools/sessionhosts'])) { $v = "$(Get-RebuildValue $sh 'properties.resourceId' '')".ToLowerInvariant(); if ($v) { $vmIds[$v] = $true } }
    foreach ($read in @($scope.rest)) {
        $parents = @()
        foreach ($p in @($read.parentTypes)) { if ($p -eq 'subscription') { $parents += $sub } else { $parents += @($rows[$p] | ForEach-Object { $_.id }) } }
        if ($read.name -eq 'run-commands') { $parents = @($parents | Where-Object { $vmIds.ContainsKey("$_".ToLowerInvariant()) }) }
        $results = @(foreach ($parentId in $parents) {
                $r = Invoke-RebuildRestRead -Path (Get-RebuildRestPath -Read $read -ParentId $parentId) -Invoker $rest
                if ($r.Status -eq 'failed') { $readFailures++; Write-Step "  $($read.name) failed for one resource: $($r.Error)" }
                [pscustomobject][ordered]@{ parentId = $parentId; status = $r.Status; error = $r.Error; items = @($r.Items) }
            })
        $restData[$read.name] = @((ConvertTo-RebuildSafeObject -InputObject $results).Object)
    }
    $roleAssignments = @()
    if (Get-Command Get-AzRoleAssignment -ErrorAction SilentlyContinue) {
        try { $roleAssignments = @(Get-AzRoleAssignment -Scope $sub -ErrorAction Stop | Select-Object DisplayName, SignInName, RoleDefinitionName, Scope, ObjectType, ObjectId) }
        catch { $readFailures++; Write-Step "  Role assignments failed: $($_.Exception.Message)" }
    } else { Write-Step '  Az.Resources is missing: role assignment parameters will read as unknown.' }
    $maps = Get-LzRebuildMap -Rows $rows -Rest $restData -RoleAssignments $roleAssignments -ParameterList $lzParameters
    Write-Step "  Rebuild map for $(@($maps).Count) host pool(s). Quota left: $(if ($script:QuotaLeft) { $script:QuotaLeft } else { 'not reported' })."
    if ($readFailures -gt 0) { Add-CouldNotCheck 'reads' "$readFailures read(s) failed, so the comparison may be incomplete." }
}

if ($ProposeBaseline) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
    foreach ($m in @($maps)) {
        $file = Join-Path $OutputPath ("drift-baseline.proposed.{0}.json" -f ((("$($m.hostPool)") -split '/')[-1]))
        (Get-DriftBaselineProposal -Map $m | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $file -Encoding utf8
        Write-Step "Proposed baseline written: $file. Review it, commit it to the private repo and pass it as -BaselinePath."
    }
    exit 0
}

$map = $null
if ($declared) {
    $map = @($maps | Where-Object { (("$($_.hostPool)") -split '/')[-1] -eq $declared.names.hostPool }) | Select-Object -First 1
    if (-not $map) { Add-CouldNotCheck 'hostPool' "The declared host pool $($declared.names.hostPool) is not in the estate. If it was removed on purpose, that is the drift to look at first." }
}

# ---------------------------------------------------------------- compare
if ($map) {
    $hpRow = @($rows['microsoft.desktopvirtualization/hostpools'] | Where-Object { "$($_.id)".ToLowerInvariant() -eq "$($map.hostPool)".ToLowerInvariant() }) | Select-Object -First 1
    $locked = $false
    if ($hpRow) { $tags = Get-RebuildValue $hpRow 'tags'; $locked = ($null -ne $tags -and $null -ne $tags.PSObject.Properties['avdlz-power-lock']) }
    foreach ($f in (Get-DriftParameterResult -Map $map -Declared $declared.parameters -ParameterList $lzParameters -Exceptions $config.exceptions -Now $now -PowerLocked $locked)) { $findings.Add($f) }
    Write-Step "Compared $(@($declared.parameters.Keys).Count) declared parameter(s): $(@($findings | Where-Object { $_.check -eq 'drift-param' -and $_.kind -eq 'drift' }).Count) drifted."
}

# ---------------------------------------------------------------- changes and attribution
$attribution = @()
if ($declared -and $declared.names.resourceGroupPrefix) {
    $prefix = $declared.names.resourceGroupPrefix
    $groups = @($rows['microsoft.resources/subscriptions/resourcegroups'] | Where-Object { "$($_.name)".ToLowerInvariant().StartsWith($prefix) } | ForEach-Object { "$($_.name)" })
    $from = $now.AddDays(-14)
    $last = $null
    if ($LastSuccess) { $last = [datetime]::Parse($LastSuccess, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal) }
    foreach ($f in (Get-DriftWindowGap -LastSuccess $last -Now $now)) { $findings.Add($f) }
    $activityFrom = $from
    if ($last -and $last -lt $from) { $activityFrom = $last; if ($activityFrom -lt $now.AddDays(-90)) { $activityFrom = $now.AddDays(-90) } }
    Write-Step "Reading 14 days of the change log and $([int]($now - $activityFrom).TotalDays) days of the Activity Log for $($groups.Count) landing zone resource group(s) ..."
    $changes = @()
    $query = "resourcechanges | extend t = todatetime(properties.changeAttributes.timestamp), target = tolower(tostring(properties.targetResourceId)) | where t > ago(14d) | where target contains '/resourcegroups/$prefix' | order by t asc"
    try { $changes += @(Invoke-RebuildGraphQuery -Query $query -SubscriptionId $SubscriptionId -Invoker $graph | ForEach-Object { ConvertFrom-DriftResourceChange -Row $_ }) }
    catch { Add-CouldNotCheck 'change-log' "The Resource Graph change log could not be read: $($_.Exception.Message)" }
    $select = 'eventTimestamp,operationName,status,caller,correlationId,resourceId,eventDataId'
    foreach ($g in $groups) {
        $filter = "eventTimestamp ge '$($activityFrom.ToString('yyyy-MM-ddTHH:mm:ssZ'))' and eventTimestamp le '$($now.ToString('yyyy-MM-ddTHH:mm:ssZ'))' and resourceGroupName eq '$g'"
        $path = "$sub/providers/Microsoft.Insights/eventtypes/management/values?api-version=2015-04-01&`$filter=$([uri]::EscapeDataString($filter))&`$select=$select"
        $r = Invoke-RebuildRestRead -Path $path -Invoker $rest -MaxPages 200
        if ($r.Status -eq 'failed') { Add-CouldNotCheck 'activity-log' "The Activity Log could not be read for one landing zone resource group: $($r.Error)"; continue }
        $changes += @($r.Items | ForEach-Object { ConvertFrom-DriftActivityEvent -ActivityEvent $_ } | Where-Object { $null -ne $_ })
    }
    $attribution = Get-DriftAttribution -Changes $changes -DeploymentCorrelationIds (Get-DriftLandingZoneCorrelationId -Deployments $deployments) `
        -ExpectedActors $ruleSets['expected-actors.json'] -RuntimePaths $ruleSets['runtime-paths.json'] -Approval $approvalState
    foreach ($f in (Get-DriftChangeResult -Attribution $attribution)) { $findings.Add($f) }
    $by = @{}; foreach ($a in $attribution) { $by[$a.by] = 1 + $(if ($by.ContainsKey($a.by)) { $by[$a.by] } else { 0 }) }
    Write-Step "  $(@($attribution).Count) change(s): $(@($by.Keys | Sort-Object | ForEach-Object { "$($by[$_]) $_" }) -join ', ')."
}
foreach ($f in (Get-DriftSuppressionResult -Approval $approval)) { $findings.Add($f) }

# ---------------------------------------------------------------- write
$code = Get-DriftExitCode -Findings $findings
$digestRows = @()
if ($Digest) { $digestRows = Get-DriftSuppressionDigest -Approval $approval -Attribution $attribution -Now $now -Threshold $DigestThreshold }
$envName = if ($declared) { "$($declared.names.hostPool)" -replace '^vdpool-', '' } else { 'unknown' }
$summary = [ordered]@{
    'Declared state' = $(if ($declared) { "$($declared.source) $(ConvertTo-DriftLiteral $declared.deployment)" } else { 'none' })
    'Checked at'     = $now.ToString('yyyy-MM-dd HH:mm') + ' UTC'
    'Open findings'  = @($findings | Where-Object { $_.open }).Count
    'Changes read'   = @($attribution).Count
}
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$reportPath = Join-Path $OutputPath 'drift-report.md'
$resultsPath = Join-Path $OutputPath 'drift-results.json'
$catalogPath = Join-Path $PSScriptRoot 'checks/catalog.json'
(Get-DriftReport -Environment $envName -Findings $findings -ExitCode $code -Summary $summary -Digest $digestRows) | Set-Content -LiteralPath $reportPath -Encoding utf8
[ordered]@{
    schema    = 'avd-current-state-drift-results/v1'
    generated = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    exitCode  = $code
    catalog   = [ordered]@{ path = 'checks/catalog.json'; sha256 = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    declared  = $(if ($declared) { [ordered]@{ source = $declared.source; deployment = $declared.deployment; timestamp = $declared.timestamp; landingZoneCommit = $lzParameters.landingZoneCommit } } else { $null })
    findings  = @($findings)
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultsPath -Encoding utf8
$files = [ordered]@{}
foreach ($f in $reportPath, $resultsPath) { $files[(Split-Path $f -Leaf)] = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() }
[ordered]@{ schema = 'avd-current-state-drift-manifest/v1'; generated = $now.ToString('yyyy-MM-ddTHH:mm:ssZ'); exitCode = $code; files = $files } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputPath 'manifest.json') -Encoding utf8

$kinds = @{}; foreach ($f in @($findings | Where-Object { $_.open })) { $kinds[$f.kind] = 1 + $(if ($kinds.ContainsKey($f.kind)) { $kinds[$f.kind] } else { 0 }) }
Write-Step "Open findings: $(if ($kinds.Count) { @($kinds.Keys | Sort-Object | ForEach-Object { "$($kinds[$_]) $_" }) -join ', ' } else { 'none' }). Report: $reportPath"
Write-Step "RESULT $(switch ($code) { 0 { 'CLEAN' } 1 { 'FINDINGS' } default { 'COULDNT-CHECK' } }) (exit $code)"
exit $code
