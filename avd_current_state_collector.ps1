<#
.SYNOPSIS
    AVD Current State Collector — inventories Azure Commercial environments from an
    Azure Virtual Desktop perspective and produces a portable evidence package.

.DESCRIPTION
    Discovers all enabled Azure subscriptions (or a filtered subset), validates read
    access, and collects AVD workload resources plus supporting platform infrastructure.
    Outputs per-subscription CSV/JSON evidence, a stakeholder-ready summary, a manifest,
    and a final ZIP archive.

    This is a current-state inventory tool. It is NOT a production-readiness certification,
    compliance attestation, or target-state gap analysis.

.PARAMETER SubscriptionNames
    Optional. One or more subscription display names to limit scope. When omitted the
    collector inventories every enabled subscription visible to the authenticated identity.

.PARAMETER OutputPath
    Optional. Parent directory for the evidence package. Defaults to the current directory.

.EXAMPLE
    .\avd_current_state_collector.ps1

.EXAMPLE
    .\avd_current_state_collector.ps1 -SubscriptionNames "Sub-A","Sub-B"

.EXAMPLE
    .\avd_current_state_collector.ps1 -OutputPath "C:\Evidence"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionNames,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# region Cloud Shell Detection
# ─────────────────────────────────────────────
$script:IsCloudShell = $false
if ($env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*' -or $env:ACC_CLOUD -eq 'true') {
    $script:IsCloudShell = $true
    # Default output to ~/clouddrive for session persistence unless caller overrode it
    $callerOverrodeOutput = $PSBoundParameters.ContainsKey('OutputPath')
    if (-not $callerOverrodeOutput) {
        $cloudDrive = Join-Path $HOME 'clouddrive'
        if (Test-Path $cloudDrive) {
            $OutputPath = $cloudDrive
        }
    }
}
# endregion

# ─────────────────────────────────────────────
# region Constants
# ─────────────────────────────────────────────
$script:Timestamp       = Get-Date -Format 'yyyyMMddTHHmmss'
$script:PackageName     = "avd-current-state-$script:Timestamp"
$script:RootDir         = Join-Path $OutputPath $script:PackageName
$script:LogMessages     = [System.Collections.Generic.List[string]]::new()
$script:Warnings        = [System.Collections.Generic.List[string]]::new()
$script:SubscriptionResults = [System.Collections.Generic.List[psobject]]::new()
# endregion

# ─────────────────────────────────────────────
# region Helper Functions
# ─────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $script:LogMessages.Add($entry)
    if ($Level -eq 'WARN')  { $script:Warnings.Add($Message); Write-Warning $Message }
    elseif ($Level -eq 'ERROR') { Write-Host $entry -ForegroundColor Red }
    else { Write-Host $entry }
}

function Safe-Export-Csv {
    param([string]$Path, [object[]]$Data, [string]$DatasetName)
    try {
        if ($null -eq $Data -or $Data.Count -eq 0) {
            Write-Log "No data for $DatasetName — skipping CSV export." -Level INFO
            return 0
        }
        $Data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -Force
        return $Data.Count
    } catch {
        Write-Log "CSV export failed for ${DatasetName}: $($_.Exception.Message)" -Level WARN
        return 0
    }
}

