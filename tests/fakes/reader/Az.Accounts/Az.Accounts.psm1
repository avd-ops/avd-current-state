# A fake Az.Accounts for avd_ops_reader.ps1's offline runs (tests/Reader.Tests.ps1): Microsoft Graph and ARM
# behind Invoke-AzRestMethod, and GitHub behind Invoke-RestMethod, with their state in a JSON file so one run
# sees what the last one made. It is no more permissive than the services: unknown routes fail, a missing
# object is 404, and ARM role assignments omit empty properties (condition) the way ARM does.
#
# Environment: FAKEREADER_STATE (state file), FAKEREADER_REPO (private | public | hidden), FAKEREADER_POLICY
# (allow | deny), FAKEREADER_AS (user | reader).

$script:Tenant = '00000000-0000-0000-0000-0000000000f0'
$script:Subs = @('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2')
$script:Me = '00000000-0000-0000-0000-0000000000e1'

function Get-State {
    if (Test-Path $env:FAKEREADER_STATE) { return Get-Content -Raw $env:FAKEREADER_STATE | ConvertFrom-Json -AsHashtable }
    @{ apps = @(); sps = @(); fics = @{}; policies = @(); policyApps = @{}; owners = @{}; roles = @(); calls = @() }
}
function Save-State { param($S) $S | ConvertTo-Json -Depth 20 | Set-Content -Path $env:FAKEREADER_STATE }
function New-Id { [guid]::NewGuid().ToString() }
function Out-Rest { param([int] $Code, $Body) [pscustomobject]@{ StatusCode = $Code; Content = $(if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 } else { '' }); Headers = @{} } }

function Get-AzContext {
    $reader = $env:FAKEREADER_AS -eq 'reader'
    $s = Get-State
    $appId = if ($reader -and @($s.apps).Count) { $s.apps[0].appId } else { 'operator@contoso.com' }
    [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = $appId; Type = $(if ($reader) { 'ServicePrincipal' } else { 'User' }) }
        Tenant       = [pscustomobject]@{ Id = $script:Tenant }
        Subscription = [pscustomobject]@{ Id = $script:Subs[0]; Name = 'sub-contoso-avd' }
    }
}
function Connect-AzAccount { Get-AzContext }
function Get-AzSubscription {
    [pscustomobject]@{ Id = $script:Subs[0]; Name = 'sub-contoso-avd'; State = 'Enabled'; TenantId = $script:Tenant }
    [pscustomobject]@{ Id = $script:Subs[1]; Name = 'sub-contoso-dev'; State = 'Enabled'; TenantId = $script:Tenant }
}
function Get-AzAccessToken {
    $s = Get-State
    $claims = @{ oid = $(if (@($s.sps).Count) { $s.sps[0].id } else { New-Id }); tid = $script:Tenant } | ConvertTo-Json -Compress
    $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [pscustomobject]@{ Token = "eyJhbGciOiJub25lIn0.$b.sig" }
}

