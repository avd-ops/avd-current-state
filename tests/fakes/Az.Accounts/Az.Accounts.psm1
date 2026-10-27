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
  param([string]$Method = 'GET', [string]$Path, [string]$Uri, [string]$Payload)
  $target = if ($Uri) { $Uri } else { $Path }
  # Optional routes for the drift check's offline runs (tests/Drift.Tests.ps1): the first route whose
  # 'match' regex finds the request (a POST's payload, else the path) answers it.
  if ($env:FAKEAZ_ROUTES -and (Test-Path -LiteralPath $env:FAKEAZ_ROUTES)) {
    foreach ($r in @(Get-Content -LiteralPath $env:FAKEAZ_ROUTES -Raw | ConvertFrom-Json)) {
      $haystack = if ($Method -eq 'POST') { $Payload } else { $target }
      if ($haystack -match $r.match) {
        $body = if ($r.content -is [string]) { $r.content } else { $r.content | ConvertTo-Json -Depth 30 -Compress }
        return [pscustomobject]@{ StatusCode = [int]$r.status; Content = $body; Headers = @{} }
      }
    }
  }
  $content = if ($target -like '*Microsoft.ResourceGraph*') { '{"totalRecords":0,"count":0,"data":[]}' } else { '{"value":[]}' }
  [pscustomobject]@{ StatusCode = 200; Content = $content; Headers = @{} }
}
Export-ModuleMember -Function *
