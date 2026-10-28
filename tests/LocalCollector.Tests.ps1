#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for issue #28 (endpoint alignment with assess/endpoints.json and off-host WARN semantics)
# and the Constrained Language Mode local collector and log bundle (docs/local-collector-spec.md,
# avd-linecheck docs/spec.md section 17).

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdLocal.psm1') -Force

  # Load Get-AvdPinnedHostEndpoints and Test-AvdEndpoints from avd_deployment_validator.ps1 via AST
  $tokens = $null
  $errors = $null
  $validatorAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $script:root 'avd_deployment_validator.ps1'),
    [ref]$tokens,
    [ref]$errors
  )
  foreach ($fnName in @('ConvertTo-DisplayString', 'Add-Check', 'Get-AvdPinnedHostEndpoints', 'Test-AvdEndpoints')) {
    $fnAst = $validatorAst.Find({
      param($n)
      $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName
    }, $true)
    if ($null -ne $fnAst) {
      Invoke-Expression $fnAst.Extent.Text
    }
  }
}

Describe 'Issue #28: Test-AvdEndpoints pinned endpoint map and off-host semantics' {
  BeforeEach {
    $script:CurrentPhase = 'PreDeployment'
    $script:Results = [System.Collections.Generic.List[object]]::new()
    $script:LogMessages = [System.Collections.Generic.List[string]]::new()
    $script:DomainName = ''
  }

  It 'reads views.host.probe and views.host.notTested from assess/endpoints.json including oneocsp on TCP 80' {
    $map = Get-AvdPinnedHostEndpoints -EndpointsPath (Join-Path $script:root 'assess/endpoints.json')
    $map.Probe.Count | Should -Be 11
    $map.NotTested.Count | Should -Be 10

    $ocsp = @($map.Probe | Where-Object { $_.Host -eq 'oneocsp.microsoft.com' })[0]
    $ocsp | Should -Not -BeNullOrEmpty
    $ocsp.Port | Should -Be 80
    $ocsp.Id | Should -Be 'host.cert-ocsp'

    $untestedIds = @($map.NotTested | ForEach-Object { $_.Id })
    $untestedIds | Should -Contain 'host.service'
    $untestedIds | Should -Contain 'host.windows-cloud'
    $untestedIds | Should -Contain 'host.windows-static'
    $untestedIds | Should -Contain 'host.relay'
    $untestedIds | Should -Contain 'platform.metadata'
    $untestedIds | Should -Contain 'platform.wireserver'
  }

  It 'reports off-host probes as WARN (unknown for session hosts, never PASS) and records notTested rows as SKIP' {
    Test-AvdEndpoints -EndpointsPath (Join-Path $script:root 'assess/endpoints.json') -ProbeRunner {
      param($h, $p)
      $null = $h; $null = $p
      [pscustomobject]@{ Succeeded = $true; Message = 'Connected' }
    }
    $passRows = @($script:Results | Where-Object { $_.Status -eq 'PASS' })
    $passRows.Count | Should -Be 0 -Because 'off-host probes must never report PASS for session host reachability'

    $warnRows = @($script:Results | Where-Object { $_.Status -eq 'WARN' })
    $warnRows.Count | Should -Be 12 # 1 Probe context + 11 probed endpoints

    $skipRows = @($script:Results | Where-Object { $_.Status -eq 'SKIP' })
    $skipRows.Count | Should -Be 10
  }

  It 'reports on-subnet reachable probes as PASS and unreachable required probes as FAIL' {
    Test-AvdEndpoints -OnSessionHostSubnet -EndpointsPath (Join-Path $script:root 'assess/endpoints.json') -ProbeRunner {
      param($h, $p)
      $null = $p
      if ($h -eq 'azkms.core.windows.net') {
        [pscustomobject]@{ Succeeded = $false; Message = 'Connection timed out' }
      } else {
        [pscustomobject]@{ Succeeded = $true; Message = 'Connected' }
      }
    }
    $passRows = @($script:Results | Where-Object { $_.Status -eq 'PASS' })
    $passRows.Count | Should -Be 10

    $failRows = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
    $failRows.Count | Should -Be 1
    $failRows[0].Check | Should -Be 'azkms.core.windows.net'
  }
}

