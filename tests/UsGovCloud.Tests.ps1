#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for Azure US Government & Microsoft 365 GCC High (usgov) support across
# collector, validator, facts snapshot (C11), assessment runner (C20/C21), and rebuild scope (C26).

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdRebuild.psm1') -Force
  Import-Module (Join-Path $script:root 'lib/AvdAssess.psm1') -Force

  $script:facts = Join-Path $script:root 'avd_current_state_facts.ps1'
  $script:collector = Join-Path $script:root 'avd_current_state_collector.ps1'
  $script:validator = Join-Path $script:root 'avd_deployment_validator.ps1'
  $script:method = Get-Content (Join-Path $script:root 'assess/method.json') -Raw | ConvertFrom-Json
  $script:register = Get-Content (Join-Path $script:root 'contracts/fact-register.json') -Raw | ConvertFrom-Json
  $script:c11Schema = Join-Path $script:root 'contracts/current-state-facts.schema.json'
  $script:c21Schema = Join-Path $script:root 'contracts/assessment.schema.json'

  function script:ConvertTo-Doc { param($Data) $Data | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
  function script:Write-TestJson { param($Path, $Data) New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null; ConvertTo-Json -InputObject $Data -Depth 8 | Set-Content $Path }
}

Describe 'C26 Cloud Environment Contract and Scope URI Resolution' {
  It 'resolves commercial and usgov environments from contracts/cloud-environments.json' {
    $comm = Resolve-AvdCloudEnvironment -Cloud 'commercial'
    $usgov = Resolve-AvdCloudEnvironment -Cloud 'usgov'

    $comm.azure.environmentName | Should -Be 'AzureCloud'
    $comm.entra.graphEndpoint | Should -Be 'https://graph.microsoft.com'
    $usgov.azure.environmentName | Should -Be 'AzureUSGovernment'
    $usgov.azure.armEndpoint | Should -Be 'https://management.usgovcloudapi.net'
    $usgov.azure.storageEndpointSuffix | Should -Be 'core.usgovcloudapi.net'
    $usgov.entra.graphEndpoint | Should -Be 'https://graph.microsoft.us'
    $usgov.powerPlatform.bapEndpoint | Should -Be 'https://high.api.bap.microsoft.us'
  }

  It 'substitutes host tokens in rebuild/scope.json for commercial and usgov' {
    Resolve-AvdScopeUri -Uri 'https://{graphHost}/v1.0/identity/conditionalAccess/policies' -Cloud 'commercial' |
      Should -Be 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
    Resolve-AvdScopeUri -Uri 'https://{graphHost}/v1.0/identity/conditionalAccess/policies' -Cloud 'usgov' |
      Should -Be 'https://graph.microsoft.us/v1.0/identity/conditionalAccess/policies'

    Resolve-AvdScopeUri -Uri 'https://{bapHost}/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2023-06-01' -Cloud 'usgov' |
      Should -Be 'https://high.api.bap.microsoft.us/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2023-06-01'

    Resolve-AvdScopeUri -Uri 'https://{logAnalyticsHost}/v1/workspaces/w/query' -Cloud 'usgov' |
      Should -Be 'https://api.loganalytics.us/v1/workspaces/w/query'
  }
}

Describe 'Collector and Validator -Cloud Parameter and Cross-Cloud Guard' {
  It 'declares [ValidateSet("commercial", "usgov")] -Cloud on both collector and validator' {
    foreach ($scriptPath in @($script:collector, $script:validator)) {
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
      $cloudParam = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Cloud' }
      $cloudParam | Should -Not -BeNullOrEmpty -Because $scriptPath
      $validateSet = $cloudParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
      @($validateSet.PositionalArguments.Value) | Should -Be @('commercial', 'usgov')
    }
  }

  It 'maps pinned session-host endpoints to US Gov domains in Get-AvdPinnedHostEndpoints when TargetCloud is usgov' {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:validator, [ref]$null, [ref]$null)
    $fnAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-AvdPinnedHostEndpoints' }, $true) | Select-Object -First 1
    $fnAst | Should -Not -BeNullOrEmpty
    . ([scriptblock]::Create($fnAst.Extent.Text))

    $commMap = Get-AvdPinnedHostEndpoints -Root $script:root -TargetCloud 'commercial'
    $usgovMap = Get-AvdPinnedHostEndpoints -Root $script:root -TargetCloud 'usgov'
    $commRows = @($commMap.Probe)
    $usgovRows = @($usgovMap.Probe)

    $commRows.Count | Should -BeGreaterThan 0
    $usgovRows.Count | Should -Be $commRows.Count
    ($usgovRows | Where-Object { $_.Host -eq 'login.microsoftonline.us' }) | Should -Not -BeNullOrEmpty
    ($usgovRows | Where-Object { $_.Host -like '*.core.usgovcloudapi.net' }) | Should -Not -BeNullOrEmpty
    ($usgovMap.NotTested | Where-Object { $_.Host -like '*.wvd.azure.us' }) | Should -Not -BeNullOrEmpty
    ($usgovRows | Where-Object { $_.Host -eq 'login.microsoftonline.com' }) | Should -BeNullOrEmpty
  }
}

