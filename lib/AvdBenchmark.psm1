# Pure, offline-testable functions for Tier 2 observational AVD Insights benchmark export (Contract C25,
# avd-benchmark-result/v1) and C11 summary Insights fact calculation (avd-ops docs/benchmark-platform-spec.md).
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.

Set-StrictMode -Version Latest

$script:PublicVmSkuCatalog = @{
    'Standard_D2s_v5'    = @{ Vcpu = 2;  MemoryGiB = 8 }
    'Standard_D4s_v5'    = @{ Vcpu = 4;  MemoryGiB = 16 }
    'Standard_D8s_v5'    = @{ Vcpu = 8;  MemoryGiB = 32 }
    'Standard_D16s_v5'   = @{ Vcpu = 16; MemoryGiB = 64 }
    'Standard_D32s_v5'   = @{ Vcpu = 32; MemoryGiB = 128 }
    'Standard_D4ds_v5'   = @{ Vcpu = 4;  MemoryGiB = 16 }
    'Standard_D8ds_v5'   = @{ Vcpu = 8;  MemoryGiB = 32 }
    'Standard_D16ds_v5'  = @{ Vcpu = 16; MemoryGiB = 64 }
    'Standard_D4ads_v5'  = @{ Vcpu = 4;  MemoryGiB = 16 }
    'Standard_D8ads_v5'  = @{ Vcpu = 8;  MemoryGiB = 32 }
    'Standard_D16ads_v5' = @{ Vcpu = 16; MemoryGiB = 64 }
    'Standard_D4as_v5'   = @{ Vcpu = 4;  MemoryGiB = 16 }
    'Standard_D8as_v5'   = @{ Vcpu = 8;  MemoryGiB = 32 }
    'Standard_D16as_v5'  = @{ Vcpu = 16; MemoryGiB = 64 }
    'Standard_E4s_v5'    = @{ Vcpu = 4;  MemoryGiB = 32 }
    'Standard_E8s_v5'    = @{ Vcpu = 8;  MemoryGiB = 64 }
    'Standard_E16s_v5'   = @{ Vcpu = 16; MemoryGiB = 128 }
    'Standard_E32s_v5'   = @{ Vcpu = 32; MemoryGiB = 256 }
    'Standard_E4ds_v5'   = @{ Vcpu = 4;  MemoryGiB = 32 }
    'Standard_E8ds_v5'   = @{ Vcpu = 8;  MemoryGiB = 64 }
    'Standard_E16ds_v5'  = @{ Vcpu = 16; MemoryGiB = 128 }
    'Standard_F4s_v2'    = @{ Vcpu = 4;  MemoryGiB = 8 }
    'Standard_F8s_v2'    = @{ Vcpu = 8;  MemoryGiB = 16 }
    'Standard_F16s_v2'   = @{ Vcpu = 16; MemoryGiB = 32 }
    'Standard_NV8as_v4'  = @{ Vcpu = 8;  MemoryGiB = 28 }
    'Standard_NV16as_v4' = @{ Vcpu = 16; MemoryGiB = 56 }
    'Standard_NV12s_v3'  = @{ Vcpu = 12; MemoryGiB = 112 }
}

function Get-BenchProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) {
            if ("$k" -ieq $Name) {
                if ($null -ne $Object[$k]) { return $Object[$k] }
                return $Default
            }
        }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    foreach ($prop in $Object.PSObject.Properties) {
        if ($prop.Name -ieq $Name -and $null -ne $prop.Value) { return $prop.Value }
    }
    return $Default
}

function Get-AvdSampleBand {
    <#
    .SYNOPSIS
    Maps an exact host or session count into the Contract C25 closed sample band enum.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [int]$Count = 0
    )
    if ($Count -le 0) { return $null }
    if ($Count -le 2) { return '1-2' }
    if ($Count -le 9) { return '3-9' }
    if ($Count -le 25) { return '10-25' }
    if ($Count -le 100) { return '26-100' }
    return '100+'
}

function Get-AvdPercentileValue {
    <#
    .SYNOPSIS
    Computes a single percentile (0..100) over a numeric sequence using linear interpolation.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Values = @(),

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 100)]
        [double]$Percentile
    )
    $nums = New-Object System.Collections.Generic.List[double]
    foreach ($v in @($Values)) {
        if ($null -eq $v -or "$v".Trim() -eq '') { continue }
        $parsed = 0.0
        if ([double]::TryParse("$v", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            if (-not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed)) {
                $nums.Add($parsed)
            }
        }
    }
    if ($nums.Count -eq 0) { return $null }
    $nums.Sort()
    $n = $nums.Count
    if ($n -eq 1) { return [Math]::Round($nums[0], 2) }
    $pos = ($Percentile / 100.0) * ($n - 1)
    $lower = [int][Math]::Floor($pos)
    $upper = [int][Math]::Ceiling($pos)
    if ($lower -eq $upper) { return [Math]::Round($nums[$lower], 2) }
    $weight = $pos - $lower
    $interpolated = $nums[$lower] + (($nums[$upper] - $nums[$lower]) * $weight)
    return [Math]::Round($interpolated, 2)
}

function Get-AvdDistribution {
    <#
    .SYNOPSIS
    Computes a Contract C25 percentile distribution object (p50, p90, p95, p99, min, max, and optional p10).
    #>
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Values = @(),

        [Parameter(Mandatory = $false)]
        [switch]$IncludeP10
    )
    $nums = New-Object System.Collections.Generic.List[double]
    foreach ($v in @($Values)) {
        if ($null -eq $v -or "$v".Trim() -eq '') { continue }
        $parsed = 0.0
        if ([double]::TryParse("$v", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            if (-not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed)) {
                $nums.Add($parsed)
            }
        }
    }
    if ($nums.Count -eq 0) { return $null }
    $nums.Sort()
    $arr = $nums.ToArray()
    $dist = [ordered]@{}
    if ($IncludeP10) {
        $dist.p10 = Get-AvdPercentileValue -Values $arr -Percentile 10
    }
    $dist.p50 = Get-AvdPercentileValue -Values $arr -Percentile 50
    $dist.p90 = Get-AvdPercentileValue -Values $arr -Percentile 90
    $dist.p95 = Get-AvdPercentileValue -Values $arr -Percentile 95
    $dist.p99 = Get-AvdPercentileValue -Values $arr -Percentile 99
    $dist.min = [Math]::Round($arr[0], 2)
    $dist.max = [Math]::Round($arr[$arr.Count - 1], 2)
    return $dist
}