function Invoke-RestMethod {
    # GitHub's REST answer for a repo or a user.
    param([string] $Uri, $Headers)
    if ($Uri -match '/users/') { return [pscustomobject]@{ id = 222 } }
    switch ($env:FAKEREADER_REPO) {
        'public' { return [pscustomobject]@{ id = 111; private = $false; owner = [pscustomobject]@{ id = 222 } } }
        'hidden' { throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', [System.Net.Http.HttpResponseMessage]::new(404)) }
        default { return [pscustomobject]@{ id = 111; private = $true; owner = [pscustomobject]@{ id = 222 } } }
    }
}

function Invoke-AzRestMethod {
    param([string] $Method = 'GET', [string] $Path, [string] $Uri, [string] $ResourceId, [string] $Payload)
    $s = Get-State
    $target = if ($Uri) { $Uri -replace '^https://graph\.microsoft\.com', '' } else { $Path }
    $s.calls = @($s.calls) + "$Method $target"
    $body = if ($Payload) { $Payload | ConvertFrom-Json -AsHashtable } else { $null }
    $deny = $env:FAKEREADER_POLICY -eq 'deny'
    $r = $null
    switch -Regex ($target) {
        "^/v1\.0/applications\(appId='([^']+)'\)$" {
            $a = @($s.apps | Where-Object { $_.appId -eq $Matches[1] })
            $r = if ($a.Count) { Out-Rest 200 $a[0] } else { Out-Rest 404 @{ error = @{ code = 'Request_ResourceNotFound' } } }
            break
        }
        '^/v1\.0/applications\?\$filter=' {
            $name = [uri]::UnescapeDataString($target) -replace ".*displayName eq '([^']+)'.*", '$1'
            $r = Out-Rest 200 @{ value = @($s.apps | Where-Object { $_.displayName -eq $name } | ForEach-Object { @{ appId = $_.appId } }) }
            break
        }
        '^/v1\.0/applications$' {
            $app = @{ id = (New-Id); appId = (New-Id); displayName = $body.displayName; signInAudience = $body.signInAudience
                passwordCredentials = @(); keyCredentials = @(); requiredResourceAccess = @(); web = @{ redirectUris = @() }
                spa = @{ redirectUris = @() }; publicClient = @{ redirectUris = @() }; isFallbackPublicClient = $null }
            $s.apps = @($s.apps) + $app; $s.owners[$app.id] = @(@{ id = $script:Me })
            $r = Out-Rest 201 $app; break
        }
        "^/v1\.0/servicePrincipals\(appId='([^']+)'\)$" {
            $p = @($s.sps | Where-Object { $_.appId -eq $Matches[1] })
            $r = if ($p.Count) { Out-Rest 200 $p[0] } else { Out-Rest 404 @{ error = @{ code = 'Request_ResourceNotFound' } } }
            break
        }
        '^/v1\.0/servicePrincipals$' { $sp = @{ id = (New-Id); appId = $body.appId; passwordCredentials = @(); keyCredentials = @() }; $s.sps = @($s.sps) + $sp; $r = Out-Rest 201 $sp; break }
        '^/v1\.0/servicePrincipals/([^/]+)/appRoleAssignments$' { $r = Out-Rest 200 @{ value = @() }; break }
        '^/v1\.0/servicePrincipals/([^/]+)$' { $id = $Matches[1]; $s.sps = @($s.sps | Where-Object { $_.id -ne $id }); $r = Out-Rest 204 $null; break }
        '^/v1\.0/applications/([^/]+)/federatedIdentityCredentials$' {
            $id = $Matches[1]
            if ($Method -eq 'POST') { $s.fics[$id] = @($s.fics[$id] | Where-Object { $_ }) + $body; $r = Out-Rest 201 $body }
            else { $r = Out-Rest 200 @{ value = @($s.fics[$id] | Where-Object { $_ }) } }
            break
        }
        '^/v1\.0/applications/([^/]+)/owners' { $r = Out-Rest 200 @{ value = @($s.owners[$Matches[1]] | Where-Object { $_ }) }; break }
        '^/v1\.0/applications/([^/]+)/appManagementPolicies/\$ref$' {
            if ($deny) { $r = Out-Rest 403 @{ error = @{ code = 'Authorization_RequestDenied' } }; break }
            $pid_ = ($body.'@odata.id' -split '/')[-1]; $s.policyApps[$pid_] = @($s.policyApps[$pid_] | Where-Object { $_ }) + $Matches[1]
            $r = Out-Rest 204 $null; break
        }
        '^/v1\.0/applications/([^/]+)/appManagementPolicies/([^/]+)/\$ref$' {
            $app = $Matches[1]; $pol = $Matches[2]; $s.policyApps[$pol] = @($s.policyApps[$pol] | Where-Object { $_ -ne $app }); $r = Out-Rest 204 $null; break
        }
        '^/v1\.0/applications/([^/]+)/appManagementPolicies$' {
            if ($deny) { $r = Out-Rest 403 @{ error = @{ code = 'Authorization_RequestDenied' } }; break }
            $app = $Matches[1]
            $r = Out-Rest 200 @{ value = @($s.policies | Where-Object { @($s.policyApps[$_.id]) -contains $app }) }; break
        }
        '^/v1\.0/applications/([^/]+)$' {
            $id = $Matches[1]; $s.apps = @($s.apps | Where-Object { $_.id -ne $id }); $s.fics.Remove($id); $r = Out-Rest 204 $null; break
        }
        '^/v1\.0/policies/appManagementPolicies$' {
            if ($deny) { $r = Out-Rest 403 @{ error = @{ code = 'Authorization_RequestDenied' } }; break }
            $pol = $body; $pol.id = New-Id; $s.policies = @($s.policies) + $pol; $r = Out-Rest 201 $pol; break
        }
        '^/v1\.0/policies/appManagementPolicies/([^/]+)/appliesTo' { $r = Out-Rest 200 @{ value = @($s.policyApps[$Matches[1]] | Where-Object { $_ } | ForEach-Object { @{ id = $_ } }) }; break }
        '^/v1\.0/policies/appManagementPolicies/([^/]+)$' { $id = $Matches[1]; $s.policies = @($s.policies | Where-Object { $_.id -ne $id }); $r = Out-Rest 204 $null; break }
        '^/subscriptions/([^/]+)/providers/Microsoft\.Authorization/roleAssignments\?\$filter=' {
            $sub = $Matches[1]
            $principal = [uri]::UnescapeDataString($target) -replace ".*principalId eq '([^']+)'.*", '$1'
            $r = Out-Rest 200 @{ value = @($s.roles | Where-Object { $_.properties.principalId -eq $principal -and $_.properties.scope -like "/subscriptions/$sub*" }) }; break
        }
        '^(.+)/providers/Microsoft\.Authorization/roleAssignments/([^/?]+)\?api-version=' {
            $scope = $Matches[1]; $name = $Matches[2]
            if ($Method -eq 'PUT') {
                $ra = @{ id = "$scope/providers/Microsoft.Authorization/roleAssignments/$name"; name = $name
                    properties = @{ scope = $scope; roleDefinitionId = $body.properties.roleDefinitionId; principalId = $body.properties.principalId; principalType = $body.properties.principalType } }
                $s.roles = @($s.roles) + $ra; $r = Out-Rest 201 $ra
            }
            elseif ($Method -eq 'DELETE') { $id = "$scope/providers/Microsoft.Authorization/roleAssignments/$name"; $s.roles = @($s.roles | Where-Object { $_.id -ne $id }); $r = Out-Rest 200 @{} }
            break
        }
    }
    if ($null -eq $r) { $r = Out-Rest 400 @{ error = @{ code = 'FakeRouteMissing'; message = "$Method $target" } } }
    Save-State $s
    $r
}
Export-ModuleMember -Function *
