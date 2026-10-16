<#
.SYNOPSIS
    AVD Second Brain -- turns collector and validator evidence packages into a living,
    Markdown knowledge base for an Azure Virtual Desktop estate.

.DESCRIPTION
    The collector answers "what is here today?" and the validator answers "is it healthy?".
    Each run is a point in time. This script remembers them: it ingests evidence packages
    into a Git-friendly Markdown vault (Obsidian-compatible) and keeps, per subscription,

      - an overview page with the latest inventory and validator verdicts
      - a timeline of every run
      - drift notes: what was added, removed or changed between two inventory snapshots
      - a findings register: every validator FAIL / WARN with first-seen and last-seen
        dates, closed only when the same check later passes
      - condensed snapshots (Markdown to read, JSON for tooling)

    Alongside the generated notes the vault holds the knowledge people carry in their
    heads: decisions (ADRs), runbooks, lessons and a glossary. A runbook that declares
    `resolves-checks` in its front matter is linked from every matching finding.

    The vault holds real tenant data. Keep it in its own private repository: this script
    and the vault template live here, the knowledge lives there.

    OFFLINE AND LOCAL
    ------------------------------------------------------------------
    This script makes no Azure call and needs no Az module. It reads evidence packages
    and writes only inside -BrainPath. Raw evidence is not copied into the vault; only
    condensed facts are.

    Generated content is rebuilt on every ingest. Human text placed outside the
    `<!-- brain:generated:start -->` / `<!-- brain:generated:end -->` markers is kept.

.PARAMETER BrainPath
    Folder of the vault. Usually the root of a private Git repository.

.PARAMETER Init
    Scaffolds the vault from the template. Existing files are never overwritten, so it is
    safe to run against a vault that already exists to pick up new template files.

.PARAMETER PackagePath
    One or more evidence packages to ingest: package folders, their ZIP archives, or a
    parent folder containing several. Collector and validator packages are told apart by
    their manifest. Packages are ingested oldest first whatever the order given.

.PARAMETER Force
    Re-ingest packages that were ingested before.

.PARAMETER TemplatePath
    Vault template. Defaults to second-brain/template next to this script.

.EXAMPLE
    .\avd_second_brain.ps1 -BrainPath ..\avd-brain -Init

.EXAMPLE
    .\avd_second_brain.ps1 -BrainPath ..\avd-brain -PackagePath .\avd-current-state-20261015T091500

.EXAMPLE
    .\avd_second_brain.ps1 -BrainPath ..\avd-brain -PackagePath (Get-ChildItem .\avd-*.zip)

.NOTES
    Requires PowerShell 5.1+ or 7+. No Az modules required.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BrainPath,
    [switch]$Init,
    [string[]]$PackagePath = @(),
    [switch]$Force,
    [string]$TemplatePath = (Join-Path $PSScriptRoot (Join-Path 'second-brain' 'template'))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StateSchemaVersion = 1
$script:GenStart = '<!-- brain:generated:start -->'
$script:GenEnd   = '<!-- brain:generated:end -->'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:TempDirs  = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------
# region Core Helpers
# ---------------------------------------------

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Level -eq 'ERROR')     { Write-Host $entry -ForegroundColor Red }
    elseif ($Level -eq 'WARN')  { Write-Host $entry -ForegroundColor Yellow }
    else                        { Write-Host $entry }
}

function Get-Prop {
    <#
    .SYNOPSIS
        StrictMode-safe property read. Returns $Default when the property is absent or null.
        Works on PSCustomObjects and hashtables alike.
    #>
    param([object]$InputObject, [string]$Name, $Default = $null)
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name) -and $null -ne $InputObject[$Name]) { return $InputObject[$Name] }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function ConvertTo-Hashtable {
    <#
    .SYNOPSIS
        Deep-converts ConvertFrom-Json output into ordered hashtables and arrays.
    .DESCRIPTION
        Windows PowerShell 5.1 has no ConvertFrom-Json -AsHashtable. State is mutated
        in place, which is far simpler on hashtables than on PSCustomObjects.
    #>
    param([object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    # PowerShell 7 turns ISO date strings into DateTime; keep them as sortable ISO strings
    if ($InputObject -is [datetime]) { return $InputObject.ToUniversalTime().ToString('o') }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [ordered]@{}
        foreach ($key in $InputObject.Keys) { $table[$key] = ConvertTo-Hashtable $InputObject[$key] }
        return $table
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $table[$p.Name] = ConvertTo-Hashtable $p.Value }
        return $table
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return ,@($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    return $InputObject
}

function Read-JsonFile {
    <#
    .SYNOPSIS Reads a JSON file. Returns $null when the file is missing, empty or unreadable.
    #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        Write-Log "Could not parse ${Path}: $($_.Exception.Message)" -Level WARN
        return $null
    }
}

function Read-Dataset {
    <#
    .SYNOPSIS
        Reads the rows of a collector dataset JSON file. A single-row dataset is
        serialised as a bare object, and an empty one may be missing or blank.
    #>
    param([string]$Directory, [string]$Name)
    $data = Read-JsonFile -Path (Join-Path $Directory "$Name.json")
    if ($null -eq $data) { return }
    # Emit rows one by one; callers wrap the call in @() to get an array back
    foreach ($row in @($data)) { $row }
}

function Write-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $normalised = ($Content -replace "`r`n", "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($Path, $normalised, $script:Utf8NoBom)
}

function Write-JsonFile {
    param([string]$Path, [object]$Data)
    Write-TextFile -Path $Path -Content ($Data | ConvertTo-Json -Depth 12)
}

function Set-GeneratedBlock {
    <#
    .SYNOPSIS
        Replaces the generated block of a Markdown file, keeping everything around it.
    .DESCRIPTION
        When the file does not exist it is created from $Header + block + $Footer. When
        it exists without markers, the block is inserted after the first heading so a
        hand-written page is never clobbered.
    #>
    param([string]$Path, [string]$Block, [string]$Header = '', [string]$Footer = '')
    $wrapped = "$script:GenStart`n$($Block.Trim())`n$script:GenEnd"
    if (-not (Test-Path -LiteralPath $Path)) {
        $parts = @($Header.Trim(), $wrapped, $Footer.Trim()) | Where-Object { $_ }
        Write-TextFile -Path $Path -Content ($parts -join "`n`n")
        return
    }
    $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $startIdx = $text.IndexOf($script:GenStart)
    $endIdx   = $text.IndexOf($script:GenEnd)
    if ($startIdx -ge 0 -and $endIdx -gt $startIdx) {
        $text = $text.Substring(0, $startIdx) + $wrapped + $text.Substring($endIdx + $script:GenEnd.Length)
    } else {
        $match = [regex]::Match($text, '(?m)^# .*$')
        if ($match.Success) {
            $at = $match.Index + $match.Length
            $text = $text.Substring(0, $at) + "`n`n" + $wrapped + "`n" + $text.Substring($at)
        } else {
            $text = $wrapped + "`n`n" + $text
        }
    }
    Write-TextFile -Path $Path -Content $text
}

function ConvertTo-Slug {
    param([string]$Text)
    $slug = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrEmpty($slug)) { $slug = 'unnamed' }
    return $slug
}

