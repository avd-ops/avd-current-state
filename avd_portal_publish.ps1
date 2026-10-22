<#
.SYNOPSIS
    Publishes a copy of the assessment portal into your own subscription (optional), or removes it.

.DESCRIPTION
    You don't need this to run an assessment: the portal on GitHub Pages works for everyone. Publish a copy
    when you want it in your own subscription, for a fork, or pinned to a release
    (docs/assessment-portal-spec.md, phase 4; the same pattern as the landing zone's decision 0017).

      1. Checks the subscription's allowed-locations policies against the host's region before it creates
         anything.
      2. Creates the resource group (-ResourceGroupName, tagged purpose=avd-assessment-portal) holding one of:
           -Hosting StaticWebApp (default)  Azure Static Web Apps, Free plan ($0), in one of centralus, eastus2,
                                            westus2, westeurope, eastasia. Uploaded with the Static Web Apps
                                            CLI (npx, pinned version).
           -Hosting Storage                 A storage account's static website in -Location (cents a month).
                                            No npm, no deployment token, no app consent; account keys are off
                                            and you upload with your own sign-in. Anyone with the URL can open it.
      3. Uploads site/portal and site/assets with a portal-config.js naming the repo and the tag or commit
         every command clones and checks out (-RepoUrl, -Ref; default: this checkout's origin and commit).
      4. Prints the portal's URL.

    -RequireSignIn (StaticWebApp only) locks every page to users you invite to the 'operator' role (up to 25
    on the Free plan) and invites you. The Free plan's sign-in accepts any Microsoft account, so signing in
    alone is never enough. Single-tenant sign-in, IP restrictions and private endpoints need the Standard
    plan (about $9 a month): your choice in the Azure portal, never this script's.

    The Static Web Apps deployment token never leaves this process: it goes to the CLI in an environment
    variable, is cleared, and is reset after the upload so the token this shell saw is dead.

    -Remove deletes the resource group, and only one this script made (the purpose tag).

    The page holds no secrets and pasted output never leaves the browser. Writes to Azure: the resource group,
    the site or storage account, and (Storage) a Storage Blob Data Contributor assignment for you on that
    account. Runs in Azure Cloud Shell (PowerShell) at the repo root, with Az.Accounts, and Az.Storage for
    -Hosting Storage. Uses ARM REST through Invoke-AzRestMethod.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

.EXAMPLE
    ./avd_portal_publish.ps1 -Location eastus2

.EXAMPLE
    ./avd_portal_publish.ps1 -Location northcentralus -Hosting Storage

.EXAMPLE
    ./avd_portal_publish.ps1 -Location eastus2 -RequireSignIn -RepoUrl https://github.com/contoso/avd-current-state -Ref v1.2.0

.EXAMPLE
    ./avd_portal_publish.ps1 -Remove
#>
[CmdletBinding()]
param(
    # The resource group's region and, for Storage, the account's.
    [string] $Location,

    [ValidateSet('StaticWebApp', 'Storage')]
    [string] $Hosting = 'StaticWebApp',

    # Empty: -Location when Static Web Apps is offered there, else the first one the policies allow.
    [ValidateSet('', 'centralus', 'eastus2', 'westus2', 'westeurope', 'eastasia')]
    [string] $StaticWebAppLocation = '',

    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string] $ResourceGroupName = 'rg-avd-assessment-portal',

    [switch] $RequireSignIn,

    # The repo the portal's commands clone, and the tag or commit they check out. Empty: this checkout's.
    [string] $RepoUrl,
    [string] $Ref,

    # A subscription name or ID. Empty: the current one.
    [string] $Subscription,

    [switch] $Remove
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'This script needs PowerShell 7.2 or later (Cloud Shell has it): run it with pwsh.' }
Import-Module (Join-Path $PSScriptRoot 'lib/AvdPortalPublish.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib/AvdReader.psm1') -Force

# Pinned on purpose: bump it in a PR, never float it.
$swaCli = '@azure/static-web-apps-cli@2.1.0'
$webApi = '2023-12-01'
$storageApi = '2023-05-01'
$rgApi = '2021-04-01'
$roleApi = '2022-04-01'
# Storage Blob Data Contributor: you write the files into $web with your own sign-in (no account keys).
$blobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
$script:failed = 0

function Write-Step {
    param([string] $Status, [string] $Check, [string] $Detail = '', [string] $Remediation = '')
    $color = @{ Pass = 'Green'; Fixed = 'Cyan'; Fail = 'Red'; Warn = 'Yellow'; Skip = 'DarkGray'; Info = 'Gray' }[$Status]
    Write-Host ('  [{0,-5}] {1}' -f $Status.ToUpper(), $Check) -ForegroundColor $color
    if ($Detail) { Write-Host "          $Detail" -ForegroundColor DarkGray }
    if ($Remediation) { Write-Host "          -> $Remediation" -ForegroundColor DarkYellow }
    if ($Status -eq 'Fail') { $script:failed++ }
}

function Invoke-Arm {
    <#
      ARM (a path) or Graph (a full URI) through Invoke-AzRestMethod. GETs follow nextLink. Any HTTP error
      throws with the method, path, status and body. -Allow lists statuses returned to the caller instead.
    #>
    param([Parameter(Mandatory)][string] $Target, [string] $Method = 'GET', $Body, [int[]] $Allow = @())
    $items = New-Object System.Collections.Generic.List[object]
    $next = $Target
    while ($next) {
        $p = @{ Method = $Method }
        if ($next -like 'https://*') { $p.Uri = $next; if ($next -like 'https://graph.microsoft.com*') { $p.ResourceId = 'https://graph.microsoft.com' } }
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
        $link = $o.PSObject.Properties['nextLink']
        $next = if ($link -and $link.Value) { "$($link.Value)" -replace '^https://management\.azure\.com', '' } else { $null }
    }
    $items.ToArray()
}

function Wait-Arm {
    <# GETs a resource until the test passes, then returns it; stops after the tries with what it last saw. #>
    param([string] $Path, [scriptblock] $Ready, [string] $What, [int] $Tries = 40, [int] $Seconds = 10)
    for ($i = 1; $i -le $Tries; $i++) {
        $r = Invoke-Arm $Path -Allow 404
        if ($r -and -not ($r.PSObject.Properties['StatusCode'] -and $r.StatusCode -eq 404) -and (& $Ready $r)) { return $r }
        if ($i -lt $Tries) { Start-Sleep -Seconds $Seconds }
    }
    throw "$What was not ready after $($Tries * $Seconds) seconds. Last answer: $($r | ConvertTo-Json -Depth 6 -Compress)"
}

function Get-ResourceGroup {
    $r = Invoke-Arm "$sub/resourcegroups/$($ResourceGroupName)?api-version=$rgApi" -Allow 404
    if ($r -and $r.PSObject.Properties['StatusCode'] -and $r.StatusCode -eq 404) { return $null }
    $r
}

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Azure sign-in. Run Connect-AzAccount first (Cloud Shell is already signed in).' }
if ($Subscription) {
    Write-Host "  Switching to subscription $Subscription..." -ForegroundColor DarkGray
    $ctx = Set-AzContext -Subscription $Subscription
}
$sub = "/subscriptions/$($ctx.Subscription.Id)"
Write-Host ''
Write-Host "== AVD assessment portal - $ResourceGroupName in '$($ctx.Subscription.Name)'" -ForegroundColor White

# ---------------------------------------------------------------------
# -Remove: only the resource group this script made
# ---------------------------------------------------------------------
if ($Remove) {
    $verdict = Get-AvdcsPortalRemoveVerdict -ResourceGroupName $ResourceGroupName -ResourceGroup (Get-ResourceGroup)
    switch ($verdict.Action) {
        'None' { Write-Step Pass 'Published portal' $verdict.Detail }
        'Refuse' { Write-Step Fail 'Published portal' $verdict.Detail }
        'Delete' {
            Write-Host "  Deleting $ResourceGroupName (a minute or two)..." -ForegroundColor DarkGray
            $null = Invoke-Arm "$sub/resourcegroups/$($ResourceGroupName)?api-version=$rgApi" -Method DELETE
            $gone = $false
            for ($i = 1; $i -le 60 -and -not $gone; $i++) {
                if ($null -eq (Get-ResourceGroup)) { $gone = $true } else { Start-Sleep -Seconds 10 }
            }
            if ($gone) { Write-Step Fixed 'Published portal' "Deleted $($verdict.Detail)" }
            else { Write-Step Fail 'Published portal' "$ResourceGroupName is still there after 10 minutes." 'Check it in the Azure portal (Resource groups) and rerun -Remove.' }
        }
    }
    if ($script:failed) { exit 1 }
    exit 0
}

if (-not $Location) { throw 'Pass -Location: the region of the resource group (and of the storage account, with -Hosting Storage).' }
if ($RequireSignIn -and $Hosting -ne 'StaticWebApp') { throw '-RequireSignIn needs -Hosting StaticWebApp: a storage static website has no sign-in.' }

# ---------------------------------------------------------------------
# 1. What the commands will run, and where the portal can go
# ---------------------------------------------------------------------
Write-Host ''
Write-Host '  Source' -ForegroundColor White
if (-not $RepoUrl) {
    $origin = "$(git -C $PSScriptRoot remote get-url origin 2>$null)".Trim()
    $RepoUrl = $origin -replace '^git@github\.com:', 'https://github.com/' -replace '\.git$', ''
}
if (-not $Ref) { $Ref = "$(git -C $PSScriptRoot rev-parse HEAD 2>$null)".Trim() }
$global:LASTEXITCODE = 0
if (-not $RepoUrl -or -not $Ref) { throw 'Could not read the repo URL or commit from this checkout. Pass -RepoUrl and -Ref.' }
# Checks both (throws with the reason); the page checks them again before it uses them.
$null = Get-AvdcsPortalConfigScript -RepoUrl $RepoUrl -Ref $Ref -PortalUrl 'https://example.com/' -Hosting $Hosting
Write-Step Pass 'Commands clone and check out' "$RepoUrl at $Ref"

Write-Host ''
Write-Host '  Region and policy' -ForegroundColor White
Write-Host '  Reading the subscription''s policy assignments...' -ForegroundColor DarkGray
$assignments = @(Invoke-Arm "$sub/providers/Microsoft.Authorization/policyAssignments?api-version=2024-04-01")
$region = Get-AvdcsPortalHostRegion -Hosting $Hosting -Location $Location -StaticWebAppLocation $StaticWebAppLocation -Assignments $assignments
if (-not $region.Allowed) {
    Write-Step Fail "Region $($region.ResourceLocation)" $region.Detail $region.Remediation
    exit 1
}
Write-Step Pass "Region $($region.ResourceLocation)" $(if ($Hosting -eq 'StaticWebApp') { "Resource group in $($region.Location); Static Web Apps serves the files from everywhere." } else { '' })

if ($Hosting -eq 'StaticWebApp' -and -not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Write-Step Fail 'npx (Node.js) for the Static Web Apps CLI' '' 'Run this in Azure Cloud Shell, which has Node.js, or publish with -Hosting Storage.'
    exit 1
}
if ($Hosting -eq 'Storage' -and -not (Get-Module -ListAvailable -Name Az.Storage)) {
    Write-Step Fail 'Az.Storage module' '' 'Run this in Azure Cloud Shell, which has it, or Install-Module Az.Storage -Scope CurrentUser.'
    exit 1
}

# Who you are: the uploader (Storage) and the invited operator (-RequireSignIn).
$tok = (Get-AzAccessToken).Token
if ($tok -is [securestring]) { $tok = [System.Net.NetworkCredential]::new('', $tok).Password }
$claims = Get-AvdReaderTokenClaim -Token $tok
$tok = $null
$meId = "$($claims.oid)"
$meType = if ($claims.PSObject.Properties['idtyp'] -and "$($claims.idtyp)" -eq 'app') { 'ServicePrincipal' } else { 'User' }
$meName = if ($claims.PSObject.Properties['upn']) { "$($claims.upn)" } elseif ($claims.PSObject.Properties['unique_name']) { "$($claims.unique_name)" } else { '' }

# ---------------------------------------------------------------------
# 2. The resource group and the host
# ---------------------------------------------------------------------
Write-Host ''
Write-Host '  Host' -ForegroundColor White
$existing = Get-ResourceGroup
if ($existing -and (Get-AvdcsPortalRemoveVerdict -ResourceGroupName $ResourceGroupName -ResourceGroup $existing).Action -eq 'Refuse') {
    Write-Step Fail "Resource group $ResourceGroupName" 'It exists and this script did not make it (no purpose=avd-assessment-portal tag).' 'Pass -ResourceGroupName with a new name.'
    exit 1
}
$tags = @{ purpose = (Get-AvdcsPortalPurposeTag); managedBy = 'avd_portal_publish.ps1'; workload = 'avd' }
$null = Invoke-Arm "$sub/resourcegroups/$($ResourceGroupName)?api-version=$rgApi" -Method PUT -Body @{ location = $region.Location; tags = $tags }
Write-Step Pass "Resource group $ResourceGroupName" $region.Location
$names = Get-AvdcsPortalName -SubscriptionId $ctx.Subscription.Id -ResourceGroupName $ResourceGroupName
$rgPath = "$sub/resourceGroups/$ResourceGroupName"

if ($Hosting -eq 'StaticWebApp') {
    $siteId = "$rgPath/providers/Microsoft.Web/staticSites/$($names.StaticSite)"
    Write-Host "  Creating the Static Web Apps site $($names.StaticSite) (a minute)..." -ForegroundColor DarkGray
    $null = Invoke-Arm "$($siteId)?api-version=$webApi" -Method PUT -Body @{
        location = $region.ResourceLocation; tags = $tags; sku = @{ name = 'Free'; tier = 'Free' }
        # Files are uploaded from Cloud Shell with a deployment token, not from a linked repository.
        properties = @{ stagingEnvironmentPolicy = 'Disabled'; allowConfigFileUpdates = $true }
    }
    $site = Wait-Arm "$($siteId)?api-version=$webApi" { param($s) $s.properties.PSObject.Properties['defaultHostname'] -and $s.properties.defaultHostname } 'The Static Web Apps site'
    if ("$($site.sku.name)" -ne 'Free') {
        Write-Step Warn 'Static Web Apps plan' "The site is on the $($site.sku.name) plan, which is billed (about `$9 a month for Standard)." 'Leave it if you chose it; this script never changes the plan.'
    }
    $portalRoot = "https://$($site.properties.defaultHostname)/"
    Write-Step Pass "Static Web Apps $($names.StaticSite)" $portalRoot
}
else {
    $accountId = "$rgPath/providers/Microsoft.Storage/storageAccounts/$($names.Storage)"
    Write-Host "  Creating the storage account $($names.Storage) (a minute)..." -ForegroundColor DarkGray
    $null = Invoke-Arm "$($accountId)?api-version=$storageApi" -Method PUT -Body @{
        location = $region.Location; tags = $tags; kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }
        # The static website endpoint serves $web anonymously whatever these say; blobs stay private and keys stay off.
        properties = @{ minimumTlsVersion = 'TLS1_2'; supportsHttpsTrafficOnly = $true; allowBlobPublicAccess = $false; allowSharedKeyAccess = $false; defaultToOAuthAuthentication = $true }
    }
    $account = Wait-Arm "$($accountId)?api-version=$storageApi" { param($a) "$($a.properties.provisioningState)" -eq 'Succeeded' } 'The storage account'
    $portalRoot = "$($account.properties.primaryEndpoints.web)"
    $assignment = Get-AvdcsPortalRoleAssignmentName -Scope $accountId -PrincipalId $meId -RoleDefinitionId $blobDataContributor
    $ra = Invoke-Arm "$accountId/providers/Microsoft.Authorization/roleAssignments/$($assignment)?api-version=$roleApi" -Method PUT -Allow 409 -Body @{
        properties = @{ roleDefinitionId = "$sub/providers/Microsoft.Authorization/roleDefinitions/$blobDataContributor"; principalId = $meId; principalType = $meType }
    }
    if ($ra -and $ra.PSObject.Properties['StatusCode'] -and $ra.StatusCode -eq 409 -and "$($ra.Content)" -notmatch 'RoleAssignmentExists') { throw "The upload role on $($names.Storage) was refused: HTTP 409 $($ra.Content)" }
    Write-Step Pass "Storage account $($names.Storage)" "$portalRoot (you hold Storage Blob Data Contributor on it to upload)"
}

