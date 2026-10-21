<#
.SYNOPSIS
    The sandbox round trip's check (docs/rebuild-fidelity-spec.md, section 11): compares the rebuild map a
    collector run wrote with the values avd-landing-zone's parameters/dev.bicepparam deployed.

.DESCRIPTION
    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    Prints one line per parameter: name, status and match or NO MATCH. It never prints a value, so the
    output can be pasted into a chat or an issue. Exits 0 when every parameter resolves (found, derived,
    secret or deployTime) and every checked value matches, 1 otherwise. Reads the two group IDs with
    the Azure CLI (az ad group show); everything else is local.

.EXAMPLE
    ./tests/sandbox/Test-RebuildRoundTrip.ps1 -PackagePath ~/rebuild-run -SessionHostVmSize Standard_D2as_v5
#>
param(
    [Parameter(Mandatory)] [string]$PackagePath,
    [string]$HostPoolName = 'vdpool-avdlz-dev',
    # The sizing flags given to deploy.sh, when they differ from dev.bicepparam.
    [string]$SessionHostVmSize = 'Standard_E4as_v5',
    [int]$SessionHostCount = 1,
    [string]$UsersGroup = 'AVD Users',
    [string]$AdminsGroup = 'AVD Admins'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../lib/AvdRebuildMap.psm1') -Force

$file = Get-ChildItem -Path $PackagePath -Recurse -Filter 'rebuild-map.json' | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $file) { Write-Host 'No rebuild-map.json under the package path: check the WARN and ERROR lines in the collector log.'; exit 1 }
$map = @(Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json) | Where-Object { "$($_.hostPool)" -like "*/$HostPoolName" } | Select-Object -First 1
if (-not $map) { Write-Host "No map for host pool $HostPoolName in $($file.Name)."; exit 1 }

Write-Host 'Looking up the two group IDs ...'
$usersId = az ad group show --group $UsersGroup --query id -o tsv
$adminsId = az ad group show --group $AdminsGroup --query id -o tsv

# parameters/dev.bicepparam at the landing zone commit in rebuild/lz-parameters.json, and the defaults it leaves.
$expected = [ordered]@{
    namePrefix = 'avdlz'; environmentName = 'dev'; location = 'northcentralus'; avdUsersGroupObjectId = $usersId; avdAdminsGroupObjectId = $adminsId
    enrollInIntune = $true; connectivityMode = 'Standalone'; spokeAddressPrefix = '10.100.0.0/22'; sessionHostSubnetPrefix = '10.100.0.0/23'
    privateEndpointSubnetPrefix = '10.100.2.0/27'; deployImageBuildSubnets = $false; enableAvdPrivateLink = $true; sessionHostCount = $SessionHostCount
    sessionHostVmSize = $SessionHostVmSize; sessionHostNamePrefix = 'avdlzdsh'; encryptionAtHost = $true; localAdminUsername = 'avdbreakglass'
    maxSessionLimit = 8; validationEnvironment = $true; profileStorageSku = 'Premium_LRS'; profileShareQuotaGiB = 100; fslogixProfileSizeMiB = 30720
    enableProfileBackup = $false; startVmOnConnect = $true; scalingTimeZone = 'UTC'; logRetentionDays = 30; monthlyBudgetAmount = 0
    enableAutoShutdown = $true; autoShutdownTime = '20:00'; autoShutdownTimeZone = 'Central Standard Time'; autoShutdownScheduleAction = 'Stop'
    enableDefenderForCloud = $false; deploySubscriptionSettings = $true; enablePolicyGuardrails = $true
}

$result = Get-LzRoundTripResult -Map $map -Expected $expected
foreach ($r in $result.Rows) { Write-Host ('{0,-30} {1,-14} {2}' -f $r.Parameter, $r.Status, $r.Check) }
$counts = @($result.Rows | Group-Object Status | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
Write-Host "Coverage: $counts"
if ($result.Passed) { Write-Host 'RESULT round-trip PASS'; exit 0 }
Write-Host 'RESULT round-trip FAIL'
exit 1
