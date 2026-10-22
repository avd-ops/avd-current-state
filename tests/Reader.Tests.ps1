#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The optional avd-ops-reader (docs/reader-identity.md): the pure checks in lib/AvdReader.psm1, and
# avd_ops_reader.ps1 run end to end against a fake Graph, ARM and GitHub (tests/fakes/reader). Each case
# answers a red team finding (docs/reader-identity.md, "Red team").

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'lib/AvdReader.psm1') -Force
    $script:readerId = (Get-AvdReaderRole -Name 'Reader').Id
    function New-Assignment { param([string] $Scope, [string] $RoleId)
        [pscustomobject]@{ id = "$Scope/providers/Microsoft.Authorization/roleAssignments/x"; properties = [pscustomobject]@{ scope = $Scope; roleDefinitionId = "/subscriptions/s/providers/Microsoft.Authorization/roleDefinitions/$RoleId" } }
    }
    function New-App { [pscustomobject]@{ id = 'o1'; appId = 'a1'; signInAudience = 'AzureADMyOrg'; passwordCredentials = @(); keyCredentials = @() } }
    $script:goodPolicy = [pscustomobject]@{ isEnabled = $true; restrictions = [pscustomobject]@{ passwordCredentials = @(
                [pscustomobject]@{ restrictionType = 'passwordAddition'; state = 'enabled' }
                [pscustomobject]@{ restrictionType = 'customPasswordAddition'; state = 'enabled' }
                [pscustomobject]@{ restrictionType = 'symmetricKeyAddition'; state = 'enabled' }) } }
    $script:goodFic = [pscustomobject]@{ name = 'gh'; issuer = 'https://token.actions.githubusercontent.com'; audiences = @('api://AzureADTokenExchange'); subject = 'repo:contoso@222/avd-runs@111:environment:avd-reader' }
}

Describe 'Get-AvdReaderSubject' {
    It 'builds the immutable environment subject' {
        Get-AvdReaderSubject -Owner contoso -OwnerId 222 -Repo avd-runs -RepoId 111 -Environment avd-reader |
            Should -Be 'repo:contoso@222/avd-runs@111:environment:avd-reader'
    }
    It 'refuses names in place of the numeric IDs' {
        { Get-AvdReaderSubject -Owner contoso -OwnerId contoso -Repo avd-runs -RepoId 111 -Environment e } | Should -Throw '*numeric*'
    }
}

Describe 'Get-AvdReaderCredentialName' {
    It 'names a credential by the repo''s numeric ID, so two repos never share a name' {
        Get-AvdReaderCredentialName -RepoId 111 -Environment avd-reader | Should -Be 'gh-111-avd-reader'
        Get-AvdReaderCredentialName -RepoId 112 -Environment avd-reader | Should -Not -Be (Get-AvdReaderCredentialName -RepoId 111 -Environment avd-reader)
    }
    It 'refuses an environment name it would have to change' {
        { Get-AvdReaderCredentialName -RepoId 111 -Environment 'avd.reader' } | Should -Throw
    }
}

Describe 'Get-AvdReaderRepoVerdict' {
    It 'says GitHub didn''t answer when there was no response' { (Get-AvdReaderRepoVerdict -StatusCode 0 -Message 'proxy refused').Reason | Should -Match 'proxy refused' }
    It 'refuses a public repo' { (Get-AvdReaderRepoVerdict -StatusCode 200 -Body @{ private = $false; id = 1; owner = @{ id = 2 } }).Ok | Should -BeFalse }
    It 'takes a private repo''s IDs from GitHub' {
        $v = Get-AvdReaderRepoVerdict -StatusCode 200 -Body ([pscustomobject]@{ private = $true; id = 111; owner = [pscustomobject]@{ id = 222 } })
        $v.Ok | Should -BeTrue; $v.RepoId | Should -Be '111'; $v.OwnerId | Should -Be '222'
    }
    It 'accepts a hidden repo only with both IDs given' {
        (Get-AvdReaderRepoVerdict -StatusCode 404).Ok | Should -BeFalse
        (Get-AvdReaderRepoVerdict -StatusCode 404 -RepoId 111 -OwnerId 222).Ok | Should -BeTrue
    }
}

