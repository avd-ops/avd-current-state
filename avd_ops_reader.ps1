<#
.SYNOPSIS
    avd-ops-reader -- the optional read-only identity for unattended avd-current-state runs: set it up,
    check it, remove it (docs/reader-identity.md).

.DESCRIPTION
    Optional. The collector, validator and facts script never need it: with no reader they use your own
    sign-in, as always. The reader is for runs with nobody signed in, such as a weekly collection from
    GitHub Actions in your private repo, and it reads with Reader instead of your own rights.

      - App-only, single tenant, no secret and no certificate. GitHub Actions signs in as it through a
        federated credential bound to one private repo and one environment, by GitHub's immutable subject
        (numeric owner and repo IDs), so a deleted or renamed repo's name can't be reused to get a token.
      - An app management policy blocks passwords and keys on the app, so not even an owner or an app
        administrator can add a secret later.
      - Roles: Reader on the subscriptions or resource groups you name; opt-in Log Analytics Reader on
        one workspace, Cost Management Reader, and Storage Blob Data Contributor on one container for the
        run's output. No directory (Graph) permission; that is a separate decision.
      - One reader for the family: each private repo that runs reads gets its own federated credential
        on the same app (Entra allows 20). Writes never use it.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    MODES
    ------------------------------------------------------------------
    Initialize  Creates or updates the reader. Run by a person: an Application Developer (or anyone, when
                users may register apps) for the app, plus Owner, User Access Administrator or a
                condition-limited Role Based Access Control Administrator on each scope. The policy step
                needs an Application Administrator; when you aren't one it prints the command for one.
                Never needs Global Administrator.
    Test        Checks the reader (the default). Signed in as a person: everything. Signed in as the
                reader itself (in the workflow): only its role assignments, which is all it can read.
    Remove      Deletes the reader's role assignments, the policy, the service principal and the app, and
                prints what it removed.

    Runs in Azure Cloud Shell (PowerShell, or Bash through pwsh) and in PowerShell 7 on Windows, macOS and
    Linux, with Az.Accounts. Uses ARM and Graph REST through Invoke-AzRestMethod, so the one Az sign-in
    covers both.

.EXAMPLE
    ./avd_ops_reader.ps1 -Mode Initialize -Repo contoso/avd-runs -Subscription 'AVD Production'

.EXAMPLE
    pwsh -NoLogo -Command './avd_ops_reader.ps1 -Mode Test'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Initialize', 'Test', 'Remove')]
    [string] $Mode = 'Test',

    # Private repos (owner/name) whose workflows may sign in as the reader.
    [string[]] $Repo = @(),

    # The GitHub Environment the workflow runs in. Restrict it to the main branch in the repo's settings.
    [string] $Environment = 'avd-reader',

    # GitHub's numeric IDs, when GitHub can't show a private repo without a sign-in (one -Repo only).
    [string] $RepoId,
    [string] $OwnerId,

    # Subscriptions (name or ID) for Reader. With -ResourceGroup, the one subscription those groups are in.
    [string[]] $Subscription = @(),

    # Resource groups for Reader instead of the whole subscription (needs exactly one -Subscription).
    [string[]] $ResourceGroup = @(),

    # Log Analytics workspace resource IDs for Log Analytics Reader (opt-in; they hold sign-in data).
    [string[]] $LogAnalyticsWorkspace = @(),

    # Cost Management Reader on the same subscriptions (opt-in).
    [switch] $Cost,

    # A blob container's resource ID for the run's output (opt-in: Storage Blob Data Contributor there only).
    [string] $OutputContainer,

    [string] $AppName = 'avd-ops-reader',

    # The reader's client ID. The app is found by this only, never by its name.
    [string] $ClientId = $env:AVD_READER_CLIENT_ID
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'lib/AvdReader.psm1') -Force

$graph = 'https://graph.microsoft.com'
$armRoleApi = '2022-04-01'
$script:failed = 0

