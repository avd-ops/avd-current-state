<#
    The rebuild map (docs/rebuild-fidelity-spec.md, sections 2 and 11): for each host pool, every
    avd-landing-zone parameter with a status, a value and the evidence it came from.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    Pure functions over what the collector saved: the Resource Graph rows keyed by type, the REST reads
    keyed by name, the role assignments dataset and the pinned parameter list (rebuild/lz-parameters.json).
    The map holds private values (names, prefixes, object IDs) and stays in the evidence package, never in
    the facts snapshot. Windows PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AvdRebuild.psm1')

$script:Statuses = @('found', 'derived', 'secret', 'deployTime', 'ambiguous', 'unexpressible', 'unknown')
$script:DefaultTags = @('workload', 'environment', 'managedBy', 'landingZone')

function Get-LzStatusList {
    <# .SYNOPSIS The statuses a parameter can have, in the order the summary counts them. #>
    return $script:Statuses
}

function Get-LzEntry {
    param([string]$Status, $Value = $null, [string[]]$Evidence = @(), [string]$Note = '')
    if ($script:Statuses -notcontains $Status) { throw "Unknown rebuild status '$Status'." }
    return [ordered]@{ status = $Status; value = $Value; evidence = @($Evidence | Where-Object { $_ }); note = $Note }
}