function Safe-Export-Json {
    param([string]$Path, [object]$Data, [string]$DatasetName)
    try {
        if ($null -eq $Data) {
            Write-Log "No data for $DatasetName — skipping JSON export." -Level INFO
            return
        }
        $json = $Data | ConvertTo-Json -Depth 10 -WarningAction SilentlyContinue
        [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
    } catch {
        Write-Log "JSON export failed for ${DatasetName}: $($_.Exception.Message)" -Level WARN
    }
}

function Export-Dataset {
    <#
    .SYNOPSIS Exports a dataset as both CSV and JSON under the given subscription folder.
    #>
    param(
        [string]$SubDir,
        [string]$Name,
        [object[]]$Data
    )
    $count = 0
    $csvPath  = Join-Path $SubDir "$Name.csv"
    $jsonPath = Join-Path $SubDir "$Name.json"
    $count = Safe-Export-Csv -Path $csvPath -Data $Data -DatasetName $Name
    Safe-Export-Json -Path $jsonPath -Data $Data -DatasetName $Name
    return $count
}

function Test-SubscriptionAccess {
    <#
    .SYNOPSIS Lightweight read-access validation against a subscription.
    #>
    param([string]$SubscriptionId)
    try {
        $null = Get-AzResourceGroup -ErrorAction Stop | Select-Object -First 1
        return $true
    } catch {
        return $false
    }
}

function Safe-Collect {
    <#
    .SYNOPSIS Wraps a script block in error handling so one dataset failure doesn't kill the run.
    #>
    param(
        [string]$DatasetName,
        [scriptblock]$Collector
    )
    try {
        Write-Log "  Collecting $DatasetName ..."
        $result = & $Collector
        if ($null -eq $result) { $result = @() }
        if ($result -isnot [System.Array]) { $result = @($result) }
        Write-Log "  $DatasetName — $($result.Count) item(s)."
        return $result
    } catch {
        Write-Log "  $DatasetName collection failed: $($_.Exception.Message)" -Level WARN
        return @()
    }
}

function Ensure-Module {
    param([string]$ModuleName)
    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Log "Module $ModuleName not found — installing from PSGallery ..."
        Install-Module -Name $ModuleName -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module $ModuleName -ErrorAction Stop
}

function Get-AzModuleVersions {
    $modules = Get-Module -Name Az.* -ListAvailable |
        Sort-Object Name -Unique |
        Select-Object Name, Version, @{N='VersionString';E={$_.Version.ToString()}}
    return $modules
}

function Sanitize-FolderName {
    param([string]$Name)
    $Name -replace '[^\w\-\.\s]', '_' -replace '\s+', '_'
}

function Get-PropValue {
    <#
    .SYNOPSIS
        StrictMode-safe property read that tolerates Az output shape changes.
    .DESCRIPTION
        Az.Resources v8 flattened Get-AzPolicyAssignment output, moving Properties.X
        up to X. Under Set-StrictMode -Version Latest a missing property throws rather
        than returning null, so a bare $_.Properties.DisplayName kills the whole dataset
        via Safe-Collect. Paths are tried in order and the first that resolves wins,
        so one expression works across Az versions.
    #>
    param([object]$InputObject, [string[]]$Paths, $Default = $null)
    foreach ($path in $Paths) {
        $current = $InputObject
        $resolved = $true
        foreach ($segment in ($path -split '\.')) {
            if ($null -eq $current) { $resolved = $false; break }
            $prop = $current.PSObject.Properties[$segment]
            if ($null -eq $prop -or $null -eq $prop.Value) { $resolved = $false; break }
            $current = $prop.Value
        }
        if ($resolved) { return $current }
    }
    return $Default
}


function Write-RebuildFile {
    <#
    .SYNOPSIS
        Writes one rebuild/ file after the never-collect scrubber, and refuses to write it if the
        final scan still finds a secret shape (docs/rebuild-fidelity-spec.md, section 5.2).
    #>
    param([string]$Path, [object]$Data, [string]$Label)
    $safe = ConvertTo-RebuildSafeObject -InputObject $Data
    if ($safe.Removed -gt 0) { Write-Log "  ${Label}: $($safe.Removed) secret value(s) left out." }
    $json = ConvertTo-Json -InputObject $safe.Object -Depth 64 -WarningAction SilentlyContinue
    $findings = @(Get-RebuildSecretFinding -Text $json)
    if ($findings.Count -gt 0) {
        $script:RebuildWithheld.Add([pscustomobject]@{ File = $Label; Findings = ($findings -join ', ') })
        Write-Log "  ${Label}: not written, the final scan found $($findings -join ', ')." -Level ERROR
        return $null
    }
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
    return $safe.Object
}

function Read-RebuildEvidence {
    <#
    .SYNOPSIS
        Reads every Resource Graph type and REST read in rebuild/scope.json for one subscription,
        writes them under <subscription>/rebuild/, and returns the scrubbed rows keyed by type
        ('*' holds the plain resource list for the arm-resources dataset).
    #>
    param([string]$SubscriptionId, [string]$SubDir)
    $graph = {
        param($body)
        $r = Invoke-AzRestMethod -Method POST -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Payload ($body | ConvertTo-Json -Depth 5 -Compress)
        @{ StatusCode = $r.StatusCode; Content = $r.Content }
    }
    $rest = {
        param($path)
        $r = Invoke-AzRestMethod -Method GET -Path $path
        @{ StatusCode = $r.StatusCode; Content = $r.Content }
    }
    $rebuildDir = Join-Path $SubDir 'rebuild'
    $rows = @{}

    Write-Log "  Reading the resource list through Resource Graph ..."
    try {
        $rows['*'] = @(Invoke-RebuildGraphQuery -Query 'resources | project id, name, type, location, tags | order by id asc' -SubscriptionId $SubscriptionId -Invoker $graph)
        Write-Log "  Resource list — $($rows['*'].Count) item(s)."
    } catch {
        $rows['*'] = @()
        Write-Log "  Resource list read failed: $($_.Exception.Message)" -Level WARN
    }

    foreach ($t in @($script:RebuildScope.resourceGraph)) {
        Write-Log "  Reading $($t.type) through Resource Graph ..."
        $status = 'ok'; $err = ''
        try {
            $found = @(Invoke-RebuildGraphQuery -Query (Get-RebuildQuery -Table $t.table -Type $t.type) -SubscriptionId $SubscriptionId -Invoker $graph)
        } catch {
            $found = @(); $status = 'failed'; $err = $_.Exception.Message
            Write-Log "  $($t.type) read failed: $err" -Level WARN
        }
        $written = Write-RebuildFile -Path (Join-Path $rebuildDir (Join-Path 'resources' (Get-RebuildFileName -Type $t.type))) -Data $found -Label $t.type
        $rows[$t.type] = if ($null -ne $written) { @($written) } else { @() }
        $script:RebuildReads.Add([pscustomobject]@{ Subscription = $SubscriptionId; Read = $t.type; Source = $t.table; Items = $found.Count; Status = $status; Error = $err })
    }

    $sessionHostVms = @{}
    foreach ($sh in @($rows['microsoft.desktopvirtualization/hostpools/sessionhosts'])) {
        $vmId = "$(Get-RebuildValue $sh 'properties.resourceId' '')".ToLowerInvariant()
        if ($vmId) { $sessionHostVms[$vmId] = $true }
    }
    foreach ($read in @($script:RebuildScope.rest)) {
        $parents = @()
        foreach ($p in @($read.parentTypes)) {
            if ($p -eq 'subscription') { $parents += "/subscriptions/$SubscriptionId" }
            else { $parents += @($rows[$p] | ForEach-Object { $_.id }) }
        }
        # Run Commands are read only on session hosts: that's where the landing zone keeps FSLogix's.
        if ($read.name -eq 'run-commands') { $parents = @($parents | Where-Object { $sessionHostVms.ContainsKey("$_".ToLowerInvariant()) }) }
        if ($parents.Count -eq 0) { continue }
        Write-Log "  Reading $($read.name) for $($parents.Count) resource(s) ..."
        $results = @(foreach ($parentId in $parents) {
                $r = Invoke-RebuildRestRead -Path (Get-RebuildRestPath -Read $read -ParentId $parentId) -Invoker $rest
                if ($r.Status -eq 'failed') { Write-Log "  $($read.name) failed for ${parentId}: $($r.Error)" -Level WARN }
                [pscustomobject][ordered]@{ parentId = $parentId; status = $r.Status; error = $r.Error; items = @($r.Items) }
            })
        $null = Write-RebuildFile -Path (Join-Path $rebuildDir (Join-Path 'rest' "$($read.name).json")) -Data $results -Label $read.name
        $failed = @($results | Where-Object { $_.status -eq 'failed' }).Count
        $script:RebuildReads.Add([pscustomobject]@{ Subscription = $SubscriptionId; Read = $read.name; Source = 'rest'; Items = $results.Count; Status = $(if ($failed) { "failed for $failed" } else { 'ok' }); Error = '' })
    }
    return $rows
}

# endregion

# ─────────────────────────────────────────────
# region Module Bootstrap
# ─────────────────────────────────────────────

Write-Log '═══════════════════════════════════════════════════'
Write-Log ' AVD Current State Collector'
Write-Log '═══════════════════════════════════════════════════'
Write-Log "Run timestamp : $script:Timestamp"
Write-Log "Output target : $script:RootDir"
if ($script:IsCloudShell) {
    Write-Log "Environment   : Azure Cloud Shell detected — output defaults to ~/clouddrive for persistence."
}

# Resource Graph and REST go through Invoke-AzRestMethod (Az.Accounts). Az.Resources keeps the
# policy and role assignment datasets and the access check.
$requiredModules = @(
    'Az.Accounts',
    'Az.Resources'
)

foreach ($mod in $requiredModules) {
    Ensure-Module -ModuleName $mod
}

Write-Log "Az modules loaded."

# Rebuild-fidelity reads (docs/rebuild-fidelity-spec.md): pure helpers and the scope of what is read.
Import-Module (Join-Path $PSScriptRoot 'lib/AvdRebuild.psm1') -Force
$script:RebuildScope    = Get-RebuildScope -Path (Join-Path $PSScriptRoot 'rebuild/scope.json')
$script:RebuildReads    = [System.Collections.Generic.List[psobject]]::new()
$script:RebuildWithheld = [System.Collections.Generic.List[psobject]]::new()
Write-Log "Rebuild scope : $(@($script:RebuildScope.resourceGraph).Count) Resource Graph types, $(@($script:RebuildScope.rest).Count) REST reads (landing zone $($script:RebuildScope.landingZoneCommit.Substring(0, 7)))."

# endregion

# ─────────────────────────────────────────────
# region Authentication
# ─────────────────────────────────────────────

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Log 'No active Azure context — launching interactive login (AzureCloud) ...'
    try {
        Connect-AzAccount -Environment AzureCloud -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    } catch {
        Write-Log "Authentication failed: $($_.Exception.Message)" -Level ERROR
        throw 'Unable to authenticate to Azure Commercial. Exiting.'
    }
}
Write-Log "Authenticated as $($context.Account.Id) in tenant $($context.Tenant.Id)."