Describe 'Get-AvdReaderScopeKind' {
    It 'tells <Scope> is a <Kind>' -ForEach @(
        @{ Scope = '/'; Kind = 'Root' }
        @{ Scope = '/providers/Microsoft.Management/managementGroups/mg'; Kind = 'ManagementGroup' }
        @{ Scope = '/subscriptions/s'; Kind = 'Subscription' }
        @{ Scope = '/subscriptions/s/resourceGroups/rg'; Kind = 'ResourceGroup' }
        @{ Scope = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/w'; Kind = 'Workspace' }
        @{ Scope = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st/blobServices/default/containers/c'; Kind = 'Container' }
    ) { Get-AvdReaderScopeKind -Scope $Scope | Should -Be $Kind }
}

Describe 'Get-AvdReaderAssignmentPlan' {
    It 'keeps what exists and adds the rest' {
        $plan = @(Get-AvdReaderAssignmentPlan -Wanted @([pscustomobject]@{ Scope = '/subscriptions/a'; RoleId = $script:readerId }, [pscustomobject]@{ Scope = '/subscriptions/b'; RoleId = $script:readerId }) `
                -Existing @(New-Assignment '/subscriptions/A' $script:readerId.ToUpper()))
        $plan[0].Action | Should -Be 'Keep'
        $plan[1].Action | Should -Be 'Add'
    }
}

Describe 'Get-AvdReaderDelegationCondition' {
    It 'limits both writes and deletes to the reader''s roles' {
        $c = Get-AvdReaderDelegationCondition
        $c.Write | Should -Match '@Request\[Microsoft.Authorization/roleAssignments:RoleDefinitionId\]'
        $c.Delete | Should -Match '@Resource\[Microsoft.Authorization/roleAssignments:RoleDefinitionId\]'
        $c.Combined | Should -Match 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    }
}

Describe 'Get-AvdReaderFinding' {
    It 'passes a clean reader' {
        $f = @(Get-AvdReaderFinding -App (New-App) -ServicePrincipal ([pscustomobject]@{ id = 's1' }) -FederatedCredential $script:goodFic -Owner @([pscustomobject]@{ id = 'u' }) `
                -Policy $script:goodPolicy -RoleAssignment (New-Assignment '/subscriptions/s' $script:readerId))
        @($f | Where-Object Status -ne 'Pass') | Should -BeNullOrEmpty
    }
    It 'fails a secret on the app (finding 4)' {
        $app = New-App; $app.passwordCredentials = @([pscustomobject]@{ keyId = 'k' })
        (@(Get-AvdReaderFinding -App $app -Policy $script:goodPolicy) | Where-Object Check -eq 'No secrets or certificates').Status | Should -Be 'Fail'
    }
    It 'fails when no policy blocks secrets, or the policy misses a credential type (finding 4)' {
        (@(Get-AvdReaderFinding -App (New-App)) | Where-Object Check -eq 'Passwords blocked by policy').Status | Should -Be 'Fail'
        $partial = [pscustomobject]@{ restrictions = [pscustomobject]@{ passwordCredentials = @([pscustomobject]@{ restrictionType = 'passwordAddition'; state = 'enabled' }) } }
        (@(Get-AvdReaderFinding -App (New-App) -Policy $partial) | Where-Object Check -eq 'Passwords blocked by policy').Status | Should -Be 'Fail'
    }
    It 'fails a name-only subject (finding 1)' {
        $fic = [pscustomobject]@{ name = 'old'; issuer = 'https://token.actions.githubusercontent.com'; audiences = @('api://AzureADTokenExchange'); subject = 'repo:contoso/avd-runs:environment:avd-reader' }
        (@(Get-AvdReaderFinding -App (New-App) -FederatedCredential $fic) | Where-Object Check -eq 'Credential old').Status | Should -Be 'Fail'
    }
    It 'fails a branch or pull request subject (finding 2)' {
        $fic = [pscustomobject]@{ name = 'pr'; issuer = 'https://token.actions.githubusercontent.com'; audiences = @('api://AzureADTokenExchange'); subject = 'repo:contoso@222/avd-runs@111:pull_request' }
        (@(Get-AvdReaderFinding -App (New-App) -FederatedCredential $fic) | Where-Object Check -eq 'Credential pr').Status | Should -Be 'Fail'
    }
    It 'fails a flexible credential and a foreign issuer' {
        $flex = [pscustomobject]@{ name = 'flex'; issuer = 'https://token.actions.githubusercontent.com'; audiences = @('api://AzureADTokenExchange'); claimsMatchingExpression = [pscustomobject]@{ value = 'x' } }
        $other = [pscustomobject]@{ name = 'other'; issuer = 'https://example.com'; audiences = @('api://AzureADTokenExchange'); subject = 's' }
        $f = @(Get-AvdReaderFinding -App (New-App) -FederatedCredential @($flex, $other))
        ($f | Where-Object Check -eq 'Credential flex').Status | Should -Be 'Fail'
        ($f | Where-Object Check -eq 'Credential other').Status | Should -Be 'Fail'
    }
    It 'fails a second owner, a redirect URI and a granted Graph permission' {
        $app = New-App; $app | Add-Member web ([pscustomobject]@{ redirectUris = @('https://example.com') })
        $f = @(Get-AvdReaderFinding -App $app -Owner @([pscustomobject]@{ id = 'u1' }, [pscustomobject]@{ id = 'u2' }) -AppRoleAssignment @([pscustomobject]@{ id = 'g' }))
        ($f | Where-Object Check -eq 'One owner').Status | Should -Be 'Fail'
        ($f | Where-Object Check -eq 'App-only').Status | Should -Be 'Fail'
        ($f | Where-Object Check -eq 'No directory permissions').Status | Should -Be 'Fail'
    }
    It 'fails a multi-tenant app' {
        $app = New-App; $app.signInAudience = 'AzureADMultipleOrgs'
        (@(Get-AvdReaderFinding -App $app) | Where-Object Check -eq 'Single tenant').Status | Should -Be 'Fail'
    }
    It 'fails <Why>' -ForEach @(
        @{ Why = 'a write role'; Scope = '/subscriptions/s'; Role = 'b24988ac-6180-42a0-ab88-20f7382dd24c' }
        @{ Why = 'Reader on a management group'; Scope = '/providers/Microsoft.Management/managementGroups/mg'; Role = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' }
        @{ Why = 'blob data on a whole storage account'; Scope = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st'; Role = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' }
        @{ Why = 'Log Analytics Reader on a subscription'; Scope = '/subscriptions/s'; Role = '73c42c96-874c-492b-b04d-ab87d138a893' }
    ) {
        $f = @(Get-AvdReaderFinding -RoleOnly -RoleAssignment (New-Assignment $Scope $Role))
        $f.Count | Should -Be 1
        $f[0].Status | Should -Be 'Fail'
    }
    It 'warns about a role that wasn''t asked for on a scope that was' {
        $cost = (Get-AvdReaderRole -Name 'Cost Management Reader').Id
        $f = @(Get-AvdReaderFinding -RoleOnly -RoleAssignment (New-Assignment '/subscriptions/s' $cost) -ExpectedAssignment @([pscustomobject]@{ Scope = '/subscriptions/s'; RoleId = $script:readerId }))
        $f[0].Status | Should -Be 'Warn'
    }
    It 'with -RoleOnly judges only role assignments (the reader can''t read its app, finding 6)' {
        $f = @(Get-AvdReaderFinding -RoleOnly -RoleAssignment (New-Assignment '/subscriptions/s' $script:readerId))
        $f.Count | Should -Be 1
        $f[0].Status | Should -Be 'Pass'
    }
}

Describe 'avd_ops_reader.ps1 against a fake tenant' {
    BeforeAll {
        $script:pwsh = (Get-Process -Id $PID).Path
        $script:fakes = Join-Path $script:root 'tests/fakes/reader'
        $script:script = Join-Path $script:root 'avd_ops_reader.ps1'
        function Invoke-Reader {
            param([string] $Arguments, [hashtable] $Env = @{})
            $names = @('FAKEREADER_STATE', 'FAKEREADER_REPO', 'FAKEREADER_POLICY', 'FAKEREADER_AS', 'AVD_READER_CLIENT_ID', 'GH_TOKEN', 'GITHUB_TOKEN')
            $saved = @{ PSModulePath = $env:PSModulePath }
            foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
            try {
                foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null) }
                $env:FAKEREADER_STATE = $script:state
                foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
                $command = "`$env:PSModulePath = '$script:fakes'; Import-Module Az.Accounts; & '$script:script' $Arguments; exit `$LASTEXITCODE"
                $log = & $script:pwsh -NoProfile -NonInteractive -Command $command 2>&1
                [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($log | Out-String) }
            }
            finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        }
        function Get-FakeState { Get-Content -Raw $script:state | ConvertFrom-Json }
    }
    BeforeEach { $script:state = Join-Path $TestDrive "state-$([guid]::NewGuid()).json" }

    It 'sets up a clean reader, and a second run changes nothing' {
        $first = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd"
        $first.Code | Should -Be 0 -Because $first.Text
        $s = Get-FakeState
        @($s.apps).Count | Should -Be 1
        $s.apps[0].signInAudience | Should -Be 'AzureADMyOrg'
        @($s.roles).Count | Should -Be 1
        $s.roles[0].properties.scope | Should -Be '/subscriptions/00000000-0000-0000-0000-0000000000a1'
        $s.roles[0].properties.principalType | Should -Be 'ServicePrincipal'
        $fic = @($s.fics.PSObject.Properties.Value)[0]
        $fic.subject | Should -Be 'repo:contoso@222/avd-runs@111:environment:avd-reader'
        @($s.policies).Count | Should -Be 1
        $first.Text | Should -Not -Match '\[FAIL'

        $before = @($s.calls | Where-Object { $_ -notlike 'GET *' }).Count
        $second = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd" @{ AVD_READER_CLIENT_ID = $s.apps[0].appId }
        $second.Code | Should -Be 0 -Because $second.Text
        @((Get-FakeState).calls | Where-Object { $_ -notlike 'GET *' }).Count | Should -Be $before
        $second.Text | Should -Not -Match '\[FIXED'
    }

    It 'adds a second repo as another credential on the same reader (one family reader)' {
        $null = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd"
        $id = (Get-FakeState).apps[0].appId
        $r = Invoke-Reader "-Mode Initialize -Repo contoso/lz-runs -Subscription sub-contoso-avd" @{ AVD_READER_CLIENT_ID = $id }
        $r.Code | Should -Be 0 -Because $r.Text
        $s = Get-FakeState
        @($s.apps).Count | Should -Be 1
        @($s.fics.PSObject.Properties.Value).Count | Should -Be 2
    }

    It 'refuses a public repo before creating anything (finding 2)' {
        $r = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd" @{ FAKEREADER_REPO = 'public' }
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'public'
        Test-Path $script:state | Should -BeFalse
    }

    It 'takes a hidden private repo only with its IDs' {
        (Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd" @{ FAKEREADER_REPO = 'hidden' }).Code | Should -Be 1
        $r = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -RepoId 111 -OwnerId 222 -Subscription sub-contoso-avd" @{ FAKEREADER_REPO = 'hidden' }
        $r.Code | Should -Be 0 -Because $r.Text
    }

    It 'never adopts an app by its name (finding 5)' {
        $null = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd"
        $r = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd"
        $r.Code | Should -Be 1
        $r.Text | Should -Match 'never reused by its name'
        @((Get-FakeState).apps).Count | Should -Be 1
    }

    It 'scopes Reader to resource groups and the opt-in roles to one workspace and one container' {
        $ws = '/subscriptions/00000000-0000-0000-0000-0000000000a1/resourceGroups/rg-ops/providers/Microsoft.OperationalInsights/workspaces/log-avd'
        $ct = '/subscriptions/00000000-0000-0000-0000-0000000000a1/resourceGroups/rg-ops/providers/Microsoft.Storage/storageAccounts/stavd/blobServices/default/containers/runs'
        $r = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd -ResourceGroup rg-avd,rg-net -LogAnalyticsWorkspace '$ws' -OutputContainer '$ct'"
        $r.Code | Should -Be 0 -Because $r.Text
        $scopes = @((Get-FakeState).roles | ForEach-Object { $_.properties.scope }) | Sort-Object
        $scopes | Should -Be (@('/subscriptions/00000000-0000-0000-0000-0000000000a1/resourceGroups/rg-avd', '/subscriptions/00000000-0000-0000-0000-0000000000a1/resourceGroups/rg-net', $ws, $ct) | Sort-Object)
    }

    It 'warns and prints the command when the sign-in can''t manage policies, and the test then fails' {
        $r = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd" @{ FAKEREADER_POLICY = 'deny' }
        $r.Text | Should -Match "Application Administrator runs: ./avd_ops_reader.ps1 -Mode Initialize -ClientId '[0-9a-f-]+' -Environment 'avd-reader' -Repo 'contoso/avd-runs' -Subscription 'sub-contoso-avd'"
        $r.Code | Should -Be 1
        $r.Text | Should -Match '\[FAIL \] Passwords blocked by policy'
    }

    It 'leaves no policy behind when assigning it is refused' {
        $r = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd" @{ FAKEREADER_POLICY = 'refdeny' }
        $r.Text | Should -Match 'Nothing was left behind'
        @((Get-FakeState).policies | Where-Object { $_ }).Count | Should -Be 0
        @((Get-FakeState).roles).Count | Should -Be 1 -Because 'the role assignments still run'
    }

    It 'reports a credential name taken by another subject instead of failing midway' {
        $null = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd"
        $raw = Get-Content -Raw $script:state | ConvertFrom-Json -AsHashtable
        $appObj = $raw.apps[0].id
        $raw.fics[$appObj][0].subject = 'repo:contoso@222/avd-runs@999:environment:avd-reader'
        $raw | ConvertTo-Json -Depth 20 | Set-Content $script:state
        $r = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd" @{ AVD_READER_CLIENT_ID = $raw.apps[0].appId }
        $r.Text | Should -Match 'The name is taken by subject'
        $r.Text | Should -Match 'Reader'
    }

    It 'as the reader scoped to resource groups, still finds its roles (it can''t list at subscription scope)' {
        $null = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd -ResourceGroup rg-avd"
        $id = (Get-FakeState).apps[0].appId
        $r = Invoke-Reader "-Mode Test" @{ AVD_READER_CLIENT_ID = $id; FAKEREADER_AS = 'reader' }
        $r.Code | Should -Be 0 -Because $r.Text
        $r.Text | Should -Match 'Reader on ResourceGroup'
    }

    It 'as the reader in a workflow, checks only its role assignments' {
        $null = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd"
        $id = (Get-FakeState).apps[0].appId
        $r = Invoke-Reader "-Mode Test" @{ AVD_READER_CLIENT_ID = $id; FAKEREADER_AS = 'reader' }
        $r.Code | Should -Be 0 -Because $r.Text
        $r.Text | Should -Match 'Reader on Subscription'
        @((Get-FakeState).calls | Where-Object { $_ -like '*graph*' -or $_ -like '*/v1.0/*' } | Select-Object -Last 1) | Should -Not -Match 'v1.0/applications/.+/federated'
    }

    It 'removes everything it made, and prints it' {
        $null = Invoke-Reader "-Mode Initialize -Repo contoso/avd-runs -Subscription sub-contoso-avd -Cost"
        $id = (Get-FakeState).apps[0].appId
        $r = Invoke-Reader "-Mode Remove -Confirm:`$false" @{ AVD_READER_CLIENT_ID = $id }
        $r.Code | Should -Be 0 -Because $r.Text
        $s = Get-FakeState
        @($s.apps | Where-Object { $_ }).Count | Should -Be 0
        @($s.sps | Where-Object { $_ }).Count | Should -Be 0
        @($s.roles | Where-Object { $_ }).Count | Should -Be 0
        @($s.policies | Where-Object { $_ }).Count | Should -Be 0
        $r.Text | Should -Match 'Removed app registration'
    }
}

Describe 'self-contained pair' {
    It 'the collector, validator and facts script never depend on the reader' {
        foreach ($f in 'avd_current_state_collector.ps1', 'avd_deployment_validator.ps1', 'avd_current_state_facts.ps1') {
            Get-Content -Raw (Join-Path $script:root $f) | Should -Not -Match 'AVD_READER|AvdReader|avd_ops_reader' -Because $f
        }
    }
}

Describe 'the sample workflow (samples/avd-ops-reader.yml)' {
    BeforeAll { $script:yml = Get-Content -Raw (Join-Path $script:root 'samples/avd-ops-reader.yml') }
    It 'runs only on a schedule or by hand (finding 2)' {
        $script:yml | Should -Not -Match '(?m)^\s+pull_request(_target)?:'
        $script:yml | Should -Match '(?m)^\s+environment: avd-reader'
    }
    It 'pins every action by commit (finding 11)' {
        foreach ($u in [regex]::Matches($script:yml, '(?m)^\s*(?:-\s*)?uses:\s*(\S+)')) { $u.Groups[1].Value | Should -Match '@[0-9a-f]{40}$' }
    }
    It 'never uploads the package as an artifact (finding 3) and asks only for an OIDC token' {
        $script:yml | Should -Not -Match 'upload-artifact'
        $script:yml | Should -Match 'id-token: write'
        $script:yml | Should -Not -Match 'secrets\.'
    }
}
