#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for the validator's policy effect resolution: a deny inside an initiative, or behind an
# "[parameters('effect')]" reference, must be found. The helpers are loaded from the validator's own
# source, so the script stays a single file that runs on its own.

BeforeAll {
  Set-StrictMode -Version Latest  # as the validator runs
  $script:root = Split-Path $PSScriptRoot -Parent
  $validator = Join-Path $script:root 'avd_deployment_validator.ps1'
  $script:parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($validator, [ref]$null, [ref]$script:parseErrors)
  $wanted = 'Get-Prop', 'Get-FirstProp', 'Get-PolicyParameterValue', 'Resolve-PolicyParameterReference',
    'Get-PolicyMemberParameterValue', 'Get-PolicyDefinitionEffect'
  $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $false) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
  . ([scriptblock]::Create(($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ResourceNameFromId' }, $false) | Select-Object -First 1).Extent.Text))

  # The policy section's own body, run against fake Az reads with Add-Check collecting the rows.
  $call = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
      $n.GetCommandName() -eq 'Invoke-Check' -and $n.Extent.Text -match "-Check 'Deny policy exposure'" }, $true) | Select-Object -First 1
  $bodyText = ($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }).ScriptBlock.Extent.Text
  $script:policyBody = [scriptblock]::Create($bodyText.Substring(1, $bodyText.Length - 2))

  function ConvertTo-Object { param([string] $Json) $Json | ConvertFrom-Json }

  # A built-in style definition whose effect is a parameter with a default.
  $script:parameterized = ConvertTo-Object '{
    "DisplayName": "Storage accounts should disable public network access",
    "PolicyRule": { "if": { "field": "type", "equals": "Microsoft.Storage/storageAccounts" }, "then": { "effect": "[parameters(''effect'')]" } },
    "Parameter": { "effect": { "type": "String", "defaultValue": "Audit" } } }'
  # The current Az.Resources shape: initiative parameters and members are flattened.
  $script:set = ConvertTo-Object '{
    "Parameter": { "storageEffect": { "type": "String", "defaultValue": "Audit" }, "regions": { "type": "Array", "defaultValue": [ "eastus2" ] } },
    "PolicyDefinition": [
      { "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/aaaa", "parameters": { "effect": { "value": "[parameters(''storageEffect'')]" } } },
      { "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c", "parameters": { "listOfAllowedLocations": { "value": "[parameters(''regions'')]" } } } ] }'
  $script:member = $script:set.PolicyDefinition[0]
  $script:locationsMember = $script:set.PolicyDefinition[1]
}

Describe 'The validator source' {
  It 'parses without errors' {
    @($script:parseErrors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) | Should -BeNullOrEmpty
  }
}

Describe 'Get-PolicyDefinitionEffect' {
  It 'reads a literal effect' {
    $definition = ConvertTo-Object '{ "PolicyRule": { "then": { "effect": "Deny" } } }'
    Get-PolicyDefinitionEffect -Definition $definition -Assignment ([pscustomobject]@{}) | Should -Be 'Deny'
  }

  It 'reads the older Properties.PolicyRule shape and a rule held as JSON text' {
    $definition = [pscustomobject]@{ Properties = [pscustomobject]@{ PolicyRule = '{ "then": { "effect": "deny" } }' } }
    Get-PolicyDefinitionEffect -Definition $definition -Assignment ([pscustomobject]@{}) | Should -Be 'deny'
  }

  It 'takes a direct assignment''s value for a parameterized effect' {
    $assignment = ConvertTo-Object '{ "Parameter": { "effect": { "value": "Deny" } } }'
    Get-PolicyDefinitionEffect -Definition $script:parameterized -Assignment $assignment | Should -Be 'Deny'
  }

  It 'falls back to the definition default when the assignment sets nothing' {
    Get-PolicyDefinitionEffect -Definition $script:parameterized -Assignment ([pscustomobject]@{}) | Should -Be 'Audit'
  }

  It 'follows an initiative member to the assignment''s initiative parameter' {
    $assignment = ConvertTo-Object '{ "Parameter": { "storageEffect": { "value": "Deny" } } }'
    Get-PolicyDefinitionEffect -Definition $script:parameterized -Assignment $assignment -Member $script:member -SetDefinition $script:set |
      Should -Be 'Deny'
  }

  It 'uses the initiative default when the assignment leaves the initiative parameter unset' {
    Get-PolicyDefinitionEffect -Definition $script:parameterized -Assignment ([pscustomobject]@{}) -Member $script:member -SetDefinition $script:set |
      Should -Be 'Audit'
  }

  It 'reads the older ParametersRaw JSON form on the assignment' {
    $assignment = [pscustomobject]@{ Properties = [pscustomobject]@{ ParametersRaw = '{ "storageEffect": { "value": "Deny" } }' } }
    Get-PolicyDefinitionEffect -Definition $script:parameterized -Assignment $assignment -Member $script:member -SetDefinition $script:set |
      Should -Be 'Deny'
  }

  It 'returns empty for an effect set by any other template expression' {
    $definition = ConvertTo-Object '{ "PolicyRule": { "then": { "effect": "[if(equals(1,1),''Deny'',''Audit'')]" } } }'
    Get-PolicyDefinitionEffect -Definition $definition -Assignment ([pscustomobject]@{}) | Should -Be ''
  }

  It 'returns empty when a parameterized effect has no value anywhere' {
    $definition = ConvertTo-Object '{ "PolicyRule": { "then": { "effect": "[parameters(''effect'')]" } } }'
    Get-PolicyDefinitionEffect -Definition $definition -Assignment ([pscustomobject]@{}) | Should -Be ''
  }
}

