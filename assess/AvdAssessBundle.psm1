# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
#
# Checks a copy of the avd-assess map against its release manifest (datapackage.json, profile
# avd-assess-bundle/v1), the same checks as tools/avd_assess_bundle.py: the manifest's own hash, its
# shape, every wanted file's size and SHA-256, each document's schema string, and, on PowerShell 7.4 or
# later, each document against its JSON Schema (Test-Json). Runs on Windows PowerShell 5.1 and
# PowerShell 7 on any OS; never touches the network.
#
#   Import-Module ./tools/AvdAssessBundle.psm1
#   Get-AvdAssessBundleCheck -Path ./bundle
#   Get-AvdAssessBundleCheck -Path . -ManifestPath assess/datapackage.json -ManifestSha256 <hex> `
#       -PathMap @{ 'method.json' = 'assess/method.json' }
#
# Emits one item per check (id, status PASS/WARN/FAIL, detail) and stops at the first FAIL. Run it only
# after the bundle's attestation is checked, or use the copy you already vendor
# (docs/distribution-spec.md section 9).

Set-StrictMode -Version 2.0

$script:BundleProfile = 'avd-assess-bundle/v1'
# The schema strings this module was written for, by name and the majors it reads (as the Python verifier).
$script:Known = @{
    'avd-assess-index' = @(1); 'avd-assess-method' = @(1); 'avd-assess-map' = @(1)
    'avd-assess-security-review' = @(1); 'avd-assess-endpoints' = @(1); 'avd-assess-evidence' = @(1)
    'avd-fact-register' = @(1); 'avd-run-use-cases' = @(1); 'avd-current-state-facts' = @(1)
    'avd-intake' = @(1); 'avd-assessment' = @(1); 'avd-assessment-review' = @(1)
    'avd-remediation-plan' = @(1); 'avd-benchmark-result' = @(1); 'avd-run-record' = @(1); 'avd-run-cost' = @(1)
    'avd-run-journal' = @(1); 'avd-assess-bundle' = @(1)
}
$script:SemVer = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$'
$script:SchemaString = '^([a-z0-9-]+)/v([1-9]\d*)$'

function New-BundleCheckItem([string]$Id, [string]$Status, [string]$Detail) {
    [pscustomobject]@{ id = $Id; status = $Status; detail = $Detail }
}

