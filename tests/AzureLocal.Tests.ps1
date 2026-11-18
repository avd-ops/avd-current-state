#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for Azure Local and Arc-enabled session host facts in avd_current_state_facts.ps1.

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:facts = Join-Path $script:root 'avd_current_state_facts.ps1'
    $script:subId = '11111111-2222-4333-8444-555555555555'
    $script:tenant = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'

    function Write-AzLTestJson {
        param($Path, $Data)
        New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
        ConvertTo-Json -InputObject $Data -Depth 8 | Set-Content $Path
    }

    function New-AzLPackage {
        param([string]$Dir, [string]$Stamp = '20261116T120000')
        $pkg = Join-Path $Dir "avd-current-state-$Stamp"
        $utc = '2026-11-16T12:00:00Z'
        Write-AzLTestJson "$pkg/manifest.json" @{
            PackageName = "avd-current-state-$Stamp"
            GeneratedUtc = $utc
            TenantId = $script:tenant
            SubscriptionDetails = @(@{ SubscriptionName = 'Contoso Local'; SubscriptionId = $script:subId; Status = 'Collected' })
        }
        $sub = Join-Path $pkg 'Contoso_Local'
        $hpId = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-local/providers/Microsoft.DesktopVirtualization/hostpools/hp-local-vdi"
        Write-AzLTestJson "$sub/resource-groups.json" @(@{ ResourceGroupName = 'rg-contoso-local'; Location = 'eastus2' })
        Write-AzLTestJson "$sub/arm-resources.json" @(@{ Name = 'hp-local-vdi'; ResourceGroupName = 'rg-contoso-local'; Location = 'eastus2'; ResourceId = $hpId })
        Write-AzLTestJson "$sub/avd-host-pools.json" @(@{
            Name = 'hp-local-vdi'; ResourceGroupName = 'rg-contoso-local'; Location = 'eastus2'; HostPoolType = 'Pooled'
            LoadBalancerType = 'BreadthFirst'; PreferredAppGroupType = 'Desktop'; MaxSessionLimit = 10
            ValidationEnvironment = $false; StartVMOnConnect = $false; CustomRdpProperty = ''; Id = $hpId
        })
        Write-AzLTestJson "$sub/avd-application-groups.json" @()
        Write-AzLTestJson "$sub/virtual-machines.json" @()
        Write-AzLTestJson "$sub/storage-accounts.json" @()
        Write-AzLTestJson "$sub/private-endpoints.json" @()
        Write-AzLTestJson "$sub/virtual-networks.json" @()
        Write-AzLTestJson "$sub/subnets.json" @()
        Write-AzLTestJson "$sub/route-tables.json" @()
        Write-AzLTestJson "$sub/public-ips.json" @()
        Write-AzLTestJson "$sub/role-assignments.json" @()
        Write-AzLTestJson "$sub/policy-assignments.json" @()
        Write-AzLTestJson "$sub/log-analytics-workspaces.json" @()
        Write-AzLTestJson "$sub/key-vaults.json" @()
        return @{ Package = $pkg; Sub = $sub; Utc = $utc; HpId = $hpId }
    }
}