Describe 'Get-PolicyMemberParameterValue' {
  It 'resolves an allowed-locations list inside an initiative through the assignment' {
    $assignment = ConvertTo-Object '{ "Parameter": { "regions": { "value": [ "westeurope", "northeurope" ] } } }'
    $value = Get-PolicyMemberParameterValue -Definition $null -ParameterName 'listOfAllowedLocations' `
      -Assignment $assignment -Member $script:locationsMember -SetDefinition $script:set
    @($value) | Should -Be @('westeurope', 'northeurope')
  }

  It 'resolves the list from the initiative default' {
    $value = Get-PolicyMemberParameterValue -Definition $null -ParameterName 'listOfAllowedLocations' `
      -Assignment ([pscustomobject]@{}) -Member $script:locationsMember -SetDefinition $script:set
    @($value) | Should -Be @('eastus2')
  }

  It 'returns a literal member value as is' {
    $member = ConvertTo-Object '{ "parameters": { "listOfAllowedLocations": { "value": [ "centralus" ] } } }'
    $value = Get-PolicyMemberParameterValue -Definition $null -ParameterName 'listOfAllowedLocations' `
      -Assignment ([pscustomobject]@{}) -Member $member -SetDefinition $script:set
    @($value) | Should -Be @('centralus')
  }

  It 'returns null when nothing sets the parameter' {
    Get-PolicyMemberParameterValue -Definition $null -ParameterName 'listOfAllowedLocations' -Assignment ([pscustomobject]@{}) |
      Should -BeNullOrEmpty
  }
}

Describe 'Policy section' {
  BeforeAll {
    function Add-Check { param($Category, $Check, $Status, $Detail, $Recommendation, $Scope) $script:rows.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail }) }
    function Get-AzPolicyDefinition { param($Id, $ErrorAction) $script:definitions[$Id] }
    function Get-AzPolicySetDefinition { param($Id, $ErrorAction) if ($script:sets.ContainsKey($Id)) { $script:sets[$Id] } else { throw 'not found' } }
    function Invoke-PolicySection { $script:rows = [System.Collections.Generic.List[object]]::new(); & $script:policyBody; $script:rows }

    $Location = 'northcentralus'
    $SessionHostVmSize = 'Standard_D2ads_v5'
    $setId = '/providers/Microsoft.Authorization/policySetDefinitions/security-baseline'
    $script:sets = @{ $setId = $script:set }
    $script:definitions = @{
      '/providers/Microsoft.Authorization/policyDefinitions/aaaa' = $script:parameterized
      '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c' = (ConvertTo-Object '{ "DisplayName": "Allowed locations", "PolicyRule": { "then": { "effect": "deny" } } }')
    }
  }

  It 'finds a deny and a region block that only exist inside an initiative' {
    function Get-AzPolicyAssignment { param($ErrorAction)
      ConvertTo-Object ('{ "DisplayName": "Security baseline", "PolicyDefinitionId": "' + $setId + '", "Parameter": { "storageEffect": { "value": "Deny" } } }') }
    $rows = Invoke-PolicySection
    ($rows | Where-Object Check -eq 'Allowed locations policy').Status | Should -Be 'FAIL'
    $deny = $rows | Where-Object Check -eq 'Deny policy exposure'
    $deny.Status | Should -Be 'WARN'
    $deny.Detail | Should -Match 'Security baseline > Storage accounts should disable public network access'
    $deny.Detail | Should -Match '1 expanded initiative'
  }

  It 'reports DoNotEnforce denies apart and does not fail the region' {
    function Get-AzPolicyAssignment { param($ErrorAction)
      ConvertTo-Object ('{ "DisplayName": "Security baseline", "PolicyDefinitionId": "' + $setId + '", "EnforcementMode": "DoNotEnforce", "Parameter": { "storageEffect": { "value": "Deny" } } }') }
    $rows = Invoke-PolicySection
    ($rows | Where-Object Check -eq 'Allowed locations policy').Status | Should -Be 'INFO'
    ($rows | Where-Object Check -eq 'Deny policy exposure').Status | Should -Be 'PASS'
    ($rows | Where-Object Check -eq 'Deny policies not enforced').Status | Should -Be 'INFO'
  }

  It 'warns, never passes silently, when an initiative cannot be read' {
    function Get-AzPolicyAssignment { param($ErrorAction)
      ConvertTo-Object '{ "DisplayName": "Hidden set", "PolicyDefinitionId": "/providers/Microsoft.Authorization/policySetDefinitions/missing" }' }
    $rows = Invoke-PolicySection
    ($rows | Where-Object Check -eq 'Policy initiatives').Status | Should -Be 'WARN'
  }

  It 'reports what the lookup cap left out' {
    $many = 1..205 | ForEach-Object { "/providers/Microsoft.Authorization/policyDefinitions/d$_" }
    foreach ($id in $many) { $script:definitions[$id] = ConvertTo-Object '{ "PolicyRule": { "then": { "effect": "audit" } } }' }
    function Get-AzPolicyAssignment { param($ErrorAction) $many | ForEach-Object { [pscustomobject]@{ DisplayName = $_; PolicyDefinitionId = $_ } } }
    $rows = Invoke-PolicySection
    $cap = $rows | Where-Object Check -eq 'Policy lookup cap'
    $cap.Status | Should -Be 'INFO'
    $cap.Detail | Should -Match '5 assignment\(s\)'
  }
}