# endregion

# ─────────────────────────────────────────────
# region Subscription Discovery
# ─────────────────────────────────────────────

Write-Log 'Discovering subscriptions ...'
$allSubs = Get-AzSubscription -ErrorAction Stop |
    Where-Object { $_.State -eq 'Enabled' } |
    Sort-Object Name

if ($allSubs.Count -eq 0) {
    Write-Log 'No enabled subscriptions visible to this identity.' -Level ERROR
    throw 'No enabled subscriptions found.'
}

Write-Log "Found $($allSubs.Count) enabled subscription(s)."

if ($SubscriptionNames -and $SubscriptionNames.Count -gt 0) {
    $filtered = $allSubs | Where-Object { $SubscriptionNames -contains $_.Name }
    $missing  = $SubscriptionNames | Where-Object { $_ -notin $allSubs.Name }
    if ($missing) {
        foreach ($m in $missing) {
            Write-Log "Requested subscription '$m' not found or not enabled." -Level WARN
        }
    }
    if ($filtered.Count -eq 0) {
        Write-Log 'None of the requested subscriptions are accessible.' -Level ERROR
        throw 'No matching subscriptions. Exiting.'
    }
    $targetSubs = $filtered
    Write-Log "Filtered to $($targetSubs.Count) subscription(s) by name."
} else {
    $targetSubs = $allSubs
    Write-Log "Targeting all $($targetSubs.Count) enabled subscription(s)."
}

