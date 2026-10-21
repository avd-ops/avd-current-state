<#
    The avd-assess method runner (avd-assess phase 4; docs/checks-spec.md, section 2): runs the pinned
    method's checks (assess/method.json, contract C20) over a C11 facts snapshot and an optional C19
    intake, scores the pillars and reports each target-state decision's readiness, as one C21
    assessment report.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    Pure functions over data already read: no Azure call, no network, no file reads. The rules are data
    (each, where, expect), never code from the method. The report carries only outcomes, pseudonyms and
    fact IDs, so it passes the same guard as the snapshot. Windows PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest

$script:Rank = @{ gap = 3; warn = 2; unknown = 1; pass = 0 }
$script:SubjectId = '^(est|sub|hp|st)-[0-9a-f]{8}$'

function Get-AssessProp {
    # StrictMode-safe property read on PSCustomObjects and hashtables; $null when absent.
    param([object]$InputObject, [string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $null }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-AssessStep {
    # One property step, as Found and Value: wrapping the value keeps a list of one a list and an
    # empty list a value (collected, none), where a function's plain return would unroll them.
    param([object]$Node, [string]$Name)
    $v = $null; $found = $false
    if ($Node -is [System.Collections.IDictionary]) { if ($Node.Contains($Name)) { $v = $Node[$Name]; $found = $true } }
    elseif ($null -ne $Node -and $Node -isnot [string] -and $Node -isnot [ValueType]) {
        $prop = $Node.PSObject.Properties[$Name]
        if ($null -ne $prop) { $v = $prop.Value; $found = $true }
    }
    [pscustomobject]@{ Found = ($found -and $null -ne $v); Value = $v }
}

function Get-AssessDateText {
    # A date as the contracts write it. PowerShell 7's ConvertFrom-Json turns ISO date strings into
    # DateTime values, so a value read back from JSON may be either.
    param($Value, [string]$Format)
    if ($Value -is [datetime]) {
        # A date with no zone (an intake's answeredOn) stays the date it says.
        if ($Value.Kind -ne [DateTimeKind]::Unspecified) { $Value = $Value.ToUniversalTime() }
        return $Value.ToString($Format, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return "$Value"
}

function Get-AssessPointerValue {
    # Every value a JSON pointer names, with * for every array item, one per output item (wrap the call
    # in @()). Missing steps give nothing. The method's pointer format allows only letters and digits in
    # a step, so there are no ~0 or ~1 escapes to decode.
    param([object]$Node, [string]$Pointer)
    $current = @(, $Node)
    foreach ($seg in ($Pointer.Trim('/') -split '/')) {
        if ($seg -eq '') { continue }
        $next = New-Object System.Collections.Generic.List[object]
        foreach ($n in $current) {
            if ($null -eq $n) { continue }
            if ($seg -eq '*') {
                foreach ($item in @($n)) { if ($null -ne $item) { $next.Add($item) } }
            } else {
                $step = Get-AssessStep $n $seg
                if ($step.Found) { $next.Add($step.Value) }
            }
        }
        $current = $next.ToArray()
    }
    return $current
}

function Get-AssessPropertyValue {
    # A subject's property by a relative path (a/b), and whether it was there at all.
    param([object]$Subject, [string]$Path)
    $step = [pscustomobject]@{ Found = $true; Value = $Subject }
    foreach ($seg in ($Path -split '/')) {
        $step = Get-AssessStep $step.Value $seg
        if (-not $step.Found) { break }
    }
    $step
}

function Test-AssessNumber {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [int16] -or $Value -is [byte])
}

function Test-AssessEqual {
    # Equality between a fact value and a rule scalar: booleans only equal booleans, numbers compare
    # as numbers, strings compare ignoring case (Azure's enums are case-insensitive).
    param($Actual, $Expected)
    if ($null -eq $Expected) { return $null -eq $Actual }
    if ($Expected -is [bool]) { return ($Actual -is [bool]) -and ($Actual -eq $Expected) }
    if (Test-AssessNumber $Expected) { return (Test-AssessNumber $Actual) -and ([double]$Actual -eq [double]$Expected) }
    if ($Actual -is [string]) { return [string]::Equals($Actual, [string]$Expected, [System.StringComparison]::OrdinalIgnoreCase) }
    return $false
}

function Get-AssessTestResult {
    # One test (eq, ne, min, max, in) on one value: $true, $false, or $null when it can't be applied
    # (a list or an object where a scalar belongs, a non-number for min or max).
    param($Actual, [object]$Test)
    if ($Actual -is [System.Collections.IEnumerable] -and $Actual -isnot [string]) { return $null }
    if ($null -ne $Actual -and -not ($Actual -is [string] -or $Actual -is [bool] -or (Test-AssessNumber $Actual))) { return $null }
    $op = @(if ($Test -is [System.Collections.IDictionary]) { $Test.Keys } else { $Test.PSObject.Properties.Name })
    $arg = Get-AssessProp $Test $op[0]
    switch ($op[0]) {
        'eq' { return [bool](Test-AssessEqual $Actual $arg) }
        'ne' { return -not (Test-AssessEqual $Actual $arg) }
        'min' { if (-not (Test-AssessNumber $Actual)) { return $null }; return [double]$Actual -ge [double]$arg }
        'max' { if (-not (Test-AssessNumber $Actual)) { return $null }; return [double]$Actual -le [double]$arg }
        'in' { foreach ($a in @($arg)) { if (Test-AssessEqual $Actual $a) { return $true } }; return $false }
        default { throw "Unknown rule test '$($op[0])'." }
    }
}

function Test-AssessRuleTest {
    # Whether a rule test is one the method format has: one operator, a number for min and max, a list
    # for in. Returns the reason it isn't, or nothing.
    param([object]$Test)
    $op = @(if ($Test -is [System.Collections.IDictionary]) { $Test.Keys } elseif ($null -ne $Test) { $Test.PSObject.Properties.Name })
    if ($op.Count -ne 1) { return "a test has $($op.Count) operators; it needs exactly one" }
    $arg = Get-AssessProp $Test $op[0]
    switch ($op[0]) {
        { $_ -in @('eq', 'ne') } { return }
        { $_ -in @('min', 'max') } { if (-not (Test-AssessNumber $arg)) { return "$($op[0]) needs a number" }; return }
        'in' { if (@($arg).Count -lt 1) { return 'in needs a list' }; return }
        default { return "'$($op[0])' isn't a rule test" }
    }
}

function Get-AssessTestSet {
    # A rule's where or expect object as (property, test) pairs, in the method's order.
    param([object]$Tests)
    if ($null -eq $Tests) { return @() }
    if ($Tests -is [System.Collections.IDictionary]) { return @($Tests.Keys | ForEach-Object { [pscustomobject]@{ Property = $_; Test = $Tests[$_] } }) }
    return @($Tests.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Property = $_.Name; Test = $_.Value } })
}

function Get-AssessFactPath {
    # The register's fact IDs to their paths (C15), for the facts that have one.
    param([object]$Register)
    $paths = @{}
    foreach ($f in @(Get-AssessProp $Register 'facts')) { $p = Get-AssessProp $f 'path'; if ($p) { $paths["$(Get-AssessProp $f 'id')"] = "$p" } }
    return $paths
}

function Test-AssessFactPresent {
    # Whether the inputs hold a fact: its register path names at least one value in the C11 snapshot
    # (c11.*) or the intake (intake.*). Other tiers (c12, partner facts) are never in these inputs.
    param([string]$Fact, [hashtable]$Path, [object]$Snapshot, [object]$Intake)
    if (-not $Path.ContainsKey($Fact)) { return $false }
    $from = if ($Fact -like 'intake.*') { $Intake } elseif ($Fact -like 'c11.*') { $Snapshot } else { $null }
    if ($null -eq $from) { return $false }
    return [bool]@(Get-AssessPointerValue -Node $from -Pointer $Path[$Fact]).Count
}

function Get-AssessWorst {
    param([string[]]$Outcome)
    $worst = $null
    foreach ($o in $Outcome) { if ($null -eq $worst -or $script:Rank[$o] -gt $script:Rank[$worst]) { $worst = $o } }
    if ($null -eq $worst) { return 'unknown' }
    return $worst
}

function Test-AssessIntakeOnly {
    # A check reads the intake when every fact it cites is an intake fact, the snapshot otherwise.
    param([object]$Check)
    $facts = @(Get-AssessProp $Check 'facts')
    return ($facts.Count -gt 0 -and @($facts | Where-Object { "$_" -notlike 'intake.*' }).Count -eq 0)
}

function Invoke-AvdAssessCheck {
    <#
    .SYNOPSIS
        Runs one method check (C20) over a C11 snapshot, or over the C19 intake when the check cites only
        intake facts, and returns its C21 result row.
    .DESCRIPTION
        The check's `each` pointer names the subjects. A subject the `where` tests exclude is not one of
        the check's subjects; a subject missing a `where` or `expect` property is unknown, never a failure.
        A subject passes when every `expect` test holds, and otherwise takes the check's `onFail` (gap
        unless the method says warn). The check's outcome is its subjects' worst: gap, then warn, then
        unknown, then pass; with no subjects it is unknown. Only builds data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Check,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [object]$Intake,
        [object]$Register
    )
    $rule = Get-AssessProp $Check 'rule'
    $onFail = "$(Get-AssessProp $rule 'onFail')"
    if (-not $onFail) { $onFail = 'gap' }
    if ($onFail -notin @('gap', 'warn')) { throw "Check $(Get-AssessProp $Check 'id') has onFail '$onFail'; it can only be gap or warn." }

    $where = @(Get-AssessTestSet (Get-AssessProp $rule 'where'))
    $expect = @(Get-AssessTestSet (Get-AssessProp $rule 'expect'))
    foreach ($t in @($where + $expect)) {
        $why = Test-AssessRuleTest $t.Test
        if ($why) { throw "Check $(Get-AssessProp $Check 'id'), property $($t.Property): $why." }
    }

    $intakeOnly = Test-AssessIntakeOnly $Check
    $root = if ($intakeOnly) { $Intake } else { $Snapshot }
    $estate = "$(Get-AssessProp $Snapshot 'estate')"
    $paths = Get-AssessFactPath $Register

    $subjects = New-Object System.Collections.Generic.List[object]
    if ($null -ne $root) {
        foreach ($s in @(Get-AssessPointerValue -Node $root -Pointer "$(Get-AssessProp $rule 'each')")) {
            # Every where test runs, so a test that excludes the subject wins over one that can't be
            # applied, whatever the order of the tests.
            $outcome = $null
            foreach ($w in $where) {
                $v = Get-AssessPropertyValue -Subject $s -Path $w.Property
                $t = if ($v.Found) { Get-AssessTestResult -Actual $v.Value -Test $w.Test } else { $null }
                if ($false -eq $t) { $outcome = 'excluded'; break }
                if ($null -eq $t) { $outcome = 'unknown' }
            }
            if ($outcome -eq 'excluded') { continue }
            if (-not $outcome -and -not $expect.Count) { $outcome = 'unknown' }
            if (-not $outcome) {
                $results = foreach ($e in $expect) {
                    $v = Get-AssessPropertyValue -Subject $s -Path $e.Property
                    if (-not $v.Found) { 'unknown'; continue }
                    $t = Get-AssessTestResult -Actual $v.Value -Test $e.Test
                    if ($null -eq $t) { 'unknown' } elseif ($t) { 'pass' } else { $onFail }
                }
                $outcome = Get-AssessWorst @($results)
            }
            $id = if ($intakeOnly) { $estate } else { "$(Get-AssessProp $s 'id')" }
            $subjects.Add([ordered]@{ id = $id; outcome = $outcome })
        }
    }

    # The check's facts that the inputs actually had, found by the register's paths.
    $had = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-AssessProp $Check 'facts')) {
        if (Test-AssessFactPresent -Fact "$f" -Path $paths -Snapshot $Snapshot -Intake $Intake) { $had.Add("$f") }
    }

    [ordered]@{
        check    = "$(Get-AssessProp $Check 'id')"
        outcome  = Get-AssessWorst @($subjects | ForEach-Object { $_.outcome })
        facts    = $had.ToArray()
        subjects = $subjects.ToArray()
    }
}