function ConvertTo-CellText {
    <#
    .SYNOPSIS Makes a value safe for a single Markdown table cell.
    #>
    param([object]$Value, [int]$MaxLength = 300)
    if ($null -eq $Value) { return '' }
    $text = ("$Value" -replace '\r?\n', ' ' -replace '\|', '\|').Trim()
    if ($text.Length -gt $MaxLength) { $text = $text.Substring(0, $MaxLength) + '...' }
    return $text
}

function Format-Utc {
    param([string]$Iso)
    if ([string]::IsNullOrWhiteSpace($Iso)) { return '' }
    try {
        return ([datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)).ToString('yyyy-MM-dd HH:mm') + ' UTC'
    } catch { return $Iso }
}

function Get-StampFromUtc {
    param([string]$Iso)
    return ([datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)).ToString('yyyyMMddTHHmmss')
}

function Get-Distinct {
    param([object[]]$Values)
    return ,@($Values | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") } | ForEach-Object { "$_" } | Sort-Object -Unique)
}

function Get-CountBy {
    <#
    .SYNOPSIS Counts rows by a property, returned as an ordered name -> count map.
    #>
    param([object[]]$Rows, [string]$Property)
    $map = [ordered]@{}
    foreach ($group in ($Rows | Group-Object -Property { $v = Get-Prop $_ $Property; if ($null -eq $v -or "$v" -eq '') { '(unknown)' } else { "$v" } } | Sort-Object Name)) {
        $map[$group.Name] = $group.Count
    }
    return $map
}

# endregion

# ---------------------------------------------
# region Vault and State
# ---------------------------------------------

function Initialize-Vault {
    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "Vault template not found at '$TemplatePath'. Pass -TemplatePath."
    }
    if (-not (Test-Path -LiteralPath $BrainPath)) { New-Item -ItemType Directory -Path $BrainPath -Force | Out-Null }
    $templateRoot = (Resolve-Path -LiteralPath $TemplatePath).Path
    $created = 0
    foreach ($file in (Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($templateRoot.Length).TrimStart('\', '/')
        $target = Join-Path $BrainPath $relative
        if (Test-Path -LiteralPath $target) { continue }
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        Copy-Item -LiteralPath $file.FullName -Destination $target
        $created++
    }
    Write-Log "Vault initialised at '$BrainPath' ($created new file(s))."
}

function Get-StatePath { Join-Path $BrainPath (Join-Path '.brain' 'state.json') }

function Read-State {
    $raw = Read-JsonFile -Path (Get-StatePath)
    if ($null -eq $raw) {
        return [ordered]@{
            SchemaVersion = $script:StateSchemaVersion
            Ingested      = @()
            Environments  = [ordered]@{}
        }
    }
    $state = ConvertTo-Hashtable $raw
    if ($null -eq $state['Ingested'])     { $state['Ingested'] = @() }
    if ($null -eq $state['Environments']) { $state['Environments'] = [ordered]@{} }
    return $state
}

function Save-State {
    param($State)
    Write-JsonFile -Path (Get-StatePath) -Data $State
}

function Get-Environment {
    <#
    .SYNOPSIS
        Returns the state record for a subscription, creating it on first sight.
    .DESCRIPTION
        Environments are keyed by subscription ID so a renamed subscription keeps its
        folder and history. The folder name is fixed at first sight.
    #>
    param($State, [string]$SubscriptionId, [string]$SubscriptionName)
    $key = if ($SubscriptionId) { $SubscriptionId.ToLowerInvariant() } else { "name:$SubscriptionName" }
    $envs = $State['Environments']
    if (-not $envs.Contains($key)) {
        $folder = ConvertTo-Slug $SubscriptionName
        $taken = @($envs.Values | ForEach-Object { $_['Folder'] })
        if ($taken -contains $folder) { $folder = "$folder-$($key.Substring(0, [Math]::Min(8, $key.Length)))" }
        $envs[$key] = [ordered]@{
            SubscriptionId   = $SubscriptionId
            SubscriptionName = $SubscriptionName
            Folder           = $folder
            Runs             = @()
            Findings         = [ordered]@{}
            LastInventory    = ''
            Verdicts         = [ordered]@{}
        }
    }
    $environment = $envs[$key]
    if ($SubscriptionName) { $environment['SubscriptionName'] = $SubscriptionName }
    return $environment
}

function Get-EnvironmentDir {
    param($Environment)
    return (Join-Path $BrainPath (Join-Path 'environments' $Environment['Folder']))
}

function Add-Run {
    param($Environment, [string]$Utc, [string]$Kind, [string]$Package, [string]$Summary, [string]$Link)
    $Environment['Runs'] = @(@($Environment['Runs']) + [ordered]@{
        Utc = $Utc; Kind = $Kind; Package = $Package; Summary = $Summary; Link = $Link
    })
}

# endregion

# ---------------------------------------------
# region Package Discovery
# ---------------------------------------------

function Resolve-Packages {
    <#
    .SYNOPSIS
        Expands -PackagePath into package folders that contain a manifest.json.
    .DESCRIPTION
        ZIP archives are expanded into a temporary folder that is removed at the end
        of the run. A parent folder is searched one level down for package folders and
        ZIPs, so pointing at an output directory picks up every run in it. The collector
        leaves a folder and a ZIP of the same package side by side; the folder wins.
    #>
    param([string[]]$Paths)
    $byName = [ordered]@{}
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log "Package path not found: $path" -Level WARN
            continue
        }
        $item = Get-Item -LiteralPath $path
        $manifests = @()
        $zips = @()
        if (-not $item.PSIsContainer) {
            if ($item.Extension -eq '.zip') { $zips = @($item) }
            else { Write-Log "Not a package folder or ZIP: $path" -Level WARN; continue }
        } elseif (Test-Path -LiteralPath (Join-Path $item.FullName 'manifest.json')) {
            $manifests = @(Join-Path $item.FullName 'manifest.json')
        } else {
            $manifests = @(Get-ChildItem -LiteralPath $item.FullName -Directory |
                ForEach-Object { Join-Path $_.FullName 'manifest.json' } |
                Where-Object { Test-Path -LiteralPath $_ })
            $zips = @(Get-ChildItem -LiteralPath $item.FullName -Filter '*.zip' -File)
        }
        foreach ($zip in $zips) {
            $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-brain-" + [guid]::NewGuid().ToString('N'))
            $script:TempDirs.Add($temp)
            Expand-Archive -LiteralPath $zip.FullName -DestinationPath $temp -Force
            # Compress-Archive keeps the package folder at the root of the archive
            $manifests += @(Get-ChildItem -LiteralPath $temp -Filter 'manifest.json' -File -Recurse -Depth 1 |
                ForEach-Object { $_.FullName })
        }
        if ($manifests.Count -eq 0) {
            Write-Log "No evidence package found in $path." -Level WARN
        }
        foreach ($manifestPath in $manifests) {
            $manifest = Read-JsonFile -Path $manifestPath
            if ($null -eq $manifest) { continue }
            $kind = $null
            if ($null -ne (Get-Prop $manifest 'Verdict')) { $kind = 'validation' }
            elseif ($null -ne (Get-Prop $manifest 'SubscriptionDetails')) { $kind = 'inventory' }
            if (-not $kind) {
                Write-Log "Unrecognised manifest: $manifestPath" -Level WARN
                continue
            }
            $packageName = "$(Get-Prop $manifest 'PackageName' (Split-Path -Leaf (Split-Path -Parent $manifestPath)))"
            if ($byName.Contains($packageName)) { continue }
            $generated = Get-Prop $manifest 'GeneratedUtc' ''
            if ($generated -is [datetime]) { $generated = $generated.ToUniversalTime().ToString('o') }
            if ([string]::IsNullOrWhiteSpace("$generated")) {
                Write-Log "Manifest has no GeneratedUtc, skipped: $manifestPath" -Level WARN
                continue
            }
            $byName[$packageName] = [pscustomobject]@{
                Kind         = $kind
                Name         = $packageName
                Directory    = Split-Path -Parent $manifestPath
                Manifest     = $manifest
                GeneratedUtc = "$generated"
            }
        }
    }
    return ,@($byName.Values | Sort-Object GeneratedUtc, Name)
}

