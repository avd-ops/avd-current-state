#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for lightweight daily snapshot mode (-Mode Summary / -Light) in lib/AvdSummary.psm1 and avd_current_state_collector.ps1.

Describe 'collector: lightweight summary mode' {
  BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:pwsh = (Get-Process -Id $PID).Path
    Import-Module (Join-Path $script:root 'lib/AvdRebuild.psm1') -Force
    Import-Module (Join-Path $script:root 'lib/AvdSummary.psm1') -Force
  }

  It 'defines all required read-only Resource Graph queries' {
    $q = Get-AvdSummaryQueryMap
    $q.ResourceCountsByType | Should -Match 'tolower\(type\)'
    $q.VirtualMachines      | Should -Match 'project name, resourceGroup, vmSize, powerState'
    $q.HostPools            | Should -Match 'hostPoolType, loadBalancerType, maxSessionLimit, startVMOnConnect'
    $q.Workspaces           | Should -Match 'microsoft\.desktopvirtualization/workspaces'
    $q.ApplicationGroups    | Should -Match 'microsoft\.desktopvirtualization/applicationgroups'
  }

  It 'collects populated subscription via mocked Graph and ARM REST, redacts IDs by default, and writes inventory files' {
    $subId = '11111111-2222-3333-4444-555555555555'
    $tenantId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

    $graphInvoker = {
      param($body)
      $q = "$($body.query)"
      $data = if ($q -match 'summarize count') {
        @(
          @{ type = 'microsoft.desktopvirtualization/hostpools'; count = 1 },
          @{ type = 'microsoft.desktopvirtualization/workspaces'; count = 1 },
          @{ type = 'microsoft.desktopvirtualization/applicationgroups'; count = 1 },
          @{ type = 'microsoft.compute/virtualmachines'; count = 2 },
          @{ type = 'microsoft.network/virtualnetworks'; count = 10 }
        )
      } elseif ($q -match 'microsoft\.compute/virtualmachines') {
        @(
          @{ name = 'vm-avd-0'; resourceGroup = 'rg-avd-prod'; vmSize = 'Standard_D4s_v5'; powerState = 'PowerState/running' },
          @{ name = 'vm-avd-1'; resourceGroup = 'rg-avd-prod'; vmSize = 'Standard_D4s_v5'; powerState = 'PowerState/deallocated' }
        )
      } elseif ($q -match 'microsoft\.desktopvirtualization/hostpools') {
        @(
          @{ name = 'hp-avd-01'; resourceGroup = 'rg-avd-prod'; hostPoolType = 'Pooled'; loadBalancerType = 'BreadthFirst'; maxSessionLimit = 10; startVMOnConnect = $true }
        )
      } elseif ($q -match 'microsoft\.desktopvirtualization/workspaces') {
        @(
          @{ name = 'ws-avd-01'; resourceGroup = 'rg-avd-prod' }
        )
      } elseif ($q -match 'microsoft\.desktopvirtualization/applicationgroups') {
        @(
          @{ name = 'dag-avd-01'; resourceGroup = 'rg-avd-prod'; applicationGroupType = 'Desktop' }
        )
      } else {
        @()
      }
      @{ StatusCode = 200; Content = (@{ data = $data } | ConvertTo-Json -Depth 10 -Compress) }
    }

    $restInvoker = {
      param($path)
      if ($path -match '/resourcegroups\?') {
        return @{ StatusCode = 200; Content = (@{ value = @(@{ name = 'rg-avd-prod' }, @{ name = 'rg-avd-net' }, @{ name = 'rg-avd-shared' }) } | ConvertTo-Json -Depth 5 -Compress) }
      }
      if ($path -match '/hostPools/hp-avd-01/sessionHosts\?') {
        return @{ StatusCode = 200; Content = (@{ value = @(@{ name = 'hp-avd-01/vm-avd-0' }, @{ name = 'hp-avd-01/vm-avd-1' }) } | ConvertTo-Json -Depth 5 -Compress) }
      }
      return @{ StatusCode = 404; Content = '{}' }
    }

    $subRes = Invoke-AvdSummarySubscription -SubscriptionId $subId -SubscriptionName 'sub-contoso-avd' `
      -GraphInvoker $graphInvoker -RestInvoker $restInvoker
    $inv = New-AvdSummaryInventory -SubscriptionSummaries @($subRes) -Stamp '2026-11-13' -TenantId $tenantId

    $inv.summary | Should -Be '1 host pool(s), 2 session host(s), 15 ARM resource(s)'
    $inv.totals.resourceGroups | Should -Be 3
    $inv.totals.virtualMachines | Should -Be 2
    $inv.totals.workspaces | Should -Be 1
    $inv.totals.applicationGroups | Should -Be 1

    $outDir = Join-Path $TestDrive 'summary-populated'
    $written = Write-AvdSummaryInventory -Inventory $inv -OutputPath $outDir
    Test-Path -LiteralPath $written.JsonPath | Should -BeTrue
    Test-Path -LiteralPath $written.MdPath   | Should -BeTrue

    $jsonRaw = Get-Content -Raw -LiteralPath $written.JsonPath
    $jsonRaw | Should -Not -Match $subId
    $jsonRaw | Should -Not -Match $tenantId

    $mdRaw = Get-Content -Raw -LiteralPath $written.MdPath
    $mdRaw | Should -Match '1 host pool\(s\), 2 session host\(s\), 15 ARM resource\(s\)'
    $mdRaw | Should -Match '## AVD workload'
    $mdRaw | Should -Match '## Dataset counts'
    $mdRaw | Should -Match 'hp-avd-01'
    $mdRaw | Should -Match 'vm-avd-0'

    # When -IncludeIds is explicitly requested, tenantId and subscriptionId are included.
    $subResWithIds = Invoke-AvdSummarySubscription -SubscriptionId $subId -SubscriptionName 'sub-contoso-avd' `
      -GraphInvoker $graphInvoker -RestInvoker $restInvoker -IncludeIds
    $invWithIds = New-AvdSummaryInventory -SubscriptionSummaries @($subResWithIds) -Stamp '2026-11-13-ids' -TenantId $tenantId -IncludeIds
    $writtenIds = Write-AvdSummaryInventory -Inventory $invWithIds -OutputPath $outDir -IncludeIds
    $jsonIdsRaw = Get-Content -Raw -LiteralPath $writtenIds.JsonPath
    $jsonIdsRaw | Should -Match $subId
    $jsonIdsRaw | Should -Match $tenantId
  }

  It 'handles an empty or torn-down subscription with 0 host pools and 0 VMs' {
    $emptyGraph = { param($body) $null = $body; @{ StatusCode = 200; Content = '{"data":[]}' } }
    $emptyRest  = { param($path) $null = $path; @{ StatusCode = 200; Content = '{"value":[]}' } }

    $subRes = Invoke-AvdSummarySubscription -SubscriptionId '00000000-0000-0000-0000-000000000001' -SubscriptionName 'sub-empty' `
      -GraphInvoker $emptyGraph -RestInvoker $emptyRest
    $inv = New-AvdSummaryInventory -SubscriptionSummaries @($subRes) -Stamp '2026-11-13-empty'

    $inv.summary | Should -Be '0 host pool(s), 0 session host(s), 0 ARM resource(s)'
    $inv.totals.resourceGroups | Should -Be 0
    $inv.totals.armResources   | Should -Be 0
    $inv.totals.hostPools      | Should -Be 0
    $inv.totals.sessionHosts   | Should -Be 0
    $inv.totals.virtualMachines | Should -Be 0

    $outDir = Join-Path $TestDrive 'summary-empty'
    $written = Write-AvdSummaryInventory -Inventory $inv -OutputPath $outDir
    (Get-Content -Raw -LiteralPath $written.MdPath) | Should -Match '0 host pool\(s\), 0 session host\(s\), 0 ARM resource\(s\)'
  }

  It 'runs avd_current_state_collector.ps1 -Light end-to-end against fake Az modules without heavy exports' {
    $out = Join-Path $TestDrive 'e2e-light'
    New-Item -ItemType Directory -Path $out | Out-Null

    $routesPath = Join-Path $TestDrive 'routes.json'
    @(
      @{ match = 'summarize count'; status = 200; content = @{ data = @(@{ type = 'microsoft.desktopvirtualization/hostpools'; count = 1 }, @{ type = 'microsoft.compute/virtualmachines'; count = 1 }) } },
      @{ match = 'microsoft\.compute/virtualmachines'; status = 200; content = @{ data = @(@{ name = 'vm-sh-1'; resourceGroup = 'rg-avd'; vmSize = 'Standard_D2s_v5'; powerState = 'PowerState/running' }) } },
      @{ match = 'microsoft\.desktopvirtualization/hostpools'; status = 200; content = @{ data = @(@{ name = 'hp-1'; resourceGroup = 'rg-avd'; hostPoolType = 'Pooled'; loadBalancerType = 'DepthFirst'; maxSessionLimit = 5; startVMOnConnect = $false }) } },
      @{ match = 'microsoft\.desktopvirtualization/workspaces'; status = 200; content = @{ data = @() } },
      @{ match = 'microsoft\.desktopvirtualization/applicationgroups'; status = 200; content = @{ data = @() } },
      @{ match = '/resourcegroups\?'; status = 200; content = @{ value = @(@{ name = 'rg-avd' }) } },
      @{ match = '/hostPools/hp-1/sessionHosts\?'; status = 200; content = @{ value = @(@{ name = 'hp-1/vm-sh-1' }) } }
    ) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $routesPath

    $saved = @{ PSModulePath = $env:PSModulePath; FAKEAZ_SUBSCRIPTIONS = $env:FAKEAZ_SUBSCRIPTIONS; FAKEAZ_ROUTES = $env:FAKEAZ_ROUTES }
    try {
      $fakes = Join-Path $script:root 'tests/fakes'
      $env:PSModulePath = $fakes
      $env:FAKEAZ_SUBSCRIPTIONS = '1'
      $env:FAKEAZ_ROUTES = $routesPath
      $collector = Join-Path $script:root 'avd_current_state_collector.ps1'
      $command = "`$env:PSModulePath = '$fakes'; & '$collector' -Light -Stamp '2026-11-13' -OutputPath '$out'; exit `$LASTEXITCODE"
      $log = & $script:pwsh -NoProfile -NonInteractive -Command $command 2>&1
      $code = $LASTEXITCODE
    } finally {
      $env:PSModulePath = $saved.PSModulePath
      $env:FAKEAZ_SUBSCRIPTIONS = $saved.FAKEAZ_SUBSCRIPTIONS
      $env:FAKEAZ_ROUTES = $saved.FAKEAZ_ROUTES
    }

    $text = ($log | Out-String)
    $code | Should -Be 0 -Because $text
    $text | Should -Match '"stage":"collect","status":"done"'
    Test-Path -LiteralPath (Join-Path $out '2026-11-13-inventory.md')   | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $out '2026-11-13-inventory.json') | Should -BeTrue
    @(Get-ChildItem -Path $out -Filter 'avd-current-state-*.zip').Count | Should -Be 0

    $inv = Get-Content -Raw -LiteralPath (Join-Path $out '2026-11-13-inventory.json') | ConvertFrom-Json
    $inv.summary | Should -Be '1 host pool(s), 1 session host(s), 2 ARM resource(s)'
  }
}
