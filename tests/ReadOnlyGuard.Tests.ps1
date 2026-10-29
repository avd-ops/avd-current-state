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
      'avd_current_state.ps1',
      'avd_current_state_collector.ps1',
      'avd_current_state_facts.ps1',
      'avd_current_state_drift.ps1',
      'avd_deployment_validator.ps1'
    )
    $script:files = @(
      $script:readOnlyScripts | ForEach-Object { Get-Item (Join-Path $script:root $_) }
      Get-ChildItem -Path (Join-Path $script:root 'lib') -Filter '*.psm1' -File
    )
    # The only POSTs a read-only script may make, each read-shaped, with the reason it is a read.
    $script:postAllowlist = @(
      @{ Pattern = 'Microsoft\.ResourceGraph/resources'; Reason = 'Resource Graph queries are POSTs that only read' }
    )

    # Returns one line per write call: a write cmdlet, a PUT, PATCH or DELETE, a POST whose path is
    # outside the allowlist, or a REST call whose method the test can't read (an expression or splatting).
    function Get-WriteCall {
      param([string]$Path)
      $forbidden = '^((Set-(?!AzContext$)|New-|Remove-|Update-|Clear-|Reset-|Stop-|Start-|Restart-|Grant-|Revoke-)(Az|Mg|Cs|AdminPowerApp|PowerApp))'
      $tokens = $null
      $errors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
      $name = Split-Path $Path -Leaf
      foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $command = $cmd.GetCommandName()
        if (-not $command) { continue }
        $at = "$name line $($cmd.Extent.StartLineNumber)"
        if ($command -match $forbidden) { "${at}: write cmdlet $command"; continue }
        if ($command -notin @('Invoke-AzRestMethod', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-MgGraphRequest')) { continue }
        # Read the parameters from this command's own elements, never from nested commands or strings.
        $elements = @($cmd.CommandElements)
        $arguments = @{}
        $splatted = $false
        for ($i = 1; $i -lt $elements.Count; $i++) {
          $e = $elements[$i]
          if ($e -is [System.Management.Automation.Language.VariableExpressionAst] -and $e.Splatted) { $splatted = $true }
          if ($e -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
          $value = if ($e.Argument) { $e.Argument } elseif ($i + 1 -lt $elements.Count -and $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) { $elements[$i + 1] }
          $arguments[$e.ParameterName.ToLowerInvariant()] = $value
        }
        if ($splatted) { "${at}: $command with splatted parameters the test can't read"; continue }
        $method = $arguments['method']
        if (-not $method) { continue }
        if ($method -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { "${at}: $command with a method the test can't read ($($method.Extent.Text))"; continue }
        $verb = $method.Value.ToUpperInvariant()
        if ($verb -in @('PUT', 'PATCH', 'DELETE', 'MERGE')) { "${at}: $command -Method $verb"; continue }
        if ($verb -eq 'POST') {
          $target = foreach ($key in 'path', 'uri') { if ($arguments[$key]) { $arguments[$key].Extent.Text.Split('?')[0] } }
          if (-not @($script:postAllowlist | Where-Object { "$target" -match $_.Pattern })) { "${at}: $command -Method POST outside the allowlist" }
        }
      }
    }
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

  It 'gives every allowed POST a reason' {
    foreach ($entry in $script:postAllowlist) { $entry.Reason | Should -Not -BeNullOrEmpty -Because $entry.Pattern }
  }

  It 'finds no write cmdlet, no PUT, PATCH or DELETE, and no POST outside the allowlist' {
    $found = @(foreach ($file in $script:files) { Get-WriteCall -Path $file.FullName })
    $found | Should -BeNullOrEmpty
  }

  It 'catches each kind of write call when a script gains one' {
    $planted = Join-Path $TestDrive 'planted.ps1'
    @(
      'Remove-AzResourceGroup -Name x',
      'New-MgUser -DisplayName x',
      'Invoke-AzRestMethod -Method PUT -Path /x',
      'Invoke-RestMethod -Uri https://example.invalid -Method:Delete',
      'Invoke-AzRestMethod -Method POST -Path /providers/Microsoft.Authorization/roleAssignments',
      'Invoke-AzRestMethod -Method $verb -Path /x',
      'Invoke-AzRestMethod -Method POST -Path /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01',
      'Invoke-AzRestMethod -Method GET -Path /x',
      'Set-AzContext -Subscription x',
      'Invoke-AzRestMethod -method put -Path /x',
      'Invoke-RestMethod -Uri (Get-Thing -Method Get) -Method Delete',
      'Invoke-AzRestMethod -Method ([Microsoft.PowerShell.Commands.WebRequestMethod]::Delete) -Path /x',
      'Invoke-AzRestMethod @splat',
      'Invoke-AzRestMethod -Method POST -Path /providers/Microsoft.Authorization/x?note=Microsoft.ResourceGraph/resources',
      'Invoke-AzRestMethod -Method POST -Path /x -Payload Microsoft.ResourceGraph/resources'
    ) | Set-Content $planted
    $found = @(Get-WriteCall -Path $planted)
    $found.Count | Should -Be 12
    ($found -join "`n") | Should -Match 'line 1: write cmdlet Remove-AzResourceGroup'
    ($found -join "`n") | Should -Match 'line 6: .*method the test can.t read'
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