function Resolve-AvdPublicVmSku {
    <#
    .SYNOPSIS
    Validates that a VM SKU is a public Azure Standard_* SKU and resolves its vCPU and memoryGiB.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$VmSku = 'Standard_D8s_v5',

        [Parameter(Mandatory = $false)]
        [int]$Vcpu = 0,

        [Parameter(Mandatory = $false)]
        [double]$MemoryGiB = 0
    )
    $cleanSku = "$VmSku".Trim()
    if ($cleanSku -notmatch '^Standard_[A-Za-z0-9_]{1,40}$') {
        $cleanSku = 'Standard_D8s_v5'
    }
    $resolvedVcpu = $Vcpu
    $resolvedMem = $MemoryGiB
    foreach ($k in $script:PublicVmSkuCatalog.Keys) {
        if ($k -ieq $cleanSku) {
            $cleanSku = $k
            if ($resolvedVcpu -le 0) { $resolvedVcpu = $script:PublicVmSkuCatalog[$k].Vcpu }
            if ($resolvedMem -le 0) { $resolvedMem = $script:PublicVmSkuCatalog[$k].MemoryGiB }
            break
        }
    }
    if ($resolvedVcpu -le 0) {
        if ($cleanSku -match '^Standard_[A-Za-z]+(\d+)[A-Za-z0-9_]*$') {
            $resolvedVcpu = [int]$Matches[1]
        } else {
            $resolvedVcpu = 8
        }
    }
    if ($resolvedMem -le 0) {
        if ($cleanSku -match '^Standard_E') {
            $resolvedMem = $resolvedVcpu * 8
        } elseif ($cleanSku -match '^Standard_F') {
            $resolvedMem = $resolvedVcpu * 2
        } else {
            $resolvedMem = $resolvedVcpu * 4
        }
    }
    return [ordered]@{
        vmSku     = $cleanSku
        vcpu      = [int]$resolvedVcpu
        memoryGiB = [double]$resolvedMem
    }
}

function Resolve-AvdJoinType {
    param([string]$JoinType = 'entra-joined')
    $v = "$JoinType".Trim().ToLowerInvariant()
    if ($v -in @('entra-joined', 'aadjoined', 'azureadjoined', 'aadloginforwindows', 'entra')) {
        return 'entra-joined'
    }
    if ($v -in @('hybrid-entra-joined', 'hybridaadjoined', 'hybrid', 'hybrid-domain-joined')) {
        return 'hybrid-entra-joined'
    }
    if ($v -in @('ad-domain-joined', 'domain-joined', 'domainjoined', 'jsonaddomainextension', 'adds', 'ad-ds')) {
        return 'ad-domain-joined'
    }
    return 'entra-joined'
}

function Resolve-AvdTransportType {
    param([string]$Transport = '')
    $v = "$Transport".Trim().ToLowerInvariant()
    if ($v -in @('turn', 'relayed', 'relayedudp', 'turnrelay', 'udp-turn', 'shortpath-turn')) {
        return 'TURN'
    }
    if ($v -in @('shortpath', 'udp', 'directudp', 'shortpathpublic', 'shortpathprivate', '1', 'true', 'direct')) {
        return 'Shortpath'
    }
    if ($v -in @('websocket', 'tcp', 'reverseconnect', '0', 'false', 'none', 'https')) {
        return 'Websocket'
    }
    return 'Websocket'
}

function Resolve-AvdOsDiskType {
    param([string]$OsDiskType = 'Premium_LRS')
    $allowed = @('Premium_LRS', 'Premium_ZRS', 'PremiumV2_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Standard_LRS', 'Ephemeral')
    foreach ($a in $allowed) {
        if ($a -ieq "$OsDiskType".Trim()) { return $a }
    }
    return 'Premium_LRS'
}

function Test-AvdTelemetryRowInWindow {
    <#
    .SYNOPSIS
    Checks whether a telemetry row's TimeGenerated falls within the lookback window and optional working hours.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Row,

        [Parameter(Mandatory = $true)]
        [datetime]$WindowStartUtc,

        [Parameter(Mandatory = $true)]
        [datetime]$WindowEndUtc,

        [Parameter(Mandatory = $false)]
        [bool]$FilterWorkingHours = $true,

        [Parameter(Mandatory = $false)]
        [int]$StartMinuteOfDay = 420,

        [Parameter(Mandatory = $false)]
        [int]$EndMinuteOfDay = 1140,

        [Parameter(Mandatory = $false)]
        [string[]]$WorkingDays = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri')
    )
    $rawTs = Get-BenchProp $Row 'TimeGenerated'
    if ($null -eq $rawTs -or "$rawTs".Trim() -eq '') { return $true }
    $ts = [datetime]::MinValue
    if ($rawTs -is [datetime]) {
        $ts = $rawTs.ToUniversalTime()
    } else {
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse("$rawTs", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
            return $true
        }
        $ts = $parsed.ToUniversalTime()
    }
    if ($ts -lt $WindowStartUtc -or $ts -gt $WindowEndUtc) { return $false }
    if ($FilterWorkingHours) {
        $dayShort = $ts.DayOfWeek.ToString().Substring(0, 3)
        $dayMatch = $false
        foreach ($d in @($WorkingDays)) {
            if ($d.StartsWith($dayShort, [System.StringComparison]::OrdinalIgnoreCase)) { $dayMatch = $true; break }
        }
        if (-not $dayMatch) { return $false }
        $minuteOfDay = ($ts.Hour * 60) + $ts.Minute
        if ($StartMinuteOfDay -le $EndMinuteOfDay) {
            if ($minuteOfDay -lt $StartMinuteOfDay -or $minuteOfDay -gt $EndMinuteOfDay) { return $false }
        } else {
            if ($minuteOfDay -lt $StartMinuteOfDay -and $minuteOfDay -gt $EndMinuteOfDay) { return $false }
        }
    }
    return $true
}

function ConvertTo-MinuteOfDay {
    param([string]$Clock, [int]$DefaultMinutes)
    if ("$Clock" -match '^([01]\d|2[0-3]):([0-5]\d)$') {
        return ([int]$Matches[1] * 60) + [int]$Matches[2]
    }
    return $DefaultMinutes
}

function Get-AvdExperienceGate {
    <#
    .SYNOPSIS
    Evaluates the Contract C25 experienceGate ('pass', 'warn', 'fail') against the baseline thresholds:
    RTT p95 < 150ms and Session Input Delay p95 < 150ms.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Metrics,

        [Parameter(Mandatory = $false)]
        [double]$MaxRttP95Ms = 150.0,

        [Parameter(Mandatory = $false)]
        [double]$MaxInputDelayP95Ms = 150.0,

        [Parameter(Mandatory = $false)]
        [switch]$EnableWarnBand
    )
    $rttDist = Get-BenchProp $Metrics 'rttMs'
    $inputDist = Get-BenchProp $Metrics 'inputDelayMs'
    $cpuDist = Get-BenchProp $Metrics 'cpuPct'
    $failRate = Get-BenchProp $Metrics 'connectionFailureRatePct'

    $rttP95 = if ($null -ne $rttDist) { Get-BenchProp $rttDist 'p95' } else { $null }
    $inputP95 = if ($null -ne $inputDist) { Get-BenchProp $inputDist 'p95' } else { $null }
    $cpuP95 = if ($null -ne $cpuDist) { Get-BenchProp $cpuDist 'p95' } else { $null }

    if ($null -ne $rttP95 -and [double]$rttP95 -ge $MaxRttP95Ms) { return 'fail' }
    if ($null -ne $inputP95 -and [double]$inputP95 -ge $MaxInputDelayP95Ms) { return 'fail' }
    if ($null -ne $cpuP95 -and [double]$cpuP95 -ge 95.0) { return 'fail' }
    if ($null -ne $failRate -and [double]$failRate -ge 20.0) { return 'fail' }

    if ($EnableWarnBand) {
        if ($null -ne $rttP95 -and [double]$rttP95 -ge 100.0) { return 'warn' }
        if ($null -ne $inputP95 -and [double]$inputP95 -ge 100.0) { return 'warn' }
        if ($null -ne $cpuP95 -and [double]$cpuP95 -ge 85.0) { return 'warn' }
        if ($null -ne $failRate -and [double]$failRate -ge 5.0) { return 'warn' }
    }
    return 'pass'
}