function Write-Step {
    param([string] $Status, [string] $Check, [string] $Detail = '', [string] $Remediation = '')
    $color = @{ Pass = 'Green'; Fixed = 'Cyan'; Fail = 'Red'; Warn = 'Yellow'; Skip = 'DarkGray'; Info = 'Gray' }[$Status]
    Write-Host ('  [{0,-5}] {1}' -f $Status.ToUpper(), $Check) -ForegroundColor $color
    if ($Detail) { Write-Host "          $Detail" -ForegroundColor DarkGray }
    if ($Remediation) { Write-Host "          -> $Remediation" -ForegroundColor DarkYellow }
    if ($Status -eq 'Fail') { $script:failed++ }
}

function Invoke-Rest {
    <#
      ARM (a path) or Graph (a full URI) through Invoke-AzRestMethod. GETs follow nextLink. Any HTTP error
      throws with the method, URI, status and body, so a failure says everything the service said.
      -Allow lists statuses returned to the caller instead (404 for "not there").
    #>
    param([Parameter(Mandatory)][string] $Target, [string] $Method = 'GET', $Body, [int[]] $Allow = @())
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Target
    while ($next) {
        $p = @{ Method = $Method }
        if ($next -like 'https://*') { $p.Uri = $next; if ($next -like "$graph*") { $p.ResourceId = $graph } }
        else { $p.Path = $next }
        if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 10 -Compress) }
        $r = Invoke-AzRestMethod @p
        $code = [int]$r.StatusCode
        if ($code -in $Allow) { return [pscustomobject]@{ StatusCode = $code; Content = $r.Content } }
        if ($code -ge 400) { throw "$Method $next failed: HTTP $code $($r.Content)" }
        if (-not $r.Content) { return $null }
        $o = $r.Content | ConvertFrom-Json
        if ($Method -ne 'GET' -or -not $o.PSObject.Properties['value']) { return $o }
        foreach ($v in @($o.value)) { $items.Add($v) }
        $link = $o.PSObject.Properties['@odata.nextLink']
        if (-not $link) { $link = $o.PSObject.Properties['nextLink'] }
        $next = if ($link -and $link.Value) { "$($link.Value)" } else { $null }
        if ($next -and $next -like 'https://management.azure.com*') { $next = $next.Substring('https://management.azure.com'.Length) }
    }
    $items.ToArray()
}

function Get-ReaderApp {
    if (-not $ClientId) { return $null }
    $r = Invoke-Rest "$graph/v1.0/applications(appId='$ClientId')" -Allow 404
    if ($r -and $r.PSObject.Properties['StatusCode']) { return $null }
    $r
}

function Get-ReaderServicePrincipal {
    param([string] $AppId)
    $r = Invoke-Rest "$graph/v1.0/servicePrincipals(appId='$AppId')" -Allow 404
    if ($r -and $r.PSObject.Properties['StatusCode']) { return $null }
    $r
}

