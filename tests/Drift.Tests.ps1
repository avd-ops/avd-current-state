#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The drift check (docs/drift-spec.md), offline: the pure functions in lib/AvdDrift.psm1 over fixtures
# that omit empty properties the way ARM does, the reviewed rule files, the C22 catalog and its pinned
# schema, and the entry point end to end against the fake Az modules (tests/fakes/). Placeholder IDs only.

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdDrift.psm1') -Force
  $script:params = Get-Content (Join-Path $script:root 'rebuild/lz-parameters.json') -Raw | ConvertFrom-Json
  $script:now = [datetime]::new(2026, 10, 21, 12, 0, 0, [DateTimeKind]::Utc)
  $script:sub = '/subscriptions/11111111-2222-4333-8444-555555555555'
  $script:hp = "$($script:sub)/resourceGroups/rg-avdlz-dev-avd/providers/Microsoft.DesktopVirtualization/hostPools/vdpool-avdlz-dev"

  function ConvertTo-Row { param($Hashtable) $Hashtable | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

  function Get-TestMap {
    param([hashtable]$Entries)
    $p = [ordered]@{}
    foreach ($k in $Entries.Keys) { $p[$k] = [ordered]@{ status = $Entries[$k][0]; value = $Entries[$k][1]; evidence = @(); note = '' } }
    return [ordered]@{ hostPool = $script:hp; landingZoneCommit = ''; parameters = $p; coverage = @{} }
  }

  function Get-TestDeployment {
    param([string]$Name, [string]$State = 'Succeeded', [string]$Time = '2026-10-20T10:00:00Z', [string]$Prefix = 'avdlz', [string]$Env = 'dev', [hashtable]$More = @{}, [string]$Correlation = 'corr-1')
    $params = @{ namePrefix = @{ type = 'String'; value = $Prefix }; environmentName = @{ type = 'String'; value = $Env }; localAdminPassword = @{ type = 'SecureString' } }
    foreach ($k in $More.Keys) { $params[$k] = @{ type = 'Int'; value = $More[$k] } }
    ConvertTo-Row @{ id = "$($script:sub)/providers/Microsoft.Resources/deployments/$Name"; name = $Name
      properties = @{ provisioningState = $State; timestamp = $Time; correlationId = $Correlation; parameters = $params } }
  }

  function Get-TestChange {
    param([string]$Id, [string]$Type, [string]$Resource, [string[]]$Props = @(), [string]$ActorType = 'User', [string]$Actor = 'someone@contoso.com', [string]$Correlation = 'corr-x', [string]$ChangeType = 'Update', [string]$Client = 'Azure Portal')
    $changes = @{}; foreach ($p in $Props) { $changes[$p] = @{ previousValue = 'a'; newValue = 'b' } }
    $body = @{ targetResourceId = $Resource; targetResourceType = $Type; changeType = $ChangeType
      changeAttributes = @{ timestamp = '2026-10-21T09:00:00Z'; changedByType = $ActorType; changedBy = $Actor; clientType = $Client; operation = "$Type/write"; correlationId = $Correlation } }
    if ($changes.Count) { $body.changes = $changes }
    ConvertFrom-DriftResourceChange -Row (ConvertTo-Row @{ id = $Id; properties = $body })
  }

  function Get-TestApproval {
    param([object[]]$Rules, [string]$On = '2026-10-01', [string]$Expires = '2026-12-01')
    $resolved = @($Rules | ForEach-Object { [pscustomobject]@{ File = 'test.json'; Rule = (ConvertTo-Row $_); Missing = @() } })
    $approvals = @($resolved | ForEach-Object { [pscustomobject]@{ entry = $_.Rule.id; digest = (Get-DriftDigest $_.Rule); approvedBy = 'owner'; approvedOn = $On; expires = $Expires } })
    Get-DriftSuppressionApproval -Rules $resolved -Approvals $approvals -Now $script:now
  }
}

Describe 'values' {
  It 'gives the same canonical JSON and digest whatever the key order or object kind' {
    $a = ConvertTo-DriftCanonicalJson ([ordered]@{ b = @(1, $true, $null); a = 'x"y'; c = @{ d = 2.5 } })
    $b = ConvertTo-DriftCanonicalJson (ConvertTo-Row @{ c = @{ d = 2.5 }; a = 'x"y'; b = @(1, $true, $null) })
    $a | Should -Be '{"a":"x\"y","b":[1,true,null],"c":{"d":2.5}}'
    $b | Should -Be $a
    # Pinned so the digest is the same on Windows PowerShell 5.1, PowerShell 7 and any other reader.
    Get-DriftDigest ([ordered]@{ b = @(1, $true, $null); a = 'x"y'; c = @{ d = 2.5 } }) | Should -Be '9e19eb66bb1f5e0324f4bd338d92ba2763d5f2bf53a49ebf9cfc605346b4d059'
  }

  It 'renders estate text as a literal Markdown cannot turn into a link or a mention' {
    $out = ConvertTo-DriftLiteral "[click](https://example.com) @someone ``x``"
    $out | Should -Match '^`[^`]*`$'
    $out | Should -Not -Match '``'
  }

  It 'derives the landing zone names from its two naming parameters' {
    $n = Get-DriftLandingZoneName -NamePrefix 'Avd-Lz' -Environment 'dev'
    $n.hostPool | Should -Be 'vdpool-avdlz-dev'
    $n.resourceGroupPrefix | Should -Be 'rg-avdlz-dev-'
  }
}

