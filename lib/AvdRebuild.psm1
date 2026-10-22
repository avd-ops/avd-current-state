<#
    Rebuild-fidelity reads for the collector (docs/rebuild-fidelity-spec.md).

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    Pure functions over data, so they test offline: the scope file, Resource Graph query text, the
    never-collect scrubber and its final scan, and the mapping from saved Resource Graph rows to the
    collector's existing dataset columns. The two Invoke- functions page through Resource Graph and REST
    through an invoker script block the caller supplies (Invoke-AzRestMethod in the collector, a fake in
    the tests); they never call Azure themselves. Windows PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest

$script:Tables = @('resources', 'resourcecontainers', 'desktopvirtualizationresources', 'insightsresources',
    'recoveryservicesresources', 'authorizationresources', 'policyresources', 'securityresources')

# Property names whose values are never written, even to the private package (spec section 5.2). The key
# stays, with a marker, so a rebuild knows a secret existed there and has to be recreated (section 5.3).
$script:SecretNames = @('token', 'registrationToken', 'primaryKey', 'secondaryKey', 'primaryConnectionString',
    'secondaryConnectionString', 'connectionString', 'accessKeys', 'protectedSettings', 'protectedParameters',
    'adminPassword', 'password', 'sasToken', 'sasUri', 'sasUrl', 'sharedKey', 'storageAccountKey',
    'secret', 'authorizationKey', 'serviceKey')

$script:SecretPatterns = [ordered]@{
    'signed URL'          = 'sig=[A-Za-z0-9%/+=]{16,}'
    'JWT'                 = 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
    'account key'         = '(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{86}==(?![A-Za-z0-9+/=])'
    'connection string'   = '(?i)(AccountKey|SharedAccessKey|SharedAccessSignature)='
}

function Get-RebuildValue {
    <#
    .SYNOPSIS
        StrictMode-safe read of a dotted path from a row (PSCustomObject or dictionary). ARM omits
        empty properties, so a missing segment returns the default instead of throwing.
    #>
    param($InputObject, [string]$Path, $Default = $null)
    $current = $InputObject
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $Default }
            $current = $current[$segment]
        } else {
            $prop = $current.PSObject.Properties[$segment]
            if ($null -eq $prop) { return $Default }
            $current = $prop.Value
        }
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Get-RebuildScope {
    <#
    .SYNOPSIS Reads and checks rebuild/scope.json: known tables, unique types, a REST path per read.
    #>
    param([Parameter(Mandatory)] [string]$Path)
    $scope = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($scope.schema -ne 'avd-current-state-rebuild-scope/v1') { throw "Unknown rebuild scope schema '$($scope.schema)'." }
    $seen = @{}
    foreach ($t in @($scope.resourceGraph)) {
        if ($script:Tables -notcontains $t.table) { throw "Unknown Resource Graph table '$($t.table)'." }
        if ($t.type -cne $t.type.ToLowerInvariant()) { throw "Resource type '$($t.type)' must be lowercase." }
        if ($seen.ContainsKey($t.type)) { throw "Resource type '$($t.type)' is listed twice." }
        if (@($t.serves | Where-Object { $_ }).Count -eq 0) { throw "Resource type '$($t.type)' serves nothing." }
        $seen[$t.type] = $true
    }
    foreach ($r in @($scope.rest)) {
        if ($r.path -notmatch '^\{id\}/') { throw "REST read '$($r.name)' must start at '{id}/'." }
        if ($r.apiVersion -notmatch '^\d{4}-\d{2}-\d{2}(-preview)?$') { throw "REST read '$($r.name)' has no API version." }
        foreach ($p in @($r.parentTypes)) {
            if ($p -ne 'subscription' -and -not $seen.ContainsKey($p)) { throw "REST read '$($r.name)' hangs off '$p', which the scope doesn't read." }
        }
    }
    return $scope
}

function Get-RebuildFileName {
    <#
    .SYNOPSIS microsoft.compute/virtualmachines/extensions -> microsoft.compute-virtualmachines-extensions.json
    #>
    param([Parameter(Mandatory)] [string]$Type)
    return ($Type.ToLowerInvariant() -replace '/', '-') + '.json'
}

