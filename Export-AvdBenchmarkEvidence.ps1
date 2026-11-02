#requires -Version 5.1
<#
.SYNOPSIS
    Exports collected read-only AVD Insights / Log Analytics telemetry into a redacted Contract C25
    (avd-benchmark-result/v1) Tier 2 observational benchmark JSON bundle.
.DESCRIPTION
    Pure, offline-testable exporter for Tier 2 observational benchmarks (avd-ops docs/benchmark-platform-spec.md).
    Reads WVDConnections, WVDConnectionNetworkData, Perf, and WVDAgentHealthStatus over a 7-to-30-day lookback
    window (filtered to working hours), computes aggregate percentile distributions (p50, p90, p95, p99),
    bands host and session counts (1-2, 3-9, 10-25, 26-100, 100+), evaluates the experience gate against
    baseline thresholds (RTT < 150ms, session input delay < 150ms), and runs a strict leak scan before
    writing the Contract C25 JSON file.

    Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [Alias('PackagePath', 'Directory')]
    [string]$InputPath = '',

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = '',

    [Parameter(Mandatory = $false)]
    [object[]]$Connections = @(),

    [Parameter(Mandatory = $false)]
    [object[]]$NetworkData = @(),

    [Parameter(Mandatory = $false)]
    [object[]]$Perf = @(),

    [Parameter(Mandatory = $false)]
    [object[]]$AgentHealth = @(),

    [Parameter(Mandatory = $false)]
    [ValidateSet('estate', 'lab', 'sandbox')]
    [string]$Source = 'estate',

    [Parameter(Mandatory = $false)]
    [bool]$Consent = $true,

    [Parameter(Mandatory = $false)]
    [string]$VmSku = '',

    [Parameter(Mandatory = $false)]
    [int]$Vcpu = 0,

    [Parameter(Mandatory = $false)]
    [double]$MemoryGiB = 0,

    [Parameter(Mandatory = $false)]
    [string]$OsDiskType = 'Premium_LRS',

    [Parameter(Mandatory = $false)]
    [string]$JoinType = '',

    [Parameter(Mandatory = $false)]
    [string]$ProfileStorageSku = '',

    [Parameter(Mandatory = $false)]
    [string]$ProfileAuth = '',

    [Parameter(Mandatory = $false)]
    [string]$SmbChannelEncryption = '',

    [Parameter(Mandatory = $false)]
    [string]$NetworkEgress = '',

    [Parameter(Mandatory = $false)]
    [string]$WorkloadClass = '',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$WindowDays = 7,

    [Parameter(Mandatory = $false)]
    [string]$WorkingHoursStart = '07:00',

    [Parameter(Mandatory = $false)]
    [string]$WorkingHoursEnd = '19:00',

    [Parameter(Mandatory = $false)]
    [string[]]$WorkingDays = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri'),

    [Parameter(Mandatory = $false)]
    [string]$IntakePath = '',

    [Parameter(Mandatory = $false)]
    [bool]$FilterWorkingHours = $true,

    [Parameter(Mandatory = $false)]
    [nullable[datetime]]$ReferenceTime = $null,

    [Parameter(Mandatory = $false)]
    [string]$Date = '',

    [Parameter(Mandatory = $false)]
    [string]$AssessCommit = '',

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/AvdBenchmark.psm1') -Force

$extraNames = New-Object 'System.Collections.Generic.List[string]'

if ($IntakePath -ne '') {
    if (-not (Test-Path -LiteralPath $IntakePath -PathType Leaf)) {
        throw "Intake file not found: $IntakePath"
    }
    $intakeObj = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $IntakePath).ProviderPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $wh = $intakeObj.PSObject.Properties['workingHours']
    if ($wh -and $null -ne $wh.Value) {
        if ($wh.Value.PSObject.Properties['start'] -and "$($wh.Value.start)" -ne '') { $WorkingHoursStart = "$($wh.Value.start)" }
        if ($wh.Value.PSObject.Properties['end'] -and "$($wh.Value.end)" -ne '')     { $WorkingHoursEnd = "$($wh.Value.end)" }
        if ($wh.Value.PSObject.Properties['days'] -and @($wh.Value.days).Count -gt 0) { $WorkingDays = @($wh.Value.days | ForEach-Object { "$_" }) }
    }
}

$connRows = @($Connections)
$netRows  = @($NetworkData)
$perfRows = @($Perf)
$ahRows   = @($AgentHealth)

