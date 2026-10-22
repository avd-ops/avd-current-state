<#
    The pure parts of avd_portal_publish.ps1, which publishes a copy of the assessment portal into the
    operator's own subscription (docs/assessment-portal-spec.md, phase 4; the landing zone's decision 0017
    pattern). Each function takes data read from Azure and returns data, so tests/PortalPublish.Tests.ps1
    checks them offline.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.
#>

Set-StrictMode -Version Latest

# The regions where Static Web Apps offers the Free plan.
$script:StaticWebAppRegions = @('centralus', 'eastus2', 'westus2', 'westeurope', 'eastasia')
# Built-in policy definitions: Allowed locations, and Allowed locations for resource groups (public IDs, the
# same in every tenant).
$script:AllowedLocationsPolicyIds = @{ Resources = 'e56962a6-4747-49cd-b67b-bf8b01975c4c'; ResourceGroups = 'e765b5de-1225-4ba3-bd56-1ac6695af988' }
# The tag that marks a resource group this script made; -Remove deletes nothing without it.
$script:PurposeTag = 'avd-assessment-portal'

function Get-AvdcsPortalStaticWebAppRegion {
    <# The regions Static Web Apps' Free plan is offered in. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    , $script:StaticWebAppRegions
}

function Get-AvdcsPortalPurposeTag {
    <# The value of the purpose tag on the resource group this script makes. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:PurposeTag
}

function Get-AvdcsPortalHostRegion {
    <#
    .SYNOPSIS
        Where the portal's resources go, and whether an allowed-locations policy lets them.
    .DESCRIPTION
        Assignments: the subscription's policy assignments, as ARM returns them. Returns Location (the resource
        group's), ResourceLocation (the host's), Allowed, and Detail and Remediation when it is blocked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('StaticWebApp', 'Storage')][string] $Hosting,
        [Parameter(Mandatory)][string] $Location,
        [string] $StaticWebAppLocation,
        [AllowEmptyCollection()][object[]] $Assignments = @()
    )
    $allowed = {
        param($kind, $all)
        $id = $script:AllowedLocationsPolicyIds[$kind]
        $lists = @($all | Where-Object { $_ -and "$($_.properties.policyDefinitionId)" -like "*/$id" -and "$($_.properties.enforcementMode)" -ne 'DoNotEnforce' } |
                ForEach-Object {
                    $p = $_.properties.PSObject.Properties['parameters']
                    $v = if ($p -and $p.Value -and $p.Value.PSObject.Properties['listOfAllowedLocations']) { $p.Value.listOfAllowedLocations.value } else { @() }
                    , @($v | Where-Object { $_ })
                })
        if (-not $lists.Count) { return $null }
        # Every assignment must allow it: intersect the lists.
        $set = $lists[0]
        foreach ($l in $lists) { $set = @($set | Where-Object { $l -contains $_ }) }
        , @($set | ForEach-Object { "$_".ToLower() })
    }
    $res = & $allowed 'Resources' $Assignments
    $rgs = & $allowed 'ResourceGroups' $Assignments
    $where = $Location.ToLower()
    if ($Hosting -eq 'StaticWebApp') {
        $where = if ($StaticWebAppLocation) { $StaticWebAppLocation.ToLower() }
        elseif ($script:StaticWebAppRegions -contains $Location.ToLower() -and (-not $res -or $res -contains $Location.ToLower())) { $Location.ToLower() }
        elseif ($res) { @(@($script:StaticWebAppRegions | Where-Object { $res -contains $_ }) + @('centralus'))[0] }
        else { 'centralus' }
    }
    $out = [ordered]@{ Hosting = $Hosting; Location = $Location.ToLower(); ResourceLocation = $where; Allowed = $true; Detail = ''; Remediation = '' }
    if ($Hosting -eq 'StaticWebApp' -and $script:StaticWebAppRegions -notcontains $where) {
        $out.Allowed = $false
        $out.Detail = "Static Web Apps isn't offered in $where; it is in $($script:StaticWebAppRegions -join ', ')."
        $out.Remediation = "Pass -StaticWebAppLocation with one of those, or publish to a storage static website in $($Location.ToLower()) with -Hosting Storage."
    }
    elseif ($rgs -and $rgs -notcontains $out.Location) {
        $out.Allowed = $false
        $out.Detail = "An allowed-locations policy blocks resource groups in $($out.Location) (allowed: $($rgs -join ', '))."
        $out.Remediation = "Pass -Location with one of: $($rgs -join ', ')."
    }
    elseif ($res -and $res -notcontains $where) {
        $out.Allowed = $false
        $out.Detail = "An allowed-locations policy blocks resources in $where (allowed: $($res -join ', '))."
        $out.Remediation = if ($Hosting -eq 'StaticWebApp') { "Static Web Apps needs one of $($script:StaticWebAppRegions -join ', ') on the allowed list (or a policy exemption), or publish with -Hosting Storage, which uses $($out.Location)." } else { "Pass -Location with one of: $($res -join ', ')." }
    }
    [pscustomobject]$out
}

function Get-AvdcsPortalName {
    <#
    .SYNOPSIS
        The names of the portal's resources: the Static Web Apps site, and a storage account name that is the
        same on every rerun in this subscription and resource group, and unlikely to be taken elsewhere.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroupName
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$SubscriptionId/$ResourceGroupName".ToLower())) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    [pscustomobject]@{ StaticSite = 'stapp-avd-assessment-portal'; Storage = "stavdassess$($hash.Substring(0, 12))" }
}

