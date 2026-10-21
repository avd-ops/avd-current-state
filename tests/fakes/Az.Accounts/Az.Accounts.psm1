# A fake Az.Accounts for the collector's offline run (tests/CollectorRun.Tests.ps1). It returns the
# shapes the real module does, including a typed subscription object: under Set-StrictMode a single
# typed object has no .Count, which is how the first real Cloud Shell run failed.
if (-not ('FakeAz.Subscription' -as [type])) {
  Add-Type -TypeDefinition @'
namespace FakeAz {
  public class Subscription { public string Id; public string Name; public string State; public string TenantId; }
}
'@
}

function Get-AzContext {
  [pscustomobject]@{
    Account      = [pscustomobject]@{ Id = 'fake-operator' }
    Tenant       = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' }
    Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001'; Name = 'sub-contoso-avd' }
  }
}
function Connect-AzAccount { Get-AzContext }
function Get-AzSubscription {
  $n = [int]$env:FAKEAZ_SUBSCRIPTIONS
  if (-not $n) { $n = 1 }
  foreach ($i in 1..$n) {
    $s = [FakeAz.Subscription]::new()
    $s.Id = '00000000-0000-0000-0000-00000000000{0}' -f $i
    $s.Name = "sub-contoso-avd-$i"
    $s.State = 'Enabled'
    $s.TenantId = '00000000-0000-0000-0000-000000000000'
    $s
  }
}
function Set-AzContext { param($SubscriptionId, $Subscription, $Tenant) Get-AzContext }
function Invoke-AzRestMethod {
  param([string]$Method = 'GET', [string]$Path, [string]$Payload)
  $content = if ($Path -like '*Microsoft.ResourceGraph*') { '{"totalRecords":0,"count":0,"data":[]}' } else { '{"value":[]}' }
  [pscustomobject]@{ StatusCode = 200; Content = $content; Headers = @{} }
}
Export-ModuleMember -Function *
