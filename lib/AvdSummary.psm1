<#
    Lightweight daily summary collector for avd-current-state.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    Pure functions over Graph and ARM REST invokers so they test offline. Compatible with Windows
    PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest

function Get-AvdSummaryQueryMap {
    <#
    .SYNOPSIS
        Returns the read-only Azure Resource Graph queries used by Summary mode.
    #>
    [ordered]@{
        ResourceCountsByType = 'resources | summarize count = count() by type = tolower(type) | order by type asc'
        VirtualMachines      = "resources | where type =~ 'microsoft.compute/virtualmachines' | extend vmSize = tostring(properties.hardwareProfile.vmSize), powerState = tostring(properties.extended.instanceView.powerState.code) | project name, resourceGroup, vmSize, powerState | order by name asc"
        HostPools            = "resources | where type =~ 'microsoft.desktopvirtualization/hostpools' | extend hostPoolType = tostring(properties.hostPoolType), loadBalancerType = tostring(properties.loadBalancerType), maxSessionLimit = toint(properties.maxSessionLimit), startVMOnConnect = tobool(properties.startVMOnConnect) | project name, resourceGroup, hostPoolType, loadBalancerType, maxSessionLimit, startVMOnConnect | order by name asc"
        Workspaces           = "resources | where type =~ 'microsoft.desktopvirtualization/workspaces' | project name, resourceGroup | order by name asc"
        ApplicationGroups    = "resources | where type =~ 'microsoft.desktopvirtualization/applicationgroups' | extend applicationGroupType = tostring(properties.applicationGroupType) | project name, resourceGroup, applicationGroupType | order by name asc"
    }
}

function Invoke-AvdSummaryLog {
    param(
        [scriptblock]$Log,
        [string]$Message,
        [string]$Level = 'INFO'
    )
    if ($null -ne $Log) {
        & $Log $Message $Level
    }
}

function Invoke-AvdSummaryGraphSafe {
    param(
        [string]$Label,
        [string]$Query,
        [string]$SubscriptionId,
        [string]$SubscriptionName,
        [scriptblock]$GraphInvoker,
        [System.Collections.Generic.List[string]]$Warnings,
        [scriptblock]$Log = $null
    )
    try {
        $rows = @(Invoke-RebuildGraphQuery -Query $Query -SubscriptionId $SubscriptionId -Invoker $GraphInvoker)
        Invoke-AvdSummaryLog -Log $Log -Message "  Summary $Label -- $($rows.Count) row(s)." -Level 'INFO'
        return $rows
    } catch {
        $msg = "Summary $Label query failed for '$SubscriptionName': $($_.Exception.Message)"
        $Warnings.Add($msg)
        Invoke-AvdSummaryLog -Log $Log -Message "  $msg" -Level 'WARN'
        return @()
    }
}

