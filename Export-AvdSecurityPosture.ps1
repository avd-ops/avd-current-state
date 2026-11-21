# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware, ServiceNow or Microsoft.
#requires -Version 5.1
<#
.SYNOPSIS
Exports C34 (avd-security-posture/v1) from an avd-current-state C11 facts bundle.

.DESCRIPTION
Reads an avd-current-state-facts/v1 JSON file (-FactsPath) or hashtable/object (-Facts)
and emits a redacted C34 avd-security-posture/v1 report mapped to avd-assess claims.
Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'Path', Mandatory)]
    [string]$FactsPath,

    [Parameter(ParameterSetName = 'Object', Mandatory)]
    [object]$Facts,

    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FactProp {
    param([object]$Obj, [string]$Name, [object]$Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        return $Default
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
}

function Format-PostureItem {
    param(
        [string]$Id,
        [string]$AssessCheckId,
        [string]$Pillar,
        [string]$Status,
        [string]$ClaimRef,
        [string]$Message,
        [string]$RemediationHint = ''
    )
    $item = [ordered]@{
        id       = $Id
        pillar   = $Pillar
        status   = $Status
        claimRef = $ClaimRef
        message  = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($AssessCheckId)) {
        $item.assessCheckId = $AssessCheckId
    }
    if (-not [string]::IsNullOrWhiteSpace($RemediationHint)) {
        $item.remediationHint = $RemediationHint
    }
    return $item
}

$doc = if ($PSCmdlet.ParameterSetName -eq 'Path') {
    if (-not (Test-Path $FactsPath)) {
        throw "FactsPath not found: $FactsPath"
    }
    Get-Content -Path $FactsPath -Raw | ConvertFrom-Json
}
else {
    $Facts
}

$schema = Get-FactProp -Obj $doc -Name 'schema'
if ($schema -ne 'avd-current-state-facts/v1') {
    throw "Expected C11 schema 'avd-current-state-facts/v1', got '$schema'"
}

$subs = @(Get-FactProp -Obj $doc -Name 'subscriptions' -Default @())
$hostPools = @()
foreach ($s in $subs) {
    $hps = @(Get-FactProp -Obj $s -Name 'hostPools' -Default @())
    $hostPools += $hps
}

$checks = @()

# 1. Trusted Launch
$totalHosts = 0
$trustedHosts = 0
$hasTrusted = $false
foreach ($hp in $hostPools) {
    $sh = Get-FactProp -Obj $hp -Name 'sessionHosts'
    $t = Get-FactProp -Obj $sh -Name 'total'
    $tl = Get-FactProp -Obj $sh -Name 'trustedLaunch'
    if ($null -ne $t -and $null -ne $tl) {
        $hasTrusted = $true
        $totalHosts += [int]$t
        $trustedHosts += [int]$tl
    }
}
if (-not $hasTrusted -or $totalHosts -eq 0) {
    $checks += (Format-PostureItem -Id 'sec-host-trusted-launch' -AssessCheckId 'asm-hosts-trusted-launch' -Pillar 'security-posture' -Status 'unknown' -ClaimRef 'ref:avd-security-guide#trusted-launch' -Message 'No session host Trusted Launch counts present in C11 facts.')
}
elseif ($trustedHosts -ge $totalHosts) {
    $checks += (Format-PostureItem -Id 'sec-host-trusted-launch' -AssessCheckId 'asm-hosts-trusted-launch' -Pillar 'security-posture' -Status 'pass' -ClaimRef 'ref:avd-security-guide#trusted-launch' -Message 'All collected session hosts have Trusted Launch enabled.')
}
else {
    $checks += (Format-PostureItem -Id 'sec-host-trusted-launch' -AssessCheckId 'asm-hosts-trusted-launch' -Pillar 'security-posture' -Status 'fail' -ClaimRef 'ref:avd-security-guide#trusted-launch' -Message 'One or more collected session hosts lack Trusted Launch.' -RemediationHint 'Enable Trusted Launch (Secure Boot + vTPM) on AVD session host VMs.')
}

# 2. Encryption at host
$encHosts = 0
$hasEnc = $false
foreach ($hp in $hostPools) {
    $sh = Get-FactProp -Obj $hp -Name 'sessionHosts'
    $t = Get-FactProp -Obj $sh -Name 'total'
    $eh = Get-FactProp -Obj $sh -Name 'encryptionAtHost'
    if ($null -ne $t -and $null -ne $eh) {
        $hasEnc = $true
        $encHosts += [int]$eh
    }
}
if (-not $hasEnc -or $totalHosts -eq 0) {
    $checks += (Format-PostureItem -Id 'sec-host-encryption-at-host' -AssessCheckId '' -Pillar 'security-posture' -Status 'unknown' -ClaimRef 'ref:mcsb-avd-baseline#DP-5' -Message 'No encryptionAtHost counts present in C11 facts.')
}
elseif ($encHosts -ge $totalHosts) {
    $checks += (Format-PostureItem -Id 'sec-host-encryption-at-host' -AssessCheckId '' -Pillar 'security-posture' -Status 'pass' -ClaimRef 'ref:mcsb-avd-baseline#DP-5' -Message 'All collected session hosts have encryptionAtHost enabled.')
}
else {
    $checks += (Format-PostureItem -Id 'sec-host-encryption-at-host' -AssessCheckId '' -Pillar 'security-posture' -Status 'fail' -ClaimRef 'ref:mcsb-avd-baseline#DP-5' -Message 'One or more collected session hosts lack encryptionAtHost.' -RemediationHint 'Enable encryptionAtHost on session host VM profiles.')
}

# 3. RDP device & clipboard redirection
$redirectionVals = @()
foreach ($hp in $hostPools) {
    $red = Get-FactProp -Obj $hp -Name 'redirection'
    if ($null -ne $red) {
        $redirectionVals += @(
            (Get-FactProp -Obj $red -Name 'drives'),
            (Get-FactProp -Obj $red -Name 'clipboard'),
            (Get-FactProp -Obj $red -Name 'usb')
        )
    }
}
if ($redirectionVals.Count -eq 0) {
    $checks += (Format-PostureItem -Id 'sec-host-rdp-redirection' -AssessCheckId 'asm-drive-usb-redirection-off' -Pillar 'security-posture' -Status 'unknown' -ClaimRef 'ref:avd-security-guide#device-redirection' -Message 'No host pool redirection properties present in C11 facts.')
}
elseif ($redirectionVals -contains 'on') {
    $checks += (Format-PostureItem -Id 'sec-host-rdp-redirection' -AssessCheckId 'asm-drive-usb-redirection-off' -Pillar 'security-posture' -Status 'fail' -ClaimRef 'ref:avd-security-guide#device-redirection' -Message 'Drive, clipboard, or USB redirection is enabled on one or more host pools.' -RemediationHint 'Disable drive, clipboard, and USB redirection in host pool RDP properties.')
}
elseif ($redirectionVals -contains 'default') {
    $checks += (Format-PostureItem -Id 'sec-host-rdp-redirection' -AssessCheckId 'asm-drive-usb-redirection-off' -Pillar 'security-posture' -Status 'warn' -ClaimRef 'ref:avd-security-guide#device-redirection' -Message 'One or more redirection properties rely on default behavior rather than explicit off.' -RemediationHint 'Explicitly set drives, clipboard, and USB redirection to off in host pool RDP properties.')
}
else {
    $checks += (Format-PostureItem -Id 'sec-host-rdp-redirection' -AssessCheckId 'asm-drive-usb-redirection-off' -Pillar 'security-posture' -Status 'pass' -ClaimRef 'ref:avd-security-guide#device-redirection' -Message 'Drive, clipboard, and USB redirection are explicitly disabled across collected host pools.')
}

# 4. EDR present
$edrMissingTotal = 0
$hasEdr = $false
foreach ($hp in $hostPools) {
    $sh = Get-FactProp -Obj $hp -Name 'sessionHosts'
    $em = Get-FactProp -Obj $sh -Name 'edrMissing'
    if ($null -ne $em) {
        $hasEdr = $true
        $edrMissingTotal += [int]$em
    }
}
if (-not $hasEdr) {
    $checks += (Format-PostureItem -Id 'sec-host-edr-present' -AssessCheckId 'asm-hosts-edr-present' -Pillar 'security-posture' -Status 'unknown' -ClaimRef 'ref:avd-security-guide#edr-microsoft-or-third-party' -Message 'No edrMissing counts present in C11 facts.')
}
elseif ($edrMissingTotal -eq 0) {
    $checks += (Format-PostureItem -Id 'sec-host-edr-present' -AssessCheckId 'asm-hosts-edr-present' -Pillar 'security-posture' -Status 'pass' -ClaimRef 'ref:avd-security-guide#edr-microsoft-or-third-party' -Message 'Zero session hosts flagged for missing EDR.')
}
else {
    $checks += (Format-PostureItem -Id 'sec-host-edr-present' -AssessCheckId 'asm-hosts-edr-present' -Pillar 'security-posture' -Status 'fail' -ClaimRef 'ref:avd-security-guide#edr-microsoft-or-third-party' -Message 'One or more session hosts are missing an active EDR agent.' -RemediationHint 'Onboard missing session hosts to Microsoft Defender for Endpoint or approved EDR.')
}

# 5. Defender for Servers plan
$vmTiers = @()
foreach ($s in $subs) {
    $dp = Get-FactProp -Obj $s -Name 'defenderPlans'
    $vmPlan = Get-FactProp -Obj $dp -Name 'VirtualMachines'
    if ($null -ne $vmPlan) { $vmTiers += $vmPlan }
}
if ($vmTiers.Count -eq 0) {
    $checks += (Format-PostureItem -Id 'sec-ctrl-defender-servers' -AssessCheckId 'asm-defender-servers' -Pillar 'security-posture' -Status 'unknown' -ClaimRef 'ref:avd-security-guide#defender-for-cloud' -Message 'No Defender for Cloud VirtualMachines plan tier present in C11 facts.')
}
elseif ($vmTiers -contains 'Free') {
    $checks += (Format-PostureItem -Id 'sec-ctrl-defender-servers' -AssessCheckId 'asm-defender-servers' -Pillar 'security-posture' -Status 'fail' -ClaimRef 'ref:avd-security-guide#defender-for-cloud' -Message 'Defender for Cloud VirtualMachines plan is Free on one or more subscriptions.' -RemediationHint 'Enable Standard Defender for Cloud (VirtualMachines P1) in enterprise deployments.')
}
else {
    $checks += (Format-PostureItem -Id 'sec-ctrl-defender-servers' -AssessCheckId 'asm-defender-servers' -Pillar 'security-posture' -Status 'pass' -ClaimRef 'ref:avd-security-guide#defender-for-cloud' -Message 'Defender for Cloud VirtualMachines plan is Standard across collected subscriptions.')
}

# 6. Azure Policy guardrails
$policySubs = @()
foreach ($s in $subs) {
    $pol = Get-FactProp -Obj $s -Name 'policy'
    $asgn = Get-FactProp -Obj $pol -Name 'assignments'
    if ($null -ne $asgn) { $policySubs += $pol }
}
if ($policySubs.Count -eq 0) {
    $checks += (Format-PostureItem -Id 'sec-ctrl-policy-guardrails' -AssessCheckId 'asm-policy-guardrails-assigned' -Pillar 'governance' -Status 'unknown' -ClaimRef 'ref:mcsb-avd-baseline#PA-7' -Message 'No Azure Policy assignment counts present in C11 facts.')
}
else {
    $zeroAsgn = @($policySubs | Where-Object { [int](Get-FactProp -Obj $_ -Name 'assignments') -eq 0 })
    $dne = @($policySubs | Where-Object {
        $v = Get-FactProp -Obj $_ -Name 'doNotEnforce'
        $null -ne $v -and [int]$v -gt 0
    })
    if ($zeroAsgn.Count -gt 0) {
        $checks += (Format-PostureItem -Id 'sec-ctrl-policy-guardrails' -AssessCheckId 'asm-policy-guardrails-assigned' -Pillar 'governance' -Status 'fail' -ClaimRef 'ref:mcsb-avd-baseline#PA-7' -Message 'One or more subscriptions have zero Azure Policy guardrail assignments.' -RemediationHint 'Deploy avd-security policy-assignments.bicep baseline.')
    }
    elseif ($dne.Count -gt 0) {
        $checks += (Format-PostureItem -Id 'sec-ctrl-policy-guardrails' -AssessCheckId 'asm-policy-guardrails-assigned' -Pillar 'governance' -Status 'warn' -ClaimRef 'ref:mcsb-avd-baseline#PA-7' -Message 'Policy assignments exist but one or more use DoNotEnforce mode.' -RemediationHint 'Switch policy assignments to Default enforcementMode.')
    }
    else {
        $checks += (Format-PostureItem -Id 'sec-ctrl-policy-guardrails' -AssessCheckId 'asm-policy-guardrails-assigned' -Pillar 'governance' -Status 'pass' -ClaimRef 'ref:mcsb-avd-baseline#PA-7' -Message 'Azure Policy guardrail assignments are active and enforced.')
    }
}

$passCount = @($checks | Where-Object { $_.status -eq 'pass' }).Count
$warnCount = @($checks | Where-Object { $_.status -eq 'warn' }).Count
$failCount = @($checks | Where-Object { $_.status -eq 'fail' }).Count
$unknownCount = @($checks | Where-Object { $_.status -eq 'unknown' }).Count

$report = [ordered]@{
    schema    = 'avd-security-posture/v1'
    checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    mode      = 'c11-facts'
    summary   = [ordered]@{
        total   = $checks.Count
        pass    = $passCount
        warn    = $warnCount
        fail    = $failCount
        unknown = $unknownCount
    }
    checks    = $checks
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding UTF8
}

return $report