Describe 'Facts Snapshot (C11) US Gov Support and .onmicrosoft.us Redaction' {
  BeforeAll {
    $script:tenant = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    $script:subId = '11111111-2222-4333-8444-555555555555'
    $script:hpId = "/subscriptions/$($script:subId)/resourceGroups/rg-agency-avd/providers/Microsoft.DesktopVirtualization/hostpools/hp-agency-mission"
    $script:key = Join-Path $TestDrive 'usgov.key'
  }

  It 'emits cloud = usgov and redacts .onmicrosoft.us UPNs and hostnames without leaking' {
    $dir = Join-Path $TestDrive 'usgov-pkg'
    $pkg = Join-Path $dir 'avd-current-state-20261021T090000'
    Write-TestJson "$pkg/manifest.json" @{
      PackageName = 'avd-current-state-20261021T090000'
      GeneratedUtc = '2026-10-21T09:00:00Z'
      Cloud = 'usgov'
      TenantId = $script:tenant
      Identity = 'jane.doe@agency.onmicrosoft.us'
      SubscriptionDetails = @(@{ SubscriptionName = 'Agency Gov Prod'; SubscriptionId = $script:subId; Status = 'Collected' })
    }
    $sub = Join-Path $pkg 'Agency_Gov_Prod'
    Write-TestJson "$sub/resource-groups.json" @(@{ ResourceGroupName = 'rg-agency-avd'; Location = 'usgovvirginia' })
    Write-TestJson "$sub/avd-host-pools.json" @(@{
      Name = 'hp-agency-mission'; ResourceGroupName = 'rg-agency-avd'; Location = 'usgovvirginia'; HostPoolType = 'Pooled'
      LoadBalancerType = 'BreadthFirst'; PreferredAppGroupType = 'Desktop'; MaxSessionLimit = 8; StartVMOnConnect = $true
      CustomRdpProperty = 'drivestoredirect:s:0;usbdevicestoredirect:s:0;redirectclipboard:i:0;'
      Id = $script:hpId
    })
    Write-TestJson "$sub/avd-session-hosts.json" @(@{
      HostPool = 'hp-agency-mission'; Name = 'hp-agency-mission/avdhost-0.agency.onmicrosoft.us'
      Status = 'Available'; AllowNewSession = $true; Sessions = 1; LastHeartBeat = '2026-10-21T09:00:00Z'
    })
    Write-TestJson "$sub/role-assignments.json" @(@{
      DisplayName = 'Jane Doe'; SignInName = 'jane.doe@agency.onmicrosoft.us'; RoleDefinitionName = 'Desktop Virtualization User'; ObjectType = 'User'; ObjectId = '0f1e2d3c-4b5a-4968-8778-695a4b3c2d1e'
    })

    $outDir = Join-Path $TestDrive 'usgov-out'
    $file = & $script:facts -PackagePath $dir -KeyPath $script:key -NewKey -OutputPath $outDir 6>$null
    $text = Get-Content -LiteralPath $file -Raw
    $data = $text | ConvertFrom-Json

    $errs = $null
    Test-Json -Json $text -SchemaFile $script:c11Schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
    $data.cloud | Should -Be 'usgov'
    $text | Should -Not -Match 'onmicrosoft\.us'
    $text | Should -Not -Match 'jane\.doe'
    $text | Should -Not -Match 'hp-agency-mission'
  }

  It 'fails closed when commercial and usgov packages are mixed in one snapshot run' {
    $dir = Join-Path $TestDrive 'mixed-pkgs'
    $pkg1 = Join-Path $dir 'avd-current-state-20261021T090000'
    Write-TestJson "$pkg1/manifest.json" @{
      PackageName = 'avd-current-state-20261021T090000'; GeneratedUtc = '2026-10-21T09:00:00Z'; Cloud = 'usgov'
      TenantId = $script:tenant; SubscriptionDetails = @(@{ SubscriptionName = 'Gov'; SubscriptionId = $script:subId; Status = 'Collected' })
    }
    Write-TestJson "$pkg1/Gov/resource-groups.json" @(@{ ResourceGroupName = 'rg-gov'; Location = 'usgovvirginia' })

    $pkg2 = Join-Path $dir 'avd-validation-20261021T100000'
    Write-TestJson "$pkg2/manifest.json" @{
      PackageName = 'avd-validation-20261021T100000'; GeneratedUtc = '2026-10-21T10:00:00Z'; Cloud = 'commercial'; Mode = 'PostDeployment'; Verdict = 'PASS'
      TenantId = $script:tenant; SubscriptionId = $script:subId; Counts = @{ Fail = 0; Warn = 0; Pass = 1; Info = 0; Skip = 0 }
    }
    Write-TestJson "$pkg2/validation-results.json" @()

    { & $script:facts -PackagePath $dir -KeyPath $script:key -OutputPath (Join-Path $TestDrive 'mixed-out') 6>$null } |
      Should -Throw '*different cloud environments*'
  }
}