function Get-AvdInsightsKqlQuery {
    <#
    .SYNOPSIS
    Returns the strictly read-only KQL queries for WVDConnections, WVDConnectionNetworkData, Perf, and WVDAgentHealthStatus.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 30)]
        [int]$WindowDays = 7
    )
    $d = "${WindowDays}d"
    return [ordered]@{
        WVDConnections           = "WVDConnections | where TimeGenerated >= ago($d) | project TimeGenerated, CorrelationId, State, SessionHostName, UdpUse, TransportType, ClientSideTransportProtocol, TimeToConnectMs, ProfileLoadMs, VhdxAttachMs, _ResourceId"
        WVDConnectionNetworkData = "WVDConnectionNetworkData | where TimeGenerated >= ago($d) | project TimeGenerated, CorrelationId, EstRoundTripTimeInMs, EstAvailableBandwidthKBps"
        Perf                     = "Perf | where TimeGenerated >= ago($d) | where ObjectName in ('Processor Information', 'Processor', 'System', 'Memory', 'User Input Delay per Session', 'User Input Delay per Process', 'LogicalDisk', 'PhysicalDisk') | project TimeGenerated, Computer, ObjectName, CounterName, InstanceName, CounterValue"
        WVDAgentHealthStatus     = "WVDAgentHealthStatus | where TimeGenerated >= ago($d) | project TimeGenerated, SessionHostName, Status, ActiveSessions, LastHeartBeat, AgentVersion"
    }
}

function Find-AvdBenchmarkLeak {
    <#
    .SYNOPSIS
    Scans a Contract C25 object for leaked GUIDs, emails, UNC paths, ARM resource IDs, domains, IP addresses, or known names.
    #>
    param(
        [Parameter(Mandatory = $false)]
        $Node,

        [Parameter(Mandatory = $false)]
        [string]$Path = '$',

        [Parameter(Mandatory = $false)]
        [string[]]$KnownNames = @()
    )
    if ($null -eq $Node) { return }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) {
            foreach ($hit in @(Find-AvdBenchmarkLeak -Node "$k" -Path "$Path[key]" -KnownNames $KnownNames)) { $hit }
            foreach ($hit in @(Find-AvdBenchmarkLeak -Node $Node[$k] -Path "$Path.$k" -KnownNames $KnownNames)) { $hit }
        }
        return
    }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) {
            foreach ($hit in @(Find-AvdBenchmarkLeak -Node $item -Path "$Path[$i]" -KnownNames $KnownNames)) { $hit }
            $i++
        }
        return
    }
    if ($Node -is [pscustomobject]) {
        foreach ($p in $Node.PSObject.Properties) {
            foreach ($hit in @(Find-AvdBenchmarkLeak -Node "$($p.Name)" -Path "$Path[key]" -KnownNames $KnownNames)) { $hit }
            foreach ($hit in @(Find-AvdBenchmarkLeak -Node $p.Value -Path "$Path.$($p.Name)" -KnownNames $KnownNames)) { $hit }
        }
        return
    }
    $text = "$Node"
    if ($text -eq '') { return }
    if ($Path -in @('$.$schema', '$.$id')) { return }

    if ($text -match '(?i)(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])') {
        "guid at $Path"
    }
    if ($text -match '[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}') {
        "email at $Path"
    } elseif ($text -match '\\\\[A-Za-z0-9]') {
        "unc-path at $Path"
    } elseif ($text -match '(?i)\b([a-z0-9-]+\.)+(com|net|org|edu|gov|mil|io|dev|local|internal|corp|lan|onmicrosoft\.com|windows\.net)\b') {
        "domain at $Path"
    }
    if ($text -match '(?i)/subscriptions/|/resourceGroups/|/providers/Microsoft\.') {
        "arm-resource-id at $Path"
    }
    if ($Path -notmatch '(?i)version') {
        foreach ($ip in [regex]::Matches($text, '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')) {
            if (@($ip.Value -split '\.' | Where-Object { [int]$_ -gt 255 }).Count) { continue }
            "ip-address at $Path"
        }
    }
    $lowerText = $text.ToLowerInvariant()
    foreach ($name in @($KnownNames)) {
        if ($null -eq $name) { continue }
        $clean = "$name".Trim().ToLowerInvariant()
        if ($clean.Length -ge 3 -and $lowerText.Contains($clean)) {
            "known-name at $Path"
            break
        }
    }
}

