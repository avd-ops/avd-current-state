#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for avd_current_state_facts.ps1 (contract C11 in avd-second-brain). The fixture
# packages are full of things that must never reach the snapshot: names, IDs, a UPN, IPs, tags.

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  $script:facts = Join-Path $script:root 'avd_current_state_facts.ps1'
  $script:schema = Join-Path $script:root 'contracts/current-state-facts.schema.json'

  $script:tenant = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
  $script:subId = '11111111-2222-4333-8444-555555555555'
  $script:hpId = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-avd/providers/Microsoft.DesktopVirtualization/hostpools/hp-contoso-finance"
  $script:stId = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-avd/providers/Microsoft.Storage/storageAccounts/stcontosoprofiles"
  $script:secrets = @('contoso', 'hp-contoso-finance', 'stcontosoprofiles', 'rg-contoso-avd', 'Contoso Production',
    'jane.doe', '10.20.30.40', '52.168.1.10', $script:tenant, $script:subId, 'avdhost-0', 'CostCenter', 'Finance Team')

  function Write-TestJson { param($Path, $Data) New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null; ConvertTo-Json -InputObject $Data -Depth 8 | Set-Content $Path }

  function New-TestCollector {
    param([string] $Dir, [string] $Stamp = '20261001T090000', [string] $Tenant = $script:tenant, [int] $Hosts = 3)
    $pkg = Join-Path $Dir "avd-current-state-$Stamp"
    $utc = "$($Stamp.Substring(0,4))-$($Stamp.Substring(4,2))-$($Stamp.Substring(6,2))T09:00:00Z"
    Write-TestJson "$pkg/manifest.json" @{ PackageName = "avd-current-state-$Stamp"; GeneratedUtc = $utc; TenantId = $Tenant; Identity = 'jane.doe@contoso.com'
      SubscriptionDetails = @(@{ SubscriptionName = 'Contoso Production'; SubscriptionId = $script:subId; Status = 'Collected' }) }
    $sub = Join-Path $pkg 'Contoso_Production'
    Write-TestJson "$sub/resource-groups.json" @(@{ ResourceGroupName = 'rg-contoso-avd'; Location = 'eastus2'; Tags = '{"CostCenter":"Finance Team"}' })
    Write-TestJson "$sub/arm-resources.json" @(@{ Name = 'hp-contoso-finance'; ResourceGroupName = 'rg-contoso-avd'; Location = 'eastus2'; ResourceId = $script:hpId })
    Write-TestJson "$sub/avd-host-pools.json" @(@{ Name = 'hp-contoso-finance'; ResourceGroupName = 'rg-contoso-avd'; Location = 'eastus2'; HostPoolType = 'Pooled'
        LoadBalancerType = 'BreadthFirst'; PreferredAppGroupType = 'Desktop'; MaxSessionLimit = 12; ValidationEnvironment = $false; StartVMOnConnect = $true
        CustomRdpProperty = 'drivestoredirect:s:;full address:s:10.20.30.40;audiocapturemode:i:1;'; Tags = '{"CostCenter":"Finance Team"}'; Id = $script:hpId })
    Write-TestJson "$sub/avd-application-groups.json" @(@{ Name = 'ag-contoso-desktop'; ApplicationGroupType = 'Desktop'; HostPoolArmPath = $script:hpId; FriendlyName = 'Contoso desktop' })
    $vmIds = 0..($Hosts - 1) | ForEach-Object { "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-avd/providers/Microsoft.Compute/virtualMachines/avdhost-$_" }
    Write-TestJson "$sub/avd-session-hosts.json" @(0..($Hosts - 1) | ForEach-Object {
        @{ HostPool = 'hp-contoso-finance'; Name = "hp-contoso-finance/avdhost-$_.contoso.com"; ResourceId = $vmIds[$_]; Status = if ($_ -eq 0) { 'Unavailable' } else { 'Available' }
          AllowNewSession = $true; AssignedUser = ''; Sessions = 2; LastHeartBeat = if ($_ -eq 0) { '2026-10-01T07:00:00Z' } else { $utc }
          OSVersion = '10.0.22631'; SxSStackVersion = 'rdp-sxs240919001'; AgentVersion = '1.0.9742.2400'; UpdateState = 'Succeeded' } })
    Write-TestJson "$sub/virtual-machines.json" @(0..($Hosts - 1) | ForEach-Object {
        @{ Name = "avdhost-$_"; ResourceGroupName = 'rg-contoso-avd'; Location = 'eastus2'; VMSize = 'Standard_D4ads_v5'; OsType = 'Windows'
          ImagePublisher = if ($_ -eq 0) { $null } else { 'MicrosoftWindowsDesktop' }; ImageOffer = 'office-365'; ImageSku = 'win11-23h2-avd-m365'
          PowerState = 'VM running'; Tags = '{"Owner":"jane.doe@contoso.com"}'; Id = $vmIds[$_] } })
    Write-TestJson "$sub/storage-accounts.json" @(@{ StorageAccountName = 'stcontosoprofiles'; Location = 'eastus2'; Kind = 'FileStorage'; SkuName = 'Premium_LRS'
        EnableHttpsOnly = $true; MinimumTlsVersion = 'TLS1_2'; AllowBlobPublicAccess = $false; NetworkRuleDefaultAction = 'Deny'; LargeFileShares = 'Enabled'; Id = $script:stId })
    Write-TestJson "$sub/private-endpoints.json" @(@{ Name = 'pe-stcontosoprofiles'; TargetResource = 'stcontosoprofiles'; GroupIds = 'file'; ConnectionStatus = 'Approved' })
    Write-TestJson "$sub/virtual-networks.json" @(@{ Name = 'vnet-contoso'; AddressSpace = '10.20.0.0/16'; DnsServers = '10.20.30.40'; SubnetCount = 1; EnableDdosProtection = $false })
    Write-TestJson "$sub/subnets.json" @(@{ Name = 'snet-contoso-hosts'; VNetName = 'vnet-contoso'; AddressPrefix = '10.20.30.0/24'; NSG = 'nsg-contoso'; RouteTable = 'rt-contoso'; Delegations = '' })
    Write-TestJson "$sub/route-tables.json" @(@{ Name = 'rt-contoso'; Routes = 'to-firewall:0.0.0.0/0->VirtualAppliance' })
    Write-TestJson "$sub/public-ips.json" @(@{ Name = 'pip-contoso'; IpAddress = '52.168.1.10' })
    Write-TestJson "$sub/role-assignments.json" @(
      @{ DisplayName = 'Jane Doe'; SignInName = 'jane.doe@contoso.com'; RoleDefinitionName = 'Desktop Virtualization User'; ObjectType = 'User'; ObjectId = '0f1e2d3c-4b5a-4968-8778-695a4b3c2d1e' }
      @{ DisplayName = 'Contoso Ops'; RoleDefinitionName = 'Contoso Custom Operator'; ObjectType = 'Group'; ObjectId = '1f1e2d3c-4b5a-4968-8778-695a4b3c2d1e' })
    Write-TestJson "$sub/policy-assignments.json" @(@{ DisplayName = 'Contoso allowed locations'; EnforcementMode = 'Default' })
    Write-TestJson "$sub/log-analytics-workspaces.json" @(@{ Name = 'law-contoso'; RetentionDays = 30; CustomerId = '2f1e2d3c-4b5a-4968-8778-695a4b3c2d1e' })
    # Resource Graph and REST rows the collector saves under rebuild/; ARM omits empty properties.
    Write-TestJson "$sub/rebuild/resources/microsoft.compute-virtualmachines.json" @(0..($Hosts - 1) | ForEach-Object {
        $vm = @{ id = $vmIds[$_]; name = "avdhost-$_"; type = 'microsoft.compute/virtualmachines'; properties = @{ hardwareProfile = @{ vmSize = 'Standard_D4ads_v5' } } }
        if ($_ -ne 0) { $vm.properties.securityProfile = @{ securityType = 'TrustedLaunch'; uefiSettings = @{ secureBootEnabled = $true; vTpmEnabled = $true } } }
        $vm })
    Write-TestJson "$sub/rebuild/resources/microsoft.storage-storageaccounts.json" @(@{ id = $script:stId; name = 'stcontosoprofiles'
        properties = @{ azureFilesIdentityBasedAuthentication = @{ directoryServiceOptions = 'AADKERB' } } })
    Write-TestJson "$sub/rebuild/rest/file-services.json" @(@{ parentId = $script:stId; status = 'ok'; error = ''
        items = @(@{ id = "$($script:stId)/fileServices/default"; properties = @{ protocolSettings = @{ smb = @{ channelEncryption = 'AES-128-GCM;AES-256-GCM;' } } } }) })
    Write-TestJson "$sub/rebuild/resources/microsoft.security-pricings.json" @(
      @{ id = "/subscriptions/$($script:subId)/providers/Microsoft.Security/pricings/VirtualMachines"; name = 'VirtualMachines'; properties = @{ pricingTier = 'Standard'; subPlan = 'P2' } }
      @{ id = "/subscriptions/$($script:subId)/providers/Microsoft.Security/pricings/StorageAccounts"; name = 'StorageAccounts'; properties = @{ pricingTier = 'Free' } })
    $pkg
  }

  function New-TestValidator {
    param([string] $Dir, [string] $Stamp = '20261002T090000')
    $pkg = Join-Path $Dir "avd-validation-$Stamp"
    Write-TestJson "$pkg/manifest.json" @{ PackageName = "avd-validation-$Stamp"; GeneratedUtc = '2026-10-02T09:00:00Z'; Mode = 'PostDeployment'; Verdict = 'FAIL'
      TenantId = $script:tenant; SubscriptionId = $script:subId; SubscriptionName = 'Contoso Production'; Identity = 'jane.doe@contoso.com'
      Counts = @{ Fail = 1; Warn = 1; Pass = 1; Info = 0; Skip = 0 }
      Inputs = @{ Location = 'eastus2'; ResourceGroupName = 'rg-contoso-avd'; SessionHostCount = 3; SessionHostVmSize = 'Standard_D4ads_v5'; StorageAccountName = 'stcontosoprofiles' } }
    Write-TestJson "$pkg/validation-results.json" @(
      @{ Phase = 'PostDeployment'; Category = 'SessionHost'; Check = 'Heartbeat freshness'; Status = 'FAIL'; Scope = 'hp-contoso-finance'; Detail = 'avdhost-0 last seen 2h ago'; Recommendation = 'Check avdhost-0' }
      @{ Phase = 'PostDeployment'; Category = 'Storage'; Check = 'Minimum TLS'; Status = 'PASS'; Scope = 'stcontosoprofiles'; Detail = '' }
      @{ Phase = 'PostDeployment'; Category = 'Naming'; Check = 'Host pool hp-contoso-finance name'; Status = 'WARN'; Scope = 'rg-contoso-avd'; Detail = '' })
    $pkg
  }

  function Invoke-Facts {
    param([string[]] $Packages, [string] $Key, [switch] $NewKey, [string] $Out)
    $file = & $script:facts -PackagePath $Packages -KeyPath $Key -NewKey:$NewKey -OutputPath $Out 6>$null
    [pscustomobject]@{ Path = $file; Text = Get-Content -LiteralPath $file -Raw; Data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json }
  }
}