Describe 'Local collector source catalog (local/sources.json)' {
  BeforeAll {
    $script:sourcesDoc = Get-Content -LiteralPath (Join-Path $script:root 'local/sources.json') -Raw | ConvertFrom-Json
  }

  It 'declares schema avd-local-sources/v1 and covers Preflight, Host, Session and Device modes' {
    $script:sourcesDoc.schema | Should -Be 'avd-local-sources/v1'
    $script:sourcesDoc.schemaVersion | Should -Be 1
    foreach ($m in @('Preflight', 'Host', 'Session', 'Device')) {
      @(Get-AvdLocalSource -Mode $m).Count | Should -BeGreaterThan 0 -Because $m
    }
  }

  It 'never includes forbidden identity or hardware-serial properties in any source allowlist' {
    $forbidden = @('UserName', 'SerialNumber', 'PartNumber', 'MACAddress', 'ComputerId', 'SSID', 'BSSID')
    foreach ($src in @($script:sourcesDoc.sources)) {
      $src.requiresAdmin | Should -BeIn @('yes', 'no', 'unknown') -Because $src.id
      $src.privacyClass | Should -BeIn @('facts', 'private', 'personal') -Because $src.id
      $src.learnUrl | Should -Match '^https://learn\.microsoft\.com/' -Because $src.id
      foreach ($prop in @($src.propertyAllowlist)) {
        $prop | Should -Not -BeIn $forbidden -Because "$($src.id) allowlist must not include $prop"
      }
    }
  }
}

