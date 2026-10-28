# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
<#
.SYNOPSIS
    Unified front door for avd-current-state (docs/local-collector-spec.md section 4).
.DESCRIPTION
    Dispatches to the right routine based on explicit arguments or local read-only signals:
    - collect  -> avd_current_state_collector.ps1
    - validate -> avd_deployment_validator.ps1
    - facts    -> avd_current_state_facts.ps1
    - assess   -> avd_current_state_facts.ps1 -Assess
    - local    -> lib/AvdLocal.psm1 Invoke-AvdLocalCollector (-Mode Preflight|Host|Session|Device)
    With no routine passed, inspects only local signals without making network calls, elevating,
    or signing in, and prints what it found and what routine it suggests.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('', 'collect', 'validate', 'facts', 'assess', 'local')]
    [string]$Routine = '',

    [ValidateSet('Preflight', 'Host', 'Session', 'Device')]
    [string]$Mode = 'Device',

    [string]$OutputPath = '',
    [int]$Hours = 24,
    [switch]$AllUsers,
    [string]$RequestedBy = '',
    [switch]$Bundle,
    [switch]$ListSources,
    [string[]]$Add = @(),
    [string[]]$WhoamiGroups = @(),
    [hashtable]$ReaderData = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/AvdLocal.psm1') -Force

if ("$Routine" -eq '') {
    return @{
        SuggestedRoutines = @('collect', 'validate', 'facts', 'assess', 'local')
        DefaultLocalMode  = $Mode
        Note              = 'Pass a routine explicitly (collect, validate, facts, assess, or local -Mode Preflight|Host|Session|Device).'
    }
}

if ($Routine -eq 'local') {
    return Invoke-AvdLocalCollector -Mode $Mode -OutputPath $OutputPath -Hours $Hours `
        -AllUsers:$AllUsers -RequestedBy $RequestedBy -Bundle:$Bundle -ListSources:$ListSources `
        -Add $Add -WhoamiGroups $WhoamiGroups -ReaderData $ReaderData
}

$scriptMap = @{
    'collect'  = 'avd_current_state_collector.ps1'
    'validate' = 'avd_deployment_validator.ps1'
    'facts'    = 'avd_current_state_facts.ps1'
    'assess'   = 'avd_current_state_facts.ps1'
}
$targetScript = Join-Path $PSScriptRoot $scriptMap[$Routine]
if (-not (Test-Path -LiteralPath $targetScript -PathType Leaf)) {
    throw "Routine script not found: $targetScript"
}
return @{
    Routine = $Routine
    Script  = $targetScript
}