function Get-AvdAssessScore {
    <#
    .SYNOPSIS
        The method's scoring (severity-weighted/v1) over C21 result rows: per pillar, the passing severity
        weight over the assessed weight (a warn counts warnFactor) and coverage, the share of checks that
        aren't unknown. A pillar with nothing assessed scores null. The same rules as the brain's
        Get-AssessScore, so its Test-AssessmentReport recomputes the same numbers. Only builds data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Method,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Result
    )
    $outcome = @{}
    foreach ($r in $Result) { $outcome["$(Get-AssessProp $r 'check')"] = "$(Get-AssessProp $r 'outcome')" }
    $scoring = Get-AssessProp $Method 'scoring'
    $weights = Get-AssessProp $scoring 'weights'
    $warnFactor = [double](Get-AssessProp $scoring 'warnFactor')
    foreach ($g in @(@(Get-AssessProp $Method 'checks') | Group-Object { Get-AssessProp $_ 'pillar' } | Sort-Object Name)) {
        $assessed = 0; $weight = 0.0; $passed = 0.0
        foreach ($c in $g.Group) {
            $o = $outcome["$(Get-AssessProp $c 'id')"]
            if (-not $o -or $o -eq 'unknown') { continue }
            $w = [double](Get-AssessProp $weights "$(Get-AssessProp $c 'severity')")
            $assessed++; $weight += $w
            if ($o -eq 'pass') { $passed += $w } elseif ($o -eq 'warn') { $passed += $w * $warnFactor }
        }
        [ordered]@{
            pillar   = $g.Name
            checks   = [int]$g.Count
            assessed = [int]$assessed
            score    = if ($weight) { [Math]::Round($passed / $weight, 3) } else { $null }
            coverage = [Math]::Round($assessed / $g.Count, 3)
        }
    }
}

