<#
    The optional avd-ops-reader identity (docs/reader-identity.md): checks and plans as pure functions.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    avd_ops_reader.ps1 reads Microsoft Graph and ARM and hands the objects here; nothing in this module
    calls Azure or GitHub, so every rule tests offline. The collector and validator never load it: they
    work with whatever Az context they find, the reader's or a person's (the self-contained pair).
    Windows PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest

$script:GitHubIssuer = 'https://token.actions.githubusercontent.com'
$script:Audience = 'api://AzureADTokenExchange'

# Microsoft's built-in role definition IDs (public, the same in every tenant). The only roles the reader may hold.
$script:Roles = @(
    [pscustomobject]@{ Name = 'Reader'; Id = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'; ScopeKind = 'Arm' }
    [pscustomobject]@{ Name = 'Log Analytics Reader'; Id = '73c42c96-874c-492b-b04d-ab87d138a893'; ScopeKind = 'Workspace' }
    [pscustomobject]@{ Name = 'Cost Management Reader'; Id = '72fafb9e-0641-4937-9268-a91bfd8191a3'; ScopeKind = 'Arm' }
    [pscustomobject]@{ Name = 'Storage Blob Data Contributor'; Id = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'; ScopeKind = 'Container' }
)

# Credential types an app management policy must block, so nobody (owner or admin) can add a secret.
$script:BlockedCredentials = @('passwordAddition', 'customPasswordAddition', 'symmetricKeyAddition')

function Get-Prop {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

function Get-AvdReaderRole {
    <# The roles the reader may hold, with their built-in IDs and the kind of scope each one is allowed on. #>
    [CmdletBinding()]
    param([string] $Name)
    if ($Name) { return @($script:Roles | Where-Object { $_.Name -eq $Name }) }
    $script:Roles
}

function Get-AvdReaderScopeKind {
    <# What an ARM scope is: Root, ManagementGroup, Subscription, ResourceGroup, Workspace, Container or Resource. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Scope)
    $s = $Scope.TrimEnd('/')
    if ($s -eq '') { return 'Root' }
    if ($s -match '(?i)^/providers/Microsoft\.Management/managementGroups/[^/]+$') { return 'ManagementGroup' }
    if ($s -match '(?i)^/subscriptions/[^/]+$') { return 'Subscription' }
    if ($s -match '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+$') { return 'ResourceGroup' }
    if ($s -match '(?i)/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') { return 'Workspace' }
    if ($s -match '(?i)/providers/Microsoft\.Storage/storageAccounts/[^/]+/blobServices/default/containers/[^/]+$') { return 'Container' }
    'Resource'
}

function Get-AvdReaderSubject {
    <#
      GitHub's immutable OIDC subject for one repo and one environment. Names alone can be recycled when a
      repo is deleted or renamed; the numeric owner and repo IDs never are.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Owner,
        [Parameter(Mandatory)][string] $OwnerId,
        [Parameter(Mandatory)][string] $Repo,
        [Parameter(Mandatory)][string] $RepoId,
        [Parameter(Mandatory)][string] $Environment
    )
    if ($OwnerId -notmatch '^\d+$' -or $RepoId -notmatch '^\d+$') { throw "Owner and repo IDs must be GitHub's numeric IDs (got '$OwnerId', '$RepoId')." }
    if ($Owner -notmatch '^[A-Za-z0-9-]+$' -or $Repo -notmatch '^[A-Za-z0-9._-]+$') { throw "Not a GitHub owner/repo name: $Owner/$Repo" }
    if ($Environment -notmatch '^[A-Za-z0-9._-]{1,255}$') { throw "Environment names here use letters, digits, '.', '_' and '-' only: '$Environment'" }
    "repo:$Owner@$OwnerId/$Repo@$RepoId`:environment:$Environment"
}

function Get-AvdReaderCredentialName {
    <# The federated credential's name: unique per repo and environment, within Entra's 3 to 120 characters. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Owner, [Parameter(Mandatory)][string] $Repo, [Parameter(Mandatory)][string] $Environment)
    $name = ('gh-{0}-{1}-{2}' -f $Owner, $Repo, $Environment) -replace '[^A-Za-z0-9_-]', '-'
    if ($name.Length -gt 120) { $name = $name.Substring(0, 120) }
    $name
}

function Get-AvdReaderRepoVerdict {
    <#
      Whether a repo may hold the reader's federated credential, from GitHub's REST answer for it. A public
      repo is refused: its workflow logs and artifacts are public. Unauthenticated, a private repo answers
      404; that is accepted only with the numeric IDs supplied by the operator.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $StatusCode,
        $Body,
        [string] $RepoId,
        [string] $OwnerId
    )
    if ($StatusCode -eq 200) {
        $private = Get-Prop $Body 'private'
        if ($private -ne $true) {
            return [pscustomobject]@{ Ok = $false; RepoId = $null; OwnerId = $null; Reason = 'The repo is public. Its workflow logs are public, and the reader''s runs print estate details: use a private repo.' }
        }
        $owner = Get-Prop $Body 'owner'
        return [pscustomobject]@{ Ok = $true; RepoId = "$(Get-Prop $Body 'id')"; OwnerId = "$(Get-Prop $owner 'id')"; Reason = 'Private repo.' }
    }
    if ($StatusCode -eq 404) {
        if ($RepoId -match '^\d+$' -and $OwnerId -match '^\d+$') {
            return [pscustomobject]@{ Ok = $true; RepoId = $RepoId; OwnerId = $OwnerId; Reason = 'Not visible without signing in to GitHub, so not public; IDs as given.' }
        }
        return [pscustomobject]@{ Ok = $false; RepoId = $null; OwnerId = $null; Reason = 'GitHub can''t see the repo without a sign-in (private, or a typo). Set GH_TOKEN (gh auth token), or pass -RepoId and -OwnerId.' }
    }
    [pscustomobject]@{ Ok = $false; RepoId = $null; OwnerId = $null; Reason = "GitHub answered HTTP $StatusCode for the repo." }
}

function Get-AvdReaderAssignmentPlan {
    <#
      Which role assignments to add. Wanted: objects with Scope and RoleId. Existing: the reader's role
      assignments as ARM returns them (properties.scope, properties.roleDefinitionId). Nothing is removed
      here; extras are for Get-AvdReaderFinding to report and for -Mode Remove to delete.
    #>
    [CmdletBinding()]
    param([object[]] $Wanted = @(), [object[]] $Existing = @())
    $have = @{}
    foreach ($a in @($Existing | Where-Object { $_ })) {
        $p = Get-Prop $a 'properties'
        $key = ('{0}|{1}' -f "$(Get-Prop $p 'scope')".TrimEnd('/').ToLowerInvariant(), ("$(Get-Prop $p 'roleDefinitionId')" -split '/')[-1].ToLowerInvariant())
        $have[$key] = $true
    }
    foreach ($w in @($Wanted | Where-Object { $_ })) {
        $key = ('{0}|{1}' -f $w.Scope.TrimEnd('/').ToLowerInvariant(), $w.RoleId.ToLowerInvariant())
        [pscustomobject]@{ Scope = $w.Scope; RoleId = $w.RoleId; Action = $(if ($have.ContainsKey($key)) { 'Keep' } else { 'Add' }) }
    }
}

function Get-AvdReaderPolicyBody {
    <# The app management policy that blocks every secret credential on the reader. #>
    [CmdletBinding()]
    param([string] $AppName = 'avd-ops-reader')
    @{
        displayName  = "$AppName no secrets"
        description  = "Blocks passwords and symmetric keys on $AppName, which signs in with federated credentials only."
        isEnabled    = $true
        restrictions = @{
            passwordCredentials = @($script:BlockedCredentials | ForEach-Object { @{ restrictionType = $_; state = 'enabled'; maxLifetime = $null } })
        }
    }
}

function Test-PolicyBlocksSecret {
    param($Policy)
    if ((Get-Prop $Policy 'isEnabled') -eq $false) { return $false }
    $rows = @(Get-Prop (Get-Prop $Policy 'restrictions') 'passwordCredentials' | Where-Object { $_ })
    foreach ($type in $script:BlockedCredentials) {
        if (-not @($rows | Where-Object { (Get-Prop $_ 'restrictionType') -eq $type -and (Get-Prop $_ 'state') -eq 'enabled' }).Count) { return $false }
    }
    $true
}

function Get-AvdReaderDelegationCondition {
    <#
      For a person who assigns the reader's roles as Role Based Access Control Administrator: the two
      conditions (write and delete) that keep that delegation to the reader's roles only.
    #>
    [CmdletBinding()]
    param([string[]] $RoleId = @($script:Roles | ForEach-Object Id))
    $list = ($RoleId | ForEach-Object { $_.ToLowerInvariant() }) -join ', '
    $write = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$list}))"
    $delete = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$list}))"
    [pscustomobject]@{ Write = $write; Delete = $delete; Combined = "$write AND $delete"; Version = '2.0' }
}