# endregion

# ---------------------------------------------
# region Inventory Ingest
# ---------------------------------------------

function Get-InventoryFacts {
    <#
    .SYNOPSIS
        Condenses one subscription folder of a collector package into the facts the vault
        keeps. Raw rows stay in the evidence package.
    #>
    param([string]$Directory)

    $datasets = [ordered]@{}
    foreach ($file in (Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File | Sort-Object Name)) {
        $datasets[$file.BaseName] = @(Read-Dataset -Directory $Directory -Name $file.BaseName).Count
    }

    $hostPools = @(Read-Dataset -Directory $Directory -Name 'avd-host-pools' | ForEach-Object {
        [ordered]@{
            Name                  = Get-Prop $_ 'Name' ''
            ResourceGroupName     = Get-Prop $_ 'ResourceGroupName' ''
            Location              = Get-Prop $_ 'Location' ''
            HostPoolType          = "$(Get-Prop $_ 'HostPoolType' '')"
            LoadBalancerType      = "$(Get-Prop $_ 'LoadBalancerType' '')"
            MaxSessionLimit       = Get-Prop $_ 'MaxSessionLimit' ''
            StartVMOnConnect      = Get-Prop $_ 'StartVMOnConnect' ''
            ValidationEnvironment = Get-Prop $_ 'ValidationEnvironment' ''
        }
    } | Sort-Object { $_['Name'] })

    $sessionHosts = @(Read-Dataset -Directory $Directory -Name 'avd-session-hosts')
    $hostSummary = [ordered]@{}
    foreach ($group in ($sessionHosts | Group-Object -Property { "$(Get-Prop $_ 'HostPool' '(unknown)')" } | Sort-Object Name)) {
        $hostSummary[$group.Name] = [ordered]@{
            Count         = $group.Count
            ByStatus      = Get-CountBy -Rows $group.Group -Property 'Status'
            AgentVersions = Get-Distinct @($group.Group | ForEach-Object { Get-Prop $_ 'AgentVersion' })
            OSVersions    = Get-Distinct @($group.Group | ForEach-Object { Get-Prop $_ 'OSVersion' })
            Drained       = @($group.Group | Where-Object { "$(Get-Prop $_ 'AllowNewSession' '')" -eq 'False' }).Count
        }
    }

    $vms = @(Read-Dataset -Directory $Directory -Name 'virtual-machines')
    $resources = @(Read-Dataset -Directory $Directory -Name 'arm-resources' | ForEach-Object {
        $id = "$(Get-Prop $_ 'ResourceId' '')"
        if ($id) { [ordered]@{ Id = $id.ToLowerInvariant(); Type = "$(Get-Prop $_ 'ResourceType' '')"; Name = "$(Get-Prop $_ 'Name' '')" } }
    } | Sort-Object { $_['Id'] })

    return [ordered]@{
        Datasets     = $datasets
        HostPools    = $hostPools
        SessionHosts = $hostSummary
        VmBySize     = Get-CountBy -Rows $vms -Property 'VMSize'
        VmByPower    = Get-CountBy -Rows $vms -Property 'PowerState'
        Workspaces   = Get-Distinct @(Read-Dataset -Directory $Directory -Name 'avd-workspaces' | ForEach-Object { Get-Prop $_ 'Name' })
        AppGroups    = Get-Distinct @(Read-Dataset -Directory $Directory -Name 'avd-application-groups' | ForEach-Object { Get-Prop $_ 'Name' })
        Resources    = $resources
    }
}

function Format-Map {
    param($Map)
    if ($null -eq $Map -or $Map.Count -eq 0) { return '—' }
    return (@($Map.Keys | ForEach-Object { "$_ $($Map[$_])" }) -join ', ')
}