function Get-LzDefaultValue {
    <# .SYNOPSIS A parameter's default as a value when it is a plain literal, else $null. #>
    param($Parameter)
    $text = Get-RebuildValue $Parameter 'default'
    if ($null -eq $text) { return $null }
    $t = "$text".Trim()
    if ($t -match "^'([^']*)'$") { return $Matches[1] }
    if ($t -eq 'true') { return $true }
    if ($t -eq 'false') { return $false }
    if ($t -match '^-?\d+$') { return [int]$t }
    if ($t -eq '[]') { return , @() }
    if ($t -eq '{}') { return [ordered]@{} }
    if ($t -match '^\[\s*((\d+\s*)+)\]$') { return , @($Matches[1].Trim() -split '\s+' | ForEach-Object { [int]$_ }) }
    if ($t -match "^\[\s*(('[^']*'\s*)+)\]$") { return , @([regex]::Matches($Matches[1], "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }) }
    return $null
}

function Get-LzUnused {
    # A parameter the estate gives no reason to set: the landing zone default stands.
    param($Parameters, [string]$Name, [string]$Why)
    $p = ($Parameters | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
    $default = Get-LzDefaultValue $p
    $note = $Why
    if ($null -eq $default -and $null -ne (Get-RebuildValue $p 'default')) { $note = "$Why Landing zone default: $($p.default)" }
    return Get-LzEntry 'derived' $default @() $note
}

function Get-LzLower { param($Value) return "$Value".ToLowerInvariant() }

function Get-LzOne {
    <#
    .SYNOPSIS
        found/ambiguous/unknown from a list of candidate values: one distinct value is found, several
        are ambiguous, none is unknown.
    #>
    param([object[]]$Values, [string[]]$Evidence, [string]$What)
    $distinct = @{}
    $ordered = @()
    foreach ($v in @($Values | Where-Object { $null -ne $_ -and "$_" -ne '' })) {
        $k = ConvertTo-Json -InputObject $v -Compress -Depth 10
        if (-not $distinct.ContainsKey($k)) { $distinct[$k] = $true; $ordered += , $v }
    }
    if ($ordered.Count -eq 1) { return Get-LzEntry 'found' $ordered[0] $Evidence }
    if ($ordered.Count -gt 1) { return Get-LzEntry 'ambiguous' $null $Evidence "$($ordered.Count) different $What." }
    return Get-LzEntry 'unknown' $null $Evidence "No $What found."
}

function Get-LzRowsOf {
    param([hashtable]$Rows, [string]$Type)
    if ($Rows.ContainsKey($Type)) { return @($Rows[$Type] | Where-Object { $null -ne $_ }) }
    return @()
}

function Get-LzRestOf {
    # Items of a REST read, and whether any call for the given parents failed.
    param([hashtable]$Rest, [string]$Name, [string[]]$ParentIds)
    $items = @(); $failed = $false; $read = $false
    if ($Rest.ContainsKey($Name)) {
        $parents = @($ParentIds | ForEach-Object { Get-LzLower $_ })
        foreach ($r in @($Rest[$Name])) {
            if ($parents.Count -and $parents -notcontains (Get-LzLower $r.parentId)) { continue }
            $read = $true
            if ($r.status -eq 'failed') { $failed = $true }
            $items += @($r.items | Where-Object { $null -ne $_ })
        }
    }
    return @{ Items = $items; Failed = $failed; Read = $read }
}

function Get-LzRebuildMap {
    <#
    .SYNOPSIS
        Builds the rebuild map for every host pool in one subscription's evidence. Returns a list of
        @{ hostPool; parameters (ordered name -> entry); coverage (status -> count) }.
    #>
    param(
        [Parameter(Mandatory)] [hashtable]$Rows,
        [hashtable]$Rest = @{},
        [object[]]$RoleAssignments = @(),
        [Parameter(Mandatory)] $ParameterList
    )
    $params = @($ParameterList.parameters)
    $maps = @()
    foreach ($hp in (Get-LzRowsOf $Rows 'microsoft.desktopvirtualization/hostpools')) {
        $map = Get-LzHostPoolMap -HostPool $hp -Rows $Rows -Rest $Rest -RoleAssignments $RoleAssignments -Parameters $params
        $map.landingZoneCommit = "$(Get-RebuildValue $ParameterList 'landingZoneCommit' '')"
        $maps += , $map
    }
    return , $maps
}

function Get-LzHostPoolMap {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RoleAssignments', Justification = 'Read by the groupFor script block.')]
    param($HostPool, [hashtable]$Rows, [hashtable]$Rest, [object[]]$RoleAssignments, [object[]]$Parameters)
    $m = [ordered]@{}
    $hpId = Get-LzLower $HostPool.id

    # ---- What this host pool is made of ----
    $sessionHosts = @(Get-LzRowsOf $Rows 'microsoft.desktopvirtualization/hostpools/sessionhosts' | Where-Object { (Get-LzLower $_.id).StartsWith("$hpId/") })
    $vmIds = @($sessionHosts | ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'properties.resourceId') } | Where-Object { $_ })
    $vms = @(Get-LzRowsOf $Rows 'microsoft.compute/virtualmachines' | Where-Object { $vmIds -contains (Get-LzLower $_.id) })
    $extensions = @(Get-LzRowsOf $Rows 'microsoft.compute/virtualmachines/extensions' | Where-Object { $id = Get-LzLower $_.id; @($vmIds | Where-Object { $id.StartsWith("$_/") }).Count -gt 0 })
    $nicIds = @($vms | ForEach-Object { @(Get-RebuildValue $_ 'properties.networkProfile.networkInterfaces' @()) | ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'id') } })
    $nics = @(Get-LzRowsOf $Rows 'microsoft.network/networkinterfaces' | Where-Object { $nicIds -contains (Get-LzLower $_.id) })
    $hostSubnetIds = @($nics | ForEach-Object { @(Get-RebuildValue $_ 'properties.ipConfigurations' @()) | ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'properties.subnet.id') } } | Where-Object { $_ } | Sort-Object -Unique)
    $vnets = @(Get-LzRowsOf $Rows 'microsoft.network/virtualnetworks')
    $vnet = $null; $hostSubnets = @()
    foreach ($v in $vnets) {
        foreach ($s in @(Get-RebuildValue $v 'properties.subnets' @())) {
            if ($hostSubnetIds -contains (Get-LzLower $s.id)) { $vnet = $v; $hostSubnets += , $s }
        }
    }
    $vnetId = if ($vnet) { Get-LzLower $vnet.id } else { '' }
    $subnets = @(if ($vnet) { @(Get-RebuildValue $vnet 'properties.subnets' @()) })
    $appGroups = @(Get-LzRowsOf $Rows 'microsoft.desktopvirtualization/applicationgroups' | Where-Object { (Get-LzLower (Get-RebuildValue $_ 'properties.hostPoolArmPath')) -eq $hpId })
    $plans = @(Get-LzRowsOf $Rows 'microsoft.desktopvirtualization/scalingplans' | Where-Object {
            @(Get-RebuildValue $_ 'properties.hostPoolReferences' @() | Where-Object { (Get-LzLower (Get-RebuildValue $_ 'hostPoolArmPath')) -eq $hpId }).Count -gt 0 })
    $pes = @(Get-LzRowsOf $Rows 'microsoft.network/privateendpoints')
    $peTargets = { param($pe) @(Get-RebuildValue $pe 'properties.privateLinkServiceConnections' @()) + @(Get-RebuildValue $pe 'properties.manualPrivateLinkServiceConnections' @()) |
            ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'properties.privateLinkServiceId') } }

    # Profile storage: where the landing zone's Run Command points FSLogix, else the one FileStorage account.
    $runCommands = Get-LzRestOf $Rest 'run-commands' $vmIds
    $fslogix = @($runCommands.Items | Where-Object { $_.name -eq 'Configure-FSLogix' })
    $runParam = { param($name) @($fslogix | ForEach-Object { @(Get-RebuildValue $_ 'properties.parameters' @()) | Where-Object { $_.name -eq $name } | ForEach-Object { $_.value } }) }
    $unc = @(& $runParam 'ProfileShareUncPath' | Sort-Object -Unique)
    $accounts = @(Get-LzRowsOf $Rows 'microsoft.storage/storageaccounts')
    $storage = $null; $shareName = ''; $storageEvidence = ''
    if ($unc.Count -eq 1 -and "$($unc[0])" -match '^\\\\([^.\\]+)\.[^\\]+\\([^\\]+)') {
        $acct = $Matches[1]; $shareName = $Matches[2]
        $storage = ($accounts | Where-Object { $_.name -eq $acct } | Select-Object -First 1)
        $storageEvidence = 'rest/run-commands Configure-FSLogix ProfileShareUncPath'
    } else {
        $fileStorage = @($accounts | Where-Object { (Get-RebuildValue $_ 'kind') -eq 'FileStorage' })
        if ($fileStorage.Count -eq 1) { $storage = $fileStorage[0]; $storageEvidence = 'the only FileStorage account' }
    }
    $storageId = if ($storage) { Get-LzLower $storage.id } else { '' }

    # Log Analytics: the workspace the hosts' data collection rule sends to, else the only one.
    $workspaces = @(Get-LzRowsOf $Rows 'microsoft.operationalinsights/workspaces')
    $dcrIds = @(Get-LzRowsOf $Rows 'microsoft.insights/datacollectionruleassociations' | Where-Object { $id = Get-LzLower $_.id; @($vmIds | Where-Object { $id.StartsWith("$_/") }).Count -gt 0 } |
            ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'properties.dataCollectionRuleId') })
    $lawIds = @(Get-LzRowsOf $Rows 'microsoft.insights/datacollectionrules' | Where-Object { $dcrIds -contains (Get-LzLower $_.id) } |
            ForEach-Object { @(Get-RebuildValue $_ 'properties.destinations.logAnalytics' @()) | ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'workspaceResourceId') } } | Sort-Object -Unique)
    $law = $null
    if ($lawIds.Count -eq 1) { $law = ($workspaces | Where-Object { (Get-LzLower $_.id) -eq $lawIds[0] } | Select-Object -First 1) }
    elseif ($workspaces.Count -eq 1) { $law = $workspaces[0] }
    $lawId = if ($law) { Get-LzLower $law.id } else { '' }

    # ---- Core ----
    if ("$($HostPool.name)" -match '^vdpool-([a-z0-9]{2,8})-(dev|test|prod)$') {
        $m.namePrefix = Get-LzEntry 'derived' $Matches[1] @($HostPool.id) 'From the landing zone host pool name vdpool-<prefix>-<environment>.'
        $m.environmentName = Get-LzEntry 'derived' $Matches[2] @($HostPool.id) 'From the host pool name.'
    } else {
        $m.namePrefix = Get-LzEntry 'ambiguous' $null @($HostPool.id) "Host pool name doesn't follow the landing zone pattern; a rebuild needs a prefix chosen."
        $m.environmentName = Get-LzEntry 'ambiguous' $null @($HostPool.id) "Host pool name doesn't follow the landing zone pattern."
    }
    $hpLocation = Get-RebuildValue $HostPool 'location'
    $m.location = if ($hpLocation) { Get-LzEntry 'found' $hpLocation @($HostPool.id) } else { Get-LzEntry 'unknown' $null @() 'The host pool row has no location.' }
    $extraTags = [ordered]@{}
    $hpTags = Get-RebuildValue $HostPool 'tags'
    if ($hpTags) { foreach ($p in $hpTags.PSObject.Properties) { if ($script:DefaultTags -notcontains $p.Name) { $extraTags[$p.Name] = $p.Value } } }
    $m.tags = Get-LzEntry 'found' $extraTags @($HostPool.id) 'Host pool tags without the four the landing zone adds.'

    # ---- Identity ----
    $groupFor = {
        param([string]$Role, [string[]]$Scopes)
        $hits = @($RoleAssignments | Where-Object { "$(Get-RebuildValue $_ 'RoleDefinitionName')" -eq $Role -and $Scopes -contains (Get-LzLower (Get-RebuildValue $_ 'Scope')) })
        $groups = @($hits | Where-Object { (Get-RebuildValue $_ 'ObjectType') -eq 'Group' } | ForEach-Object { Get-RebuildValue $_ 'ObjectId' } | Sort-Object -Unique)
        if ($groups.Count -eq 1) { return Get-LzEntry 'found' $groups[0] @("role-assignments: $Role") }
        if ($groups.Count -gt 1) { return Get-LzEntry 'ambiguous' $null @("role-assignments: $Role") "$($groups.Count) groups hold $Role; the landing zone takes one." }
        if ($hits.Count -gt 0) { return Get-LzEntry 'unexpressible' $null @("role-assignments: $Role") "$Role is assigned to users or service principals, not a group." }
        return Get-LzEntry 'unknown' $null @() "No $Role assignment found at the expected scope."
    }
    $m.avdUsersGroupObjectId = & $groupFor 'Desktop Virtualization User' @($appGroups | ForEach-Object { Get-LzLower $_.id })
    $hostRgs = @($vms | ForEach-Object { ($_.id -split '/')[0..4] -join '/' } | ForEach-Object { Get-LzLower $_ } | Sort-Object -Unique)
    $m.avdAdminsGroupObjectId = & $groupFor 'Virtual Machine Administrator Login' (@($hostRgs) + @($vmIds))
    $m.avdServicePrincipalObjectId = Get-LzEntry 'deployTime' $null @() 'The tenant''s Azure Virtual Desktop service principal; deploy.sh looks it up.'
    $join = @($extensions | ForEach-Object { Get-RebuildValue $_ 'properties.type' })
    if ($join -contains 'JsonADDomainExtension') {
        $m.enrollInIntune = Get-LzEntry 'unexpressible' $null @('microsoft.compute/virtualmachines/extensions') 'Session hosts join AD DS; the landing zone joins Entra ID only.'
    } else {
        $aad = @($extensions | Where-Object { (Get-RebuildValue $_ 'properties.type') -eq 'AADLoginForWindows' })
        if ($aad.Count -eq 0) { $m.enrollInIntune = Get-LzEntry 'unknown' $null @() 'No Entra join extension on the session hosts.' }
        else { $m.enrollInIntune = Get-LzOne @($aad | ForEach-Object { $null -ne (Get-RebuildValue $_ 'properties.settings.mdmId') }) @('AADLoginForWindows settings.mdmId') 'Intune enrollment settings' }
    }

    # ---- Connectivity ----
    $natSubnets = @($hostSubnets | Where-Object { Get-RebuildValue $_ 'properties.natGateway.id' })
    $routeTableIds = @($hostSubnets | ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'properties.routeTable.id') } | Where-Object { $_ })
    $defaultRoutes = @(Get-LzRowsOf $Rows 'microsoft.network/routetables' | Where-Object { $routeTableIds -contains (Get-LzLower $_.id) } | ForEach-Object {
            @(Get-RebuildValue $_ 'properties.routes' @()) | Where-Object { (Get-RebuildValue $_ 'properties.addressPrefix') -eq '0.0.0.0/0' -and (Get-RebuildValue $_ 'properties.nextHopType') -eq 'VirtualAppliance' } })
    $peerings = @(if ($vnet) { @(Get-RebuildValue $vnet 'properties.virtualNetworkPeerings' @()) })
    $mode = ''
    if (-not $vnet) { $m.connectivityMode = Get-LzEntry 'unknown' $null @() "The session hosts' subnet wasn't found." }
    elseif ($natSubnets.Count -gt 0 -and $natSubnets.Count -eq $hostSubnets.Count) { $mode = 'Standalone'; $m.connectivityMode = Get-LzEntry 'derived' 'Standalone' @($vnet.id) 'NAT Gateway on the session host subnet.' }
    elseif ($defaultRoutes.Count -gt 0 -and $peerings.Count -gt 0) { $mode = 'HubPeered'; $m.connectivityMode = Get-LzEntry 'derived' 'HubPeered' @($vnet.id) 'Default route to a virtual appliance and a VNet peering.' }
    else { $m.connectivityMode = Get-LzEntry 'unexpressible' $null @($vnet.id) 'Egress is neither a NAT Gateway nor a peered hub firewall.' }

    if ($vnet) {
        $space = @(Get-RebuildValue $vnet 'properties.addressSpace.addressPrefixes' @())
        $m.spokeAddressPrefix = if ($space.Count -eq 1) { Get-LzEntry 'found' $space[0] @($vnet.id) } else { Get-LzEntry 'unexpressible' $null @($vnet.id) "The VNet has $($space.Count) address prefixes; the landing zone takes one." }
        $m.sessionHostSubnetPrefix = Get-LzOne @($hostSubnets | ForEach-Object { Get-RebuildValue $_ 'properties.addressPrefix' }) @($hostSubnetIds) 'session host subnets'
        $peSubnetIds = @($pes | ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'properties.subnet.id') } | Where-Object { $_.StartsWith("$vnetId/") } | Sort-Object -Unique)
        $peSubnets = @($subnets | Where-Object { $peSubnetIds -contains (Get-LzLower $_.id) })
        $m.privateEndpointSubnetPrefix = if ($peSubnets.Count -eq 0) { Get-LzEntry 'unexpressible' $null @($vnet.id) 'No private endpoints in the spoke; the landing zone always has them.' }
        else { Get-LzOne @($peSubnets | ForEach-Object { Get-RebuildValue $_ 'properties.addressPrefix' }) @($peSubnetIds) 'private endpoint subnets' }
        $aci = @($subnets | Where-Object { @(Get-RebuildValue $_ 'properties.delegations' @() | Where-Object { (Get-RebuildValue $_ 'properties.serviceName') -eq 'Microsoft.ContainerInstance/containerGroups' }).Count -gt 0 })
        if ($aci.Count -gt 0) {
            $m.deployImageBuildSubnets = Get-LzEntry 'derived' $true @($aci[0].id) 'A subnet delegated to Container Instances.'
            $build = @($subnets | Where-Object { $_.name -eq 'snet-image-build' })
            $m.imageBuildSubnetPrefix = if ($build.Count -eq 1) { Get-LzEntry 'found' (Get-RebuildValue $build[0] 'properties.addressPrefix') @($build[0].id) } else { Get-LzEntry 'ambiguous' $null @() 'The image build VM subnet has no landing zone name.' }
            $m.imageBuildAciSubnetPrefix = Get-LzOne @($aci | ForEach-Object { Get-RebuildValue $_ 'properties.addressPrefix' }) @($aci | ForEach-Object { $_.id }) 'delegated subnets'
        } else {
            $m.deployImageBuildSubnets = Get-LzEntry 'derived' $false @($vnet.id) 'No subnet delegated to Container Instances.'
            $m.imageBuildSubnetPrefix = Get-LzUnused $Parameters 'imageBuildSubnetPrefix' 'No image build subnets.'
            $m.imageBuildAciSubnetPrefix = Get-LzUnused $Parameters 'imageBuildAciSubnetPrefix' 'No image build subnets.'
        }
        $m.dnsServers = Get-LzEntry 'found' @(Get-RebuildValue $vnet 'properties.dhcpOptions.dnsServers' @()) @($vnet.id)
    } else {
        foreach ($n in 'spokeAddressPrefix', 'sessionHostSubnetPrefix', 'privateEndpointSubnetPrefix', 'deployImageBuildSubnets', 'imageBuildSubnetPrefix', 'imageBuildAciSubnetPrefix', 'dnsServers') {
            $m[$n] = Get-LzEntry 'unknown' $null @() "The session hosts' VNet wasn't found."
        }
    }

    if ($mode -eq 'HubPeered') {
        $remote = @($peerings | ForEach-Object { Get-RebuildValue $_ 'properties.remoteVirtualNetwork.id' } | Sort-Object -Unique)
        $m.hubVnetResourceId = Get-LzOne $remote @($vnet.id) 'peered VNets'
        $hub = $null
        if ($remote.Count -eq 1) { $hub = ($vnets | Where-Object { (Get-LzLower $_.id) -eq (Get-LzLower $remote[0]) } | Select-Object -First 1) }
        if ($hub) {
            $back = @(Get-RebuildValue $hub 'properties.virtualNetworkPeerings' @() | Where-Object { (Get-LzLower (Get-RebuildValue $_ 'properties.remoteVirtualNetwork.id')) -eq $vnetId })
            $m.createHubToSpokePeering = Get-LzEntry 'found' ($back.Count -gt 0) @($hub.id)
        } else { $m.createHubToSpokePeering = Get-LzEntry 'unknown' $null @() 'The hub VNet is outside what this identity reads.' }
        $m.hubFirewallPrivateIp = Get-LzOne @($defaultRoutes | ForEach-Object { Get-RebuildValue $_ 'properties.nextHopIpAddress' }) @($routeTableIds) 'default route next hops'
    } else {
        $m.hubVnetResourceId = Get-LzUnused $Parameters 'hubVnetResourceId' 'Not hub-peered.'
        $m.createHubToSpokePeering = Get-LzUnused $Parameters 'createHubToSpokePeering' 'Not hub-peered.'
        $m.hubFirewallPrivateIp = Get-LzUnused $Parameters 'hubFirewallPrivateIp' 'Not hub-peered.'
    }

    $ourPes = @($pes | Where-Object { $t = @(& $peTargets $_); ($storageId -and $t -contains $storageId) -or $t -contains $hpId -or @($t | Where-Object { $_ -like '*/microsoft.keyvault/vaults/*' }).Count -gt 0 })
    $zoneGroups = Get-LzRestOf $Rest 'private-dns-zone-groups' @($ourPes | ForEach-Object { $_.id })
    $zones = @($zoneGroups.Items | ForEach-Object { @(Get-RebuildValue $_ 'properties.privateDnsZoneConfigs' @()) | ForEach-Object { Get-RebuildValue $_ 'properties.privateDnsZoneId' } } | Where-Object { $_ } | Sort-Object -Unique)
    if ($zoneGroups.Failed -or $zones.Count -eq 0) {
        $m.centralPrivateDnsZoneResourceIds = Get-LzEntry 'unknown' $null @() 'No private DNS zone groups read for the private endpoints.'
    } else {
        $vnetRg = if ($vnet) { (Get-LzLower $vnet.id) -split '/' | Select-Object -First 5 } else { @() }
        $local = @($zones | Where-Object { ((Get-LzLower $_) -split '/' | Select-Object -First 5) -join '/' -eq ($vnetRg -join '/') })
        if ($local.Count -eq $zones.Count) { $m.centralPrivateDnsZoneResourceIds = Get-LzEntry 'derived' ([ordered]@{}) @($zones) 'Zones are in the spoke''s network resource group (created by the landing zone).' }
        else {
            $central = [ordered]@{}
            foreach ($z in $zones) {
                $zn = Get-LzLower (($z -split '/')[-1])
                if ($zn -eq 'privatelink.file.core.windows.net') { $central.file = $z }
                elseif ($zn -eq 'privatelink.vaultcore.azure.net') { $central.keyVault = $z }
                elseif ($zn -eq 'privatelink.wvd.microsoft.com') { $central.avd = $z }
            }
            $m.centralPrivateDnsZoneResourceIds = Get-LzEntry 'derived' $central @($zones) 'Zones live outside the spoke (central DNS).'
        }
    }
    $m.enableAvdPrivateLink = Get-LzEntry 'found' (@($pes | Where-Object { @(& $peTargets $_) -contains $hpId }).Count -gt 0) @($HostPool.id) 'A private endpoint targets the host pool.'

    # ---- Session hosts ----
    $m.sessionHostCount = Get-LzEntry 'found' $sessionHosts.Count @("$($HostPool.id)/sessionhosts")
    $m.sessionHostVmSize = Get-LzOne @($vms | ForEach-Object { Get-RebuildValue $_ 'properties.hardwareProfile.vmSize' }) @($vmIds) 'VM sizes'
    $prefixes = @($vms | ForEach-Object { if ("$($_.name)" -match '^(.+)-\d{3}$') { $Matches[1] } else { "$($_.name)" } })
    $m.sessionHostNamePrefix = Get-LzOne $prefixes @($vmIds) 'host name prefixes'
    if ($m.sessionHostNamePrefix.status -eq 'found' -and @($vms | Where-Object { "$($_.name)" -notmatch '-\d{3}$' }).Count -gt 0) {
        $m.sessionHostNamePrefix = Get-LzEntry 'ambiguous' $null @($vmIds) 'Host names don''t end in the landing zone''s -NNN index.'
    }
    if ($vms.Count -eq 0) { $m.availabilityZones = Get-LzEntry 'unknown' $null @() 'No session host VMs found.' }
    else { $m.availabilityZones = Get-LzEntry 'found' (@($vms | ForEach-Object { @(Get-RebuildValue $_ 'zones' @()) } | ForEach-Object { [int]"$_" } | Sort-Object -Unique)) @($vmIds) }
    $images = @($vms | ForEach-Object {
            $ref = Get-RebuildValue $_ 'properties.storageProfile.imageReference'
            $gallery = Get-RebuildValue $ref 'id'
            if ($gallery) { [ordered]@{ id = $gallery } }
            elseif ($ref) { [ordered]@{ publisher = Get-RebuildValue $ref 'publisher'; offer = Get-RebuildValue $ref 'offer'; sku = Get-RebuildValue $ref 'sku'; version = Get-RebuildValue $ref 'version' } }
        })
    $m.sessionHostImage = Get-LzOne $images @($vmIds) 'images'
    $m.maxSessionLimit = Get-LzEntry 'found' (Get-RebuildValue $HostPool 'properties.maxSessionLimit') @($HostPool.id)
    $m.encryptionAtHost = Get-LzOne @($vms | ForEach-Object { [bool](Get-RebuildValue $_ 'properties.securityProfile.encryptionAtHost' $false) }) @($vmIds) 'encryption at host settings'
    $m.localAdminUsername = Get-LzOne @($vms | ForEach-Object { Get-RebuildValue $_ 'properties.osProfile.adminUsername' }) @($vmIds) 'admin user names'
    $m.localAdminPassword = Get-LzEntry 'secret' $null @() 'Never collected; a rebuild generates a new one (spec section 5.3).'
    $m.rdpProperties = Get-LzEntry 'found' (Get-RebuildValue $HostPool 'properties.customRdpProperty' '') @($HostPool.id)
    $m.validationEnvironment = Get-LzEntry 'found' ([bool](Get-RebuildValue $HostPool 'properties.validationEnvironment' $false)) @($HostPool.id)

    # ---- Profiles ----
    if ($storage) {
        $m.profileStorageSku = Get-LzEntry 'found' (Get-RebuildValue $storage 'sku.name') @($storage.id, $storageEvidence)
        $shares = Get-LzRestOf $Rest 'file-shares' @($storage.id)
        $share = @($shares.Items | Where-Object { -not $shareName -or $_.name -eq $shareName })
        if ($shares.Failed) { $m.profileShareQuotaGiB = Get-LzEntry 'unknown' $null @() 'The file share read failed.' }
        else { $m.profileShareQuotaGiB = Get-LzOne @($share | ForEach-Object { Get-RebuildValue $_ 'properties.shareQuota' }) @("$($storage.id)/fileServices/default/shares") 'profile share quotas' }
        $protected = @(Get-LzRowsOf $Rows 'microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers/protecteditems' | Where-Object { (Get-LzLower (Get-RebuildValue $_ 'properties.sourceResourceId')) -eq $storageId })
        $m.enableProfileBackup = Get-LzEntry 'derived' ($protected.Count -gt 0) @($storage.id) 'A backup protected item on the profile storage account.'
        if ($protected.Count -gt 0) {
            $policyIds = @($protected | ForEach-Object { Get-LzLower (Get-RebuildValue $_ 'properties.policyId') })
            $policies = Get-LzRestOf $Rest 'backup-policies' @()
            $m.profileBackupRetentionDays = Get-LzOne @($policies.Items | Where-Object { $policyIds -contains (Get-LzLower $_.id) } | ForEach-Object { Get-RebuildValue $_ 'properties.retentionPolicy.dailySchedule.retentionDuration.count' }) @($policyIds) 'backup retention periods'
        } else { $m.profileBackupRetentionDays = Get-LzUnused $Parameters 'profileBackupRetentionDays' 'No backup.' }
    } else {
        foreach ($n in 'profileStorageSku', 'profileShareQuotaGiB', 'enableProfileBackup', 'profileBackupRetentionDays') { $m[$n] = Get-LzEntry 'unknown' $null @() 'The profile storage account wasn''t identified.' }
    }
    $size = @(& $runParam 'ProfileSizeMiB' | ForEach-Object { [int]"$_" })
    $m.fslogixProfileSizeMiB = if ($size.Count) { Get-LzOne $size @('rest/run-commands Configure-FSLogix') 'FSLogix profile sizes' }
    else { Get-LzEntry 'unknown' $null @() 'In-guest setting; no landing zone Run Command found (spec section 6).' }

    # ---- Scaling ----
    $m.startVmOnConnect = Get-LzEntry 'found' ([bool](Get-RebuildValue $HostPool 'properties.startVMOnConnect' $false)) @($HostPool.id)
    $m.scalingTimeZone = if ($plans.Count -eq 0) { Get-LzEntry 'unexpressible' $null @() 'No scaling plan; the landing zone always deploys one.' }
    else { Get-LzOne @($plans | ForEach-Object { Get-RebuildValue $_ 'properties.timeZone' }) @($plans | ForEach-Object { $_.id }) 'scaling plan time zones' }

    # ---- Operations ----
    $m.logRetentionDays = if ($law) { Get-LzEntry 'found' (Get-RebuildValue $law 'properties.retentionInDays') @($law.id) } else { Get-LzEntry 'ambiguous' $null @() 'More than one Log Analytics workspace and no data collection rule to pick one.' }
    $groups = @(Get-LzRowsOf $Rows 'microsoft.insights/actiongroups' | Where-Object { @(Get-RebuildValue $_ 'properties.emailReceivers' @()).Count -gt 0 })
    $emails = @($groups | ForEach-Object { @(Get-RebuildValue $_ 'properties.emailReceivers' @()) | ForEach-Object { Get-RebuildValue $_ 'emailAddress' } } | Where-Object { $_ } | Sort-Object -Unique)
    $m.alertEmailAddresses = Get-LzEntry $(if ($emails.Count) { 'found' } else { 'derived' }) ($emails) @($groups | ForEach-Object { $_.id })
    $budgets = Get-LzRestOf $Rest 'budgets' @()
    $monthly = @($budgets.Items | Where-Object { (Get-RebuildValue $_ 'properties.timeGrain') -eq 'Monthly' })
    if ($budgets.Failed -or -not $budgets.Read) {
        $m.monthlyBudgetAmount = Get-LzEntry 'unknown' $null @() 'Budgets were not read (Cost Management needs Reader on the subscription).'
        $m.budgetStartDate = Get-LzEntry 'unknown' $null @() 'Budgets were not read.'
    } elseif ($monthly.Count -eq 0) {
        $m.monthlyBudgetAmount = Get-LzEntry 'derived' 0 @() 'No monthly budget.'
        $m.budgetStartDate = Get-LzEntry 'derived' '' @() 'No monthly budget.'
    } else {
        $m.monthlyBudgetAmount = Get-LzOne @($monthly | ForEach-Object { [int](Get-RebuildValue $_ 'properties.amount') }) @($monthly | ForEach-Object { $_.id }) 'monthly budgets'
        $m.budgetStartDate = Get-LzOne @($monthly | ForEach-Object { "$(Get-RebuildValue $_ 'properties.timePeriod.startDate')".Substring(0, [Math]::Min(10, "$(Get-RebuildValue $_ 'properties.timePeriod.startDate')".Length)) }) @() 'budget start dates'
    }

    # ---- Auto shutdown ----
    $runbooks = @(Get-LzRowsOf $Rows 'microsoft.automation/automationaccounts/runbooks' | Where-Object { ($_.id -split '/')[-1] -eq 'Invoke-AvdPowerAction' })
    $m.enableAutoShutdown = Get-LzEntry 'derived' ($runbooks.Count -gt 0) @($runbooks | ForEach-Object { $_.id }) 'The Invoke-AvdPowerAction runbook.'
    $m.autoShutdownRunbookUri = Get-LzEntry 'deployTime' (@($runbooks | ForEach-Object { Get-RebuildValue $_ 'properties.publishContentLink.uri' } | Where-Object { $_ }) | Select-Object -First 1) @() 'deploy.sh pins it to the commit being deployed.'
    $flows = @(Get-LzRowsOf $Rows 'microsoft.logic/workflows' | ForEach-Object {
            $wf = $_
            $actions = Get-RebuildValue $wf 'properties.definition.actions'
            if ($actions) {
                foreach ($a in $actions.PSObject.Properties) {
                    $body = Get-RebuildValue $a.Value 'inputs.body.properties'
                    if ((Get-RebuildValue $body 'runbook.name') -eq 'Invoke-AvdPowerAction') {
                        [pscustomobject]@{ Workflow = $wf; Reason = Get-RebuildValue $body 'parameters.Reason'; Action = Get-RebuildValue $body 'parameters.Action' }
                    }
                }
            } })
    $schedule = @($flows | Where-Object { $_.Reason -eq 'schedule' })
    if ($schedule.Count -eq 1) {
        $triggers = Get-RebuildValue $schedule[0].Workflow 'properties.definition.triggers'
        $trigger = (@(if ($triggers) { $triggers.PSObject.Properties })  | ForEach-Object { $_.Value } | Where-Object { (Get-RebuildValue $_ 'type') -eq 'Recurrence' } | Select-Object -First 1)
        $hour = (Get-RebuildValue $trigger 'recurrence.schedule.hours' @()) | Select-Object -First 1; $minute = (Get-RebuildValue $trigger 'recurrence.schedule.minutes' @()) | Select-Object -First 1
        $ev = @($schedule[0].Workflow.id)
        $m.autoShutdownTime = Get-LzEntry 'found' ('{0:D2}:{1:D2}' -f [int]$hour, [int]$minute) $ev
        $m.autoShutdownDays = Get-LzEntry 'found' (@(Get-RebuildValue $trigger 'recurrence.schedule.weekDays' @())) $ev
        $m.autoShutdownTimeZone = Get-LzEntry 'found' (Get-RebuildValue $trigger 'recurrence.timeZone') $ev
        $m.autoShutdownScheduleAction = Get-LzEntry 'found' $schedule[0].Action $ev
    } elseif ($schedule.Count -gt 1) {
        foreach ($n in 'autoShutdownTime', 'autoShutdownDays', 'autoShutdownTimeZone', 'autoShutdownScheduleAction') { $m[$n] = Get-LzEntry 'ambiguous' $null @() 'More than one shutdown schedule.' }
    } else {
        $m.autoShutdownTime = Get-LzEntry 'derived' '' @() 'No scheduled stop.'
        foreach ($n in 'autoShutdownDays', 'autoShutdownScheduleAction') { $m[$n] = Get-LzUnused $Parameters $n 'No scheduled stop.' }
        $m.autoShutdownTimeZone = Get-LzEntry 'derived' $m.scalingTimeZone.value @() 'No scheduled stop; the landing zone default is the scaling time zone.'
    }
    $budgetFlow = @($flows | Where-Object { $_.Reason -eq 'budget' })
    $budgetTrigger = @($monthly | ForEach-Object { $b = $_; $n = Get-RebuildValue $b 'properties.notifications'; if ($n) { $n.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { @(Get-RebuildValue $_ 'contactGroups' @()).Count -gt 0 } } })
    if ($budgetFlow.Count -eq 1) {
        $m.autoShutdownBudgetAction = Get-LzEntry 'found' $budgetFlow[0].Action @($budgetFlow[0].Workflow.id)
        $m.autoShutdownBudgetPercent = Get-LzOne @($budgetTrigger | ForEach-Object { Get-RebuildValue $_ 'threshold' }) @() 'budget shutdown thresholds'
    } elseif ($monthly.Count -gt 0) {
        $m.autoShutdownBudgetAction = Get-LzEntry 'derived' 'None' @() 'A budget with no shutdown trigger.'
        $m.autoShutdownBudgetPercent = Get-LzUnused $Parameters 'autoShutdownBudgetPercent' 'No budget trigger.'
    } else {
        $m.autoShutdownBudgetAction = Get-LzUnused $Parameters 'autoShutdownBudgetAction' 'No budget, so no budget trigger.'
        $m.autoShutdownBudgetPercent = Get-LzUnused $Parameters 'autoShutdownBudgetPercent' 'No budget trigger.'
    }

    # ---- Governance ----
    $pricing = @(Get-LzRowsOf $Rows 'microsoft.security/pricings' | Where-Object { @('VirtualMachines', 'StorageAccounts', 'KeyVaults') -contains $_.name })
    if ($pricing.Count -eq 0) { $m.enableDefenderForCloud = Get-LzEntry 'unknown' $null @() 'Defender plans were not read.' }
    else { $m.enableDefenderForCloud = Get-LzOne @($pricing | ForEach-Object { (Get-RebuildValue $_ 'properties.pricingTier') -eq 'Standard' }) @($pricing | ForEach-Object { $_.id }) 'Defender plan tiers (Servers, Storage, Key Vault)' }
    $subDiag = Get-LzRestOf $Rest 'subscription-diagnostic-settings' @()
    if ($subDiag.Failed -or -not $subDiag.Read) { $m.deploySubscriptionSettings = Get-LzEntry 'unknown' $null @() 'Subscription diagnostic settings were not read.' }
    else { $m.deploySubscriptionSettings = Get-LzEntry 'derived' (@($subDiag.Items | Where-Object { $lawId -and (Get-LzLower (Get-RebuildValue $_ 'properties.workspaceId')) -eq $lawId }).Count -gt 0) @() 'The activity log goes to the landing zone workspace.' }
    $subScope = (Get-LzLower $HostPool.id) -split '/' | Select-Object -First 3
    $allowed = @(Get-LzRowsOf $Rows 'microsoft.authorization/policyassignments' | Where-Object {
            (Get-RebuildValue $_ 'properties.parameters.listOfAllowedLocations') -and (Get-LzLower (Get-RebuildValue $_ 'properties.scope')) -eq ($subScope -join '/') })
    $m.enablePolicyGuardrails = Get-LzEntry 'derived' ($allowed.Count -gt 0) @($allowed | ForEach-Object { $_.id }) 'An allowed-locations assignment on the subscription.'
    $m.allowedLocations = if ($allowed.Count) { Get-LzOne @($allowed | ForEach-Object { , @(Get-RebuildValue $_ 'properties.parameters.listOfAllowedLocations.value' @()) }) @($allowed | ForEach-Object { $_.id }) 'allowed location lists' }
    else { Get-LzEntry 'derived' (@($hpLocation | Where-Object { $_ })) @() 'No guardrail; the landing zone default is the deployment region.' }

    # ---- In parameter-file order, with nothing missing ----
    $ordered = [ordered]@{}
    $coverage = [ordered]@{}
    foreach ($s in $script:Statuses) { $coverage[$s] = 0 }
    foreach ($p in $Parameters) {
        $entry = if ($m.Contains($p.name)) { $m[$p.name] } else { Get-LzEntry 'unknown' $null @() 'No rule for this parameter yet.' }
        $ordered[$p.name] = $entry
        $coverage[$entry.status]++
    }
    return [ordered]@{ hostPool = $HostPool.id; landingZoneCommit = ''; parameters = $ordered; coverage = $coverage }
}