function Get-AvdReaderTokenClaim {
    <# The claims of an access token (its middle part), to find the signed-in service principal's object ID. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Token)
    $parts = $Token.Split('.')
    if ($parts.Count -lt 2) { throw 'Not a JWT access token.' }
    $b = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($b.Length % 4) { 2 { $b += '==' } 3 { $b += '=' } }
    [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json
}

function New-Finding {
    param([string] $Status, [string] $Check, [string] $Detail = '', [string] $Remediation = '')
    [pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail; Remediation = $Remediation }
}

function Get-AvdReaderFinding {
    <#
      Everything that makes the reader safe, checked against what Graph and ARM returned. Pass, Warn or Fail
      per check. The app-side checks need Graph and a person's sign-in (the reader can't read its own app);
      with -RoleOnly only the role assignments are judged, which the reader itself can read at run time.

      App, ServicePrincipal: the Graph objects. FederatedCredential, Owner, Policy, AppRoleAssignment,
      RoleAssignment: lists as Graph and ARM return them (empty properties omitted, as ARM does).
      ExpectedSubject, ExpectedScope: what setup asked for; anything else is reported.
    #>
    [CmdletBinding()]
    param(
        $App,
        $ServicePrincipal,
        [object[]] $FederatedCredential = @(),
        [object[]] $Owner = @(),
        [object[]] $Policy = @(),
        [object[]] $AppRoleAssignment = @(),
        [object[]] $RoleAssignment = @(),
        [string[]] $ExpectedSubject = @(),
        [string[]] $ExpectedScope = @(),
        [switch] $RoleOnly
    )
    $out = New-Object System.Collections.Generic.List[object]

    if (-not $RoleOnly) {
        if ($null -eq $App) {
            $out.Add((New-Finding Fail 'App registration' 'Not found.' 'Run avd_ops_reader.ps1 -Mode Initialize, or pass -ClientId.'))
            return $out.ToArray()
        }
        $audience = Get-Prop $App 'signInAudience'
        if ($audience -eq 'AzureADMyOrg') { $out.Add((New-Finding Pass 'Single tenant' 'signInAudience AzureADMyOrg.')) }
        else { $out.Add((New-Finding Fail 'Single tenant' "signInAudience is '$audience'." 'Set signInAudience to AzureADMyOrg; the reader is never multi-tenant.')) }

        $secrets = @(@(Get-Prop $App 'passwordCredentials') + @(Get-Prop $App 'keyCredentials') +
            @(Get-Prop $ServicePrincipal 'passwordCredentials') + @(Get-Prop $ServicePrincipal 'keyCredentials') | Where-Object { $_ })
        if ($secrets.Count) { $out.Add((New-Finding Fail 'No secrets or certificates' "$($secrets.Count) password or key credential(s) on the app or its service principal." 'Remove them: the reader signs in with federated credentials only. Then find out who added them (Entra audit log).')) }
        else { $out.Add((New-Finding Pass 'No secrets or certificates')) }

        $redirects = @(@(Get-Prop (Get-Prop $App 'web') 'redirectUris') + @(Get-Prop (Get-Prop $App 'spa') 'redirectUris') +
            @(Get-Prop (Get-Prop $App 'publicClient') 'redirectUris') | Where-Object { $_ })
        if ($redirects.Count -or (Get-Prop $App 'isFallbackPublicClient') -eq $true) {
            $out.Add((New-Finding Fail 'App-only' 'The app has redirect URIs or is a public client, so a person could sign in through it.' 'Remove the redirect URIs and turn off "Allow public client flows".'))
        }
        else { $out.Add((New-Finding Pass 'App-only' 'No redirect URIs, not a public client.')) }

        $apiAccess = @(Get-Prop $App 'requiredResourceAccess' | Where-Object { $_ })
        $granted = @($AppRoleAssignment | Where-Object { $_ })
        if ($granted.Count) { $out.Add((New-Finding Fail 'No directory permissions' "$($granted.Count) application permission(s) granted (for example Microsoft Graph)." 'Directory reads are a separate decision (docs/reader-identity.md); remove the grants until it is made.')) }
        elseif ($apiAccess.Count) { $out.Add((New-Finding Warn 'No directory permissions' 'API permissions are requested but not granted.' 'Remove them from the app registration.')) }
        else { $out.Add((New-Finding Pass 'No directory permissions')) }

        $owners = @($Owner | Where-Object { $_ })
        if ($owners.Count -gt 1) { $out.Add((New-Finding Fail 'One owner' "$($owners.Count) owners; each can add credentials to the app." 'Keep one owner (the person who set it up, or a named break-glass account).')) }
        else { $out.Add((New-Finding Pass 'One owner' "$($owners.Count) owner(s).")) }

        $blocking = @($Policy | Where-Object { $_ } | Where-Object { Test-PolicyBlocksSecret $_ })
        if ($blocking.Count) { $out.Add((New-Finding Pass 'Secrets blocked by policy' 'An app management policy blocks passwords and symmetric keys.')) }
        else { $out.Add((New-Finding Fail 'Secrets blocked by policy' 'No app management policy blocks passwords and symmetric keys on the app, so an owner or app admin could add a secret.' 'Rerun -Mode Initialize as an Application Administrator, or run the command it prints.')) }

        $fics = @($FederatedCredential | Where-Object { $_ })
        if (-not $fics.Count) { $out.Add((New-Finding Warn 'Federated credentials' 'None: nothing can sign in as the reader yet.' 'Run -Mode Initialize -Repo <owner/repo>.')) }
        foreach ($f in $fics) {
            $name = Get-Prop $f 'name'
            $subject = Get-Prop $f 'subject'
            $issuer = Get-Prop $f 'issuer'
            $aud = @(Get-Prop $f 'audiences')
            if (Get-Prop $f 'claimsMatchingExpression') { $out.Add((New-Finding Fail "Credential $name" 'Flexible (claims matching) credential.' 'Replace it with one exact immutable subject per repo and environment.')); continue }
            if ($issuer -ne $script:GitHubIssuer -or $aud.Count -ne 1 -or $aud[0] -ne $script:Audience) {
                $out.Add((New-Finding Fail "Credential $name" "Issuer '$issuer', audiences '$($aud -join ', ')'." "Only GitHub Actions ($script:GitHubIssuer, audience $script:Audience) may sign in as the reader.")); continue
            }
            if ($subject -notmatch '^repo:[A-Za-z0-9-]+@\d+/[A-Za-z0-9._-]+@\d+:environment:[A-Za-z0-9._-]+$') {
                $out.Add((New-Finding Fail "Credential $name" "Subject '$subject' isn't an immutable environment subject." 'Use repo:<owner>@<owner id>/<repo>@<repo id>:environment:<env>: a name-only subject can be claimed by whoever re-registers the name, and a branch or pull request subject skips the environment''s protection.')); continue
            }
            if ($ExpectedSubject.Count -and $subject -notin $ExpectedSubject) { $out.Add((New-Finding Warn "Credential $name" "Subject '$subject' wasn't asked for in this run." 'Remove it if that repo no longer runs the reader.')); continue }
            $out.Add((New-Finding Pass "Credential $name" $subject))
        }
        if ($fics.Count -ge 18) { $out.Add((New-Finding Warn 'Credential limit' "$($fics.Count) of Entra's 20 federated credentials per app are used.")) }
    }

    $allowed = @{}
    foreach ($r in $script:Roles) { $allowed[$r.Id] = $r }
    $assignments = @($RoleAssignment | Where-Object { $_ })
    if (-not $assignments.Count) { $out.Add((New-Finding Warn 'Role assignments' 'None: the reader can read nothing yet.')) }
    foreach ($a in $assignments) {
        $p = Get-Prop $a 'properties'
        $scope = "$(Get-Prop $p 'scope')"
        $roleId = ("$(Get-Prop $p 'roleDefinitionId')" -split '/')[-1].ToLowerInvariant()
        $kind = Get-AvdReaderScopeKind -Scope $scope
        $role = $allowed[$roleId]
        $label = "Role on $kind"
        if (-not $role) { $out.Add((New-Finding Fail $label "Role definition $roleId on $scope is not one of the reader's roles." 'Remove it: the reader only reads. Writes belong to other identities.')); continue }
        $label = "$($role.Name) on $kind"
        if (Get-Prop $p 'condition') { $out.Add((New-Finding Warn $label 'The assignment carries a condition.' 'Check it is meant.')) }
        $okScope = switch ($role.ScopeKind) {
            'Arm' { $kind -in @('Subscription', 'ResourceGroup', 'Resource') }
            'Workspace' { $kind -eq 'Workspace' }
            'Container' { $kind -eq 'Container' }
        }
        if (-not $okScope) { $out.Add((New-Finding Fail $label "Scope $scope is wider than this role is allowed." 'Reader and Cost Management Reader go on named subscriptions or resource groups; Log Analytics Reader on one workspace; Storage Blob Data Contributor on one container.')); continue }
        $want = @($ExpectedScope | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() })
        if ($want.Count -and $scope.TrimEnd('/').ToLowerInvariant() -notin $want) { $out.Add((New-Finding Warn $label "$scope wasn't asked for in this run." 'Remove it if it is no longer needed.')); continue }
        $out.Add((New-Finding Pass $label $scope))
    }
    $out.ToArray()
}

Export-ModuleMember -Function Get-AvdReaderRole, Get-AvdReaderScopeKind, Get-AvdReaderSubject, Get-AvdReaderCredentialName,
    Get-AvdReaderRepoVerdict, Get-AvdReaderAssignmentPlan, Get-AvdReaderTokenClaim, Get-AvdReaderPolicyBody, Get-AvdReaderDelegationCondition, Get-AvdReaderFinding