function Get-AvdAssessDecision {
    <#
    .SYNOPSIS
        Each target-state decision's readiness from the method (C20 readiness rows) and whether this
        estate's inputs supply what it needs, as C21 decision rows.
    .DESCRIPTION
        needs-measurement stays needs-measurement until measured use (C12) replaces the priors.
        decidable-with-intake without an intake is needs-intake. Otherwise a decision is supported when
        each input it draws on (the C11 snapshot, the intake) has at least one of its listed facts, and
        missing-facts when one doesn't. A collected empty list counts where it is the fact itself (no
        host pools is a host pool count); a per-pool fact needs a pool, so an estate with none is
        missing-facts for the decisions that read one. Only builds data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Method,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [object]$Intake,
        [Parameter(Mandatory = $true)][object]$Register
    )
    $paths = Get-AssessFactPath $Register
    foreach ($row in @(Get-AssessProp $Method 'readiness')) {
        $readiness = "$(Get-AssessProp $row 'readiness')"
        if ($readiness -notin @('decidable', 'decidable-with-intake', 'needs-measurement')) { throw "Decision $(Get-AssessProp $row 'decision') has readiness '$readiness', which the method format doesn't have." }
        $status = 'supported'
        if ($readiness -eq 'needs-measurement') { $status = 'needs-measurement' }
        # Without an intake, C21 allows only needs-intake here, even when C11 facts are missing too.
        elseif ($readiness -eq 'decidable-with-intake' -and $null -eq $Intake) { $status = 'needs-intake' }
        else {
            foreach ($prefix in @('c11.*', 'intake.*')) {
                $listed = @(@(Get-AssessProp $row 'facts') | Where-Object { "$_" -like $prefix })
                if (-not $listed.Count) { continue }
                if (-not @($listed | Where-Object { Test-AssessFactPresent -Fact "$_" -Path $paths -Snapshot $Snapshot -Intake $Intake }).Count) { $status = 'missing-facts' }
            }
        }
        [ordered]@{ decision = "$(Get-AssessProp $row 'decision')"; readiness = $readiness; status = $status }
    }
}