function Invoke-AvdSummarySubscription {
    <#
    .SYNOPSIS
        Collects a lightweight read-only inventory snapshot for one subscription using
        Azure Resource Graph and ARM REST.
    #>
    param(
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$SubscriptionName,
        [Parameter(Mandatory)] [scriptblock]$GraphInvoker,
        [Parameter(Mandatory)] [scriptblock]$RestInvoker,
        [scriptblock]$Log = $null,
        [switch]$IncludeIds
    )

    $queries = Get-AvdSummaryQueryMap
    $warnings = [System.Collections.Generic.List[string]]::new()

    $typeRows = @(Invoke-AvdSummaryGraphSafe -Label 'ResourceCountsByType' -Query $queries.ResourceCountsByType -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -GraphInvoker $GraphInvoker -Warnings $warnings -Log $Log)
    $vmRows   = @(Invoke-AvdSummaryGraphSafe -Label 'VirtualMachines'      -Query $queries.VirtualMachines      -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -GraphInvoker $GraphInvoker -Warnings $warnings -Log $Log)
    $hpRows   = @(Invoke-AvdSummaryGraphSafe -Label 'HostPools'            -Query $queries.HostPools            -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -GraphInvoker $GraphInvoker -Warnings $warnings -Log $Log)
    $wsRows   = @(Invoke-AvdSummaryGraphSafe -Label 'Workspaces'           -Query $queries.Workspaces           -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -GraphInvoker $GraphInvoker -Warnings $warnings -Log $Log)
    $agRows   = @(Invoke-AvdSummaryGraphSafe -Label 'ApplicationGroups'    -Query $queries.ApplicationGroups    -SubscriptionId $SubscriptionId -SubscriptionName $SubscriptionName -GraphInvoker $GraphInvoker -Warnings $warnings -Log $Log)

    $resourceCountsByType = [System.Collections.Generic.List[psobject]]::new()
    $armTotal = 0
    foreach ($row in $typeRows) {
        $typeName = "$(Get-RebuildValue $row 'type' '')"
        $ct = [int](Get-RebuildValue $row 'count' 0)
        if ($typeName) {
            $resourceCountsByType.Add([pscustomobject]@{
                type  = $typeName.ToLowerInvariant()
                count = $ct
            })
        }
        $armTotal += $ct
    }

    # ARM REST: count resource groups
    $rgCount = 0
    $rgPath = "/subscriptions/$SubscriptionId/resourcegroups?api-version=2021-04-01"
    $rgRead = Invoke-RebuildRestRead -Path $rgPath -Invoker $RestInvoker
    if ($rgRead.Status -eq 'ok') {
        $rgCount = @($rgRead.Items).Count
        Invoke-AvdSummaryLog -Log $Log -Message "  Summary ResourceGroups -- $rgCount item(s)." -Level 'INFO'
    } elseif ($rgRead.Status -eq 'failed') {
        $msg = "Summary ResourceGroups REST read failed for '$SubscriptionName': $($rgRead.Error)"
        $warnings.Add($msg)
        Invoke-AvdSummaryLog -Log $Log -Message "  $msg" -Level 'WARN'
    }

    # ARM REST: count session hosts per host pool
    $hostPools = [System.Collections.Generic.List[psobject]]::new()
    $totalSessionHosts = 0
    foreach ($hp in $hpRows) {
        $hpName = "$(Get-RebuildValue $hp 'name' '')"
        $hpRg   = "$(Get-RebuildValue $hp 'resourceGroup' '')"
        $shCount = 0
        if ($hpName -and $hpRg) {
            $shPath = "/subscriptions/$SubscriptionId/resourceGroups/$hpRg/providers/Microsoft.DesktopVirtualization/hostPools/$hpName/sessionHosts?api-version=2024-04-03"
            $shRead = Invoke-RebuildRestRead -Path $shPath -Invoker $RestInvoker
            if ($shRead.Status -eq 'ok') {
                $shCount = @($shRead.Items).Count
            } elseif ($shRead.Status -eq 'failed') {
                $msg = "Summary SessionHosts REST read failed for host pool '$hpName': $($shRead.Error)"
                $warnings.Add($msg)
                Invoke-AvdSummaryLog -Log $Log -Message "  $msg" -Level 'WARN'
            }
        }
        $totalSessionHosts += $shCount
        $hostPools.Add([pscustomobject]@{
            name             = $hpName
            resourceGroup    = $hpRg
            hostPoolType     = "$(Get-RebuildValue $hp 'hostPoolType' '')"
            loadBalancerType = "$(Get-RebuildValue $hp 'loadBalancerType' '')"
            maxSessionLimit  = [int](Get-RebuildValue $hp 'maxSessionLimit' 0)
            startVMOnConnect = [bool](Get-RebuildValue $hp 'startVMOnConnect' $false)
            sessionHostCount = $shCount
        })
    }

    $vms = [System.Collections.Generic.List[psobject]]::new()
    foreach ($vm in $vmRows) {
        $vms.Add([pscustomobject]@{
            name          = "$(Get-RebuildValue $vm 'name' '')"
            resourceGroup = "$(Get-RebuildValue $vm 'resourceGroup' '')"
            vmSize        = "$(Get-RebuildValue $vm 'vmSize' '')"
            powerState    = "$(Get-RebuildValue $vm 'powerState' '')"
        })
    }

    $workspaces = [System.Collections.Generic.List[psobject]]::new()
    foreach ($ws in $wsRows) {
        $workspaces.Add([pscustomobject]@{
            name          = "$(Get-RebuildValue $ws 'name' '')"
            resourceGroup = "$(Get-RebuildValue $ws 'resourceGroup' '')"
        })
    }

    $appGroups = [System.Collections.Generic.List[psobject]]::new()
    foreach ($ag in $agRows) {
        $appGroups.Add([pscustomobject]@{
            name                 = "$(Get-RebuildValue $ag 'name' '')"
            resourceGroup        = "$(Get-RebuildValue $ag 'resourceGroup' '')"
            applicationGroupType = "$(Get-RebuildValue $ag 'applicationGroupType' '')"
        })
    }

    $subSummary = [ordered]@{
        name              = $SubscriptionName
        status            = 'Collected'
        resourceGroups    = $rgCount
        armResources      = $armTotal
        hostPools         = $hostPools.Count
        workspaces        = $workspaces.Count
        applicationGroups = $appGroups.Count
        sessionHosts      = $totalSessionHosts
        virtualMachines   = $vms.Count
    }
    if ($IncludeIds) {
        $subSummary['subscriptionId'] = $SubscriptionId
    }

    return [pscustomobject]@{
        Subscription         = [pscustomobject]$subSummary
        ResourceCountsByType = $resourceCountsByType.ToArray()
        VirtualMachines      = $vms.ToArray()
        HostPools            = $hostPools.ToArray()
        Workspaces           = $workspaces.ToArray()
        ApplicationGroups    = $appGroups.ToArray()
        Warnings             = $warnings.ToArray()
    }
}