function Get-InventoryMarkdown {
    param($Environment, $Facts, [string]$Utc, [string]$Package)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Inventory snapshot — $($Environment['SubscriptionName']) — $(Format-Utc $Utc)")
    $lines.Add('')
    $lines.Add("Source package: ``$Package`` · Subscription ``$($Environment['SubscriptionId'])``")
    $lines.Add('')
    $lines.Add('## AVD workload')
    $lines.Add('')
    if ($Facts['HostPools'].Count -eq 0) {
        $lines.Add('_No host pools collected._')
    } else {
        $lines.Add('| Host pool | Type | Load balancer | Max sessions | Start VM on Connect | Session hosts | Status | Agent versions |')
        $lines.Add('|---|---|---|---|---|---|---|---|')
        foreach ($hp in $Facts['HostPools']) {
            $sh = Get-Prop $Facts['SessionHosts'] $hp['Name']
            $count = if ($sh) { $sh['Count'] } else { 0 }
            $status = if ($sh) { Format-Map $sh['ByStatus'] } else { '—' }
            $agents = if ($sh) { ($sh['AgentVersions'] -join ', ') } else { '' }
            $lines.Add("| $(ConvertTo-CellText $hp['Name']) | $($hp['HostPoolType']) | $($hp['LoadBalancerType']) | $($hp['MaxSessionLimit']) | $($hp['StartVMOnConnect']) | $count | $status | $(ConvertTo-CellText $agents) |")
        }
    }
    $lines.Add('')
    $lines.Add("- **Workspaces:** $(if ($Facts['Workspaces'].Count) { $Facts['Workspaces'] -join ', ' } else { '—' })")
    $lines.Add("- **Application groups:** $(if ($Facts['AppGroups'].Count) { $Facts['AppGroups'] -join ', ' } else { '—' })")
    $lines.Add("- **VMs by size:** $(Format-Map $Facts['VmBySize'])")
    $lines.Add("- **VMs by power state:** $(Format-Map $Facts['VmByPower'])")
    $lines.Add('')
    $lines.Add('## Dataset counts')
    $lines.Add('')
    $lines.Add('| Dataset | Rows |')
    $lines.Add('|---|---|')
    foreach ($k in $Facts['Datasets'].Keys) { $lines.Add("| $k | $($Facts['Datasets'][$k]) |") }
    return ($lines -join "`n")
}

function Compare-Inventory {
    <#
    .SYNOPSIS Describes what changed between two inventory fact sets. Returns $null when nothing did.
    #>
    param($Previous, $Current)
    $sections = New-Object System.Collections.Generic.List[string]

    $prevIds = @{}; foreach ($r in @($Previous['Resources'])) { $prevIds[$r['Id']] = $r }
    $currIds = @{}; foreach ($r in @($Current['Resources']))  { $currIds[$r['Id']] = $r }
    $added   = @($currIds.Keys | Where-Object { -not $prevIds.ContainsKey($_) } | Sort-Object)
    $removed = @($prevIds.Keys | Where-Object { -not $currIds.ContainsKey($_) } | Sort-Object)
    $limit = 50
    foreach ($pair in @(@('Resources added', $added, $currIds), @('Resources removed', $removed, $prevIds))) {
        $title, $ids, $lookup = $pair
        if ($ids.Count -eq 0) { continue }
        $block = @("### $title ($($ids.Count))", '', '| Type | Name | Resource ID |', '|---|---|---|')
        foreach ($id in ($ids | Select-Object -First $limit)) {
            $block += "| $($lookup[$id]['Type']) | $(ConvertTo-CellText $lookup[$id]['Name']) | ``$id`` |"
        }
        if ($ids.Count -gt $limit) { $block += '', "_…and $($ids.Count - $limit) more. See the evidence packages for the full list._" }
        $sections.Add(($block -join "`n"))
    }

    $countRows = @()
    $allSets = @(@($Previous['Datasets'].Keys) + @($Current['Datasets'].Keys) | Sort-Object -Unique)
    foreach ($ds in $allSets) {
        $before = [int](Get-Prop $Previous['Datasets'] $ds 0)
        $after  = [int](Get-Prop $Current['Datasets'] $ds 0)
        if ($before -ne $after) {
            $delta = $after - $before
            $countRows += "| $ds | $before | $after | $(if ($delta -gt 0) { "+$delta" } else { $delta }) |"
        }
    }
    if ($countRows.Count -gt 0) {
        $sections.Add((@('### Dataset counts', '', '| Dataset | Before | After | Change |', '|---|---|---|---|') + $countRows) -join "`n")
    }

    $hpRows = @()
    $prevPools = @{}; foreach ($hp in @($Previous['HostPools'])) { $prevPools[$hp['Name']] = $hp }
    $currPools = @{}; foreach ($hp in @($Current['HostPools']))  { $currPools[$hp['Name']] = $hp }
    foreach ($name in @(@($prevPools.Keys) + @($currPools.Keys) | Sort-Object -Unique)) {
        if (-not $prevPools.ContainsKey($name)) { $hpRows += "- **$name** — host pool added"; continue }
        if (-not $currPools.ContainsKey($name)) { $hpRows += "- **$name** — host pool removed"; continue }
        foreach ($field in @('HostPoolType', 'LoadBalancerType', 'MaxSessionLimit', 'StartVMOnConnect', 'ValidationEnvironment')) {
            $a = "$($prevPools[$name][$field])"; $b = "$($currPools[$name][$field])"
            if ($a -ne $b) { $hpRows += "- **$name** — $field ``$a`` → ``$b``" }
        }
        $shA = Get-Prop $Previous['SessionHosts'] $name
        $shB = Get-Prop $Current['SessionHosts'] $name
        $countA = if ($shA) { $shA['Count'] } else { 0 }
        $countB = if ($shB) { $shB['Count'] } else { 0 }
        if ($countA -ne $countB) { $hpRows += "- **$name** — session hosts $countA → $countB" }
        foreach ($field in @('AgentVersions', 'OSVersions')) {
            $a = if ($shA) { @($shA[$field]) -join ', ' } else { '' }
            $b = if ($shB) { @($shB[$field]) -join ', ' } else { '' }
            if ($a -ne $b) { $hpRows += "- **$name** — $field ``$a`` → ``$b``" }
        }
    }
    if ($hpRows.Count -gt 0) { $sections.Add((@('### AVD host pools', '') + $hpRows) -join "`n") }

    if ($sections.Count -eq 0) { return $null }
    return ($sections -join "`n`n")
}