function Get-BundleSha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-BundlePathProblem($Value) {
    if ($Value -isnot [string] -or $Value -eq '') { return 'not a string' }
    if ($Value.StartsWith('/') -or $Value.Contains('\') -or $Value.Contains(':')) { return 'absolute, drive or backslash' }
    foreach ($seg in $Value.Split('/')) {
        if ($seg -eq '' -or $seg -eq '.' -or $seg -eq '..') { return "empty, '.' or '..' segment" }
    }
    return $null
}

function Test-BundleProperty($Object, [string]$Name) {
    $null -ne $Object -and $Object -is [System.Management.Automation.PSCustomObject] -and
        ($Object.PSObject.Properties.Name -ccontains $Name)
}

function Get-BundleProfileError($Manifest) {
    $errs = New-Object System.Collections.Generic.List[string]
    if ($Manifest -isnot [System.Management.Automation.PSCustomObject]) { $errs.Add('the manifest is not a JSON object'); return $errs }
    # PowerShell 7 turns ISO date strings into [datetime] when it parses JSON; created may arrive as one.
    foreach ($pair in @(@('$schema', 'string'), @('name', 'string'), @('version', 'string'), @('created', 'string'),
            @('licenses', 'array'), @('resources', 'array'), @('avdAssess', 'object'))) {
        $ok = Test-BundleProperty $Manifest $pair[0]
        if ($ok) {
            $v = $Manifest.($pair[0])
            switch ($pair[1]) {
                'string' { $ok = $v -is [string] -or ($pair[0] -eq 'created' -and $v -is [datetime]) }
                'array' { $ok = $v -is [System.Array] }
                'object' { $ok = $v -is [System.Management.Automation.PSCustomObject] }
            }
        }
        if (-not $ok) { $errs.Add("$($pair[0]) missing or not a $($pair[1])") }
    }
    if ($errs.Count) { return $errs }
    if ($Manifest.name -cne 'avd-assess') { $errs.Add('name is not avd-assess') }
    if ($Manifest.version -cnotmatch $script:SemVer) { $errs.Add("version '$($Manifest.version)' is not semantic") }
    $a = $Manifest.avdAssess
    if (-not (Test-BundleProperty $a 'profile') -or $a.profile -cne $script:BundleProfile) { $errs.Add("avdAssess.profile is not $script:BundleProfile") }
    if (-not (Test-BundleProperty $a 'commit') -or $a.commit -isnot [string] -or $a.commit -cnotmatch '^[0-9a-f]{40}$') { $errs.Add('avdAssess.commit is not 40 hex') }
    if ((Test-BundleProperty $a 'tag') -and ($a.tag -isnot [string] -or $a.tag -cne ('v' + $Manifest.version))) { $errs.Add('avdAssess.tag is not v<version>') }
    $names = @{}; $paths = @{}; $listed = @{}
    foreach ($r in $Manifest.resources) { if (Test-BundleProperty $r 'path') { $listed[[string]$r.path] = $true } }
    $i = 0
    foreach ($r in $Manifest.resources) {
        $where = "resources[$i]"; $i++
        if ($r -isnot [System.Management.Automation.PSCustomObject]) { $errs.Add("$where is not an object"); continue }
        $name = if (Test-BundleProperty $r 'name') { $r.name } else { $null }
        if ($name -isnot [string] -or $name -cnotmatch '^[a-z0-9][a-z0-9._-]*$') { $errs.Add("$where.name missing or not lower case") }
        elseif ($names.ContainsKey($name)) { $errs.Add("$where.name $name is not unique") }
        else { $names[$name] = $true }
        $path = if (Test-BundleProperty $r 'path') { $r.path } else { $null }
        $why = Get-BundlePathProblem $path
        if ($why) { $errs.Add("$where.path '$path': $why") }
        elseif ($paths.ContainsKey($path)) { $errs.Add("$where.path $path is listed twice") }
        else { $paths[$path] = $true }
        $bytes = if (Test-BundleProperty $r 'bytes') { $r.bytes } else { $null }
        if (-not ($bytes -is [int] -or $bytes -is [long]) -or $bytes -lt 0) { $errs.Add("$where.bytes missing or not a whole number") }
        $hash = if (Test-BundleProperty $r 'hash') { $r.hash } else { $null }
        if ($hash -isnot [string] -or $hash -cnotmatch '^sha256:[0-9a-f]{64}$') { $errs.Add("$where.hash is not sha256:<64 lower-case hex>") }
        if ((Test-BundleProperty $r 'jsonSchema') -and (Get-BundlePathProblem $r.jsonSchema)) { $errs.Add("$where.jsonSchema '$($r.jsonSchema)': $(Get-BundlePathProblem $r.jsonSchema)") }
        if ((Test-BundleProperty $r 'jsonSchema') -and -not (Get-BundlePathProblem $r.jsonSchema) -and -not $listed.ContainsKey([string]$r.jsonSchema)) { $errs.Add("$where.jsonSchema $($r.jsonSchema) is not a resource, so its hash is not checked") }
        if ((Test-BundleProperty $r 'schemaString') -and ($r.schemaString -isnot [string] -or $r.schemaString -cnotmatch $script:SchemaString)) { $errs.Add("$where.schemaString is not <name>/v<major>") }
        if (Test-BundleProperty $r 'idPaths') {
            $ok = $r.idPaths -is [System.Array]
            if ($ok) { foreach ($p in $r.idPaths) { if ($p -isnot [string] -or -not $p.StartsWith('/')) { $ok = $false } } }
            if (-not $ok) { $errs.Add("$where.idPaths is not a list of JSON pointers") }
        }
    }
    return $errs
}

function Get-AvdAssessBundleCheck {
    <#
    .SYNOPSIS
    Checks a vendored copy of the avd-assess map against its release manifest; emits one item per check.
    .PARAMETER Path
    The bundle folder, or the folder that -PathMap's local paths and -ManifestPath are relative to.
    .PARAMETER ManifestPath
    datapackage.json, if not at <Path>/datapackage.json.
    .PARAMETER ManifestSha256
    The pin: the SHA-256 of datapackage.json from the consumer's PINS.json.
    .PARAMETER Resource
    Check only these resource names. Default: the paths in -PathMap, or every resource.
    .PARAMETER PathMap
    Bundle path to local path, for a consumer that keeps its own layout (@{ 'method.json' = 'assess/method.json' }).
    .PARAMETER KnownSchema
    The schema strings the caller reads (avd-assess-map/v1, ...). Default: the ones this module was written for.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ManifestPath,
        [string]$ManifestSha256,
        [string[]]$Resource,
        [hashtable]$PathMap = @{},
        [string[]]$KnownSchema
    )
    $root = $Path
    $mpath = if ($ManifestPath) { if ([System.IO.Path]::IsPathRooted($ManifestPath)) { $ManifestPath } else { Join-Path $root $ManifestPath } } else { Join-Path $root 'datapackage.json' }
    if (-not (Test-Path -LiteralPath $mpath -PathType Leaf)) { New-BundleCheckItem 'manifest-read' 'FAIL' "$mpath not found"; return }
    $raw = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $mpath).ProviderPath)
    $got = Get-BundleSha256Hex $raw
    if ($ManifestSha256) {
        if ($got -ne $ManifestSha256.ToLowerInvariant()) { New-BundleCheckItem 'manifest-pin' 'FAIL' "datapackage.json is $got, the pin says $($ManifestSha256.ToLowerInvariant())"; return }
        New-BundleCheckItem 'manifest-pin' 'PASS' "datapackage.json matches the pin $got"
    }
    try { $m = [System.Text.Encoding]::UTF8.GetString($raw) | ConvertFrom-Json -ErrorAction Stop }
    catch { New-BundleCheckItem 'manifest-profile' 'FAIL' "datapackage.json is not JSON ($($_.Exception.Message))"; return }
    $errs = @(Get-BundleProfileError $m)
    if ($errs.Count) { New-BundleCheckItem 'manifest-profile' 'FAIL' (($errs | Select-Object -First 5) -join '; '); return }
    New-BundleCheckItem 'manifest-profile' 'PASS' ("$script:BundleProfile, version $($m.version), commit $($m.avdAssess.commit.Substring(0, 12)), " +
        "$(@($m.resources).Count) resources")

    $byName = @{}; $byPath = @{}
    foreach ($r in $m.resources) { $byName[$r.name] = $r; $byPath[$r.path] = $r }
    foreach ($p in $PathMap.Keys) {
        if (-not $byPath.ContainsKey($p)) { New-BundleCheckItem 'resource-wanted' 'FAIL' "path map names $p, which is not in the manifest"; return }
    }
    if ($Resource) {
        $missing = @($Resource | Where-Object { -not $byName.ContainsKey($_) })
        if ($missing.Count) { New-BundleCheckItem 'resource-wanted' 'FAIL' "not in the manifest: $($missing -join ', ')"; return }
        $wanted = @($Resource | ForEach-Object { $byName[$_] })
    }
    elseif ($PathMap.Count) { $wanted = @($PathMap.Keys | Sort-Object | ForEach-Object { $byPath[$_] }) }
    else { $wanted = @($m.resources) }

    $localOf = {
        param($p)
        $rel = if ($PathMap.ContainsKey($p)) { $PathMap[$p] } else { $p }
        if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $root $rel }
    }
    $data = @{}
    foreach ($r in $wanted) {
        $f = & $localOf $r.path
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { New-BundleCheckItem 'resource-hash' 'FAIL' "$($r.path): missing (looked for $f)"; return }
        $b = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $f).ProviderPath)
        if ($b.Length -ne $r.bytes) { New-BundleCheckItem 'resource-hash' 'FAIL' "$($r.path): $($b.Length) bytes, the manifest says $($r.bytes)"; return }
        if (('sha256:' + (Get-BundleSha256Hex $b)) -cne $r.hash) { New-BundleCheckItem 'resource-hash' 'FAIL' "$($r.path): SHA-256 differs from the manifest"; return }
        $data[$r.path] = $b
    }
    New-BundleCheckItem 'resource-hash' 'PASS' "$($wanted.Count) files match their size and SHA-256"

    $known = @{}
    if ($KnownSchema) {
        foreach ($k in $KnownSchema) {
            if ($k -cnotmatch $script:SchemaString) { throw "KnownSchema '$k' is not <name>/v<major>" }
            if (-not $known.ContainsKey($Matches[1])) { $known[$Matches[1]] = @() }
            $known[$Matches[1]] += [int]$Matches[2]
        }
    }
    else { $known = $script:Known }
    $untyped = @($wanted | Where-Object { ($_.path -like '*.json' -or $_.path -like '*.jsonl') -and -not ((Test-BundleProperty $_ 'format') -and ($_.format -eq 'json' -or $_.format -eq 'jsonl')) } | ForEach-Object { $_.path })
    if ($untyped.Count) { New-BundleCheckItem 'resource-format' 'WARN' "not parsed or schema-checked, the manifest gives no json format: $(($untyped | Select-Object -First 5) -join ', ')" }
    $texts = @{}
    foreach ($r in $wanted) {
        $fmt = if (Test-BundleProperty $r 'format') { $r.format } else { $null }
        if ($fmt -ne 'json' -and $fmt -ne 'jsonl') { continue }
        $text = [System.Text.Encoding]::UTF8.GetString($data[$r.path])
        $lines = if ($fmt -eq 'jsonl') { @($text -split "`r?`n" | Where-Object { $_.Trim() }) } else { @($text) }
        $items = @()
        try { foreach ($l in $lines) { $items += , ($l | ConvertFrom-Json -ErrorAction Stop) } }
        catch { New-BundleCheckItem 'resource-schema-string' 'FAIL' "$($r.path): not $fmt ($($_.Exception.Message))"; return }
        if ($fmt -eq 'json') {
            $top = if (Test-BundleProperty $items[0] 'schema') { $items[0].schema } else { $null }
            $declared = if (Test-BundleProperty $r 'schemaString') { $r.schemaString } else { $null }
            if ($top -is [string] -and $top -cne $declared) { New-BundleCheckItem 'resource-schema-string' 'FAIL' "$($r.path): says '$top', the manifest says '$declared'"; return }
            if ($declared -and $null -eq $top) { New-BundleCheckItem 'resource-schema-string' 'FAIL' "$($r.path): has no schema string, the manifest says '$declared'"; return }
            if ($declared -and $declared -cmatch $script:SchemaString) {
                $name = $Matches[1]; $major = [int]$Matches[2]
                if ($known.ContainsKey($name) -and @($known[$name]) -notcontains $major) {
                    New-BundleCheckItem 'resource-schema-string' 'FAIL' "$($r.path): $declared is a major this reader does not know ($name v$(@($known[$name]) -join ','))"; return
                }
            }
        }
        $texts[$r.path] = $lines
    }
    New-BundleCheckItem 'resource-schema-string' 'PASS' "$($texts.Count) JSON files parse; every schema string matches the manifest"

    $withSchema = @($wanted | Where-Object { (Test-BundleProperty $_ 'jsonSchema') -and $texts.ContainsKey($_.path) })
    if (-not $withSchema.Count) { return }
    $canValidate = $PSVersionTable.PSVersion -ge [version]'7.4' -and (Get-Command Test-Json -ErrorAction SilentlyContinue)
    if (-not $canValidate) {
        New-BundleCheckItem 'resource-schema' 'WARN' "schemas not checked for $($withSchema.Count) files: Test-Json -Schema needs PowerShell 7.4 or later"
        return
    }
    $checked = 0; $unchecked = @()
    foreach ($r in $withSchema) {
        $sf = & $localOf $r.jsonSchema
        if (-not (Test-Path -LiteralPath $sf -PathType Leaf)) { $unchecked += $r.path; continue }
        $sb = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $sf).ProviderPath)
        if ($byPath.ContainsKey($r.jsonSchema) -and ('sha256:' + (Get-BundleSha256Hex $sb)) -cne $byPath[$r.jsonSchema].hash) {
            New-BundleCheckItem 'resource-schema' 'FAIL' "$($r.jsonSchema): SHA-256 differs from the manifest"; return
        }
        $schema = [System.Text.Encoding]::UTF8.GetString($sb)
        $n = 0
        foreach ($line in $texts[$r.path]) {
            $n++
            $errors = $null
            $ok = Test-Json -Json $line -Schema $schema -ErrorAction SilentlyContinue -ErrorVariable errors
            if (-not $ok) {
                $where = if ((Test-BundleProperty $r 'format') -and $r.format -eq 'jsonl') { "line $n " } else { '' }
                $msg = if ($errors) { ($errors | Select-Object -First 1).ToString() } else { 'not valid' }
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
                New-BundleCheckItem 'resource-schema' 'FAIL' "$($r.path): $where$msg"; return
            }
        }
        $checked++
    }
    if ($unchecked.Count) { New-BundleCheckItem 'resource-schema' 'WARN' "schemas not available locally for: $($unchecked -join ', ')" }
    New-BundleCheckItem 'resource-schema' 'PASS' "$checked files valid against their JSON Schema"
}

Export-ModuleMember -Function Get-AvdAssessBundleCheck
