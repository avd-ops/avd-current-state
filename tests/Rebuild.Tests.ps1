#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for the rebuild-fidelity reads (docs/rebuild-fidelity-spec.md): the scope file, the
# never-collect scrubber and scan, Resource Graph and REST paging, and the datasets built from Resource
# Graph rows, down to a facts snapshot identical to the one the cmdlet-shaped datasets give. Fixture rows
# omit empty properties the way ARM does.

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdRebuild.psm1') -Force
  $script:facts = Join-Path $script:root 'avd_current_state_facts.ps1'

  $script:subId = '11111111-2222-4333-8444-555555555555'
  $script:rgId = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-avd"
  $script:hpId = "$($script:rgId)/providers/Microsoft.DesktopVirtualization/hostpools/hp-contoso-finance"
  $script:stId = "$($script:rgId)/providers/Microsoft.Storage/storageAccounts/stcontosoprofiles"
  $script:vnetId = "$($script:rgId)/providers/Microsoft.Network/virtualNetworks/vnet-contoso"

  function ConvertTo-Row { param($Hashtable) $Hashtable | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

  # The estate tests/Facts.Tests.ps1 builds from cmdlet-shaped datasets, as Resource Graph returns it.
  function Get-TestRowSet {
    $vmIds = 0..2 | ForEach-Object { "$($script:rgId)/providers/Microsoft.Compute/virtualMachines/avdhost-$_" }
    $rows = @{
      '*' = @(ConvertTo-Row @{ id = $script:hpId; name = 'hp-contoso-finance'; type = 'microsoft.desktopvirtualization/hostpools'; location = 'eastus2' })
      'microsoft.resources/subscriptions/resourcegroups' = @(ConvertTo-Row @{ id = $script:rgId; name = 'rg-contoso-avd'; location = 'eastus2'; tags = @{ CostCenter = 'Finance Team' }; properties = @{ provisioningState = 'Succeeded' } })
      'microsoft.desktopvirtualization/hostpools' = @(ConvertTo-Row @{ id = $script:hpId; name = 'hp-contoso-finance'; location = 'eastus2'; tags = @{ CostCenter = 'Finance Team' }
          properties = @{ hostPoolType = 'Pooled'; loadBalancerType = 'BreadthFirst'; preferredAppGroupType = 'Desktop'; maxSessionLimit = 12; validationEnvironment = $false; startVMOnConnect = $true
            customRdpProperty = 'drivestoredirect:s:;full address:s:10.20.30.40;audiocapturemode:i:1;' } })
      'microsoft.desktopvirtualization/applicationgroups' = @(ConvertTo-Row @{ id = "$($script:rgId)/providers/Microsoft.DesktopVirtualization/applicationgroups/ag-contoso-desktop"; name = 'ag-contoso-desktop'; location = 'eastus2'
          properties = @{ applicationGroupType = 'Desktop'; hostPoolArmPath = $script:hpId; friendlyName = 'Contoso desktop' } })
      'microsoft.desktopvirtualization/hostpools/sessionhosts' = @(0..2 | ForEach-Object {
          ConvertTo-Row @{ id = "$($script:hpId)/sessionhosts/avdhost-$_.contoso.com"; name = "hp-contoso-finance/avdhost-$_.contoso.com"
            properties = @{ resourceId = $vmIds[$_]; status = $(if ($_ -eq 0) { 'Unavailable' } else { 'Available' }); allowNewSession = $true; sessions = 2
              lastHeartBeat = $(if ($_ -eq 0) { '2026-10-01T07:00:00Z' } else { '2026-10-01T09:00:00Z' }); osVersion = '10.0.22631'; sxSStackVersion = 'rdp-sxs240919001'
              agentVersion = '1.0.9742.2400'; updateState = 'Succeeded' } } })
      'microsoft.compute/virtualmachines' = @(0..2 | ForEach-Object {
          $image = if ($_ -eq 0) { @{ id = "$($script:rgId)/providers/Microsoft.Compute/galleries/gal_contoso/images/win11/versions/1.0.0" } }
          else { @{ publisher = 'MicrosoftWindowsDesktop'; offer = 'office-365'; sku = 'win11-23h2-avd-m365'; version = 'latest'; exactVersion = '22631.4317.241010' } }
          ConvertTo-Row @{ id = $vmIds[$_]; name = "avdhost-$_"; location = 'eastus2'; tags = @{ Owner = 'jane.doe@contoso.com' }
            properties = @{ hardwareProfile = @{ vmSize = 'Standard_D4ads_v5' }; provisioningState = 'Succeeded'
              storageProfile = @{ osDisk = @{ osType = 'Windows'; diskSizeGB = 128 }; imageReference = $image }
              extended = @{ instanceView = @{ powerState = @{ code = 'PowerState/running'; displayStatus = 'VM running' } } } } } })
      'microsoft.storage/storageaccounts' = @(ConvertTo-Row @{ id = $script:stId; name = 'stcontosoprofiles'; location = 'eastus2'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }
          properties = @{ supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'; allowBlobPublicAccess = $false; networkAcls = @{ defaultAction = 'Deny' }; largeFileSharesState = 'Enabled' } })
      'microsoft.network/privateendpoints' = @(ConvertTo-Row @{ id = "$($script:rgId)/providers/Microsoft.Network/privateEndpoints/pe-stcontosoprofiles"; name = 'pe-stcontosoprofiles'; location = 'eastus2'
          properties = @{ subnet = @{ id = "$($script:vnetId)/subnets/snet-contoso-pe" }
            privateLinkServiceConnections = @(@{ name = 'file'; properties = @{ privateLinkServiceId = $script:stId; groupIds = @('file'); privateLinkServiceConnectionState = @{ status = 'Approved' } } }) } })
      'microsoft.network/virtualnetworks' = @(ConvertTo-Row @{ id = $script:vnetId; name = 'vnet-contoso'; location = 'eastus2'
          properties = @{ addressSpace = @{ addressPrefixes = @('10.20.0.0/16') }; dhcpOptions = @{ dnsServers = @('10.20.30.40') }
            subnets = @(@{ id = "$($script:vnetId)/subnets/snet-contoso-hosts"; name = 'snet-contoso-hosts'
                properties = @{ addressPrefix = '10.20.30.0/24'; networkSecurityGroup = @{ id = "$($script:rgId)/providers/Microsoft.Network/networkSecurityGroups/nsg-contoso" }
                  routeTable = @{ id = "$($script:rgId)/providers/Microsoft.Network/routeTables/rt-contoso" } } }) } })
      'microsoft.network/routetables' = @(ConvertTo-Row @{ id = "$($script:rgId)/providers/Microsoft.Network/routeTables/rt-contoso"; name = 'rt-contoso'; location = 'eastus2'
          properties = @{ routes = @(@{ name = 'to-firewall'; properties = @{ addressPrefix = '0.0.0.0/0'; nextHopType = 'VirtualAppliance'; nextHopIpAddress = '10.20.0.4' } }) } })
      'microsoft.network/publicipaddresses' = @(ConvertTo-Row @{ id = "$($script:rgId)/providers/Microsoft.Network/publicIPAddresses/pip-contoso"; name = 'pip-contoso'; location = 'eastus2'; sku = @{ name = 'Standard' }
          properties = @{ publicIPAllocationMethod = 'Static'; ipAddress = '52.168.1.10' } })
      'microsoft.operationalinsights/workspaces' = @(ConvertTo-Row @{ id = "$($script:rgId)/providers/Microsoft.OperationalInsights/workspaces/law-contoso"; name = 'law-contoso'; location = 'eastus2'
          properties = @{ retentionInDays = 30; customerId = '2f1e2d3c-4b5a-4968-8778-695a4b3c2d1e'; sku = @{ name = 'PerGB2018' } } })
    }
    return $rows
  }

  function Write-TestJson { param($Path, $Data) New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null; ConvertTo-Json -InputObject $Data -Depth 8 | Set-Content $Path }

  function Get-SessionResponse {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Pages', Justification = 'Read by the closure.')]
    param([object[]]$Pages)
    $state = @{ i = 0 }
    $invoker = { param($request) $r = $Pages[$state.i]; $state.i++; $state.last = $request; $r }.GetNewClosure()
    return @{ Invoker = $invoker; State = $state }
  }
}

Describe 'rebuild/scope.json' {
  BeforeAll { $script:scope = Get-RebuildScope -Path (Join-Path $script:root 'rebuild/scope.json') }

  It 'loads and pins a landing zone commit' {
    $script:scope.landingZoneCommit | Should -Match '^[0-9a-f]{40}$'
    @($script:scope.resourceGraph).Count | Should -BeGreaterThan 30
  }

  It 'reads every resource type the datasets are built from' {
    $types = @($script:scope.resourceGraph | ForEach-Object { $_.type })
    foreach ($t in (Get-TestRowSet).Keys | Where-Object { $_ -ne '*' }) { $types | Should -Contain $t }
  }

  It 'refuses an unknown table, a duplicate type and a REST read with no parent' {
    $bad = Join-Path $TestDrive 'scope.json'
    $base = Get-Content (Join-Path $script:root 'rebuild/scope.json') -Raw | ConvertFrom-Json
    $base.resourceGraph[0].table = 'everything'
    $base | ConvertTo-Json -Depth 10 | Set-Content $bad
    { Get-RebuildScope -Path $bad } | Should -Throw '*Unknown Resource Graph table*'
    $base = Get-Content (Join-Path $script:root 'rebuild/scope.json') -Raw | ConvertFrom-Json
    $base.resourceGraph += $base.resourceGraph[1]
    $base | ConvertTo-Json -Depth 10 | Set-Content $bad
    { Get-RebuildScope -Path $bad } | Should -Throw '*listed twice*'
    $base = Get-Content (Join-Path $script:root 'rebuild/scope.json') -Raw | ConvertFrom-Json
    $base.rest[0].parentTypes = @('microsoft.web/sites')
    $base | ConvertTo-Json -Depth 10 | Set-Content $bad
    { Get-RebuildScope -Path $bad } | Should -Throw "*doesn't read*"
  }
}

Describe 'Resource Graph and REST helpers' {
  It 'builds a whole-object query and refuses anything that is not a type' {
    Get-RebuildQuery -Table 'resources' -Type 'microsoft.desktopvirtualization/scalingplans' |
      Should -Be "resources | where type =~ 'microsoft.desktopvirtualization/scalingplans' | order by id asc"
    { Get-RebuildQuery -Table 'resources' -Type "x' | project secrets" } | Should -Throw
    Get-RebuildFileName -Type 'microsoft.compute/virtualmachines/extensions' | Should -Be 'microsoft.compute-virtualmachines-extensions.json'
  }

  It 'follows the skip token and stops on the last page' {
    $fake = Get-SessionResponse @(
      @{ StatusCode = 200; Content = '{"data":[{"id":"a"},{"id":"b"}],"$skipToken":"next"}' }
      @{ StatusCode = 200; Content = '{"data":[{"id":"c"}]}' }
      @{ StatusCode = 200; Content = '{"data":[{"id":"never"}]}' })
    $rows = Invoke-RebuildGraphQuery -Query 'resources' -SubscriptionId $script:subId -Invoker $fake.Invoker
    @($rows | ForEach-Object id) | Should -Be @('a', 'b', 'c')
    $fake.State.last.options['$skipToken'] | Should -Be 'next'
    $fake.State.last.subscriptions | Should -Be @($script:subId)
  }

  It 'stops on an empty page even when a skip token comes back' {
    $fake = Get-SessionResponse @(@{ StatusCode = 200; Content = '{"data":[],"$skipToken":"loop"}' }, @{ StatusCode = 200; Content = '{"data":[{"id":"never"}]}' })
    @(Invoke-RebuildGraphQuery -Query 'resources' -SubscriptionId $script:subId -Invoker $fake.Invoker).Count | Should -Be 0
    $fake.State.i | Should -Be 1
  }

  It 'reports the status and body when Resource Graph fails' {
    $fake = Get-SessionResponse @(@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' })
    { Invoke-RebuildGraphQuery -Query 'resources' -SubscriptionId $script:subId -Invoker $fake.Invoker } | Should -Throw '*HTTP 403*AuthorizationFailed*'
  }

  It 'reads a list with nextLink, a single object, a missing child and a failure' {
    $fake = Get-SessionResponse @(
      @{ StatusCode = 200; Content = '{"value":[{"name":"one"}],"nextLink":"https://management.azure.com/x?page=2"}' }
      @{ StatusCode = 200; Content = '{"value":[{"name":"two"}]}' })
    $r = Invoke-RebuildRestRead -Path '/x' -Invoker $fake.Invoker
    $r.Status | Should -Be 'ok'
    @($r.Items | ForEach-Object name) | Should -Be @('one', 'two')
    $fake.State.last | Should -Be '/x?page=2'

    $single = Get-SessionResponse @(@{ StatusCode = 200; Content = '{"name":"default","properties":{"protocolSettings":{}}}' })
    @((Invoke-RebuildRestRead -Path '/y' -Invoker $single.Invoker).Items).Count | Should -Be 1
    (Invoke-RebuildRestRead -Path '/z' -Invoker (Get-SessionResponse @(@{ StatusCode = 404; Content = '' })).Invoker).Status | Should -Be 'none'
    $failed = Invoke-RebuildRestRead -Path '/w' -Invoker (Get-SessionResponse @(@{ StatusCode = 500; Content = 'boom' })).Invoker
    $failed.Status | Should -Be 'failed'
    $failed.Error | Should -Be 'HTTP 500: boom'
  }
}

Describe 'never-collect scrubber and final scan' {
  It 'replaces secret values with a marker and keeps the rest' {
    $row = ConvertTo-Row @{ id = $script:hpId; properties = @{ registrationInfo = @{ token = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4eXoxMjM0NTY3OCJ9.c2ln'; expirationTime = '2026-10-21T00:00:00Z' }
        maxSessionLimit = 8; startVMOnConnect = $true } }
    $ext = ConvertTo-Row @{ properties = @{ publisher = 'Microsoft.Compute'; settings = @{ Name = 'contoso.com' }; protectedSettings = @{ Password = 'P@ss' } } }
    $rc = ConvertTo-Row @{ properties = @{ source = @{ scriptUri = 'https://stcontoso.blob.core.windows.net/s/x.ps1?sv=2024&sig=AbCdEfGhIjKlMnOpQrStUv%3D' }
        parameters = @(@{ name = 'ProfileSizeMiB'; value = '30720' }); protectedParameters = @(@{ name = 'RegistrationToken'; value = 'x' }) } }
    $safe = ConvertTo-RebuildSafeObject -InputObject @($row, $ext, $rc)
    $safe.Removed | Should -Be 4
    $o = $safe.Object
    $o[0].properties.registrationInfo.token | Should -Be '[removed]'
    $o[0].properties.registrationInfo.expirationTime | Should -Not -Be '[removed]'
    $o[0].properties.maxSessionLimit | Should -Be 8
    $o[0].properties.startVMOnConnect | Should -BeTrue
    $o[1].properties.protectedSettings | Should -Be '[removed]'
    $o[1].properties.settings.Name | Should -Be 'contoso.com'
    $o[2].properties.source.scriptUri | Should -Be '[removed: signed URL]'
    $o[2].properties.parameters[0].value | Should -Be '30720'
    $o[2].properties.protectedParameters | Should -Be '[removed]'
    (ConvertTo-Json $o -Depth 20) | Should -Not -Match 'P@ss|sig=|eyJ'
  }

  It 'keeps arrays as arrays and leaves an empty secret property alone' {
    $safe = ConvertTo-RebuildSafeObject -InputObject (ConvertTo-Row @{ list = @('a'); token = '' })
    ($safe.Object.list -is [array]) | Should -BeTrue
    $safe.Removed | Should -Be 0
  }

  It 'finds secret shapes the scrubber could miss, and nothing in clean text' {
    $key = ('A' * 86) + '=='
    (Get-RebuildSecretFinding -Text '{"x":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig"}') | Should -Contain 'JWT'
    (Get-RebuildSecretFinding -Text '{"u":"https://x/y?sv=1&sig=AbCdEfGhIjKlMnOpQrSt"}') | Should -Contain 'signed URL'
    (Get-RebuildSecretFinding -Text "{`"k`":`"$key`"}") | Should -Contain 'account key'
    (Get-RebuildSecretFinding -Text 'DefaultEndpointsProtocol=https;AccountName=x;AccountKey=abc') | Should -Contain 'connection string'
    @(Get-RebuildSecretFinding -Text ((Get-TestRowSet).Values | ConvertTo-Json -Depth 20)).Count | Should -Be 0
  }
}

Describe 'datasets built from Resource Graph rows' {
  BeforeAll { $script:rows = Get-TestRowSet }

  It 'keeps every column the cmdlet datasets wrote, in order' {
    $columns = @{
      'resource-groups'          = 'ResourceGroupName,Location,ProvisioningState,Tags'
      'arm-resources'            = 'Name,ResourceGroupName,ResourceType,Location,ResourceId,Tags'
      'virtual-networks'         = 'Name,ResourceGroupName,Location,AddressSpace,DnsServers,SubnetCount,EnableDdosProtection,Id'
      'subnets'                  = 'Name,VNetName,AddressPrefix,NSG,RouteTable,ServiceEndpoints,Delegations,PrivateEndpointNetworkPolicies,Id'
      'route-tables'             = 'Name,ResourceGroupName,Location,RouteCount,DisableBgpRoutePropagation,Routes,Id'
      'public-ips'               = 'Name,ResourceGroupName,Location,PublicIpAllocationMethod,IpAddress,Sku,AssociatedTo,Id'
      'virtual-machines'         = 'Name,ResourceGroupName,Location,VMSize,OsType,OsDiskSize,ImagePublisher,ImageOffer,ImageSku,ImageVersion,DataDiskCount,PowerState,ProvisioningState,AvailabilitySet,Tags,Id'
      'storage-accounts'         = 'StorageAccountName,ResourceGroupName,Location,Kind,SkuName,AccessTier,EnableHttpsOnly,MinimumTlsVersion,AllowBlobPublicAccess,NetworkRuleDefaultAction,LargeFileShares,Tags,Id'
      'log-analytics-workspaces' = 'Name,ResourceGroupName,Location,Sku,RetentionDays,CustomerId,ResourceId'
      'private-endpoints'        = 'Name,ResourceGroupName,Location,Subnet,VNet,TargetResource,GroupIds,ConnectionStatus,Id'
      'avd-host-pools'           = 'Name,ResourceGroupName,Location,HostPoolType,LoadBalancerType,PreferredAppGroupType,MaxSessionLimit,ValidationEnvironment,StartVMOnConnect,CustomRdpProperty,Tags,Id'
      'avd-application-groups'   = 'Name,ResourceGroupName,Location,ApplicationGroupType,HostPoolArmPath,FriendlyName,Description,Tags,Id'
      'avd-session-hosts'        = 'HostPool,Name,ResourceId,Status,AllowNewSession,AssignedUser,Sessions,LastHeartBeat,OSVersion,SxSStackVersion,AgentVersion,UpdateState,StatusTimestamp'
    }
    foreach ($name in $columns.Keys) {
      $first = @(Get-RebuildDataset -Name $name -Rows $script:rows)[0]
      ($first.PSObject.Properties.Name -join ',') | Should -Be $columns[$name] -Because $name
    }
  }

  It 'maps the values the facts and the vault read' {
    $vm = @(Get-RebuildDataset -Name 'virtual-machines' -Rows $script:rows)
    $vm[0].ImagePublisher | Should -BeNullOrEmpty
    $vm[1].ImagePublisher | Should -Be 'MicrosoftWindowsDesktop'
    $vm[1].ImageVersion | Should -Be '22631.4317.241010'
    $vm[1].PowerState | Should -Be 'VM running'
    $vm[1].DataDiskCount | Should -Be 0
    $vm[1].ResourceGroupName | Should -Be 'rg-contoso-avd'
    $sh = @(Get-RebuildDataset -Name 'avd-session-hosts' -Rows $script:rows)
    $sh[0].HostPool | Should -Be 'hp-contoso-finance'
    $sh[0].Name | Should -Be 'hp-contoso-finance/avdhost-0.contoso.com'
    $sh[0].AssignedUser | Should -BeNullOrEmpty
    (Get-RebuildDataset -Name 'route-tables' -Rows $script:rows)[0].Routes | Should -Be 'to-firewall:0.0.0.0/0->VirtualAppliance'
    $pe = (Get-RebuildDataset -Name 'private-endpoints' -Rows $script:rows)[0]
    $pe.TargetResource | Should -Be 'stcontosoprofiles'
    $pe.VNet | Should -Be 'vnet-contoso'
    $pe.Subnet | Should -Be 'snet-contoso-pe'
    $sn = (Get-RebuildDataset -Name 'subnets' -Rows $script:rows)[0]
    $sn.NSG | Should -Be 'nsg-contoso'
    $sn.Delegations | Should -Be ''
    (Get-RebuildDataset -Name 'resource-groups' -Rows $script:rows)[0].Tags | Should -Be '{"CostCenter":"Finance Team"}'
    (Get-RebuildDataset -Name 'avd-application-groups' -Rows $script:rows)[0].Tags | Should -BeNullOrEmpty
  }

  It 'reads plural NSG prefixes and treats an omitted soft delete as on' {
    $rows = @{
      'microsoft.network/networksecuritygroups' = @(ConvertTo-Row @{ id = "$($script:rgId)/providers/Microsoft.Network/networkSecurityGroups/nsg-contoso"; name = 'nsg-contoso'; location = 'eastus2'
          properties = @{ securityRules = @(@{ name = 'Deny-RDP'; properties = @{ direction = 'Outbound'; priority = 4000; access = 'Deny'; protocol = 'Tcp'; sourceAddressPrefix = '*'; sourcePortRange = '*'
                  destinationAddressPrefix = 'VirtualNetwork'; destinationPortRanges = @('3389', '22') } }) } })
      'microsoft.keyvault/vaults' = @(ConvertTo-Row @{ id = "$($script:rgId)/providers/Microsoft.KeyVault/vaults/kvcontoso"; name = 'kvcontoso'; location = 'eastus2'; properties = @{ sku = @{ name = 'standard' }; enablePurgeProtection = $true } })
    }
    $rule = (Get-RebuildDataset -Name 'nsg-rules' -Rows $rows)[0]
    $rule.DestinationPortRange | Should -Be '3389, 22'
    $rule.NSGName | Should -Be 'nsg-contoso'
    (Get-RebuildDataset -Name 'nsgs' -Rows $rows)[0].DefaultRuleCount | Should -Be 0
    $kv = (Get-RebuildDataset -Name 'key-vaults' -Rows $rows)[0]
    $kv.EnableSoftDelete | Should -BeTrue
    $kv.EnablePurgeProtection | Should -BeTrue
  }

  It 'returns nothing, not an error, for a type with no rows' {
    @(Get-RebuildDataset -Name 'recovery-services-vaults' -Rows @{}).Count | Should -Be 0
    { Get-RebuildDataset -Name 'no-such-dataset' -Rows @{} } | Should -Throw
  }

  It 'gives the same facts snapshot as the cmdlet-shaped datasets' {
    # The same estate as tests/Facts.Tests.ps1, once as the cmdlets wrote it and once from Resource Graph rows.
    $utc = '2026-10-01T09:00:00Z'
    $manifest = @{ PackageName = 'avd-current-state-20261001T090000'; GeneratedUtc = $utc; TenantId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
      SubscriptionDetails = @(@{ SubscriptionName = 'Contoso Production'; SubscriptionId = $script:subId; Status = 'Collected' }) }
    $policy = @(@{ DisplayName = 'Contoso allowed locations'; EnforcementMode = 'Default' })
    $roles = @(@{ RoleDefinitionName = 'Desktop Virtualization User'; ObjectType = 'User' })

    $graphPkg = Join-Path $TestDrive 'graph/avd-current-state-20261001T090000'
    Write-TestJson "$graphPkg/manifest.json" $manifest
    foreach ($name in 'resource-groups', 'arm-resources', 'virtual-networks', 'subnets', 'nsgs', 'nsg-rules', 'route-tables', 'public-ips', 'virtual-machines',
      'vm-extensions', 'storage-accounts', 'key-vaults', 'log-analytics-workspaces', 'recovery-services-vaults', 'private-endpoints', 'avd-host-pools',
      'avd-workspaces', 'avd-application-groups', 'avd-session-hosts') {
      $data = @(Get-RebuildDataset -Name $name -Rows $script:rows)
      if ($data.Count) { Write-TestJson "$graphPkg/Contoso_Production/$name.json" $data }
    }
    Write-TestJson "$graphPkg/Contoso_Production/policy-assignments.json" $policy
    Write-TestJson "$graphPkg/Contoso_Production/role-assignments.json" $roles
    # Secret-shaped and name-holding files under rebuild/ must not change the snapshot.
    Write-TestJson "$graphPkg/Contoso_Production/rebuild/resources/microsoft.desktopvirtualization-hostpools.json" @(@{ id = $script:hpId; name = 'hp-contoso-secret-pool' })

    $cmdletPkg = Join-Path $TestDrive 'cmdlet/avd-current-state-20261001T090000'
    Write-TestJson "$cmdletPkg/manifest.json" $manifest
    foreach ($name in (Get-ChildItem "$graphPkg/Contoso_Production" -Filter '*.json').BaseName) {
      $data = Get-Content "$graphPkg/Contoso_Production/$name.json" -Raw | ConvertFrom-Json
      if ($name -eq 'avd-host-pools') { $data = @($data | Select-Object * -ExcludeProperty Tags) }
      Write-TestJson "$cmdletPkg/Contoso_Production/$name.json" @($data)
    }

    $key = Join-Path $TestDrive 'facts.key'
    $a = & $script:facts -PackagePath (Split-Path $graphPkg) -KeyPath $key -NewKey -OutputPath (Join-Path $TestDrive 'o1') 6>$null
    $b = & $script:facts -PackagePath (Split-Path $cmdletPkg) -KeyPath $key -OutputPath (Join-Path $TestDrive 'o2') 6>$null
    $ja = Get-Content $a -Raw | ConvertFrom-Json
    $jb = Get-Content $b -Raw | ConvertFrom-Json
    ($ja.subscriptions | ConvertTo-Json -Depth 20) | Should -Be ($jb.subscriptions | ConvertTo-Json -Depth 20)
    (Get-Content $a -Raw) | Should -Not -Match 'secret-pool'
    $hp = $ja.subscriptions[0].hostPools[0]
    $hp.sessionHosts.total | Should -Be 3
    $hp.vmSizes.Standard_D4ads_v5 | Should -Be 3
    @($hp.images | Where-Object publisher -eq 'custom').hosts | Should -Be 1
    $ja.subscriptions[0].network.defaultRoutes.VirtualAppliance | Should -Be 1
    $ja.subscriptions[0].storageAccounts[0].privateEndpoint | Should -BeTrue
  }
}

Describe 'collector: Read-RebuildEvidence with a fake Azure' {
  BeforeAll {
    # Load only the collector's rebuild functions from its syntax tree, so nothing signs in or runs.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:root 'avd_current_state_collector.ps1'), [ref]$null, [ref]$null)
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Write-RebuildFile', 'Read-RebuildEvidence' }, $true)) {
      . ([scriptblock]::Create($f.Extent.Text))
    }
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') $script:log += "[$Level] $Message" }
    $script:RebuildScope = Get-RebuildScope -Path (Join-Path $script:root 'rebuild/scope.json')
    $script:RebuildReads = [System.Collections.Generic.List[psobject]]::new()
    $script:RebuildWithheld = [System.Collections.Generic.List[psobject]]::new()
    $script:log = @()
    $script:calls = [System.Collections.Generic.List[string]]::new()
    $testRows = Get-TestRowSet
    $hpWithToken = ConvertTo-Row @{ id = $script:hpId; name = 'hp-contoso-finance'; properties = @{ hostPoolType = 'Pooled'; registrationInfo = @{ token = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4eXoxMjM0NTY3OCJ9.c2ln' } } }
    function Invoke-AzRestMethod {
      param([string]$Method, [string]$Path, [string]$Payload)
      $script:calls.Add("$Method $Path")
      if ($Method -eq 'POST') {
        $query = ($Payload | ConvertFrom-Json).query
        if ($query -match "type =~ '([^']+)'") {
          $type = $Matches[1]
          $data = if ($type -eq 'microsoft.desktopvirtualization/hostpools') { @($hpWithToken) } elseif ($testRows.ContainsKey($type)) { @($testRows[$type]) } else { @() }
        } else { $data = @($testRows['*']) }
        return [pscustomobject]@{ StatusCode = 200; Content = (@{ data = $data } | ConvertTo-Json -Depth 30) }
      }
      if ($Path -match '/runCommands\?') {
        return [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"name":"Configure-FSLogix","properties":{"parameters":[{"name":"ProfileSizeMiB","value":"30720"}],"protectedParameters":[{"name":"x","value":"y"}]}}]}' }
      }
      if ($Path -match 'Consumption/budgets') { return [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
      return [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
    }
    $script:subDir = Join-Path $TestDrive 'Contoso_Production'
    $script:result = Read-RebuildEvidence -SubscriptionId $script:subId -SubDir $script:subDir
  }

  It 'writes one file per Resource Graph type and per REST read' {
    Test-Path (Join-Path $script:subDir 'rebuild/resources/microsoft.desktopvirtualization-hostpools.json') | Should -BeTrue
    Test-Path (Join-Path $script:subDir 'rebuild/resources/microsoft.desktopvirtualization-scalingplans.json') | Should -BeTrue
    Test-Path (Join-Path $script:subDir 'rebuild/rest/run-commands.json') | Should -BeTrue
    @($script:RebuildReads | Where-Object Source -ne 'rest').Count | Should -Be @($script:RebuildScope.resourceGraph).Count
  }

  It 'never writes the registration token or protected parameters' {
    $all = (Get-ChildItem (Join-Path $script:subDir 'rebuild') -Recurse -File | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    $all | Should -Not -Match 'eyJ'
    $all | Should -Match '"protectedParameters": "\[removed\]"'
    $all | Should -Match 'ProfileSizeMiB'
    $script:RebuildWithheld.Count | Should -Be 0
  }

  It 'reads Run Commands only on session hosts and records a failed read with its error' {
    @($script:calls | Where-Object { $_ -match '/runCommands\?' }).Count | Should -Be 3
    ($script:RebuildReads | Where-Object Read -eq 'budgets').Status | Should -Be 'failed for 1'
    ($script:log -join "`n") | Should -Match 'budgets failed.*HTTP 403.*AuthorizationFailed'
  }

  It 'returns rows the datasets are built from' {
    @(Get-RebuildDataset -Name 'avd-session-hosts' -Rows $script:result).Count | Should -Be 3
    @(Get-RebuildDataset -Name 'arm-resources' -Rows $script:result).Count | Should -Be 1
  }
}