Describe 'the declared side' {
  It 'takes the latest successful avdlz deployment and leaves secure parameters out' {
    $d = @(
      (Get-TestDeployment 'avdlz-dev-20261019-1000' -Time '2026-10-19T10:00:00Z' -More @{ maxSessionLimit = 4 }),
      (Get-TestDeployment 'avdlz-dev-20261020-1000' -More @{ maxSessionLimit = 8 } -Correlation 'corr-2'),
      (Get-TestDeployment 'avdlz-dev-20261021-1000' -State 'Failed' -Time '2026-10-21T10:00:00Z' -More @{ maxSessionLimit = 99 }),
      (Get-TestDeployment 'other-deployment' -Time '2026-10-21T11:00:00Z' -More @{ maxSessionLimit = 1 }))
    $s = Get-DriftDeclaredState -Deployments $d
    $s.deployment | Should -Be 'avdlz-dev-20261020-1000'
    $s.parameters.maxSessionLimit | Should -Be 8
    $s.parameters.Contains('localAdminPassword') | Should -BeFalse
    $s.secure | Should -Be @('localAdminPassword')
    $s.names.hostPool | Should -Be 'vdpool-avdlz-dev'
    Get-DriftLandingZoneCorrelationId -Deployments $d | Should -Be @('corr-1', 'corr-2')
    # Another landing zone's deployments in the same subscription explain nothing here.
    $d += Get-TestDeployment 'avdlz-test-1' -Env 'test' -Correlation 'corr-other'
    Get-DriftLandingZoneCorrelationId -Deployments $d -NamePrefix 'avdlz' -Environment 'dev' | Should -Not -Contain 'corr-other'
  }

  It 'asks for -Environment when the subscription holds two, and returns nothing when none matches' {
    $d = @((Get-TestDeployment 'avdlz-dev-1'), (Get-TestDeployment 'avdlz-test-1' -Env 'test'))
    { Get-DriftDeclaredState -Deployments $d } | Should -Throw '*Pass -Environment*'
    (Get-DriftDeclaredState -Deployments $d -Environment 'test').names.hostPool | Should -Be 'vdpool-avdlz-test'
    Get-DriftDeclaredState -Deployments @() | Should -BeNullOrEmpty
  }
}