Describe 'Assessment Runner (C20/C21) US Gov and Compliance Profile Checks' {
  It 'marks usgov and compliance-profile checks not-applicable on commercial snapshots without complianceProfile' {
    $commSnap = ConvertTo-Doc @{
      schema = 'avd-current-state-facts/v1'; estate = 'est-0a1b2c3d'; generatedUtc = '2026-10-21T09:00:00Z'; cloud = 'commercial'
      subscriptions = @(@{ id = 'sub-1a2b3c4d'; regions = @('eastus2'); hostPools = @(@{ id = 'hp-00000001'; region = 'eastus2'; type = 'Pooled' }) })
    }
    $commIntake = ConvertTo-Doc @{
      schema = 'avd-intake/v1'; estate = 'est-0a1b2c3d'; answeredOn = '2026-10-21'; cloud = 'commercial'
      residency = @{ required = $true; regions = @('eastus2') }; preferredRegions = @('eastus2')
      existingHub = 'azure-hub'; identityConstraints = 'entra-only'
      workingHours = @{ start = '07:00'; end = '19:00'; days = @('Mon'); timeZone = 'UTC' }
    }
    $report = Get-AvdAssessment -Method $script:method -MethodCommit ('ab' * 20) -MethodSha256 ('cd' * 32) -Register $script:register `
      -Snapshot $commSnap -SnapshotSha256 ('12' * 32) -Intake $commIntake -IntakeSha256 ('ef' * 32) `
      -ProducerName 'avd_current_state_facts.ps1' -ProducerVersion '1.4.0' -GeneratedUtc '2026-10-21T10:00:00Z'

    $byId = @{}; foreach ($r in $report.results) { $byId[$r.check] = $r.outcome }
    $byId['asm-gov-allowed-locations'] | Should -Be 'not-applicable'
    $byId['asm-gov-private-dns-zones'] | Should -Be 'not-applicable'
    $byId['asm-gov-itar-redirection-lockdown'] | Should -Be 'not-applicable'
    $byId['asm-gov-fips-tls-baseline'] | Should -Be 'not-applicable'
  }

  It 'evaluates usgov and itar_cui checks on a US Gov estate and validates against C21 schema' {
    $usgovSnap = ConvertTo-Doc @{
      schema = 'avd-current-state-facts/v1'; estate = 'est-0a1b2c3d'; generatedUtc = '2026-10-21T09:00:00Z'; cloud = 'usgov'
      subscriptions = @(
        @{
          id = 'sub-1a2b3c4d'
          regions = @('usgovvirginia')
          policy = @{ assignments = 2; doNotEnforce = 0 }
          hostPools = @(
            @{
              id = 'hp-00000001'
              region = 'usgovvirginia'
              type = 'Pooled'
              sessionHosts = @{ total = 2 }
              redirection = @{ drives = 'off'; clipboard = 'off'; printers = 'off'; usb = 'off' }
            }
          )
          storageAccounts = @(
            @{
              id = 'st-00000001'
              kind = 'FileStorage'
              privateEndpoint = $true
              smbChannelEncryption = 'aes256-gcm-only'
            }
          )
        }
      )
    }
    $usgovIntake = ConvertTo-Doc @{
      schema = 'avd-intake/v1'; estate = 'est-0a1b2c3d'; answeredOn = '2026-10-21'
      cloud = 'usgov'; complianceProfile = 'itar_cui'
      residency = @{ required = $true; regions = @('usgovvirginia') }; preferredRegions = @('usgovvirginia')
      existingHub = 'azure-hub'; identityConstraints = 'entra-only'
      workingHours = @{ start = '07:00'; end = '19:00'; days = @('Mon'); timeZone = 'UTC' }
    }
    $report = Get-AvdAssessment -Method $script:method -MethodCommit ('ab' * 20) -MethodSha256 ('cd' * 32) -Register $script:register `
      -Snapshot $usgovSnap -SnapshotSha256 ('12' * 32) -Intake $usgovIntake -IntakeSha256 ('ef' * 32) `
      -ProducerName 'avd_current_state_facts.ps1' -ProducerVersion '1.4.0' -GeneratedUtc '2026-10-21T10:00:00Z'

    $byId = @{}; foreach ($r in $report.results) { $byId[$r.check] = $r.outcome }
    $byId['asm-gov-allowed-locations'] | Should -Be 'pass'
    $byId['asm-gov-private-dns-zones'] | Should -Be 'pass'
    $byId['asm-gov-itar-redirection-lockdown'] | Should -Be 'pass'
    $byId['asm-gov-fips-tls-baseline'] | Should -Be 'pass'

    $json = $report | ConvertTo-Json -Depth 12
    $errs = $null
    Test-Json -Json $json -SchemaFile $script:c21Schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
  }
}