function Import-InventoryPackage {
    param($State, $Package)
    $manifest = $Package.Manifest
    $utc = $Package.GeneratedUtc
    $stamp = Get-StampFromUtc $utc
    $subscriptions = @(Get-Prop $manifest 'SubscriptionDetails' @())

    foreach ($sub in $subscriptions) {
        $subName = "$(Get-Prop $sub 'SubscriptionName' '')"
        $subId   = "$(Get-Prop $sub 'SubscriptionId' '')"
        $status  = "$(Get-Prop $sub 'Status' '')"
        $environment = Get-Environment -State $State -SubscriptionId $subId -SubscriptionName $subName
        $envDir = Get-EnvironmentDir $environment

        if ($status -ne 'Collected') {
            Add-Run -Environment $environment -Utc $utc -Kind 'inventory' -Package $Package.Name `
                -Summary "Not collected: $status. $(Get-Prop $sub 'Reason' '')" -Link ''
            continue
        }

        # Same folder naming as the collector's Sanitize-FolderName
        $folderName = $subName -replace '[^\w\-\.\s]', '_' -replace '\s+', '_'
        $subDir = Join-Path $Package.Directory $folderName
        if (-not (Test-Path -LiteralPath $subDir)) {
            Write-Log "  Subscription folder '$folderName' missing from $($Package.Name)." -Level WARN
            continue
        }

        $facts = Get-InventoryFacts -Directory $subDir
        $snapshotBase = "$stamp-inventory"
        Write-JsonFile -Path (Join-Path $envDir "snapshots/$snapshotBase.json") -Data $facts
        Write-TextFile -Path (Join-Path $envDir "snapshots/$snapshotBase.md") `
            -Content (Get-InventoryMarkdown -Environment $environment -Facts $facts -Utc $utc -Package $Package.Name)

        $sessionHostTotal = 0
        foreach ($k in $facts['SessionHosts'].Keys) { $sessionHostTotal += $facts['SessionHosts'][$k]['Count'] }
        $summary = "$($facts['HostPools'].Count) host pool(s), $sessionHostTotal session host(s), $($facts['Resources'].Count) ARM resource(s)"

        Add-Run -Environment $environment -Utc $utc -Kind 'inventory' -Package $Package.Name `
            -Summary $summary -Link "snapshots/$snapshotBase.md"
        if ($utc -gt "$($environment['LastInventory'])") { $environment['LastInventory'] = $utc }
        Write-Log "  $subName -- $summary"
    }
}

# endregion

# ---------------------------------------------
# region Validation Ingest
# ---------------------------------------------

function Get-FindingKey {
    param($Result)
    return (@('Phase', 'Category', 'Check', 'Scope') | ForEach-Object { "$(Get-Prop $Result $_ '')".Trim().ToLowerInvariant() }) -join '|'
}

function Import-ValidationPackage {
    param($State, $Package)
    $manifest = $Package.Manifest
    $utc = $Package.GeneratedUtc
    $stamp = Get-StampFromUtc $utc
    $mode = "$(Get-Prop $manifest 'Mode' 'Unknown')"
    $verdict = "$(Get-Prop $manifest 'Verdict' '')"
    $counts = Get-Prop $manifest 'Counts'
    $environment = Get-Environment -State $State `
        -SubscriptionId "$(Get-Prop $manifest 'SubscriptionId' '')" `
        -SubscriptionName "$(Get-Prop $manifest 'SubscriptionName' 'unknown-subscription')"
    $envDir = Get-EnvironmentDir $environment

    $results = @(Read-Dataset -Directory $Package.Directory -Name 'validation-results' | ForEach-Object {
        [ordered]@{
            Phase          = "$(Get-Prop $_ 'Phase' '')"
            Category       = "$(Get-Prop $_ 'Category' '')"
            Check          = "$(Get-Prop $_ 'Check' '')"
            Status         = "$(Get-Prop $_ 'Status' '')"
            Scope          = "$(Get-Prop $_ 'Scope' '')"
            Detail         = "$(Get-Prop $_ 'Detail' '')"
            Recommendation = "$(Get-Prop $_ 'Recommendation' '')"
        }
    })
    $issues = @($results | Where-Object { $_['Status'] -in @('FAIL', 'WARN') } |
        Sort-Object @{ E = { if ($_['Status'] -eq 'FAIL') { 0 } else { 1 } } }, @{ E = { $_['Phase'] } }, @{ E = { $_['Category'] } }, @{ E = { $_['Check'] } })

    $snapshotBase = "$stamp-validation-$(ConvertTo-Slug $mode)"
    $countText = '—'
    if ($counts) {
        $countText = "FAIL $(Get-Prop $counts 'Fail' 0) · WARN $(Get-Prop $counts 'Warn' 0) · PASS $(Get-Prop $counts 'Pass' 0) · INFO $(Get-Prop $counts 'Info' 0) · SKIP $(Get-Prop $counts 'Skip' 0)"
    }

    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("# Validation snapshot — $($environment['SubscriptionName']) — $(Format-Utc $utc)")
    $md.Add('')
    $md.Add("Mode **$mode** · Verdict **$verdict** · $countText")
    $md.Add('')
    $md.Add("Source package: ``$($Package.Name)``")
    $md.Add('')
    $inputs = Get-Prop $manifest 'Inputs'
    if ($inputs) {
        $md.Add('## Inputs')
        $md.Add('')
        foreach ($p in $inputs.PSObject.Properties) {
            if ($null -ne $p.Value -and "$($p.Value)" -ne '' -and "$($p.Value)" -ne '0') { $md.Add("- $($p.Name): ``$($p.Value)``") }
        }
        $md.Add('')
    }
    $md.Add('## Failures and warnings')
    $md.Add('')
    if ($issues.Count -eq 0) {
        $md.Add('_None._')
    } else {
        $md.Add('| Status | Phase | Category | Check | Scope | Detail | Recommendation |')
        $md.Add('|---|---|---|---|---|---|---|')
        foreach ($r in $issues) {
            $md.Add("| $($r['Status']) | $($r['Phase']) | $($r['Category']) | $(ConvertTo-CellText $r['Check']) | $(ConvertTo-CellText $r['Scope']) | $(ConvertTo-CellText $r['Detail']) | $(ConvertTo-CellText $r['Recommendation']) |")
        }
    }
    Write-TextFile -Path (Join-Path $envDir "snapshots/$snapshotBase.md") -Content ($md -join "`n")
    # Every result is kept, not only the issues: a later PASS is what closes a finding
    Write-JsonFile -Path (Join-Path $envDir "snapshots/$snapshotBase.json") -Data ([ordered]@{
        GeneratedUtc = $utc; Package = $Package.Name; Mode = $mode; Verdict = $verdict
        Counts = $counts; Inputs = $inputs; Results = $results
    })

    Add-Run -Environment $environment -Utc $utc -Kind 'validation' -Package $Package.Name `
        -Summary "$mode → **$verdict** ($countText)" -Link "snapshots/$snapshotBase.md"
    $previousVerdict = Get-Prop $environment['Verdicts'] $mode
    if ($null -eq $previousVerdict -or $utc -ge $previousVerdict['Utc']) {
        $environment['Verdicts'][$mode] = [ordered]@{ Verdict = $verdict; Utc = $utc; Counts = $countText; Link = "snapshots/$snapshotBase.md" }
    }
    Write-Log "  $($environment['SubscriptionName']) -- $mode $verdict"
}

# endregion

# ---------------------------------------------
# region Derived Knowledge
# ---------------------------------------------
# Drift and findings are rebuilt from every snapshot, in time order, on each ingest.
# Packages can therefore arrive in any order -- a backfilled run slots into history
# exactly as if it had been ingested on the day -- and the result is deterministic.

function Update-Drift {
    <#
    .SYNOPSIS Rewrites drift/ from consecutive inventory snapshots. Returns snapshot link -> annotation.
    #>
    param($Environment)
    $envDir = Get-EnvironmentDir $Environment
    $notes = @{}
    $driftDir = Join-Path $envDir 'drift'
    if (Test-Path -LiteralPath $driftDir) {
        Get-ChildItem -LiteralPath $driftDir -Filter '*.md' -File | Remove-Item -Force
    }
    $snapDir = Join-Path $envDir 'snapshots'
    if (-not (Test-Path -LiteralPath $snapDir)) { return $notes }
    $snapshots = @(Get-ChildItem -LiteralPath $snapDir -Filter '*-inventory.json' -File | Sort-Object Name)
    $previous = $null
    $prevStamp = ''
    foreach ($file in $snapshots) {
        $current = ConvertTo-Hashtable (Read-JsonFile -Path $file.FullName)
        $stamp = $file.BaseName -replace '-inventory$', ''
        $link = "snapshots/$($file.BaseName).md"
        if ($null -ne $previous) {
            $diff = Compare-Inventory -Previous $previous -Current $current
            if ($diff) {
                $driftName = "$prevStamp--$stamp.md"
                Write-TextFile -Path (Join-Path $driftDir $driftName) -Content (@(
                    "# Drift — $($Environment['SubscriptionName'])",
                    '',
                    "From [$prevStamp](../snapshots/$prevStamp-inventory.md) to [$stamp](../$link).",
                    '',
                    $diff
                ) -join "`n")
                $notes[$link] = "[drift](drift/$driftName)"
            } else {
                $notes[$link] = 'no drift'
            }
        }
        $previous = $current
        $prevStamp = $stamp
    }
    return $notes
}

