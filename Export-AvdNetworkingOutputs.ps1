# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware, ServiceNow or Microsoft.
#requires -Version 5.1
<#
.SYNOPSIS
Exports C31 (avd-networking-outputs/v1) from an avd-current-state collector package or Resource Graph rows.

.DESCRIPTION
Reads rebuild/resources/*.json from a collector package (or -Rows directly for offline tests) and emits
a redacted C31 avd-networking-outputs/v1 document for Azure Firewall, 3rd-party NVA, VPN, and ExpressRoute hubs.
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Package', Mandatory)]
    [string]$PackagePath,

    [Parameter(ParameterSetName = 'Rows', Mandatory)]
    [object[]]$Rows,

    [string]$HubVnetResourceId = '',

    [ValidateSet('commercial', 'usgov')]
    [string]$Cloud = 'commercial',

    [ValidateSet('dev', 'test', 'prod')]
    [string]$Environment = 'prod',

    [ValidateSet('lab', 'enterprise')]
    [string]$Profile = 'enterprise',

    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ObjProp {
    param([object]$Obj, [string]$Path, [object]$Default = $null)
    $cur = $Obj
    foreach ($part in $Path -split '\.') {
        if ($null -eq $cur) { return $Default }
        if ($cur -is [System.Collections.IDictionary]) {
            if ($cur.Contains($part)) { $cur = $cur[$part] } else { return $Default }
        } else {
            $p = $cur.PSObject.Properties[$part]
            if ($null -ne $p) { $cur = $p.Value } else { return $Default }
        }
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

if ($PSCmdlet.ParameterSetName -eq 'Package') {
    $resDir = Join-Path $PackagePath 'rebuild/resources'
    if (-not (Test-Path -LiteralPath $resDir)) {
        throw "Rebuild resources directory not found: $resDir"
    }
    $loaded = [System.Collections.Generic.List[object]]::new()
    foreach ($f in Get-ChildItem -Path $resDir -Filter '*.json' -File) {
        $items = Get-Content -Raw -Path $f.FullName | ConvertFrom-Json
        foreach ($item in @($items)) {
            if ($null -ne $item) { $loaded.Add($item) }
        }
    }
    $Rows = $loaded.ToArray()
}

$byType = @{}
foreach ($r in @($Rows)) {
    $t = ([string](Get-ObjProp $r 'type' '')).ToLowerInvariant()
    if (-not $t) { continue }
    if (-not $byType.ContainsKey($t)) { $byType[$t] = [System.Collections.Generic.List[object]]::new() }
    $byType[$t].Add($r)
}

function Get-RowsByType {
    param([string]$Type)
    $k = $Type.ToLowerInvariant()
    if ($byType.ContainsKey($k)) { return @($byType[$k]) }
    return @()
}

$vnets = Get-RowsByType 'microsoft.network/virtualnetworks'
$hubVnet = $null
if (-not [string]::IsNullOrWhiteSpace($HubVnetResourceId)) {
    $hubVnet = $vnets | Where-Object { ([string]$_.id).ToLowerInvariant() -eq $HubVnetResourceId.ToLowerInvariant() } | Select-Object -First 1
}
if ($null -eq $hubVnet) {
    $hubVnet = $vnets | Where-Object {
        $subs = @(Get-ObjProp $_ 'properties.subnets' @())
        @($subs | Where-Object { $_.name -in @('AzureFirewallSubnet', 'GatewaySubnet', 'snet-nva-untrusted', 'snet-nva-trusted') }).Count -gt 0
    } | Select-Object -First 1
}
if ($null -eq $hubVnet -and -not [string]::IsNullOrWhiteSpace($HubVnetResourceId)) {
    $hubId = $HubVnetResourceId
    $hubLoc = 'eastus2'
    $hubRg = ''
    if ($hubId -match '/resourceGroups/([^/]+)/') { $hubRg = $Matches[1] }
} elseif ($null -ne $hubVnet) {
    $hubId = [string]$hubVnet.id
    $hubLoc = [string](Get-ObjProp $hubVnet 'location' 'eastus2')
    $hubRg = [string](Get-ObjProp $hubVnet 'resourceGroup' '')
    if (-not $hubRg -and $hubId -match '/resourceGroups/([^/]+)/') { $hubRg = $Matches[1] }
} else {
    throw 'No hub virtual network found in collected rows; pass -HubVnetResourceId explicitly.'
}

$hubIdLower = $hubId.ToLowerInvariant()

# Firewall / NVA detection
$fwMode = 'none'
$fwIp = ''
$azFirewalls = Get-RowsByType 'microsoft.network/azurefirewalls'
foreach ($fw in $azFirewalls) {
    $ipConfs = @(Get-ObjProp $fw 'properties.ipConfigurations' @())
    $inHub = @($ipConfs | Where-Object { ([string](Get-ObjProp $_ 'properties.subnet.id' '')).ToLowerInvariant().StartsWith("$hubIdLower/subnets/") }).Count -gt 0
    if ($inHub -or $azFirewalls.Count -eq 1) {
        $ip = [string](Get-ObjProp $ipConfs[0] 'properties.privateIPAddress' '')
        if ($ip) {
            $fwMode = 'azure-firewall'
            $fwIp = $ip
            break
        }
    }
}

if ($fwMode -eq 'none') {
    $routeTables = Get-RowsByType 'microsoft.network/routetables'
    foreach ($rt in $routeTables) {
        $routes = @(Get-ObjProp $rt 'properties.routes' @())
        $vaRoute = $routes | Where-Object {
            (Get-ObjProp $_ 'properties.addressPrefix' '') -eq '0.0.0.0/0' -and
            (Get-ObjProp $_ 'properties.nextHopType' '') -eq 'VirtualAppliance' -and
            -not [string]::IsNullOrWhiteSpace([string](Get-ObjProp $_ 'properties.nextHopIpAddress' ''))
        } | Select-Object -First 1
        if ($null -ne $vaRoute) {
            $fwMode = 'nva'
            $fwIp = [string](Get-ObjProp $vaRoute 'properties.nextHopIpAddress' '')
            break
        }
    }
}

# DNS servers
$dnsServers = @()
if ($null -ne $hubVnet) {
    $dnsServers = @(Get-ObjProp $hubVnet 'properties.dhcpOptions.dnsServers' @() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

# Central Private DNS zones
$dnsZones = [ordered]@{
    file      = ''
    keyVault  = ''
    avd       = ''
    avdGlobal = ''
}
foreach ($z in (Get-RowsByType 'microsoft.network/privatednszones')) {
    $zName = ([string](Get-ObjProp $z 'name' '')).ToLowerInvariant()
    if ($zName -like 'privatelink.file.*' -and -not $dnsZones.file) { $dnsZones.file = [string]$z.id }
    elseif ($zName -like 'privatelink.vaultcore.*' -and -not $dnsZones.keyVault) { $dnsZones.keyVault = [string]$z.id }
    elseif ($zName -like 'privatelink.wvd.*' -and -not $dnsZones.avd) { $dnsZones.avd = [string]$z.id }
    elseif ($zName -like 'privatelink-global.wvd.*' -and -not $dnsZones.avdGlobal) { $dnsZones.avdGlobal = [string]$z.id }
}

# Bastion
$bastionId = ''
foreach ($b in (Get-RowsByType 'microsoft.network/bastionhosts')) {
    $ipConfs = @(Get-ObjProp $b 'properties.ipConfigurations' @())
    $inHub = @($ipConfs | Where-Object { ([string](Get-ObjProp $_ 'properties.subnet.id' '')).ToLowerInvariant().StartsWith("$hubIdLower/subnets/") }).Count -gt 0
    if ($inHub) { $bastionId = [string]$b.id; break }
}

# VPN & ExpressRoute Gateways
$vpnGwId = ''
$erGwId = ''
foreach ($gw in (Get-RowsByType 'microsoft.network/virtualnetworkgateways')) {
    $ipConfs = @(Get-ObjProp $gw 'properties.ipConfigurations' @())
    $inHub = @($ipConfs | Where-Object { ([string](Get-ObjProp $_ 'properties.subnet.id' '')).ToLowerInvariant().StartsWith("$hubIdLower/subnets/") }).Count -gt 0
    if (-not $inHub) { continue }
    $gwType = [string](Get-ObjProp $gw 'properties.gatewayType' '')
    if ($gwType -eq 'Vpn' -and -not $vpnGwId) { $vpnGwId = [string]$gw.id }
    elseif ($gwType -eq 'ExpressRoute' -and -not $erGwId) { $erGwId = [string]$gw.id }
}
$primaryGwId = if ($vpnGwId) { $vpnGwId } else { $erGwId }

$result = [ordered]@{
    schema                           = 'avd-networking-outputs/v1'
    cloud                            = $Cloud
    environment                      = $Environment
    location                         = $hubLoc
    profile                          = $Profile
    connectivityTopology             = 'hub-spoke'
    firewallMode                     = $fwMode
    resourceGroup                    = $hubRg
    hubVnetResourceId                = $hubId
    hubFirewallPrivateIp             = $fwIp
    dnsServers                       = @($dnsServers)
    centralPrivateDnsZoneResourceIds = $dnsZones
    bastionResourceId                = $bastionId
    gatewayResourceId                = $primaryGwId
    vpnGatewayResourceId             = $vpnGwId
    expressRouteGatewayResourceId    = $erGwId
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
}

$result