function Get-RebuildQuery {
    <#
    .SYNOPSIS Resource Graph query for one type: whole objects, in a stable order.
    #>
    param([Parameter(Mandatory)] [string]$Table, [Parameter(Mandatory)] [string]$Type)
    if ($script:Tables -notcontains $Table) { throw "Unknown Resource Graph table '$Table'." }
    if ($Type -notmatch '^[a-z0-9./]+$') { throw "Unexpected resource type '$Type'." }
    return "$Table | where type =~ '$Type' | order by id asc"
}

function Get-RebuildRestPath {
    <#
    .SYNOPSIS Path of a REST read under one parent ID, with its API version.
    #>
    param([Parameter(Mandatory)] $Read, [Parameter(Mandatory)] [string]$ParentId)
    return ($Read.path -replace '\{id\}', $ParentId.TrimEnd('/')) + "?api-version=$($Read.apiVersion)"
}

function ConvertTo-RebuildSafeValue {
    # Recursive worker for ConvertTo-RebuildSafeObject; $Counter is a one-element array it increments.
    param($Node, [int[]]$Counter)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) {
        if ($Node -match $script:SecretPatterns['signed URL']) { $Counter[0]++; return '[removed: signed URL]' }
        return $Node
    }
    if ($Node -is [System.ValueType]) { return $Node }
    # [pscustomobject] is an alias of [psobject], which -is matches for any wrapped value; test the real type.
    $isObject = $Node -is [System.Collections.IDictionary] -or $Node.GetType().FullName -eq 'System.Management.Automation.PSCustomObject'
    if (-not $isObject -and $Node -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Node) { $items.Add((ConvertTo-RebuildSafeValue -Node $item -Counter $Counter)) }
        return , $items.ToArray()
    }
    if ($isObject) {
        $names = @(if ($Node -is [System.Collections.IDictionary]) { $Node.Keys } else { $Node.PSObject.Properties | ForEach-Object { $_.Name } })
        $copy = [ordered]@{}
        foreach ($name in $names) {
            # Not an if-expression: its output would unroll a one-element array into a scalar.
            $value = $null
            if ($Node -is [System.Collections.IDictionary]) { $value = $Node[$name] } else { $value = $Node.PSObject.Properties[$name].Value }
            # A PSCustomObject stringifies to '', so emptiness is tested by type, not by "$value".
            $empty = $null -eq $value -or ($value -is [string] -and $value -eq '') -or ($value -is [array] -and $value.Count -eq 0)
            if ($script:SecretNames -contains "$name" -and -not $empty) {
                $Counter[0]++
                $copy["$name"] = '[removed]'
            } else {
                $copy["$name"] = ConvertTo-RebuildSafeValue -Node $value -Counter $Counter
            }
        }
        return [pscustomobject]$copy
    }
    return $Node
}

function ConvertTo-RebuildSafeObject {
    <#
    .SYNOPSIS
        Copies a row, replacing never-collect values with a marker (spec section 5.2). Returns
        @{ Object = <copy>; Removed = <count> }.
    #>
    param($InputObject)
    $counter = [int[]]@(0)
    $object = ConvertTo-RebuildSafeValue -Node $InputObject -Counter $counter
    return @{ Object = $object; Removed = $counter[0] }
}

function Get-RebuildSecretFinding {
    <#
    .SYNOPSIS The final scan: names of secret patterns found in text about to be written. Empty means clean.
    #>
    param([AllowEmptyString()] [string]$Text)
    $found = @()
    foreach ($k in $script:SecretPatterns.Keys) {
        if ($Text -match $script:SecretPatterns[$k]) { $found += $k }
    }
    return $found
}