Describe 'Azure Local fact collection' {
    It 'classifies an azure-local host pool, counts Arc status, and emits estate azureLocal counts without leaking names' {
        $tmp = Join-Path $TestDrive 'azl-pure'
        $p = New-AzLPackage -Dir $tmp
        $m0 = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-local/providers/Microsoft.HybridCompute/machines/azlhost-0"
        $m1 = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-local/providers/Microsoft.HybridCompute/machines/azlhost-1"
        $vmi0 = "$m0/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"
        $vmi1 = "$m1/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"

        Write-AzLTestJson "$($p.Sub)/avd-session-hosts.json" @(
            @{ HostPool = 'hp-local-vdi'; Name = 'hp-local-vdi/azlhost-0.contoso.com'; ResourceId = $vmi0; Status = 'Available'; AllowNewSession = $true; Sessions = 1; LastHeartBeat = $p.Utc },
            @{ HostPool = 'hp-local-vdi'; Name = 'hp-local-vdi/azlhost-1.contoso.com'; ResourceId = $vmi1; Status = 'Unavailable'; AllowNewSession = $false; Sessions = 0; LastHeartBeat = $p.Utc }
        )
        Write-AzLTestJson "$($p.Sub)/rebuild/resources/microsoft.azurestackhci-clusters.json" @(
            @{ id = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-local/providers/Microsoft.AzureStackHCI/clusters/hcl-contoso-01"; name = 'hcl-contoso-01'; properties = @{ status = 'Connected'; reportedProperties = @{ clusterVersion = '10.0.25398.1' } } }
        )
        Write-AzLTestJson "$($p.Sub)/rebuild/resources/microsoft.extendedlocation-customlocations.json" @(
            @{ id = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-local/providers/Microsoft.ExtendedLocation/customLocations/cl-contoso-01"; name = 'cl-contoso-01' }
        )
        Write-AzLTestJson "$($p.Sub)/rebuild/resources/microsoft.azurestackhci-virtualmachineinstances.json" @(
            @{ id = $vmi0; name = 'default' },
            @{ id = $vmi1; name = 'default' }
        )
        Write-AzLTestJson "$($p.Sub)/rebuild/resources/microsoft.hybridcompute-machines.json" @(
            @{ id = $m0; name = 'azlhost-0'; properties = @{ status = 'Connected' } },
            @{ id = $m1; name = 'azlhost-1'; properties = @{ status = 'Disconnected' } }
        )
        Write-AzLTestJson "$($p.Sub)/rebuild/resources/microsoft.hybridcompute-machines-extensions.json" @(
            @{ id = "$m0/extensions/CloudDeviceExtension"; name = 'CloudDeviceExtension'; properties = @{ type = 'CloudDeviceExtension'; provisioningState = 'Succeeded' } },
            @{ id = "$m1/extensions/CloudDeviceExtension"; name = 'CloudDeviceExtension'; properties = @{ type = 'CloudDeviceExtension'; provisioningState = 'Failed' } }
        )

        $outDir = Join-Path $tmp 'out'
        $key = Join-Path $tmp 'facts.key'
        $out = & $script:facts -PackagePath $p.Package -KeyPath $key -NewKey -OutputPath $outDir 6>$null
        $raw = Get-Content -LiteralPath $out -Raw
        $facts = $raw | ConvertFrom-Json

        $subFact = $facts.subscriptions[0]
        $subFact.azureLocal.clusters | Should -Be 1
        $subFact.azureLocal.clustersRegistered23h2Plus | Should -Be 1
        $subFact.azureLocal.customLocations | Should -Be 1
        $subFact.azureLocal.vmInstances | Should -Be 2
        $subFact.azureLocal.connectedMachineAgentConnected | Should -Be 1

        $hp = $subFact.hostPools[0]
        $hp.hostPlacement | Should -Be 'azure-local'
        $hp.sessionHosts.azureLocalHosts | Should -Be 2
        $hp.sessionHosts.arcConnected | Should -Be 2
        $hp.sessionHosts.arcAgentDisconnected | Should -Be 1
        $hp.sessionHosts.cloudDeviceExtensionFailed | Should -Be 1

        $raw | Should -Not -Match 'azlhost|hcl-contoso|cl-contoso|contoso'
    }

    It 'flags a mixed host pool when Azure VMs and Azure Local VM instances share one pool' {
        $tmp = Join-Path $TestDrive 'azl-mixed'
        $p = New-AzLPackage -Dir $tmp
        $azVm = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-local/providers/Microsoft.Compute/virtualMachines/azvm-0"
        $vmi0 = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-local/providers/Microsoft.HybridCompute/machines/azlhost-0/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"

        Write-AzLTestJson "$($p.Sub)/avd-session-hosts.json" @(
            @{ HostPool = 'hp-local-vdi'; Name = 'hp-local-vdi/azvm-0'; ResourceId = $azVm; Status = 'Available'; AllowNewSession = $true; Sessions = 0; LastHeartBeat = $p.Utc },
            @{ HostPool = 'hp-local-vdi'; Name = 'hp-local-vdi/azlhost-0'; ResourceId = $vmi0; Status = 'Available'; AllowNewSession = $true; Sessions = 0; LastHeartBeat = $p.Utc }
        )

        $outDir = Join-Path $tmp 'out'
        $key = Join-Path $tmp 'facts.key'
        $out = & $script:facts -PackagePath $p.Package -KeyPath $key -NewKey -OutputPath $outDir 6>$null
        $facts = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json

        $hp = $facts.subscriptions[0].hostPools[0]
        $hp.hostPlacement | Should -Be 'mixed'
        $hp.sessionHosts.azureLocalHosts | Should -Be 1
    }

    It 'classifies an Azure VM host pool as azure when Azure Local inventory is present, and omits azureLocal when absent' {
        $tmp = Join-Path $TestDrive 'azl-azure'
        $p = New-AzLPackage -Dir $tmp
        $azVm = "/subscriptions/$($script:subId)/resourceGroups/rg-contoso-local/providers/Microsoft.Compute/virtualMachines/azvm-0"

        Write-AzLTestJson "$($p.Sub)/avd-session-hosts.json" @(
            @{ HostPool = 'hp-local-vdi'; Name = 'hp-local-vdi/azvm-0'; ResourceId = $azVm; Status = 'Available'; AllowNewSession = $true; Sessions = 0; LastHeartBeat = $p.Utc }
        )

        $outDir = Join-Path $tmp 'out'
        $key = Join-Path $tmp 'facts.key'
        $out = & $script:facts -PackagePath $p.Package -KeyPath $key -NewKey -OutputPath $outDir 6>$null
        $facts = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json

        $subFact = $facts.subscriptions[0]
        $subFact.PSObject.Properties.Name | Should -Not -Contain 'azureLocal'
        $subFact.hostPools[0].PSObject.Properties.Name | Should -Not -Contain 'hostPlacement'

        Write-AzLTestJson "$($p.Sub)/rebuild/resources/microsoft.azurestackhci-clusters.json" @()
        $outDir2 = Join-Path $tmp 'out2'
        $out2 = & $script:facts -PackagePath $p.Package -KeyPath $key -OutputPath $outDir2 6>$null
        $facts2 = Get-Content -LiteralPath $out2 -Raw | ConvertFrom-Json
        $facts2.subscriptions[0].hostPools[0].hostPlacement | Should -Be 'azure'
    }
}
