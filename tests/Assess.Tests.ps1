#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for lib/AvdAssess.psm1, the avd-assess method runner (avd-assess phase 4): the pinned
# copies under assess/ and contracts/, the evaluator's four outcomes, the scoring and the C21 report.
# The fixture snapshots are C11 shaped and, like ARM, omit what wasn't collected.

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdAssess.psm1') -Force

  function Read-TestJson { param([string] $Path) Get-Content -LiteralPath (Join-Path $script:root $Path) -Raw | ConvertFrom-Json }
  function ConvertTo-Doc { param($Data) $Data | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

  $script:method = Read-TestJson 'assess/method.json'
  $script:register = Read-TestJson 'contracts/fact-register.json'
  $script:intake = Read-TestJson 'tests/portal/fixtures/intake.json'
  $script:schema = Join-Path $script:root 'contracts/assessment.schema.json'

  # One estate, two subscriptions: every pinned check gets pass, warn and unknown subjects.
  $script:snapshot = ConvertTo-Doc @{
    schema = 'avd-current-state-facts/v1'; estate = 'est-0a1b2c3d'; generatedUtc = '2026-10-21T09:00:00Z'
    subscriptions = @(
      @{ id = 'sub-1a2b3c4d'; regions = @('eastus2'); defenderPlans = @{ VirtualMachines = 'Standard'; StorageAccounts = 'Free' }
        hostPools = @(
          @{ id = 'hp-00000001'; region = 'eastus2'; type = 'Personal'; startVmOnConnect = $false; appGroups = @('Desktop')
            redirection = @{ drives = 'off'; usb = 'off' }; sessionHosts = @{ total = 4; notTrustedLaunch = 0 } }
          @{ id = 'hp-00000002'; region = 'eastus2'; type = 'Pooled'; startVmOnConnect = $true; preferredAppGroupType = 'Desktop'
            redirection = @{ drives = 'on'; usb = 'off' }; sessionHosts = @{ total = 1; notTrustedLaunch = 1 } }
          @{ id = 'hp-00000003'; region = 'eastus2'; type = 'Pooled'; sessionHosts = @{ total = 3 } })
        storageAccounts = @(
          @{ id = 'st-00000001'; kind = 'FileStorage'; sku = 'Premium_ZRS'; privateEndpoint = $true; smbChannelEncryption = 'gcm' }
          @{ id = 'st-00000002'; kind = 'FileStorage'; sku = 'Premium_LRS' }
          @{ id = 'st-00000003'; kind = 'StorageV2'; sku = 'Standard_LRS'; privateEndpoint = $false })
        network = @{ virtualNetworks = 2; customDnsVirtualNetworks = 1; defaultRoutes = 1; privateEndpoints = 1 } }
      @{ id = 'sub-5e6f7a8b'; regions = @('centralus'); hostPools = @(); storageAccounts = @() })
  }

  function Get-Row { param($Report, [string] $Id) @($Report.results | Where-Object { $_.check -eq $Id })[0] }
  function New-TestReport {
    param($Snapshot = $script:snapshot, $Intake = $script:intake, $Method = $script:method)
    $sha = if ($null -ne $Intake) { 'ef' * 32 } else { $null }
    Get-AvdAssessment -Method $Method -MethodCommit ('ab' * 20) -MethodSha256 ('cd' * 32) -Register $script:register -Snapshot $Snapshot -SnapshotSha256 ('12' * 32) `
      -Intake $Intake -IntakeSha256 $sha -ProducerName 'avd_current_state_facts.ps1' -ProducerVersion '1.4.0' -GeneratedUtc '2026-10-21T10:00:00Z'
  }
}

Describe 'Pinned copies' {
  It 'assess/ matches avd-assess byte for byte at the pinned commit' {
    $pins = Read-TestJson 'assess/PINS.json'
    $pins.commit | Should -Match '^[0-9a-f]{40}$'
    $pins.source | Should -Be 'https://github.com/avd-ops/avd-assess'
    @($pins.files.PSObject.Properties).Count | Should -Be 2
    foreach ($f in $pins.files.PSObject.Properties) {
      (Get-FileHash (Join-Path $script:root "assess/$($f.Name)") -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $f.Value -Because $f.Name
    }
  }

  It 'pins assess/ and contracts/ to the same avd-assess commit' {
    (Read-TestJson 'assess/PINS.json').commit | Should -Be (Read-TestJson 'contracts/PINS.json').commit
  }

  It 'the method cites the register it is pinned with' {
    $script:method.schema | Should -Be 'avd-assess-method/v1'
    $script:method.factRegister | Should -Be $script:register.version
  }

  It 'the method validates against its C20 schema' {
    Test-Json -Json (Get-Content (Join-Path $script:root 'assess/method.json') -Raw) -SchemaFile (Join-Path $script:root 'contracts/assess-method.schema.json') `
      -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
  }

  It 'every fact a check cites is in the register' {
    $ids = @($script:register.facts.id)
    foreach ($c in $script:method.checks) { foreach ($f in $c.facts) { $ids | Should -Contain $f -Because $c.id } }
  }
}