function Invoke-RebuildGraphQuery {
    <#
    .SYNOPSIS
        Pages a Resource Graph query for one subscription. $Invoker takes a request body (hashtable) and
        returns @{ StatusCode; Content }. Stops on an error or an empty page (avd-landing-zone lesson 0008)
        and reports the full error (lesson 0012).
    #>
    param(
        [Parameter(Mandatory)] [string]$Query,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [scriptblock]$Invoker,
        [int]$MaxPages = 500
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    for ($page = 0; $page -lt $MaxPages; $page++) {
        $options = @{ '$top' = 1000; resultFormat = 'objectArray' }
        if ($skipToken) { $options['$skipToken'] = $skipToken }
        $body = @{ subscriptions = @($SubscriptionId); query = $Query; options = $options }
        $response = & $Invoker $body
        if ($null -eq $response -or [int]$response.StatusCode -ne 200) {
            $status = if ($response) { $response.StatusCode } else { 'none' }
            $content = if ($response) { $response.Content } else { '' }
            throw "Resource Graph query failed (HTTP $status): $content"
        }
        $result = $response.Content | ConvertFrom-Json
        $data = @(Get-RebuildValue $result 'data' @() | Where-Object { $null -ne $_ })
        foreach ($row in $data) { $rows.Add($row) }
        $skipToken = Get-RebuildValue $result '$skipToken'
        if ($data.Count -eq 0 -or -not $skipToken) { break }
    }
    return $rows.ToArray()
}

function Invoke-RebuildRestRead {
    <#
    .SYNOPSIS
        GET one REST path and follow nextLink. $Invoker takes a path and returns @{ StatusCode; Content }.
        Returns @{ Status; Items; Error; Complete }: 'ok', 'none' (404, the parent has no such child) or
        'failed'; Complete is false when it stopped with pages left.
    #>
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [scriptblock]$Invoker,
        [int]$MaxPages = 100
    )
    $items = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    $stoppedEarly = $false
    for ($page = 0; $page -lt $MaxPages -and $next; $page++) {
        $response = & $Invoker $next
        $code = if ($response) { [int]$response.StatusCode } else { 0 }
        if ($code -eq 404 -and $page -eq 0) { return @{ Status = 'none'; Items = @(); Error = ''; Complete = $true } }
        if ($code -ne 200) {
            $content = if ($response) { $response.Content } else { '' }
            return @{ Status = 'failed'; Items = $items.ToArray(); Error = "HTTP ${code}: $content"; Complete = $false }
        }
        $result = $response.Content | ConvertFrom-Json
        $value = Get-RebuildValue $result 'value'
        if ($null -ne $value -or $null -ne $result.PSObject.Properties['value']) {
            $pageItems = @($value | Where-Object { $null -ne $_ })
            foreach ($i in $pageItems) { $items.Add($i) }
            $next = Get-RebuildValue $result 'nextLink'
            if ($next -and $next -match '^https://[^/]+(/.*)$') { $next = $Matches[1] }
            # An empty page ends the loop (avd-landing-zone lesson 0008); a next link it still carried means
            # the read may be incomplete, which Complete says.
            if ($pageItems.Count -eq 0) { if ($next) { $stoppedEarly = $true }; $next = $null }
        } else {
            $items.Add($result)
            $next = $null
        }
    }
    # Complete is false when the loop stopped at MaxPages with pages left, or at an empty page with a next link.
    return @{ Status = 'ok'; Items = $items.ToArray(); Error = ''; Complete = (-not $stoppedEarly -and -not $next) }
}

