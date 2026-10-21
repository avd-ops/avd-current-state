# A fake Az.Resources for the collector's offline run: an empty but readable subscription.
function Get-AzResourceGroup { param($Name, $ErrorAction) }
function Get-AzRoleAssignment { param($Scope, $ErrorAction) }
function Get-AzPolicyAssignment { param($Scope, $ErrorAction) }
Export-ModuleMember -Function *