function Get-FindingKey {
    param($Result)
    return (@('Phase', 'Category', 'Check', 'Scope') | ForEach-Object { "$($Result[$_])".Trim().ToLowerInvariant() }) -join '|'
}

function Update-Findings {
    <#
    .SYNOPSIS
        Rebuilds the findings register by replaying every validation snapshot in time order.
        Returns snapshot link -> annotation.
    .DESCRIPTION
        A FAIL or WARN opens (or refreshes) a finding. A finding closes only when the same
        check on the same scope later reports PASS or INFO: a SKIP, or a check that did not
        run because its inputs were omitted, proves nothing and leaves it open.
    #>
    param($Environment)
    $envDir = Get-EnvironmentDir $Environment
    $findings = [ordered]@{}
    $notes = @{}
    $snapDir = Join-Path $envDir 'snapshots'
    $snapshots = @()
    if (Test-Path -LiteralPath $snapDir) {
        $snapshots = @(Get-ChildItem -LiteralPath $snapDir -Filter '*-validation-*.json' -File | Sort-Object Name)
    }
    foreach ($file in $snapshots) {
        $snapshot = ConvertTo-Hashtable (Read-JsonFile -Path $file.FullName)
        if ($null -eq $snapshot) { continue }
        $utc = "$($snapshot['GeneratedUtc'])"
        $opened = 0; $closed = 0
        foreach ($result in @($snapshot['Results'])) {
            if ($null -eq $result) { continue }
            $status = "$($result['Status'])"
            $key = Get-FindingKey $result
            $existing = Get-Prop $findings $key
            if ($status -in @('FAIL', 'WARN')) {
                if ($null -eq $existing -or $existing['State'] -eq 'Resolved') {
                    $findings[$key] = [ordered]@{
                        Phase = $result['Phase']; Category = $result['Category']; Check = $result['Check']
                        Scope = $result['Scope']; State = 'Open'; FirstSeen = $utc
                        Reopened = ($null -ne $existing)
                    }
                    $existing = $findings[$key]
                    $opened++
                }
                $existing['Status']         = $status
                $existing['Detail']         = $result['Detail']
                $existing['Recommendation'] = $result['Recommendation']
                $existing['LastSeen']       = $utc
                $existing['LastPackage']    = $snapshot['Package']
                $existing['ResolvedOn']     = ''
            } elseif ($status -in @('PASS', 'INFO') -and $null -ne $existing -and $existing['State'] -eq 'Open') {
                $existing['State'] = 'Resolved'
                $existing['ResolvedOn'] = $utc
                $closed++
            }
        }
        $notes["snapshots/$($file.BaseName).md"] = "$opened finding(s) opened, $closed resolved"
    }
    $Environment['Findings'] = $findings
    return $notes
}

function Update-DerivedKnowledge {
    param($Environment)
    $notes = @{}
    foreach ($table in @((Update-Drift $Environment), (Update-Findings $Environment))) {
        foreach ($k in $table.Keys) { $notes[$k] = $table[$k] }
    }
    foreach ($run in @($Environment['Runs'])) {
        $run['Note'] = if ($run['Link'] -and $notes.ContainsKey($run['Link'])) { $notes[$run['Link']] } else { '' }
    }
}

# endregion

# ---------------------------------------------
# region Page Rendering
# ---------------------------------------------

