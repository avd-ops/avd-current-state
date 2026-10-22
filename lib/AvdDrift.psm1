<#
    Drift and conformance checks (docs/drift-spec.md): compare what avd-landing-zone last deployed with
    what is live, attribute every change, and report it, changing nothing.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    Pure functions over data already read: the subscription's deployment records, the rebuild map
    (lib/AvdRebuildMap.psm1), Resource Graph change rows, Activity Log events and the reviewed rule files.
    Nothing here calls Azure or writes to an estate. Windows PowerShell 5.1 and PowerShell 7.
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'AvdRebuild.psm1')

$script:Compared = @('found', 'derived')
$script:NeverCompared = @('secret', 'deployTime')
$script:CantTell = @('ambiguous', 'unexpressible', 'unknown')
# Types the Resource Graph change log doesn't cover; their changes come from the Activity Log (spec section 3.2).
$script:ActivityLogTypes = @('microsoft.authorization/roleassignments', 'microsoft.authorization/locks',
    'microsoft.authorization/policyassignments', 'microsoft.desktopvirtualization/hostpools/sessionhosts')
$script:MaxApprovalDays = 90
$script:ChangeLogDays = 14

# ---------------------------------------------------------------- values

function ConvertTo-DriftCanonicalJson {
    <#
    .SYNOPSIS
        Compact JSON with object keys sorted and one escaping rule, so the same value gives the same text
        (and the same digest) on Windows PowerShell 5.1 and PowerShell 7.
    #>
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [datetime] -or $Value -is [guid]) {
        $s = if ($Value -is [datetime]) { $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { "$Value" }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        foreach ($c in $s.ToCharArray()) {
            switch ([int]$c) {
                34 { [void]$sb.Append('\"') }
                92 { [void]$sb.Append('\\') }
                10 { [void]$sb.Append('\n') }
                13 { [void]$sb.Append('\r') }
                9 { [void]$sb.Append('\t') }
                default { if ([int]$c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) } else { [void]$sb.Append($c) } }
            }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [int16] -or $Value -is [byte]) {
        return ([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys | ForEach-Object { "$_" } | Sort-Object -CaseSensitive)
        return '{' + (@($keys | ForEach-Object { (ConvertTo-DriftCanonicalJson $_) + ':' + (ConvertTo-DriftCanonicalJson $Value[$_]) }) -join ',') + '}'
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $keys = @($Value.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object -CaseSensitive)
        return '{' + (@($keys | ForEach-Object { (ConvertTo-DriftCanonicalJson $_) + ':' + (ConvertTo-DriftCanonicalJson $Value.$_) }) -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return '[' + (@($Value | ForEach-Object { ConvertTo-DriftCanonicalJson $_ }) -join ',') + ']'
    }
    return ConvertTo-DriftCanonicalJson "$Value"
}

function Get-DriftDigest {
    <# .SYNOPSIS SHA-256 (lowercase hex) of a value's canonical JSON. #>
    param($Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-DriftCanonicalJson $Value))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function ConvertTo-DriftLiteral {
    <#
    .SYNOPSIS
        Renders a value from the estate (a name, a tag, a parameter value) as inline code that Markdown
        can't turn into a link, a mention or formatting (spec section 3.2 step 6).
    #>
    param($Value, [int]$MaxLength = 120)
    $text = if ($null -eq $Value) { 'null' } elseif ($Value -is [string]) { $Value } else { ConvertTo-DriftCanonicalJson $Value }
    $text = ($text -replace '[\r\n\t]', ' ') -replace '`', "'"
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + '...' }
    if ($text -eq '') { return '(empty)' }
    return '`' + $text + '`'
}

function Get-DriftEntryValue {
    # A map entry's value read directly: a function or an if-expression would unroll an empty array to null.
    param($Entry)
    if ($Entry -is [System.Collections.IDictionary]) { return , $Entry['value'] }
    return , $Entry.value
}

function Get-DriftDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse("$Value", [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
}

function Get-DriftFinding {
    param(
        [Parameter(Mandatory)] [string]$Check,
        [Parameter(Mandatory)] [ValidateSet('drift', 'unexplained-change', 'accepted', 'expired-exception', 'cant-tell', 'window-gap', 'suppression-unapproved', 'not-mapped', 'couldnt-check')] [string]$Kind,
        [Parameter(Mandatory)] [string]$Subject,
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('codify', 'revert', 'accept', 'investigate', 'approve', 'none')] [string]$Action = 'investigate',
        [bool]$Open = $true,
        [hashtable]$Data = @{}
    )
    return [pscustomobject][ordered]@{ check = $Check; kind = $Kind; subject = $Subject; message = $Message; action = $Action; open = $Open; data = $Data }
}

# ---------------------------------------------------------------- the declared side

function Get-DriftLandingZoneName {
    <# .SYNOPSIS The landing zone's names from its two naming parameters (avd-landing-zone bicep/main.bicep). #>
    param([Parameter(Mandatory)] [string]$NamePrefix, [Parameter(Mandatory)] [string]$Environment)
    $base = '{0}-{1}' -f $NamePrefix.Replace('-', '').ToLowerInvariant(), $Environment.ToLowerInvariant()
    if ($base -notmatch '^[a-z0-9]{1,8}-[a-z]{2,8}$') { throw "Unexpected landing zone name '$base'." }
    return [ordered]@{ baseName = $base; hostPool = "vdpool-$base"; resourceGroupPrefix = "rg-$base-"; controlPlaneGroup = "rg-$base-avd" }
}

function Get-DriftDeclaredState {
    <#
    .SYNOPSIS
        Picks the landing zone's last successful subscription deployment from the deployment records and
        returns its non-secure parameters (spec section 2). Deployments are the objects ARM lists under
        /subscriptions/{id}/providers/Microsoft.Resources/deployments. Returns $null when none matches.
    #>
    param(
        [object[]]$Deployments = @(),
        [string]$Environment,
        [string]$DeploymentName
    )
    $candidates = @(foreach ($d in @($Deployments | Where-Object { $null -ne $_ })) {
            $name = "$(Get-RebuildValue $d 'name' '')"
            if ($DeploymentName) { if ($name -ne $DeploymentName) { continue } }
            elseif ($name -notmatch '^avdlz-') { continue }
            if ("$(Get-RebuildValue $d 'properties.provisioningState' '')" -ne 'Succeeded') { continue }
            $params = Get-RebuildValue $d 'properties.parameters'
            if ($null -eq $params) { continue }
            $prefix = Get-RebuildValue $params 'namePrefix.value'
            $env = Get-RebuildValue $params 'environmentName.value'
            if (-not $prefix -or -not $env) { continue }
            if ($Environment -and $env -ne $Environment) { continue }
            [pscustomobject]@{ Deployment = $d; Prefix = "$prefix"; Environment = "$env"; Time = (Get-DriftDate (Get-RebuildValue $d 'properties.timestamp')) }
        })
    if ($candidates.Count -eq 0) { return $null }
    $envs = @($candidates | ForEach-Object { "$($_.Prefix)-$($_.Environment)" } | Sort-Object -Unique)
    if ($envs.Count -gt 1 -and -not $DeploymentName) {
        throw "More than one landing zone environment has a deployment ($($envs -join ', ')). Pass -Environment."
    }
    $pick = @($candidates | Sort-Object -Property Time -Descending)[0]
    $d = $pick.Deployment
    $values = [ordered]@{}; $secure = @()
    foreach ($p in @((Get-RebuildValue $d 'properties.parameters').PSObject.Properties)) {
        $type = "$(Get-RebuildValue $p.Value 'type' '')"
        if ($type -match '^secure') { $secure += $p.Name; continue }
        $values[$p.Name] = Get-DriftEntryValue $p.Value
    }
    $names = Get-DriftLandingZoneName -NamePrefix $pick.Prefix -Environment $pick.Environment
    return [ordered]@{
        source        = 'deployment-record'
        namePrefix    = $pick.Prefix
        environment   = $pick.Environment
        deployment    = "$(Get-RebuildValue $d 'name')"
        deploymentId  = "$(Get-RebuildValue $d 'id')"
        timestamp     = $pick.Time
        correlationId = "$(Get-RebuildValue $d 'properties.correlationId' '')"
        names         = $names
        parameters    = $values
        secure        = $secure
    }
}

function Get-DriftLandingZoneCorrelationId {
    <#
    .SYNOPSIS
        Correlation IDs of this landing zone's deployments (an avdlz-* name and the same namePrefix and
        environmentName, succeeded or not, since a failed deployment still changed what it reached), so
        their changes count as deployments. A deployment named that way with another template still
        passes: who may deploy at subscription scope is the reader proposal's control, not this one.
    #>
    param([object[]]$Deployments = @(), [string]$NamePrefix, [string]$Environment)
    return @($Deployments | Where-Object {
            $null -ne $_ -and "$(Get-RebuildValue $_ 'name' '')" -match '^avdlz-' -and
            (-not $NamePrefix -or "$(Get-RebuildValue $_ 'properties.parameters.namePrefix.value' '')" -eq $NamePrefix) -and
            (-not $Environment -or "$(Get-RebuildValue $_ 'properties.parameters.environmentName.value' '')" -eq $Environment) } |
            ForEach-Object { "$(Get-RebuildValue $_ 'properties.correlationId' '')".ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-DriftBaselineProposal {
    <#
    .SYNOPSIS
        A proposed declared state for an estate the landing zone didn't deploy: every found or derived
        value in the map, and the resource groups whose changes the run reads. A person reviews and
        commits it; nothing uses it until then (spec section 2).
    #>
    param([Parameter(Mandatory)] $Map, [string[]]$ResourceGroups = @())
    $values = [ordered]@{}
    $params = Get-RebuildValue $Map 'parameters'
    $names = if ($params -is [System.Collections.IDictionary]) { @($params.Keys) } else { @($params.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($n in $names) {
        $e = if ($params -is [System.Collections.IDictionary]) { $params[$n] } else { $params.$n }
        if ($script:Compared -contains "$(Get-RebuildValue $e 'status')") { $values[$n] = Get-DriftEntryValue $e }
    }
    return [ordered]@{ schema = 'avd-current-state-drift-baseline/v1'; hostPool = "$(Get-RebuildValue $Map 'hostPool')"
        resourceGroups = @($ResourceGroups | ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique); parameters = $values }
}

# ---------------------------------------------------------------- parameter drift

function Get-DriftException {
    # A parameter's exceptions, latest expiry first, so a renewal appended after an expired entry wins.
    param([object[]]$Exceptions, [string]$Parameter)
    return @($Exceptions | Where-Object { $null -ne $_ -and "$(Get-RebuildValue $_ 'parameter' '')" -eq $Parameter } |
            Sort-Object -Property @{ Expression = { $d = Get-DriftDate (Get-RebuildValue $_ 'expires'); if ($d) { $d } else { [datetime]::MinValue } } } -Descending)
}

function Test-DriftExpired {
    param($Exception, [datetime]$Now)
    $expires = Get-DriftDate (Get-RebuildValue $Exception 'expires')
    return ($null -eq $expires -or $expires -lt $Now)
}

function Get-DriftParameterResult {
    <#
    .SYNOPSIS
        Compares the declared parameters with one host pool's rebuild map, value by value (spec sections 2
        and 3.2 step 3). Returns findings: drift, accepted, expired-exception, cant-tell, not-mapped.
        Found and derived entries are compared; secret and deployTime never are; ambiguous, unexpressible
        and unknown are cant-tell unless an exception pins that status. A parameter the declared side
        doesn't carry is skipped. Under the auto shutdown power lock, Start VM on Connect off is expected.
    #>
    param(
        [Parameter(Mandatory)] $Map,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Declared,
        [Parameter(Mandatory)] $ParameterList,
        [object[]]$Exceptions = @(),
        [datetime]$Now = [datetime]::UtcNow,
        [bool]$PowerLocked = $false
    )
    $findings = @()
    $known = @($ParameterList.parameters | ForEach-Object { $_.name })
    $entries = Get-RebuildValue $Map 'parameters'
    $hostPool = (("$(Get-RebuildValue $Map 'hostPool' '')") -split '/')[-1]
    foreach ($name in $known) {
        if (-not $Declared.Contains($name)) { continue }
        $entry = if ($entries -is [System.Collections.IDictionary]) { $entries[$name] } else { Get-RebuildValue $entries $name }
        if ($null -eq $entry) { continue }
        $status = "$(Get-RebuildValue $entry 'status')"
        $want = $Declared[$name]
        $mine = @(Get-DriftException $Exceptions $name)
        if ($script:NeverCompared -contains $status) { continue }
        if ($script:CantTell -contains $status) {
            $exception = @($mine | Where-Object { "$(Get-RebuildValue $_ 'status' '')" -eq $status -and -not (Test-DriftExpired $_ $Now) }) | Select-Object -First 1
            if ($exception) {
                $findings += Get-DriftFinding -Check 'drift-cant-tell' -Kind 'cant-tell' -Subject $name -Open $false -Action 'none' `
                    -Message "$name can't be read back from the estate ($status); acknowledged until $(Get-RebuildValue $exception 'expires')."
            } else {
                $findings += Get-DriftFinding -Check 'drift-cant-tell' -Kind 'cant-tell' -Subject $name -Action 'accept' `
                    -Message "$name can't be read back from the estate ($status), so it isn't compared. Acknowledge it with an exception that pins the status." -Data @{ status = $status; note = "$(Get-RebuildValue $entry 'note' '')" }
            }
            continue
        }
        if ($script:Compared -notcontains $status) { continue }
        $got = Get-DriftEntryValue $entry
        $wantJson = ConvertTo-DriftCanonicalJson $want
        $gotJson = ConvertTo-DriftCanonicalJson $got
        if ($wantJson -eq $gotJson) { continue }
        if ($name -eq 'startVmOnConnect' -and $PowerLocked -and $gotJson -eq 'false') {
            $findings += Get-DriftFinding -Check 'drift-param' -Kind 'accepted' -Subject $name -Open $false -Action 'none' `
                -Message "Start VM on Connect is off because auto shutdown has locked the host pool $(ConvertTo-DriftLiteral $hostPool); expected while the lock holds."
            continue
        }
        $matching = @($mine | Where-Object { $_.PSObject.Properties['acceptedValue'] -and (ConvertTo-DriftCanonicalJson $_.acceptedValue) -eq $gotJson })
        if ($matching.Count -gt 0) {
            # Latest expiry first: if it has expired, they all have.
            $exception = $matching[0]
            if (Test-DriftExpired $exception $Now) {
                $findings += Get-DriftFinding -Check 'drift-exception-expired' -Kind 'expired-exception' -Subject $name -Action 'codify' `
                    -Message "$name differs from the deployment, and its exception expired on $(Get-RebuildValue $exception 'expires'). Renew it, codify the value, or revert." -Data @{ declared = $want; live = $got }
            } else {
                $findings += Get-DriftFinding -Check 'drift-param' -Kind 'accepted' -Subject $name -Open $false -Action 'none' `
                    -Message "$name differs from the deployment by an accepted exception, until $(Get-RebuildValue $exception 'expires')." -Data @{ declared = $want; live = $got }
            }
            continue
        }
        $findings += Get-DriftFinding -Check 'drift-param' -Kind 'drift' -Subject $name -Action 'revert' `
            -Message "$name was deployed as $(ConvertTo-DriftLiteral $want) and is now $(ConvertTo-DriftLiteral $got) ($status). Codify it in the parameter file, revert it with a redeploy, or accept it." `
            -Data @{ declared = $want; live = $got; status = $status }
    }
    $unmapped = @($Declared.Keys | Where-Object { $known -notcontains $_ })
    if ($unmapped.Count -gt 0) {
        $findings += Get-DriftFinding -Check 'drift-param' -Kind 'not-mapped' -Subject 'parameters' -Open $false -Action 'none' `
            -Message "$($unmapped.Count) deployed parameter(s) aren't mapped by this version of avd-current-state, so they aren't compared: $(($unmapped | Sort-Object | ForEach-Object { ConvertTo-DriftLiteral $_ }) -join ', ')."
    }
    return , $findings
}

# ---------------------------------------------------------------- changes and attribution

function ConvertFrom-DriftResourceChange {
    <# .SYNOPSIS One Resource Graph resourcechanges row as a change record. #>
    param([Parameter(Mandatory)] $Row)
    $attr = Get-RebuildValue $Row 'properties.changeAttributes'
    $props = @()
    $changes = Get-RebuildValue $Row 'properties.changes'
    if ($null -ne $changes) { $props = @($changes.PSObject.Properties | ForEach-Object { $_.Name }) }
    return [pscustomobject][ordered]@{
        id            = "$(Get-RebuildValue $Row 'id' '')"
        source        = 'change-log'
        resourceId    = "$(Get-RebuildValue $Row 'properties.targetResourceId' '')".ToLowerInvariant()
        type          = "$(Get-RebuildValue $Row 'properties.targetResourceType' '')".ToLowerInvariant()
        changeType    = "$(Get-RebuildValue $Row 'properties.changeType' '')"
        timestamp     = Get-DriftDate (Get-RebuildValue $attr 'timestamp')
        actorType     = "$(Get-RebuildValue $attr 'changedByType' '')"
        actor         = "$(Get-RebuildValue $attr 'changedBy' '')"
        clientType    = "$(Get-RebuildValue $attr 'clientType' '')"
        operation     = "$(Get-RebuildValue $attr 'operation' '')"
        correlationId = "$(Get-RebuildValue $attr 'correlationId' '')".ToLowerInvariant()
        properties    = $props
    }
}

function ConvertFrom-DriftActivityEvent {
    <#
    .SYNOPSIS
        One Activity Log event as a change record, or $null for anything but a succeeded write or delete
        on a type the change log doesn't cover. -AnyType keeps every type: for the span before the change
        log's 14 days, the Activity Log is the only record (who and when, no properties).
    #>
    param([Parameter(Mandatory)] $ActivityEvent, [switch]$AnyType)
    if ("$(Get-RebuildValue $ActivityEvent 'status.value' '')" -ne 'Succeeded') { return $null }
    $op = "$(Get-RebuildValue $ActivityEvent 'operationName.value' '')".ToLowerInvariant()
    if ($op -notmatch '/(write|delete)$') { return $null }
    $type = ($op -replace '/(write|delete)$', '')
    if (-not $AnyType -and $script:ActivityLogTypes -notcontains $type) { return $null }
    $caller = "$(Get-RebuildValue $ActivityEvent 'caller' '')"
    $actorType = if ($caller -match '@') { 'User' } elseif ($caller -match '^[0-9a-fA-F-]{36}$') { 'AppId' } else { 'Unknown' }
    return [pscustomobject][ordered]@{
        id            = "$(Get-RebuildValue $ActivityEvent 'eventDataId' '')"
        source        = 'activity-log'
        resourceId    = "$(Get-RebuildValue $ActivityEvent 'resourceId' '')".ToLowerInvariant()
        type          = $type
        changeType    = $(if ($op -match '/delete$') { 'Delete' } else { 'Update' })
        timestamp     = Get-DriftDate (Get-RebuildValue $ActivityEvent 'eventTimestamp')
        actorType     = $actorType
        actor         = $caller
        clientType    = ''
        operation     = $op
        correlationId = "$(Get-RebuildValue $ActivityEvent 'correlationId' '')".ToLowerInvariant()
        properties    = @()
    }
}

function Test-DriftPrefix {
    param([string]$Path, [string[]]$Prefixes)
    foreach ($p in $Prefixes) { if ($Path -eq $p -or $Path.StartsWith("$p.") -or $Path.StartsWith("$p[")) { return $true } }
    return $false
}

function Test-DriftRuleMatch {
    # Every field a rule gives must match; properties match when every changed property is covered.
    param($Rule, $Change)
    $types = @(Get-RebuildValue $Rule 'types' @())
    if ($types.Count -gt 0 -and $types -notcontains $Change.type) { return $false }
    foreach ($f in 'actorType', 'actor', 'clientType', 'operation') {
        $want = "$(Get-RebuildValue $Rule $f '')"
        if ($want -and $want -ne "$($Change.$f)") { return $false }
    }
    $props = @(Get-RebuildValue $Rule 'properties' @())
    if ($props.Count -gt 0) {
        $changed = @($Change.properties)
        if ($changed.Count -eq 0) { return $false }
        foreach ($c in $changed) { if (-not (Test-DriftPrefix $c $props)) { return $false } }
    }
    return $true
}

function Get-DriftActorText {
    <# .SYNOPSIS Who made a change, said without a name or an email (spec section 3.2 step 4). #>
    param($Change)
    switch -Regex ("$($Change.actorType)") {
        '^User$' { return 'a user' }
        '^AppId$' { return 'an app or managed identity' }
        '^System$' { return 'the platform (System)' }
        default {
            if ("$($Change.actor)" -match '@') { return 'a user' }
            foreach ($v in 'Unknown', 'Unspecified', 'System') { if ("$($Change.actor)" -eq $v) { return $v } }
            return 'Unknown'
        }
    }
}

function Get-DriftAttribution {
    <#
    .SYNOPSIS
        Attributes each change on a landing zone resource (spec section 3.2 step 4). First the changed
        properties that runtime-path rules cover are set aside; a change with nothing left is runtime.
        Then: deployment (its correlation ID is a landing zone deployment's), automation (an
        expected-actor rule matches what is left), or unexplained. A rule counts only when its approval
        holds ($Approval maps rule ID to the state from Get-DriftSuppressionApproval); an unapproved rule
        that would have matched is named in 'wouldMatch' and hides nothing. Returns one row per change.
    #>
    param(
        [object[]]$Changes = @(),
        [string[]]$DeploymentCorrelationIds = @(),
        [object[]]$ExpectedActors = @(),
        [object[]]$RuntimePaths = @(),
        [hashtable]$Approval = @{}
    )
    $approved = @($Approval.Keys | Where-Object { $Approval[$_] -eq 'approved' })
    $rows = @()
    $seen = @{}
    foreach ($c in @($Changes | Where-Object { $null -ne $_ } | Sort-Object -Property timestamp)) {
        $key = if ($c.id) { "$($c.source)|$($c.id)" } else { "$($c.resourceId)|$($c.timestamp)|$($c.operation)" }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $rules = @(); $would = @()
        $left = @($c.properties)
        foreach ($r in @($RuntimePaths | Where-Object { $null -ne $_ })) {
            $types = @(Get-RebuildValue $r 'types' @())
            if ($types.Count -gt 0 -and $types -notcontains $c.type) { continue }
            $props = @(Get-RebuildValue $r 'properties' @())
            $covered = @($left | Where-Object { Test-DriftPrefix $_ $props })
            if ($covered.Count -eq 0) { continue }
            $id = "$(Get-RebuildValue $r 'id')"
            if ($approved -contains $id) { $rules += $id; $left = @($left | Where-Object { -not (Test-DriftPrefix $_ $props) }) } else { $would += $id }
        }
        $by = 'unexplained'
        if (@($c.properties).Count -gt 0 -and $left.Count -eq 0 -and $rules.Count -gt 0) { $by = 'runtime' }
        elseif ($c.correlationId -and $DeploymentCorrelationIds -contains $c.correlationId) { $by = 'deployment' }
        else {
            $rest = $c.PSObject.Copy(); $rest.properties = $left
            foreach ($r in @($ExpectedActors | Where-Object { $null -ne $_ })) {
                if (-not (Test-DriftRuleMatch $r $rest)) { continue }
                $id = "$(Get-RebuildValue $r 'id')"
                if ($approved -contains $id) { $by = 'automation'; $rules += $id; break }
                $would += $id
            }
        }
        $rows += [pscustomobject][ordered]@{ change = $c; by = $by; rules = @($rules); wouldMatch = @($would | Sort-Object -Unique); properties = @($left) }
    }
    return , $rows
}

function Get-DriftChangeResult {
    <# .SYNOPSIS Findings for the unexplained changes, one per change, said in plain language. #>
    param([object[]]$Attribution = @())
    $findings = @()
    foreach ($a in @($Attribution | Where-Object { $_.by -eq 'unexplained' })) {
        $c = $a.change
        $props = @($a.properties)
        $what = if (@('Create', 'Delete') -contains $c.changeType) { "was $($c.changeType.ToLowerInvariant())d (the change log lists no properties for this)" }
        elseif ($props.Count -gt 0) { "changed: $((@($props) | Select-Object -First 5 | ForEach-Object { ConvertTo-DriftLiteral $_ }) -join ', ')$(if ($props.Count -gt 5) { " and $($props.Count - 5) more" })" }
        else { 'changed' }
        $client = if ($c.clientType) { " through $(ConvertTo-DriftLiteral $c.clientType)" } else { '' }
        $when = if ($c.timestamp) { $c.timestamp.ToString('yyyy-MM-dd HH:mm') + ' UTC' } else { 'at an unknown time' }
        $name = ("$($c.resourceId)" -split '/')[-1]
        $msg = "$(ConvertTo-DriftLiteral $c.type) $(ConvertTo-DriftLiteral $name) $what, by $(Get-DriftActorText $c)$client, $when. Correlation ID $(ConvertTo-DriftLiteral $c.correlationId)."
        if (@($a.wouldMatch).Count -gt 0) { $msg += " Rule(s) $((@($a.wouldMatch) | ForEach-Object { ConvertTo-DriftLiteral $_ }) -join ', ') would explain it but aren't approved." }
        $findings += Get-DriftFinding -Check 'drift-unexplained-change' -Kind 'unexplained-change' -Subject $c.resourceId -Message $msg -Action 'investigate' `
            -Data @{ source = $c.source; type = $c.type; changeType = $c.changeType; timestamp = $c.timestamp; correlationId = $c.correlationId; actor = (Get-DriftActorText $c); properties = $props }
    }
    return , $findings
}

function Get-DriftWindowGap {
    <#
    .SYNOPSIS
        A window-gap finding when the last successful run is older than the change log keeps (14 days),
        so changes in between can't be attributed from it (spec section 3.2). No last run: none.
    #>
    param($LastSuccess, [datetime]$Now = [datetime]::UtcNow)
    $last = Get-DriftDate $LastSuccess
    if ($null -eq $last) { return }
    $days = ($Now - $last).TotalDays
    if ($days -le $script:ChangeLogDays) { return }
    return (Get-DriftFinding -Check 'drift-window-gap' -Kind 'window-gap' -Subject 'window' -Action 'investigate' `
            -Message ("The last successful run was {0:N0} days ago, longer than the change log keeps ({1} days). Changes between {2:yyyy-MM-dd} and {3:yyyy-MM-dd} are read from the Activity Log only, which says who and when but not which properties changed." -f $days, $script:ChangeLogDays, $last, $Now.AddDays(-$script:ChangeLogDays)) `
            -Data @{ lastSuccess = $last })
}

# ---------------------------------------------------------------- suppression rules: approval and digest

function Resolve-DriftRule {
    <#
    .SYNOPSIS
        Replaces placeholders (<name>) in a rule's fields with the private repo's values, so the digest
        covers what the rule really matches. A placeholder with no value leaves the rule unresolved.
    #>
    param([Parameter(Mandatory)] $Rule, [System.Collections.IDictionary]$Values = @{})
    $json = ConvertTo-DriftCanonicalJson $Rule
    $missing = @()
    foreach ($m in [regex]::Matches($json, '<([a-z0-9-]{2,60})>')) {
        $k = $m.Groups[1].Value
        if ($Values.Contains($k)) { $json = $json.Replace("<$k>", (ConvertTo-DriftCanonicalJson "$($Values[$k])").Trim('"')) }
        else { $missing += $k }
    }
    $resolved = $json | ConvertFrom-Json
    return [pscustomobject]@{ Rule = $resolved; Missing = @($missing | Sort-Object -Unique) }
}

function Get-DriftSuppressionApproval {
    <#
    .SYNOPSIS
        For each suppression rule (expected actors, runtime paths, what-if noise), whether it may suppress:
        approved only when the private approvals list holds its exact digest, approved within the last 90
        days and not expired (spec section 3.6). Returns one row per rule: id, file, digest, state
        (approved, unapproved, changed, expired, unresolved), expires.
    #>
    param(
        [object[]]$Rules = @(),
        [object[]]$Approvals = @(),
        [datetime]$Now = [datetime]::UtcNow
    )
    $rows = @()
    foreach ($r in @($Rules | Where-Object { $null -ne $_ })) {
        $id = "$(Get-RebuildValue $r.Rule 'id')"
        $digest = Get-DriftDigest $r.Rule
        $mine = @($Approvals | Where-Object { $null -ne $_ -and "$(Get-RebuildValue $_ 'entry' '')" -eq $id })
        $same = @($mine | Where-Object { "$(Get-RebuildValue $_ 'digest' '')" -eq $digest })
        $state = 'unapproved'; $expires = $null
        if (@($r.Missing).Count -gt 0) { $state = 'unresolved' }
        elseif ($same.Count -gt 0) {
            # Any valid entry approves, so a renewal appended after an expired one counts.
            $state = 'expired'
            foreach ($m in $same) {
                $on = Get-DriftDate (Get-RebuildValue $m 'approvedOn')
                $until = Get-DriftDate (Get-RebuildValue $m 'expires')
                if ($null -eq $on -or $null -eq $until) { continue }
                if (($until - $on).TotalDays -gt $script:MaxApprovalDays -or $until -lt $Now -or $on -gt $Now) { if ($null -eq $expires -or $until -gt $expires) { $expires = $until }; continue }
                if ($state -ne 'approved' -or $until -gt $expires) { $expires = $until }
                $state = 'approved'
            }
        } elseif ($mine.Count -gt 0) { $state = 'changed' }
        $rows += [pscustomobject][ordered]@{ id = $id; file = $r.File; digest = $digest; state = $state; expires = $expires; missing = @($r.Missing) }
    }
    return , $rows
}

function Get-DriftSuppressionResult {
    <#
    .SYNOPSIS
        One finding per rule that may not suppress, saying why and how to approve it. It holds the issue
        open when the rule changed or its approval lapsed (someone must look), or when it would have
        explained a change in this run. A rule never approved that matched nothing, or one with no value
        for its placeholder (it can't match anything), is listed but doesn't hold the issue open.
    #>
    param([object[]]$Approval = @(), [object[]]$Attribution = @())
    $findings = @()
    foreach ($a in @($Approval | Where-Object { $_.state -ne 'approved' })) {
        $wouldHide = @($Attribution | Where-Object { @($_.wouldMatch) -contains $a.id }).Count
        $open = ($a.state -in @('changed', 'expired')) -or ($a.state -eq 'unapproved' -and $wouldHide -gt 0)
        $why = switch ($a.state) {
            'unapproved' { 'has no approval' }
            'changed' { 'changed since it was approved' }
            'expired' { 'has an approval that expired or runs longer than 90 days' }
            'unresolved' { "names placeholder(s) with no value: $((@($a.missing) | ForEach-Object { ConvertTo-DriftLiteral $_ }) -join ', ')" }
        }
        $findings += Get-DriftFinding -Check 'drift-suppression-unapproved' -Kind 'suppression-unapproved' -Subject $a.id -Action 'approve' -Open $open `
            -Message "Rule $(ConvertTo-DriftLiteral $a.id) in $(ConvertTo-DriftLiteral $a.file) $why, so it hides nothing: $(if ($wouldHide) { "$wouldHide change(s) it would explain are reported" } else { 'it matched no change in this run' }). Digest $(ConvertTo-DriftLiteral $a.digest)." `
            -Data @{ file = $a.file; digest = $a.digest; state = $a.state; wouldHide = $wouldHide }
    }
    return , $findings
}

function Get-DriftApprovalLine {
    <# .SYNOPSIS The approvals-file entry a person pastes to approve one rule; it never writes the file. #>
    param([Parameter(Mandatory)] $Approval, [datetime]$Now = [datetime]::UtcNow, [int]$Days = 90)
    if ($Days -lt 1 -or $Days -gt $script:MaxApprovalDays) { throw "An approval lasts 1 to $script:MaxApprovalDays days." }
    return ConvertTo-DriftCanonicalJson ([ordered]@{
            entry = $Approval.id; digest = $Approval.digest; approvedBy = 'owner'; approvedOn = $Now.ToString('yyyy-MM-dd')
            expires = $Now.AddDays($Days).ToString('yyyy-MM-dd'); reason = 'TODO: why this rule is right'
        })
}

function Get-DriftSuppressionDigest {
    <#
    .SYNOPSIS
        The weekly digest of suppression rules (spec section 3.6): per rule, how many changes it hid in the
        last 7 and 14 days with up to three examples, rules that hid nothing in 14 days, approvals expiring
        within 14 days, and rules waiting for approval. Rules over the threshold come first.
    #>
    param(
        [object[]]$Approval = @(),
        [object[]]$Attribution = @(),
        [datetime]$Now = [datetime]::UtcNow,
        [int]$Threshold = 50
    )
    $rows = @()
    foreach ($a in @($Approval)) {
        $hid = @($Attribution | Where-Object { @($_.rules) -contains $a.id -or @($_.wouldMatch) -contains $a.id })
        $week = @($hid | Where-Object { $_.change.timestamp -and $_.change.timestamp -ge $Now.AddDays(-7) })
        $examples = @($hid | Sort-Object { $_.change.timestamp } -Descending | Select-Object -First 3 | ForEach-Object {
                [ordered]@{ timestamp = $_.change.timestamp; type = $_.change.type; operation = $_.change.operation; correlationId = $_.change.correlationId } })
        $rows += [pscustomobject][ordered]@{
            id = $a.id; file = $a.file; state = $a.state; expires = $a.expires; hid7 = $week.Count; hid14 = $hid.Count
            overThreshold = ($week.Count -gt $Threshold); unused = ($hid.Count -eq 0)
            expiringSoon = ($a.state -eq 'approved' -and $null -ne $a.expires -and $a.expires -le $Now.AddDays(14))
            examples = $examples
        }
    }
    return , @($rows | Sort-Object -Property @{ Expression = 'overThreshold'; Descending = $true }, @{ Expression = 'hid7'; Descending = $true }, @{ Expression = 'id'; Descending = $false })
}

# ---------------------------------------------------------------- outcome and report

function Get-DriftExitCode {
    <#
    .SYNOPSIS
        2 when the run couldn't check, else 1 when any finding is open, else 0. Only 0 may close the
        issue (spec section 3.2 step 7).
    #>
    param([object[]]$Findings = @(), [bool]$CouldNotCheck = $false)
    if ($CouldNotCheck -or @($Findings | Where-Object { $_.kind -eq 'couldnt-check' }).Count -gt 0) { return 2 }
    if (@($Findings | Where-Object { $_.open }).Count -gt 0) { return 1 }
    return 0
}

function Get-DriftReport {
    <#
    .SYNOPSIS
        The Markdown report the issue shows: an outcome line, open findings by kind with their suggested
        action, closed ones collapsed, then the digest when asked for. Every estate value is a literal.
    #>
    param(
        [Parameter(Mandatory)] [string]$Environment,
        [object[]]$Findings = @(),
        [int]$ExitCode = 0,
        [System.Collections.IDictionary]$Summary = @{},
        [object[]]$Digest = @()
    )
    $outcome = switch ($ExitCode) { 0 { 'Clean: nothing drifted and every change is explained.' } 1 { 'Findings to review.' } default { "Couldn't check: the run is incomplete, so this isn't a clean result." } }
    $lines = @("# Drift: $(ConvertTo-DriftLiteral $Environment)", '', "**$outcome**", '')
    foreach ($k in $Summary.Keys) { $lines += "- $k`: $($Summary[$k])" }
    $titles = [ordered]@{
        'couldnt-check' = "Couldn't check"; 'drift' = 'Parameters that drifted'; 'expired-exception' = 'Expired exceptions'
        'unexplained-change' = 'Changes nobody explained'; 'suppression-unapproved' = 'Rules waiting for approval'
        'window-gap' = 'Gaps in the record'; 'cant-tell' = "Parameters it can't read back"
    }
    $open = @($Findings | Where-Object { $_.open })
    foreach ($k in $titles.Keys) {
        $group = @($open | Where-Object { $_.kind -eq $k })
        if ($group.Count -eq 0) { continue }
        $lines += ''; $lines += "## $($titles[$k]) ($($group.Count))"; $lines += ''
        foreach ($f in $group) { $lines += "- $($f.message) Suggested: **$($f.action)**." }
    }
    $closed = @($Findings | Where-Object { -not $_.open })
    if ($closed.Count -gt 0) {
        $lines += ''; $lines += "<details><summary>Accepted or informational ($($closed.Count))</summary>"; $lines += ''
        foreach ($f in $closed) { $lines += "- $($f.message)" }
        $lines += ''; $lines += '</details>'
    }
    if (@($Digest).Count -gt 0) {
        $lines += ''; $lines += '## Weekly digest of suppression rules'; $lines += ''
        $lines += '| Rule | File | State | Hid, 7 days | Hid, 14 days | Note |'; $lines += '|---|---|---|---|---|---|'
        foreach ($d in $Digest) {
            $note = @()
            if ($d.overThreshold) { $note += 'over threshold' }
            if ($d.unused) { $note += 'hid nothing in 14 days: drop it?' }
            if ($d.expiringSoon) { $note += "approval expires $($d.expires.ToString('yyyy-MM-dd'))" }
            $lines += "| $(ConvertTo-DriftLiteral $d.id) | $(ConvertTo-DriftLiteral $d.file) | $($d.state) | $($d.hid7) | $($d.hid14) | $($note -join '; ') |"
        }
    }
    $lines += ''; $lines += '_Read-only report from avd-current-state. Fixes go through the landing zone''s deploy workflow after a person approves; see docs/drift-spec.md section 3.4._'
    return ($lines -join "`n")
}

Export-ModuleMember -Function ConvertTo-DriftCanonicalJson, Get-DriftFinding, Get-DriftDigest, ConvertTo-DriftLiteral, Get-DriftLandingZoneName,
    Get-DriftDeclaredState, Get-DriftLandingZoneCorrelationId, Get-DriftBaselineProposal, Get-DriftParameterResult,
    ConvertFrom-DriftResourceChange, ConvertFrom-DriftActivityEvent, Get-DriftAttribution, Get-DriftChangeResult, Get-DriftWindowGap,
    Resolve-DriftRule, Get-DriftSuppressionApproval, Get-DriftSuppressionResult, Get-DriftApprovalLine, Get-DriftSuppressionDigest,
    Get-DriftExitCode, Get-DriftReport
