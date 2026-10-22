# A fake Az.Accounts for avd_portal_publish.ps1's offline runs (tests/PortalPublish.Tests.ps1): ARM behind
# Invoke-AzRestMethod, with its state in a JSON file so one run sees what the last one made. It is no more
# permissive than ARM: unknown routes fail, a missing resource is 404, and a policy assignment with no
# parameters omits the property the way ARM does.
#
# Environment: FAKEPUBLISH_STATE (state file), FAKEPUBLISH_POLICY (none | eastus2-only: an Allowed locations
# assignment for resources and one for resource groups, plus an audit assignment with no parameters).

$script:Sub = '00000000-0000-0000-0000-0000000000a1'
$script:Me = '00000000-0000-0000-0000-0000000000e1'

function Get-State {
    if (Test-Path $env:FAKEPUBLISH_STATE) { return Get-Content -Raw $env:FAKEPUBLISH_STATE | ConvertFrom-Json -AsHashtable }
    @{ groups = @{}; sites = @{}; accounts = @{}; roles = @{}; resets = 0; calls = @(); blobs = @{}; website = $false }
}
function Save-State { param($S) $S | ConvertTo-Json -Depth 20 | Set-Content -Path $env:FAKEPUBLISH_STATE }
function Out-Rest { param([int] $Code, $Body) [pscustomobject]@{ StatusCode = $Code; Content = $(if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 } else { '' }); Headers = @{} } }

function Get-AzContext {
    [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'operator@contoso.com'; Type = 'User' }
        Tenant       = [pscustomobject]@{ Id = '00000000-0000-0000-0000-0000000000f0' }
        Subscription = [pscustomobject]@{ Id = $script:Sub; Name = 'sub-contoso-avd' }
    }
}
function Set-AzContext { param([string] $Subscription) Get-AzContext }
function Get-AzAccessToken {
    $claims = @{ oid = $script:Me; upn = 'operator@contoso.com'; tid = '00000000-0000-0000-0000-0000000000f0' } | ConvertTo-Json -Compress
    $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [pscustomobject]@{ Token = "eyJhbGciOiJub25lIn0.$b.sig" }
}