function Get-LzRoundTripResult {
    <#
    .SYNOPSIS
        Compares one host pool's rebuild map with the values a deployment used (spec section 11). Returns
        @{ Rows = parameter, status, check; Passed }. Rows never carry values, so they can be shared.
        Passed: no parameter is ambiguous, unexpressible or unknown, and every expected value matches.
    #>
    param([Parameter(Mandatory)] $Map, [Parameter(Mandatory)] [System.Collections.IDictionary]$Expected)
    $parameters = Get-RebuildValue $Map 'parameters'
    $entries = if ($parameters -is [System.Collections.IDictionary]) { @($parameters.Keys | ForEach-Object { @{ Name = $_; Entry = $parameters[$_] } }) }
    else { @($parameters.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Entry = $_.Value } }) }
    $rows = @(); $passed = $true
    foreach ($e in $entries) {
        $status = "$(Get-RebuildValue $e.Entry 'status')"
        if (@('ambiguous', 'unexpressible', 'unknown') -contains $status) { $passed = $false }
        $check = ''
        if ($Expected.Contains($e.Name)) {
            # Read the value directly, never through a function or an if-expression: both unroll an empty array to null.
            $value = $e.Entry.value
            if ($e.Entry -is [System.Collections.IDictionary]) { $value = $e.Entry['value'] }
            $got = ConvertTo-Json -InputObject $value -Compress -Depth 10
            $want = ConvertTo-Json -InputObject $Expected[$e.Name] -Compress -Depth 10
            $check = if ($got -eq $want) { 'match' } else { 'NO MATCH' }
            if ($check -ne 'match') { $passed = $false }
        }
        $rows += [pscustomobject]@{ Parameter = $e.Name; Status = $status; Check = $check }
    }
    foreach ($k in $Expected.Keys) {
        if (@($entries | Where-Object { $_.Name -eq $k }).Count -eq 0) { $rows += [pscustomobject]@{ Parameter = $k; Status = 'missing'; Check = 'NO MATCH' }; $passed = $false }
    }
    return @{ Rows = $rows; Passed = $passed }
}

Export-ModuleMember -Function Get-LzStatusList, Get-LzRebuildMap, Get-LzDefaultValue, Get-LzRoundTripResult