Describe 'Invoke-AvdAssessCheck' {
  BeforeAll {
    # A fixture method: one check per outcome, the gap one with onFail left to its default.
    $script:fourChecks = ConvertTo-Doc @(
      @{ id = 'asm-test-pass'; facts = @('c11.hostPool.type'); rule = @{ each = '/subscriptions/*/hostPools/*'; where = @{ type = @{ eq = 'Personal' } }; expect = @{ 'sessionHosts/total' = @{ min = 2 } }; onFail = 'warn' } }
      @{ id = 'asm-test-warn'; facts = @('c11.hostPool.startVmOnConnect'); rule = @{ each = '/subscriptions/*/hostPools/*'; where = @{ type = @{ eq = 'Personal' } }; expect = @{ startVmOnConnect = @{ eq = $true } }; onFail = 'warn' } }
      @{ id = 'asm-test-gap'; facts = @('c11.storage.sku'); rule = @{ each = '/subscriptions/*/storageAccounts/*'; where = @{ kind = @{ eq = 'FileStorage' } }; expect = @{ sku = @{ in = @('Premium_ZRS') } } } }
      @{ id = 'asm-test-unknown'; facts = @('c11.storage.smbChannelEncryption'); rule = @{ each = '/subscriptions/*/storageAccounts/*'; where = @{ kind = @{ eq = 'StorageV2' } }; expect = @{ smbChannelEncryption = @{ eq = 'gcm' } } } })
  }

  It 'gives <outcome> for <id>' -ForEach @(
    @{ id = 'asm-test-pass'; outcome = 'pass' }
    @{ id = 'asm-test-warn'; outcome = 'warn' }
    @{ id = 'asm-test-gap'; outcome = 'gap' }
    @{ id = 'asm-test-unknown'; outcome = 'unknown' }) {
    $check = @($script:fourChecks | Where-Object id -eq $id)[0]
    (Invoke-AvdAssessCheck -Check $check -Snapshot $script:snapshot -Register $script:register).outcome | Should -Be $outcome
  }

  It 'leaves out subjects the where tests exclude, and keeps the worst outcome' {
    $row = Invoke-AvdAssessCheck -Check $script:fourChecks[2] -Snapshot $script:snapshot -Register $script:register
    @($row.subjects.id) | Should -Be @('st-00000001', 'st-00000002')
    @($row.subjects.outcome) | Should -Be @('pass', 'gap')
  }

  It 'makes a subject missing a property unknown, never a failure' {
    $row = Invoke-AvdAssessCheck -Check $script:fourChecks[3] -Snapshot $script:snapshot -Register $script:register
    @($row.subjects.outcome) | Should -Be @('unknown')
  }

  It 'makes a subject unknown when a where property is missing' {
    $check = ConvertTo-Doc @{ id = 'asm-test-where'; facts = @('c11.storage.kind'); rule = @{ each = '/subscriptions/*/storageAccounts/*'; where = @{ filesIdentity = @{ eq = 'AADKERB' } }; expect = @{ sku = @{ eq = 'Premium_ZRS' } } } }
    @((Invoke-AvdAssessCheck -Check $check -Snapshot $script:snapshot -Register $script:register).subjects.outcome) | Should -Be @('unknown', 'unknown', 'unknown')
  }

  It 'is unknown with no subjects' {
    $empty = ConvertTo-Doc @{ estate = 'est-0a1b2c3d'; subscriptions = @(@{ id = 'sub-1a2b3c4d'; hostPools = @() }) }
    $row = Invoke-AvdAssessCheck -Check $script:fourChecks[0] -Snapshot $empty -Register $script:register
    $row.outcome | Should -Be 'unknown'
    @($row.subjects).Count | Should -Be 0
  }

  It 'tests booleans as booleans, numbers as numbers and strings ignoring case' {
    $doc = ConvertTo-Doc @{ estate = 'est-0a1b2c3d'; subscriptions = @(@{ id = 'sub-1a2b3c4d'; hostPools = @(
            @{ id = 'hp-00000001'; type = 'personal'; startVmOnConnect = 'true'; sessionHosts = @{ total = 2.0 } }) }) }
    (Invoke-AvdAssessCheck -Check $script:fourChecks[0] -Snapshot $doc -Register $script:register).outcome | Should -Be 'pass'
    (Invoke-AvdAssessCheck -Check $script:fourChecks[1] -Snapshot $doc -Register $script:register).outcome | Should -Be 'warn' -Because "the string 'true' isn't the boolean true"
  }

  It 'makes min and max on a non-number unknown' {
    $doc = ConvertTo-Doc @{ estate = 'est-0a1b2c3d'; subscriptions = @(@{ id = 'sub-1a2b3c4d'; hostPools = @(@{ id = 'hp-00000001'; type = 'Personal'; sessionHosts = @{ total = 'many' } }) }) }
    (Invoke-AvdAssessCheck -Check $script:fourChecks[0] -Snapshot $doc -Register $script:register).outcome | Should -Be 'unknown'
  }

  It 'supports ne and max' {
    $check = ConvertTo-Doc @{ id = 'asm-test-ops'; facts = @('c11.hostPool.type'); rule = @{ each = '/subscriptions/*/hostPools/*'; where = @{ type = @{ ne = 'Personal' } }; expect = @{ 'sessionHosts/total' = @{ max = 2 } } } }
    @((Invoke-AvdAssessCheck -Check $check -Snapshot $script:snapshot -Register $script:register).subjects.outcome) | Should -Be @('pass', 'gap')
  }

  It 'lists only the facts the snapshot had' {
    $snap = ConvertTo-Doc @{ estate = 'est-0a1b2c3d'; subscriptions = @(@{ id = 'sub-1a2b3c4d'; storageAccounts = @(@{ id = 'st-00000001'; kind = 'FileStorage' }) }) }
    $check = @($script:method.checks | Where-Object id -eq 'asm-files-private-endpoint')[0]
    $row = Invoke-AvdAssessCheck -Check $check -Snapshot $snap -Register $script:register
    @($row.facts) | Should -Be @('c11.storage.kind')
    $row.outcome | Should -Be 'unknown'
  }

  It 'runs a check that cites only intake facts over the intake, as the estate' {
    $check = ConvertTo-Doc @{ id = 'asm-test-intake'; facts = @('intake.existingHub'); rule = @{ each = '/workingHours'; expect = @{ start = @{ eq = '07:00' } } } }
    $row = Invoke-AvdAssessCheck -Check $check -Snapshot $script:snapshot -Intake $script:intake -Register $script:register
    $row.outcome | Should -Be 'pass'
    @($row.subjects.id) | Should -Be @('est-0a1b2c3d')
    (Invoke-AvdAssessCheck -Check $check -Snapshot $script:snapshot -Register $script:register).outcome | Should -Be 'unknown' -Because 'no intake was answered'
  }

  It 'refuses an onFail the method format does not have' {
    $check = ConvertTo-Doc @{ id = 'asm-test-bad'; facts = @('c11.hostPool.type'); rule = @{ each = '/subscriptions/*/hostPools/*'; expect = @{ type = @{ eq = 'Pooled' } }; onFail = 'fail' } }
    { Invoke-AvdAssessCheck -Check $check -Snapshot $script:snapshot -Register $script:register } | Should -Throw '*gap or warn*'
  }
}