function New-AvdSummaryInventory {
    <#
    .SYNOPSIS
        Aggregates per-subscription summary results into the compact inventory object.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [object[]]$SubscriptionSummaries = @(),
        [object[]]$SkippedSubscriptions = @(),
        [string]$Stamp = (Get-Date -Format 'yyyy-MM-dd'),
        [string]$GeneratedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
        [string]$TenantId = '',
        [string[]]$Warnings = @(),
        [switch]$IncludeIds
    )

    $subRecords = [System.Collections.Generic.List[psobject]]::new()
    $typeTotals = @{}
    $allVms     = [System.Collections.Generic.List[psobject]]::new()
    $allHps     = [System.Collections.Generic.List[psobject]]::new()
    $allWss     = [System.Collections.Generic.List[psobject]]::new()
    $allAgs     = [System.Collections.Generic.List[psobject]]::new()
    $allWarns   = [System.Collections.Generic.List[string]]::new()
    foreach ($w in @($Warnings | Where-Object { $_ })) { $allWarns.Add("$w") }

    $totRg  = 0
    $totArm = 0
    $totSh  = 0
    $collectedCount = 0

    foreach ($item in @($SubscriptionSummaries | Where-Object { $null -ne $_ })) {
        $collectedCount++
        $subRecords.Add($item.Subscription)
        $totRg  += [int](Get-RebuildValue $item.Subscription 'resourceGroups' 0)
        $totArm += [int](Get-RebuildValue $item.Subscription 'armResources' 0)
        $totSh  += [int](Get-RebuildValue $item.Subscription 'sessionHosts' 0)

        foreach ($tc in @($item.ResourceCountsByType | Where-Object { $null -ne $_ })) {
            $t = "$($tc.type)"
            $prev = if ($typeTotals.ContainsKey($t)) { $typeTotals[$t] } else { 0 }
            $typeTotals[$t] = $prev + [int]$tc.count
        }
        foreach ($vm in @($item.VirtualMachines   | Where-Object { $null -ne $_ })) { $allVms.Add($vm) }
        foreach ($hp in @($item.HostPools         | Where-Object { $null -ne $_ })) { $allHps.Add($hp) }
        foreach ($ws in @($item.Workspaces        | Where-Object { $null -ne $_ })) { $allWss.Add($ws) }
        foreach ($ag in @($item.ApplicationGroups | Where-Object { $null -ne $_ })) { $allAgs.Add($ag) }
        foreach ($w  in @($item.Warnings          | Where-Object { $_ }))           { $allWarns.Add("$w") }
    }

    $skippedCount = 0
    foreach ($sk in @($SkippedSubscriptions | Where-Object { $null -ne $_ })) {
        $skippedCount++
        $rec = [ordered]@{
            name   = "$(Get-RebuildValue $sk 'SubscriptionName' '')"
            status = "$(Get-RebuildValue $sk 'Status' 'Skipped')"
            reason = "$(Get-RebuildValue $sk 'Reason' '')"
        }
        if ($IncludeIds) {
            $rec['subscriptionId'] = "$(Get-RebuildValue $sk 'SubscriptionId' '')"
        }
        $subRecords.Add([pscustomobject]$rec)
    }

    $mergedTypes = @(
        $typeTotals.Keys | Sort-Object | ForEach-Object {
            [pscustomobject]@{ type = $_; count = [int]$typeTotals[$_] }
        }
    )

    $summaryLine = "$($allHps.Count) host pool(s), $totSh session host(s), $totArm ARM resource(s)"

    $doc = [ordered]@{
        schema       = 'avd-current-state-summary/v1'
        mode         = 'summary'
        generatedUtc = $GeneratedUtc
        stamp        = $Stamp
        summary      = $summaryLine
    }
    if ($IncludeIds -and -not [string]::IsNullOrWhiteSpace($TenantId)) {
        $doc['tenantId'] = $TenantId
    }
    $doc['subscriptions'] = $subRecords.ToArray()
    $doc['totals'] = [ordered]@{
        subscriptionsTargeted  = $collectedCount + $skippedCount
        subscriptionsCollected = $collectedCount
        subscriptionsSkipped   = $skippedCount
        resourceGroups         = $totRg
        armResources           = $totArm
        hostPools              = $allHps.Count
        workspaces             = $allWss.Count
        applicationGroups      = $allAgs.Count
        sessionHosts           = $totSh
        virtualMachines        = $allVms.Count
    }
    $doc['resourceCountsByType'] = $mergedTypes
    $doc['avdWorkload'] = [ordered]@{
        hostPools         = $allHps.ToArray()
        workspaces        = $allWss.ToArray()
        applicationGroups = $allAgs.ToArray()
    }
    $doc['virtualMachines'] = $allVms.ToArray()
    $doc['warnings']        = $allWarns.ToArray()

    return [pscustomobject]$doc
}

