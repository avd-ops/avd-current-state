#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Publishing the assessment portal into the operator's own subscription (docs/assessment-portal-spec.md,
# phase 4): the pure parts in lib/AvdPortalPublish.psm1, and avd_portal_publish.ps1 run end to end against a
# fake ARM and storage data plane (tests/fakes/publish), with npx replaced by a function that records its call.

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'lib/AvdPortalPublish.psm1') -Force
    function New-Assignment { param([string] $Definition, [string[]] $Allowed, [string] $Mode = 'Default')
        $p = [ordered]@{ policyDefinitionId = "/providers/Microsoft.Authorization/policyDefinitions/$Definition"; enforcementMode = $Mode }
        if ($Allowed) { $p.parameters = [pscustomobject]@{ listOfAllowedLocations = [pscustomobject]@{ value = $Allowed } } }
        [pscustomobject]@{ properties = [pscustomobject]$p }
    }
    $script:resources = 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
    $script:groups = 'e765b5de-1225-4ba3-bd56-1ac6695af988'
}

Describe 'Get-AvdcsPortalHostRegion' {
    It 'puts Static Web Apps in -Location when the Free plan is offered there' {
        $r = Get-AvdcsPortalHostRegion -Hosting StaticWebApp -Location EastUS2
        $r.Allowed | Should -BeTrue; $r.ResourceLocation | Should -Be 'eastus2'; $r.Location | Should -Be 'eastus2'
    }
    It 'picks a Free plan region the policy allows when -Location has none' {
        $r = Get-AvdcsPortalHostRegion -Hosting StaticWebApp -Location northcentralus -Assignments @(New-Assignment $script:resources @('northcentralus', 'westus2'))
        $r.Allowed | Should -BeTrue; $r.ResourceLocation | Should -Be 'westus2'
    }
    It 'stops when no allowed region offers Static Web Apps, and says how to go on' {
        $r = Get-AvdcsPortalHostRegion -Hosting StaticWebApp -Location northcentralus -Assignments @(New-Assignment $script:resources @('northcentralus'))
        $r.Allowed | Should -BeFalse; $r.Remediation | Should -Match '-Hosting Storage'
    }
    It 'refuses a region Static Web Apps does not offer' {
        (Get-AvdcsPortalHostRegion -Hosting StaticWebApp -Location eastus2 -StaticWebAppLocation 'northcentralus' -ErrorAction SilentlyContinue).Allowed | Should -BeFalse
    }
    It 'intersects every assignment, checks resource groups too, and skips one not enforced or with no parameters' {
        $a = @((New-Assignment $script:resources @('eastus2', 'centralus')), (New-Assignment $script:resources @('centralus')), (New-Assignment $script:groups @('eastus2')),
            (New-Assignment $script:resources @('westeurope') -Mode DoNotEnforce), (New-Assignment 'audit-only'))
        (Get-AvdcsPortalHostRegion -Hosting Storage -Location centralus -Assignments $a).Detail | Should -Match 'resource groups in centralus'
        (Get-AvdcsPortalHostRegion -Hosting Storage -Location eastus2 -Assignments $a).Detail | Should -Match 'resources in eastus2 \(allowed: centralus\)'
        $ok = Get-AvdcsPortalHostRegion -Hosting StaticWebApp -Location eastus2 -Assignments $a
        $ok.Allowed | Should -BeTrue; $ok.ResourceLocation | Should -Be 'centralus'
    }
}

Describe 'Get-AvdcsPortalConfigScript' {
    It 'writes one JSON object on the one global the page reads' {
        $js = Get-AvdcsPortalConfigScript -RepoUrl 'https://github.com/contoso/avd-current-state/' -Ref v1.2.0 -PortalUrl 'https://site.example.net/portal/' -Hosting Storage
        $js | Should -Match '^/\* Personal project, not for production'
        $json = ($js -split "`n" | Where-Object { $_ -like 'window.AVDCS_PORTAL_CONFIG = *' }) -replace '^window\.AVDCS_PORTAL_CONFIG = (.*);$', '$1' | ConvertFrom-Json
        $json.repoUrl | Should -Be 'https://github.com/contoso/avd-current-state'
        $json.ref | Should -Be 'v1.2.0'
        $json.hosting | Should -Be 'Storage'
    }
    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a repo outside GitHub'; Repo = 'https://evil.example/a/b'; Ref = 'v1' }
        @{ Name = 'a repo URL that breaks out of a quote'; Repo = "https://github.com/a/b'x"; Ref = 'v1' }
        @{ Name = 'a parent path'; Repo = 'https://github.com/a/..'; Ref = 'v1' }
        @{ Name = 'a ref with a quote'; Repo = 'https://github.com/a/b'; Ref = "v1'; rm" }
        @{ Name = 'a ref with ..'; Repo = 'https://github.com/a/b'; Ref = 'a..b' }
    ) {
        { Get-AvdcsPortalConfigScript -RepoUrl $Repo -Ref $Ref -PortalUrl 'https://x.example/' -Hosting Storage } | Should -Throw
    }
}