# ---------------------------------------------------------------------
# 3. The files: the portal and the design system and engine it loads, plus this copy's config
# ---------------------------------------------------------------------
Write-Host ''
Write-Host '  Files' -ForegroundColor White
$stage = Join-Path ([IO.Path]::GetTempPath()) "avdcs-portal-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
try {
    New-Item -ItemType Directory -Path $stage | Out-Null
    foreach ($d in 'portal', 'assets') { Copy-Item -Recurse -Path (Join-Path $PSScriptRoot "site/$d") -Destination (Join-Path $stage $d) }
    Set-Content -Path (Join-Path $stage 'portal/portal-config.js') -Value (Get-AvdcsPortalConfigScript -RepoUrl $RepoUrl -Ref $Ref -PortalUrl "$($portalRoot)portal/" -Hosting $Hosting) -NoNewline
    # The site root opens the portal.
    Set-Content -Path (Join-Path $stage 'index.html') -Value '<!doctype html><meta charset="utf-8"><title>AVD assessment portal</title><meta http-equiv="refresh" content="0; url=portal/"><p><a href="portal/">AVD assessment portal</a></p>'
    if ($Hosting -eq 'StaticWebApp') {
        Set-Content -Path (Join-Path $stage 'staticwebapp.config.json') -Value (Get-AvdcsStaticWebAppConfig -RequireSignIn:$RequireSignIn)
        if ($RequireSignIn) {
            Set-Content -Path (Join-Path $stage 'denied.html') -Value '<!doctype html><meta charset="utf-8"><title>Not invited</title><p>You are signed in, but not invited to this assessment portal. Ask its owner for an invitation to the operator role, then <a href="/.auth/logout">sign out</a> and back in.</p>'
        }
    }
    $files = @(Get-ChildItem -Path $stage -Recurse -File)
    Write-Step Pass 'Files staged' "$($files.Count) files, config for $RepoUrl at $Ref."

    # -------------------------------------------------------------------
    # 4. Upload
    # -------------------------------------------------------------------
    Write-Host ''
    Write-Host '  Upload' -ForegroundColor White
    if ($Hosting -eq 'StaticWebApp') {
        $token = (Invoke-Arm "$siteId/listSecrets?api-version=$webApi" -Method POST).properties.apiKey
        if (-not $token) { throw "Static Web Apps returned no deployment token for $($names.StaticSite)." }
        Write-Host "  Uploading with $swaCli (npx downloads it the first time)..." -ForegroundColor DarkGray
        try {
            $env:SWA_CLI_DEPLOYMENT_TOKEN = $token
            $out = & npx --yes $swaCli deploy $stage --env production --no-use-keychain 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally {
            Remove-Item Env:SWA_CLI_DEPLOYMENT_TOKEN -ErrorAction SilentlyContinue
            $token = $null
        }
        # Kill the token this shell held, whether or not the upload worked.
        $null = Invoke-Arm "$siteId/resetapikey?api-version=$webApi" -Method POST -Body @{ properties = @{ shouldUpdateRepository = $false } }
        if ($code -ne 0) {
            $tail = (($out -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last 15) -join "`n          "
            Write-Step Fail 'Upload (Static Web Apps CLI)' "Exit code $code. Last lines:`n          $tail" 'Rerun; if npm is blocked here, publish with -Hosting Storage.'
        }
        else { Write-Step Pass 'Upload (Static Web Apps CLI)' 'Deployment token reset after the upload.' }

        if ($RequireSignIn -and $meType -eq 'User' -and $meName) {
            $inv = Invoke-Arm "$siteId/createUserInvitation?api-version=$webApi" -Method POST -Body @{ properties = @{
                    domain = $site.properties.defaultHostname; provider = 'aad'; userDetails = $meName; roles = 'operator'; numHoursToExpiration = 168
                }
            }
            Write-Step Pass "Invitation for $meName" "Open within 7 days, signed in as that account: $($inv.properties.invitationUrl)" 'Invite other operators in the Azure portal (Static Web App > Role management, role operator), up to 25.'
        }
        elseif ($RequireSignIn) {
            Write-Step Warn 'Invitation' 'This sign-in has no user name to invite.' 'Invite operators in the Azure portal (Static Web App > Role management, role operator).'
        }
    }
    else {
        $sctx = New-AzStorageContext -StorageAccountName $names.Storage -UseConnectedAccount
        Write-Host '  Turning on the static website...' -ForegroundColor DarkGray
        $null = Enable-AzStorageStaticWebsite -Context $sctx -IndexDocument 'index.html' -ErrorDocument404Path 'index.html'
        # The role assigned above can take a few minutes to apply: retry, then stop.
        $uploaded = 0; $attempt = 0; $wait = 20; $max = 9
        foreach ($f in $files) {
            $blob = [IO.Path]::GetRelativePath($stage, $f.FullName).Replace('\', '/')
            while ($true) {
                try {
                    $null = Set-AzStorageBlobContent -Context $sctx -Container '$web' -File $f.FullName -Blob $blob -Force -Properties @{ ContentType = (Get-AvdcsPortalContentType -Path $blob); CacheControl = 'no-cache' } -ErrorAction Stop
                    $uploaded++
                    break
                }
                catch {
                    if ("$_" -notmatch '403|AuthorizationPermissionMismatch|not authorized') { throw }
                    $attempt++
                    if ($attempt -ge $max) { throw "Upload still forbidden after $attempt tries ($("$_")). The Storage Blob Data Contributor role on $($names.Storage) may not have applied yet: rerun in a few minutes." }
                    Write-Host "  The upload role isn't active yet; waiting $wait seconds ($attempt of $max)..." -ForegroundColor DarkGray
                    Start-Sleep -Seconds $wait
                }
            }
        }
        # Files removed from site/ since the last publish.
        $keep = @($files | ForEach-Object { [IO.Path]::GetRelativePath($stage, $_.FullName).Replace('\', '/') })
        $stale = @(Get-AzStorageBlob -Context $sctx -Container '$web' -ErrorAction SilentlyContinue | Where-Object { $_ -and $keep -notcontains $_.Name })
        foreach ($b in $stale) { Remove-AzStorageBlob -Context $sctx -Container '$web' -Blob $b.Name -Force }
        Write-Step Pass 'Upload ($web)' "$uploaded files$(if ($stale.Count) { ", $($stale.Count) old ones removed" })."
    }
}
finally {
    Remove-Item -Recurse -Force -Path $stage -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
# 5. Where it is
# ---------------------------------------------------------------------
if ($script:failed) { exit 1 }
Write-Host ''
Write-Host "Portal: $($portalRoot)portal/" -ForegroundColor Green
Write-Host "Its commands clone $RepoUrl at $Ref. Remove it with: ./avd_portal_publish.ps1 -Remove$(if ($ResourceGroupName -ne 'rg-avd-assessment-portal') { " -ResourceGroupName $ResourceGroupName" })" -ForegroundColor DarkGray
if ($Hosting -eq 'Storage') { Write-Host 'Anyone with this URL can open the portal. It holds no secrets and pasted output never leaves the browser, but treat the URL as internal.' -ForegroundColor DarkGray }
exit 0