# endregion

# ─────────────────────────────────────────────
# region Create Output Structure
# ─────────────────────────────────────────────

New-Item -ItemType Directory -Path $script:RootDir -Force | Out-Null

# Record module versions
$moduleVersions = Get-AzModuleVersions
$mvPath = Join-Path $script:RootDir 'az-module-versions'
Safe-Export-Csv  -Path "$mvPath.csv"  -Data $moduleVersions -DatasetName 'AzModuleVersions'
Safe-Export-Json -Path "$mvPath.json" -Data $moduleVersions -DatasetName 'AzModuleVersions'
Write-Log "Recorded Az module versions."

# endregion

# ─────────────────────────────────────────────
# region Per-Subscription Collection
# ─────────────────────────────────────────────

$grandTotals = @{}

foreach ($sub in $targetSubs) {
    $subName = $sub.Name
    $subId   = $sub.Id
    Write-Log "───────────────────────────────────────────────"
    Write-Log "Subscription: $subName ($subId)"

    # Switch context
    try {
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "Cannot set context for '$subName': $($_.Exception.Message)" -Level WARN
        $script:SubscriptionResults.Add([pscustomobject]@{
            SubscriptionName = $subName; SubscriptionId = $subId
            Status = 'ContextFailed'; Reason = $_.Exception.Message
        })
        continue
    }

    # Access validation
    if (-not (Test-SubscriptionAccess -SubscriptionId $subId)) {
        Write-Log "Read access validation failed for '$subName' — skipping." -Level WARN
        $script:SubscriptionResults.Add([pscustomobject]@{
            SubscriptionName = $subName; SubscriptionId = $subId
            Status = 'AccessDenied'; Reason = 'Lightweight read validation failed.'
        })
        continue
    }

    Write-Log "  Access validated."
    $folderName = Sanitize-FolderName -Name $subName
    $subDir = Join-Path $script:RootDir $folderName
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null

    # Store counts for this subscription
    $subCounts = @{}

    # ── Resource Graph and REST reads (docs/rebuild-fidelity-spec.md) ──
    # One read per resource type in rebuild/scope.json. The full objects go to rebuild/, and the
    # datasets below are built from the same rows, so the two never disagree.
    $rows = Read-RebuildEvidence -SubscriptionId $subId -SubDir $subDir

    # ── Core Resources ──
    $resourceGroups = Safe-Collect 'ResourceGroups' { Get-RebuildDataset -Name 'resource-groups' -Rows $rows }
    $subCounts['ResourceGroups'] = (Export-Dataset -SubDir $subDir -Name 'resource-groups' -Data $resourceGroups)

    $armResources = Safe-Collect 'ARMResources' { Get-RebuildDataset -Name 'arm-resources' -Rows $rows }
    $subCounts['ARMResources'] = (Export-Dataset -SubDir $subDir -Name 'arm-resources' -Data $armResources)

    # ── Networking ──
    $vnets = Safe-Collect 'VirtualNetworks' { Get-RebuildDataset -Name 'virtual-networks' -Rows $rows }
    $subCounts['VirtualNetworks'] = (Export-Dataset -SubDir $subDir -Name 'virtual-networks' -Data $vnets)

    $subnets = Safe-Collect 'Subnets' { Get-RebuildDataset -Name 'subnets' -Rows $rows }
    $subCounts['Subnets'] = (Export-Dataset -SubDir $subDir -Name 'subnets' -Data $subnets)

    $nsgs = Safe-Collect 'NSGs' { Get-RebuildDataset -Name 'nsgs' -Rows $rows }
    $subCounts['NSGs'] = (Export-Dataset -SubDir $subDir -Name 'nsgs' -Data $nsgs)

    $nsgRules = Safe-Collect 'NSGRules' { Get-RebuildDataset -Name 'nsg-rules' -Rows $rows }
    $subCounts['NSGRules'] = (Export-Dataset -SubDir $subDir -Name 'nsg-rules' -Data $nsgRules)

    $routeTables = Safe-Collect 'RouteTables' { Get-RebuildDataset -Name 'route-tables' -Rows $rows }
    $subCounts['RouteTables'] = (Export-Dataset -SubDir $subDir -Name 'route-tables' -Data $routeTables)

    $publicIPs = Safe-Collect 'PublicIPs' { Get-RebuildDataset -Name 'public-ips' -Rows $rows }
    $subCounts['PublicIPs'] = (Export-Dataset -SubDir $subDir -Name 'public-ips' -Data $publicIPs)

    # ── Compute ──
    $vms = Safe-Collect 'VirtualMachines' { Get-RebuildDataset -Name 'virtual-machines' -Rows $rows }
    $subCounts['VirtualMachines'] = (Export-Dataset -SubDir $subDir -Name 'virtual-machines' -Data $vms)

    $vmExtensions = Safe-Collect 'VMExtensions' { Get-RebuildDataset -Name 'vm-extensions' -Rows $rows }
    $subCounts['VMExtensions'] = (Export-Dataset -SubDir $subDir -Name 'vm-extensions' -Data $vmExtensions)

    # ── Storage ──
    $storageAccounts = Safe-Collect 'StorageAccounts' { Get-RebuildDataset -Name 'storage-accounts' -Rows $rows }
    $subCounts['StorageAccounts'] = (Export-Dataset -SubDir $subDir -Name 'storage-accounts' -Data $storageAccounts)

    # ── Key Vault ──
    $keyVaults = Safe-Collect 'KeyVaults' { Get-RebuildDataset -Name 'key-vaults' -Rows $rows }
    $subCounts['KeyVaults'] = (Export-Dataset -SubDir $subDir -Name 'key-vaults' -Data $keyVaults)

    # ── Log Analytics ──
    $logAnalytics = Safe-Collect 'LogAnalyticsWorkspaces' { Get-RebuildDataset -Name 'log-analytics-workspaces' -Rows $rows }
    $subCounts['LogAnalyticsWorkspaces'] = (Export-Dataset -SubDir $subDir -Name 'log-analytics-workspaces' -Data $logAnalytics)

    # ── Recovery Services ──
    $recVaults = Safe-Collect 'RecoveryServicesVaults' { Get-RebuildDataset -Name 'recovery-services-vaults' -Rows $rows }
    $subCounts['RecoveryServicesVaults'] = (Export-Dataset -SubDir $subDir -Name 'recovery-services-vaults' -Data $recVaults)

    # ── Private Endpoints ──
    $privateEndpoints = Safe-Collect 'PrivateEndpoints' { Get-RebuildDataset -Name 'private-endpoints' -Rows $rows }
    $subCounts['PrivateEndpoints'] = (Export-Dataset -SubDir $subDir -Name 'private-endpoints' -Data $privateEndpoints)

    # Policy and role assignments stay on cmdlets: Get-AzPolicyAssignment includes assignments
    # inherited from management groups, and Get-AzRoleAssignment adds display names from Graph.
    # Their full Resource Graph rows are saved under rebuild/ as well.

    # ── Policy Assignments ──
    $policyAssignments = Safe-Collect 'PolicyAssignments' {
        Get-AzPolicyAssignment -ErrorAction SilentlyContinue |
            Select-Object @{N='DisplayName';E={ Get-PropValue $_ @('DisplayName','Properties.DisplayName') '' }},
                @{N='PolicyDefinitionId';E={ Get-PropValue $_ @('PolicyDefinitionId','Properties.PolicyDefinitionId') '' }},
                @{N='Scope';E={ Get-PropValue $_ @('Scope','Properties.Scope') '' }},
                @{N='EnforcementMode';E={ Get-PropValue $_ @('EnforcementMode','Properties.EnforcementMode') '' }},
                @{N='AssignmentName';E={ $_.Name }},
                @{N='ResourceId';E={ Get-PropValue $_ @('Id','ResourceId') '' }}
    }
    $subCounts['PolicyAssignments'] = (Export-Dataset -SubDir $subDir -Name 'policy-assignments' -Data $policyAssignments)

    # ── Role Assignments ──
    $roleAssignments = Safe-Collect 'RoleAssignments' {
        Get-AzRoleAssignment -ErrorAction SilentlyContinue |
            Select-Object DisplayName, SignInName, RoleDefinitionName, Scope, ObjectType, ObjectId
    }
    $subCounts['RoleAssignments'] = (Export-Dataset -SubDir $subDir -Name 'role-assignments' -Data $roleAssignments)

    # ── AVD Host Pools ──
    $hostPools = Safe-Collect 'AVDHostPools' { Get-RebuildDataset -Name 'avd-host-pools' -Rows $rows }
    $subCounts['AVDHostPools'] = (Export-Dataset -SubDir $subDir -Name 'avd-host-pools' -Data $hostPools)

    # ── AVD Workspaces ──
    $avdWorkspaces = Safe-Collect 'AVDWorkspaces' { Get-RebuildDataset -Name 'avd-workspaces' -Rows $rows }
    $subCounts['AVDWorkspaces'] = (Export-Dataset -SubDir $subDir -Name 'avd-workspaces' -Data $avdWorkspaces)

    # ── AVD Application Groups ──
    $appGroups = Safe-Collect 'AVDApplicationGroups' { Get-RebuildDataset -Name 'avd-application-groups' -Rows $rows }
    $subCounts['AVDApplicationGroups'] = (Export-Dataset -SubDir $subDir -Name 'avd-application-groups' -Data $appGroups)

    # ── AVD Session Hosts ──
    $sessionHosts = Safe-Collect 'AVDSessionHosts' { Get-RebuildDataset -Name 'avd-session-hosts' -Rows $rows }
    $subCounts['AVDSessionHosts'] = (Export-Dataset -SubDir $subDir -Name 'avd-session-hosts' -Data $sessionHosts)
    # ── Record subscription outcome ──
    $script:SubscriptionResults.Add([pscustomobject]@{
        SubscriptionName = $subName
        SubscriptionId   = $subId
        Status           = 'Collected'
        Reason           = ''
    })

    foreach ($k in $subCounts.Keys) {
        if ($grandTotals.ContainsKey($k)) { $grandTotals[$k] += $subCounts[$k] }
        else { $grandTotals[$k] = $subCounts[$k] }
    }

    Write-Log "Subscription '$subName' collection complete."
}