function Format-AvdSummaryMarkdown {
    <#
    .SYNOPSIS
        Renders the compact <stamp>-inventory.md content from a summary inventory object.
    #>
    param([Parameter(Mandatory)] [psobject]$Inventory)

    $lines = [System.Collections.Generic.List[string]]::new()
    $totals = $Inventory.totals

    $lines.Add('# AVD Current State -- Inventory Summary')
    $lines.Add('')
    $lines.Add("**Generated:** $($Inventory.generatedUtc)")
    $lines.Add("**Summary:** $($Inventory.summary)")
    $lines.Add("**Subscriptions collected:** $($totals.subscriptionsCollected) of $($totals.subscriptionsTargeted)")
    $lines.Add('')
    $lines.Add('## AVD workload')
    $lines.Add('')
    $lines.Add('| Component | Count |')
    $lines.Add('|---|---|')
    $lines.Add("| Host Pools | $($totals.hostPools) |")
    $lines.Add("| Workspaces | $($totals.workspaces) |")
    $lines.Add("| Application Groups | $($totals.applicationGroups) |")
    $lines.Add("| Session Hosts | $($totals.sessionHosts) |")
    $lines.Add('')

    $hps = @($Inventory.avdWorkload.hostPools)
    if ($hps.Count -gt 0) {
        $lines.Add('| Host Pool | Resource Group | Type | Load Balancer | Max Session Limit | Start VM on Connect | Session Hosts |')
        $lines.Add('|---|---|---|---|---|---|---|')
        foreach ($hp in $hps) {
            $lines.Add("| $($hp.name) | $($hp.resourceGroup) | $($hp.hostPoolType) | $($hp.loadBalancerType) | $($hp.maxSessionLimit) | $($hp.startVMOnConnect) | $($hp.sessionHostCount) |")
        }
        $lines.Add('')
    }

    $lines.Add('## Dataset counts')
    $lines.Add('')
    $lines.Add('| Dataset | Count |')
    $lines.Add('|---|---|')
    $lines.Add("| ResourceGroups | $($totals.resourceGroups) |")
    $lines.Add("| ARMResources | $($totals.armResources) |")
    $lines.Add("| VirtualMachines | $($totals.virtualMachines) |")
    $lines.Add("| AVDHostPools | $($totals.hostPools) |")
    $lines.Add("| AVDWorkspaces | $($totals.workspaces) |")
    $lines.Add("| AVDApplicationGroups | $($totals.applicationGroups) |")
    $lines.Add("| AVDSessionHosts | $($totals.sessionHosts) |")
    $lines.Add('')

    $types = @($Inventory.resourceCountsByType)
    if ($types.Count -gt 0) {
        $lines.Add('## Resource counts by type')
        $lines.Add('')
        $lines.Add('| Resource Type | Count |')
        $lines.Add('|---|---|')
        foreach ($tc in $types) {
            $lines.Add("| $($tc.type) | $($tc.count) |")
        }
        $lines.Add('')
    }

    $vms = @($Inventory.virtualMachines)
    if ($vms.Count -gt 0) {
        $lines.Add('## Virtual machines')
        $lines.Add('')
        $lines.Add('| Name | Resource Group | Size | Power State |')
        $lines.Add('|---|---|---|---|')
        foreach ($vm in $vms) {
            $lines.Add("| $($vm.name) | $($vm.resourceGroup) | $($vm.vmSize) | $($vm.powerState) |")
        }
        $lines.Add('')
    }

    $warns = @($Inventory.warnings)
    if ($warns.Count -gt 0) {
        $lines.Add('## Warnings')
        $lines.Add('')
        foreach ($w in $warns) {
            $lines.Add("- $w")
        }
        $lines.Add('')
    }

    return ($lines.ToArray() -join "`n")
}