Describe 'parameter drift' {
  BeforeAll {
    $script:map = Get-TestMap @{
      maxSessionLimit = @('found', 10); startVmOnConnect = @('found', $false); localAdminPassword = @('secret', $null)
      sessionHostCount = @('deployTime', 2); rdpProperties = @('unexpressible', $null); tags = @('found', @{}); dnsServers = @('derived', @())
      enableAvdPrivateLink = @('found', $true); scalingTimeZone = @('found', 'UTC')
    }
    $script:declared = [ordered]@{ maxSessionLimit = 8; startVmOnConnect = $true; sessionHostCount = 3; rdpProperties = 'x'; tags = @{}; dnsServers = @()
      enableAvdPrivateLink = $false; scalingTimeZone = 'Eastern Standard Time'; someNewParameter = 1 }
  }

  It 'reports a changed value with both values, and compares empty values without false drift' {
    $f = Get-DriftParameterResult -Map $script:map -Declared $script:declared -ParameterList $script:params -Now $script:now
    $d = @($f | Where-Object { $_.kind -eq 'drift' })
    ($d.subject | Sort-Object) | Should -Be @('enableAvdPrivateLink', 'maxSessionLimit', 'scalingTimeZone', 'startVmOnConnect')
    $m = $d | Where-Object subject -eq 'maxSessionLimit'
    $m.data.declared | Should -Be 8
    $m.data.live | Should -Be 10
    $m.open | Should -BeTrue
    @($f | Where-Object { $_.subject -in @('tags', 'dnsServers', 'localAdminPassword', 'sessionHostCount') }).Count | Should -Be 0
  }

  It "says what it can't read back, and reports deployed parameters this version doesn't map once" {
    $f = Get-DriftParameterResult -Map $script:map -Declared $script:declared -ParameterList $script:params -Now $script:now
    $c = @($f | Where-Object { $_.kind -eq 'cant-tell' })
    $c.subject | Should -Be 'rdpProperties'
    $c.open | Should -BeTrue
    $n = @($f | Where-Object { $_.kind -eq 'not-mapped' })
    $n.Count | Should -Be 1
    $n.open | Should -BeFalse
    $n.message | Should -Match 'someNewParameter'
  }

  It 'treats Start VM on Connect off as expected while the power lock holds' {
    $f = Get-DriftParameterResult -Map $script:map -Declared $script:declared -ParameterList $script:params -Now $script:now -PowerLocked $true
    $s = $f | Where-Object subject -eq 'startVmOnConnect'
    $s.kind | Should -Be 'accepted'
    $s.open | Should -BeFalse
  }

  It 'honors an exception only for its accepted value and only until it expires' {
    $ex = @(
      (ConvertTo-Row @{ parameter = 'maxSessionLimit'; acceptedValue = 10; reason = 'pilot'; expires = '2026-11-01' }),
      (ConvertTo-Row @{ parameter = 'scalingTimeZone'; acceptedValue = 'UTC'; reason = 'old'; expires = '2026-10-01' }),
      (ConvertTo-Row @{ parameter = 'enableAvdPrivateLink'; acceptedValue = $false; reason = 'value moved again'; expires = '2026-12-01' }),
      (ConvertTo-Row @{ parameter = 'rdpProperties'; status = 'unexpressible'; reason = 'custom string'; expires = '2026-12-01' }))
    $f = Get-DriftParameterResult -Map $script:map -Declared $script:declared -ParameterList $script:params -Exceptions $ex -Now $script:now
    ($f | Where-Object subject -eq 'maxSessionLimit').kind | Should -Be 'accepted'
    ($f | Where-Object subject -eq 'scalingTimeZone').kind | Should -Be 'expired-exception'
    ($f | Where-Object subject -eq 'enableAvdPrivateLink').kind | Should -Be 'drift'
    $r = $f | Where-Object subject -eq 'rdpProperties'
    $r.kind | Should -Be 'cant-tell'
    $r.open | Should -BeFalse
  }

  It 'takes a renewed exception appended after the expired one' {
    $ex = @(
      (ConvertTo-Row @{ parameter = 'scalingTimeZone'; acceptedValue = 'UTC'; reason = 'old'; expires = '2026-10-01' }),
      (ConvertTo-Row @{ parameter = 'scalingTimeZone'; acceptedValue = 'UTC'; reason = 'renewed'; expires = '2026-12-01' }))
    $f = Get-DriftParameterResult -Map $script:map -Declared $script:declared -ParameterList $script:params -Exceptions $ex -Now $script:now
    ($f | Where-Object subject -eq 'scalingTimeZone').kind | Should -Be 'accepted'
  }

  It 'proposes a baseline from found and derived values only, with the resource groups to watch' {
    $b = Get-DriftBaselineProposal -Map $script:map -ResourceGroups @('RG-Pool', 'rg-hosts', 'rg-pool')
    $b.resourceGroups | Should -Be @('rg-hosts', 'rg-pool')
    $b.parameters.Contains('maxSessionLimit') | Should -BeTrue
    $b.parameters.Contains('rdpProperties') | Should -BeFalse
    $b.parameters.Contains('localAdminPassword') | Should -BeFalse
  }
}