# endregion

# ─────────────────────────────────────────────
# region Summary Generation
# ─────────────────────────────────────────────

Write-Log 'Generating summary ...'

$collectedSubs = $script:SubscriptionResults | Where-Object { $_.Status -eq 'Collected' }
$skippedSubs   = $script:SubscriptionResults | Where-Object { $_.Status -ne 'Collected' }

$summaryLines = [System.Collections.Generic.List[string]]::new()
function Add-Line { param([string]$L='') $summaryLines.Add($L) }

Add-Line "# AVD Current State — Collection Summary"
Add-Line ""
Add-Line "**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"
Add-Line "**Identity:** $($context.Account.Id)"
Add-Line "**Tenant:** $($context.Tenant.Id)"
Add-Line "**Subscriptions collected:** $($collectedSubs.Count) of $($targetSubs.Count) targeted"
Add-Line ""
Add-Line "---"
Add-Line ""

# Executive Summary
Add-Line "## Executive Summary"
Add-Line ""
Add-Line ("This evidence package captures a point-in-time inventory of the Azure environment " +
          "as seen through an Azure Virtual Desktop (AVD) lens. It documents host pools, " +
          "workspaces, application groups, session hosts, and the supporting platform infrastructure " +
          "(networking, storage, identity, monitoring, security) across $($collectedSubs.Count) subscription(s).")