function Get-RebuildEvidence {
    <#
    .SYNOPSIS
        Reads every Resource Graph type and REST read in the scope (rebuild/scope.json) for one
        subscription through the two invokers, and returns @{ Rows (type -> rows); Rest (read name ->
        @{ parentId; status; error; complete; items }); Reads (one status row per read) }. Nothing is
        scrubbed or written: the collector writes files, the drift check keeps them in memory. $Log takes
        a message and a level (INFO or WARN) and prints a line before each slow read.
    #>
    param(
        [Parameter(Mandatory)] $Scope,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [scriptblock]$GraphInvoker,
        [Parameter(Mandatory)] [scriptblock]$RestInvoker,
        [scriptblock]$Log = { param($Message, $Level) $null = $Message, $Level }
    )
    $rows = @{}
    $rest = @{}
    $reads = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @($Scope.resourceGraph)) {
        & $Log "  Reading $($t.type) through Resource Graph ..." 'INFO'
        $status = 'ok'; $err = ''
        try {
            $found = @(Invoke-RebuildGraphQuery -Query (Get-RebuildQuery -Table $t.table -Type $t.type) -SubscriptionId $SubscriptionId -Invoker $GraphInvoker)
        } catch {
            $found = @(); $status = 'failed'; $err = $_.Exception.Message
            & $Log "  $($t.type) read failed: $err" 'WARN'
        }
        $rows[$t.type] = $found
        $reads.Add([pscustomobject]@{ Read = $t.type; Source = $t.table; Items = $found.Count; Status = $status; Error = $err })
    }
    $sessionHostVms = @{}
    foreach ($sh in @($rows['microsoft.desktopvirtualization/hostpools/sessionhosts'])) {
        $vmId = "$(Get-RebuildValue $sh 'properties.resourceId' '')".ToLowerInvariant()
        if ($vmId) { $sessionHostVms[$vmId] = $true }
    }
    foreach ($read in @($Scope.rest)) {
        $parents = @()
        foreach ($p in @($read.parentTypes)) {
            if ($p -eq 'subscription') { $parents += "/subscriptions/$SubscriptionId" }
            else { $parents += @($rows[$p] | ForEach-Object { $_.id }) }
        }
        # Run Commands are read only on session hosts: that's where the landing zone keeps FSLogix's.
        if ($read.name -eq 'run-commands') { $parents = @($parents | Where-Object { $sessionHostVms.ContainsKey("$_".ToLowerInvariant()) }) }
        if ($parents.Count -eq 0) { continue }
        & $Log "  Reading $($read.name) for $($parents.Count) resource(s) ..." 'INFO'
        $results = @(foreach ($parentId in $parents) {
                $r = Invoke-RebuildRestRead -Path (Get-RebuildRestPath -Read $read -ParentId $parentId) -Invoker $RestInvoker
                if ($r.Status -eq 'failed') { & $Log "  $($read.name) failed for ${parentId}: $($r.Error)" 'WARN' }
                if ($r.Status -ne 'failed' -and $r.Complete -eq $false) { & $Log "  $($read.name) stopped with pages left for ${parentId}." 'WARN' }
                [pscustomobject][ordered]@{ parentId = $parentId; status = $r.Status; error = $r.Error; complete = ($r.Complete -ne $false); items = @($r.Items) }
            })
        $rest[$read.name] = $results
        $failed = @($results | Where-Object { $_.status -eq 'failed' -or -not $_.complete }).Count
        $reads.Add([pscustomobject]@{ Read = $read.name; Source = 'rest'; Items = $results.Count; Status = $(if ($failed) { "failed for $failed" } else { 'ok' }); Error = '' })
    }
    return @{ Rows = $rows; Rest = $rest; Reads = $reads.ToArray() }
}

function Get-RebuildIdPart {
    param([string]$Id, [int]$Index)
    $parts = "$Id" -split '/'
    if ($parts.Count -gt $Index) { return $parts[$Index] }
    return ''
}

function Get-RebuildTagsJson {
    # The cmdlet datasets wrote tags as compressed JSON, and nothing when there were none.
    param($Tags)
    if ($null -eq $Tags) { return $null }
    $names = @(if ($Tags -is [System.Collections.IDictionary]) { $Tags.Keys } else { $Tags.PSObject.Properties | ForEach-Object { $_.Name } })
    if ($names.Count -eq 0) { return $null }
    return ($Tags | ConvertTo-Json -Compress -Depth 5 -WarningAction SilentlyContinue)
}

function Get-RebuildList {
    # Joins a list the way the cmdlet datasets did; ARM omits empty lists, so null becomes ''.
    param($Value, [string]$Separator = ', ')
    return (@($Value | Where-Object { $null -ne $_ -and "$_" -ne '' }) -join $Separator)
}

function Get-RebuildCount {
    # ARM omits empty properties and @($null).Count is 1 (avd-landing-zone lesson 0021).
    param($Value)
    return @($Value | Where-Object { $_ }).Count
}