Describe 'changes and attribution' {
  BeforeAll {
    $script:vm = "$($script:sub)/resourceGroups/rg-avdlz-dev-hosts/providers/Microsoft.Compute/virtualMachines/avdlzdsh-001"
    $script:runtime = @(@{ id = 'vm-power-state'; types = @('microsoft.compute/virtualmachines'); properties = @('properties.extended.instanceView') },
      @{ id = 'modified-stamps'; properties = @('systemData') })
    $script:actors = @(@{ id = 'auto-shutdown-scaling-exclusion'; actorType = 'AppId'; actor = 'aaaaaaaa-0000-4000-8000-000000000001'; types = @('microsoft.compute/virtualmachines'); properties = @('tags.avd-scaling-exclude') })
  }

  It 'reads change rows and Activity Log events the way ARM returns them' {
    $c = Get-TestChange 'c1' 'microsoft.compute/virtualmachines' $script:vm @('tags.x')
    $c.resourceId | Should -Be $script:vm.ToLowerInvariant()
    $c.properties | Should -Be @('tags.x')
    (Get-TestChange 'c2' 'microsoft.compute/virtualmachines' $script:vm -ChangeType 'Delete').properties.Count | Should -Be 0
    $ev = { param($status, $op) ConvertTo-Row @{ eventDataId = 'e1'; status = @{ value = $status }; operationName = @{ value = $op }; caller = 'someone@contoso.com'; correlationId = 'corr-y'; resourceId = "$($script:sub)/resourceGroups/rg-avdlz-dev-avd/providers/Microsoft.Authorization/roleAssignments/r1"; eventTimestamp = '2026-10-21T08:00:00Z' } }
    $a = ConvertFrom-DriftActivityEvent -ActivityEvent (& $ev 'Succeeded' 'Microsoft.Authorization/roleAssignments/write')
    $a.type | Should -Be 'microsoft.authorization/roleassignments'
    $a.actorType | Should -Be 'User'
    ConvertFrom-DriftActivityEvent -ActivityEvent (& $ev 'Started' 'Microsoft.Authorization/roleAssignments/write') | Should -BeNullOrEmpty
    # A type the change log covers is left to it, unless the event is older than the change log's window.
    ConvertFrom-DriftActivityEvent -ActivityEvent (& $ev 'Succeeded' 'Microsoft.Compute/virtualMachines/write') | Should -BeNullOrEmpty
    (ConvertFrom-DriftActivityEvent -ActivityEvent (& $ev 'Succeeded' 'Microsoft.Compute/virtualMachines/write') -AnyType).type | Should -Be 'microsoft.compute/virtualmachines'
    ConvertFrom-DriftActivityEvent -ActivityEvent (& $ev 'Succeeded' 'Microsoft.Compute/virtualMachines/write') | Should -BeNullOrEmpty
  }

  It 'explains deployments by correlation ID, run-time state and approved automation, and nothing else' {
    $changes = @(
      (Get-TestChange 'd1' 'microsoft.compute/virtualmachines' $script:vm @('properties.hardwareProfile.vmSize') -Correlation 'corr-dep'),
      (Get-TestChange 'r1' 'microsoft.compute/virtualmachines' $script:vm @('properties.extended.instanceView.powerState.code', 'systemData.lastModifiedAt') -ActorType 'System' -Actor 'System'),
      (Get-TestChange 'a1' 'microsoft.compute/virtualmachines' $script:vm @('tags.avd-scaling-exclude', 'systemData.lastModifiedAt') -ActorType 'AppId' -Actor 'aaaaaaaa-0000-4000-8000-000000000001'),
      (Get-TestChange 'u1' 'microsoft.compute/virtualmachines' $script:vm @('tags.avd-scaling-exclude') -ActorType 'User'),
      (Get-TestChange 'u1' 'microsoft.compute/virtualmachines' $script:vm @('tags.avd-scaling-exclude') -ActorType 'User'))
    $approval = @{}; foreach ($a in (Get-TestApproval ($script:runtime + $script:actors))) { $approval[$a.id] = $a.state }
    $rows = Get-DriftAttribution -Changes $changes -DeploymentCorrelationIds @('corr-dep') -ExpectedActors $script:actors -RuntimePaths $script:runtime -Approval $approval
    $rows.Count | Should -Be 4
    @($rows | ForEach-Object { "$($_.change.id)=$($_.by)" }) | Should -Be @('d1=deployment', 'r1=runtime', 'a1=automation', 'u1=unexplained')
    ($rows | Where-Object { $_.change.id -eq 'a1' }).rules | Should -Be @('modified-stamps', 'auto-shutdown-scaling-exclusion')
    $f = Get-DriftChangeResult -Attribution $rows
    $f.Count | Should -Be 1
    $f[0].message | Should -Match 'by a user'
    $f[0].message | Should -Not -Match 'contoso'
    ($f | ConvertTo-Json -Depth 10) | Should -Not -Match '@contoso'
  }

  It 'hides nothing with an unapproved rule, and names the rule that would have' {
    $changes = @(Get-TestChange 'r1' 'microsoft.compute/virtualmachines' $script:vm @('properties.extended.instanceView.powerState.code') -ActorType 'System' -Actor 'System')
    $rows = Get-DriftAttribution -Changes $changes -RuntimePaths $script:runtime -Approval @{ 'vm-power-state' = 'expired' }
    $rows[0].by | Should -Be 'unexplained'
    $rows[0].wouldMatch | Should -Be @('vm-power-state')
    (Get-DriftChangeResult -Attribution $rows)[0].message | Should -Match "aren't approved"
  }

  It 'reports a window gap only when the last run is older than the change log keeps' {
    (Get-DriftWindowGap -LastSuccess '2026-10-01T00:00:00Z' -Now $script:now).kind | Should -Be 'window-gap'
    @(Get-DriftWindowGap -LastSuccess '2026-10-18T00:00:00Z' -Now $script:now).Count | Should -Be 0
    @(Get-DriftWindowGap -LastSuccess $null -Now $script:now).Count | Should -Be 0
  }
}