Add-Line ""
Add-Line ("**Important:** This is a current-state inventory. It is not a production-readiness " +
          "certification, a compliance attestation, or a full target-state gap analysis.")
Add-Line ""

# AVD Workload Summary
Add-Line "## AVD Workload Overview"
Add-Line ""
$hpCount  = if ($grandTotals.ContainsKey('AVDHostPools'))         { $grandTotals['AVDHostPools'] }         else { 0 }
$wsCount  = if ($grandTotals.ContainsKey('AVDWorkspaces'))        { $grandTotals['AVDWorkspaces'] }        else { 0 }
$agCount  = if ($grandTotals.ContainsKey('AVDApplicationGroups')) { $grandTotals['AVDApplicationGroups'] } else { 0 }
$shCount  = if ($grandTotals.ContainsKey('AVDSessionHosts'))      { $grandTotals['AVDSessionHosts'] }      else { 0 }

Add-Line "| Component | Count |"
Add-Line "|---|---|"
Add-Line "| Host Pools | $hpCount |"
Add-Line "| Workspaces | $wsCount |"
Add-Line "| Application Groups | $agCount |"
Add-Line "| Session Hosts | $shCount |"
Add-Line ""

if ($hpCount -eq 0) {
    Add-Line "> **Note:** No AVD host pools were discovered. The environment may not yet have AVD deployed, or the collector identity may lack `Desktop Virtualization Reader` permissions."
    Add-Line ""
}