Describe 'Constrained Language Mode and no-network AST guards on lib/AvdLocal.psm1' {
  BeforeAll {
    $tokens = $null
    $errors = $null
    $script:localAst = [System.Management.Automation.Language.Parser]::ParseFile(
      (Join-Path $script:root 'lib/AvdLocal.psm1'),
      [ref]$tokens,
      [ref]$errors
    )
    $script:parseErrors = $errors
  }

  It 'parses lib/AvdLocal.psm1 with zero syntax errors and zero classes, Add-Type, New-Object or .NET method calls' {
    @($script:parseErrors).Count | Should -Be 0

    $typeDefs = $script:localAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true)
    @($typeDefs).Count | Should -Be 0 -Because 'CLM blocks PowerShell classes'

    $memberCalls = $script:localAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
    @($memberCalls).Count | Should -Be 0 -Because 'CLM blocks .NET method invocation'

    $commands = $script:localAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $commands) {
      $name = $cmd.GetCommandName()
      $name | Should -Not -BeIn @('Add-Type', 'New-Object') -Because "line $($cmd.Extent.StartLineNumber)"
    }
  }

  It 'contains no network cmdlets, web clients, remote -ComputerName/-CimSession or non-LiteralPath Copy-Item calls' {
    $forbiddenCmds = @(
      'Invoke-WebRequest', 'Invoke-RestMethod', 'iwr', 'curl', 'wget',
      'Start-BitsTransfer', 'Test-NetConnection', 'Start-Process'
    )
    $commands = $script:localAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $commands) {
      $name = $cmd.GetCommandName()
      if ($name) {
        $name | Should -Not -BeIn $forbiddenCmds -Because "line $($cmd.Extent.StartLineNumber)"
        $name | Should -Not -Match '(?i)\b(curl\.exe|certutil|bitsadmin)\b' -Because "line $($cmd.Extent.StartLineNumber)"
      }
      $text = $cmd.Extent.Text
      $text | Should -Not -Match '(?i)\s-(ComputerName|CimSession)\b' -Because "line $($cmd.Extent.StartLineNumber)"
      if ($name -eq 'Copy-Item') {
        $text | Should -Match '-LiteralPath\b' -Because "Copy-Item on line $($cmd.Extent.StartLineNumber) must use -LiteralPath"
      }
    }
    $rawText = $script:localAst.Extent.Text
    $rawText | Should -Not -Match '(?i)\b(System\.Net|HttpClient|WebClient)\b'
  }

  It 'executes pure functions inside a ConstrainedLanguage child runspace' {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    try {
      $ps = [powershell]::Create()
      $ps.Runspace = $rs
      $null = $ps.AddCommand('Import-Module').AddParameter('Name', (Join-Path $script:root 'lib/AvdLocal.psm1')).AddParameter('Force', $true)
      $null = $ps.Invoke()
      $ps.Streams.Error.Count | Should -Be 0

      $rs.SessionStateProxy.LanguageMode = 'ConstrainedLanguage'

      $ps.Commands.Clear()
      $null = $ps.AddScript(@'
        $mode = $ExecutionContext.SessionState.LanguageMode
        $ctxDeviceUser = Test-AvdLocalContext -Mode Device -WhoamiGroups @('Medium Mandatory Level', 'S-1-16-8192')
        $ctxDeviceSys  = Test-AvdLocalContext -Mode Device -WhoamiGroups @('System Mandatory Level', 'S-1-5-18')
        $ctxHostUser   = Test-AvdLocalContext -Mode Host   -WhoamiGroups @('Medium Mandatory Level', 'S-1-16-8192')
        $ctxHostAdmin  = Test-AvdLocalContext -Mode Host   -WhoamiGroups @('High Mandatory Level', 'S-1-16-12288')
        $filtered = Select-AvdAllowedProperty -InputObject @{ Model = 'Surface'; SerialNumber = 'SECRET-123'; UserName = 'corp\alice' } -Allowlist @('Model')
        $redacted = Protect-AvdFslogixLocation -Value 'type=azure,connectionString=DefaultEndpointsProtocol=https;AccountKey=secretKey123|fslogix/prof|'
        $normPath = ConvertTo-AvdNormalizedUserPath -Path 'C:\Users\alice\Downloads\avd-linecheck.json' -UserProfile 'C:\Users\alice'
        $facts = New-AvdLocalFactDocument -Mode Host -ReaderData @{ vmId = '00000000-0000-0000-0000-000000000001'; fslogixEnabled = $true; teamsOptimized = $true }
        $health = New-AvdLocalHealthSummary -ReaderData @{ freeDiskGiB = 42; pendingReboot = $false; crashCount = 0 }
        $manifest = New-AvdLocalManifest -Mode Device -Files @() -Skipped @() -UserProfile 'C:\Users\alice'
        @{
          LanguageMode  = "$mode"
          DeviceUserOk  = $ctxDeviceUser.Allowed
          DeviceSysOk   = $ctxDeviceSys.Allowed
          DeviceSysWhy  = $ctxDeviceSys.Reason
          HostUserOk    = $ctxHostUser.Allowed
          HostAdminOk   = $ctxHostAdmin.Allowed
          FilteredProps = @($filtered.Keys)
          Redacted      = $redacted
          NormPath      = $normPath
          FactsSchema   = $facts.schemaVersion
          HealthSchema  = $health.schemaVersion
          ManSchema     = $manifest.schemaVersion
        }
'@)
      $res = @($ps.Invoke())[0]
      @($ps.Streams.Error) | Should -BeNullOrEmpty
      $res.LanguageMode | Should -Be 'ConstrainedLanguage'
      $res.DeviceUserOk | Should -BeTrue
      $res.DeviceSysOk | Should -BeFalse
      $res.DeviceSysWhy | Should -Match 'ran as SYSTEM, wrong context'
      $res.HostUserOk | Should -BeFalse
      $res.HostAdminOk | Should -BeTrue
      $res.FilteredProps | Should -Be @('Model')
      $res.Redacted | Should -Match 'connectionString=<redacted>'
      $res.Redacted | Should -Not -Match 'secretKey123'
      $res.NormPath | Should -Be '%USERPROFILE%\Downloads\avd-linecheck.json'
      $res.FactsSchema | Should -Be 'avd-local-facts/v1'
      $res.HealthSchema | Should -Be 'avd-local-health/v1'
      $res.ManSchema | Should -Be 'avd-local-manifest/v1'
    } finally {
      $rs.Close()
      $rs.Dispose()
    }
  }
}

