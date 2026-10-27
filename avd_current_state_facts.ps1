<#
.SYNOPSIS
    AVD Current State Facts -- turns collector and validator evidence packages into one
    redacted facts snapshot (avd-current-state-facts/v1) for avd-second-brain and avd-swarm.

.DESCRIPTION
    The collector and validator packages hold tenant data: subscription and object IDs,
    resource names, user principal names, IP addresses, tags. They feed the customer's
    private estate vault (avd-second-brain contract C1). This script makes the form of the
    same evidence that the brain's agents read, that a model prompt may hold, and that a
    playbook proposal to avd-swarm may cite (contract C11):

      - Allowlisted fields only. Every value is a count, a boolean, a public Azure value
        (region, VM size, marketplace image, built-in role name, check name) or a keyed
        pseudonym. Names, IDs, IPs, tags, user names and free text are never copied.
      - Keyed pseudonyms. Subscriptions, host pools and storage accounts become
        `sub-3fa2c1d0`, `hp-...`, `st-...`: HMAC-SHA256 of the resource ID with the estate's
        key. The same key gives the same pseudonyms on every run, so the brain sees trends.
        Nobody can reverse one without the key and the resource IDs.
      - A final scan refuses to write the snapshot if anything that looks like a GUID, an
        email address, a UNC path or a non-documentation IPv4 address got through, and
        redacts any validator check name that contains a collected resource name.

    The key is the estate's secret. Keep it with the vault (or, with the landing zone's
    operations brain, in its Key Vault), never in a repository and never in the snapshot.
    Losing or rotating it breaks the link to earlier snapshots, by design.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License, see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    OFFLINE AND LOCAL
    ------------------------------------------------------------------
    Reads package folders and ZIPs from disk and writes one JSON file. No Azure call, no
    network. Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER PackagePath
    Collector or validator package folders, their ZIPs, or folders that contain them. The
    latest collector run per subscription and the latest validator run per subscription
    and mode are used.

.PARAMETER KeyPath
    File holding the estate's pseudonymization key (base64, 32 bytes).

.PARAMETER NewKey
    Create the key file when it doesn't exist. Without it a missing key is an error, so a
    typo can't silently start a new set of pseudonyms.

.PARAMETER OutputPath
    Folder for avd-current-state-facts-<timestamp>.json. Defaults to the current folder.

.PARAMETER Assess
    Also run the avd-assess method pinned in assess/ over the snapshot and write
    avd-assessment-<timestamp>.json (contract C21) beside it: one outcome per check (pass, warn,
    gap, unknown), the pillar scores with their coverage, and each design decision's readiness.
    It holds only pseudonyms, fact IDs and outcomes. Nothing is fetched; the method's copy must
    match its hash in assess/PINS.json.

.PARAMETER IntakePath
    With -Assess, the estate's intake.json (contract C19, written by the assessment portal's
    Discover stage). It must be for the same estate as the snapshot. Without it, the decisions
    that need intake answers report needs-intake.

.EXAMPLE
    .\avd_current_state_facts.ps1 -PackagePath .\avd-current-state-20261015T091500, .\avd-validation-20261016T100000.zip -KeyPath ..\avd-brain\.brain\facts.key -NewKey

.EXAMPLE
    .\avd_current_state_facts.ps1 -PackagePath D:\Assessments -KeyPath ..\avd-brain\.brain\facts.key -OutputPath ..\avd-brain\facts

.EXAMPLE
    .\avd_current_state_facts.ps1 -PackagePath $out -KeyPath (Join-Path $out 'estate.key') -OutputPath $out -Assess -IntakePath (Join-Path $out 'intake.json')
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$PackagePath,
    [Parameter(Mandatory = $true)][string]$KeyPath,
    [switch]$NewKey,
    [string]$OutputPath = (Get-Location).Path,
    [switch]$Assess,
    [string]$IntakePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FactsVersion = '1.2.0'
$script:TempDirs = New-Object System.Collections.Generic.List[string]
$script:RedactedValues = 0

# Values from these fields may name customer things. They feed the leak check, never the output.
$script:NameFields = @('Name', 'ResourceGroupName', 'VaultName', 'StorageAccountName', 'HostPool', 'VMName',
    'VNetName', 'NSGName', 'NSG', 'RouteTable', 'Subnet', 'VNet', 'TargetResource', 'DisplayName', 'SignInName',
    'AssignedUser', 'FriendlyName', 'Description', 'SubscriptionName', 'AssignmentName', 'AvailabilitySet')

# Built-in roles worth counting for AVD. Any other role, custom roles included, counts as 'other'.
$script:PublicRoles = @('Owner', 'Contributor', 'Reader', 'User Access Administrator',
    'Role Based Access Control Administrator', 'Virtual Machine Contributor', 'Virtual Machine User Login',
    'Virtual Machine Administrator Login', 'Network Contributor', 'Storage Account Contributor',
    'Storage File Data SMB Share Reader', 'Storage File Data SMB Share Contributor',
    'Storage File Data SMB Share Elevated Contributor', 'Storage File Data Privileged Contributor',
    'Storage File Data Privileged Reader', 'Log Analytics Reader', 'Log Analytics Contributor',
    'Monitoring Reader', 'Monitoring Contributor', 'Key Vault Administrator', 'Key Vault Secrets User')

# region Helpers

function Write-FactsLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Get-Prop {
    # StrictMode-safe property read on PSCustomObjects and hashtables.
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

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        Write-FactsLog "Could not parse ${Path}: $($_.Exception.Message)" -Level WARN
        return $null
    }
}

function Read-Dataset {
    # A single-row dataset is serialized as a bare object; an empty one may be missing.
    param([string]$Directory, [string]$Name)
    $data = Read-JsonFile -Path (Join-Path $Directory "$Name.json")
    if ($null -eq $data) { return }
    foreach ($row in @($data)) { $row }
}

