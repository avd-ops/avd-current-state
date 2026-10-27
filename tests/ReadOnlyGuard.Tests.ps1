#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# AST and runtime read-only guard tests across all five control planes (docs/five-plane-assess-current-state-spec.md, section 2.3).

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdRebuild.psm1') -Force

  function New-TestJwt {
    param([hashtable]$Payload)
    $headerB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $bodyJson = $Payload | ConvertTo-Json -Compress
    $bodyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bodyJson)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "$headerB64.$bodyB64.signature"
  }
}

Describe 'PowerShell AST read-only guard' {
  BeforeAll {
    $script:readOnlyScripts = @(
      'avd_current_state_collector.ps1',
      'avd_current_state_facts.ps1',
      'avd_current_state_drift.ps1',
      'avd_deployment_validator.ps1'
    )
    $script:files = @(
      $script:readOnlyScripts | ForEach-Object { Get-Item (Join-Path $script:root $_) }
      Get-ChildItem -Path (Join-Path $script:root 'lib') -Filter '*.psm1' -File
    )
  }

  It 'parses every collector, validator, facts, drift and library file without syntax errors' {
    $script:files.Count | Should -BeGreaterOrEqual 6
    foreach ($file in $script:files) {
      $tokens = $null
      $errors = $null
      $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
      @($errors).Count | Should -Be 0 -Because $file.Name
    }
  }

  It 'never calls write cmdlets against Azure, Graph, Intune, M365 or Power Platform' {
    $forbiddenPattern = '^((Set-(?!AzContext$)|New-|Remove-|Update-|Clear-|Reset-|Stop-|Start-|Restart-|Grant-|Revoke-)(Az|Mg|Cs|AdminPowerApp|PowerApp))'
    foreach ($file in $script:files) {
      $tokens = $null
      $errors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
      $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
      foreach ($cmd in $commands) {
        $name = $cmd.GetCommandName()
        if ($name) {
          $name | Should -Not -Match $forbiddenPattern -Because "$($file.Name) line $($cmd.Extent.StartLineNumber)"
        }
      }
    }
  }

  It 'never invokes REST with PUT, PATCH or DELETE, and uses POST only for Resource Graph' {
    foreach ($file in $script:files) {
      $tokens = $null
      $errors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
      $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
      foreach ($cmd in $commands) {
        $name = $cmd.GetCommandName()
        if ($name -in @('Invoke-AzRestMethod', 'Invoke-RestMethod', 'Invoke-WebRequest')) {
          $text = $cmd.Extent.Text
          $text | Should -Not -Match '-Method\s+[''"]?(PUT|PATCH|DELETE)\b' -Because "$($file.Name) line $($cmd.Extent.StartLineNumber)"
          if ($text -match '-Method\s+[''"]?POST\b') {
            $text | Should -Match 'Microsoft\.ResourceGraph/resources' -Because "$($file.Name) line $($cmd.Extent.StartLineNumber)"
          }
        }
      }
    }
  }
}

Describe 'Multi-plane scope allowlist (rebuild/scope.json)' {
  BeforeAll {
    $script:scope = Get-RebuildScope -Path (Join-Path $script:root 'rebuild/scope.json')
  }

  It 'declares all five control planes with read-only permissions and methods' {
    $planes = @($script:scope.planes.PSObject.Properties.Name)
    $planes | Should -Be @('azure', 'entra', 'intune', 'm365', 'powerPlatform')
    foreach ($p in $planes) {
      $def = $script:scope.planes.$p
      @($def.permissions).Count | Should -BeGreaterThan 0 -Because $p
      @($def.calls).Count | Should -BeGreaterThan 0 -Because $p
      foreach ($call in $def.calls) {
        $call.method | Should -BeIn @('GET', 'SELECT/PROJECT', 'Get-*', 'list') -Because "$p call"
      }
    }
  }

  It 'refuses a scope file where a plane requests a write permission or method' {
    $bad = Join-Path $TestDrive 'bad-scope.json'
    $copy = Get-Content (Join-Path $script:root 'rebuild/scope.json') -Raw | ConvertFrom-Json
    $copy.planes.entra.permissions += 'Directory.ReadWrite.All'
    $copy | ConvertTo-Json -Depth 10 | Set-Content $bad
    { Get-RebuildScope -Path $bad } | Should -Throw '*write permission*'

    $copy = Get-Content (Join-Path $script:root 'rebuild/scope.json') -Raw | ConvertFrom-Json
    $copy.planes.intune.calls[0].method = 'POST'
    $copy | ConvertTo-Json -Depth 10 | Set-Content $bad
    { Get-RebuildScope -Path $bad } | Should -Throw '*non-read method*'
  }
}

Describe 'Runtime token and plane helpers' {
  It 'resolves all and plane subsets in canonical order' {
    Resolve-AvdPlanes -Planes @('all') | Should -Be @('azure', 'entra', 'intune', 'm365', 'power-platform')
    Resolve-AvdPlanes -Planes @('intune', 'azure') | Should -Be @('azure', 'intune')
    { Resolve-AvdPlanes -Planes @('unknown-plane') } | Should -Throw '*Unknown control plane*'
  }

  It 'accepts read-only tokens and rejects .ReadWrite.*, .Write.*, .Manage.* and AccessAsUser' {
    $ro = New-TestJwt @{ scp = 'Group.Read.All Policy.Read.All DeviceManagementConfiguration.Read.All'; roles = @('Directory.Read.All') }
    Test-AvdReadOnlyToken -Token $ro | Should -BeTrue

    foreach ($badScope in @('Directory.ReadWrite.All', 'DeviceManagementConfiguration.ReadWrite.All', 'Policy.Write.All', 'PowerPlatform.Manage.All', 'Directory.AccessAsUser.All')) {
      $rw = New-TestJwt @{ scp = "Group.Read.All $badScope" }
      { Test-AvdReadOnlyToken -Token $rw } | Should -Throw '*write-capable scope*'
    }
  }

  It 'collects Entra, Intune, M365 and Power Platform planes and degrades gracefully on 403 or missing services' {
    $denyInvoker = { param($u) $null = $u; @{ StatusCode = 403; Content = '{"error":{"code":"Authorization_RequestDenied"}}' } }
    (Get-AvdStateEntra -Invoker $denyInvoker).Status | Should -Be 'unconsented'
    (Get-AvdStateIntune -Invoker $denyInvoker).Status | Should -Be 'unconsented'
    (Get-AvdStateM365 -Invoker $denyInvoker).Status | Should -Be 'unconsented'
    (Get-AvdStatePowerPlatform -Invoker $denyInvoker).Status | Should -Be 'unconsented'

    $okInvoker = { param($u) $null = $u; @{ StatusCode = 200; Content = '{"value":[{"id":"1"}]}' } }
    (Get-AvdStateEntra -Invoker $okInvoker).Status | Should -Be 'collected'
    (Get-AvdStateIntune -Invoker $okInvoker).Status | Should -Be 'collected'
    $m365Partial = Get-AvdStateM365 -Invoker $okInvoker
    $m365Partial.Status | Should -Be 'partial'
    $m365Partial.Reason | Should -Be 'teams-ps-unavailable'
    $m365Full = Get-AvdStateM365 -Invoker $okInvoker -TeamsInvoker { @([pscustomobject]@{ Identity = 'Global'; VdiMediaOptimization = 'Enabled' }) }
    $m365Full.Status | Should -Be 'collected'
    (Get-AvdStatePowerPlatform -Invoker $okInvoker).Status | Should -Be 'collected'
  }
}
