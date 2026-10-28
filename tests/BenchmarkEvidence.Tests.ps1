#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for Tier 2 observational benchmark export (Export-AvdBenchmarkEvidence.ps1, lib/AvdBenchmark.psm1)
# and C11 summary Insights fact calculation (avd_current_state_facts.ps1).

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:root 'lib/AvdBenchmark.psm1') -Force
    $script:exporterScript = Join-Path $script:root 'Export-AvdBenchmarkEvidence.ps1'
    $script:factsScript = Join-Path $script:root 'avd_current_state_facts.ps1'
    $script:c25Schema = Join-Path $script:root 'contracts/benchmark-result.schema.json'

    function New-SyntheticInsightsFixtures {
        param(
            [double]$RttBaseMs = 28.0,
            [double]$RttSpikeMs = 74.0,
            [double]$InputDelayBaseMs = 22.0,
            [double]$InputDelaySpikeMs = 68.0
        )
        # 20 samples inside working hours (Wednesday 2026-10-28 14:00..15:35 UTC) + 1 weekend outlier outside working hours
        $conns = New-Object System.Collections.Generic.List[object]
        $net   = New-Object System.Collections.Generic.List[object]
        $perf  = New-Object System.Collections.Generic.List[object]
        $ah    = New-Object System.Collections.Generic.List[object]

        for ($i = 1; $i -le 20; $i++) {
            $corrId = ('{0:d8}-1111-4222-8333-{1:d12}' -f $i, ($i * 100))
            $hostFqdn = ('sh-avd-prod-{0:d2}.contoso.com' -f (($i % 4) + 1))
            $userUpn = ("user{0}@contoso.com" -f $i)
            $ts = ('2026-10-28T14:{0:d2}:00Z' -f ($i * 2))
            $isSpike = ($i -ge 19)

            $rttVal = if ($isSpike) { $RttSpikeMs } else { $RttBaseMs + ($i % 5) }
            $inDelayVal = if ($isSpike) { $InputDelaySpikeMs } else { $InputDelayBaseMs + ($i % 6) }
            $ttcVal = if ($isSpike) { 24000 } else { 11000 + ($i * 200) }
            $profVal = if ($isSpike) { 6500 } else { 3200 + ($i * 50) }
            $vhdxVal = if ($isSpike) { 1800 } else { 850 + ($i * 10) }
            $transport = if ($i -le 16) { 'Shortpath' } elseif ($i -le 19) { 'TURN' } else { 'Websocket' }
            $state = if ($i -eq 20) { 'Failed' } else { 'Connected' }

            $conns.Add([pscustomobject]@{
                TimeGenerated               = $ts
                CorrelationId               = $corrId
                State                       = $state
                SessionHostName             = $hostFqdn
                UserName                    = $userUpn
                ClientSideIPAddress         = "198.51.100.$i"
                ClientSideTransportProtocol = $transport
                TimeToConnectMs             = $ttcVal
                ProfileLoadMs               = $profVal
                VhdxAttachMs                = $vhdxVal
                _ResourceId                 = "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-avd-prod/providers/Microsoft.DesktopVirtualization/hostpools/hp-contoso-prod"
            })

            $net.Add([pscustomobject]@{
                TimeGenerated             = $ts
                CorrelationId             = $corrId
                SessionHostName           = $hostFqdn
                EstRoundTripTimeInMs      = $rttVal
                EstAvailableBandwidthKBps = 25000
            })

            $perf.Add([pscustomobject]@{
                TimeGenerated = $ts
                Computer      = $hostFqdn
                ObjectName    = 'User Input Delay per Session'
                CounterName   = 'Max Input Delay'
                InstanceName  = 'Max'
                CounterValue  = $inDelayVal
            })
            $perf.Add([pscustomobject]@{
                TimeGenerated = $ts
                Computer      = $hostFqdn
                ObjectName    = 'Processor Information'
                CounterName   = '% Processor Time'
                InstanceName  = '_Total'
                CounterValue  = (45.0 + $i)
            })
            $perf.Add([pscustomobject]@{
                TimeGenerated = $ts
                Computer      = $hostFqdn
                ObjectName    = 'System'
                CounterName   = 'Processor Queue Length'
                InstanceName  = ''
                CounterValue  = $(if ($isSpike) { 8.0 } else { 4.0 })
            })
            $perf.Add([pscustomobject]@{
                TimeGenerated  = $ts
                Computer       = $hostFqdn
                ObjectName     = 'Memory'
                CounterName    = 'Available MBytes'
                InstanceName   = ''
                CounterValue   = (16384 - ($i * 100))
                ActiveSessions = 12
            })
            $perf.Add([pscustomobject]@{
                TimeGenerated = $ts
                Computer      = $hostFqdn
                ObjectName    = 'LogicalDisk'
                CounterName   = 'Disk Reads/sec'
                InstanceName  = 'C:'
                CounterValue  = (20.0 + $i)
            })
        }

        # Add a Sunday 03:00 UTC outlier that should be excluded by working-hours filtering
        $net.Add([pscustomobject]@{
            TimeGenerated        = '2026-10-25T03:00:00Z'
            CorrelationId        = '99999999-1111-4222-8333-999999999999'
            SessionHostName      = 'sh-avd-prod-01.contoso.com'
            EstRoundTripTimeInMs = 999.0
        })

        for ($h = 1; $h -le 4; $h++) {
            $ah.Add([pscustomobject]@{
                TimeGenerated   = '2026-10-28T15:00:00Z'
                SessionHostName = ('sh-avd-prod-{0:d2}.contoso.com' -f $h)
                Status          = 'Available'
                ActiveSessions  = 12
                AgentVersion    = '1.0.8543.1200'
            })
        }

        return @{
            Connections = $conns.ToArray()
            NetworkData = $net.ToArray()
            Perf        = $perf.ToArray()
            AgentHealth = $ah.ToArray()
        }
    }
}