if ($InputPath -ne '') {
    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "InputPath not found: $InputPath"
    }
    $resolvedInput = (Resolve-Path -LiteralPath $InputPath).ProviderPath
    if ($connRows.Count -eq 0) { $connRows = @(Read-AvdTelemetryTable -Directory $resolvedInput -TableName 'WVDConnections') }
    if ($netRows.Count -eq 0)  { $netRows  = @(Read-AvdTelemetryTable -Directory $resolvedInput -TableName 'WVDConnectionNetworkData') }
    if ($perfRows.Count -eq 0) { $perfRows = @(Read-AvdTelemetryTable -Directory $resolvedInput -TableName 'Perf') }
    if ($ahRows.Count -eq 0)   { $ahRows   = @(Read-AvdTelemetryTable -Directory $resolvedInput -TableName 'WVDAgentHealthStatus') }

    # Also check child subscription folders if InputPath is a top-level collector package
    if ($connRows.Count -eq 0 -and $netRows.Count -eq 0 -and $perfRows.Count -eq 0) {
        foreach ($child in @(Get-ChildItem -LiteralPath $resolvedInput -Directory -ErrorAction SilentlyContinue)) {
            $connRows += @(Read-AvdTelemetryTable -Directory $child.FullName -TableName 'WVDConnections')
            $netRows  += @(Read-AvdTelemetryTable -Directory $child.FullName -TableName 'WVDConnectionNetworkData')
            $perfRows += @(Read-AvdTelemetryTable -Directory $child.FullName -TableName 'Perf')
            $ahRows   += @(Read-AvdTelemetryTable -Directory $child.FullName -TableName 'WVDAgentHealthStatus')
        }
    }

    # Discover VM SKU, join type, storage SKU, and known names from collector package metadata if present
    $manifestPath = Join-Path $resolvedInput 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json
        foreach ($mProp in @('TenantId', 'Identity', 'SubscriptionName', 'SubscriptionId')) {
            $p = $manifest.PSObject.Properties[$mProp]
            if ($p -and "$($p.Value)".Length -ge 3) { $extraNames.Add("$($p.Value)") }
        }
        $subDetails = $manifest.PSObject.Properties['SubscriptionDetails']
        if ($subDetails -and $null -ne $subDetails.Value) {
            foreach ($sd in @($subDetails.Value)) {
                foreach ($sp in @('SubscriptionName', 'SubscriptionId')) {
                    $svp = $sd.PSObject.Properties[$sp]
                    if ($svp -and "$($svp.Value)".Length -ge 3) { $extraNames.Add("$($svp.Value)") }
                }
            }
        }
    }

    $vmJson = Join-Path $resolvedInput 'virtual-machines.json'
    if (Test-Path -LiteralPath $vmJson) {
        $vms = @([System.IO.File]::ReadAllText($vmJson, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json)
        foreach ($vm in $vms) {
            $vn = $vm.PSObject.Properties['Name']
            if ($vn -and "$($vn.Value)".Length -ge 3) { $extraNames.Add("$($vn.Value)") }
            if ($VmSku -eq '') {
                $vs = $vm.PSObject.Properties['VMSize']
                if ($vs -and "$($vs.Value)" -match '^Standard_[A-Za-z0-9_]{1,40}$') { $VmSku = "$($vs.Value)" }
            }
        }
    }
    $extJson = Join-Path $resolvedInput 'vm-extensions.json'
    if ($JoinType -eq '' -and (Test-Path -LiteralPath $extJson)) {
        $exts = @([System.IO.File]::ReadAllText($extJson, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) | ConvertFrom-Json)
        foreach ($ext in $exts) {
            $et = $ext.PSObject.Properties['ExtensionType']
            if ($et -and "$($et.Value)" -eq 'AADLoginForWindows') { $JoinType = 'entra-joined'; break }
            if ($et -and "$($et.Value)" -eq 'JsonADDomainExtension') { $JoinType = 'ad-domain-joined'; break }
        }
    }
}

if ($VmSku -eq '')    { $VmSku = 'Standard_D8s_v5' }
if ($JoinType -eq '') { $JoinType = 'entra-joined' }

$c25 = ConvertFrom-AvdInsightsTelemetry `
    -Connections $connRows `
    -NetworkData $netRows `
    -Perf $perfRows `
    -AgentHealth $ahRows `
    -Source $Source `
    -Consent $Consent `
    -VmSku $VmSku `
    -Vcpu $Vcpu `
    -MemoryGiB $MemoryGiB `
    -OsDiskType $OsDiskType `
    -JoinType $JoinType `
    -ProfileStorageSku $ProfileStorageSku `
    -ProfileAuth $ProfileAuth `
    -SmbChannelEncryption $SmbChannelEncryption `
    -NetworkEgress $NetworkEgress `
    -WorkloadClass $WorkloadClass `
    -WindowDays $WindowDays `
    -WorkingHoursStart $WorkingHoursStart `
    -WorkingHoursEnd $WorkingHoursEnd `
    -WorkingDays $WorkingDays `
    -FilterWorkingHours $FilterWorkingHours `
    -ReferenceTime $ReferenceTime `
    -Date $Date `
    -AssessCommit $AssessCommit `
    -ExtraKnownNames $extraNames.ToArray()

$json = $c25 | ConvertTo-Json -Depth 12

# Validate against contracts/benchmark-result.schema.json when Test-Json is available (PowerShell 7+)
$schemaFile = Join-Path $PSScriptRoot 'contracts/benchmark-result.schema.json'
if ((Test-Path -LiteralPath $schemaFile) -and (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
    $schemaErrs = $null
    if (-not (Test-Json -Json $json -SchemaFile $schemaFile -ErrorVariable schemaErrs -ErrorAction SilentlyContinue)) {
        throw "Exported benchmark JSON failed Contract C25 schema validation: $schemaErrs"
    }
}

if ($OutputPath -ne '') {
    $outFull = [System.IO.Path]::GetFullPath($OutputPath)
    $destFile = if ($outFull -match '\.json$' -and -not (Test-Path -LiteralPath $outFull -PathType Container)) {
        $parentDir = Split-Path -Parent $outFull
        if (-not (Test-Path -LiteralPath $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
        $outFull
    } else {
        if (-not (Test-Path -LiteralPath $outFull)) { New-Item -ItemType Directory -Path $outFull -Force | Out-Null }
        Join-Path $outFull "$($c25.id).json"
    }
    [System.IO.File]::WriteAllText($destFile, ($json -replace "`r`n", "`n") + "`n", (New-Object System.Text.UTF8Encoding $false))
    if (-not $PassThru) {
        Write-Output $destFile
    }
}

if ($PassThru -or $OutputPath -eq '') {
    Write-Output $c25
}