function Get-RebuildDataset {
    <#
    .SYNOPSIS
        Builds one of the collector's existing datasets from saved Resource Graph rows, with the same
        file name and columns the cmdlet version wrote (spec section 5.1). $Rows maps a resource type
        to its rows. Each column's ARM path is pinned by tests/Rebuild.Tests.ps1.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Rows', Justification = 'Read by the $of script block.')]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [hashtable]$Rows
    )
    $of = { param($t) if ($Rows.ContainsKey($t)) { @($Rows[$t] | Where-Object { $null -ne $_ }) } else { @() } }
    $rg = { param($r) Get-RebuildIdPart $r.id 4 }
    switch ($Name) {
        'resource-groups' {
            return @(& $of 'microsoft.resources/subscriptions/resourcegroups' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        ResourceGroupName = $_.name
                        Location          = $_.location
                        ProvisioningState = Get-RebuildValue $_ 'properties.provisioningState'
                        Tags              = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                    } })
        }
        'arm-resources' {
            return @(& $of '*' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name              = $_.name
                        ResourceGroupName = & $rg $_
                        ResourceType      = $_.type
                        Location          = $_.location
                        ResourceId        = $_.id
                        Tags              = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                    } })
        }
        'virtual-networks' {
            return @(& $of 'microsoft.network/virtualnetworks' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name                 = $_.name
                        ResourceGroupName    = & $rg $_
                        Location             = $_.location
                        AddressSpace         = Get-RebuildList (Get-RebuildValue $_ 'properties.addressSpace.addressPrefixes')
                        DnsServers           = Get-RebuildList (Get-RebuildValue $_ 'properties.dhcpOptions.dnsServers')
                        SubnetCount          = Get-RebuildCount (Get-RebuildValue $_ 'properties.subnets')
                        EnableDdosProtection = [bool](Get-RebuildValue $_ 'properties.enableDdosProtection' $false)
                        Id                   = $_.id
                    } })
        }
        'subnets' {
            return @(& $of 'microsoft.network/virtualnetworks' | ForEach-Object {
                    $vnetName = $_.name
                    @(Get-RebuildValue $_ 'properties.subnets' @()) | Where-Object { $_ } | ForEach-Object {
                        $prefix = Get-RebuildValue $_ 'properties.addressPrefix'
                        if ($null -eq $prefix) { $prefix = Get-RebuildValue $_ 'properties.addressPrefixes' }
                        [pscustomobject][ordered]@{
                            Name                           = $_.name
                            VNetName                       = $vnetName
                            AddressPrefix                  = Get-RebuildList $prefix
                            NSG                            = Get-RebuildIdPart (Get-RebuildValue $_ 'properties.networkSecurityGroup.id') 8
                            RouteTable                     = Get-RebuildIdPart (Get-RebuildValue $_ 'properties.routeTable.id') 8
                            ServiceEndpoints               = Get-RebuildList @(Get-RebuildValue $_ 'properties.serviceEndpoints' @() | ForEach-Object { Get-RebuildValue $_ 'service' })
                            Delegations                    = Get-RebuildList @(Get-RebuildValue $_ 'properties.delegations' @() | ForEach-Object { Get-RebuildValue $_ 'properties.serviceName' })
                            PrivateEndpointNetworkPolicies = Get-RebuildValue $_ 'properties.privateEndpointNetworkPolicies'
                            Id                             = $_.id
                        }
                    }
                })
        }
        'nsgs' {
            return @(& $of 'microsoft.network/networksecuritygroups' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name              = $_.name
                        ResourceGroupName = & $rg $_
                        Location          = $_.location
                        SecurityRuleCount = Get-RebuildCount (Get-RebuildValue $_ 'properties.securityRules')
                        DefaultRuleCount  = Get-RebuildCount (Get-RebuildValue $_ 'properties.defaultSecurityRules')
                        Id                = $_.id
                    } })
        }
        'nsg-rules' {
            return @(& $of 'microsoft.network/networksecuritygroups' | ForEach-Object {
                    $nsgName = $_.name
                    @(Get-RebuildValue $_ 'properties.securityRules' @()) | Where-Object { $_ } | ForEach-Object {
                        $p = Get-RebuildValue $_ 'properties'
                        $pick = { param($single, $plural) $v = Get-RebuildValue $p $single; if ($null -eq $v -or "$v" -eq '') { $v = Get-RebuildValue $p $plural }; Get-RebuildList $v }
                        [pscustomobject][ordered]@{
                            Name                     = $_.name
                            NSGName                  = $nsgName
                            Direction                = Get-RebuildValue $p 'direction'
                            Priority                 = Get-RebuildValue $p 'priority'
                            Access                   = Get-RebuildValue $p 'access'
                            Protocol                 = Get-RebuildValue $p 'protocol'
                            SourceAddressPrefix      = & $pick 'sourceAddressPrefix' 'sourceAddressPrefixes'
                            SourcePortRange          = & $pick 'sourcePortRange' 'sourcePortRanges'
                            DestinationAddressPrefix = & $pick 'destinationAddressPrefix' 'destinationAddressPrefixes'
                            DestinationPortRange     = & $pick 'destinationPortRange' 'destinationPortRanges'
                        }
                    }
                })
        }
        'route-tables' {
            return @(& $of 'microsoft.network/routetables' | ForEach-Object {
                    $routes = @(Get-RebuildValue $_ 'properties.routes' @() | Where-Object { $_ })
                    [pscustomobject][ordered]@{
                        Name                       = $_.name
                        ResourceGroupName          = & $rg $_
                        Location                   = $_.location
                        RouteCount                 = $routes.Count
                        DisableBgpRoutePropagation = [bool](Get-RebuildValue $_ 'properties.disableBgpRoutePropagation' $false)
                        Routes                     = (@($routes | ForEach-Object { "$($_.name):$(Get-RebuildValue $_ 'properties.addressPrefix')->$(Get-RebuildValue $_ 'properties.nextHopType')" }) -join '; ')
                        Id                         = $_.id
                    } })
        }
        'public-ips' {
            return @(& $of 'microsoft.network/publicipaddresses' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name                     = $_.name
                        ResourceGroupName        = & $rg $_
                        Location                 = $_.location
                        PublicIpAllocationMethod = Get-RebuildValue $_ 'properties.publicIPAllocationMethod'
                        IpAddress                = Get-RebuildValue $_ 'properties.ipAddress'
                        Sku                      = Get-RebuildValue $_ 'sku.name'
                        AssociatedTo             = Get-RebuildIdPart (Get-RebuildValue $_ 'properties.ipConfiguration.id') 8
                        Id                       = $_.id
                    } })
        }
        'virtual-machines' {
            return @(& $of 'microsoft.compute/virtualmachines' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name              = $_.name
                        ResourceGroupName = & $rg $_
                        Location          = $_.location
                        VMSize            = Get-RebuildValue $_ 'properties.hardwareProfile.vmSize'
                        OsType            = Get-RebuildValue $_ 'properties.storageProfile.osDisk.osType'
                        OsDiskSize        = Get-RebuildValue $_ 'properties.storageProfile.osDisk.diskSizeGB'
                        ImagePublisher    = Get-RebuildValue $_ 'properties.storageProfile.imageReference.publisher'
                        ImageOffer        = Get-RebuildValue $_ 'properties.storageProfile.imageReference.offer'
                        ImageSku          = Get-RebuildValue $_ 'properties.storageProfile.imageReference.sku'
                        ImageVersion      = Get-RebuildValue $_ 'properties.storageProfile.imageReference.exactVersion'
                        DataDiskCount     = Get-RebuildCount (Get-RebuildValue $_ 'properties.storageProfile.dataDisks')
                        PowerState        = Get-RebuildValue $_ 'properties.extended.instanceView.powerState.displayStatus'
                        ProvisioningState = Get-RebuildValue $_ 'properties.provisioningState'
                        AvailabilitySet   = Get-RebuildIdPart (Get-RebuildValue $_ 'properties.availabilitySet.id') 8
                        Tags              = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                        Id                = $_.id
                    } })
        }
        'vm-extensions' {
            return @(& $of 'microsoft.compute/virtualmachines/extensions' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        VMName             = Get-RebuildIdPart $_.id 8
                        Name               = Get-RebuildIdPart $_.id 10
                        Publisher          = Get-RebuildValue $_ 'properties.publisher'
                        ExtensionType      = Get-RebuildValue $_ 'properties.type'
                        TypeHandlerVersion = Get-RebuildValue $_ 'properties.typeHandlerVersion'
                        ProvisioningState  = Get-RebuildValue $_ 'properties.provisioningState'
                        AutoUpgrade        = Get-RebuildValue $_ 'properties.autoUpgradeMinorVersion'
                    } })
        }
        'storage-accounts' {
            return @(& $of 'microsoft.storage/storageaccounts' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        StorageAccountName       = $_.name
                        ResourceGroupName        = & $rg $_
                        Location                 = $_.location
                        Kind                     = Get-RebuildValue $_ 'kind'
                        SkuName                  = Get-RebuildValue $_ 'sku.name'
                        AccessTier               = Get-RebuildValue $_ 'properties.accessTier'
                        EnableHttpsOnly          = Get-RebuildValue $_ 'properties.supportsHttpsTrafficOnly'
                        MinimumTlsVersion        = Get-RebuildValue $_ 'properties.minimumTlsVersion'
                        AllowBlobPublicAccess    = Get-RebuildValue $_ 'properties.allowBlobPublicAccess'
                        NetworkRuleDefaultAction = Get-RebuildValue $_ 'properties.networkAcls.defaultAction'
                        LargeFileShares          = Get-RebuildValue $_ 'properties.largeFileSharesState'
                        Tags                     = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                        Id                       = $_.id
                    } })
        }
        'key-vaults' {
            return @(& $of 'microsoft.keyvault/vaults' | ForEach-Object {
                    # Soft delete can't be turned off any more and ARM may omit it; absent means on.
                    [pscustomobject][ordered]@{
                        VaultName             = $_.name
                        ResourceGroupName     = & $rg $_
                        Location              = $_.location
                        EnableSoftDelete      = [bool](Get-RebuildValue $_ 'properties.enableSoftDelete' $true)
                        EnablePurgeProtection = Get-RebuildValue $_ 'properties.enablePurgeProtection'
                        SkuName               = Get-RebuildValue $_ 'properties.sku.name'
                        Tags                  = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                        ResourceId            = $_.id
                    } })
        }
        'log-analytics-workspaces' {
            return @(& $of 'microsoft.operationalinsights/workspaces' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name              = $_.name
                        ResourceGroupName = & $rg $_
                        Location          = $_.location
                        Sku               = Get-RebuildValue $_ 'properties.sku.name'
                        RetentionDays     = Get-RebuildValue $_ 'properties.retentionInDays'
                        CustomerId        = Get-RebuildValue $_ 'properties.customerId'
                        ResourceId        = $_.id
                    } })
        }
        'recovery-services-vaults' {
            return @(& $of 'microsoft.recoveryservices/vaults' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name              = $_.name
                        ResourceGroupName = & $rg $_
                        Location          = $_.location
                        Type              = $_.type
                        ProvisioningState = Get-RebuildValue $_ 'properties.provisioningState' ''
                        Tags              = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                        ID                = $_.id
                    } })
        }
        'private-endpoints' {
            return @(& $of 'microsoft.network/privateendpoints' | ForEach-Object {
                    $subnetId = Get-RebuildValue $_ 'properties.subnet.id'
                    $conns = @(Get-RebuildValue $_ 'properties.privateLinkServiceConnections' @() | Where-Object { $_ })
                    [pscustomobject][ordered]@{
                        Name              = $_.name
                        ResourceGroupName = & $rg $_
                        Location          = $_.location
                        Subnet            = Get-RebuildIdPart $subnetId 10
                        VNet              = Get-RebuildIdPart $subnetId 8
                        TargetResource    = (@($conns | ForEach-Object { ("$(Get-RebuildValue $_ 'properties.privateLinkServiceId')" -split '/')[-1] }) -join ', ')
                        GroupIds          = (@($conns | ForEach-Object { @(Get-RebuildValue $_ 'properties.groupIds' @()) -join ',' }) -join '; ')
                        ConnectionStatus  = (@($conns | ForEach-Object { Get-RebuildValue $_ 'properties.privateLinkServiceConnectionState.status' }) -join ', ')
                        Id                = $_.id
                    } })
        }
        'avd-host-pools' {
            return @(& $of 'microsoft.desktopvirtualization/hostpools' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name                  = $_.name
                        ResourceGroupName     = & $rg $_
                        Location              = $_.location
                        HostPoolType          = Get-RebuildValue $_ 'properties.hostPoolType'
                        LoadBalancerType      = Get-RebuildValue $_ 'properties.loadBalancerType'
                        PreferredAppGroupType = Get-RebuildValue $_ 'properties.preferredAppGroupType'
                        MaxSessionLimit       = Get-RebuildValue $_ 'properties.maxSessionLimit'
                        ValidationEnvironment = Get-RebuildValue $_ 'properties.validationEnvironment'
                        StartVMOnConnect      = Get-RebuildValue $_ 'properties.startVMOnConnect'
                        CustomRdpProperty     = Get-RebuildValue $_ 'properties.customRdpProperty'
                        Tags                  = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                        Id                    = $_.id
                    } })
        }
        'avd-workspaces' {
            return @(& $of 'microsoft.desktopvirtualization/workspaces' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name               = $_.name
                        ResourceGroupName  = & $rg $_
                        Location           = $_.location
                        FriendlyName       = Get-RebuildValue $_ 'properties.friendlyName'
                        Description        = Get-RebuildValue $_ 'properties.description'
                        AppGroupReferences = Get-RebuildList (Get-RebuildValue $_ 'properties.applicationGroupReferences') '; '
                        Tags               = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                        Id                 = $_.id
                    } })
        }
        'avd-application-groups' {
            return @(& $of 'microsoft.desktopvirtualization/applicationgroups' | ForEach-Object {
                    [pscustomobject][ordered]@{
                        Name                 = $_.name
                        ResourceGroupName    = & $rg $_
                        Location             = $_.location
                        ApplicationGroupType = Get-RebuildValue $_ 'properties.applicationGroupType'
                        HostPoolArmPath      = Get-RebuildValue $_ 'properties.hostPoolArmPath'
                        FriendlyName         = Get-RebuildValue $_ 'properties.friendlyName'
                        Description          = Get-RebuildValue $_ 'properties.description'
                        Tags                 = Get-RebuildTagsJson (Get-RebuildValue $_ 'tags')
                        Id                   = $_.id
                    } })
        }
        'avd-session-hosts' {
            return @(& $of 'microsoft.desktopvirtualization/hostpools/sessionhosts' | ForEach-Object {
                    $hostPool = Get-RebuildIdPart $_.id 8
                    [pscustomobject][ordered]@{
                        HostPool        = $hostPool
                        Name            = "$hostPool/$(Get-RebuildIdPart $_.id 10)"
                        ResourceId      = Get-RebuildValue $_ 'properties.resourceId'
                        Status          = Get-RebuildValue $_ 'properties.status'
                        AllowNewSession = Get-RebuildValue $_ 'properties.allowNewSession'
                        AssignedUser    = Get-RebuildValue $_ 'properties.assignedUser'
                        Sessions        = Get-RebuildValue $_ 'properties.sessions'
                        LastHeartBeat   = Get-RebuildValue $_ 'properties.lastHeartBeat'
                        OSVersion       = Get-RebuildValue $_ 'properties.osVersion'
                        SxSStackVersion = Get-RebuildValue $_ 'properties.sxSStackVersion'
                        AgentVersion    = Get-RebuildValue $_ 'properties.agentVersion'
                        UpdateState     = Get-RebuildValue $_ 'properties.updateState'
                        StatusTimestamp = Get-RebuildValue $_ 'properties.statusTimestamp'
                    } })
        }
        default { throw "No Resource Graph mapping for dataset '$Name'." }
    }
}

Export-ModuleMember -Function Get-RebuildValue, Get-RebuildScope, Get-RebuildFileName, Get-RebuildQuery, Get-RebuildRestPath,
    ConvertTo-RebuildSafeObject, Get-RebuildSecretFinding, Invoke-RebuildGraphQuery, Invoke-RebuildRestRead, Get-RebuildEvidence, Get-RebuildDataset