function Get-RunbookIndex {
    <#
    .SYNOPSIS
        Maps lower-cased validator check names to the runbooks that declare they resolve them
        (front matter `resolves-checks: ["Check A", "Check B"]`).
    #>
    $index = @{}
    $dir = Join-Path $BrainPath 'runbooks'
    if (-not (Test-Path -LiteralPath $dir)) { return $index }
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.md' -File)) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        $match = [regex]::Match($text, '(?m)^resolves-checks:\s*\[(.*?)\]')
        if (-not $match.Success) { continue }
        foreach ($name in ($match.Groups[1].Value -split ',')) {
            $check = $name.Trim().Trim('"', "'").ToLowerInvariant()
            if (-not $check) { continue }
            if (-not $index.ContainsKey($check)) { $index[$check] = @() }
            $index[$check] += $file.Name
        }
    }
    return $index
}

function Get-RunSummary {
    param($Run)
    $note = "$(Get-Prop $Run 'Note' '')"
    if ($note) { return "$($Run['Summary']) · $note" }
    return $Run['Summary']
}

function Get-Age {
    param([string]$Iso)
    try {
        $days = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)).TotalDays
        return "$days d"
    } catch { return '' }
}

function Write-EnvironmentPages {
    param($Environment, $RunbookIndex)
    $envDir = Get-EnvironmentDir $Environment
    $name = $Environment['SubscriptionName']
    $findings = @($Environment['Findings'].Values)
    $open = @($findings | Where-Object { $_['State'] -eq 'Open' } |
        Sort-Object @{ E = { if ($_['Status'] -eq 'FAIL') { 0 } else { 1 } } }, @{ E = { $_['FirstSeen'] } })
    $resolved = @($findings | Where-Object { $_['State'] -eq 'Resolved' } | Sort-Object { $_['ResolvedOn'] } -Descending | Select-Object -First 25)

    # findings.md -- fully generated
    $f = New-Object System.Collections.Generic.List[string]
    $f.Add("# Findings — $name")
    $f.Add('')
    $f.Add('Generated from validator runs. A finding closes only when the same check on the same scope passes in a later run.')
    $f.Add('')
    $f.Add("## Open ($($open.Count))")
    $f.Add('')
    if ($open.Count -eq 0) {
        $f.Add('_No open findings._')
    } else {
        $f.Add('| Status | Phase | Check | Scope | Open for | First seen | Last seen | Detail | Recommendation | Runbook |')
        $f.Add('|---|---|---|---|---|---|---|---|---|---|')
        foreach ($x in $open) {
            $books = @(Get-Prop $RunbookIndex $x['Check'].ToLowerInvariant() @())
            $bookLinks = if ($books.Count) { (@($books | ForEach-Object { "[$_](../../runbooks/$_)" }) -join ', ') } else { '—' }
            $flag = if ($x['Reopened']) { ' (reopened)' } else { '' }
            $f.Add("| $($x['Status'])$flag | $($x['Phase']) | $(ConvertTo-CellText $x['Check']) | $(ConvertTo-CellText $x['Scope']) | $(Get-Age $x['FirstSeen']) | $(Format-Utc $x['FirstSeen']) | $(Format-Utc $x['LastSeen']) | $(ConvertTo-CellText $x['Detail']) | $(ConvertTo-CellText $x['Recommendation']) | $bookLinks |")
        }
    }
    $f.Add('')
    $f.Add('## Recently resolved')
    $f.Add('')
    if ($resolved.Count -eq 0) {
        $f.Add('_None yet._')
    } else {
        $f.Add('| Phase | Check | Scope | First seen | Resolved |')
        $f.Add('|---|---|---|---|---|')
        foreach ($x in $resolved) {
            $f.Add("| $($x['Phase']) | $(ConvertTo-CellText $x['Check']) | $(ConvertTo-CellText $x['Scope']) | $(Format-Utc $x['FirstSeen']) | $(Format-Utc $x['ResolvedOn']) |")
        }
    }
    Write-TextFile -Path (Join-Path $envDir 'findings.md') -Content ($f -join "`n")

    # timeline.md -- fully generated
    $t = New-Object System.Collections.Generic.List[string]
    $t.Add("# Timeline — $name")
    $t.Add('')
    $t.Add('| When | Run | Summary | Package |')
    $t.Add('|---|---|---|---|')
    foreach ($run in (@($Environment['Runs']) | Sort-Object { $_['Utc'] } -Descending)) {
        $label = if ($run['Link']) { "[$($run['Kind'])]($($run['Link']))" } else { $run['Kind'] }
        $t.Add("| $(Format-Utc $run['Utc']) | $label | $(Get-RunSummary $run) | ``$($run['Package'])`` |")
    }
    Write-TextFile -Path (Join-Path $envDir 'timeline.md') -Content ($t -join "`n")

    # README.md -- generated block plus a human section seeded once from the template
    $g = New-Object System.Collections.Generic.List[string]
    $g.Add("Subscription ID ``$($Environment['SubscriptionId'])`` · [Timeline](timeline.md) · [Findings](findings.md) · [Drift](drift/)")
    $g.Add('')
    $g.Add('### Latest evidence')
    $g.Add('')
    $g.Add('| Evidence | Result | When | Age |')
    $g.Add('|---|---|---|---|')
    $lastInv = @(@($Environment['Runs']) | Where-Object { $_['Kind'] -eq 'inventory' -and $_['Link'] } | Sort-Object { $_['Utc'] }) | Select-Object -Last 1
    if ($lastInv) { $g.Add("| [Inventory]($($lastInv['Link'])) | $(Get-RunSummary $lastInv) | $(Format-Utc $lastInv['Utc']) | $(Get-Age $lastInv['Utc']) |") }
    else { $g.Add('| Inventory | _never collected_ | | |') }
    $verdicts = Get-Prop $Environment 'Verdicts'
    if ($verdicts -and $verdicts.Count) {
        foreach ($mode in $verdicts.Keys) {
            $v = $verdicts[$mode]
            $g.Add("| [Validation: $mode]($($v['Link'])) | **$($v['Verdict'])** — $($v['Counts']) | $(Format-Utc $v['Utc']) | $(Get-Age $v['Utc']) |")
        }
    } else { $g.Add('| Validation | _never validated_ | | |') }
    $g.Add('')
    $openFail = @($open | Where-Object { $_['Status'] -eq 'FAIL' }).Count
    $openWarn = @($open | Where-Object { $_['Status'] -eq 'WARN' }).Count
    $g.Add("**Open findings:** $openFail FAIL · $openWarn WARN — see [findings](findings.md).")

    $header = "# $name"
    $footer = ''
    $notesTemplate = Join-Path $BrainPath (Join-Path '_templates' 'environment-notes.md')
    if (Test-Path -LiteralPath $notesTemplate) { $footer = [System.IO.File]::ReadAllText($notesTemplate) }
    Set-GeneratedBlock -Path (Join-Path $envDir 'README.md') -Block ($g -join "`n") -Header $header -Footer $footer
}