Describe 'The pinned method over the fixture estate' {
  BeforeAll { $script:report = New-TestReport }

  It 'gives <id> <outcome>' -ForEach @(
    @{ id = 'asm-personal-start-vm-on-connect'; outcome = 'warn' }
    @{ id = 'asm-pooled-host-redundancy'; outcome = 'warn' }
    @{ id = 'asm-files-private-endpoint'; outcome = 'unknown' }
    @{ id = 'asm-files-zone-redundant'; outcome = 'warn' }
    @{ id = 'asm-hosts-trusted-launch'; outcome = 'warn' }
    @{ id = 'asm-drive-usb-redirection-off'; outcome = 'warn' }
    @{ id = 'asm-defender-servers'; outcome = 'unknown' }
    @{ id = 'asm-files-smb-gcm'; outcome = 'unknown' }) {
    (Get-Row $script:report $id).outcome | Should -Be $outcome
  }

  It 'has exactly one row per method check' {
    @($script:report.results.check) | Should -Be @($script:method.checks.id)
  }

  It 'keeps subjects that passed beside the ones that did not' {
    @((Get-Row $script:report 'asm-files-zone-redundant').subjects.outcome) | Should -Be @('pass', 'warn')
    @((Get-Row $script:report 'asm-defender-servers').subjects.outcome) | Should -Be @('pass', 'unknown')
  }

  It 'validates against the C21 schema' {
    $json = $script:report | ConvertTo-Json -Depth 12
    Test-Json -Json $json -SchemaFile $script:schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
  }

  It 'validates against the C21 schema with no intake' {
    $json = (New-TestReport -Intake $null) | ConvertTo-Json -Depth 12
    Test-Json -Json $json -SchemaFile $script:schema -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
  }

  It 'holds no names, IDs or free text' {
    $json = $script:report | ConvertTo-Json -Depth 12
    $json | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-'
    $json | Should -Not -Match '@|\\\\|/subscriptions/'
  }
}