# Rebuild-fidelity reads
Add-Line "## Rebuild Evidence"
Add-Line ""
$readsFailed = @($script:RebuildReads | Where-Object { $_.Status -ne 'ok' })
Add-Line ("Full Azure objects for what a landing zone rebuild needs are under each subscription's ``rebuild/`` folder " +
          "(scope: ``rebuild/scope.json``, landing zone $($script:RebuildScope.landingZoneCommit.Substring(0, 7))). " +
          "Secrets are never collected: a rebuild recreates them.")
Add-Line ""
Add-Line "| Reads | Failed | Files withheld by the secret scan |"
Add-Line "|---|---|---|"
Add-Line "| $($script:RebuildReads.Count) | $($readsFailed.Count) | $($script:RebuildWithheld.Count) |"
Add-Line ""
foreach ($f in $readsFailed) { Add-Line "- $($f.Read): $($f.Status)" }
if ($readsFailed.Count -gt 0) { Add-Line "" }

# Per-subscription detail
Add-Line "## Subscription Detail"
Add-Line ""
foreach ($sr in $script:SubscriptionResults) {
    if ($sr.Status -eq 'Collected') {
        Add-Line "### $($sr.SubscriptionName)"
        Add-Line "- **Subscription ID:** $($sr.SubscriptionId)"
        Add-Line "- **Status:** Collected"
        Add-Line ""
    } else {
        Add-Line "### $($sr.SubscriptionName) *(skipped)*"
        Add-Line "- **Subscription ID:** $($sr.SubscriptionId)"
        Add-Line "- **Status:** $($sr.Status) — $($sr.Reason)"
        Add-Line ""
    }
}

# Platform inventory totals
Add-Line "## Supporting Platform Inventory"
Add-Line ""
Add-Line "| Dataset | Total Across Subscriptions |"
Add-Line "|---|---|"

$datasetOrder = @(
    'ResourceGroups', 'ARMResources', 'VirtualNetworks', 'Subnets', 'NSGs', 'NSGRules',
    'RouteTables', 'PublicIPs', 'VirtualMachines', 'VMExtensions', 'StorageAccounts',
    'KeyVaults', 'LogAnalyticsWorkspaces', 'RecoveryServicesVaults', 'PrivateEndpoints',
    'PolicyAssignments', 'RoleAssignments'
)

foreach ($ds in $datasetOrder) {
    $ct = if ($grandTotals.ContainsKey($ds)) { $grandTotals[$ds] } else { 0 }
    Add-Line "| $ds | $ct |"
}
Add-Line ""

# Architecture observations
Add-Line "## Architecture & Platform Observations"
Add-Line ""
$vnetCount = if ($grandTotals.ContainsKey('VirtualNetworks')) { $grandTotals['VirtualNetworks'] } else { 0 }
$peCount   = if ($grandTotals.ContainsKey('PrivateEndpoints')) { $grandTotals['PrivateEndpoints'] } else { 0 }
$vmCount   = if ($grandTotals.ContainsKey('VirtualMachines')) { $grandTotals['VirtualMachines'] } else { 0 }
$saCount   = if ($grandTotals.ContainsKey('StorageAccounts')) { $grandTotals['StorageAccounts'] } else { 0 }
$kvCount   = if ($grandTotals.ContainsKey('KeyVaults')) { $grandTotals['KeyVaults'] } else { 0 }
$laCount   = if ($grandTotals.ContainsKey('LogAnalyticsWorkspaces')) { $grandTotals['LogAnalyticsWorkspaces'] } else { 0 }
$rtCount   = if ($grandTotals.ContainsKey('RouteTables')) { $grandTotals['RouteTables'] } else { 0 }

Add-Line "- **Networking:** $vnetCount virtual network(s) discovered across all subscriptions providing the backbone for AVD session host connectivity."
if ($peCount -gt 0) {
    Add-Line "- **Private Endpoints:** $peCount private endpoint(s) detected, indicating use of private connectivity for platform services."
}
if ($rtCount -gt 0) {
    Add-Line "- **Routing:** $rtCount route table(s) present, which may affect AVD session host traffic patterns (e.g., forced tunneling, NVA routing)."
}
Add-Line "- **Compute:** $vmCount virtual machine(s) total, including any session hosts, image-authoring VMs, and supporting infrastructure."
Add-Line "- **Storage:** $saCount storage account(s), which may include FSLogix profile containers, MSIX app attach shares, or diagnostic storage."
if ($kvCount -gt 0) {
    Add-Line "- **Key Vault:** $kvCount Key Vault(s) available for certificate, secret, and key management supporting AVD or related services."
}
if ($laCount -gt 0) {
    Add-Line "- **Monitoring:** $laCount Log Analytics workspace(s) providing potential AVD diagnostics and monitoring integration."
}
Add-Line ""