Describe 'Get-AvdcsStaticWebAppConfig' {
    It 'sends headers that match a page with no requests and no inline script' {
        $c = Get-AvdcsStaticWebAppConfig | ConvertFrom-Json
        $csp = $c.globalHeaders.'Content-Security-Policy'
        $csp | Should -Match "script-src 'self';"
        $csp | Should -Match "connect-src 'none'"
        $csp | Should -Match "frame-ancestors 'none'"
        $c.PSObject.Properties['routes'] | Should -BeNullOrEmpty
    }
    It 'locks every route to the invited operator role with -RequireSignIn, never to any signed-in account' {
        $c = Get-AvdcsStaticWebAppConfig -RequireSignIn | ConvertFrom-Json
        ($c.routes | Where-Object route -EQ '/*').allowedRoles | Should -Be @('operator')
        ($c.routes | Where-Object route -EQ '/.auth/login/github').statusCode | Should -Be 404
        $c.routes.allowedRoles | Should -Not -Contain 'authenticated'
    }
    It 'matches the page: no inline script, no inline event handler' {
        $html = Get-Content -Raw (Join-Path $script:root 'site/portal/index.html')
        $html | Should -Not -Match '<script>(?!</script>)|<script(?![^>]*\bsrc=)[^>]*>'
        $html | Should -Not -Match '\son[a-z]+="'
    }
}

Describe 'Names, the role assignment and the remove verdict' {
    It 'names the storage account the same on every rerun, within the 24 character limit' {
        $a = Get-AvdcsPortalName -SubscriptionId 'sub-1' -ResourceGroupName 'rg-avd-assessment-portal'
        $a.Storage | Should -Match '^[a-z0-9]{3,24}$'
        (Get-AvdcsPortalName -SubscriptionId 'SUB-1' -ResourceGroupName 'RG-avd-assessment-portal').Storage | Should -Be $a.Storage
        (Get-AvdcsPortalName -SubscriptionId 'sub-2' -ResourceGroupName 'rg-avd-assessment-portal').Storage | Should -Not -Be $a.Storage
    }
    It 'names a role assignment the same on every rerun' {
        $n = Get-AvdcsPortalRoleAssignmentName -Scope '/s/a' -PrincipalId 'p' -RoleDefinitionId 'r'
        { [guid]::Parse($n) } | Should -Not -Throw
        Get-AvdcsPortalRoleAssignmentName -Scope '/s/a' -PrincipalId 'p' -RoleDefinitionId 'r' | Should -Be $n
        Get-AvdcsPortalRoleAssignmentName -Scope '/s/b' -PrincipalId 'p' -RoleDefinitionId 'r' | Should -Not -Be $n
    }
    It 'deletes only a resource group it made' {
        (Get-AvdcsPortalRemoveVerdict -ResourceGroupName rg -ResourceGroup $null).Action | Should -Be 'None'
        (Get-AvdcsPortalRemoveVerdict -ResourceGroupName rg -ResourceGroup ([pscustomobject]@{ name = 'rg' })).Action | Should -Be 'Refuse'
        (Get-AvdcsPortalRemoveVerdict -ResourceGroupName rg -ResourceGroup ([pscustomobject]@{ tags = [pscustomobject]@{ purpose = 'other' } })).Action | Should -Be 'Refuse'
        (Get-AvdcsPortalRemoveVerdict -ResourceGroupName rg -ResourceGroup ([pscustomobject]@{ tags = [pscustomobject]@{ purpose = 'avd-assessment-portal' } })).Action | Should -Be 'Delete'
    }
    It 'serves each file the page loads with its own type' {
        Get-AvdcsPortalContentType -Path 'portal/index.html' | Should -Be 'text/html; charset=utf-8'
        Get-AvdcsPortalContentType -Path 'assets/engine/redact.js' | Should -Be 'text/javascript; charset=utf-8'
        Get-AvdcsPortalContentType -Path 'assets/fonts/x.woff2' | Should -Be 'font/woff2'
        Get-AvdcsPortalContentType -Path 'assets/fonts/LICENSE' | Should -Be 'text/plain; charset=utf-8'
        foreach ($f in Get-ChildItem -Path (Join-Path $script:root 'site') -Recurse -File) {
            Get-AvdcsPortalContentType -Path $f.Name | Should -Not -Be 'application/octet-stream' -Because "$($f.Name) needs a type"
        }
    }
}

