#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for the assessment portal's state line (docs/assessment-portal-spec.md, section 3): the
# exact line each script ends with, and the refusals that keep names and IDs out of it. The portal's engine
# (site/portal/assess-core.js) reads the same lines in tests/portal/fixtures/.

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdPortalState.psm1') -Force
}

Describe 'Get-AvdcsStateLine' {
  It 'builds the collect line with sorted keys' {
    $line = Get-AvdcsStateLine -Stage collect -Status partial -Context @{ package = 'avd-current-state-20261021T090000' } `
      -Counts @{ subscriptions = 1; skipped = 1; datasets = 14; rows = 230; hostPools = 3; sessionHosts = 12; warnings = 1 } `
      -Coverage @{ found = 40; secret = 3; unknown = 2 }
    $line | Should -BeExactly '<<<AVDCS-STATE {"v":1,"stage":"collect","status":"partial","context":{"package":"avd-current-state-20261021T090000"},"counts":{"datasets":14,"hostPools":3,"rows":230,"sessionHosts":12,"skipped":1,"subscriptions":1,"warnings":1},"coverage":{"found":40,"secret":3,"unknown":2}} AVDCS-STATE>>>'
  }

  It 'matches the fixtures the portal engine is tested with' {
    $fixtures = Get-Content (Join-Path $script:root 'tests/portal/fixtures/collect-run.txt') -Raw
    $line = Get-AvdcsStateLine -Stage collect -Status partial -Context @{ package = 'avd-current-state-20261021T090000' } `
      -Counts @{ subscriptions = 1; skipped = 1; datasets = 14; rows = 230; hostPools = 3; sessionHosts = 12; warnings = 1 } `
      -Coverage @{ found = 40; secret = 3; unknown = 2 }
    $fixtures | Should -Match ([regex]::Escape($line))
    $facts = Get-AvdcsStateLine -Stage facts -Status done -Context @{ estate = 'est-0a1b2c3d'; snapshot = 'avd-current-state-facts-20261021T090500.json' } `
      -Counts @{ subscriptions = 1; hostPools = 3; validations = 0; redacted = 4 }
    $fixtures | Should -Match ([regex]::Escape($facts))
    $analyze = Get-AvdcsStateLine -Stage analyze -Status done -Context @{ mode = 'PostDeployment'; package = 'avd-validation-20261021T091000'; verdict = 'READY WITH WARNINGS' } `
      -Counts @{ fail = 0; warn = 3; pass = 21; info = 4; skip = 2 }
    (Get-Content (Join-Path $script:root 'tests/portal/fixtures/analyze-run.txt') -Raw) | Should -Match ([regex]::Escape($analyze))
  }

  It 'leaves out empty sections' {
    Get-AvdcsStateLine -Stage analyze -Status failed | Should -BeExactly '<<<AVDCS-STATE {"v":1,"stage":"analyze","status":"failed"} AVDCS-STATE>>>'
  }

  It 'refuses an unknown stage, status or context key' {
    { Get-AvdcsStateLine -Stage deploy -Status done } | Should -Throw '*stage*'
    { Get-AvdcsStateLine -Stage collect -Status ok } | Should -Throw '*status*'
    { Get-AvdcsStateLine -Stage collect -Status done -Context @{ subscriptionName = 'Contoso Prod' } } | Should -Throw '*not allowed*'
  }

  It 'refuses values that look private' {
    { Get-AvdcsStateLine -Stage collect -Status done -Context @{ package = '11111111-2222-4333-8444-555555555555' } } | Should -Throw '*private*'
    { Get-AvdcsStateLine -Stage collect -Status done -Context @{ package = 'C:\Evidence\run' } } | Should -Throw '*private*'
    { Get-AvdcsStateLine -Stage collect -Status done -Context @{ package = 'admin@contoso.com' } } | Should -Throw '*private*'
    { Get-AvdcsStateLine -Stage collect -Status done -Counts @{ rows = 'many' } } | Should -Throw '*whole number*'
  }
}

Describe 'The scripts end with the state line' {
  It '<_> builds it' -ForEach @('avd_current_state_collector.ps1', 'avd_current_state_facts.ps1', 'avd_deployment_validator.ps1') {
    $text = Get-Content (Join-Path $script:root $_) -Raw
    $text | Should -Match 'Get-AvdcsStateLine -Stage'
    $text | Should -Match 'lib/AvdPortalState\.psm1'
  }

  It 'the validator reports a run that could not start as failed' {
    $text = Get-Content (Join-Path $script:root 'avd_deployment_validator.ps1') -Raw
    ([regex]::Matches($text, "Write-PortalState -Status 'failed'\s+exit 2")).Count | Should -Be ([regex]::Matches($text, '\bexit 2\b').Count)
  }
}