function Get-RepoInfo {
    <# GitHub's numeric IDs for owner/name, and whether the repo is private (Get-AvdReaderRepoVerdict). #>
    param([string] $FullName)
    $owner, $name = $FullName -split '/', 2
    if (-not $name) { throw "-Repo takes owner/name, got '$FullName'." }
    $headers = @{ 'User-Agent' = 'avd-ops-reader'; Accept = 'application/vnd.github+json' }
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $null }
    if ($token) { $headers.Authorization = "Bearer $token" }
    $status = 0; $body = $null
    try { $body = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$name" -Headers $headers; $status = 200 }
    catch { $status = [int]$_.Exception.Response.StatusCode }
    $ownerId = $OwnerId
    if ($status -eq 404 -and -not $ownerId -and $RepoId) {
        try { $ownerId = "$((Invoke-RestMethod -Uri "https://api.github.com/users/$owner" -Headers $headers).id)" } catch { $ownerId = $null }
    }
    $verdict = Get-AvdReaderRepoVerdict -StatusCode $status -Body $body -RepoId $RepoId -OwnerId $ownerId
    [pscustomobject]@{ Owner = $owner; Name = $name; Verdict = $verdict }
}

function Resolve-Scope {
    <# The ARM scopes and roles setup asks for, from the parameters. #>
    $subs = @(foreach ($s in $Subscription) {
            $found = @(Get-AzSubscription | Where-Object { $_.Id -eq $s -or $_.Name -eq $s })
            if ($found.Count -ne 1) { throw "Subscription '$s' matched $($found.Count) subscriptions you can see." }
            $found[0].Id
        })
    if ($ResourceGroup.Count -and $subs.Count -ne 1) { throw '-ResourceGroup needs exactly one -Subscription.' }
    $reader = (Get-AvdReaderRole -Name 'Reader').Id
    $wanted = New-Object System.Collections.Generic.List[object]
    if ($ResourceGroup.Count) { foreach ($g in $ResourceGroup) { $wanted.Add([pscustomobject]@{ Scope = "/subscriptions/$($subs[0])/resourceGroups/$g"; RoleId = $reader }) } }
    else { foreach ($s in $subs) { $wanted.Add([pscustomobject]@{ Scope = "/subscriptions/$s"; RoleId = $reader }) } }
    if ($Cost) { foreach ($s in $subs) { $wanted.Add([pscustomobject]@{ Scope = "/subscriptions/$s"; RoleId = (Get-AvdReaderRole -Name 'Cost Management Reader').Id }) } }
    foreach ($w in $LogAnalyticsWorkspace) {
        if ((Get-AvdReaderScopeKind -Scope $w) -ne 'Workspace') { throw "-LogAnalyticsWorkspace takes a workspace resource ID, got '$w'." }
        $wanted.Add([pscustomobject]@{ Scope = $w; RoleId = (Get-AvdReaderRole -Name 'Log Analytics Reader').Id })
    }
    if ($OutputContainer) {
        if ((Get-AvdReaderScopeKind -Scope $OutputContainer) -ne 'Container') { throw "-OutputContainer takes a blob container resource ID (.../blobServices/default/containers/<name>), got '$OutputContainer'." }
        $wanted.Add([pscustomobject]@{ Scope = $OutputContainer; RoleId = (Get-AvdReaderRole -Name 'Storage Blob Data Contributor').Id })
    }
    $wanted.ToArray()
}

function Get-ReaderRoleAssignment {
    <# The reader's role assignments in every subscription this sign-in can see (at, above and below each). #>
    param([string] $PrincipalId)
    $seen = @{}
    foreach ($s in @(Get-AzSubscription | Where-Object { $_.State -eq 'Enabled' })) {
        $filter = [uri]::EscapeDataString("principalId eq '$PrincipalId'")
        foreach ($a in @(Invoke-Rest "/subscriptions/$($s.Id)/providers/Microsoft.Authorization/roleAssignments?`$filter=$filter&api-version=$armRoleApi" | Where-Object { $_ })) {
            if (-not $seen.ContainsKey($a.id)) { $seen[$a.id] = $true; $a }
        }
    }
}

function Write-Finding {
    param([object[]] $Finding)
    foreach ($f in $Finding) { Write-Step $f.Status $f.Check $f.Detail $f.Remediation }
}

Write-Host ''
Write-Host "== $AppName ($Mode)" -ForegroundColor White
$ctx = Get-AzContext
if (-not $ctx) { throw 'No Azure sign-in. Run Connect-AzAccount first (Cloud Shell is already signed in).' }
$asReader = "$($ctx.Account.Type)" -eq 'ServicePrincipal' -and $ClientId -and "$($ctx.Account.Id)" -eq $ClientId

# ---- Test as the reader itself (the workflow's first step): role assignments only ----
if ($Mode -eq 'Test' -and $asReader) {
    Write-Host '  Signed in as the reader: checking its role assignments (it can''t read its own app).' -ForegroundColor DarkGray
    # The service principal's object ID is the token's oid claim; the reader may list its own role assignments.
    $tok = (Get-AzAccessToken).Token
    if ($tok -is [securestring]) { $tok = [System.Net.NetworkCredential]::new('', $tok).Password }
    $oid = (Get-AvdReaderTokenClaim -Token $tok).oid
    $mine = @(Get-ReaderRoleAssignment -PrincipalId $oid)
    Write-Finding (Get-AvdReaderFinding -RoleOnly -RoleAssignment $mine)
    if ($script:failed) { Write-Host "  $($script:failed) check(s) failed: the reader holds more than it should. Stopping." -ForegroundColor Red; exit 1 }
    exit 0
}

$app = Get-ReaderApp
if (-not $app -and $Mode -ne 'Initialize') {
    if (-not $ClientId) { throw 'Set AVD_READER_CLIENT_ID or pass -ClientId: the reader is found by its client ID only, never by name.' }
    Write-Step Fail 'App registration' "No app with client ID $ClientId in this tenant."
    exit 1
}

if ($Mode -eq 'Initialize') {
    if (-not $Repo.Count) { throw 'Name at least one private repo: -Repo owner/name.' }
    if (-not $Subscription.Count) { throw 'Name at least one subscription: -Subscription <name or ID>.' }
    if ($RepoId -and $Repo.Count -ne 1) { throw '-RepoId and -OwnerId go with exactly one -Repo.' }
    $wanted = @(Resolve-Scope)

    # GitHub first: refuse before anything is created.
    $subjects = @{}
    foreach ($r in $Repo) {
        $info = Get-RepoInfo $r
        if (-not $info.Verdict.Ok) { Write-Step Fail "Repo $r" $info.Verdict.Reason; exit 1 }
        $subjects[(Get-AvdReaderCredentialName -Owner $info.Owner -Repo $info.Name -Environment $Environment)] =
            Get-AvdReaderSubject -Owner $info.Owner -OwnerId $info.Verdict.OwnerId -Repo $info.Name -RepoId $info.Verdict.RepoId -Environment $Environment
        Write-Step Pass "Repo $r" $info.Verdict.Reason
    }

    if (-not $app) {
        if ($ClientId) { Write-Step Fail 'App registration' "No app with client ID $ClientId in this tenant." -Remediation 'Clear AVD_READER_CLIENT_ID to create a new one.'; exit 1 }
        $named = @(Invoke-Rest "$graph/v1.0/applications?`$filter=$([uri]::EscapeDataString("displayName eq '$AppName'"))&`$select=appId")
        if ($named.Count) {
            Write-Step Fail "App registration '$AppName'" "Already exists (client ID $(($named | ForEach-Object appId) -join ', '))." `
                -Remediation 'If it is yours, set AVD_READER_CLIENT_ID to its client ID and run again. An app is never reused by its name alone: anyone may register one with this name.'
            exit 1
        }
        if ($PSCmdlet.ShouldProcess($AppName, 'Create the app registration')) {
            $app = Invoke-Rest "$graph/v1.0/applications" -Method POST -Body @{
                displayName    = $AppName
                signInAudience = 'AzureADMyOrg'
                notes          = 'avd-ops-reader: read-only, app-only, federated credentials only (avd-current-state docs/reader-identity.md).'
            }
            Write-Step Fixed "App registration '$AppName'" "Created. Client ID $($app.appId), object ID $($app.id)"
        }
        else { Write-Step Skip "App registration '$AppName'" 'Would be created.'; exit 0 }
    }
    else { Write-Step Pass "App registration '$AppName'" "Client ID $($app.appId)" }

    $sp = Get-ReaderServicePrincipal $app.appId
    if (-not $sp -and $PSCmdlet.ShouldProcess($AppName, 'Create the service principal')) {
        $sp = Invoke-Rest "$graph/v1.0/servicePrincipals" -Method POST -Body @{ appId = $app.appId }
        Write-Step Fixed 'Service principal' "Created. Object ID $($sp.id)"
    }
    elseif ($sp) { Write-Step Pass 'Service principal' "Object ID $($sp.id)" }

    # Federated credentials: add what is missing; extras are reported by the test, never deleted here.
    $fics = @(Invoke-Rest "$graph/v1.0/applications/$($app.id)/federatedIdentityCredentials")
    foreach ($name in $subjects.Keys) {
        $subject = $subjects[$name]
        if (@($fics | Where-Object { $_.subject -eq $subject }).Count) { Write-Step Pass "Credential $name" $subject; continue }
        if ($PSCmdlet.ShouldProcess($name, 'Add the federated credential')) {
            $null = Invoke-Rest "$graph/v1.0/applications/$($app.id)/federatedIdentityCredentials" -Method POST -Body @{
                name = $name; issuer = 'https://token.actions.githubusercontent.com'; subject = $subject; audiences = @('api://AzureADTokenExchange')
                description = "GitHub Actions, environment $Environment"
            }
            Write-Step Fixed "Credential $name" $subject
        }
    }

    # App management policy: blocks secrets for everyone, owners and app admins included.
    $assigned = @(Invoke-Rest "$graph/v1.0/applications/$($app.id)/appManagementPolicies" -Allow 403)
    $policyDenied = $assigned.Count -eq 1 -and $assigned[0].PSObject.Properties['StatusCode']
    $policyBody = Get-AvdReaderPolicyBody -AppName $AppName
    if (-not $policyDenied -and -not @($assigned | Where-Object { $_.displayName -eq $policyBody.displayName }).Count -and
        $PSCmdlet.ShouldProcess($AppName, 'Assign an app management policy that blocks secrets')) {
        $created = Invoke-Rest "$graph/v1.0/policies/appManagementPolicies" -Method POST -Body $policyBody -Allow 403
        if ($created.PSObject.Properties['StatusCode']) { $policyDenied = $true }
        else {
            $null = Invoke-Rest "$graph/v1.0/applications/$($app.id)/appManagementPolicies/`$ref" -Method POST -Body @{ '@odata.id' = "$graph/v1.0/policies/appManagementPolicies/$($created.id)" }
            Write-Step Fixed 'Secrets blocked by policy' "Policy '$($policyBody.displayName)' assigned."
        }
    }
    if ($policyDenied) {
        Write-Step Warn 'Secrets blocked by policy' 'This sign-in can''t manage app management policies.' `
            -Remediation "An Application Administrator runs: ./avd_ops_reader.ps1 -Mode Initialize -ClientId $($app.appId) -Repo $($Repo -join ',') -Subscription $($Subscription -join ',')"
    }

    # Role assignments.
    $existing = @(Get-ReaderRoleAssignment -PrincipalId $sp.id)
    foreach ($step in @(Get-AvdReaderAssignmentPlan -Wanted $wanted -Existing $existing)) {
        $role = (Get-AvdReaderRole | Where-Object Id -eq $step.RoleId).Name
        if ($step.Action -eq 'Keep') { Write-Step Pass "$role" $step.Scope; continue }
        if (-not $PSCmdlet.ShouldProcess($step.Scope, "Assign $role")) { continue }
        $subId = ($step.Scope -split '/')[2]
        $put = Invoke-Rest "$($step.Scope)/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())?api-version=$armRoleApi" -Method PUT -Allow 403 -Body @{
            properties = @{ roleDefinitionId = "/subscriptions/$subId/providers/Microsoft.Authorization/roleDefinitions/$($step.RoleId)"; principalId = $sp.id; principalType = 'ServicePrincipal' }
        }
        if ($put -and $put.PSObject.Properties['StatusCode']) {
            $cond = Get-AvdReaderDelegationCondition
            Write-Step Fail "$role" "$($step.Scope): HTTP 403 $($put.Content)" `
                -Remediation "Run as Owner or User Access Administrator there, or as Role Based Access Control Administrator with this condition (version $($cond.Version)): $($cond.Combined)"
            continue
        }
        Write-Step Fixed "$role" $step.Scope
    }
}