Describe 'suppression rules: approval and digest' {
  BeforeAll {
    $script:rule = ConvertTo-Row @{ id = 'auto-shutdown-pool-lock'; actorType = 'AppId'; actor = '<auto-shutdown-principal-id>'; types = @('microsoft.desktopvirtualization/hostpools') }
    $script:values = @{ 'auto-shutdown-principal-id' = 'aaaaaaaa-0000-4000-8000-000000000001' }
  }

  It 'resolves placeholders before the digest, and a missing value leaves the rule unresolved' {
    $r = Resolve-DriftRule -Rule $script:rule -Values $script:values
    $r.Rule.actor | Should -Be 'aaaaaaaa-0000-4000-8000-000000000001'
    $r.Missing.Count | Should -Be 0
    $u = Resolve-DriftRule -Rule $script:rule -Values @{}
    $u.Missing | Should -Be @('auto-shutdown-principal-id')
    $a = Get-DriftSuppressionApproval -Rules @([pscustomobject]@{ File = 'x'; Rule = $u.Rule; Missing = $u.Missing }) -Now $script:now
    $a.state | Should -Be 'unresolved'
  }

  It 'approves only the exact digest, within 90 days and before it expires' {
    $r = [pscustomobject]@{ File = 'expected-actors.json'; Rule = (Resolve-DriftRule -Rule $script:rule -Values $script:values).Rule; Missing = @() }
    $digest = Get-DriftDigest $r.Rule
    $case = { param($d, $on, $exp) (Get-DriftSuppressionApproval -Rules @($r) -Approvals @([pscustomobject]@{ entry = 'auto-shutdown-pool-lock'; digest = $d; approvedOn = $on; expires = $exp }) -Now $script:now).state }
    & $case $digest '2026-10-01' '2026-12-01' | Should -Be 'approved'
    & $case ('0' * 64) '2026-10-01' '2026-12-01' | Should -Be 'changed'
    & $case $digest '2026-08-01' '2026-10-20' | Should -Be 'expired'
    & $case $digest '2026-10-01' '2027-03-01' | Should -Be 'expired'
    (Get-DriftSuppressionApproval -Rules @($r) -Now $script:now).state | Should -Be 'unapproved'
  }

  It 'prints an approval line that, once pasted, approves the rule' {
    $r = [pscustomobject]@{ File = 'expected-actors.json'; Rule = (Resolve-DriftRule -Rule $script:rule -Values $script:values).Rule; Missing = @() }
    $a = (Get-DriftSuppressionApproval -Rules @($r) -Now $script:now)[0]
    $line = Get-DriftApprovalLine -Approval $a -Now $script:now -Days 60
    (Get-DriftSuppressionApproval -Rules @($r) -Approvals @($line | ConvertFrom-Json) -Now $script:now).state | Should -Be 'approved'
    { Get-DriftApprovalLine -Approval $a -Days 120 } | Should -Throw
    # Unapproved, it hides nothing; it is an open finding only once it would have hidden a change.
    $f = Get-DriftSuppressionResult -Approval @($a)
    $f.kind | Should -Be 'suppression-unapproved'
    $f.open | Should -BeFalse
    $c = [pscustomobject]@{ timestamp = $script:now; type = 't'; operation = 'o'; correlationId = 'c' }
    $f = Get-DriftSuppressionResult -Approval @($a) -Attribution @([pscustomobject]@{ change = $c; by = 'unexplained'; rules = @(); wouldMatch = @($a.id) })
    $f.open | Should -BeTrue
  }

  It 'takes a renewal appended after an expired approval, and ignores an approval for another digest' {
    $r = [pscustomobject]@{ File = 'expected-actors.json'; Rule = (Resolve-DriftRule -Rule $script:rule -Values $script:values).Rule; Missing = @() }
    $a = (Get-DriftSuppressionApproval -Rules @($r) -Now $script:now)[0]
    $old = Get-DriftApprovalLine -Approval $a -Now $script:now.AddDays(-100) -Days 30 | ConvertFrom-Json
    $new = Get-DriftApprovalLine -Approval $a -Now $script:now.AddDays(-1) -Days 30 | ConvertFrom-Json
    (Get-DriftSuppressionApproval -Rules @($r) -Approvals @($old) -Now $script:now).state | Should -Be 'expired'
    (Get-DriftSuppressionApproval -Rules @($r) -Approvals @($old, $new) -Now $script:now).state | Should -Be 'approved'
    $other = $new.PSObject.Copy(); $other.digest = 'x' * 64
    (Get-DriftSuppressionApproval -Rules @($r) -Approvals @($other) -Now $script:now).state | Should -Be 'changed'
  }

  It 'closes the finding of a rule that needs a private value nobody set' {
    $unresolved = [pscustomobject]@{ id = 'needs-value'; file = 'a'; state = 'unresolved'; expires = $null; digest = ''; missing = @('<x>') }
    @(Get-DriftSuppressionResult -Approval @($unresolved) | Where-Object { $_.open }).Count | Should -Be 0
  }

  It 'digests what each rule hid, which hid nothing and which approvals expire soon' {
    $approval = @(
      [pscustomobject]@{ id = 'busy'; file = 'a'; state = 'approved'; expires = $script:now.AddDays(10); digest = ''; missing = @() },
      [pscustomobject]@{ id = 'idle'; file = 'a'; state = 'approved'; expires = $script:now.AddDays(60); digest = ''; missing = @() })
    $c = [pscustomobject]@{ timestamp = $script:now.AddDays(-1); type = 't'; operation = 'o'; correlationId = 'c' }
    $attr = @(1..3 | ForEach-Object { [pscustomobject]@{ change = $c; by = 'automation'; rules = @('busy'); wouldMatch = @() } })
    $d = Get-DriftSuppressionDigest -Approval $approval -Attribution $attr -Now $script:now -Threshold 2
    $d[0].id | Should -Be 'busy'
    $d[0].hid7 | Should -Be 3
    $d[0].overThreshold | Should -BeTrue
    $d[0].expiringSoon | Should -BeTrue
    $d[0].examples.Count | Should -Be 3
    $d[1].unused | Should -BeTrue
  }
}

