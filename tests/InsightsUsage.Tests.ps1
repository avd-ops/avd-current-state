#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for Contract C27 (avd-measured-usage/v1) Tier 2 AVD Insights measured-usage exporter (Export-AvdInsightsUsage.ps1).

BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:exporter = Join-Path $script:root 'Export-AvdInsightsUsage.ps1'
    $script:schema = Join-Path $script:root 'contracts/measured-usage.schema.json'
}

Describe 'Contract C27 Tier 2 Measured-Usage Exporter (Export-AvdInsightsUsage.ps1)' {
    It 'exports a schema-valid avd-measured-usage/v1 JSON document in SyntheticMode' {
        $outFile = Join-Path $TestDrive 'measured-usage-synthetic.json'
        $written = & $script:exporter -OutputPath $outFile -EstateId 'est-3fa2c1d0' -SourcePoolId 'hp-89ab12cd' -LookbackDays 21 -SyntheticMode
        $written | Should -Be $outFile
        $written | Should -Exist

        $raw = Get-Content -LiteralPath $outFile -Raw
        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            $errs = $null
            Test-Json -Json $raw -SchemaFile $script:schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
        }

        $doc = $raw | ConvertFrom-Json
        $doc.schema | Should -Be 'avd-measured-usage/v1'
        $doc.tier | Should -Be 'tier-2-insights'
        $doc.estate | Should -Be 'est-3fa2c1d0'
        $doc.measurementGate.daysObserved | Should -Be 21
        $doc.measurementGate.passed | Should -BeTrue
        $doc.groups.Count | Should -Be 1
        $doc.groups[0].id | Should -Be 'grp-01'
        $doc.groups[0].sourcePoolId | Should -Be 'hp-89ab12cd'
        $doc.groups[0].userCount | Should -BeGreaterOrEqual 10
        $doc.groups[0].hourlyConcurrency.Count | Should -Be 24
    }

    It 'derives percentiles and concurrency from collected Insights telemetry and strips all tenant/host/user identifiers' {
        $inDir = Join-Path $TestDrive 'pkg-insights'
        New-Item -ItemType Directory -Path $inDir -Force | Out-Null

        @{
            TenantId            = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
            Identity            = 'admin@contoso.com'
            SubscriptionName    = 'Contoso Prod'
            SubscriptionId      = '11111111-2222-4333-8444-555555555555'
        } | ConvertTo-Json | Set-Content (Join-Path $inDir 'manifest.json')

        $conns = @(1..15 | ForEach-Object {
            [pscustomobject]@{
                TimeGenerated   = ('2026-10-28T14:{0:d2}:00Z' -f $_)
                CorrelationId   = ('{0:d8}-1111-4222-8333-{0:d12}' -f $_)
                State           = 'Connected'
                SessionHostName = 'sh-contoso-01.contoso.com'
                UserName        = ("user{0}@contoso.com" -f $_)
                TimeToConnectMs = (12000 + ($_ * 200))
            }
        })
        $net = @(1..15 | ForEach-Object {
            [pscustomobject]@{
                TimeGenerated        = ('2026-10-28T14:{0:d2}:00Z' -f $_)
                CorrelationId        = ('{0:d8}-1111-4222-8333-{0:d12}' -f $_)
                SessionHostName      = 'sh-contoso-01.contoso.com'
                EstRoundTripTimeInMs = (24.0 + $_)
            }
        })
        $perf = @(1..15 | ForEach-Object {
            [pscustomobject]@{
                TimeGenerated = ('2026-10-28T14:{0:d2}:00Z' -f $_)
                Computer      = 'sh-contoso-01.contoso.com'
                ObjectName    = 'LogicalDisk'
                CounterName   = 'Disk Reads/sec'
                InstanceName  = 'C:'
                CounterValue  = (14.0 + $_)
            }
        })

        $conns | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $inDir 'WVDConnections.json')
        $net   | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $inDir 'WVDConnectionNetworkData.json')
        $perf  | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $inDir 'Perf.json')

        $outFile = Join-Path $TestDrive 'measured-usage-from-pkg.json'
        & $script:exporter -InputPath $inDir -OutputPath $outFile -EstateId 'est-0a1b2c3d' -SourcePoolId 'hp-2b3c4d5e' | Out-Null

        $raw = Get-Content -LiteralPath $outFile -Raw
        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            $errs = $null
            Test-Json -Json $raw -SchemaFile $script:schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
        }

        $doc = $raw | ConvertFrom-Json
        $doc.groups[0].userCount | Should -Be 15
        $doc.groups[0].peakConcurrency | Should -Be 12
        $doc.groups[0].rttMsByRegion.eastus2.p95 | Should -BeGreaterThan 24
        $raw | Should -Not -Match 'contoso'
        $raw | Should -Not -Match '11111111-2222-4333-8444-555555555555'
        $raw | Should -Not -Match 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
    }
}
