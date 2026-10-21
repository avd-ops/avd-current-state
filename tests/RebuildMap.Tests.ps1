#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline round trip for the rebuild map (docs/rebuild-fidelity-spec.md, section 11): an estate shaped
# the way avd-landing-zone's parameters/dev.bicepparam deploys it must map back to those values, and a
# brownfield estate must say what the landing zone can't express instead of guessing. Fixture rows are
# Resource Graph shaped and omit empty properties the way ARM does. Placeholder IDs only.

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdRebuildMap.psm1') -Force
  $script:params = Get-Content (Join-Path $script:root 'rebuild/lz-parameters.json') -Raw | ConvertFrom-Json

  function ConvertTo-Row { param($Hashtable) $Hashtable | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

  $script:sub = '/subscriptions/11111111-2222-4333-8444-555555555555'
  $script:usersGroup = '00000000-0000-4000-8000-000000000001'
  $script:adminsGroup = '00000000-0000-4000-8000-000000000002'

  # avd-landing-zone parameters/dev.bicepparam at the pinned commit, as Azure holds it after a deploy.
  function Get-DevEstate {
    $base = 'avdlz-dev'
    $rg = @{}; foreach ($r in 'network', 'avd', 'hosts', 'storage', 'management') { $rg[$r] = "$($script:sub)/resourceGroups/rg-$base-$r" }
    $hp = "$($rg.avd)/providers/Microsoft.DesktopVirtualization/hostPools/vdpool-avdlz-dev"
    $ag = "$($rg.avd)/providers/Microsoft.DesktopVirtualization/applicationGroups/vdag-avdlz-dev-desktop"
    $vnet = "$($rg.network)/providers/Microsoft.Network/virtualNetworks/vnet-$base-spoke"
    $vm = "$($rg.hosts)/providers/Microsoft.Compute/virtualMachines/avdlzdsh-001"
    $nic = "$($rg.hosts)/providers/Microsoft.Network/networkInterfaces/avdlzdsh-001-nic"
    $st = "$($rg.storage)/providers/Microsoft.Storage/storageAccounts/stavdlzdevprof01"
    $law = "$($rg.management)/providers/Microsoft.OperationalInsights/workspaces/law-$base"
    $dcr = "$($rg.management)/providers/Microsoft.Insights/dataCollectionRules/microsoft-avdi-$base"
    $aa = "$($rg.management)/providers/Microsoft.Automation/automationAccounts/aa-$base"
    $zone = { param($n) "$($rg.network)/providers/Microsoft.Network/privateDnsZones/$n" }
    $pe = { param($n, $target, $group) ConvertTo-Row @{ id = "$($rg.network)/providers/Microsoft.Network/privateEndpoints/pe-$n"; name = "pe-$n"; location = 'northcentralus'
        properties = @{ subnet = @{ id = "$vnet/subnets/snet-private-endpoints" }; privateLinkServiceConnections = @(@{ name = $n; properties = @{ privateLinkServiceId = $target; groupIds = @($group) } }) } } }
    $rows = @{
      'microsoft.desktopvirtualization/hostpools' = @(ConvertTo-Row @{ id = $hp; name = 'vdpool-avdlz-dev'; location = 'northcentralus'
          tags = @{ workload = 'avd'; environment = 'dev'; managedBy = 'bicep'; landingZone = 'avdlz' }
          properties = @{ hostPoolType = 'Pooled'; maxSessionLimit = 8; validationEnvironment = $true; startVMOnConnect = $true
            customRdpProperty = 'enablerdsaadauth:i:1;targetisaadjoined:i:1;drivestoredirect:s:;usbdevicestoredirect:s:;redirectcomports:i:0;redirectsmartcards:i:1;redirectprinters:i:1;redirectclipboard:i:1;redirectwebauthn:i:1;audiomode:i:0;audiocapturemode:i:1;camerastoredirect:s:*;use multimon:i:1' } })
      'microsoft.desktopvirtualization/applicationgroups' = @(ConvertTo-Row @{ id = $ag; name = 'vdag-avdlz-dev-desktop'; properties = @{ applicationGroupType = 'Desktop'; hostPoolArmPath = $hp } })
      'microsoft.desktopvirtualization/hostpools/sessionhosts' = @(ConvertTo-Row @{ id = "$hp/sessionHosts/avdlzdsh-001"; name = 'vdpool-avdlz-dev/avdlzdsh-001'; properties = @{ resourceId = $vm } })
      'microsoft.desktopvirtualization/scalingplans' = @(ConvertTo-Row @{ id = "$($rg.avd)/providers/Microsoft.DesktopVirtualization/scalingPlans/vdscaling-avdlz-dev"; name = 'vdscaling-avdlz-dev'
          properties = @{ timeZone = 'UTC'; hostPoolReferences = @(@{ hostPoolArmPath = $hp; scalingPlanEnabled = $true }) } })
      'microsoft.compute/virtualmachines' = @(ConvertTo-Row @{ id = $vm; name = 'avdlzdsh-001'; location = 'northcentralus'
          properties = @{ hardwareProfile = @{ vmSize = 'Standard_E4as_v5' }; securityProfile = @{ encryptionAtHost = $true }
            osProfile = @{ computerName = 'avdlzdsh-001'; adminUsername = 'avdbreakglass' }
            storageProfile = @{ imageReference = @{ publisher = 'MicrosoftWindowsDesktop'; offer = 'office-365'; sku = 'win11-24h2-avd-m365'; version = 'latest' } }
            networkProfile = @{ networkInterfaces = @(@{ id = $nic }) } } })
      'microsoft.compute/virtualmachines/extensions' = @(ConvertTo-Row @{ id = "$vm/extensions/AADLoginForWindows"; name = 'AADLoginForWindows'
          properties = @{ publisher = 'Microsoft.Azure.ActiveDirectory'; type = 'AADLoginForWindows'; settings = @{ mdmId = '0000000a-0000-0000-c000-000000000000' } } })
      'microsoft.network/networkinterfaces' = @(ConvertTo-Row @{ id = $nic; name = 'avdlzdsh-001-nic'; properties = @{ ipConfigurations = @(@{ name = 'ipconfig1'; properties = @{ subnet = @{ id = "$vnet/subnets/snet-session-hosts" } } }) } })
      'microsoft.network/virtualnetworks' = @(ConvertTo-Row @{ id = $vnet; name = "vnet-$base-spoke"; location = 'northcentralus'
          properties = @{ addressSpace = @{ addressPrefixes = @('10.100.0.0/22') }
            subnets = @(
              @{ id = "$vnet/subnets/snet-session-hosts"; name = 'snet-session-hosts'; properties = @{ addressPrefix = '10.100.0.0/23'; natGateway = @{ id = "$($rg.network)/providers/Microsoft.Network/natGateways/ng-$base" } } }
              @{ id = "$vnet/subnets/snet-private-endpoints"; name = 'snet-private-endpoints'; properties = @{ addressPrefix = '10.100.2.0/27' } }) } })
      'microsoft.network/privateendpoints' = @((& $pe 'storage' $st 'file'), (& $pe 'hostpool' $hp 'connection'))
      'microsoft.storage/storageaccounts' = @(ConvertTo-Row @{ id = $st; name = 'stavdlzdevprof01'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' } })
      'microsoft.operationalinsights/workspaces' = @(ConvertTo-Row @{ id = $law; name = "law-$base"; properties = @{ retentionInDays = 30 } })
      'microsoft.insights/datacollectionrules' = @(ConvertTo-Row @{ id = $dcr; name = "microsoft-avdi-$base"; properties = @{ destinations = @{ logAnalytics = @(@{ name = 'law'; workspaceResourceId = $law }) } } })
      'microsoft.insights/datacollectionruleassociations' = @(ConvertTo-Row @{ id = "$vm/providers/Microsoft.Insights/dataCollectionRuleAssociations/avdi"; properties = @{ dataCollectionRuleId = $dcr } })
      'microsoft.automation/automationaccounts/runbooks' = @(ConvertTo-Row @{ id = "$aa/runbooks/Invoke-AvdPowerAction"; name = 'aa-avdlz-dev/Invoke-AvdPowerAction'
          properties = @{ runbookType = 'PowerShell'; publishContentLink = @{ uri = 'https://raw.githubusercontent.com/contoso/avd-landing-zone/0000000/scripts/automation/Invoke-AvdPowerAction.ps1' } } })
      'microsoft.logic/workflows' = @(ConvertTo-Row @{ id = "$($rg.management)/providers/Microsoft.Logic/workflows/logic-$base-shutdown-schedule"; name = "logic-$base-shutdown-schedule"
          properties = @{ definition = @{
              triggers = @{ Schedule = @{ type = 'Recurrence'; recurrence = @{ frequency = 'Week'; interval = 1; timeZone = 'Central Standard Time'
                    schedule = @{ weekDays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'); hours = @(20); minutes = @(0) } } } }
              actions = @{ Start_runbook_job = @{ type = 'Http'; inputs = @{ method = 'PUT'; body = @{ properties = @{ runbook = @{ name = 'Invoke-AvdPowerAction' }
                        parameters = @{ NamePrefix = 'avdlz'; Environment = 'dev'; Action = 'Stop'; Reason = 'schedule' } } } } } } } } })
      'microsoft.security/pricings' = @('VirtualMachines', 'StorageAccounts', 'KeyVaults' | ForEach-Object { ConvertTo-Row @{ id = "$($script:sub)/providers/Microsoft.Security/pricings/$_"; name = $_; properties = @{ pricingTier = 'Free' } } })
      'microsoft.authorization/policyassignments' = @(ConvertTo-Row @{ id = "$($script:sub)/providers/Microsoft.Authorization/policyAssignments/avdlz-allowed-locations"; name = 'avdlz-allowed-locations'
          properties = @{ scope = $script:sub; parameters = @{ listOfAllowedLocations = @{ value = @('northcentralus') } } } })
    }
    $rest = @{
      'run-commands' = @(@{ parentId = $vm; status = 'ok'; items = @(ConvertTo-Row @{ id = "$vm/runCommands/Configure-FSLogix"; name = 'Configure-FSLogix'
              properties = @{ parameters = @(@{ name = 'ProfileShareUncPath'; value = '\\stavdlzdevprof01.file.core.windows.net\profiles' }, @{ name = 'ProfileSizeMiB'; value = '30720' }) } }) })
      'file-shares' = @(@{ parentId = $st; status = 'ok'; items = @(ConvertTo-Row @{ id = "$st/fileServices/default/shares/profiles"; name = 'profiles'; properties = @{ shareQuota = 100 } }) })
      'private-dns-zone-groups' = @(
        @{ parentId = "$($rg.network)/providers/Microsoft.Network/privateEndpoints/pe-storage"; status = 'ok'; items = @(ConvertTo-Row @{ name = 'default'; properties = @{ privateDnsZoneConfigs = @(@{ name = 'file'; properties = @{ privateDnsZoneId = (& $zone 'privatelink.file.core.windows.net') } }) } }) }
        @{ parentId = "$($rg.network)/providers/Microsoft.Network/privateEndpoints/pe-hostpool"; status = 'ok'; items = @(ConvertTo-Row @{ name = 'default'; properties = @{ privateDnsZoneConfigs = @(@{ name = 'wvd'; properties = @{ privateDnsZoneId = (& $zone 'privatelink.wvd.microsoft.com') } }) } }) })
      'budgets' = @(@{ parentId = $script:sub; status = 'ok'; items = @() })
      'subscription-diagnostic-settings' = @(@{ parentId = $script:sub; status = 'ok'; items = @(ConvertTo-Row @{ name = 'avdlz-activity-log'; properties = @{ workspaceId = $law } }) })
    }
    $roles = @(
      [pscustomobject]@{ RoleDefinitionName = 'Desktop Virtualization User'; Scope = $ag; ObjectId = $script:usersGroup; ObjectType = 'Group' }
      [pscustomobject]@{ RoleDefinitionName = 'Virtual Machine User Login'; Scope = $rg.hosts; ObjectId = $script:usersGroup; ObjectType = 'Group' }
      [pscustomobject]@{ RoleDefinitionName = 'Virtual Machine Administrator Login'; Scope = $rg.hosts; ObjectId = $script:adminsGroup; ObjectType = 'Group' })
    return @{ Rows = $rows; Rest = $rest; Roles = $roles }
  }

  # A hand-built estate: AD DS join, RemoteApp, no scaling plan, no private endpoints, users assigned directly.
  function Get-BrownfieldEstate {
    $rg = "$($script:sub)/resourceGroups/rg-contoso-vdi"
    $hp = "$rg/providers/Microsoft.DesktopVirtualization/hostPools/hp-contoso-apps"
    $ag = "$rg/providers/Microsoft.DesktopVirtualization/applicationGroups/ag-contoso-apps"
    $vnet = "$rg/providers/Microsoft.Network/virtualNetworks/vnet-contoso"
    $vms = 1..2 | ForEach-Object { "$rg/providers/Microsoft.Compute/virtualMachines/ctxapp0$_" }
    $rows = @{
      'microsoft.desktopvirtualization/hostpools' = @(ConvertTo-Row @{ id = $hp; name = 'hp-contoso-apps'; location = 'eastus2'
          properties = @{ hostPoolType = 'Pooled'; maxSessionLimit = 20; preferredAppGroupType = 'RailApplications' } })
      'microsoft.desktopvirtualization/applicationgroups' = @(ConvertTo-Row @{ id = $ag; name = 'ag-contoso-apps'; properties = @{ applicationGroupType = 'RemoteApp'; hostPoolArmPath = $hp } })
      'microsoft.desktopvirtualization/hostpools/sessionhosts' = @(1..2 | ForEach-Object { ConvertTo-Row @{ id = "$hp/sessionHosts/ctxapp0$_.contoso.com"; properties = @{ resourceId = $vms[$_ - 1] } } })
      'microsoft.compute/virtualmachines' = @(1..2 | ForEach-Object { ConvertTo-Row @{ id = $vms[$_ - 1]; name = "ctxapp0$_"; zones = @("$_")
            properties = @{ hardwareProfile = @{ vmSize = $(if ($_ -eq 1) { 'Standard_D8s_v5' } else { 'Standard_D4s_v5' }) }; osProfile = @{ adminUsername = 'localadmin' }
              storageProfile = @{ imageReference = @{ id = "$rg/providers/Microsoft.Compute/galleries/gal_contoso/images/apps/versions/1.0.0" } }
              networkProfile = @{ networkInterfaces = @(@{ id = "$($vms[$_ - 1])-nic" }) } } } })
      'microsoft.compute/virtualmachines/extensions' = @(1..2 | ForEach-Object { ConvertTo-Row @{ id = "$($vms[$_ - 1])/extensions/joindomain"; properties = @{ type = 'JsonADDomainExtension' } } })
      'microsoft.network/networkinterfaces' = @(1..2 | ForEach-Object { ConvertTo-Row @{ id = "$($vms[$_ - 1])-nic"; properties = @{ ipConfigurations = @(@{ properties = @{ subnet = @{ id = "$vnet/subnets/vdi" } } }) } } })
      'microsoft.network/virtualnetworks' = @(ConvertTo-Row @{ id = $vnet; name = 'vnet-contoso'
          properties = @{ addressSpace = @{ addressPrefixes = @('10.10.0.0/16', '10.11.0.0/16') }; dhcpOptions = @{ dnsServers = @('10.10.0.4', '10.10.0.5') }
            subnets = @(@{ id = "$vnet/subnets/vdi"; name = 'vdi'; properties = @{ addressPrefix = '10.10.1.0/24' } }) } })
      'microsoft.storage/storageaccounts' = @(
        ConvertTo-Row @{ id = "$rg/providers/Microsoft.Storage/storageAccounts/stcontosoa"; name = 'stcontosoa'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' } }
        ConvertTo-Row @{ id = "$rg/providers/Microsoft.Storage/storageAccounts/stcontosob"; name = 'stcontosob'; kind = 'FileStorage'; sku = @{ name = 'Premium_ZRS' } })
      'microsoft.operationalinsights/workspaces' = @(
        ConvertTo-Row @{ id = "$rg/providers/Microsoft.OperationalInsights/workspaces/law-a"; name = 'law-a'; properties = @{ retentionInDays = 30 } }
        ConvertTo-Row @{ id = "$rg/providers/Microsoft.OperationalInsights/workspaces/law-b"; name = 'law-b'; properties = @{ retentionInDays = 90 } })
    }
    $roles = @([pscustomobject]@{ RoleDefinitionName = 'Desktop Virtualization User'; Scope = $ag; ObjectId = '00000000-0000-4000-8000-000000000003'; ObjectType = 'User' })
    return @{ Rows = $rows; Rest = @{ 'budgets' = @(@{ parentId = $script:sub; status = 'failed'; items = @() }) }; Roles = $roles }
  }
}

Describe 'rebuild/lz-parameters.json' {
  It 'pins the same landing zone commit as the scope file' {
    $scope = Get-Content (Join-Path $script:root 'rebuild/scope.json') -Raw | ConvertFrom-Json
    $script:params.landingZoneCommit | Should -Be $scope.landingZoneCommit
  }

  It 'lists every parameter once' {
    $names = @($script:params.parameters | ForEach-Object { $_.name })
    $names.Count | Should -BeGreaterThan 50
    @($names | Sort-Object -Unique).Count | Should -Be $names.Count
  }

  It 'reads literal defaults' {
    $byName = @{}; foreach ($p in $script:params.parameters) { $byName[$p.name] = $p }
    Get-LzDefaultValue $byName.autoShutdownScheduleAction | Should -Be 'Stop'
    Get-LzDefaultValue $byName.profileShareQuotaGiB | Should -Be 1024
    Get-LzDefaultValue $byName.enableProfileBackup | Should -BeTrue
    $zones = Get-LzDefaultValue $byName.availabilityZones
    $zones | Should -Be @(1, 2, 3)
    $days = Get-LzDefaultValue $byName.autoShutdownDays
    $days.Count | Should -Be 7
    Get-LzDefaultValue $byName.autoShutdownTimeZone | Should -BeNullOrEmpty
  }
}

Describe 'Get-LzRebuildMap: the dev landing zone round trip' {
  BeforeAll {
    $e = Get-DevEstate
    $script:maps = Get-LzRebuildMap -Rows $e.Rows -Rest $e.Rest -RoleAssignments $e.Roles -ParameterList $script:params
    $script:map = $script:maps[0]
    $script:p = $script:map.parameters
  }

  It 'builds one map with an entry for every parameter, in order' {
    @($script:maps).Count | Should -Be 1
    @($script:p.Keys) | Should -Be @($script:params.parameters | ForEach-Object { $_.name })
  }

  It 'recovers the values parameters/dev.bicepparam set' {
    $expected = [ordered]@{
      namePrefix = 'avdlz'; environmentName = 'dev'; location = 'northcentralus'; connectivityMode = 'Standalone'; deployImageBuildSubnets = $false
      sessionHostCount = 1; sessionHostVmSize = 'Standard_E4as_v5'; maxSessionLimit = 8; profileStorageSku = 'Premium_LRS'; profileShareQuotaGiB = 100
      enableProfileBackup = $false; logRetentionDays = 30; enableDefenderForCloud = $false; monthlyBudgetAmount = 0; autoShutdownTime = '20:00'
      startVmOnConnect = $true; autoShutdownTimeZone = 'Central Standard Time'
    }
    foreach ($k in $expected.Keys) { $script:p[$k].value | Should -Be $expected[$k] -Because $k }
    @($script:p.availabilityZones.value).Count | Should -Be 0
  }

  It 'recovers the landing zone defaults dev.bicepparam left alone' {
    $expected = [ordered]@{
      spokeAddressPrefix = '10.100.0.0/22'; sessionHostSubnetPrefix = '10.100.0.0/23'; privateEndpointSubnetPrefix = '10.100.2.0/27'
      enrollInIntune = $true; enableAvdPrivateLink = $true; sessionHostNamePrefix = 'avdlzdsh'; encryptionAtHost = $true; localAdminUsername = 'avdbreakglass'
      validationEnvironment = $true; fslogixProfileSizeMiB = 30720; scalingTimeZone = 'UTC'; enableAutoShutdown = $true; autoShutdownScheduleAction = 'Stop'
      autoShutdownBudgetAction = 'Lock'; autoShutdownBudgetPercent = 100; deploySubscriptionSettings = $true; enablePolicyGuardrails = $true; profileBackupRetentionDays = 30
    }
    foreach ($k in $expected.Keys) { $script:p[$k].value | Should -Be $expected[$k] -Because $k }
    $script:p.sessionHostImage.value.sku | Should -Be 'win11-24h2-avd-m365'
    @($script:p.allowedLocations.value) | Should -Be @('northcentralus')
    @($script:p.autoShutdownDays.value).Count | Should -Be 7
    $script:p.centralPrivateDnsZoneResourceIds.value.Count | Should -Be 0
    $script:p.tags.value.Count | Should -Be 0
  }

  It 'finds the groups from their role assignments' {
    $script:p.avdUsersGroupObjectId.value | Should -Be $script:usersGroup
    $script:p.avdAdminsGroupObjectId.value | Should -Be $script:adminsGroup
  }

  It 'never carries a secret and leaves deploy-time lookups to deploy.sh' {
    $script:p.localAdminPassword.status | Should -Be 'secret'
    $script:p.localAdminPassword.value | Should -BeNullOrEmpty
    $script:p.avdServicePrincipalObjectId.status | Should -Be 'deployTime'
    $script:p.autoShutdownRunbookUri.status | Should -Be 'deployTime'
  }

  It 'resolves every parameter: nothing ambiguous, unexpressible or unknown' {
    $open = @($script:p.Keys | Where-Object { @('ambiguous', 'unexpressible', 'unknown') -contains $script:p[$_].status })
    $open | Should -BeNullOrEmpty
    ($script:map.coverage.Values | Measure-Object -Sum).Sum | Should -Be @($script:params.parameters).Count
  }
}

Describe 'Get-LzRoundTripResult' {
  BeforeAll {
    $e = Get-DevEstate
    $script:devMap = (Get-LzRebuildMap -Rows $e.Rows -Rest $e.Rest -RoleAssignments $e.Roles -ParameterList $script:params)[0]
    $script:want = [ordered]@{ namePrefix = 'avdlz'; sessionHostCount = 1; sessionHostVmSize = 'Standard_E4as_v5'; availabilityZones = @(); avdUsersGroupObjectId = $script:usersGroup }
  }

  It 'passes the dev estate, from memory and from the JSON file the collector writes' {
    (Get-LzRoundTripResult -Map $script:devMap -Expected $script:want).Passed | Should -BeTrue
    $fromFile = ConvertTo-Json -InputObject $script:devMap -Depth 20 | ConvertFrom-Json
    $r = Get-LzRoundTripResult -Map $fromFile -Expected $script:want
    $r.Passed | Should -BeTrue
    @($r.Rows | Where-Object { $_.Check -eq 'match' }).Count | Should -Be 5
  }

  It 'fails on a different value or a missing parameter, and never prints values' {
    $wrong = [ordered]@{ sessionHostVmSize = 'Standard_D2as_v5'; noSuchParameter = 1 }
    $r = Get-LzRoundTripResult -Map $script:devMap -Expected $wrong
    $r.Passed | Should -BeFalse
    @($r.Rows | Where-Object { $_.Check -eq 'NO MATCH' }).Count | Should -Be 2
    ($r.Rows | ConvertTo-Json) | Should -Not -Match 'Standard_|avdlz|00000000-'
  }

  It 'fails a brownfield estate' {
    $b = Get-BrownfieldEstate
    $map = (Get-LzRebuildMap -Rows $b.Rows -Rest $b.Rest -RoleAssignments $b.Roles -ParameterList $script:params)[0]
    (Get-LzRoundTripResult -Map $map -Expected @{}).Passed | Should -BeFalse
  }
}

Describe 'Get-LzRebuildMap: a brownfield estate' {
  BeforeAll {
    $e = Get-BrownfieldEstate
    $script:p = (Get-LzRebuildMap -Rows $e.Rows -Rest $e.Rest -RoleAssignments $e.Roles -ParameterList $script:params)[0].parameters
  }

  It 'says what the landing zone cannot express' {
    foreach ($k in 'enrollInIntune', 'connectivityMode', 'spokeAddressPrefix', 'privateEndpointSubnetPrefix', 'scalingTimeZone', 'avdUsersGroupObjectId') {
      $script:p[$k].status | Should -Be 'unexpressible' -Because $k
    }
  }

  It 'says what needs a choice instead of guessing' {
    foreach ($k in 'namePrefix', 'environmentName', 'sessionHostVmSize', 'logRetentionDays') {
      $script:p[$k].status | Should -Be 'ambiguous' -Because $k
      $script:p[$k].value | Should -BeNullOrEmpty
    }
  }

  It 'marks what it could not read as unknown' {
    foreach ($k in 'profileStorageSku', 'fslogixProfileSizeMiB', 'monthlyBudgetAmount', 'avdAdminsGroupObjectId', 'enableDefenderForCloud', 'deploySubscriptionSettings') {
      $script:p[$k].status | Should -Be 'unknown' -Because $k
    }
  }

  It 'still finds what the estate does say' {
    $script:p.sessionHostCount.value | Should -Be 2
    $script:p.sessionHostNamePrefix.status | Should -Be 'ambiguous'
    @($script:p.availabilityZones.value) | Should -Be @(1, 2)
    $script:p.sessionHostImage.value.id | Should -Match '/galleries/gal_contoso/'
    @($script:p.dnsServers.value) | Should -Be @('10.10.0.4', '10.10.0.5')
    $script:p.enableAvdPrivateLink.value | Should -BeFalse
    $script:p.enableAutoShutdown.value | Should -BeFalse
  }
}