function Get-AvdAssessment {
    <#
    .SYNOPSIS
        One C21 assessment report (avd-assessment/v1): every method check run over the snapshot and the
        optional intake, the pillar scores and the decisions' readiness.
    .DESCRIPTION
        Refuses to build a report that would carry anything but pseudonyms, fact IDs and outcomes: a
        subject without a pseudonym, or a method whose register version differs from the register given.
        Only builds data; the caller writes it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Method,
        [Parameter(Mandatory = $true)][string]$MethodCommit,
        [Parameter(Mandatory = $true)][string]$MethodSha256,
        [Parameter(Mandatory = $true)][object]$Register,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$SnapshotSha256,
        [object]$Intake,
        [string]$IntakeSha256,
        [Parameter(Mandatory = $true)][string]$ProducerName,
        [Parameter(Mandatory = $true)][string]$ProducerVersion,
        [string]$GeneratedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    )
    if ("$(Get-AssessProp $Method 'schema')" -ne 'avd-assess-method/v1') { throw "The method isn't avd-assess-method/v1." }
    if ([int](Get-AssessProp $Method 'factRegister') -ne [int](Get-AssessProp $Register 'version')) {
        throw "The method cites fact register v$(Get-AssessProp $Method 'factRegister'); the register given is v$(Get-AssessProp $Register 'version'). Re-pin assess/ and contracts/ together."
    }
    $estate = "$(Get-AssessProp $Snapshot 'estate')"
    if ($estate -cnotmatch '^est-[0-9a-f]{8}$') { throw 'The snapshot has no estate pseudonym.' }
    $factsUtc = Get-AssessDateText (Get-AssessProp $Snapshot 'generatedUtc') "yyyy-MM-dd'T'HH:mm:ss'Z'"
    if ($factsUtc -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') { throw 'The snapshot has no generatedUtc in UTC (yyyy-MM-ddTHH:mm:ssZ).' }
    $answeredOn = if ($null -ne $Intake) { Get-AssessDateText (Get-AssessProp $Intake 'answeredOn') 'yyyy-MM-dd' } else { $null }
    if ($null -ne $Intake -and $answeredOn -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') { throw 'The intake has no answeredOn date (yyyy-MM-dd).' }
    if ($null -ne $Intake -and -not $IntakeSha256) { throw 'An intake needs its SHA-256.' }
    if ($null -ne $Intake -and "$(Get-AssessProp $Intake 'estate')" -ne $estate) { throw "The intake is for another estate than the snapshot ($estate)." }

    $results = @(foreach ($c in @(Get-AssessProp $Method 'checks')) { Invoke-AvdAssessCheck -Check $c -Snapshot $Snapshot -Intake $Intake -Register $Register })
    foreach ($r in $results) {
        foreach ($s in $r.subjects) {
            if ("$($s.id)" -cnotmatch $script:SubjectId) { throw "Refusing the report: a subject of $($r.check) has no pseudonym. Report the check ID, never the value." }
        }
    }
    $inputs = [ordered]@{ facts = [ordered]@{ generatedUtc = $factsUtc; sha256 = $SnapshotSha256.ToLowerInvariant() } }
    $inputs.intake = if ($null -ne $Intake) { [ordered]@{ answeredOn = $answeredOn; sha256 = $IntakeSha256.ToLowerInvariant() } } else { $null }

    [ordered]@{
        schema       = 'avd-assessment/v1'
        estate       = $estate
        generatedUtc = $GeneratedUtc
        producer     = [ordered]@{ name = $ProducerName; version = $ProducerVersion }
        method       = [ordered]@{
            version      = [int](Get-AssessProp $Method 'version')
            commit       = $MethodCommit.ToLowerInvariant()
            sha256       = $MethodSha256.ToLowerInvariant()
            factRegister = [int](Get-AssessProp $Method 'factRegister')
        }
        inputs       = $inputs
        results      = $results
        pillars      = @(Get-AvdAssessScore -Method $Method -Result $results)
        decisions    = @(Get-AvdAssessDecision -Method $Method -Snapshot $Snapshot -Intake $Intake -Register $Register)
    }
}

Export-ModuleMember -Function Invoke-AvdAssessCheck, Get-AvdAssessScore, Get-AvdAssessDecision, Get-AvdAssessment