Describe 'Sample count banding (Get-AvdSampleBand)' {
    It 'maps host and session counts into the 5 closed Contract C25 sample bands' {
        Get-AvdSampleBand -Count 0   | Should -BeNullOrEmpty
        Get-AvdSampleBand -Count 1   | Should -Be '1-2'
        Get-AvdSampleBand -Count 2   | Should -Be '1-2'
        Get-AvdSampleBand -Count 3   | Should -Be '3-9'
        Get-AvdSampleBand -Count 9   | Should -Be '3-9'
        Get-AvdSampleBand -Count 10  | Should -Be '10-25'
        Get-AvdSampleBand -Count 25  | Should -Be '10-25'
        Get-AvdSampleBand -Count 26  | Should -Be '26-100'
        Get-AvdSampleBand -Count 100 | Should -Be '26-100'
        Get-AvdSampleBand -Count 101 | Should -Be '100+'
        Get-AvdSampleBand -Count 450 | Should -Be '100+'
    }
}

Describe 'Percentile calculation (Get-AvdPercentileValue and Get-AvdDistribution)' {
    It 'computes exact p10, p50, p90, p95, p99, min, and max over numeric distributions' {
        $series = 1..100
        $dist = Get-AvdDistribution -Values $series -IncludeP10
        $dist.min | Should -Be 1
        $dist.p10 | Should -Be 10.9
        $dist.p50 | Should -Be 50.5
        $dist.p90 | Should -Be 90.1
        $dist.p95 | Should -Be 95.05
        $dist.p99 | Should -Be 99.01
        $dist.max | Should -Be 100
    }

    It 'computes Started-to-Connected duration when WVDConnections uses state transitions' {
        $rows = @(
            [pscustomobject]@{ TimeGenerated = '2026-10-28T10:00:00Z'; CorrelationId = 'c1'; State = 'Started'; SessionHostName = 'sh01.contoso.com' }
            [pscustomobject]@{ TimeGenerated = '2026-10-28T10:00:15Z'; CorrelationId = 'c1'; State = 'Connected'; SessionHostName = 'sh01.contoso.com'; TransportType = 'Shortpath' }
            [pscustomobject]@{ TimeGenerated = '2026-10-28T10:05:00Z'; CorrelationId = 'c2'; State = 'Started'; SessionHostName = 'sh02.contoso.com' }
            [pscustomobject]@{ TimeGenerated = '2026-10-28T10:05:25Z'; CorrelationId = 'c2'; State = 'Connected'; SessionHostName = 'sh02.contoso.com'; TransportType = 'TURN' }
        )
        $c25 = ConvertFrom-AvdInsightsTelemetry -Connections $rows -Source 'lab' -VmSku 'Standard_E4s_v5'
        $c25.metrics.timeToConnectMs.min | Should -Be 15000
        $c25.metrics.timeToConnectMs.max | Should -Be 25000
        $c25.metrics.timeToConnectMs.p50 | Should -Be 20000
        $c25.metrics.shortpathUdpSharePct | Should -Be 50
        $c25.metrics.turnRelaySharePct | Should -Be 50
        $c25.environment.sampleHostsBand | Should -Be '1-2'
        $c25.environment.sampleSessionsBand | Should -Be '1-2'
    }
}