# Warnings
if ($script:Warnings.Count -gt 0) {
    Add-Line "## Warnings"
    Add-Line ""
    foreach ($w in $script:Warnings) {
        Add-Line "- $w"
    }
    Add-Line ""
}

# Stakeholder takeaways
Add-Line "## Stakeholder Takeaways"
Add-Line ""
Add-Line "1. This package provides a factual snapshot of the Azure environment as discovered by the collector identity at the time of execution."
Add-Line "2. All AVD-specific resources (host pools, workspaces, application groups, session hosts) and supporting platform components (networking, storage, identity, monitoring) are inventoried."
Add-Line "3. Review the per-subscription CSV and JSON files for detailed resource-level evidence."
Add-Line "4. Any subscriptions that were skipped due to access issues are noted above — expand permissions and re-run if coverage is incomplete."
Add-Line "5. Pair this inventory with a design workshop or assessment to translate current state into actionable recommendations."
Add-Line ""

Add-Line "## Scope & Limitations"
Add-Line ""
Add-Line "- This collector reads Azure Resource Manager (ARM) data only. It does not inspect OS-level configuration, Group Policy, FSLogix registry settings, or Entra ID conditional access policies."
Add-Line "- Session host details depend on the AVD control plane; powered-off or unregistered hosts may show limited metadata."
Add-Line "- The collector does not modify any resources. It is read-only."
Add-Line "- Network and security datasets reflect ARM-level configuration. Effective NSG rules, NVA inspection, and DNS resolution behavior require separate validation."
Add-Line ""
Add-Line "---"
Add-Line "*Generated by AVD Current State Collector*"

$summaryPath = Join-Path $script:RootDir 'summary.md'
[System.IO.File]::WriteAllLines($summaryPath, $summaryLines.ToArray(), [System.Text.Encoding]::UTF8)
Write-Log "Summary written to summary.md."

# endregion

# ─────────────────────────────────────────────
# region Manifest
# ─────────────────────────────────────────────

$manifestFiles = Get-ChildItem -Path $script:RootDir -Recurse -File |
    Select-Object @{N='RelativePath';E={ $_.FullName.Replace($script:RootDir + [IO.Path]::DirectorySeparatorChar, '') }},
        @{N='SizeKB';E={ [math]::Round($_.Length / 1KB, 2) }},
        LastWriteTimeUtc

$manifest = [pscustomobject]@{
    PackageName      = $script:PackageName
    GeneratedUtc     = (Get-Date).ToUniversalTime().ToString('o')
    Identity         = $context.Account.Id
    TenantId         = $context.Tenant.Id
    SubscriptionsTargeted  = $targetSubs.Count
    SubscriptionsCollected = $collectedSubs.Count
    SubscriptionsSkipped   = $skippedSubs.Count
    SubscriptionDetails    = $script:SubscriptionResults
    GrandTotals      = $grandTotals
    RebuildScope     = [pscustomobject]@{ LandingZoneCommit = $script:RebuildScope.landingZoneCommit; Reads = $script:RebuildReads; Withheld = $script:RebuildWithheld }
    Warnings         = $script:Warnings
    Files            = $manifestFiles
}

$manifestPath = Join-Path $script:RootDir 'manifest.json'
Safe-Export-Json -Path $manifestPath -Data $manifest -DatasetName 'Manifest'
Write-Log "Manifest written."

# endregion

# ─────────────────────────────────────────────
# region ZIP Package
# ─────────────────────────────────────────────

$zipPath = Join-Path $OutputPath "$script:PackageName.zip"
Write-Log "Creating ZIP archive: $zipPath"
try {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path $script:RootDir -DestinationPath $zipPath -Force
    Write-Log "Evidence package archived successfully."
} catch {
    Write-Log "ZIP creation failed: $($_.Exception.Message)" -Level WARN
}

# endregion

# ─────────────────────────────────────────────
# region Final Output
# ─────────────────────────────────────────────

Write-Log '═══════════════════════════════════════════════════'
Write-Log ' Collection Complete'
Write-Log '═══════════════════════════════════════════════════'
Write-Log "Evidence folder : $script:RootDir"
Write-Log "ZIP archive     : $zipPath"
Write-Log "Summary         : $summaryPath"
Write-Log "Subscriptions   : $($collectedSubs.Count) collected, $($skippedSubs.Count) skipped"
Write-Log "Warnings        : $($script:Warnings.Count)"
Write-Log '═══════════════════════════════════════════════════'

# endregion