function Invoke-AzRestMethod {
    param([string] $Method = 'GET', [string] $Path, [string] $Uri, [string] $ResourceId, [string] $Payload)
    $s = Get-State
    $target = if ($Uri) { $Uri } else { $Path }
    $s.calls = @($s.calls) + "$Method $target"
    $body = if ($Payload) { $Payload | ConvertFrom-Json -AsHashtable } else { $null }
    $sub = "/subscriptions/$script:Sub"
    $r = $null
    switch -Regex ($target) {
        '^/subscriptions/[^/]+/providers/Microsoft\.Authorization/policyAssignments\?' {
            $list = @()
            if ($env:FAKEPUBLISH_POLICY -eq 'eastus2-only') {
                $list = @(
                    @{ id = 'pa1'; properties = @{ policyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'; enforcementMode = 'Default'; parameters = @{ listOfAllowedLocations = @{ value = @('eastus2', 'centralus') } } } }
                    @{ id = 'pa2'; properties = @{ policyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/e765b5de-1225-4ba3-bd56-1ac6695af988'; enforcementMode = 'Default'; parameters = @{ listOfAllowedLocations = @{ value = @('eastus2') } } } }
                    @{ id = 'pa3'; properties = @{ policyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/audit-something'; enforcementMode = 'Default' } }
                )
            }
            $r = Out-Rest 200 @{ value = $list }; break
        }
        '^/subscriptions/[^/]+/resourcegroups/([^/?]+)\?' {
            $name = $Matches[1]
            switch ($Method) {
                'GET' { $r = if ($s.groups.ContainsKey($name)) { Out-Rest 200 $s.groups[$name] } else { Out-Rest 404 @{ error = @{ code = 'ResourceGroupNotFound' } } } }
                'PUT' { $g = @{ id = "$sub/resourceGroups/$name"; name = $name; location = $body.location; properties = @{ provisioningState = 'Succeeded' } }; if ($body.tags) { $g.tags = $body.tags }; $s.groups[$name] = $g; $r = Out-Rest 201 $g }
                'DELETE' {
                    $s.groups.Remove($name)
                    foreach ($k in @($s.sites.Keys)) { if ($k -like "*/resourceGroups/$name/*") { $s.sites.Remove($k) } }
                    foreach ($k in @($s.accounts.Keys)) { if ($k -like "*/resourceGroups/$name/*") { $s.accounts.Remove($k) } }
                    $r = Out-Rest 202 $null
                }
            }
            break
        }
        '^(/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Web/staticSites/[^/?]+)/(listSecrets|resetapikey|createUserInvitation)\?' {
            $id = $Matches[1]
            if (-not $s.sites.ContainsKey($id)) { $r = Out-Rest 404 @{ error = @{ code = 'ResourceNotFound' } }; break }
            switch ($Matches[2]) {
                'listSecrets' { $r = Out-Rest 200 @{ properties = @{ apiKey = "fake-token-$($s.resets)" } } }
                'resetapikey' { $s.resets++; $r = Out-Rest 200 $null }
                'createUserInvitation' { $s.invited = $body.properties.userDetails; $r = Out-Rest 200 @{ properties = @{ invitationUrl = 'https://example.com/invite' } } }
            }
            break
        }
        '^(/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/Microsoft\.Web/staticSites/([^/?]+))\?' {
            $id = $Matches[1]; $rg = $Matches[2]
            if (-not $s.groups.ContainsKey($rg)) { $r = Out-Rest 404 @{ error = @{ code = 'ResourceGroupNotFound' } }; break }
            if ($Method -eq 'PUT') {
                if ($body.sku.name -ne 'Free') { throw "fake: the script asked for the $($body.sku.name) plan" }
                $s.sites[$id] = @{ id = $id; location = $body.location; sku = $body.sku; tags = $body.tags; properties = @{ defaultHostname = 'nice-sea-0a1b2c3d4.6.azurestaticapps.net' } }
                $r = Out-Rest 200 $s.sites[$id]
            }
            else { $r = if ($s.sites.ContainsKey($id)) { Out-Rest 200 $s.sites[$id] } else { Out-Rest 404 @{ error = @{ code = 'ResourceNotFound' } } } }
            break
        }
        '^(/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[^/]+)/providers/Microsoft\.Authorization/roleAssignments/([^/?]+)\?' {
            $key = "$($Matches[1])|$($Matches[2])"
            if ($s.roles.ContainsKey($key)) { $r = Out-Rest 409 @{ error = @{ code = 'RoleAssignmentExists' } }; break }
            $s.roles[$key] = $body.properties; $r = Out-Rest 201 @{ id = $key; properties = $body.properties }; break
        }
        '^(/subscriptions/[^/]+/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([^/?]+))\?' {
            $id = $Matches[1]; $rg = $Matches[2]; $name = $Matches[3]
            if (-not $s.groups.ContainsKey($rg)) { $r = Out-Rest 404 @{ error = @{ code = 'ResourceGroupNotFound' } }; break }
            if ($name -notmatch '^[a-z0-9]{3,24}$') { $r = Out-Rest 400 @{ error = @{ code = 'AccountNameInvalid' } }; break }
            if ($Method -eq 'PUT') {
                if ($body.properties.allowSharedKeyAccess -ne $false) { throw 'fake: shared keys must stay off' }
                $s.accounts[$id] = @{ id = $id; name = $name; location = $body.location; kind = $body.kind; sku = $body.sku; tags = $body.tags
                    properties = @{ provisioningState = 'Succeeded'; allowSharedKeyAccess = $false; primaryEndpoints = @{ web = "https://$name.z13.web.core.windows.net/" } } }
                $r = Out-Rest 202 $null
            }
            else { $r = if ($s.accounts.ContainsKey($id)) { Out-Rest 200 $s.accounts[$id] } else { Out-Rest 404 @{ error = @{ code = 'ResourceNotFound' } } } }
            break
        }
        default { throw "fake ARM: no route for $Method $target" }
    }
    Save-State $s
    $r
}