Describe 'Tier 2 Observational Benchmark Exporter (Export-AvdBenchmarkEvidence.ps1)' {
    It 'exports a schema-valid, strictly redacted Contract C25 JSON file and filters working hours' {
        $fx = New-SyntheticInsightsFixtures -RttBaseMs 28.0 -RttSpikeMs 74.0 -InputDelayBaseMs 22.0 -InputDelaySpikeMs 68.0
        $inDir = Join-Path $TestDrive 'insights-pkg'
        $outDir = Join-Path $TestDrive 'out-c25'
        New-Item -ItemType Directory -Path $inDir -Force | Out-Null

        $fx.Connections | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $inDir 'WVDConnections.json')
        $fx.NetworkData | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $inDir 'WVDConnectionNetworkData.json')
        $fx.Perf        | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $inDir 'Perf.json')
        $fx.AgentHealth | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $inDir 'WVDAgentHealthStatus.json')

        $writtenFile = & $script:exporterScript -InputPath $inDir -OutputPath $outDir -Source 'estate' -Consent $true `
            -VmSku 'Standard_D8s_v5' -JoinType 'entra-joined' -ProfileStorageSku 'Premium_ZRS' -Date '2026-10-28'

        $writtenFile | Should -Exist
        $rawJson = Get-Content -LiteralPath $writtenFile -Raw

        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            $errs = $null
            Test-Json -Json $rawJson -SchemaFile $script:c25Schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
        }

        $doc = $rawJson | ConvertFrom-Json
        $doc.schema | Should -Be 'avd-benchmark-result/v1'
        $doc.id | Should -Be 'bm-20261028-insights-observational-d8sv5'
        $doc.tier | Should -Be 'observational'
        $doc.source | Should -Be 'estate'
        $doc.consent | Should -BeTrue
        $doc.profile.id | Should -Be 'insights-observational'
        $doc.environment.vmSku | Should -Be 'Standard_D8s_v5'
        $doc.environment.vcpu | Should -Be 8
        $doc.environment.memoryGiB | Should -Be 32
        $doc.environment.joinType | Should -Be 'entra-joined'
        $doc.environment.sampleHostsBand | Should -Be '3-9'
        $doc.environment.sampleSessionsBand | Should -Be '10-25'

        # Verify weekend 999ms RTT outlier was filtered out by working hours
        $doc.metrics.rttMs.max | Should -Be 74
        $doc.metrics.rttMs.p95 | Should -BeLessThan 150
        $doc.metrics.inputDelayMs.p95 | Should -BeLessThan 150
        $doc.metrics.cpuPct.p50 | Should -BeGreaterThan 45
        $doc.metrics.pqlPerCore.p95 | Should -Be 1
        $doc.metrics.memoryPerSessionMiB.p50 | Should -BeGreaterThan 1000
        $doc.metrics.timeToConnectMs.p95 | Should -BeGreaterThan 14000
        $doc.metrics.profileLoadMs.p95 | Should -BeGreaterThan 4000
        $doc.metrics.vhdxAttachMs.p95 | Should -BeGreaterThan 1000
        $doc.metrics.connectionFailureRatePct | Should -Be 5
        $doc.verdict.experienceGate | Should -Be 'pass'

        # Verify zero GUIDs, hostnames, usernames, domains, or IPs in the emitted C25 JSON
        $rawJson | Should -Not -Match 'contoso\.com'
        $rawJson | Should -Not -Match 'sh-avd-prod'
        $rawJson | Should -Not -Match 'user\d+'
        $rawJson | Should -Not -Match '198\.51\.100'
        $rawJson | Should -Not -Match '11111111-2222-3333-4444-555555555555'
        $rawJson | Should -Not -Match 'rg-avd-prod'
        $rawJson | Should -Not -Match 'hp-contoso-prod'
    }

    It 'evaluates experienceGate as fail when RTT p95 >= 150ms or input delay p95 >= 150ms' {
        $highRtt = New-SyntheticInsightsFixtures -RttBaseMs 155.0 -RttSpikeMs 210.0 -InputDelayBaseMs 25.0 -InputDelaySpikeMs 45.0
        $c25RttFail = ConvertFrom-AvdInsightsTelemetry -Connections $highRtt.Connections -NetworkData $highRtt.NetworkData -Perf $highRtt.Perf -Source 'lab'
        $c25RttFail.metrics.rttMs.p95 | Should -BeGreaterOrEqual 150
        $c25RttFail.verdict.experienceGate | Should -Be 'fail'

        $highInput = New-SyntheticInsightsFixtures -RttBaseMs 30.0 -RttSpikeMs 55.0 -InputDelayBaseMs 160.0 -InputDelaySpikeMs 240.0
        $c25InputFail = ConvertFrom-AvdInsightsTelemetry -Connections $highInput.Connections -NetworkData $highInput.NetworkData -Perf $highInput.Perf -Source 'lab'
        $c25InputFail.metrics.inputDelayMs.p95 | Should -BeGreaterOrEqual 150
        $c25InputFail.verdict.experienceGate | Should -Be 'fail'
    }

    It 'refuses estate export without owner consent and catches injected leaks in Find-AvdBenchmarkLeak' {
        $fx = New-SyntheticInsightsFixtures
        { ConvertFrom-AvdInsightsTelemetry -Connections $fx.Connections -NetworkData $fx.NetworkData -Perf $fx.Perf -Source 'estate' -Consent $false } | Should -Throw '*consent*'

        $leaksGuid = @(Find-AvdBenchmarkLeak -Node @{ field = '11111111-2222-3333-4444-555555555555' })
        $leaksGuid | Should -Match '^guid at'

        $leaksEmail = @(Find-AvdBenchmarkLeak -Node @{ field = 'alice@contoso.com' })
        $leaksEmail | Should -Match '^email at'

        $leaksUnc = @(Find-AvdBenchmarkLeak -Node @{ field = '\\stcontoso.file.core.windows.net\profiles' })
        $leaksUnc | Should -Match '^unc-path at'

        $leaksIp = @(Find-AvdBenchmarkLeak -Node @{ field = '10.20.30.40' })
        $leaksIp | Should -Match '^ip-address at'

        $leaksKnown = @(Find-AvdBenchmarkLeak -Node @{ field = 'host sh-avd-prod-01 metric' } -KnownNames @('sh-avd-prod-01'))
        $leaksKnown | Should -Match '^known-name at'
    }
}

Describe 'C11 Summary Insights Facts & Read-Only KQL Queries' {
    It 'computes c11.insights.* summary facts when telemetry is present and degrades to null when absent' {
        $emptyDir = Join-Path $TestDrive 'no-insights'
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
        Get-AvdInsightsFact -Directory $emptyDir | Should -BeNullOrEmpty

        $fx = New-SyntheticInsightsFixtures -RttBaseMs 28.0 -RttSpikeMs 74.0 -InputDelayBaseMs 22.0 -InputDelaySpikeMs 68.0
        $facts = Get-AvdInsightsFact -Connections $fx.Connections -NetworkData $fx.NetworkData -Perf $fx.Perf -AgentHealth $fx.AgentHealth
        $facts | Should -Not -BeNullOrEmpty
        $facts.rttP50 | Should -BeGreaterThan 25
        $facts.rttP95 | Should -BeLessThan 150
        $facts.inputDelayP95 | Should -BeLessThan 150
        $facts.timeToConnectP95 | Should -BeGreaterThan 14000
        $facts.connectionFailureRate | Should -Be 5
        $facts.fslogixReadIopsP95 | Should -BeGreaterThan 35
    }

    It 'integrates with avd_current_state_facts.ps1 when insights/ is present and omits insights when absent' {
        $fx = New-SyntheticInsightsFixtures -RttBaseMs 28.0 -RttSpikeMs 74.0 -InputDelayBaseMs 22.0 -InputDelaySpikeMs 68.0
        $pkgDir = Join-Path $TestDrive 'collector-with-insights'
        $subDir = Join-Path $pkgDir 'Contoso_Prod'
        $insDir = Join-Path $pkgDir 'insights'
        New-Item -ItemType Directory -Path $subDir, $insDir -Force | Out-Null

        @{
            GeneratedUtc        = '2026-10-28T16:00:00Z'
            TenantId            = '11111111-1111-4111-8111-111111111111'
            Identity            = 'reader@contoso.com'
            SubscriptionDetails = @(
                @{ SubscriptionName = 'Contoso Prod'; SubscriptionId = '22222222-2222-4222-8222-222222222222'; Status = 'Collected' }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $pkgDir 'manifest.json')
        @(@{ Name = 'rg-avd'; Location = 'eastus2' }) | ConvertTo-Json | Set-Content (Join-Path $subDir 'resource-groups.json')

        $fx.Connections | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $insDir 'WVDConnections.json')
        $fx.NetworkData | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $insDir 'WVDConnectionNetworkData.json')
        $fx.Perf        | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $insDir 'Perf.json')

        $keyPath = Join-Path $TestDrive 'estate.key'
        $outDir = Join-Path $TestDrive 'facts-out'
        $snapFile = & $script:factsScript -PackagePath $pkgDir -KeyPath $keyPath -NewKey -OutputPath $outDir 6>$null
        $snap = Get-Content -LiteralPath $snapFile -Raw | ConvertFrom-Json
        $snap.insights | Should -Not -BeNullOrEmpty
        $snap.insights.rttP50 | Should -BeGreaterThan 25
        $snap.insights.rttP95 | Should -BeLessThan 150
        $snap.insights.inputDelayP95 | Should -BeLessThan 150
        $snap.insights.timeToConnectP95 | Should -BeGreaterThan 14000
        $snap.insights.connectionFailureRate | Should -Be 5
    }

    It 'builds strictly read-only KQL queries for the four Log Analytics tables' {
        $queries = Get-AvdInsightsKqlQuery -WindowDays 14
        @($queries.Keys) | Should -Be @('WVDConnections', 'WVDConnectionNetworkData', 'Perf', 'WVDAgentHealthStatus')
        foreach ($q in $queries.Values) {
            $q | Should -Match 'where TimeGenerated >= ago\(14d\)'
            $q | Should -Match '\|\s*project\b'
            $q | Should -Not -Match '(?i)\b(\.set|\.append|\.drop|\.delete|\.alter|\.create)\b'
        }
    }
}
