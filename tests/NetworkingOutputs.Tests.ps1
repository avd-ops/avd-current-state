# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware, ServiceNow or Microsoft.
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path $script:Root 'Export-AvdNetworkingOutputs.ps1'
    $script:Sub = '/subscriptions/11111111-2222-4333-8444-555555555555'
    $script:HubId = "$($script:Sub)/resourceGroups/rg-avd-hub/providers/Microsoft.Network/virtualNetworks/vnet-avd-hub"
}

Describe 'Export-AvdNetworkingOutputs.ps1' {
    It 'exports C31 for a 3rd-party NVA hub with VPN and ExpressRoute gateways' {
        $rows = @(
            @{
                id            = $script:HubId
                type          = 'Microsoft.Network/virtualNetworks'
                location      = 'eastus2'
                resourceGroup = 'rg-avd-hub'
                properties    = @{
                    dhcpOptions = @{ dnsServers = @('10.0.5.68') }
                    subnets     = @(
                        @{ name = 'GatewaySubnet' }
                        @{ name = 'snet-nva-trusted' }
                    )
                }
            },
            @{
                id         = "$($script:Sub)/resourceGroups/rg-avd-spoke/providers/Microsoft.Network/routeTables/rt-spoke"
                type       = 'Microsoft.Network/routeTables'
                properties = @{
                    routes = @(
                        @{
                            name       = 'default-to-nva'
                            properties = @{
                                addressPrefix    = '0.0.0.0/0'
                                nextHopType      = 'VirtualAppliance'
                                nextHopIpAddress = '10.0.5.68'
                            }
                        }
                    )
                }
            },
            @{
                id         = "$($script:Sub)/resourceGroups/rg-avd-hub/providers/Microsoft.Network/virtualNetworkGateways/vgw-vpn"
                type       = 'Microsoft.Network/virtualNetworkGateways'
                properties = @{
                    gatewayType      = 'Vpn'
                    ipConfigurations = @(@{ properties = @{ subnet = @{ id = "$($script:HubId)/subnets/GatewaySubnet" } } })
                }
            },
            @{
                id         = "$($script:Sub)/resourceGroups/rg-avd-hub/providers/Microsoft.Network/virtualNetworkGateways/vgw-er"
                type       = 'Microsoft.Network/virtualNetworkGateways'
                properties = @{
                    gatewayType      = 'ExpressRoute'
                    ipConfigurations = @(@{ properties = @{ subnet = @{ id = "$($script:HubId)/subnets/GatewaySubnet" } } })
                }
            },
            @{
                id   = "$($script:Sub)/resourceGroups/rg-avd-hub/providers/Microsoft.Network/privateDnsZones/privatelink.wvd.microsoft.com"
                name = 'privatelink.wvd.microsoft.com'
                type = 'Microsoft.Network/privateDnsZones'
            }
        ) | ConvertTo-Json -Depth 10 | ConvertFrom-Json

        $outPath = Join-Path $TestDrive 'networking-outputs.json'
        $c31 = & $script:ScriptPath -Rows $rows -OutputPath $outPath

        $c31.schema | Should -Be 'avd-networking-outputs/v1'
        $c31.firewallMode | Should -Be 'nva'
        $c31.hubFirewallPrivateIp | Should -Be '10.0.5.68'
        $c31.dnsServers | Should -Contain '10.0.5.68'
        $c31.vpnGatewayResourceId | Should -Match 'vgw-vpn$'
        $c31.expressRouteGatewayResourceId | Should -Match 'vgw-er$'
        $c31.centralPrivateDnsZoneResourceIds.avd | Should -Match 'privatelink\.wvd\.microsoft\.com$'
        (Test-Path $outPath) | Should -BeTrue
    }

    It 'exports C31 for an Azure Firewall hub' {
        $rows = @(
            @{
                id            = $script:HubId
                type          = 'Microsoft.Network/virtualNetworks'
                location      = 'usgovvirginia'
                resourceGroup = 'rg-avd-hub'
                properties    = @{
                    subnets = @(@{ name = 'AzureFirewallSubnet' })
                }
            },
            @{
                id         = "$($script:Sub)/resourceGroups/rg-avd-hub/providers/Microsoft.Network/azureFirewalls/afw-hub"
                type       = 'Microsoft.Network/azureFirewalls'
                properties = @{
                    ipConfigurations = @(
                        @{
                            properties = @{
                                subnet           = @{ id = "$($script:HubId)/subnets/AzureFirewallSubnet" }
                                privateIPAddress = '10.0.1.4'
                            }
                        }
                    )
                }
            }
        ) | ConvertTo-Json -Depth 10 | ConvertFrom-Json

        $c31 = & $script:ScriptPath -Rows $rows -Cloud 'usgov'
        $c31.cloud | Should -Be 'usgov'
        $c31.firewallMode | Should -Be 'azure-firewall'
        $c31.hubFirewallPrivateIp | Should -Be '10.0.1.4'
    }
}