function Write-AvdSummaryInventory {
    <#
    .SYNOPSIS
        Scrubs and writes <stamp>-inventory.json and <stamp>-inventory.md into OutputPath.
    #>
    param(
        [Parameter(Mandatory)] [psobject]$Inventory,
        [Parameter(Mandatory)] [string]$OutputPath,
        [switch]$IncludeIds
    )

    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

    $safe = ConvertTo-RebuildSafeObject -InputObject $Inventory
    $json = ConvertTo-Json -InputObject $safe.Object -Depth 10 -WarningAction SilentlyContinue
    $findings = @(Get-RebuildSecretFinding -Text $json)
    if ($findings.Count -gt 0) {
        throw "Summary inventory secret scan failed: $($findings -join ', ')."
    }
    if (-not $IncludeIds) {
        if ($json -match '(?i)(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])') {
            throw 'Summary inventory unexpectedly contains an unredacted GUID without -IncludeIds.'
        }
    }

    $md = Format-AvdSummaryMarkdown -Inventory $safe.Object
    $stamp = "$($Inventory.stamp)"
    $jsonPath = Join-Path $OutputPath "$stamp-inventory.json"
    $mdPath   = Join-Path $OutputPath "$stamp-inventory.md"

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jsonPath, $json, $utf8NoBom)
    [System.IO.File]::WriteAllText($mdPath, $md, $utf8NoBom)

    return [pscustomobject]@{
        JsonPath = $jsonPath
        MdPath   = $mdPath
        Summary  = $Inventory.summary
    }
}

Export-ModuleMember -Function Get-AvdSummaryQueryMap, Invoke-AvdSummarySubscription, New-AvdSummaryInventory, Format-AvdSummaryMarkdown, Write-AvdSummaryInventory