Describe 'outcome and report' {
  It 'exits 2 when it could not check, 1 on open findings, and 0 only when clean' {
    $open = Get-DriftFinding -Check 'drift-param' -Kind 'drift' -Subject 'x' -Message 'm'
    $closed = Get-DriftFinding -Check 'drift-param' -Kind 'accepted' -Subject 'x' -Message 'm' -Open $false
    $cant = Get-DriftFinding -Check 'drift-couldnt-check' -Kind 'couldnt-check' -Subject 'x' -Message 'm'
    Get-DriftExitCode -Findings @($open, $cant) | Should -Be 2
    Get-DriftExitCode -Findings @($open, $closed) | Should -Be 1
    Get-DriftExitCode -Findings @($closed) | Should -Be 0
    Get-DriftExitCode -Findings @() | Should -Be 0
  }

  It 'never calls an incomplete run clean' {
    $cant = Get-DriftFinding -Check 'drift-couldnt-check' -Kind 'couldnt-check' -Subject 'x' -Message 'reads failed'
    $md = Get-DriftReport -Environment 'avdlz-dev' -Findings @($cant) -ExitCode 2
    $md | Should -Match "Couldn't check"
    $md | Should -Not -Match 'Clean:'
  }
}

Describe 'the rule files and the catalog' {
  It 'keeps the public rule files to placeholders, with unique IDs' {
    foreach ($f in 'expected-actors.json', 'runtime-paths.json') {
      $text = Get-Content (Join-Path $script:root "drift/$f") -Raw
      $text | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' -Because "$f holds placeholders only"
      $doc = $text | ConvertFrom-Json
      $doc.schema | Should -Be 'avd-current-state-drift-rules/v1'
      $ids = @($doc.rules | ForEach-Object { $_.id })
      $ids.Count | Should -Be @($ids | Sort-Object -Unique).Count
      foreach ($r in $doc.rules) { $r.why | Should -Not -BeNullOrEmpty -Because $r.id }
    }
  }

  It 'vendors the C22 schema byte for byte, and the catalog passes it' {
    $pins = Get-Content (Join-Path $script:root 'checks/PINS.json') -Raw | ConvertFrom-Json
    foreach ($f in $pins.files.PSObject.Properties) {
      (Get-FileHash (Join-Path $script:root "checks/$($f.Name)") -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $f.Value -Because $f.Name
    }
    $errs = $null
    Test-Json -Json (Get-Content (Join-Path $script:root 'checks/catalog.json') -Raw) -SchemaFile (Join-Path $script:root 'checks/check-catalog.schema.json') -ErrorVariable errs -ErrorAction SilentlyContinue | Should -BeTrue -Because "$errs"
  }

  It 'lists every check the drift code reports, and each impl is a function the module exports' {
    $catalog = Get-Content (Join-Path $script:root 'checks/catalog.json') -Raw | ConvertFrom-Json
    $ids = @($catalog.checks | ForEach-Object { $_.id })
    $code = (Get-Content (Join-Path $script:root 'lib/AvdDrift.psm1') -Raw) + (Get-Content (Join-Path $script:root 'avd_current_state_drift.ps1') -Raw)
    $used = @([regex]::Matches($code, "-Check '([a-z-]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $used.Count | Should -BeGreaterThan 5
    foreach ($u in $used) { $ids | Should -Contain $u }
    $exported = @((Get-Module AvdDrift).ExportedFunctions.Keys)
    foreach ($c in $catalog.checks) { $exported | Should -Contain $c.impl -Because $c.id }
  }
}

Describe 'the sample workflow (samples/drift.yml)' {
  BeforeAll { $script:yml = Get-Content (Join-Path $script:root 'samples/drift.yml') -Raw }

  It 'runs on a schedule or by hand only, never on pull requests' {
    $script:yml | Should -Match '(?m)^on:\s*\n\s+schedule:'
    $script:yml | Should -Match '(?m)^  workflow_dispatch:'
    $script:yml | Should -Not -Match 'pull_request'
    $script:yml | Should -Not -Match '(?m)^  push:'
  }

  It 'asks only for the permissions it needs and signs in with OIDC, no secret' {
    $block = [regex]::Match($script:yml, '(?ms)^permissions:\s*\n(.*?)\n\S').Groups[1].Value
    @($block -split '\n' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } | Sort-Object) | Should -Be @('actions: read', 'contents: read', 'id-token: write', 'issues: write')
    $script:yml | Should -Not -Match 'secrets\.'
    $script:yml | Should -Match 'client-id: \$\{\{ vars\.AVD_READER_CLIENT_ID \}\}'
    $script:yml | Should -Match 'environment: avd-reader'
  }

  It 'pins every action by commit SHA and never uploads an artifact' {
    $uses = @([regex]::Matches($script:yml, '(?m)uses:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
    $uses.Count | Should -BeGreaterThan 2
    foreach ($u in $uses) { $u | Should -Match '@[0-9a-f]{40}$' }
    $script:yml | Should -Not -Match 'upload-artifact'
    @([regex]::Matches($script:yml, 'persist-credentials: false')).Count | Should -Be 2
  }

  It 'checks the repository is private with a real call before anything else, and guards the issue on it' {
    $first = [regex]::Match($script:yml, '(?ms)steps:\s*\n\s+- name: ([^\n]+)').Groups[1].Value
    $first | Should -Match 'private'
    $script:yml | Should -Match 'gh api "repos/\$GITHUB_REPOSITORY" --jq \.private'
    $script:yml | Should -Match "if: always\(\) && env\.DRIFT_REPO_PRIVATE == 'true'"
  }

  It 'keeps workflow expressions out of run blocks, so no input reaches a shell as code' {
    foreach ($m in [regex]::Matches($script:yml, '(?ms)run: \|\s*\n(.*?)(?=\n      - |\z)')) { $m.Groups[1].Value | Should -Not -Match '\$\{\{' }
  }

  It 'closes the issue only on a clean run' {
    $script:yml | Should -Match '(?s)if \[ "\$CODE" = "0" \]; then\s+gh issue close'
  }
}

Describe 'the entry point, offline' {
  BeforeAll {
    $script:pwsh = (Get-Process -Id $PID).Path
    $script:fakes = Join-Path $script:root 'tests/fakes'
    $script:script = Join-Path $script:root 'avd_current_state_drift.ps1'
    function Invoke-Drift {
      param([string]$Arguments, [object[]]$Routes = @(), [hashtable]$Env = @{})
      $routesPath = Join-Path $TestDrive ("routes-{0}.json" -f [guid]::NewGuid())
      ConvertTo-Json -InputObject @($Routes) -Depth 40 | Set-Content -LiteralPath $routesPath
      $saved = @{ PSModulePath = $env:PSModulePath; FAKEAZ_ROUTES = $env:FAKEAZ_ROUTES; GITHUB_ACTIONS = $env:GITHUB_ACTIONS; DRIFT_REPO_PRIVATE = $env:DRIFT_REPO_PRIVATE }
      try {
        $env:PSModulePath = $script:fakes
        $env:FAKEAZ_ROUTES = $routesPath
        $env:GITHUB_ACTIONS = $Env.GITHUB_ACTIONS
        $env:DRIFT_REPO_PRIVATE = $Env.DRIFT_REPO_PRIVATE
        $command = "`$env:PSModulePath = '$($script:fakes)'; & '$($script:script)' $Arguments; exit `$LASTEXITCODE"
        $log = & $script:pwsh -NoProfile -NonInteractive -Command $command 2>&1
        return @{ Code = $LASTEXITCODE; Text = ($log | Out-String) }
      } finally {
        foreach ($k in $saved.Keys) { Set-Item -Path "env:$k" -Value $saved[$k] }
      }
    }
  }

  It "stops in GitHub Actions unless the workflow confirmed the repository is private" {
    $r = Invoke-Drift -Arguments "-OutputPath '$(Join-Path $TestDrive 'gha')'" -Env @{ GITHUB_ACTIONS = 'true' }
    $r.Code | Should -Be 2 -Because $r.Text
    $r.Text | Should -Match 'private repository'
  }

  It "fails closed on an empty subscription: no deployment record is a couldn't-check, never clean" {
    $out = Join-Path $TestDrive 'empty'
    $r = Invoke-Drift -Arguments "-OutputPath '$out'"
    $r.Code | Should -Be 2 -Because $r.Text
    $r.Text | Should -Match 'RESULT COULDNT-CHECK'
    Get-Content (Join-Path $out 'drift-report.md') -Raw | Should -Match "Couldn't check"
    (Get-Content (Join-Path $out 'drift-results.json') -Raw | ConvertFrom-Json).exitCode | Should -Be 2
  }

  It 'prints digests and approval lines offline' {
    $r = Invoke-Drift -Arguments '-ShowSuppressionDigest'
    $r.Code | Should -Be 0 -Because $r.Text
    $r.Text | Should -Match 'vm-power-state \(runtime-paths.json\): unapproved'
    $r.Text | Should -Match 'auto-shutdown-pool-lock .*: unresolved'
    $r.Text | Should -Match '"approvedBy":"owner"'
  }

  It 'compares a deployed landing zone, attributes its changes and writes the report' {
    $hpRow = @{ id = $script:hp; name = 'vdpool-avdlz-dev'; type = 'microsoft.desktopvirtualization/hostpools'; location = 'northcentralus'; tags = @{ environment = 'dev' }
      properties = @{ hostPoolType = 'Pooled'; maxSessionLimit = 12; validationEnvironment = $true; startVMOnConnect = $true } }
    $rgRow = @{ id = "$($script:sub)/resourceGroups/rg-avdlz-dev-avd"; name = 'rg-avdlz-dev-avd'; type = 'microsoft.resources/subscriptions/resourcegroups'; location = 'northcentralus' }
    $dep = @{ id = "$($script:sub)/providers/Microsoft.Resources/deployments/avdlz-dev-1"; name = 'avdlz-dev-1'
      properties = @{ provisioningState = 'Succeeded'; timestamp = '2026-10-20T10:00:00Z'; correlationId = 'corr-dep'
        parameters = @{ namePrefix = @{ type = 'String'; value = 'avdlz' }; environmentName = @{ type = 'String'; value = 'dev' }; maxSessionLimit = @{ type = 'Int'; value = 8 }; localAdminPassword = @{ type = 'SecureString' } } } }
    $change = @{ id = 'chg-1'; properties = @{ targetResourceId = $script:hp; targetResourceType = 'microsoft.desktopvirtualization/hostpools'; changeType = 'Update'
        changes = @{ 'properties.maxSessionLimit' = @{ previousValue = '8'; newValue = '12' } }
        changeAttributes = @{ timestamp = '2026-10-21T09:00:00Z'; changedByType = 'User'; changedBy = 'someone@contoso.com'; clientType = 'Azure Portal'; operation = 'Microsoft.DesktopVirtualization/hostPools/write'; correlationId = 'corr-portal' } } }
    $event = @{ eventDataId = 'ev-1'; status = @{ value = 'Succeeded' }; operationName = @{ value = 'Microsoft.Authorization/roleAssignments/write' }; caller = 'someone@contoso.com'
      correlationId = 'corr-role'; resourceId = "$($script:sub)/resourceGroups/rg-avdlz-dev-avd/providers/Microsoft.Authorization/roleAssignments/r1"; eventTimestamp = '2026-10-21T08:00:00Z' }
    # A role assignment at subscription scope sits in no resource group; the subscription-wide read finds it.
    $subEvent = @{ eventDataId = 'ev-2'; status = @{ value = 'Succeeded' }; operationName = @{ value = 'Microsoft.Authorization/roleAssignments/write' }; caller = 'someone@contoso.com'
      correlationId = 'corr-subrole'; resourceId = "$($script:sub)/providers/Microsoft.Authorization/roleAssignments/r2"; eventTimestamp = '2026-10-21T08:30:00Z' }
    $graph = { param($rows) @{ totalRecords = @($rows).Count; count = @($rows).Count; data = @($rows) } }
    $routes = @(
      @{ match = 'resourcechanges'; status = 200; content = (& $graph @($change)) },
      @{ match = "hostpools/sessionhosts'"; status = 200; content = (& $graph @()) },
      @{ match = "desktopvirtualization/hostpools'"; status = 200; content = (& $graph @($hpRow)) },
      @{ match = "subscriptions/resourcegroups'"; status = 200; content = (& $graph @($rgRow)) },
      @{ match = 'ResourceGraph|^\{'; status = 200; content = (& $graph @()) },
      @{ match = 'Microsoft.Resources/deployments\?'; status = 200; content = @{ value = @($dep) } },
      @{ match = 'resourceProvider'; status = 200; content = @{ value = @($event, $subEvent) } },
      @{ match = 'eventtypes/management/values'; status = 200; content = @{ value = @($event) } })
    $out = Join-Path $TestDrive 'deployed'
    $r = Invoke-Drift -Arguments "-OutputPath '$out' -Digest" -Routes $routes
    $r.Code | Should -Be 1 -Because $r.Text
    $r.Text | Should -Match 'Declared state: deployment-record avdlz-dev-1, host pool vdpool-avdlz-dev'
    $r.Text | Should -Not -Match 'contoso'
    $results = Get-Content (Join-Path $out 'drift-results.json') -Raw | ConvertFrom-Json
    $drift = @($results.findings | Where-Object { $_.kind -eq 'drift' })
    $drift.subject | Should -Contain 'maxSessionLimit'
    $changes = @($results.findings | Where-Object { $_.kind -eq 'unexplained-change' })
    $changes.Count | Should -Be 3
    $md = Get-Content (Join-Path $out 'drift-report.md') -Raw
    $md | Should -Match 'Weekly digest of suppression rules'
    $md | Should -Match 'by a user'
    $md | Should -Not -Match 'contoso'
    $manifest = Get-Content (Join-Path $out 'manifest.json') -Raw | ConvertFrom-Json
    $manifest.files.'drift-report.md' | Should -Be (Get-FileHash (Join-Path $out 'drift-report.md') -Algorithm SHA256).Hash.ToLowerInvariant()
  }

  It "reads a baseline's resource groups, and says couldn't check when it lists none" {
    $base = Join-Path $TestDrive 'baseline.json'
    @{ schema = 'avd-current-state-drift-baseline/v1'; hostPool = $script:hp; parameters = @{ maxSessionLimit = 8 } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $base
    $r = Invoke-Drift -Arguments "-OutputPath '$(Join-Path $TestDrive 'nogroups')' -BaselinePath '$base'"
    $r.Code | Should -Be 2 -Because $r.Text
    $r.Text | Should -Match 'lists no resource groups'
  }

  It 'writes no baseline proposal when a read failed' {
    $out = Join-Path $TestDrive 'propose'
    $r = Invoke-Drift -Arguments "-OutputPath '$out' -ProposeBaseline" -Routes @(@{ match = 'desktopvirtualization/hostpools'; status = 403; content = 'denied' })
    $r.Code | Should -Be 2 -Because $r.Text
    $r.Text | Should -Match 'no baseline was proposed'
    @(Get-ChildItem -Path $out -Filter 'drift-baseline.proposed.*' -ErrorAction SilentlyContinue).Count | Should -Be 0
  }
}