Describe 'Synthetic profile tree, junction/reparse guard and bundle zip generation' {
  It 'skips junctions/reparse points and paths outside the root' {
    $rootDir = Join-Path $TestDrive 'profile-root'
    $outsideDir = Join-Path $TestDrive 'outside-secret'
    $stageDir = Join-Path $TestDrive 'stage-out'
    $null = New-Item -Path $rootDir -ItemType Directory -Force
    $null = New-Item -Path $outsideDir -ItemType Directory -Force
    'safe log line' | Set-Content -LiteralPath (Join-Path $rootDir 'app.log') -Encoding UTF8
    'secret file'   | Set-Content -LiteralPath (Join-Path $outsideDir 'secret.txt') -Encoding UTF8

    $junctionPath = Join-Path $rootDir 'planted-junction'
    $null = New-Item -ItemType Junction -Path $junctionPath -Target $outsideDir -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $junctionPath) {
      $jCheck = Test-AvdSafeLocalPath -LiteralPath $junctionPath -RootPath $rootDir
      $jCheck.Safe | Should -BeFalse
      $jCheck.Status | Should -Be 'skipped: reparse point'
    }

    $outCheck = Test-AvdSafeLocalPath -LiteralPath (Join-Path $outsideDir 'secret.txt') -RootPath $rootDir
    $outCheck.Safe | Should -BeFalse
    $outCheck.Status | Should -Be 'skipped: outside root'

    $copyRes = Copy-AvdSafeLocalItem -LiteralPath $rootDir -Destination $stageDir -RootPath $rootDir
    $copyRes.Copied.Count | Should -Be 1
    $copyRes.Copied[0].SourcePath | Should -Match 'app\.log$'
    if (Test-Path -LiteralPath $junctionPath) {
      @($copyRes.Skipped | Where-Object { $_.Reason -eq 'skipped: reparse point' }).Count | Should -Be 1
    }
  }

  It 'builds Device and Session zip bundles and Host/Preflight local-facts.json via avd_current_state.ps1' {
    $frontDoor = Join-Path $script:root 'avd_current_state.ps1'
    $dryRun = & $frontDoor -Routine local -Mode Device -ListSources
    $dryRun.Mode | Should -Be 'Device'
    $dryRun.ContainsPersonalData | Should -BeTrue
    $dryRun.Sources.Count | Should -BeGreaterThan 5

    $userSim = Join-Path $TestDrive 'user-sim'
    $downloads = Join-Path $userSim 'Downloads'
    $null = New-Item -Path $downloads -ItemType Directory -Force
    $commentFile = Join-Path $downloads 'comments.txt'
    'Screen froze during Teams call at 10:15' | Set-Content -LiteralPath $commentFile -Encoding UTF8

    $devOut = Invoke-AvdLocalCollector -Mode Device -OutputPath $downloads -Add @($commentFile) `
      -WhoamiGroups @('Medium Mandatory Level', 'S-1-16-8192') `
      -ReaderData @{ freeDiskGiB = 120; uptimeHours = 18; pendingReboot = $false; crashCount = 1; defenderEnabled = $true } `
      -RunUtc '2026-10-28T14:30:00Z' -UserProfile $userSim

    $devOut.schemaVersion | Should -Be 'avd-local-summary/v1'
    $devOut.zipPath | Should -Match 'avd-linecheck-device-20261028-1430\.zip$'
    Test-Path -LiteralPath $devOut.zipPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $devOut.manifestPath -PathType Leaf | Should -BeTrue

    $man = Get-Content -LiteralPath $devOut.manifestPath -Raw | ConvertFrom-Json
    $man.schemaVersion | Should -Be 'avd-local-manifest/v1'
    $man.containsPersonalData | Should -BeTrue
    # The run's own separator: the TestDrive profile is a forward-slash path on Linux and macOS.
    $expectedSource = Join-Path (Join-Path '%USERPROFILE%' 'Downloads') 'comments.txt'
    @($man.files | Where-Object { $_.sourcePath -eq $expectedSource }).Count | Should -Be 1

    $hostDir = Join-Path $TestDrive 'host-out'
    $hostOut = Invoke-AvdLocalCollector -Mode Host -OutputPath $hostDir `
      -WhoamiGroups @('High Mandatory Level', 'S-1-16-12288') `
      -ReaderData @{ vmId = '00000000-0000-0000-0000-000000000009'; agentVersion = '1.0.8500.1'; fslogixEnabled = $true; teamsOptimized = $true; shortpathEnabled = $true } `
      -RunUtc '2026-10-28T14:35:00Z' -UserProfile $userSim

    Test-Path -LiteralPath $hostOut.factsPath -PathType Leaf | Should -BeTrue
    $hostOut.zipPath | Should -BeNullOrEmpty -Because 'Host mode writes facts only unless -Bundle is set'
    $factsDoc = Get-Content -LiteralPath $hostOut.factsPath -Raw | ConvertFrom-Json
    $factsDoc.schemaVersion | Should -Be 'avd-local-facts/v1'
    $factsDoc.identity.idSource | Should -Be 'imds'
    $factsDoc.facts.'c11.hostPool.sessionHosts.localFslogixEnabled' | Should -BeTrue
  }
}
