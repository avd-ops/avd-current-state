<#
    The state line the assessment portal reads (docs/assessment-portal-spec.md, section 3): one
    machine-readable line at the end of a collector, facts or validator run, so the page can say what ran
    and build the next block.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    <<<AVDCS-STATE {"v":1,"stage":"collect","status":"done",...} AVDCS-STATE>>>

    The line holds counts, relative package names and the estate pseudonym only, never a name or an ID:
    an operator may paste it anywhere. Its tag differs from the landing zone's, so neither portal misreads
    the other's output. Pure function; Windows PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest

$script:Stages   = @('collect', 'facts', 'analyze')
$script:Statuses = @('done', 'partial', 'failed')
# Context keys the line may carry. Anything else is refused, so a private value can't slip in by a new key.
$script:ContextKeys = @('subscriptions', 'package', 'estate', 'mode', 'verdict', 'snapshot')

function Get-AvdcsStateLine {
    <#
    .SYNOPSIS
        Builds the AVDCS-STATE line for a run. Throws on a stage, status or context key it doesn't know,
        and on a value that looks like an ID, an email address or a path outside the run's folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [hashtable]$Context = @{},
        [hashtable]$Counts = @{},
        [hashtable]$Coverage = @{}
    )
    if ($script:Stages -notcontains $Stage) { throw "Unknown state line stage '$Stage'." }
    if ($script:Statuses -notcontains $Status) { throw "Unknown state line status '$Status'." }
    foreach ($k in $Context.Keys) {
        if ($script:ContextKeys -notcontains $k) { throw "State line context key '$k' is not allowed." }
        $v = [string]$Context[$k]
        if ($v -match '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}' -or $v -match '@' -or $v -match '[\\/:]') {
            throw "State line context '$k' holds a value that looks private."
        }
    }
    foreach ($table in @($Counts, $Coverage)) {
        foreach ($k in $table.Keys) {
            if ($k -notmatch '^[A-Za-z][A-Za-z0-9]{0,40}$') { throw "State line count name '$k' is not allowed." }
            if ($table[$k] -isnot [int] -and $table[$k] -isnot [long]) { throw "State line count '$k' is not a whole number." }
        }
    }
    # Sorted keys, so the same run always gives the same line and tests can pin it.
    $sorted = {
        param($h)
        $o = [ordered]@{}
        foreach ($k in @($h.Keys | Sort-Object)) { $o[$k] = $h[$k] }
        $o
    }
    $state = [ordered]@{ v = 1; stage = $Stage; status = $Status }
    if ($Context.Count) { $state.context = & $sorted $Context }
    if ($Counts.Count) { $state.counts = & $sorted $Counts }
    if ($Coverage.Count) { $state.coverage = & $sorted $Coverage }
    $json = $state | ConvertTo-Json -Depth 4 -Compress
    "<<<AVDCS-STATE $json AVDCS-STATE>>>"
}

Export-ModuleMember -Function Get-AvdcsStateLine