Describe 'avd_current_state_facts.ps1' {
  BeforeAll {
    $script:pk = Join-Path $TestDrive 'packages'
    New-TestCollector $script:pk | Out-Null
    New-TestValidator $script:pk | Out-Null
    $script:key = Join-Path $TestDrive 'vault/.brain/facts.key'
    $script:run = Invoke-Facts -Packages $script:pk -Key $script:key -NewKey -Out (Join-Path $TestDrive 'out1')
  }

  It 'writes a snapshot that is valid avd-current-state-facts/v1' {
    $errs = $null
    Test-Json -Json $script:run.Text -SchemaFile $script:schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
  }

  It 'never copies a name, an ID, a UPN, an IP address or a tag' {
    foreach ($s in $script:secrets) { $script:run.Text | Should -Not -Match ([regex]::Escape($s)) }
  }

  It 'keeps the facts the brain reasons with' {
    $sub = $script:run.Data.subscriptions[0]
    $sub.id | Should -Match '^sub-[0-9a-f]{8}$'
    $hp = $sub.hostPools[0]
    $hp.id | Should -Match '^hp-[0-9a-f]{8}$'
    $hp.type | Should -Be 'Pooled'
    $hp.maxSessionLimit | Should -Be 12
    $hp.loadBalancer | Should -Be 'BreadthFirst'
    $hp.rdpProperties | Should -Be @('audiocapturemode', 'drivestoredirect', 'full address')
    $hp.appGroups.Desktop | Should -Be 1
    $hp.sessionHosts.total | Should -Be 3
    $hp.sessionHosts.status.Unavailable | Should -Be 1
    $hp.sessionHosts.staleHeartbeat | Should -Be 1
    $hp.vmSizes.Standard_D4ads_v5 | Should -Be 3
    @($hp.images | Where-Object publisher -eq 'custom').hosts | Should -Be 1
    $sub.storageAccounts[0].privateEndpoint | Should -BeTrue
    $sub.network.defaultRoutes.VirtualAppliance | Should -Be 1
    $sub.roleAssignments.roles.'Desktop Virtualization User' | Should -Be 1
    $sub.roleAssignments.roles.other | Should -Be 1
    $sub.logAnalytics.retentionDays.'30' | Should -Be 1
  }

  It 'keeps the security facts the assess method checks, without a property value' {
    $sub = $script:run.Data.subscriptions[0]
    $hp = $sub.hostPools[0]
    $hp.redirection.drives | Should -Be 'off'
    $hp.redirection.usb | Should -Be 'default'
    $hp.redirection.camera | Should -Be 'default'
    $hp.sessionHosts.trustedLaunch | Should -Be 2
    $hp.sessionHosts.notTrustedLaunch | Should -Be 1
    $sub.storageAccounts[0].smbChannelEncryption | Should -Be 'gcm'
    $sub.storageAccounts[0].filesIdentity | Should -Be 'AADKERB'
    $sub.defenderPlans.VirtualMachines | Should -Be 'Standard'
    $sub.defenderPlans.StorageAccounts | Should -Be 'Free'
  }

  It 'leaves the security facts out when a package has no rebuild rows' {
    $dir = Join-Path $TestDrive 'no-rebuild'
    $pkg = New-TestCollector $dir
    Get-ChildItem $pkg -Recurse -Directory -Filter 'rebuild' | Remove-Item -Recurse
    $r = Invoke-Facts -Packages $dir -Key $script:key -Out (Join-Path $TestDrive 'out7')
    $sub = $r.Data.subscriptions[0]
    $sub.PSObject.Properties.Name | Should -Not -Contain 'defenderPlans'
    $sub.hostPools[0].sessionHosts.PSObject.Properties.Name | Should -Not -Contain 'notTrustedLaunch'
    $sub.storageAccounts[0].PSObject.Properties.Name | Should -Not -Contain 'smbChannelEncryption'
    $errs = $null
    Test-Json -Json $r.Text -SchemaFile $script:schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
  }

  It 'points validator checks at pseudonyms and redacts a check name that holds a resource name' {
    $v = $script:run.Data.validations[0]
    $v.inputs.sessionHostCount | Should -Be 3
    ($v.checks | Where-Object check -eq 'Heartbeat freshness').target | Should -Be $script:run.Data.subscriptions[0].hostPools[0].id
    ($v.checks | Where-Object check -eq 'Minimum TLS').target | Should -Be $script:run.Data.subscriptions[0].storageAccounts[0].id
    @($v.checks | Where-Object check -eq 'redacted').Count | Should -Be 1
    $script:run.Data.redactedValues | Should -BeGreaterThan 0
  }

  It 'gives the same pseudonyms with the same key, and different ones with another key' {
    $again = Invoke-Facts -Packages $script:pk -Key $script:key -Out (Join-Path $TestDrive 'out2')
    $again.Data.subscriptions[0].hostPools[0].id | Should -Be $script:run.Data.subscriptions[0].hostPools[0].id
    $again.Data.estate | Should -Be $script:run.Data.estate
    $other = Invoke-Facts -Packages $script:pk -Key (Join-Path $TestDrive 'other.key') -NewKey -Out (Join-Path $TestDrive 'out3')
    $other.Data.subscriptions[0].hostPools[0].id | Should -Not -Be $script:run.Data.subscriptions[0].hostPools[0].id
  }

  It 'refuses a missing key unless -NewKey is given' {
    { & $script:facts -PackagePath $script:pk -KeyPath (Join-Path $TestDrive 'typo.key') -OutputPath $TestDrive 6>$null } | Should -Throw '*Key file not found*'
  }

  It 'uses the latest collector run and reads ZIPs' {
    $dir = Join-Path $TestDrive 'zips'
    New-TestCollector $dir -Stamp '20261001T090000' -Hosts 2 | Out-Null
    $newer = New-TestCollector $dir -Stamp '20261008T090000' -Hosts 4
    Compress-Archive -Path $newer -DestinationPath "$newer.zip"
    Remove-Item $newer -Recurse
    $r = Invoke-Facts -Packages $dir -Key $script:key -Out (Join-Path $TestDrive 'out4')
    $r.Data.subscriptions[0].hostPools[0].sessionHosts.total | Should -Be 4
    $r.Text | Should -Match '"collectedUtc": "2026-10-08T09:00:00Z"'
  }

  It 'says which design decisions the snapshot can support and which need measurement' {
    $log = & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath (Join-Path $TestDrive 'out5') 6>&1 | ForEach-Object { "$_" }
    $line = $log | Where-Object { $_ -like '*Manifest coverage:*' }
    $line | Should -Match 'Manifest coverage: 5 of 10 design decisions can come from this snapshot \(region, network mode, host pool type, application group, power settings\)'
    ($log -join ' ') | Should -Match 'Identity lane, VM size, Sessions per host, Host count, Profile share quota need measured usage: a Stratusphere UX assessment'
  }

  It 'counts host pool decisions only when the estate has host pools' {
    $dir = Join-Path $TestDrive 'no-pools'
    $pkg = New-TestCollector $dir
    Get-ChildItem $pkg -Recurse -Filter 'avd-*.json' | Remove-Item
    $log = & $script:facts -PackagePath $dir -KeyPath $script:key -OutputPath (Join-Path $TestDrive 'out6') 6>&1 | ForEach-Object { "$_" }
    ($log | Where-Object { $_ -like '*Manifest coverage:*' }) | Should -Not -Match 'host pool type'
  }

  It 'vendors the fact register byte for byte from avd-assess' {
    $pins = Get-Content (Join-Path $script:root 'contracts/PINS.json') -Raw | ConvertFrom-Json
    foreach ($f in $pins.files.PSObject.Properties) {
      (Get-FileHash (Join-Path $script:root "contracts/$($f.Name)") -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $f.Value -Because $f.Name
    }
  }

  It 'with -Assess, writes a valid C21 report beside the snapshot from the pinned method' {
    $out = Join-Path $TestDrive 'assess1'
    $log = & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath $out -Assess 6>&1 | ForEach-Object { "$_" }
    $files = @(Get-ChildItem $out -Filter '*.json' | Sort-Object Name)
    $files.Name | Should -HaveCount 2
    $report = $files | Where-Object Name -like 'avd-assessment-*'
    $snap = $files | Where-Object Name -like 'avd-current-state-facts-*'
    $report.Name.Substring(15) | Should -Be $snap.Name.Substring(24)
    $text = Get-Content $report.FullName -Raw
    $errs = $null
    Test-Json -Json $text -SchemaFile (Join-Path $script:root 'contracts/assessment.schema.json') -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
    foreach ($x in $script:secrets) { $text | Should -Not -Match ([regex]::Escape($x)) }
    $doc = $text | ConvertFrom-Json
    $pins = Get-Content (Join-Path $script:root 'assess/PINS.json') -Raw | ConvertFrom-Json
    $doc.method.commit | Should -Be $pins.commit
    $doc.method.sha256 | Should -Be $pins.files.'method.json'
    $doc.inputs.facts.sha256 | Should -Be (Get-FileHash $snap.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $doc.inputs.intake | Should -BeNullOrEmpty
    $outcome = @{}; foreach ($r in $doc.results) { $outcome[$r.check] = $r.outcome }
    $outcome['asm-pooled-host-redundancy'] | Should -Be 'pass'
    $outcome['asm-personal-start-vm-on-connect'] | Should -Be 'unknown'
    $outcome['asm-files-zone-redundant'] | Should -Be 'warn'
    $outcome['asm-files-private-endpoint'] | Should -Be 'pass'
    $outcome['asm-defender-servers'] | Should -Be 'pass'
    ($log | Where-Object { $_ -like '*reliability: score*' }) | Should -Not -BeNullOrEmpty
    ($log -join ' ') | Should -Match 'Assessment readiness: 2 of 10 design decisions are supported \(hostPool.type, hostPool.appGroup\)'
    ($log -join ' ') | Should -Not -Match 'Manifest coverage'
    ($log | Where-Object { $_ -like '*AVDCS-STATE*' }) | Should -Match ([regex]::Escape(('"assessment":"{0}"' -f $report.Name)))
  }

  It 'with -Assess and an intake for the estate, answers the decisions that need it' {
    $intake = Get-Content (Join-Path $script:root 'tests/portal/fixtures/intake.json') -Raw | ConvertFrom-Json
    $intake.estate = $script:run.Data.estate
    $intakeFile = Join-Path $TestDrive 'intake.json'
    $intake | ConvertTo-Json -Depth 6 | Set-Content $intakeFile
    $out = Join-Path $TestDrive 'assess2'
    & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath $out -Assess -IntakePath $intakeFile 6>$null | Out-Null
    $doc = Get-Content (Get-ChildItem $out -Filter 'avd-assessment-*').FullName -Raw | ConvertFrom-Json
    $doc.inputs.intake.sha256 | Should -Be (Get-FileHash $intakeFile -Algorithm SHA256).Hash.ToLowerInvariant()
    @($doc.decisions | Where-Object { $_.decision -eq 'region' })[0].status | Should -Be 'supported'
    @($doc.decisions | Where-Object { $_.status -eq 'needs-intake' }).Count | Should -Be 0
  }

  It 'refuses an intake for another estate, an invalid intake, and -IntakePath without -Assess' {
    $other = Join-Path $TestDrive 'other-intake.json'
    Copy-Item (Join-Path $script:root 'tests/portal/fixtures/intake.json') $other
    { & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath (Join-Path $TestDrive 'assess3') -Assess -IntakePath $other 6>$null } | Should -Throw '*another estate*'
    $bad = Join-Path $TestDrive 'bad-intake.json'
    '{"schema":"avd-intake/v1","estate":"est-0a1b2c3d"}' | Set-Content $bad
    { & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath (Join-Path $TestDrive 'assess4') -Assess -IntakePath $bad 6>$null } | Should -Throw '*avd-intake/v1*'
    { & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath $TestDrive -IntakePath $other 6>$null } | Should -Throw '*goes with -Assess*'
  }

  It 'with -Assess, checks the intake before writing anything, and resolves it from the current location' {
    $out = Join-Path $TestDrive 'assess5'
    $other = Join-Path $TestDrive 'other-intake.json'
    { & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath $out -Assess -IntakePath $other 6>$null } | Should -Throw
    @(Get-ChildItem $out -ErrorAction SilentlyContinue).Count | Should -Be 0
    { & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath $out -Assess -IntakePath $TestDrive 6>$null } | Should -Throw '*Intake file not found*'
    Push-Location $TestDrive
    try { & $script:facts -PackagePath $script:pk -KeyPath $script:key -OutputPath $out -Assess -IntakePath 'intake.json' 6>$null | Should -HaveCount 1 }
    finally { Pop-Location }
    @(Get-ChildItem $out -Filter 'avd-assessment-*').Count | Should -Be 1
  }

  It 'refuses packages from more than one tenant' {
    $dir = Join-Path $TestDrive 'two-tenants'
    New-TestCollector $dir -Stamp '20261001T090000' | Out-Null
    New-TestCollector $dir -Stamp '20261002T090000' -Tenant 'ffffffff-bbbb-4ccc-8ddd-eeeeeeeeeeee' | Out-Null
    { & $script:facts -PackagePath $dir -KeyPath $script:key -OutputPath $TestDrive 6>$null } | Should -Throw '*tenants*'
  }

  It 'emits planesCollected, entra, intune, m365 and powerPlatform facts without leaking tenant names' {
    $dir = Join-Path $TestDrive 'five-planes'
    $pkg = New-TestCollector $dir -Stamp '20261010T090000'
    $manifest = Get-Content "$pkg/manifest.json" -Raw | ConvertFrom-Json
    $manifest | Add-Member -NotePropertyName PlanesCollected -NotePropertyValue @{
      azure            = @{ status = 'collected' }
      entra            = @{ status = 'collected' }
      intune           = @{ status = 'collected' }
      m365             = @{ status = 'partial'; reason = 'teams-ps-unavailable' }
      'power-platform' = @{ status = 'collected' }
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content "$pkg/manifest.json"
    Write-TestJson "$pkg/entra/groups.json" @(@{ id = '33333333-2222-4333-8444-555555555555'; displayName = 'grp-contoso-avd-hosts'; groupTypes = @('DynamicMembership') })
    Write-TestJson "$pkg/entra/conditionalAccessPolicies.json" @(@{ id = '44444444-2222-4333-8444-555555555555'; displayName = 'CA-Contoso-AVD-MFA'; state = 'enabled'
        conditions = @{ applications = @{ includeApplications = @('9cdead84-a844-4324-93f2-b2e6bb768d07') }; users = @{ excludeUsers = @('55555555-2222-4333-8444-555555555555') } }
        grantControls = @{ builtInControls = @('mfa', 'compliantDevice') }; sessionControls = @{ signInFrequency = @{ isEnabled = $true } } })
    Write-TestJson "$pkg/entra/servicePrincipals.json" @(@{ id = '66666666-2222-4333-8444-555555555555'; displayName = 'stcontosoprofiles'; kerberosReady = $true })
    Write-TestJson "$pkg/entra/subscribedSkus.json" @(@{ skuPartNumber = 'SPE_E5'; prepaidUnits = @{ enabled = 100 }; consumedUnits = 75 })
    Write-TestJson "$pkg/intune/settings.json" @(@{ secureByDefault = $true })
    Write-TestJson "$pkg/intune/mdmPolicies.json" @(@{ id = 'mdm-1'; displayName = 'Contoso MDM'; appliesTo = 'all' })
    Write-TestJson "$pkg/intune/configurationPolicies.json" @(@{ id = 'cfg-1'; name = 'Contoso FSLogix Catalog'; technologies = 'mdm,windowsEnterpriseMultiSession'; fslogixConfigured = $true; rdpShortpathConfigured = $true; sessionTimeLimitsConfigured = $true; multiSessionUpdateRingAssigned = $true })
    Write-TestJson "$pkg/intune/managedDevices.json" @(
      @{ id = '77777777-2222-4333-8444-555555555555'; deviceName = 'avdhost-0'; complianceState = 'compliant'; lastSyncDateTime = '2026-10-10T08:00:00Z'; baselineApplied = $true }
      @{ id = '88888888-2222-4333-8444-555555555555'; deviceName = 'avdhost-orphan'; complianceState = 'noncompliant'; isAvdSessionHost = $true })
    Write-TestJson "$pkg/m365/configurationPolicies.json" @(@{ id = 'm365-1'; name = 'Contoso M365 VDI'; oneDriveSilentConfigEnabled = $true; oneDriveKfmState = 'enforced'; oneDriveFilesOnDemandEnabled = $true; m365AppsSharedComputerActivation = $true; outlookCachedModeConfigured = $true; teamsMediaOptimizationState = 'enabled'; mmrConfigured = $true })
    Write-TestJson "$pkg/power-platform/environments.json" @(@{ id = 'env-1'; displayName = 'Contoso AVD Prod'; properties = @{ environmentSku = 'Production' } })
    Write-TestJson "$pkg/power-platform/dlpPolicies.json" @(@{ id = 'dlp-1'; displayName = 'Contoso Strict DLP'; defaultConnectorsClassification = 'Blocked' })
    Write-TestJson "$pkg/power-platform/solutions.json" @(@{ id = 'sol-1'; displayName = 'Contoso Day2 Solution' })
    Write-TestJson "$pkg/power-platform/workflows.json" @(@{ id = 'wf-1'; displayName = 'Contoso Drain Host Flow'; state = 'activated' })
    Write-TestJson "$pkg/Contoso_Production/rebuild/resources/microsoft.powerplatform-enterprisepolicies.json" @(@{ id = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-avd/providers/Microsoft.PowerPlatform/enterprisePolicies/ep-contoso"; name = 'ep-contoso' })

    $r = Invoke-Facts -Packages $dir -Key $script:key -Out (Join-Path $TestDrive 'out-five-planes')
    $errs = $null
    Test-Json -Json $r.Text -SchemaFile $script:schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
    foreach ($s in ($script:secrets + @('grp-contoso-avd-hosts', 'CA-Contoso-AVD-MFA', 'avdhost-orphan', 'Contoso Strict DLP'))) {
      $r.Text | Should -Not -Match ([regex]::Escape($s))
    }
    $r.Data.planesCollected.m365.status | Should -Be 'partial'
    $r.Data.planesCollected.m365.reason | Should -Be 'teams-ps-unavailable'
    $r.Data.entra.caAvdRequiresMfa | Should -Be 'enforced'
    $r.Data.entra.caAvdBreakGlassExcluded | Should -BeTrue
    $r.Data.entra.skuAvdEligibleAvailable | Should -Be 25
    $r.Data.intune.fslogixProfileConfigured | Should -BeTrue
    $r.Data.subscriptions[0].hostPools[0].sessionHosts.intuneManaged | Should -Be 1
    $r.Data.subscriptions[0].hostPools[0].intuneOrphans | Should -Be 1
    $r.Data.m365.oneDriveKfmState | Should -Be 'enforced'
    $r.Data.powerPlatform.dlpDefaultGroupClassification | Should -Be 'Blocked'
    $r.Data.subscriptions[0].powerPlatform.enterprisePoliciesCount | Should -Be 1
  }
}