function Write-HomePage {
    param($State)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Environments')
    $lines.Add('')
    $lines.Add('| Environment | Last inventory | Latest verdicts | Open FAIL | Open WARN |')
    $lines.Add('|---|---|---|---|---|')
    $allRuns = @()
    foreach ($environment in (@($State['Environments'].Values) | Sort-Object { $_['SubscriptionName'] })) {
        $open = @($environment['Findings'].Values | Where-Object { $_['State'] -eq 'Open' })
        $verdicts = Get-Prop $environment 'Verdicts'
        $verdictText = if ($verdicts -and $verdicts.Count) { (@($verdicts.Keys | ForEach-Object { "$_ **$($verdicts[$_]['Verdict'])**" }) -join '<br>') } else { '—' }
        $inv = if ($environment['LastInventory']) { "$(Format-Utc $environment['LastInventory']) ($(Get-Age $environment['LastInventory']))" } else { '—' }
        $lines.Add("| [$($environment['SubscriptionName'])](environments/$($environment['Folder'])/README.md) | $inv | $verdictText | $(@($open | Where-Object { $_['Status'] -eq 'FAIL' }).Count) | $(@($open | Where-Object { $_['Status'] -eq 'WARN' }).Count) |")
        foreach ($run in @($environment['Runs'])) {
            $allRuns += [pscustomobject]@{ Utc = $run['Utc']; Env = $environment; Run = $run }
        }
    }
    $lines.Add('')
    $lines.Add('## Recent activity')
    $lines.Add('')
    $recent = @($allRuns | Sort-Object Utc -Descending | Select-Object -First 15)
    if ($recent.Count -eq 0) { $lines.Add('_Nothing ingested yet._') }
    foreach ($item in $recent) {
        $link = if ($item.Run['Link']) { "environments/$($item.Env['Folder'])/$($item.Run['Link'])" } else { "environments/$($item.Env['Folder'])/timeline.md" }
        $summary = (Get-RunSummary $item.Run) -replace '\]\((drift|snapshots)/', "](environments/$($item.Env['Folder'])/`$1/"
        $lines.Add("- $(Format-Utc $item.Utc) · [$($item.Env['SubscriptionName']) $($item.Run['Kind'])]($link) — $summary")
    }
    $lines.Add('')
    $lastIngest = @(@($State['Ingested']) | ForEach-Object { "$($_['IngestedUtc'])" } | Sort-Object) | Select-Object -Last 1
    $lines.Add("_Last ingest $(Format-Utc $lastIngest) · $(@($State['Ingested']).Count) package(s) in total._")
    Set-GeneratedBlock -Path (Join-Path $BrainPath 'README.md') -Block ($lines -join "`n") -Header '# AVD Second Brain'
}

# endregion

# ---------------------------------------------
# region Main
# ---------------------------------------------

try {
    if ($Init) { Initialize-Vault }

    if (-not (Test-Path -LiteralPath $BrainPath)) {
        throw "Vault '$BrainPath' does not exist. Run with -Init first."
    }
    $BrainPath = (Resolve-Path -LiteralPath $BrainPath).Path

    if ($PackagePath.Count -eq 0) {
        if (-not $Init) { Write-Log 'Nothing to do: pass -PackagePath to ingest evidence, or -Init to scaffold the vault.' -Level WARN }
        return
    }

    $state = Read-State
    $packages = Resolve-Packages -Paths $PackagePath
    $ingestedNames = @(@($state['Ingested']) | ForEach-Object { $_['Package'] })
    $processed = 0
    $newPackages = @()

    foreach ($package in $packages) {
        if (($ingestedNames -contains $package.Name) -and -not $Force) {
            Write-Log "Skipping $($package.Name) -- already ingested (use -Force to re-ingest)."
            continue
        }
        if ($Force -and ($ingestedNames -contains $package.Name)) {
            # Drop the earlier run rows so a re-ingest does not duplicate the timeline
            foreach ($environment in $state['Environments'].Values) {
                $environment['Runs'] = @(@($environment['Runs']) | Where-Object { $_['Package'] -ne $package.Name })
            }
            $state['Ingested'] = @(@($state['Ingested']) | Where-Object { $_['Package'] -ne $package.Name })
        }
        Write-Log "Ingesting $($package.Kind) package $($package.Name) ($(Format-Utc $package.GeneratedUtc))"
        if ($package.Kind -eq 'inventory') { Import-InventoryPackage -State $state -Package $package }
        else { Import-ValidationPackage -State $state -Package $package }
        $state['Ingested'] = @(@($state['Ingested']) + [ordered]@{
            Package = $package.Name; Kind = $package.Kind; GeneratedUtc = $package.GeneratedUtc
            IngestedUtc = (Get-Date).ToUniversalTime().ToString('o')
        })
        $processed++
        $newPackages += $package.Name
    }

    $runbooks = Get-RunbookIndex
    foreach ($environment in $state['Environments'].Values) {
        Update-DerivedKnowledge -Environment $environment
        Write-EnvironmentPages -Environment $environment -RunbookIndex $runbooks
    }
    Write-HomePage -State $state
    Save-State -State $state

    Write-Log "Done. $processed package(s) ingested into '$BrainPath'."
    foreach ($environment in $state['Environments'].Values) {
        foreach ($run in (@($environment['Runs']) | Where-Object { $newPackages -contains $_['Package'] } | Sort-Object { $_['Utc'] })) {
            Write-Log "  $(Format-Utc $run['Utc']) · $($environment['SubscriptionName']) · $($run['Kind']): $((Get-RunSummary $run) -replace '\*\*', '')"
        }
    }
    if ($processed -gt 0) { Write-Log "Review the changes and commit them: git -C `"$BrainPath`" add -A; git -C `"$BrainPath`" commit -m `"Ingest evidence`"" }
} finally {
    foreach ($dir in $script:TempDirs) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

# endregion
