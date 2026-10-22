# A fake Az.Storage for avd_portal_publish.ps1's offline runs: the static website's $web container, kept in the
# same state file as the fake ARM (FAKEPUBLISH_STATE). It refuses an account the fake ARM doesn't hold and a
# sign-in without the upload role, as Azure does.

function Get-State { Get-Content -Raw $env:FAKEPUBLISH_STATE | ConvertFrom-Json -AsHashtable }
function Save-State { param($S) $S | ConvertTo-Json -Depth 20 | Set-Content -Path $env:FAKEPUBLISH_STATE }

function New-AzStorageContext {
    param([string] $StorageAccountName, [switch] $UseConnectedAccount)
    if (-not $UseConnectedAccount) { throw 'fake: the upload must use the signed-in account, not keys' }
    $s = Get-State
    $id = @($s.accounts.Keys | Where-Object { $_ -like "*/storageAccounts/$StorageAccountName" })
    if (-not $id.Count) { throw "fake: no storage account $StorageAccountName" }
    if (-not @($s.roles.Keys | Where-Object { $_ -like "$($id[0])|*" }).Count) { throw 'fake: 403 AuthorizationPermissionMismatch' }
    [pscustomobject]@{ StorageAccountName = $StorageAccountName }
}
function Enable-AzStorageStaticWebsite {
    param($Context, [string] $IndexDocument, [string] $ErrorDocument404Path)
    $s = Get-State; $s.website = $true; Save-State $s
}
function Set-AzStorageBlobContent {
    param($Context, [string] $Container, [string] $File, [string] $Blob, [switch] $Force, [hashtable] $Properties)
    if ($Container -ne '$web') { throw "fake: container $Container" }
    $s = Get-State
    $s.blobs[$Blob] = @{ type = $Properties.ContentType; length = (Get-Item $File).Length }
    if ($Blob -eq 'portal/portal-config.js') { $s.config = Get-Content -Raw $File }
    Save-State $s
}
function Get-AzStorageBlob {
    param($Context, [string] $Container)
    $s = Get-State
    foreach ($k in $s.blobs.Keys) { [pscustomobject]@{ Name = $k } }
}
function Remove-AzStorageBlob {
    param($Context, [string] $Container, [string] $Blob, [switch] $Force)
    $s = Get-State; $s.blobs.Remove($Blob); Save-State $s
}