Describe 'Get-AvdAssessScore' {
  It 'scores a pillar as passing weight over assessed weight, a warn counting half' {
    $rows = @(
      @{ check = 'asm-files-private-endpoint'; outcome = 'pass' }      # security, medium (2)
      @{ check = 'asm-hosts-trusted-launch'; outcome = 'warn' }        # security, medium (2)
      @{ check = 'asm-drive-usb-redirection-off'; outcome = 'gap' }    # security, medium (2)
      @{ check = 'asm-defender-servers'; outcome = 'unknown' }         # security, medium
      @{ check = 'asm-files-smb-gcm'; outcome = 'unknown' })           # security, medium
    $security = @(Get-AvdAssessScore -Method $script:method -Result $rows | Where-Object { $_.pillar -eq 'security' })[0]
    $security.checks | Should -Be 5
    $security.assessed | Should -Be 3
    $security.score | Should -Be 0.5
    $security.coverage | Should -Be 0.6
  }

  It 'scores null with nothing assessed, and lists pillars in name order' {
    $scores = @(Get-AvdAssessScore -Method $script:method -Result @())
    @($scores.pillar) | Should -Be @('cost', 'reliability', 'security')
    foreach ($s in $scores) { $s.score | Should -BeNullOrEmpty; $s.coverage | Should -Be 0 }
  }
}

Describe 'Get-AvdAssessDecision' {
  It 'gives every method decision one row' {
    @((Get-AvdAssessDecision -Method $script:method -Snapshot $script:snapshot -Intake $script:intake -Register $script:register).decision) | Should -Be @($script:method.readiness.decision)
  }

  It 'is <status> for <decision> with the intake answered' -ForEach @(
    @{ decision = 'region'; status = 'supported' }
    @{ decision = 'hostPool.type'; status = 'supported' }
    @{ decision = 'hostPool.power'; status = 'supported' }
    @{ decision = 'hostPool.vmSize'; status = 'needs-measurement' }) {
    $rows = @(Get-AvdAssessDecision -Method $script:method -Snapshot $script:snapshot -Intake $script:intake -Register $script:register)
    @($rows | Where-Object { $_.decision -eq $decision })[0].status | Should -Be $status
  }

  It 'needs intake for a decision that takes it when none was answered' {
    $rows = @(Get-AvdAssessDecision -Method $script:method -Snapshot $script:snapshot -Register $script:register)
    @($rows | Where-Object { $_.decision -eq 'region' })[0].status | Should -Be 'needs-intake'
    @($rows | Where-Object { $_.decision -eq 'hostPool.type' })[0].status | Should -Be 'supported'
  }

  It 'is missing-facts when the snapshot has none of what a decision reads' {
    $bare = ConvertTo-Doc @{ estate = 'est-0a1b2c3d'; subscriptions = @(@{ id = 'sub-1a2b3c4d' }) }
    $rows = @(Get-AvdAssessDecision -Method $script:method -Snapshot $bare -Register $script:register)
    @($rows | Where-Object { $_.decision -eq 'hostPool.type' })[0].status | Should -Be 'missing-facts'
  }
}

Describe 'Get-AvdAssessment refuses' {
  It 'a subject without a pseudonym' {
    $leaky = ConvertTo-Doc @{ estate = 'est-0a1b2c3d'; generatedUtc = '2026-10-21T09:00:00Z'; subscriptions = @(@{ id = 'sub-1a2b3c4d'; hostPools = @(@{ id = 'hp-contoso-finance'; type = 'Personal' }) }) }
    { New-TestReport -Snapshot $leaky } | Should -Throw '*no pseudonym*'
  }

  It 'a method pinned to another register version' {
    $other = ConvertTo-Doc $script:method
    $other.factRegister = 99
    { New-TestReport -Method $other } | Should -Throw '*register*'
  }

  It 'an intake for another estate' {
    $intake = ConvertTo-Doc $script:intake
    $intake.estate = 'est-99999999'
    { New-TestReport -Intake $intake } | Should -Throw '*another estate*'
  }
}
