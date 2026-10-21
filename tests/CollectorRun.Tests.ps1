#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The whole collector, run offline against fake Az modules (tests/fakes/): it must finish on an empty
# subscription, one or several. The first real Cloud Shell run (2026-10-21) stopped at subscription
# discovery, because under Set-StrictMode one typed subscription object has no .Count, and an empty
# rebuild map list came back wrapped in a second array. No test ran the script end to end before.

BeforeDiscovery {
  $script:cases = @(@{ Subs = 1 }, @{ Subs = 2 })
}

Describe 'collector: a full offline run' {
  BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:pwsh = (Get-Process -Id $PID).Path
  }

  It 'finishes with <Subs> empty subscription(s)' -ForEach $script:cases {
    $out = Join-Path $TestDrive "run-$Subs"
    New-Item -ItemType Directory -Path $out | Out-Null
    $saved = @{ PSModulePath = $env:PSModulePath; FAKEAZ_SUBSCRIPTIONS = $env:FAKEAZ_SUBSCRIPTIONS }
    try {
      # Only the fakes, so a real Az install on the runner can't be loaded instead. pwsh puts the user
      # and shared module folders back in front at startup (where macOS runners keep Az), so the child
      # sets the path again before it runs the collector.
      $fakes = Join-Path $script:root 'tests/fakes'
      $env:PSModulePath = $fakes
      $env:FAKEAZ_SUBSCRIPTIONS = "$Subs"
      $collector = Join-Path $script:root 'avd_current_state_collector.ps1'
      $command = "`$env:PSModulePath = '$fakes'; & '$collector' -OutputPath '$out'; exit `$LASTEXITCODE"
      $log = & $script:pwsh -NoProfile -NonInteractive -Command $command 2>&1
      $code = $LASTEXITCODE
    } finally {
      $env:PSModulePath = $saved.PSModulePath
      $env:FAKEAZ_SUBSCRIPTIONS = $saved.FAKEAZ_SUBSCRIPTIONS
    }
    $text = ($log | Out-String)
    $code | Should -Be 0 -Because $text
    $text | Should -Match '"stage":"collect","status":"done"'
    $text | Should -Match "Subscriptions   : $Subs collected, 0 skipped"
    @(Get-ChildItem -Path $out -Filter 'avd-current-state-*.zip').Count | Should -Be 1
    $text | Should -Not -Match 'HTML summary skipped'
    $html = @(Get-ChildItem -Path $out -Recurse -Filter 'summary.html')
    $html.Count | Should -Be 1
    Get-Content -Raw $html[0].FullName | Should -Match '<body class="shell report">'
  }
}