function Measure-AvdInsightsTelemetry {
    <#
    .SYNOPSIS
    Internal helper that parses WVDConnections, WVDConnectionNetworkData, Perf, and WVDAgentHealthStatus rows
    over the working-hours window and returns aggregated distributions, scalars, bands, and known names to redact.
    #>
    param(
        [object[]]$Connections = @(),
        [object[]]$NetworkData = @(),
        [object[]]$Perf = @(),
        [object[]]$AgentHealth = @(),
        [int]$WindowDays = 7,
        [string]$WorkingHoursStart = '07:00',
        [string]$WorkingHoursEnd = '19:00',
        [string[]]$WorkingDays = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri'),
        [bool]$FilterWorkingHours = $true,
        [nullable[datetime]]$ReferenceTime = $null,
        [int]$Vcpu = 8,
        [double]$MemoryGiB = 32.0
    )
    $knownNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $distinctHosts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $distinctSessions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $allRows = @($Connections) + @($NetworkData) + @($Perf) + @($AgentHealth)
    foreach ($r in $allRows) {
        if ($null -eq $r) { continue }
        foreach ($col in @('SessionHostName', 'Computer', 'UserName', 'UserPrincipalName', 'CorrelationId', 'SessionId', '_ResourceId', 'ResourceId', 'ClientSideIPAddress', 'TenantId', 'SubscriptionId')) {
            $val = "$(Get-BenchProp $r $col '')".Trim()
            if ($val -ne '') {
                if ($val.Length -ge 3) { [void]$knownNames.Add($val) }
                if ($col -in @('SessionHostName', 'Computer')) {
                    $shortHost = (($val -split '/')[-1] -split '\.')[0]
                    if ($shortHost.Length -ge 3) { [void]$knownNames.Add($shortHost) }
                }
                if ($col -in @('UserName', 'UserPrincipalName') -and $val -match '^([^@\\]+)') {
                    $userPart = $Matches[1]
                    if ($userPart.Length -ge 3) { [void]$knownNames.Add($userPart) }
                }
            }
        }
    }

    # Determine reference timestamp from data if not explicitly passed
    $latestTs = [datetime]::MinValue
    foreach ($r in $allRows) {
        $rawTs = Get-BenchProp $r 'TimeGenerated'
        if ($null -ne $rawTs -and "$rawTs".Trim() -ne '') {
            $parsed = [datetime]::MinValue
            if ($rawTs -is [datetime]) {
                $parsed = $rawTs.ToUniversalTime()
            } elseif ([datetime]::TryParse("$rawTs", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
                $parsed = $parsed.ToUniversalTime()
            }
            if ($parsed -gt $latestTs) { $latestTs = $parsed }
        }
    }
    $windowEnd = if ($null -ne $ReferenceTime) { $ReferenceTime.Value.ToUniversalTime() } elseif ($latestTs -gt [datetime]::MinValue) { $latestTs } else { [datetime]::UtcNow }
    $windowStart = $windowEnd.AddDays(-1 * [Math]::Max(1, $WindowDays))
    $startMin = ConvertTo-MinuteOfDay -Clock $WorkingHoursStart -DefaultMinutes 420
    $endMin = ConvertTo-MinuteOfDay -Clock $WorkingHoursEnd -DefaultMinutes 1140

    $filtConn = @($Connections | Where-Object { $null -ne $_ -and (Test-AvdTelemetryRowInWindow -Row $_ -WindowStartUtc $windowStart -WindowEndUtc $windowEnd -FilterWorkingHours $FilterWorkingHours -StartMinuteOfDay $startMin -EndMinuteOfDay $endMin -WorkingDays $WorkingDays) })
    $filtNet  = @($NetworkData | Where-Object { $null -ne $_ -and (Test-AvdTelemetryRowInWindow -Row $_ -WindowStartUtc $windowStart -WindowEndUtc $windowEnd -FilterWorkingHours $FilterWorkingHours -StartMinuteOfDay $startMin -EndMinuteOfDay $endMin -WorkingDays $WorkingDays) })
    $filtPerf = @($Perf | Where-Object { $null -ne $_ -and (Test-AvdTelemetryRowInWindow -Row $_ -WindowStartUtc $windowStart -WindowEndUtc $windowEnd -FilterWorkingHours $FilterWorkingHours -StartMinuteOfDay $startMin -EndMinuteOfDay $endMin -WorkingDays $WorkingDays) })
    $filtAh   = @($AgentHealth | Where-Object { $null -ne $_ -and (Test-AvdTelemetryRowInWindow -Row $_ -WindowStartUtc $windowStart -WindowEndUtc $windowEnd -FilterWorkingHours $FilterWorkingHours -StartMinuteOfDay $startMin -EndMinuteOfDay $endMin -WorkingDays $WorkingDays) })

    # Collect distinct hosts and sessions across filtered rows
    foreach ($r in (@($filtConn) + @($filtNet) + @($filtPerf) + @($filtAh))) {
        $hostVal = "$(Get-BenchProp $r 'SessionHostName' (Get-BenchProp $r 'Computer' ''))".Trim()
        if ($hostVal -ne '') {
            $normHost = (($hostVal -split '/')[-1] -split '\.')[0].ToLowerInvariant()
            if ($normHost -ne '') { [void]$distinctHosts.Add($normHost) }
        }
        $corrVal = "$(Get-BenchProp $r 'CorrelationId' (Get-BenchProp $r 'SessionId' ''))".Trim()
        if ($corrVal -ne '') {
            [void]$distinctSessions.Add($corrVal.ToLowerInvariant())
        }
    }

    # 1. RTT from WVDConnectionNetworkData (or WVDConnections fallback)
    $rttValues = New-Object System.Collections.Generic.List[double]
    foreach ($r in $filtNet) {
        $v = Get-BenchProp $r 'EstRoundTripTimeInMs' (Get-BenchProp $r 'RoundTripTimeMs' (Get-BenchProp $r 'RttMs'))
        if ($null -ne $v -and "$v" -ne '') {
            $d = 0.0
            if ([double]::TryParse("$v", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -ge 0) {
                $rttValues.Add($d)
            }
        }
    }
    if ($rttValues.Count -eq 0) {
        foreach ($r in $filtConn) {
            $v = Get-BenchProp $r 'EstRoundTripTimeInMs' (Get-BenchProp $r 'RoundTripTimeMs' (Get-BenchProp $r 'RttMs'))
            if ($null -ne $v -and "$v" -ne '') {
                $d = 0.0
                if ([double]::TryParse("$v", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -ge 0) {
                    $rttValues.Add($d)
                }
            }
        }
    }

    # 2. WVDConnections: TimeToConnect, ProfileLoad, VhdxAttach, Failure Rate, and Transport shares
    $ttcValues = New-Object System.Collections.Generic.List[double]
    $profileLoadValues = New-Object System.Collections.Generic.List[double]
    $vhdxAttachValues = New-Object System.Collections.Generic.List[double]
    $startedByCorr = @{}
    $connectedByCorr = @{}
    $corrOutcomes = @{}
    $transportCounts = @{ Shortpath = 0; TURN = 0; Websocket = 0; Total = 0 }
    $anonAttemptIndex = 0

    foreach ($r in $filtConn) {
        $anonAttemptIndex++
        $corr = "$(Get-BenchProp $r 'CorrelationId' '')".Trim().ToLowerInvariant()
        if ($corr -eq '') { $corr = "row-$anonAttemptIndex" }
        $state = "$(Get-BenchProp $r 'State' (Get-BenchProp $r 'Outcome' (Get-BenchProp $r 'Status' '')))".Trim()

        # Direct duration columns if present
        $ttcRaw = Get-BenchProp $r 'TimeToConnectMs' (Get-BenchProp $r 'DurationMs' (Get-BenchProp $r 'ConnectDurationMs'))
        if ($null -ne $ttcRaw -and "$ttcRaw" -ne '') {
            $d = 0.0
            if ([double]::TryParse("$ttcRaw", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -ge 0) {
                $ttcValues.Add($d)
            }
        } else {
            # Stage sum if stage columns exist
            $stageSum = 0.0
            $hasStages = $false
            foreach ($sCol in @('BrokerMs', 'TransportMs', 'AuthMs', 'ProfileLoadMs', 'GpMs', 'ShellMs')) {
                $sv = Get-BenchProp $r $sCol
                if ($null -ne $sv -and "$sv" -ne '') {
                    $sd = 0.0
                    if ([double]::TryParse("$sv", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$sd) -and $sd -ge 0) {
                        $stageSum += $sd
                        $hasStages = $true
                    }
                }
            }
            if ($hasStages -and $stageSum -gt 0) { $ttcValues.Add($stageSum) }
        }

        $profRaw = Get-BenchProp $r 'ProfileLoadMs'
        if ($null -ne $profRaw -and "$profRaw" -ne '') {
            $pd = 0.0
            if ([double]::TryParse("$profRaw", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$pd) -and $pd -ge 0) {
                $profileLoadValues.Add($pd)
            }
        }
        $vhdxRaw = Get-BenchProp $r 'VhdxAttachMs'
        if ($null -ne $vhdxRaw -and "$vhdxRaw" -ne '') {
            $vd = 0.0
            if ([double]::TryParse("$vhdxRaw", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$vd) -and $vd -ge 0) {
                $vhdxAttachValues.Add($vd)
            }
        }

        # State timestamps for Started -> Connected delta
        $rawTs = Get-BenchProp $r 'TimeGenerated'
        if ($null -ne $rawTs -and "$rawTs" -ne '') {
            $parsedTs = [datetime]::MinValue
            if ($rawTs -is [datetime]) { $parsedTs = $rawTs.ToUniversalTime() }
            elseif ([datetime]::TryParse("$rawTs", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsedTs)) {
                $parsedTs = $parsedTs.ToUniversalTime()
            }
            if ($parsedTs -gt [datetime]::MinValue) {
                if ($state -ieq 'Started') { $startedByCorr[$corr] = $parsedTs }
                elseif ($state -in @('Connected', 'Completed')) { $connectedByCorr[$corr] = $parsedTs }
            }
        }

        # Outcome tracking per correlation ID
        if ($state -in @('Connected', 'Completed', 'Success', 'Succeeded')) {
            $corrOutcomes[$corr] = 'Success'
        } elseif ($state -in @('Failed', 'Failure', 'Error')) {
            if (-not $corrOutcomes.ContainsKey($corr)) { $corrOutcomes[$corr] = 'Failed' }
        } elseif (-not $corrOutcomes.ContainsKey($corr)) {
            $corrOutcomes[$corr] = 'Started'
        }

        # Transport classification (handles UdpUse, TransportType, ClientSideTransportProtocol)
        $rawTransport = Get-BenchProp $r 'TransportType' (Get-BenchProp $r 'ClientSideTransportProtocol' (Get-BenchProp $r 'UdpUse' (Get-BenchProp $r 'TransportProtocol')))
        if ($null -ne $rawTransport -and "$rawTransport".Trim() -ne '' -and $state -notin @('Started', 'Failed', 'Failure')) {
            $normTr = Resolve-AvdTransportType -Transport "$rawTransport"
            $transportCounts[$normTr]++
            $transportCounts.Total++
        }
    }

    if ($ttcValues.Count -eq 0) {
        foreach ($corrKey in $connectedByCorr.Keys) {
            if ($startedByCorr.ContainsKey($corrKey)) {
                $deltaMs = ($connectedByCorr[$corrKey] - $startedByCorr[$corrKey]).TotalMilliseconds
                if ($deltaMs -ge 0) { $ttcValues.Add($deltaMs) }
            }
        }
    }

    $totalConnAttempts = 0
    $failedConnAttempts = 0
    foreach ($k in $corrOutcomes.Keys) {
        $outcome = $corrOutcomes[$k]
        if ($outcome -in @('Success', 'Failed')) {
            $totalConnAttempts++
            if ($outcome -eq 'Failed') { $failedConnAttempts++ }
        }
    }
    $connFailureRatePct = if ($totalConnAttempts -gt 0) { [Math]::Round(($failedConnAttempts * 100.0) / $totalConnAttempts, 2) } else { $null }
    $shortpathSharePct = if ($transportCounts.Total -gt 0) { [Math]::Round(($transportCounts.Shortpath * 100.0) / $transportCounts.Total, 2) } else { $null }
    $turnSharePct = if ($transportCounts.Total -gt 0) { [Math]::Round(($transportCounts.TURN * 100.0) / $transportCounts.Total, 2) } else { $null }

    # 3. Perf counters (Input Delay, CPU, PQL, Available Memory, Memory per Session, Disk IOPS/Latency)
    $inputDelayValues = New-Object System.Collections.Generic.List[double]
    $cpuValues = New-Object System.Collections.Generic.List[double]
    $pqlPerCoreValues = New-Object System.Collections.Generic.List[double]
    $availMemValues = New-Object System.Collections.Generic.List[double]
    $memPerSessionValues = New-Object System.Collections.Generic.List[double]
    $readIopsValues = New-Object System.Collections.Generic.List[double]
    $writeIopsValues = New-Object System.Collections.Generic.List[double]
    $readLatValues = New-Object System.Collections.Generic.List[double]
    $writeLatValues = New-Object System.Collections.Generic.List[double]

    $totalMemMiB = $MemoryGiB * 1024.0
    $activeSessionsByHost = @{}
    foreach ($ah in $filtAh) {
        $hn = "$(Get-BenchProp $ah 'SessionHostName' '')".Trim()
        $normHn = (($hn -split '/')[-1] -split '\.')[0].ToLowerInvariant()
        $act = Get-BenchProp $ah 'ActiveSessions'
        if ($normHn -ne '' -and $null -ne $act -and "$act" -match '^\d+$' -and [int]"$act" -gt 0) {
            $activeSessionsByHost[$normHn] = [int]"$act"
        }
    }

    foreach ($r in $filtPerf) {
        # Support both standard Log Analytics Perf rows (ObjectName/CounterName/CounterValue) and pre-projected metric columns
        $objName = "$(Get-BenchProp $r 'ObjectName' '')".Trim()
        $cntName = "$(Get-BenchProp $r 'CounterName' '')".Trim()
        $cntValRaw = Get-BenchProp $r 'CounterValue'
        $valNum = 0.0
        $hasVal = ($null -ne $cntValRaw -and [double]::TryParse("$cntValRaw", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$valNum))

        if ($hasVal -and $cntName -ne '') {
            if ($objName -match '(?i)User Input Delay' -or $cntName -match '(?i)Input Delay') {
                if ($valNum -ge 0) { $inputDelayValues.Add($valNum) }
            } elseif ($cntName -eq '% Processor Time' -or $cntName -ieq 'CpuPct') {
                if ($valNum -ge 0 -and $valNum -le 100) { $cpuValues.Add($valNum) }
            } elseif ($cntName -eq 'Processor Queue Length') {
                $divisor = [Math]::Max(1, $Vcpu)
                if ($valNum -ge 0) { $pqlPerCoreValues.Add([Math]::Round($valNum / $divisor, 3)) }
            } elseif ($cntName -in @('Available MBytes', 'Available MBytes Memory')) {
                if ($valNum -ge 0) {
                    $availMemValues.Add($valNum)
                    $sessCountRaw = Get-BenchProp $r 'ActiveSessions' (Get-BenchProp $r 'SessionCount')
                    $sessCount = 0
                    if ($null -ne $sessCountRaw -and [int]::TryParse("$sessCountRaw", [ref]$sessCount) -and $sessCount -gt 0) {
                        $usedMiB = [Math]::Max(0.0, $totalMemMiB - $valNum)
                        if ($usedMiB -gt 0) { $memPerSessionValues.Add([Math]::Round($usedMiB / $sessCount, 2)) }
                    } else {
                        $comp = (($("$(Get-BenchProp $r 'Computer' '')".Trim()) -split '/')[-1] -split '\.')[0].ToLowerInvariant()
                        if ($comp -ne '' -and $activeSessionsByHost.ContainsKey($comp) -and $activeSessionsByHost[$comp] -gt 0) {
                            $usedMiB = [Math]::Max(0.0, $totalMemMiB - $valNum)
                            if ($usedMiB -gt 0) { $memPerSessionValues.Add([Math]::Round($usedMiB / $activeSessionsByHost[$comp], 2)) }
                        }
                    }
                }
            } elseif ($cntName -in @('Memory Per Session MBytes', 'MemoryPerSessionMiB', 'Working Set - Private')) {
                if ($valNum -gt 0) { $memPerSessionValues.Add($valNum) }
            } elseif ($cntName -eq 'Disk Reads/sec' -or $cntName -ieq 'ReadIops') {
                if ($valNum -ge 0) { $readIopsValues.Add($valNum) }
            } elseif ($cntName -eq 'Disk Writes/sec' -or $cntName -ieq 'WriteIops') {
                if ($valNum -ge 0) { $writeIopsValues.Add($valNum) }
            } elseif ($cntName -eq 'Avg. Disk sec/Read') {
                if ($valNum -ge 0) { $readLatValues.Add([Math]::Round($valNum * 1000.0, 2)) }
            } elseif ($cntName -eq 'Avg. Disk sec/Write') {
                if ($valNum -ge 0) { $writeLatValues.Add([Math]::Round($valNum * 1000.0, 2)) }
            }
        }

        # Direct property fallbacks on synthetic Perf rows
        foreach ($direct in @(
                @{ Prop = 'InputDelayMs'; List = $inputDelayValues },
                @{ Prop = 'CpuPct'; List = $cpuValues },
                @{ Prop = 'PqlPerCore'; List = $pqlPerCoreValues },
                @{ Prop = 'AvailableMemoryMiB'; List = $availMemValues },
                @{ Prop = 'MemoryPerSessionMiB'; List = $memPerSessionValues },
                @{ Prop = 'ReadIops'; List = $readIopsValues },
                @{ Prop = 'WriteIops'; List = $writeIopsValues },
                @{ Prop = 'ReadLatencyMs'; List = $readLatValues },
                @{ Prop = 'WriteLatencyMs'; List = $writeLatValues }
            )) {
            if ($cntName -ieq $direct.Prop) { continue }
            $dv = Get-BenchProp $r $direct.Prop
            if ($null -ne $dv -and "$dv" -ne '') {
                $dd = 0.0
                if ([double]::TryParse("$dv", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$dd) -and $dd -ge 0) {
                    $direct.List.Add($dd)
                }
            }
        }
    }

    $metrics = [ordered]@{}
    if ($cpuValues.Count -gt 0)           { $metrics.cpuPct              = Get-AvdDistribution -Values $cpuValues.ToArray() }
    if ($pqlPerCoreValues.Count -gt 0)    { $metrics.pqlPerCore          = Get-AvdDistribution -Values $pqlPerCoreValues.ToArray() }
    if ($availMemValues.Count -gt 0)      { $metrics.availableMemoryMiB  = Get-AvdDistribution -Values $availMemValues.ToArray() -IncludeP10 }
    if ($memPerSessionValues.Count -gt 0) { $metrics.memoryPerSessionMiB = Get-AvdDistribution -Values $memPerSessionValues.ToArray() }
    if ($inputDelayValues.Count -gt 0)    { $metrics.inputDelayMs        = Get-AvdDistribution -Values $inputDelayValues.ToArray() }
    if ($rttValues.Count -gt 0)           { $metrics.rttMs               = Get-AvdDistribution -Values $rttValues.ToArray() }
    if ($ttcValues.Count -gt 0)           { $metrics.timeToConnectMs     = Get-AvdDistribution -Values $ttcValues.ToArray() }
    if ($profileLoadValues.Count -gt 0)   { $metrics.profileLoadMs       = Get-AvdDistribution -Values $profileLoadValues.ToArray() }
    if ($vhdxAttachValues.Count -gt 0)    { $metrics.vhdxAttachMs        = Get-AvdDistribution -Values $vhdxAttachValues.ToArray() }
    if ($readIopsValues.Count -gt 0)      { $metrics.readIops            = Get-AvdDistribution -Values $readIopsValues.ToArray() }
    if ($writeIopsValues.Count -gt 0)     { $metrics.writeIops           = Get-AvdDistribution -Values $writeIopsValues.ToArray() }
    if ($readLatValues.Count -gt 0)       { $metrics.readLatencyMs       = Get-AvdDistribution -Values $readLatValues.ToArray() }
    if ($writeLatValues.Count -gt 0)      { $metrics.writeLatencyMs      = Get-AvdDistribution -Values $writeLatValues.ToArray() }
    if ($null -ne $connFailureRatePct)    { $metrics.connectionFailureRatePct = [double]$connFailureRatePct }
    if ($null -ne $shortpathSharePct)     { $metrics.shortpathUdpSharePct     = [double]$shortpathSharePct }
    if ($null -ne $turnSharePct)          { $metrics.turnRelaySharePct        = [double]$turnSharePct }

    $hostCount = if ($distinctHosts.Count -gt 0) { $distinctHosts.Count } else { 1 }
    $sessCountFinal = if ($distinctSessions.Count -gt 0) { $distinctSessions.Count } elseif ($totalConnAttempts -gt 0) { $totalConnAttempts } else { 1 }

    return [ordered]@{
        Metrics            = $metrics
        HostCount          = $hostCount
        SessionCount       = $sessCountFinal
        SampleHostsBand    = Get-AvdSampleBand -Count $hostCount
        SampleSessionsBand = Get-AvdSampleBand -Count $sessCountFinal
        KnownNames         = @($knownNames)
        WindowEndUtc       = $windowEnd
    }
}

function Read-AvdTelemetryTable {
    param([string]$Directory, [string]$TableName)
    foreach ($sub in @('', 'insights', 'log-analytics')) {
        $baseDir = if ($sub -eq '') { $Directory } else { Join-Path $Directory $sub }
        if (-not (Test-Path -LiteralPath $baseDir)) { continue }
        foreach ($name in @($TableName, $TableName.ToLowerInvariant())) {
            $jsonPath = Join-Path $baseDir "$name.json"
            if (Test-Path -LiteralPath $jsonPath) {
                $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = $raw | ConvertFrom-Json
                    if ($null -ne (Get-BenchProp $parsed 'tables')) {
                        # Azure Monitor query REST format: { tables: [ { columns: [...], rows: [[...]] } ] }
                        $table = @($parsed.tables)[0]
                        $cols = @($table.columns | ForEach-Object { $_.name })
                        $outRows = New-Object System.Collections.Generic.List[object]
                        foreach ($r in @($table.rows)) {
                            $obj = [ordered]@{}
                            for ($i = 0; $i -lt $cols.Count; $i++) { $obj[$cols[$i]] = $r[$i] }
                            $outRows.Add([pscustomobject]$obj)
                        }
                        return $outRows.ToArray()
                    }
                    return @($parsed)
                }
            }
            $csvPath = Join-Path $baseDir "$name.csv"
            if (Test-Path -LiteralPath $csvPath) {
                return @(Import-Csv -LiteralPath $csvPath)
            }
        }
        $bundlePath = Join-Path $baseDir 'insights.json'
        if (Test-Path -LiteralPath $bundlePath) {
            $raw = [System.IO.File]::ReadAllText($bundlePath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $bundle = $raw | ConvertFrom-Json
                $tbl = Get-BenchProp $bundle $TableName
                if ($null -ne $tbl) { return @($tbl) }
            }
        }
    }
    return @()
}

function Get-AvdInsightsFact {
    <#
    .SYNOPSIS
    Computes the C11 summary Insights facts (c11.insights.rttP50, rttP95, inputDelayP95, timeToConnectP95,
    connectionFailureRate, and optional fslogixReadIopsP95) from collected Log Analytics telemetry.
    Returns $null (omitted / unknown) when Log Analytics telemetry was not collected.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Directory = '',

        [Parameter(Mandatory = $false)]
        [object[]]$Connections = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$NetworkData = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$Perf = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$AgentHealth = @(),

        [Parameter(Mandatory = $false)]
        [int]$WindowDays = 7,

        [Parameter(Mandatory = $false)]
        [string]$WorkingHoursStart = '07:00',

        [Parameter(Mandatory = $false)]
        [string]$WorkingHoursEnd = '19:00',

        [Parameter(Mandatory = $false)]
        [string[]]$WorkingDays = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri'),

        [Parameter(Mandatory = $false)]
        [bool]$FilterWorkingHours = $true,

        [Parameter(Mandatory = $false)]
        [nullable[datetime]]$ReferenceTime = $null
    )
    $connRows = @($Connections)
    $netRows  = @($NetworkData)
    $perfRows = @($Perf)
    $ahRows   = @($AgentHealth)

    if ($Directory -ne '' -and (Test-Path -LiteralPath $Directory)) {
        if ($connRows.Count -eq 0) { $connRows = @(Read-AvdTelemetryTable -Directory $Directory -TableName 'WVDConnections') }
        if ($netRows.Count -eq 0)  { $netRows  = @(Read-AvdTelemetryTable -Directory $Directory -TableName 'WVDConnectionNetworkData') }
        if ($perfRows.Count -eq 0) { $perfRows = @(Read-AvdTelemetryTable -Directory $Directory -TableName 'Perf') }
        if ($ahRows.Count -eq 0)   { $ahRows   = @(Read-AvdTelemetryTable -Directory $Directory -TableName 'WVDAgentHealthStatus') }
    }

    if ($connRows.Count -eq 0 -and $netRows.Count -eq 0 -and $perfRows.Count -eq 0 -and $ahRows.Count -eq 0) {
        return $null
    }

    $measured = Measure-AvdInsightsTelemetry -Connections $connRows -NetworkData $netRows -Perf $perfRows -AgentHealth $ahRows `
        -WindowDays $WindowDays -WorkingHoursStart $WorkingHoursStart -WorkingHoursEnd $WorkingHoursEnd `
        -WorkingDays $WorkingDays -FilterWorkingHours $FilterWorkingHours -ReferenceTime $ReferenceTime
    $m = $measured.Metrics
    if ($m.Keys.Count -eq 0) { return $null }

    $facts = [ordered]@{}
    if ($null -ne (Get-BenchProp $m 'rttMs')) {
        $facts.rttP50 = Get-BenchProp $m.rttMs 'p50'
        $facts.rttP95 = Get-BenchProp $m.rttMs 'p95'
    }
    if ($null -ne (Get-BenchProp $m 'inputDelayMs')) {
        $facts.inputDelayP95 = Get-BenchProp $m.inputDelayMs 'p95'
    }
    if ($null -ne (Get-BenchProp $m 'timeToConnectMs')) {
        $facts.timeToConnectP95 = Get-BenchProp $m.timeToConnectMs 'p95'
    }
    if ($null -ne (Get-BenchProp $m 'connectionFailureRatePct')) {
        $facts.connectionFailureRate = [double]$m.connectionFailureRatePct
    }
    if ($null -ne (Get-BenchProp $m 'readIops')) {
        $facts.fslogixReadIopsP95 = Get-BenchProp $m.readIops 'p95'
    }
    if ($facts.Keys.Count -eq 0) { return $null }
    return $facts
}

function ConvertFrom-AvdInsightsTelemetry {
    <#
    .SYNOPSIS
    Converts read-only AVD Insights / Log Analytics telemetry (WVDConnections, WVDConnectionNetworkData, Perf,
    WVDAgentHealthStatus) into a schema-valid, strictly redacted Contract C25 (avd-benchmark-result/v1) object.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Connections = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$NetworkData = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$Perf = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$AgentHealth = @(),

        [Parameter(Mandatory = $false)]
        [ValidateSet('estate', 'lab', 'sandbox')]
        [string]$Source = 'estate',

        [Parameter(Mandatory = $false)]
        [bool]$Consent = $true,

        [Parameter(Mandatory = $false)]
        [string]$VmSku = 'Standard_D8s_v5',

        [Parameter(Mandatory = $false)]
        [int]$Vcpu = 0,

        [Parameter(Mandatory = $false)]
        [double]$MemoryGiB = 0,

        [Parameter(Mandatory = $false)]
        [string]$OsDiskType = 'Premium_LRS',

        [Parameter(Mandatory = $false)]
        [string]$JoinType = 'entra-joined',

        [Parameter(Mandatory = $false)]
        [string]$ProfileStorageSku = '',

        [Parameter(Mandatory = $false)]
        [string]$ProfileAuth = '',

        [Parameter(Mandatory = $false)]
        [string]$SmbChannelEncryption = '',

        [Parameter(Mandatory = $false)]
        [string]$NetworkEgress = '',

        [Parameter(Mandatory = $false)]
        [string]$WorkloadClass = '',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 365)]
        [int]$WindowDays = 7,

        [Parameter(Mandatory = $false)]
        [string]$WorkingHoursStart = '07:00',

        [Parameter(Mandatory = $false)]
        [string]$WorkingHoursEnd = '19:00',

        [Parameter(Mandatory = $false)]
        [string[]]$WorkingDays = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri'),

        [Parameter(Mandatory = $false)]
        [bool]$FilterWorkingHours = $true,

        [Parameter(Mandatory = $false)]
        [nullable[datetime]]$ReferenceTime = $null,

        [Parameter(Mandatory = $false)]
        [string]$Date = '',

        [Parameter(Mandatory = $false)]
        [string]$AssessCommit = '',

        [Parameter(Mandatory = $false)]
        [string[]]$ExtraKnownNames = @()
    )
    if ($Source -eq 'estate' -and -not $Consent) {
        throw 'Exporting an estate benchmark result (Contract C25) requires explicit owner consent (-Consent).'
    }

    $skuSpec = Resolve-AvdPublicVmSku -VmSku $VmSku -Vcpu $Vcpu -MemoryGiB $MemoryGiB
    $resolvedJoin = Resolve-AvdJoinType -JoinType $JoinType
    $resolvedDisk = Resolve-AvdOsDiskType -OsDiskType $OsDiskType

    $measured = Measure-AvdInsightsTelemetry -Connections $Connections -NetworkData $NetworkData -Perf $Perf -AgentHealth $AgentHealth `
        -WindowDays $WindowDays -WorkingHoursStart $WorkingHoursStart -WorkingHoursEnd $WorkingHoursEnd `
        -WorkingDays $WorkingDays -FilterWorkingHours $FilterWorkingHours -ReferenceTime $ReferenceTime `
        -Vcpu $skuSpec.vcpu -MemoryGiB $skuSpec.memoryGiB

    if ($measured.Metrics.Keys.Count -eq 0) {
        throw 'No valid telemetry metrics found in the supplied Insights tables for the selected window.'
    }

    $resolvedCommit = "$AssessCommit".Trim().ToLowerInvariant()
    if ($resolvedCommit -notmatch '^[0-9a-f]{40}$') {
        $pinsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'assess/PINS.json'
        if (Test-Path -LiteralPath $pinsPath) {
            $pinsObj = Get-Content -LiteralPath $pinsPath -Raw | ConvertFrom-Json
            $resolvedCommit = "$($pinsObj.commit)".Trim().ToLowerInvariant()
        }
        if ($resolvedCommit -notmatch '^[0-9a-f]{40}$') {
            $resolvedCommit = 'cfcc3026b968c3c15a4150b8c7160891a138d3f0'
        }
    }

    $resolvedDate = "$Date".Trim()
    if ($resolvedDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
        $resolvedDate = $measured.WindowEndUtc.ToString('yyyy-MM-dd')
    }
    $dateCompact = $resolvedDate -replace '-', ''
    $skuSlug = ($skuSpec.vmSku -replace '^Standard_', '' -replace '_', '').ToLowerInvariant()
    $benchId = "bm-$dateCompact-insights-observational-$skuSlug"

    $profileObj = [ordered]@{
        id           = 'insights-observational'
        version      = '1.0.0'
        assessCommit = $resolvedCommit
    }
    if ($WorkloadClass -in @('light', 'medium', 'heavy', 'power')) {
        $profileObj.workloadClass = $WorkloadClass
    }

    $envObj = [ordered]@{
        vmSku              = $skuSpec.vmSku
        vcpu               = [int]$skuSpec.vcpu
        memoryGiB          = [double]$skuSpec.memoryGiB
        osDiskType         = $resolvedDisk
        joinType           = $resolvedJoin
        sampleHostsBand    = $measured.SampleHostsBand
        sampleSessionsBand = $measured.SampleSessionsBand
        windowHours        = [int]($WindowDays * 24)
    }
    if ($ProfileStorageSku -in @('Premium_ZRS', 'Premium_LRS', 'Standard_ZRS', 'Standard_LRS', 'Standard_GZRS', 'Standard_GRS', 'ANF_Standard', 'ANF_Premium', 'ANF_Ultra', 'none')) {
        $envObj.profileStorageSku = $ProfileStorageSku
    }
    if ($ProfileAuth -in @('entra-kerberos', 'ad-ds', 'entra-ds', 'none')) {
        $envObj.profileAuth = $ProfileAuth
    }
    if ($SmbChannelEncryption -in @('AES-128-GCM+AES-256-GCM', 'AES-256-GCM-only', 'includes-CCM', 'default', 'none')) {
        $envObj.smbChannelEncryption = $SmbChannelEncryption
    }
    if ($NetworkEgress -in @('nat-gateway', 'azure-firewall', 'nva', 'default-outbound', 'public-ip', 'private-link')) {
        $envObj.networkEgress = $NetworkEgress
    }

    $gate = Get-AvdExperienceGate -Metrics $measured.Metrics
    $claims = New-Object System.Collections.Generic.List[object]

    $rttDist = Get-BenchProp $measured.Metrics 'rttMs'
    if ($null -ne $rttDist) {
        $rttVerdict = if ([double]$rttDist.p95 -lt 150.0) { 'agrees' } else { 'extends' }
        $claims.Add([ordered]@{
            claim   = 'ref:avd-prerequisites#rtt-under-150'
            verdict = $rttVerdict
        })
    }
    $inDist = Get-BenchProp $measured.Metrics 'inputDelayMs'
    if ($null -ne $inDist) {
        $inVerdict = if ([double]$inDist.p95 -lt 150.0) { 'agrees' } else { 'extends' }
        $claims.Add([ordered]@{
            claim   = 'ref:avd-insights-glossary#input-delay-bands'
            verdict = $inVerdict
        })
    }
    $turnShare = Get-BenchProp $measured.Metrics 'turnRelaySharePct'
    if ($null -ne $turnShare) {
        $claims.Add([ordered]@{
            claim       = 'ref:rdp-shortpath#symmetric-nat-means-turn'
            observation = 'obs:symmetric-nat-egress-means-turn'
            verdict     = $(if ([double]$turnShare -gt 0) { 'agrees' } else { 'extends' })
        })
    }
    $claims.Add([ordered]@{
        claim   = 'gap:insights-facts'
        verdict = 'agrees'
    })
    $claims.Add([ordered]@{
        claim   = 'gap:baseline-profile'
        verdict = 'agrees'
    })

    $result = [ordered]@{
        schema  = 'avd-benchmark-result/v1'
        id      = $benchId
        date    = $resolvedDate
        source  = $Source
    }
    if ($Source -eq 'estate' -or $Consent) {
        $result.consent = [bool]$Consent
    }
    $result.tier        = 'observational'
    $result.profile     = $profileObj
    $result.environment = $envObj
    $result.metrics     = $measured.Metrics
    $result.verdict     = [ordered]@{
        experienceGate = $gate
        claims         = $claims.ToArray()
    }

    $allKnownNames = @($measured.KnownNames) + @($ExtraKnownNames)
    $leaks = @(Find-AvdBenchmarkLeak -Node $result -KnownNames $allKnownNames)
    if ($leaks.Count -gt 0) {
        throw "Refusing to emit Contract C25 benchmark evidence: leak scan flagged $($leaks -join '; ')."
    }

    return $result
}

Export-ModuleMember -Function @(
    'Get-AvdSampleBand',
    'Get-AvdPercentileValue',
    'Get-AvdDistribution',
    'Resolve-AvdPublicVmSku',
    'Resolve-AvdJoinType',
    'Resolve-AvdTransportType',
    'Resolve-AvdOsDiskType',
    'Test-AvdTelemetryRowInWindow',
    'Get-AvdExperienceGate',
    'Get-AvdInsightsKqlQuery',
    'Find-AvdBenchmarkLeak',
    'Read-AvdTelemetryTable',
    'Get-AvdInsightsFact',
    'ConvertFrom-AvdInsightsTelemetry'
)