function Get-AvdcsPortalRoleAssignmentName {
    <# A role assignment's name (a GUID) that is the same on every rerun, so a rerun finds the one it made. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Scope,
        [Parameter(Mandatory)][string] $PrincipalId,
        [Parameter(Mandatory)][string] $RoleDefinitionId
    )
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Scope|$PrincipalId|$RoleDefinitionId".ToLower())) }
    finally { $md5.Dispose() }
    ([guid]::new($bytes)).ToString()
}

function Get-AvdcsPortalConfigScript {
    <#
    .SYNOPSIS
        The portal-config.js a published copy serves: one JSON object on one known global. The page checks
        repoUrl and ref again (assess-core.js setSource) before it puts either in a command.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $RepoUrl,
        [Parameter(Mandatory)][string] $Ref,
        [Parameter(Mandatory)][string] $PortalUrl,
        [Parameter(Mandatory)][ValidateSet('StaticWebApp', 'Storage')][string] $Hosting
    )
    if ($RepoUrl -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?$' -or $RepoUrl -match '\.\.') { throw "-RepoUrl must be a GitHub repository URL (https://github.com/<owner>/<repo>), not '$RepoUrl'." }
    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$' -or $Ref -match '\.\.|//|/$|\.lock$') { throw "-Ref must be a tag or commit, not '$Ref'." }
    if ($PortalUrl -notmatch '^https://[A-Za-z0-9.-]+(:\d+)?/[A-Za-z0-9._/-]*$') { throw "The portal URL '$PortalUrl' is not an https URL." }
    $cfg = [ordered]@{ repoUrl = $RepoUrl.TrimEnd('/'); ref = $Ref; portalUrl = $PortalUrl; hosting = $Hosting }
    $json = $cfg | ConvertTo-Json -Compress
    "/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.`n   Written by avd_portal_publish.ps1 for this copy of the assessment portal. */`nwindow.AVDCS_PORTAL_CONFIG = $json;`n"
}

function Get-AvdcsStaticWebAppConfig {
    <#
    .SYNOPSIS
        staticwebapp.config.json for a published copy: the response headers GitHub Pages can't set, and with
        -RequireSignIn every route locked to the invited 'operator' role. The Free plan's built-in sign-in lets
        any Microsoft account in, so 'authenticated' alone is never used, and GitHub sign-in is turned off.
    .DESCRIPTION
        The page makes no request (connect-src 'none') and loads no inline script; its one style block needs
        style-src 'unsafe-inline'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch] $RequireSignIn)
    $csp = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    $config = [ordered]@{
        globalHeaders = [ordered]@{
            'Content-Security-Policy' = $csp
            'X-Frame-Options'         = 'DENY'
            'X-Content-Type-Options'  = 'nosniff'
            'Referrer-Policy'         = 'no-referrer'
        }
    }
    if ($RequireSignIn) {
        $config.routes = @(
            [ordered]@{ route = '/.auth/login/github'; statusCode = 404 },
            [ordered]@{ route = '/.auth/*'; allowedRoles = @('anonymous') },
            [ordered]@{ route = '/denied.html'; allowedRoles = @('anonymous') },
            [ordered]@{ route = '/*'; allowedRoles = @('operator') }
        )
        $config.responseOverrides = [ordered]@{
            '401' = [ordered]@{ redirect = '/.auth/login/aad'; statusCode = 302 }
            '403' = [ordered]@{ rewrite = '/denied.html'; statusCode = 403 }
        }
    }
    $config | ConvertTo-Json -Depth 6
}

function Get-AvdcsPortalContentType {
    <# The Content-Type a storage static website serves a file with (a blob keeps the type it was uploaded with). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)
    $types = @{
        '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'; '.md' = 'text/markdown; charset=utf-8'; '.txt' = 'text/plain; charset=utf-8'
        '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2'
    }
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    if ($types.ContainsKey($ext)) { $types[$ext] } elseif ([IO.Path]::GetFileName($Path) -eq 'LICENSE') { 'text/plain; charset=utf-8' } else { 'application/octet-stream' }
}

function Get-AvdcsPortalRemoveVerdict {
    <#
    .SYNOPSIS
        What -Remove does with the resource group it found: nothing when it is not there, refuse when this
        script didn't make it (no purpose tag), delete otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ResourceGroupName,
        [AllowNull()] $ResourceGroup
    )
    if ($null -eq $ResourceGroup) { return [pscustomobject]@{ Action = 'None'; Detail = "$ResourceGroupName is not there." } }
    $tags = $ResourceGroup.PSObject.Properties['tags']
    $purpose = if ($tags -and $tags.Value -and $tags.Value.PSObject.Properties['purpose']) { "$($tags.Value.purpose)" } else { '' }
    if ($purpose -ne $script:PurposeTag) {
        return [pscustomobject]@{ Action = 'Refuse'; Detail = "$ResourceGroupName has no purpose=$($script:PurposeTag) tag, so this script didn't make it. It deletes nothing it didn't make: check what is in it and delete it yourself if you mean to." }
    }
    [pscustomobject]@{ Action = 'Delete'; Detail = "$ResourceGroupName (purpose=$($script:PurposeTag))." }
}

Export-ModuleMember -Function Get-AvdcsPortal*, Get-AvdcsStaticWebAppConfig