# ---- Test (as a person) and Remove both read everything first ----
$sp = Get-ReaderServicePrincipal $app.appId
$fics = @(Invoke-Rest "$graph/v1.0/applications/$($app.id)/federatedIdentityCredentials")
$owners = @(Invoke-Rest "$graph/v1.0/applications/$($app.id)/owners?`$select=id")
$policies = @(Invoke-Rest "$graph/v1.0/applications/$($app.id)/appManagementPolicies" -Allow 403)
if ($policies.Count -eq 1 -and $policies[0].PSObject.Properties['StatusCode']) { $policies = @() }
$grants = if ($sp) { @(Invoke-Rest "$graph/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments") } else { @() }
$roles = if ($sp) { @(Get-ReaderRoleAssignment -PrincipalId $sp.id) } else { @() }

if ($Mode -eq 'Remove') {
    if (-not $PSCmdlet.ShouldProcess("$AppName ($($app.appId))", 'Remove the reader: role assignments, policy, service principal, app')) { exit 0 }
    foreach ($a in $roles) { $null = Invoke-Rest "$($a.id)?api-version=$armRoleApi" -Method DELETE; Write-Step Fixed 'Removed role assignment' "$($a.properties.scope) ($(($a.properties.roleDefinitionId -split '/')[-1]))" }
    foreach ($p in $policies) {
        $null = Invoke-Rest "$graph/v1.0/applications/$($app.id)/appManagementPolicies/$($p.id)/`$ref" -Method DELETE
        $users = @(Invoke-Rest "$graph/v1.0/policies/appManagementPolicies/$($p.id)/appliesTo?`$select=id")
        if (-not $users.Count -and $p.displayName -eq (Get-AvdReaderPolicyBody -AppName $AppName).displayName) { $null = Invoke-Rest "$graph/v1.0/policies/appManagementPolicies/$($p.id)" -Method DELETE }
        Write-Step Fixed 'Removed policy' $p.displayName
    }
    if ($sp) { $null = Invoke-Rest "$graph/v1.0/servicePrincipals/$($sp.id)" -Method DELETE; Write-Step Fixed 'Removed service principal' $sp.id }
    $null = Invoke-Rest "$graph/v1.0/applications/$($app.id)" -Method DELETE
    Write-Step Fixed 'Removed app registration' "Client ID $($app.appId), with its $($fics.Count) federated credential(s). Entra keeps it in Deleted applications for 30 days."
    Write-Host ''
    Write-Host '  Also delete the repository variables AVD_READER_CLIENT_ID, AVD_TENANT_ID and AVD_SUBSCRIPTION_ID in each repo.' -ForegroundColor White
    exit 0
}