function ConvertTo-Utc {
    # PowerShell 7 turns ISO strings into DateTime on ConvertFrom-Json; 5.1 doesn't.
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try {
        if ($Value -is [datetime]) { $dt = $Value }
        else { $dt = [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        return $dt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    } catch { return $null }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

function Get-Pseudonym {
    # <kind>-<8 hex>: HMAC-SHA256 over "<kind>|<lowercased resource ID>" with the estate key.
    param([string]$Kind, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 (, $script:Key)
    try {
        $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Kind|$($Value.Trim().ToLowerInvariant())"))
    } finally { $hmac.Dispose() }
    return "$Kind-" + (-join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') }))
}

function Get-PublicValue {
    # A value from a fixed vocabulary or a public Azure name, else 'other'.
    param($Value, [string]$Pattern = '^[A-Za-z0-9][A-Za-z0-9 ._/+()-]{0,63}$')
    $text = "$Value".Trim()
    if ($text -eq '') { return 'unknown' }
    if ($text -cmatch $Pattern) { return $text }
    $script:RedactedValues++
    return 'other'
}

function Get-CountMap {
    param([object[]]$Values, [string]$Pattern = '^[A-Za-z0-9][A-Za-z0-9 ._/+()-]{0,63}$')
    $map = @{}
    foreach ($v in $Values) {
        $k = Get-PublicValue -Value $v -Pattern $Pattern
        if ($map.ContainsKey($k)) { $map[$k]++ } else { $map[$k] = 1 }
    }
    $ordered = [ordered]@{}
    foreach ($k in ($map.Keys | Sort-Object)) { $ordered[$k] = $map[$k] }
    return $ordered
}

function Test-True {
    param($Value)
    return ("$Value" -eq 'True' -or "$Value" -eq '1' -or $Value -eq $true)
}

function Get-OptionalBool {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    return (Test-True $Value)
}

function Get-PathValue {
    # StrictMode-safe dotted path read (properties.securityProfile.securityType). ARM omits empty
    # properties, so a missing segment returns the default.
    param([object]$InputObject, [string]$Path, $Default = $null)
    $current = $InputObject
    foreach ($segment in ($Path -split '\.')) {
        $current = Get-Prop $current $segment
        if ($null -eq $current) { return $Default }
    }
    return $current
}

function Get-RedirectionFact {
    # Device redirection from a host pool's custom RDP properties: 'on' or 'off' per kind when the
    # property is set, 'default' when it isn't. The property's value (a drive or device list) is
    # never copied.
    param([string]$CustomRdpProperty)
    $set = @{}
    foreach ($pair in ($CustomRdpProperty -split ';')) {
        $parts = $pair -split ':', 3
        if ($parts.Count -lt 3) { continue }
        $set[$parts[0].Trim().ToLowerInvariant()] = $parts[2].Trim()
    }
    $kinds = [ordered]@{
        drives = 'drivestoredirect'; clipboard = 'redirectclipboard'; printers = 'redirectprinters'; usb = 'usbdevicestoredirect'
        comPorts = 'redirectcomports'; smartCards = 'redirectsmartcards'; camera = 'camerastoredirect'; webAuthn = 'redirectwebauthn'
    }
    $result = [ordered]@{}
    foreach ($k in $kinds.Keys) {
        $name = $kinds[$k]
        if (-not $set.ContainsKey($name)) { $result[$k] = 'default'; continue }
        $value = $set[$name]
        if ($name -like 'redirect*') { $result[$k] = $(if ($value -eq '0') { 'off' } else { 'on' }) }
        else { $result[$k] = $(if ($value -eq '') { 'off' } else { 'on' }) }
    }
    return $result
}

function Get-SmbChannelEncryptionFact {
    # avd-assess obs:smb-channel-aes128-gcm-needed: AES-256-GCM alone denies Entra Kerberos sessions.
    param([string]$Value)
    $algs = @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($algs.Count -eq 0) { return 'default' }
    if (@($algs | Where-Object { $_ -like '*CCM' }).Count -gt 0) { return 'includes-ccm' }
    if ($algs -contains 'AES-128-GCM') { return 'gcm' }
    return 'aes256-gcm-only'
}

function Test-TrustedLaunch {
    # Trusted launch (or a confidential VM) with Secure Boot and vTPM on, from a VM's Resource Graph row.
    param([object]$Vm)
    $type = "$(Get-PathValue $Vm 'properties.securityProfile.securityType' '')"
    return ($type -in @('TrustedLaunch', 'ConfidentialVM') -and
        (Test-True (Get-PathValue $Vm 'properties.securityProfile.uefiSettings.secureBootEnabled')) -and
        (Test-True (Get-PathValue $Vm 'properties.securityProfile.uefiSettings.vTpmEnabled')))
}

# endregion

# region Packages

function Resolve-Package {
    # Same discovery as avd-second-brain's vault: folders, ZIPs, or a parent folder one level down.
    param([string[]]$Paths)
    $byName = [ordered]@{}
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { Write-FactsLog "Package path not found: $path" -Level WARN; continue }
        $item = Get-Item -LiteralPath $path
        $manifests = @()
        $zips = @()
        if (-not $item.PSIsContainer) {
            if ($item.Extension -eq '.zip') { $zips = @($item) }
            else { Write-FactsLog "Not a package folder or ZIP: $path" -Level WARN; continue }
        } elseif (Test-Path -LiteralPath (Join-Path $item.FullName 'manifest.json')) {
            $manifests = @(Join-Path $item.FullName 'manifest.json')
        } else {
            $manifests = @(Get-ChildItem -LiteralPath $item.FullName -Directory |
                ForEach-Object { Join-Path $_.FullName 'manifest.json' } |
                Where-Object { Test-Path -LiteralPath $_ })
            $zips = @(Get-ChildItem -LiteralPath $item.FullName -Filter '*.zip' -File)
        }
        foreach ($zip in $zips) {
            $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('avd-facts-' + [guid]::NewGuid().ToString('N'))
            $script:TempDirs.Add($temp)
            Expand-Archive -LiteralPath $zip.FullName -DestinationPath $temp -Force
            $manifests += @(Get-ChildItem -LiteralPath $temp -Filter 'manifest.json' -File -Recurse -Depth 1 |
                ForEach-Object { $_.FullName })
        }
        foreach ($manifestPath in $manifests) {
            $manifest = Read-JsonFile -Path $manifestPath
            if ($null -eq $manifest) { continue }
            $kind = $null
            if ($null -ne (Get-Prop $manifest 'Verdict')) { $kind = 'validator' }
            elseif ($null -ne (Get-Prop $manifest 'SubscriptionDetails')) { $kind = 'collector' }
            if (-not $kind) { Write-FactsLog "Unrecognized manifest: $manifestPath" -Level WARN; continue }
            $name = "$(Get-Prop $manifest 'PackageName' (Split-Path -Leaf (Split-Path -Parent $manifestPath)))"
            if ($byName.Contains($name)) { continue }
            $utc = ConvertTo-Utc (Get-Prop $manifest 'GeneratedUtc')
            if (-not $utc) { Write-FactsLog "Manifest has no GeneratedUtc, skipped: $manifestPath" -Level WARN; continue }
            $byName[$name] = [pscustomobject]@{
                Kind           = $kind
                Name           = $name
                Directory      = Split-Path -Parent $manifestPath
                Manifest       = $manifest
                GeneratedUtc   = $utc
                ManifestSha256 = Get-Sha256Hex ([System.IO.File]::ReadAllBytes($manifestPath))
            }
        }
    }
    return , @($byName.Values | Sort-Object GeneratedUtc, Name)
}

function Add-KnownName {
    # Remembers a customer string so the leak check can look for it in the output.
    param($Value)
    $text = "$Value".Trim()
    if ($text.Length -ge 4) { [void]$script:KnownNames.Add($text.ToLowerInvariant()) }
}

function Add-KnownNamesFrom {
    param([object[]]$Rows)
    foreach ($row in $Rows) {
        if ($null -eq $row) { continue }
        foreach ($field in $script:NameFields) { Add-KnownName (Get-Prop $row $field) }
        $tags = Get-Prop $row 'Tags'
        if ($tags) {
            try {
                $parsed = "$tags" | ConvertFrom-Json
                if ($parsed) { foreach ($p in $parsed.PSObject.Properties) { Add-KnownName $p.Name; Add-KnownName $p.Value } }
            } catch { Add-KnownName $tags }
        }
    }
}

# endregion

# region Facts

function Get-SubscriptionFact {
    param([string]$Directory, [string]$SubscriptionId, [string]$CollectedUtc, [object[]]$ManagedDevices = $null)

    $ds = @{}
    foreach ($n in @('resource-groups', 'arm-resources', 'virtual-networks', 'subnets', 'nsgs', 'nsg-rules',
            'route-tables', 'public-ips', 'virtual-machines', 'vm-extensions', 'storage-accounts', 'key-vaults',
            'log-analytics-workspaces', 'recovery-services-vaults', 'private-endpoints', 'policy-assignments',
            'role-assignments', 'avd-host-pools', 'avd-workspaces', 'avd-application-groups', 'avd-session-hosts')) {
        $ds[$n] = @(Read-Dataset -Directory $Directory -Name $n)
        Add-KnownNamesFrom $ds[$n]
    }

    # The collector's rebuild/ rows hold what the datasets don't: VM security profiles, file service
    # settings, the storage identity source and Defender plans. An older package has none of them,
    # and those facts are left out (a check then reads them as unknown).
    $rebuild = Join-Path $Directory 'rebuild'
    $rbById = @{}
    foreach ($type in @('microsoft.compute-virtualmachines', 'microsoft.storage-storageaccounts')) {
        foreach ($row in @(Read-JsonFile -Path (Join-Path $rebuild "resources/$type.json"))) {
            $rid = "$(Get-Prop $row 'id' '')".ToLowerInvariant()
            if ($rid) { $rbById[$rid] = $row }
        }
    }
    $extRows = @(Read-JsonFile -Path (Join-Path $rebuild 'resources/microsoft.compute-virtualmachines-extensions.json'))
    $epFile = Join-Path $rebuild 'resources/microsoft.powerplatform-enterprisepolicies.json'
    $epRows = if (Test-Path -LiteralPath $epFile) { @(Read-JsonFile -Path $epFile) } else { $null }
    $fileServices = @{}
    foreach ($read in @(Read-JsonFile -Path (Join-Path $rebuild 'rest/file-services.json'))) {
        if ("$(Get-Prop $read 'status' '')" -ne 'ok') { continue }
        $item = @(Get-Prop $read 'items' @()) | Select-Object -First 1
        if ($null -ne $item) { $fileServices["$(Get-Prop $read 'parentId' '')".ToLowerInvariant()] = $item }
    }
    $pricingFile = Join-Path $rebuild 'resources/microsoft.security-pricings.json'
    $defenderPlans = $null
    if (Test-Path -LiteralPath $pricingFile) {
        $defenderPlans = [ordered]@{}
        foreach ($row in @(Read-JsonFile -Path $pricingFile | Sort-Object { "$(Get-Prop $_ 'name' '')" })) {
            $plan = "$(Get-Prop $row 'name' '')"
            $tier = "$(Get-PathValue $row 'properties.pricingTier' '')"
            if ($plan -cmatch '^[A-Za-z][A-Za-z0-9]{1,40}$' -and $tier -in @('Free', 'Standard')) { $defenderPlans[$plan] = $tier }
        }
    }

    $vmById = @{}
    foreach ($vm in $ds['virtual-machines']) {
        $id = "$(Get-Prop $vm 'Id' '')".ToLowerInvariant()
        if ($id) { $vmById[$id] = $vm }
    }
    $collected = $null
    if ($CollectedUtc) { $collected = [datetime]::Parse($CollectedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }

    # Host pools, keyed by name for the session hosts and by ID for the application groups
    $hostPools = @()
    $hpByName = @{}
    $hpById = @{}
    foreach ($hp in $ds['avd-host-pools']) {
        $id = "$(Get-Prop $hp 'Id' '')"
        $rdp = @()
        foreach ($pair in ("$(Get-Prop $hp 'CustomRdpProperty' '')" -split ';')) {
            $propName = ($pair -split ':')[0].Trim().ToLowerInvariant()
            if ($propName -match '^[a-z][a-z0-9 ]{1,40}$') { $rdp += $propName }
        }
        $entry = [ordered]@{
            id                    = Get-Pseudonym 'hp' $id
            region                = Get-PublicValue (Get-Prop $hp 'Location') '^[a-z0-9]{2,40}$'
            type                  = Get-PublicValue (Get-Prop $hp 'HostPoolType') '^[A-Za-z]{2,40}$'
            loadBalancer          = Get-PublicValue (Get-Prop $hp 'LoadBalancerType') '^[A-Za-z]{2,40}$'
            preferredAppGroupType = Get-PublicValue (Get-Prop $hp 'PreferredAppGroupType') '^[A-Za-z]{2,40}$'
            maxSessionLimit       = $null
            validationEnvironment = Get-OptionalBool (Get-Prop $hp 'ValidationEnvironment')
            startVmOnConnect      = Get-OptionalBool (Get-Prop $hp 'StartVMOnConnect')
            rdpProperties         = @($rdp | Sort-Object -Unique)
            redirection           = Get-RedirectionFact "$(Get-Prop $hp 'CustomRdpProperty' '')"
            appGroups             = [ordered]@{}
            sessionHosts          = $null
            vmSizes               = [ordered]@{}
            images                = @()
        }
        $limit = Get-Prop $hp 'MaxSessionLimit'
        if ($null -ne $limit -and "$limit" -match '^\d+$') { $entry.maxSessionLimit = [int]"$limit" }
        $rawRdp = "$(Get-Prop $hp 'CustomRdpProperty' '')"
        if ($null -ne (Get-Prop $hp 'CustomRdpProperty')) {
            $entry.entraSso = if ($rawRdp -match '(?i)(^|;)enablerdsaadauth:i:1($|;)') { 'enabled' } else { 'disabled' }
        }
        if ($ds['role-assignments'].Count -gt 0) {
            $entry.directUserAssignments = [int]@($ds['role-assignments'] | Where-Object {
                    "$(Get-Prop $_ 'RoleDefinitionName' '')" -eq 'Desktop Virtualization User' -and "$(Get-Prop $_ 'ObjectType' '')" -eq 'User'
                }).Count
        }
        $hostPools += $entry
        $hpByName["$(Get-Prop $hp 'Name' '')".ToLowerInvariant()] = $entry
        if ($id) { $hpById[$id.ToLowerInvariant()] = $entry }
    }

    $agTypes = @{}
    foreach ($ag in $ds['avd-application-groups']) {
        $hpId = "$(Get-Prop $ag 'HostPoolArmPath' '')".ToLowerInvariant()
        if (-not $hpById.ContainsKey($hpId)) { continue }
        if (-not $agTypes.ContainsKey($hpId)) { $agTypes[$hpId] = @() }
        $agTypes[$hpId] += Get-Prop $ag 'ApplicationGroupType'
    }
    foreach ($k in $agTypes.Keys) { $hpById[$k].appGroups = Get-CountMap $agTypes[$k] '^[A-Za-z]{2,40}$' }

    $shByPool = @{}
    foreach ($sh in $ds['avd-session-hosts']) {
        $pool = "$(Get-Prop $sh 'HostPool' '')".ToLowerInvariant()
        if (-not $shByPool.ContainsKey($pool)) { $shByPool[$pool] = @() }
        $shByPool[$pool] += $sh
    }
    foreach ($pool in $hpByName.Keys) {
        $entry = $hpByName[$pool]
        $hosts = @()
        if ($shByPool.ContainsKey($pool)) { $hosts = @($shByPool[$pool]) }
        $stale = 0
        $sessions = 0
        foreach ($h in $hosts) {
            $s = Get-Prop $h 'Sessions'
            if ("$s" -match '^\d+$') { $sessions += [int]"$s" }
            $beat = ConvertTo-Utc (Get-Prop $h 'LastHeartBeat')
            if ($collected -and $beat) {
                $age = $collected - [datetime]::Parse($beat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                if ($age.TotalMinutes -gt 30) { $stale++ }
            }
        }
        $vms = @($hosts | ForEach-Object {
                $vmId = "$(Get-Prop $_ 'ResourceId' '')".ToLowerInvariant()
                if ($vmById.ContainsKey($vmId)) { $vmById[$vmId] }
            })
        $entry.sessionHosts = [ordered]@{
            total            = $hosts.Count
            status           = Get-CountMap @($hosts | ForEach-Object { Get-Prop $_ 'Status' }) '^[A-Za-z]{2,40}$'
            allowNewSession  = @($hosts | Where-Object { Test-True (Get-Prop $_ 'AllowNewSession') }).Count
            assigned         = @($hosts | Where-Object { "$(Get-Prop $_ 'AssignedUser' '')" -ne '' }).Count
            sessions         = $sessions
            staleHeartbeat   = $stale
            agentVersions    = Get-CountMap @($hosts | ForEach-Object { Get-Prop $_ 'AgentVersion' }) '^[0-9][0-9.]{0,30}$'
            sxsStackVersions = Get-CountMap @($hosts | ForEach-Object { Get-Prop $_ 'SxSStackVersion' }) '^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$'
            osVersions       = Get-CountMap @($hosts | ForEach-Object { Get-Prop $_ 'OSVersion' }) '^[0-9][0-9.]{0,30}$'
            updateStates     = Get-CountMap @($hosts | ForEach-Object { Get-Prop $_ 'UpdateState' }) '^[A-Za-z]{2,40}$'
        }
        $rbVms = @($hosts | ForEach-Object {
                $vmId = "$(Get-Prop $_ 'ResourceId' '')".ToLowerInvariant()
                if ($rbById.ContainsKey($vmId)) { $rbById[$vmId] }
            })
        if ($rbVms.Count -gt 0) {
            $trusted = @($rbVms | Where-Object { Test-TrustedLaunch $_ }).Count
            $entry.sessionHosts.trustedLaunch = $trusted
            $entry.sessionHosts.notTrustedLaunch = $rbVms.Count - $trusted
        }
        if ($extRows.Count -gt 0 -or $ds['vm-extensions'].Count -gt 0) {
            $hostVmNames = @{}
            foreach ($h in $hosts) {
                $vmId = "$(Get-Prop $h 'ResourceId' '')"
                if ($vmId) { $hostVmNames[(($vmId -split '/')[-1]).ToLowerInvariant()] = $true }
            }
            $entraJoined = 0; $domainJoined = 0; $intuneEnroll = 0
            if ($extRows.Count -gt 0) {
                foreach ($ext in $extRows) {
                    $extId = "$(Get-Prop $ext 'id' '')"
                    $parts = $extId -split '/'
                    $vmName = if ($parts.Count -gt 8) { $parts[8].ToLowerInvariant() } else { '' }
                    if (-not $hostVmNames.ContainsKey($vmName)) { continue }
                    $extType = "$(Get-PathValue $ext 'properties.type' '')"
                    if ($extType -eq 'AADLoginForWindows') {
                        $entraJoined++
                        if ("$(Get-PathValue $ext 'properties.settings.mdmId' '')" -ne '') { $intuneEnroll++ }
                    } elseif ($extType -eq 'JsonADDomainExtension') {
                        $domainJoined++
                    }
                }
            } else {
                foreach ($ext in $ds['vm-extensions']) {
                    $vmName = "$(Get-Prop $ext 'VMName' '')".ToLowerInvariant()
                    if (-not $hostVmNames.ContainsKey($vmName)) { continue }
                    $extType = "$(Get-Prop $ext 'ExtensionType' '')"
                    if ($extType -eq 'AADLoginForWindows') { $entraJoined++ }
                    elseif ($extType -eq 'JsonADDomainExtension') { $domainJoined++ }
                }
            }
            $entry.sessionHosts.entraJoined = [int]$entraJoined
            $entry.sessionHosts.domainJoined = [int]$domainJoined
            $entry.sessionHosts.intuneEnrollRequested = [int]$intuneEnroll
        }
        if ($null -ne $ManagedDevices) {
            $hostShortNames = @{}
            foreach ($h in $hosts) {
                $leaf = ("$(Get-Prop $h 'Name' '')" -split '/')[-1]
                $short = ($leaf -split '\.')[0].ToLowerInvariant()
                if ($short) { $hostShortNames[$short] = $true }
            }
            $matched = @($ManagedDevices | Where-Object { $hostShortNames.ContainsKey("$(Get-Prop $_ 'deviceName' '')".ToLowerInvariant()) })
            $entry.sessionHosts.intuneManaged = [int]$matched.Count
            $entry.sessionHosts.intuneCompliant = [int]@($matched | Where-Object { "$(Get-Prop $_ 'complianceState' '')" -eq 'compliant' }).Count
            $entry.sessionHosts.intuneNoncompliant = [int]@($matched | Where-Object { "$(Get-Prop $_ 'complianceState' '')" -eq 'noncompliant' }).Count
            $entry.sessionHosts.intuneSyncStale = [int]@($matched | Where-Object {
                    $sync = ConvertTo-Utc (Get-Prop $_ 'lastSyncDateTime')
                    $collected -and $sync -and (($collected - [datetime]::Parse($sync, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()).TotalDays -gt 7)
                }).Count
            $entry.sessionHosts.intuneConfigErrors = [int]@($matched | Where-Object { [int](Get-Prop $_ 'configurationErrorCount' 0) -gt 0 }).Count
            $entry.sessionHosts.intuneBaselineApplied = [int]@($matched | Where-Object { Test-True (Get-Prop $_ 'baselineApplied') }).Count
            $entry.intuneOrphans = [int]@($ManagedDevices | Where-Object {
                    $dn = "$(Get-Prop $_ 'deviceName' '')".ToLowerInvariant()
                    $dn -and -not $hostShortNames.ContainsKey($dn) -and [bool](Get-Prop $_ 'isAvdSessionHost' $false)
                }).Count
        }
        $entry.vmSizes = Get-CountMap @($vms | ForEach-Object { Get-Prop $_ 'VMSize' }) '^Standard_[A-Za-z0-9_]{1,40}$'
        $images = @{}
        foreach ($vm in $vms) {
            $publisher = "$(Get-Prop $vm 'ImagePublisher' '')"
            if ($publisher -eq '') { $key = 'custom||' }
            else {
                $key = (Get-PublicValue $publisher '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') + '|' +
                    (Get-PublicValue (Get-Prop $vm 'ImageOffer') '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') + '|' +
                    (Get-PublicValue (Get-Prop $vm 'ImageSku') '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
            }
            if ($images.ContainsKey($key)) { $images[$key]++ } else { $images[$key] = 1 }
        }
        $entry.images = @($images.Keys | Sort-Object | ForEach-Object {
                $p = $_ -split '\|'
                $img = [ordered]@{ publisher = $p[0] }
                if ($p[0] -ne 'custom') { $img.offer = $p[1]; $img.sku = $p[2] }
                $img.hosts = $images[$_]
                $img
            })
    }

    # Storage accounts, with whether a private endpoint targets them
    $peTargets = @{}
    foreach ($pe in $ds['private-endpoints']) {
        foreach ($t in ("$(Get-Prop $pe 'TargetResource' '')" -split ',\s*')) { if ($t) { $peTargets[$t.ToLowerInvariant()] = $true } }
    }
    $storage = @($ds['storage-accounts'] | ForEach-Object {
            $name = "$(Get-Prop $_ 'StorageAccountName' '')".ToLowerInvariant()
            $stId = "$(Get-Prop $_ 'Id' '')".ToLowerInvariant()
            $st = [ordered]@{
                id                   = Get-Pseudonym 'st' (Get-Prop $_ 'Id' '')
                region               = Get-PublicValue (Get-Prop $_ 'Location') '^[a-z0-9]{2,40}$'
                kind                 = Get-PublicValue (Get-Prop $_ 'Kind') '^[A-Za-z0-9]{2,40}$'
                sku                  = Get-PublicValue (Get-Prop $_ 'SkuName') '^[A-Za-z0-9_]{2,40}$'
                httpsOnly            = Get-OptionalBool (Get-Prop $_ 'EnableHttpsOnly')
                minimumTls           = Get-PublicValue (Get-Prop $_ 'MinimumTlsVersion') '^TLS[0-9_]{1,6}$'
                blobPublicAccess     = Get-OptionalBool (Get-Prop $_ 'AllowBlobPublicAccess')
                networkDefaultAction = Get-PublicValue (Get-Prop $_ 'NetworkRuleDefaultAction') '^[A-Za-z]{2,20}$'
                largeFileShares      = Get-PublicValue (Get-Prop $_ 'LargeFileShares') '^[A-Za-z]{2,20}$'
                privateEndpoint      = $peTargets.ContainsKey($name)
            }
            if ($fileServices.ContainsKey($stId)) {
                $st.smbChannelEncryption = Get-SmbChannelEncryptionFact "$(Get-PathValue $fileServices[$stId] 'properties.protocolSettings.smb.channelEncryption' '')"
            }
            if ($rbById.ContainsKey($stId)) {
                $source = "$(Get-PathValue $rbById[$stId] 'properties.azureFilesIdentityBasedAuthentication.directoryServiceOptions' 'None')"
                $st.filesIdentity = $(if ($source -in @('AADKERB', 'AD', 'AADDS', 'None')) { $source } else { 'other' })
            }
            $st
        } | Where-Object { $_.id })

    $routes = @($ds['route-tables'] | ForEach-Object {
            foreach ($r in ("$(Get-Prop $_ 'Routes' '')" -split ';\s*')) {
                if ($r -match ':0\.0\.0\.0/0->(\w+)$') { $Matches[1] }
            }
        })
    $pes = @($ds['private-endpoints'] | ForEach-Object { ("$(Get-Prop $_ 'GroupIds' '')" -split '[;,]\s*') | Where-Object { $_ } })
    $roles = @($ds['role-assignments'] | ForEach-Object {
            $r = "$(Get-Prop $_ 'RoleDefinitionName' '')"
            if ($script:PublicRoles -contains $r -or $r -match '^Desktop Virtualization [A-Za-z ]{2,40}$') { $r } else { 'other' }
        })

    $regions = @(@($ds['resource-groups']) + @($ds['arm-resources']) | ForEach-Object { "$(Get-Prop $_ 'Location' '')".ToLowerInvariant() } |
            Where-Object { $_ -match '^[a-z0-9]{2,40}$' } | Sort-Object -Unique)

    $counts = [ordered]@{}
    foreach ($n in ($ds.Keys | Sort-Object)) {
        # resource-groups -> resourceGroups
        $key = [regex]::Replace($n, '-([a-z])', { param($m) $m.Groups[1].Value.ToUpperInvariant() })
        $counts[$key] = $ds[$n].Count
    }

    $result = [ordered]@{
        id              = Get-Pseudonym 'sub' $SubscriptionId
        collectedUtc    = $CollectedUtc
        regions         = $regions
        counts          = $counts
        hostPools       = @($hostPools)
        virtualMachines = [ordered]@{
            total       = $ds['virtual-machines'].Count
            sizes       = Get-CountMap @($ds['virtual-machines'] | ForEach-Object { Get-Prop $_ 'VMSize' }) '^Standard_[A-Za-z0-9_]{1,40}$'
            powerStates = Get-CountMap @($ds['virtual-machines'] | ForEach-Object { Get-Prop $_ 'PowerState' }) '^[A-Za-z][A-Za-z ]{1,40}$'
            osTypes     = Get-CountMap @($ds['virtual-machines'] | ForEach-Object { Get-Prop $_ 'OsType' }) '^[A-Za-z]{2,20}$'
        }
        storageAccounts = $storage
        network         = [ordered]@{
            virtualNetworks              = $ds['virtual-networks'].Count
            customDnsVirtualNetworks     = @($ds['virtual-networks'] | Where-Object { "$(Get-Prop $_ 'DnsServers' '')" -ne '' }).Count
            ddosProtectedVirtualNetworks = @($ds['virtual-networks'] | Where-Object { Test-True (Get-Prop $_ 'EnableDdosProtection') }).Count
            subnets                      = $ds['subnets'].Count
            subnetsWithNsg               = @($ds['subnets'] | Where-Object { "$(Get-Prop $_ 'NSG' '')" -ne '' }).Count
            subnetsWithRouteTable        = @($ds['subnets'] | Where-Object { "$(Get-Prop $_ 'RouteTable' '')" -ne '' }).Count
            subnetDelegations            = Get-CountMap @($ds['subnets'] | ForEach-Object { "$(Get-Prop $_ 'Delegations' '')" -split ',\s*' | Where-Object { $_ } }) '^[A-Za-z][A-Za-z0-9./]{2,63}$'
            defaultRoutes                = Get-CountMap $routes '^[A-Za-z]{2,40}$'
            publicIps                    = $ds['public-ips'].Count
            privateEndpoints             = Get-CountMap $pes '^[A-Za-z][A-Za-z0-9_]{1,40}$'
        }
        keyVaults       = [ordered]@{
            total           = $ds['key-vaults'].Count
            softDelete      = @($ds['key-vaults'] | Where-Object { Test-True (Get-Prop $_ 'EnableSoftDelete') }).Count
            purgeProtection = @($ds['key-vaults'] | Where-Object { Test-True (Get-Prop $_ 'EnablePurgeProtection') }).Count
        }
        logAnalytics    = [ordered]@{
            total         = $ds['log-analytics-workspaces'].Count
            retentionDays = Get-CountMap @($ds['log-analytics-workspaces'] | ForEach-Object { Get-Prop $_ 'RetentionDays' }) '^[0-9]{1,5}$'
        }
        policy          = [ordered]@{
            assignments  = $ds['policy-assignments'].Count
            doNotEnforce = @($ds['policy-assignments'] | Where-Object { "$(Get-Prop $_ 'EnforcementMode' '')" -eq 'DoNotEnforce' }).Count
        }
        roleAssignments = [ordered]@{
            roles       = Get-CountMap $roles '^[A-Za-z][A-Za-z ]{1,63}$'
            objectTypes = Get-CountMap @($ds['role-assignments'] | ForEach-Object { Get-Prop $_ 'ObjectType' }) '^[A-Za-z]{2,40}$'
        }
    }
    if ($null -ne $defenderPlans) { $result.defenderPlans = $defenderPlans }
    $ppDelegated = @($ds['subnets'] | Where-Object { "$(Get-Prop $_ 'Delegations' '')" -match '(?i)Microsoft\.PowerPlatform/enterprisePolicies' }).Count
    if ($null -ne $epRows -or $ppDelegated -gt 0) {
        $result.powerPlatform = [ordered]@{
            enterprisePoliciesCount = $(if ($null -ne $epRows) { [int]$epRows.Count } else { 0 })
            vnetInjectedSubnets     = [int]$ppDelegated
        }
    }
    return $result
}

function Get-EntraFact {
    param([string]$PackageDir, [int]$GroupRoleAssignments = 0)
    $dir = Join-Path $PackageDir 'entra'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $groups = @(Read-Dataset -Directory $dir -Name 'groups')
    $caPolicies = @(Read-Dataset -Directory $dir -Name 'conditionalAccessPolicies')
    $sps = @(Read-Dataset -Directory $dir -Name 'servicePrincipals')
    $skus = @(Read-Dataset -Directory $dir -Name 'subscribedSkus')
    foreach ($row in @($groups + $caPolicies + $sps)) {
        Add-KnownName (Get-Prop $row 'displayName')
        Add-KnownName (Get-Prop $row 'id')
    }
    $dynamicGroups = @($groups | Where-Object { @(Get-Prop $_ 'groupTypes' @()) -contains 'DynamicMembership' }).Count
    $avdAppIds = @('9cdead84-a844-4324-93f2-b2e6bb768d07', 'a4a365df-50f1-4397-bc59-1a1564b8bb9c', '270efc09-cd0d-444b-a71f-39af4910ec45', '00cb2876-7ebd-4aa4-9cc9-d28bd4d359a9')
    $avdCa = @($caPolicies | Where-Object {
            $incApps = @(Get-PathValue $_ 'conditions.applications.includeApplications' @())
            $incApps -contains 'All' -or @($incApps | Where-Object { $avdAppIds -contains "$_" }).Count -gt 0
        })
    $caStates = Get-CountMap @($avdCa | ForEach-Object { Get-Prop $_ 'state' }) '^[A-Za-z]{2,40}$'
    $mfaEnforced = @($avdCa | Where-Object { "$(Get-Prop $_ 'state' '')" -eq 'enabled' -and (@(Get-PathValue $_ 'grantControls.builtInControls' @()) -contains 'mfa' -or $null -ne (Get-PathValue $_ 'grantControls.authenticationStrength')) }).Count
    $mfaReportOnly = @($avdCa | Where-Object { "$(Get-Prop $_ 'state' '')" -eq 'enabledForReportingButNotEnforced' -and (@(Get-PathValue $_ 'grantControls.builtInControls' @()) -contains 'mfa' -or $null -ne (Get-PathValue $_ 'grantControls.authenticationStrength')) }).Count
    $compEnforced = @($avdCa | Where-Object { "$(Get-Prop $_ 'state' '')" -eq 'enabled' -and @(Get-PathValue $_ 'grantControls.builtInControls' @()) -contains 'compliantDevice' }).Count
    $compReportOnly = @($avdCa | Where-Object { "$(Get-Prop $_ 'state' '')" -eq 'enabledForReportingButNotEnforced' -and @(Get-PathValue $_ 'grantControls.builtInControls' @()) -contains 'compliantDevice' }).Count
    $sifConfigured = @($avdCa | Where-Object { Test-True (Get-PathValue $_ 'sessionControls.signInFrequency.isEnabled') }).Count -gt 0
    $breakGlassExcluded = $avdCa.Count -gt 0 -and @($avdCa | Where-Object {
            @(Get-PathValue $_ 'conditions.users.excludeUsers' @()).Count -eq 0 -and @(Get-PathValue $_ 'conditions.users.excludeGroups' @()).Count -eq 0
        }).Count -eq 0
    $kerberosReady = @($sps | Where-Object { Test-True (Get-Prop $_ 'kerberosReady') -or "$(Get-Prop $_ 'servicePrincipalType' '')" -eq 'StorageAccountKerberos' }).Count
    $eligibleSeats = 0
    foreach ($sku in $skus) {
        $enabled = [int](Get-PathValue $sku 'prepaidUnits.enabled' 0)
        $consumed = [int](Get-Prop $sku 'consumedUnits' 0)
        if ($enabled -gt $consumed) { $eligibleSeats += ($enabled - $consumed) }
    }
    return [ordered]@{
        userGroupsAssigned             = [int]$GroupRoleAssignments
        dynamicHostGroups              = [int]$dynamicGroups
        caPoliciesTargetingAvd         = $caStates
        caAvdRequiresMfa               = $(if ($mfaEnforced -gt 0) { 'enforced' } elseif ($mfaReportOnly -gt 0) { 'report-only' } else { 'none' })
        caAvdRequiresCompliantDevice   = $(if ($compEnforced -gt 0) { 'enforced' } elseif ($compReportOnly -gt 0) { 'report-only' } else { 'none' })
        caAvdSignInFrequencyConfigured = [bool]$sifConfigured
        caAvdBreakGlassExcluded        = [bool]$breakGlassExcluded
        kerberosStoragePrincipalsReady = [int]$kerberosReady
        skuAvdEligibleAvailable        = [int]$eligibleSeats
    }
}

function Get-IntuneFact {
    param([string]$PackageDir)
    $dir = Join-Path $PackageDir 'intune'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $settings = @(Read-Dataset -Directory $dir -Name 'settings')
    $mdm = @(Read-Dataset -Directory $dir -Name 'mdmPolicies')
    $profiles = @(Read-Dataset -Directory $dir -Name 'configurationPolicies')
    foreach ($row in @($mdm + $profiles)) {
        Add-KnownName (Get-Prop $row 'name')
        Add-KnownName (Get-Prop $row 'displayName')
        Add-KnownName (Get-Prop $row 'id')
    }
    $firstSetting = $settings | Select-Object -First 1
    $secureByDefault = Test-True (Get-Prop $firstSetting 'secureByDefault' $true)
    $firstMdm = $mdm | Select-Object -First 1
    $mdmScopeRaw = "$(Get-Prop $firstMdm 'appliesTo' 'none')".ToLowerInvariant()
    $mdmScope = if ($mdmScopeRaw -in @('all', 'some', 'none')) { $mdmScopeRaw } else { 'none' }
    $multiSession = @($profiles | Where-Object { "$(Get-Prop $_ 'technologies' '')" -match 'windowsEnterpriseMultiSession|mdm' })
    $fslogix = @($profiles | Where-Object { Test-True (Get-Prop $_ 'fslogixConfigured') -or "$(Get-Prop $_ 'category' '')" -eq 'fslogix' }).Count -gt 0
    $shortpath = @($profiles | Where-Object { Test-True (Get-Prop $_ 'rdpShortpathConfigured') -or "$(Get-Prop $_ 'category' '')" -eq 'rdpShortpath' }).Count -gt 0
    $timeLimits = @($profiles | Where-Object { Test-True (Get-Prop $_ 'sessionTimeLimitsConfigured') -or "$(Get-Prop $_ 'category' '')" -eq 'sessionTimeLimits' }).Count -gt 0
    $updateRing = @($profiles | Where-Object { Test-True (Get-Prop $_ 'multiSessionUpdateRingAssigned') -or "$(Get-Prop $_ 'category' '')" -eq 'updateRing' }).Count -gt 0
    return [ordered]@{
        noPolicyMeansNoncompliant      = [bool]$secureByDefault
        mdmAutoEnrollmentScope         = $mdmScope
        multiSessionCatalogProfiles    = [int]$multiSession.Count
        fslogixProfileConfigured       = [bool]$fslogix
        rdpShortpathConfigured         = [bool]$shortpath
        sessionTimeLimitsConfigured    = [bool]$timeLimits
        multiSessionUpdateRingAssigned = [bool]$updateRing
    }
}

function Get-M365Fact {
    param([string]$PackageDir)
    $dir = Join-Path $PackageDir 'm365'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $profiles = @(Read-Dataset -Directory $dir -Name 'configurationPolicies')
    $teams = @(Read-Dataset -Directory $dir -Name 'teamsVdiPolicies')
    foreach ($row in @($profiles + $teams)) {
        Add-KnownName (Get-Prop $row 'name')
        Add-KnownName (Get-Prop $row 'displayName')
        Add-KnownName (Get-Prop $row 'id')
    }
    $silent = @($profiles | Where-Object { Test-True (Get-Prop $_ 'oneDriveSilentConfigEnabled') }).Count -gt 0
    $kfm = if (@($profiles | Where-Object { "$(Get-Prop $_ 'oneDriveKfmState' '')" -eq 'enforced' }).Count -gt 0) { 'enforced' }
        elseif (@($profiles | Where-Object { "$(Get-Prop $_ 'oneDriveKfmState' '')" -eq 'prompt' }).Count -gt 0) { 'prompt' } else { 'none' }
    $fod = @($profiles | Where-Object { Test-True (Get-Prop $_ 'oneDriveFilesOnDemandEnabled') }).Count -gt 0
    $sca = @($profiles | Where-Object { Test-True (Get-Prop $_ 'm365AppsSharedComputerActivation') }).Count -gt 0
    $outlook = @($profiles | Where-Object { Test-True (Get-Prop $_ 'outlookCachedModeConfigured') }).Count -gt 0
    $teamsOpt = if (@($profiles | Where-Object { "$(Get-Prop $_ 'teamsMediaOptimizationState' '')" -eq 'enabled' }).Count -gt 0 -or
        @($teams | Where-Object { "$(Get-Prop $_ 'VdiMediaOptimization' '')" -eq 'Enabled' }).Count -gt 0) { 'enabled' } else { 'disabled' }
    $mmr = @($profiles | Where-Object { Test-True (Get-Prop $_ 'mmrConfigured') }).Count -gt 0
    return [ordered]@{
        oneDriveSilentConfigEnabled      = [bool]$silent
        oneDriveKfmState                 = $kfm
        oneDriveFilesOnDemandEnabled     = [bool]$fod
        m365AppsSharedComputerActivation = [bool]$sca
        outlookCachedModeConfigured      = [bool]$outlook
        teamsMediaOptimizationState      = $teamsOpt
        mmrConfigured                    = [bool]$mmr
    }
}

function Get-PowerPlatformFact {
    param([string]$PackageDir)
    $dir = Join-Path $PackageDir 'power-platform'
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $envs = @(Read-Dataset -Directory $dir -Name 'environments')
    $dlp = @(Read-Dataset -Directory $dir -Name 'dlpPolicies')
    $solutions = @(Read-Dataset -Directory $dir -Name 'solutions')
    $workflows = @(Read-Dataset -Directory $dir -Name 'workflows')
    foreach ($row in @($envs + $dlp + $solutions + $workflows)) {
        Add-KnownName (Get-Prop $row 'name')
        Add-KnownName (Get-Prop $row 'displayName')
        Add-KnownName (Get-Prop $row 'id')
    }
    $dedicated = @($envs | Where-Object { "$(Get-PathValue $_ 'properties.environmentSku' '')" -ne 'Default' -and "$(Get-Prop $_ 'type' '')" -ne 'Default' }).Count
    $defaultClass = 'General'
    if ($dlp.Count -gt 0) {
        $rawClass = "$(Get-Prop ($dlp | Select-Object -First 1) 'defaultConnectorsClassification' 'General')"
        if ($rawClass -in @('Blocked', 'Confidential', 'General')) { $defaultClass = $rawClass }
    }
    $flowStates = Get-CountMap @($workflows | ForEach-Object { Get-Prop $_ 'state' }) '^[A-Za-z]{2,40}$'
    return [ordered]@{
        dedicatedEnvironments         = [int]$dedicated
        dlpPoliciesCoveringAvdEnv     = [int]$dlp.Count
        dlpDefaultGroupClassification = $defaultClass
        avdDay2SolutionsDeployed      = [int]$solutions.Count
        avdDay2FlowsActive            = $flowStates
    }
}

function Get-ValidationFact {
    param($Package, [hashtable]$Targets)
    $m = $Package.Manifest
    $subId = "$(Get-Prop $m 'SubscriptionId' '')"
    Add-KnownName (Get-Prop $m 'SubscriptionName')
    Add-KnownName (Get-Prop $m 'Identity')
    $inputs = Get-Prop $m 'Inputs'
    if ($inputs) {
        foreach ($p in $inputs.PSObject.Properties) {
            if ($p.Name -notin @('Location', 'MetadataLocation', 'SessionHostCount', 'SessionHostVmSize', 'MaxHeartbeatAgeMinutes', 'IpBufferPercent', 'IncludeNetworkProbe')) { Add-KnownName $p.Value }
        }
    }
    $rows = @(Read-Dataset -Directory $Package.Directory -Name 'validation-results')
    foreach ($r in $rows) { Add-KnownName (Get-Prop $r 'Scope') }

    $subPseudonym = Get-Pseudonym 'sub' $subId
    $checks = @($rows | ForEach-Object {
            $check = [ordered]@{
                phase    = Get-PublicValue (Get-Prop $_ 'Phase') '^[A-Za-z]{2,40}$'
                category = Get-PublicValue (Get-Prop $_ 'Category') '^[A-Za-z]{2,40}$'
                check    = Get-PublicValue (Get-Prop $_ 'Check') "^[A-Za-z0-9][A-Za-z0-9 ._:/()+,'-]{0,99}$"
                status   = Get-PublicValue (Get-Prop $_ 'Status') '^(PASS|WARN|FAIL|INFO|SKIP)$'
            }
            $scope = "$(Get-Prop $_ 'Scope' '')".Trim().ToLowerInvariant()
            if ($scope -and $Targets.ContainsKey($scope)) { $check.target = $Targets[$scope] }
            elseif ($scope -and ($scope -eq $subId.ToLowerInvariant() -or $scope -eq "$(Get-Prop $m 'SubscriptionName' '')".ToLowerInvariant())) { $check.target = $subPseudonym }
            $check
        })

    $counts = Get-Prop $m 'Counts'
    $facts = [ordered]@{
        subscription = $subPseudonym
        mode         = Get-PublicValue (Get-Prop $m 'Mode') '^[A-Za-z]{2,30}$'
        generatedUtc = $Package.GeneratedUtc
        verdict      = Get-PublicValue (Get-Prop $m 'Verdict') '^[A-Z]{2,10}$'
        counts       = [ordered]@{}
        inputs       = [ordered]@{}
        checks       = $checks
    }
    foreach ($k in @('Fail', 'Warn', 'Pass', 'Info', 'Skip')) {
        $v = Get-Prop $counts $k
        if ("$v" -match '^\d+$') { $facts.counts[$k.ToLowerInvariant()] = [int]"$v" }
    }
    if ($inputs) {
        $loc = "$(Get-Prop $inputs 'Location' '')".ToLowerInvariant()
        if ($loc -match '^[a-z0-9]{2,40}$') { $facts.inputs.region = $loc }
        $count = Get-Prop $inputs 'SessionHostCount'
        if ("$count" -match '^\d+$' -and [int]"$count" -gt 0) { $facts.inputs.sessionHostCount = [int]"$count" }
        $size = "$(Get-Prop $inputs 'SessionHostVmSize' '')"
        if ($size -match '^Standard_[A-Za-z0-9_]{1,40}$') { $facts.inputs.sessionHostVmSize = $size }
    }
    return $facts
}

function Find-Leak {
    # Walks the snapshot. Returns what looks like tenant data; version fields are exempt from the IP check.
    param($Node, [string]$Path = '$')
    if ($null -eq $Node) { return }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) {
            foreach ($hit in (Find-Leak -Node "$k" -Path "$Path[key]")) { $hit }
            foreach ($hit in (Find-Leak -Node $Node[$k] -Path "$Path.$k")) { $hit }
        }
        return
    }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) { foreach ($hit in (Find-Leak -Node $item -Path "$Path[$i]")) { $hit }; $i++ }
        return
    }
    $text = "$Node"
    if ($text -match '(?i)(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])') { "guid at $Path" }
    if ($text -match '[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}') { "email at $Path" }
    if ($text -match '\\\\[A-Za-z0-9]') { "unc-path at $Path" }
    if ($Path -notmatch '(?i)version') {
        foreach ($ip in [regex]::Matches($text, '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')) {
            if (@($ip.Value -split '\.' | Where-Object { [int]$_ -gt 255 }).Count) { continue }
            if ($ip.Value -notmatch '^(0\.0\.0\.0|127\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)') { "ip-address at $Path" }
        }
    }
}

# endregion

function Get-PointerValue {
    # Every value a JSON pointer names, with * for every array item. Missing steps give nothing.
    param([object]$Node, [string]$Pointer)
    $current = @(, $Node)
    foreach ($seg in ($Pointer.Trim('/') -split '/')) {
        $next = New-Object System.Collections.Generic.List[object]
        foreach ($n in $current) {
            if ($null -eq $n) { continue }
            if ($seg -eq '*') { foreach ($item in @($n)) { $next.Add($item) } }
            else { $v = Get-Prop $n $seg; if ($null -ne $v) { $next.Add($v) } }
        }
        $current = $next.ToArray()
    }
    return , $current
}

function Get-ManifestCoverage {
    # Which design decisions of a target-state manifest (avd-second-brain C14) this snapshot can
    # support, from the fact register (C15): a decision counts when the register says Azure-side
    # facts can decide it and at least one built C11 fact for it has data in this snapshot.
    param([object]$Snapshot, [object]$Register)
    $supported = @(); $needs = @()
    foreach ($d in @($Register.decisions)) {
        $has = $false
        if (@($d.decidableFrom) -contains 'azure') {
            foreach ($f in @($Register.facts | Where-Object { $_.contract -eq 'C11' -and $_.status -eq 'built' -and @($_.evidences) -contains $d.id })) {
                $values = @(Get-PointerValue -Node $Snapshot -Pointer $f.path | Where-Object { $null -ne $_ -and -not ($_ -is [array] -and $_.Count -eq 0) })
                if ($values.Count) { $has = $true; break }
            }
        }
        if ($has) { $supported += $d.label } else { $needs += $d.label }
    }
    [pscustomobject]@{ Total = @($Register.decisions).Count; Supported = $supported; Needs = $needs }
}

function Read-AssessInput {
    # Everything -Assess needs, read and checked before any package is: every pinned copy in assess/ and
    # contracts/ against its hash (the run uses the method, the register and the schemas), and the intake
    # against C19. A mistake here stops the run before it writes anything.
    param([string]$IntakeFile)
    Import-Module (Join-Path $PSScriptRoot 'lib/AvdAssess.psm1') -Force
    $pins = $null
    foreach ($dir in @('assess', 'contracts')) {
        $p = Get-Content -LiteralPath (Join-Path $PSScriptRoot "$dir/PINS.json") -Raw | ConvertFrom-Json
        if ("$($p.commit)" -notmatch '^[0-9a-f]{40}$') { throw "$dir/PINS.json has no full commit." }
        foreach ($f in $p.files.PSObject.Properties) {
            $sha = Get-Sha256Hex ([System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot "$dir/$($f.Name)")))
            if ($sha -ne "$($f.Value)") { throw "$dir/$($f.Name) does not match its hash in $dir/PINS.json. Re-copy it from avd-assess at the pinned commit." }
        }
        if ($dir -eq 'assess') { $pins = $p }
    }
    $methodFile = Join-Path $PSScriptRoot 'assess/method.json'
    $result = [ordered]@{
        Commit       = "$($pins.commit)"
        MethodSha256 = "$($pins.files.'method.json')"
        Method       = Get-Content -LiteralPath $methodFile -Raw | ConvertFrom-Json
        Register     = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'contracts/fact-register.json') -Raw | ConvertFrom-Json
        Intake       = $null
        IntakeSha256 = $null
    }
    if ($IntakeFile) {
        $intakeBytes = [System.IO.File]::ReadAllBytes($IntakeFile)
        $intakeText = [System.Text.Encoding]::UTF8.GetString($intakeBytes).TrimStart([char]0xFEFF)
        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            $errs = $null
            if (-not (Test-Json -Json $intakeText -SchemaFile (Join-Path $PSScriptRoot 'contracts/intake.schema.json') -ErrorVariable errs -ErrorAction SilentlyContinue)) { throw "The intake isn't valid avd-intake/v1: $errs" }
        } else {
            Write-FactsLog 'Windows PowerShell has no Test-Json: the intake is checked for its schema and estate only.' -Level WARN
        }
        $result.Intake = $intakeText | ConvertFrom-Json
        if ("$(Get-Prop $result.Intake 'schema' '')" -ne 'avd-intake/v1') { throw "The intake isn't avd-intake/v1." }
        $result.IntakeSha256 = Get-Sha256Hex $intakeBytes
    }
    return $result
}

function Write-Assessment {
    # Runs the pinned method over the snapshot just written (lib/AvdAssess.psm1) and writes the C21
    # report; refuses one the leak scan flags.
    param($AssessInput, [string]$SnapshotJson, [object]$Snapshot, [string]$Destination)
    $report = Get-AvdAssessment -Method $AssessInput.Method -MethodCommit $AssessInput.Commit -MethodSha256 $AssessInput.MethodSha256 -Register $AssessInput.Register `
        -Snapshot $Snapshot -SnapshotSha256 (Get-Sha256Hex ((New-Object System.Text.UTF8Encoding $false).GetBytes($SnapshotJson))) `
        -Intake $AssessInput.Intake -IntakeSha256 $AssessInput.IntakeSha256 -ProducerName 'avd_current_state_facts.ps1' -ProducerVersion $script:FactsVersion
    $leaks = @(Find-Leak -Node $report)
    if ($leaks.Count) { throw "Refusing to write the assessment: it looks like it holds tenant data ($(($leaks | Select-Object -First 5) -join '; '))." }
    [System.IO.File]::WriteAllText($Destination, ($report | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
    Write-FactsLog "Assessment: $Destination (avd-assess method v$($AssessInput.Method.version) at $($AssessInput.Commit.Substring(0, 7)))"
    return $report
}

# region Main

try {
    if ($IntakePath -and -not $Assess) { throw '-IntakePath goes with -Assess.' }
    $assessInput = $null
    if ($Assess) {
        $intakeFile = $null
        if ($IntakePath) {
            # Resolved against PowerShell's location, which .NET's file calls don't follow.
            if (-not (Test-Path -LiteralPath $IntakePath -PathType Leaf)) { throw "Intake file not found: $IntakePath" }
            $intakeFile = (Resolve-Path -LiteralPath $IntakePath).ProviderPath
        }
        $assessInput = Read-AssessInput -IntakeFile $intakeFile
    }
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        if (-not $NewKey) { throw "Key file not found: $KeyPath. Pass -NewKey to create one for a new estate." }
        $bytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $keyDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($KeyPath))
        if (-not (Test-Path -LiteralPath $keyDir)) { New-Item -ItemType Directory -Path $keyDir -Force | Out-Null }
        [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($KeyPath), [Convert]::ToBase64String($bytes))
        Write-FactsLog "Created a new estate key at $KeyPath. Keep it with the vault; never commit it." -Level WARN
    }
    $script:Key = [Convert]::FromBase64String(([System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($KeyPath))).Trim())
    if ($script:Key.Length -lt 32) { throw "The key in $KeyPath is shorter than 32 bytes." }

    $packages = Resolve-Package -Paths $PackagePath
    if ($packages.Count -eq 0) { throw 'No collector or validator package found.' }

    $tenants = @($packages | ForEach-Object { "$(Get-Prop $_.Manifest 'TenantId' '')".ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($tenants.Count -gt 1) { throw "The packages come from $($tenants.Count) tenants. Make one snapshot per tenant." }
    if ($tenants.Count -eq 0) { throw 'No package records a TenantId, so the estate has no pseudonym. Re-run the collector or validator.' }

    $script:KnownNames = New-Object 'System.Collections.Generic.HashSet[string]'
    Add-KnownName $tenants[0]

    # Latest collector run per subscription
    $latestSub = @{}
    $latestCollectorPkg = $null
    foreach ($p in @($packages | Where-Object Kind -eq 'collector')) {
        $latestCollectorPkg = $p
        Add-KnownName (Get-Prop $p.Manifest 'Identity')
        foreach ($sub in @(Get-Prop $p.Manifest 'SubscriptionDetails' @())) {
            Add-KnownName (Get-Prop $sub 'SubscriptionName')
            if ("$(Get-Prop $sub 'Status' '')" -ne 'Collected') { continue }
            $id = "$(Get-Prop $sub 'SubscriptionId' '')".ToLowerInvariant()
            if ($id) { $latestSub[$id] = [pscustomobject]@{ Package = $p; Subscription = $sub } }
        }
    }

    $managedDevices = $null
    if ($null -ne $latestCollectorPkg) {
        $mdFile = Join-Path $latestCollectorPkg.Directory 'intune/managedDevices.json'
        if (Test-Path -LiteralPath $mdFile) {
            $managedDevices = @(Read-JsonFile -Path $mdFile)
            foreach ($md in $managedDevices) {
                Add-KnownName (Get-Prop $md 'deviceName')
                Add-KnownName (Get-Prop $md 'id')
            }
        }
    }

    $subscriptions = @()
    $targetsBySub = @{}
    $groupRoleAssignments = 0
    foreach ($id in ($latestSub.Keys | Sort-Object)) {
        $p = $latestSub[$id].Package
        $subName = "$(Get-Prop $latestSub[$id].Subscription 'SubscriptionName' '')"
        # Same folder naming as the collector's Sanitize-FolderName
        $folder = Join-Path $p.Directory ($subName -replace '[^\w\-\.\s]', '_' -replace '\s+', '_')
        if (-not (Test-Path -LiteralPath $folder)) { Write-FactsLog "A subscription folder is missing from $($p.Name); skipped." -Level WARN; continue }
        $facts = Get-SubscriptionFact -Directory $folder -SubscriptionId $id -CollectedUtc $p.GeneratedUtc -ManagedDevices $managedDevices
        foreach ($ra in @(Read-Dataset -Directory $folder -Name 'role-assignments')) {
            if ("$(Get-Prop $ra 'RoleDefinitionName' '')" -eq 'Desktop Virtualization User' -and "$(Get-Prop $ra 'ObjectType' '')" -eq 'Group') { $groupRoleAssignments++ }
        }

        $targets = @{}
        foreach ($hp in @(Read-Dataset -Directory $folder -Name 'avd-host-pools')) { $targets["$(Get-Prop $hp 'Name' '')".ToLowerInvariant()] = Get-Pseudonym 'hp' (Get-Prop $hp 'Id' '') }
        foreach ($st in @(Read-Dataset -Directory $folder -Name 'storage-accounts')) { $targets["$(Get-Prop $st 'StorageAccountName' '')".ToLowerInvariant()] = Get-Pseudonym 'st' (Get-Prop $st 'Id' '') }
        $targetsBySub[$id] = $targets
        $subscriptions += $facts
    }

    # Latest validator run per subscription and mode
    $latestVal = @{}
    foreach ($p in @($packages | Where-Object Kind -eq 'validator')) {
        $latestVal["$(Get-Prop $p.Manifest 'SubscriptionId' '')|$(Get-Prop $p.Manifest 'Mode' '')".ToLowerInvariant()] = $p
    }
    $validations = @()
    foreach ($k in ($latestVal.Keys | Sort-Object)) {
        $subId = ($k -split '\|')[0]
        $targets = @{}
        if ($targetsBySub.ContainsKey($subId)) { $targets = $targetsBySub[$subId] }
        $validations += Get-ValidationFact -Package $latestVal[$k] -Targets $targets
    }

    # Check names are code literals with few exceptions; one that carries a collected name is redacted.
    foreach ($v in $validations) {
        foreach ($c in $v.checks) {
            $lower = $c.check.ToLowerInvariant()
            foreach ($name in $script:KnownNames) {
                if ($lower.Contains($name)) { $c.check = 'redacted'; $script:RedactedValues++; break }
            }
        }
    }

    $usedNames = @{}
    if ($null -ne $latestCollectorPkg) { $usedNames[$latestCollectorPkg.Name] = $true }
    foreach ($v in $latestSub.Values) { $usedNames[$v.Package.Name] = $true }
    foreach ($v in $latestVal.Values) { $usedNames[$v.Name] = $true }
    $sources = @($packages | Where-Object { $usedNames.ContainsKey($_.Name) } | ForEach-Object {
            [ordered]@{ kind = $_.Kind; generatedUtc = $_.GeneratedUtc; manifestSha256 = $_.ManifestSha256 }
        })

    $snapshot = [ordered]@{
        schema       = 'avd-current-state-facts/v1'
        estate       = Get-Pseudonym 'est' $tenants[0]
        generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    if ($null -ne $latestCollectorPkg -and $null -ne (Get-Prop $latestCollectorPkg.Manifest 'PlanesCollected')) {
        $rawPlanes = Get-Prop $latestCollectorPkg.Manifest 'PlanesCollected'
        $pc = [ordered]@{}
        $validStatuses = @('collected', 'partial', 'skipped', 'unconsented')
        $validReasons = @('not-selected', 'insufficient-scope', 'no-license', 'teams-ps-unavailable', 'bap-unavailable', 'not-applicable-intake')
        foreach ($pn in @('azure', 'entra', 'intune', 'm365', 'power-platform')) {
            $pObj = Get-Prop $rawPlanes $pn
            $st = "$(Get-Prop $pObj 'status' 'skipped')"
            if ($st -notin $validStatuses) { $st = 'skipped' }
            $entry = [ordered]@{ status = $st }
            $rsn = "$(Get-Prop $pObj 'reason' '')"
            if ($rsn -and $rsn -in $validReasons) { $entry.reason = $rsn }
            $pc[$pn] = $entry
        }
        $snapshot.planesCollected = $pc
    }
    $snapshot.producer = [ordered]@{ name = 'avd_current_state_facts.ps1'; version = $script:FactsVersion }
    $snapshot.sources = $sources
    $snapshot.subscriptions = $subscriptions
    if ($null -ne $latestCollectorPkg) {
        $entraFact = Get-EntraFact -PackageDir $latestCollectorPkg.Directory -GroupRoleAssignments $groupRoleAssignments
        if ($null -ne $entraFact) { $snapshot.entra = $entraFact }
        $intuneFact = Get-IntuneFact -PackageDir $latestCollectorPkg.Directory
        if ($null -ne $intuneFact) { $snapshot.intune = $intuneFact }
        $m365Fact = Get-M365Fact -PackageDir $latestCollectorPkg.Directory
        if ($null -ne $m365Fact) { $snapshot.m365 = $m365Fact }
        $ppFact = Get-PowerPlatformFact -PackageDir $latestCollectorPkg.Directory
        if ($null -ne $ppFact) { $snapshot.powerPlatform = $ppFact }
    }
    $snapshot.validations = $validations
    $snapshot.redactedValues = $script:RedactedValues

    if ($assessInput -and $assessInput.Intake -and "$(Get-Prop $assessInput.Intake 'estate' '')" -cne $snapshot.estate) {
        throw "The intake is for another estate than these packages ($($snapshot.estate)). Use the intake.json the Discover stage wrote for this estate."
    }

    $leaks = @(Find-Leak -Node $snapshot)
    if ($leaks.Count) {
        throw "Refusing to write the snapshot: it looks like it holds tenant data ($(($leaks | Select-Object -First 5) -join '; ')). Report this with the check or dataset name, never the value."
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss")
    $outFile = Join-Path (Resolve-Path -LiteralPath $OutputPath).Path "avd-current-state-facts-$stamp.json"
    $json = $snapshot | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($outFile, $json, (New-Object System.Text.UTF8Encoding $false))

    Write-FactsLog "Facts snapshot: $outFile"
    Write-FactsLog "  $($subscriptions.Count) subscription(s), $(@($subscriptions | ForEach-Object { $_.hostPools }).Count) host pool(s), $($validations.Count) validator run(s), $($script:RedactedValues) value(s) redacted."
    # What this snapshot can and can't decide, and what the rest needs.
    # With -Assess the method's readiness rows answer this instead (below), so the run gives one answer.
    $registerFile = Join-Path $PSScriptRoot 'contracts/fact-register.json'
    if (-not $Assess -and (Test-Path -LiteralPath $registerFile)) {
        $coverage = Get-ManifestCoverage -Snapshot ($json | ConvertFrom-Json) -Register (Get-Content -LiteralPath $registerFile -Raw | ConvertFrom-Json)
        $line = "Manifest coverage: $($coverage.Supported.Count) of $($coverage.Total) design decisions can come from this snapshot"
        if ($coverage.Supported.Count) { $line += " ($(($coverage.Supported | ForEach-Object { $_.ToLowerInvariant() }) -join ', '))" }
        Write-FactsLog "$line."
        if ($coverage.Needs.Count) {
            Write-FactsLog "  $(($coverage.Needs -join ', ')) need measured usage: a Stratusphere UX assessment over a 2-4 week window turns them into a deployment-ready manifest."
        }
    }
    $assessFile = $null
    if ($Assess) {
        $assessFile = Join-Path (Split-Path -Parent $outFile) "avd-assessment-$stamp.json"
        $assessment = Write-Assessment -AssessInput $assessInput -SnapshotJson $json -Snapshot ($json | ConvertFrom-Json) -Destination $assessFile
        foreach ($p in $assessment.pillars) {
            $score = if ($null -eq $p.score) { 'no score' } else { 'score {0:0.00}' -f $p.score }
            Write-FactsLog ("  {0}: {1}, {2} of {3} checks assessed (coverage {4:0%})." -f $p.pillar, $score, $p.assessed, $p.checks, $p.coverage)
        }
        $byOutcome = @{}
        foreach ($r in $assessment.results) { $byOutcome[$r.outcome] = 1 + [int]$byOutcome[$r.outcome] }
        Write-FactsLog ("  Checks: {0} pass, {1} warn, {2} gap, {3} unknown." -f [int]$byOutcome['pass'], [int]$byOutcome['warn'], [int]$byOutcome['gap'], [int]$byOutcome['unknown'])
        $supported = @($assessment.decisions | Where-Object { $_.status -eq 'supported' })
        $line = "Assessment readiness: $($supported.Count) of $(@($assessment.decisions).Count) design decisions are supported"
        if ($supported.Count) { $line += " ($(($supported | ForEach-Object { $_.decision }) -join ', '))" }
        Write-FactsLog "$line."
        foreach ($status in @('needs-intake', 'missing-facts', 'needs-measurement')) {
            $rows = @($assessment.decisions | Where-Object { $_.status -eq $status })
            if ($rows.Count) { Write-FactsLog "  ${status}: $(($rows | ForEach-Object { $_.decision }) -join ', ')" }
        }
    }
    # The assessment portal's state line (docs/assessment-portal-spec.md, section 3): the estate pseudonym
    # the intake and the review are keyed by, and the snapshot's file name. No name or ID.
    $portalState = Join-Path $PSScriptRoot 'lib/AvdPortalState.psm1'
    if (Test-Path -LiteralPath $portalState) {
        Import-Module $portalState -Force
        $context = @{ estate = $snapshot.estate; snapshot = (Split-Path -Leaf $outFile) }
        if ($assessFile) { $context.assessment = Split-Path -Leaf $assessFile }
        Write-Host (Get-AvdcsStateLine -Stage 'facts' -Status 'done' -Context $context -Counts @{
                subscriptions = [int]$subscriptions.Count; hostPools = [int]@($subscriptions | ForEach-Object { $_.hostPools }).Count
                validations = [int]$validations.Count; redacted = [int]$script:RedactedValues })
    }
    Write-Output $outFile
} finally {
    foreach ($dir in $script:TempDirs) { if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } }
}

# endregion