Describe 'avd_portal_publish.ps1 against a fake subscription' {
    BeforeAll {
        $script:pwsh = (Get-Process -Id $PID).Path
        $script:fakes = Join-Path $script:root 'tests/fakes/publish'
        $script:script = Join-Path $script:root 'avd_portal_publish.ps1'
        function Invoke-Publish {
            param([string] $Arguments, [hashtable] $Env = @{}, [int] $NpxExit = 0, [switch] $NoNpx)
            $names = @('FAKEPUBLISH_STATE', 'FAKEPUBLISH_POLICY', 'FAKEPUBLISH_NPX', 'SWA_CLI_DEPLOYMENT_TOKEN')
            $saved = @{ PSModulePath = $env:PSModulePath }
            foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
            try {
                foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null) }
                $env:FAKEPUBLISH_STATE = $script:state
                $env:FAKEPUBLISH_NPX = $script:npxLog
                foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
                # npx: a function, which PowerShell finds before any npx on PATH. It records its arguments and
                # whether it saw the deployment token, and fails on request. -NoNpx hides every npx.
                $npx = if ($NoNpx) { "`$env:PATH = ''" } else {
                    "function global:npx { `$d = `$args[3]; Set-Content -Path `$env:FAKEPUBLISH_NPX -Value ((`$args -join ' ') + ' token=' + [bool]`$env:SWA_CLI_DEPLOYMENT_TOKEN + ' files=' + (Get-ChildItem -Recurse -File `$d | ForEach-Object { [IO.Path]::GetRelativePath(`$d, `$_.FullName).Replace('\','/') } | Sort-Object) -join ','); `$global:LASTEXITCODE = $NpxExit; 'swa: done' }"
                }
                $command = "`$env:PSModulePath = '$script:fakes'; Import-Module Az.Accounts; $npx; & '$script:script' $Arguments; exit `$LASTEXITCODE"
                $log = & $script:pwsh -NoProfile -NonInteractive -Command $command 2>&1
                [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($log | Out-String) }
            }
            finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        }
        function Get-FakeState { Get-Content -Raw $script:state | ConvertFrom-Json -AsHashtable }
    }
    BeforeEach {
        $script:state = Join-Path $TestDrive "state-$([guid]::NewGuid()).json"
        $script:npxLog = Join-Path $TestDrive "npx-$([guid]::NewGuid()).txt"
    }

    It 'publishes to Static Web Apps Free, uploads the portal with its config, and kills the token' {
        $r = Invoke-Publish '-Location eastus2 -RepoUrl https://github.com/contoso/avd-current-state -Ref v1.2.0'
        $r.Code | Should -Be 0 -Because $r.Text
        $s = Get-FakeState
        $s.groups['rg-avd-assessment-portal'].tags.purpose | Should -Be 'avd-assessment-portal'
        @($s.sites.Values)[0].sku.name | Should -Be 'Free'
        $s.resets | Should -Be 1 -Because 'the token this shell saw is reset after the upload'
        $npx = Get-Content -Raw $script:npxLog
        $npx | Should -Match '^--yes @azure/static-web-apps-cli@2\.1\.0 deploy '
        $npx | Should -Match 'token=True'
        $npx | Should -Match 'files=.*\bportal/index\.html\b'
        $npx | Should -Match '\bassets/engine/redact\.js\b'
        $npx | Should -Match '\bportal/portal-config\.js\b'
        $npx | Should -Match '\bstaticwebapp\.config\.json\b'
        $r.Text | Should -Match 'Portal: https://nice-sea-0a1b2c3d4\.6\.azurestaticapps\.net/portal/'
        $r.Text | Should -Not -Match 'fake-token'
    }

    It 'still resets the token when the upload fails, and fails with the CLI''s last lines' {
        $r = Invoke-Publish '-Location eastus2 -RepoUrl https://github.com/contoso/avd-current-state -Ref v1.2.0' -NpxExit 3
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'Exit code 3'
        $r.Text | Should -Match 'swa: done'
        (Get-FakeState).resets | Should -Be 1
    }

    It 'invites you with -RequireSignIn' {
        $r = Invoke-Publish '-Location eastus2 -RequireSignIn -RepoUrl https://github.com/contoso/avd-current-state -Ref v1.2.0'
        $r.Code | Should -Be 0 -Because $r.Text
        (Get-FakeState).invited | Should -Be 'operator@contoso.com'
        Get-Content -Raw $script:npxLog | Should -Match '\bdenied\.html\b'
    }

    It 'publishes to a storage static website with your own sign-in, no keys, and removes files that went away' {
        $r = Invoke-Publish '-Location northcentralus -Hosting Storage -RepoUrl https://github.com/contoso/avd-current-state -Ref 0123abc'
        $r.Code | Should -Be 0 -Because $r.Text
        $s = Get-FakeState
        $s.website | Should -BeTrue
        $acct = @($s.accounts.Values)[0]
        $acct.name | Should -Match '^stavdassess[0-9a-f]{12}$'
        $acct.location | Should -Be 'northcentralus'
        @($s.roles.Values)[0].principalType | Should -Be 'User'
        $s.blobs['portal/index.html'].type | Should -Be 'text/html; charset=utf-8'
        $s.blobs.ContainsKey('assets/engine/core.js') | Should -BeTrue
        $s.blobs.ContainsKey('staticwebapp.config.json') | Should -BeFalse
        $s.config | Should -Match '"ref":"0123abc"'
        Test-Path $script:npxLog | Should -BeFalse
        # A file from an older publish goes; a rerun finds its role assignment (409) and carries on.
        $s.blobs['portal/old.js'] = @{ type = 'x'; length = 1 }
        $s | ConvertTo-Json -Depth 20 | Set-Content -Path $script:state
        $again = Invoke-Publish '-Location northcentralus -Hosting Storage -RepoUrl https://github.com/contoso/avd-current-state -Ref 0123abc'
        $again.Code | Should -Be 0 -Because $again.Text
        $again.Text | Should -Match '1 old ones removed'
        (Get-FakeState).blobs.ContainsKey('portal/old.js') | Should -BeFalse
    }

    It 'checks the policy before it creates anything' {
        $r = Invoke-Publish '-Location northcentralus -Hosting Storage -RepoUrl https://github.com/contoso/avd-current-state -Ref v1' -Env @{ FAKEPUBLISH_POLICY = 'eastus2-only' }
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'blocks resource groups in northcentralus'
        @((Get-FakeState).calls | Where-Object { $_ -notlike 'GET *' }) | Should -BeNullOrEmpty
        $ok = Invoke-Publish '-Location northcentralus -RepoUrl https://github.com/contoso/avd-current-state -Ref v1' -Env @{ FAKEPUBLISH_POLICY = 'eastus2-only' }
        $ok.Text | Should -Match 'blocks resource groups in northcentralus' -Because 'the resource group follows -Location even when the site does not'
    }

    It 'stops before creating anything when npx is missing for Static Web Apps' {
        $r = Invoke-Publish '-Location eastus2 -RepoUrl https://github.com/contoso/avd-current-state -Ref v1' -NoNpx
        $r.Code | Should -Be 1
        $r.Text | Should -Match '-Hosting Storage'
        @((Get-FakeState).calls | Where-Object { $_ -notlike 'GET *' }) | Should -BeNullOrEmpty
    }

    It 'refuses a bad repo URL or ref before it reads anything' {
        $r = Invoke-Publish "-Location eastus2 -RepoUrl https://evil.example/a/b -Ref v1"
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match 'GitHub repository URL'
        Test-Path $script:state | Should -BeFalse
    }

    It 'never takes over or removes a resource group it did not make' {
        @{ groups = @{ 'rg-avd-assessment-portal' = @{ name = 'rg-avd-assessment-portal'; location = 'eastus2' } }; sites = @{}; accounts = @{}; roles = @{}; resets = 0; calls = @(); blobs = @{}; website = $false } |
            ConvertTo-Json -Depth 10 | Set-Content -Path $script:state
        $pub = Invoke-Publish '-Location eastus2 -RepoUrl https://github.com/contoso/avd-current-state -Ref v1'
        $pub.Code | Should -Be 1
        $pub.Text | Should -Match 'did not make it'
        $rm = Invoke-Publish '-Remove'
        $rm.Code | Should -Be 1
        $rm.Text | Should -Match "didn't make it"
        (Get-FakeState).groups.ContainsKey('rg-avd-assessment-portal') | Should -BeTrue
    }

    It 'removes what it published, and a second -Remove finds nothing' {
        (Invoke-Publish '-Location northcentralus -Hosting Storage -RepoUrl https://github.com/contoso/avd-current-state -Ref v1').Code | Should -Be 0
        $rm = Invoke-Publish '-Remove'
        $rm.Code | Should -Be 0 -Because $rm.Text
        $rm.Text | Should -Match 'FIXED.*Published portal'
        (Get-FakeState).groups.Count | Should -Be 0
        $again = Invoke-Publish '-Remove'
        $again.Code | Should -Be 0
        $again.Text | Should -Match 'is not there'
    }
}