$expectedSubject = @()
if ($Mode -eq 'Initialize') { $expectedSubject = @($subjects.Values) }
$expectedScope = @()
if ($Mode -eq 'Initialize') { $expectedScope = @($wanted | ForEach-Object Scope) }
Write-Host ''
Write-Host '  Checks' -ForegroundColor White
Write-Finding (Get-AvdReaderFinding -App $app -ServicePrincipal $sp -FederatedCredential $fics -Owner $owners -Policy $policies `
        -AppRoleAssignment $grants -RoleAssignment $roles -ExpectedSubject $expectedSubject -ExpectedScope $expectedScope)

if ($Mode -eq 'Initialize') {
    Write-Host ''
    Write-Host '  Set these as repository variables (Settings > Secrets and variables > Actions > Variables) in each repo:' -ForegroundColor White
    Write-Host "    AVD_READER_CLIENT_ID = $($app.appId)"
    Write-Host "    AVD_TENANT_ID        = $($ctx.Tenant.Id)"
    Write-Host "    AVD_SUBSCRIPTION_ID  = <the subscription the workflow reads>"
    Write-Host "  And here, for the next run of this script: `$env:AVD_READER_CLIENT_ID = '$($app.appId)'"
    Write-Host ''
    Write-Host "  In each repo: create the environment '$Environment', allow only the main branch to deploy to it, and" -ForegroundColor White
    Write-Host '  protect .github/workflows with a ruleset. A repo created before 2026-07-15 also turns on immutable OIDC' -ForegroundColor White
    Write-Host '  subjects (Settings > Actions > OIDC); without it, GitHub''s token won''t match the credential.' -ForegroundColor White
    Write-Host '  Sample workflow: samples/avd-ops-reader.yml' -ForegroundColor White
}
if ($script:failed) { exit 1 }
exit 0
