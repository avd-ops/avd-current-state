# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
#
# Pure functions for the on-box local collector and log bundle (docs/local-collector-spec.md and
# avd-linecheck docs/spec.md section 17). Written for Windows PowerShell 5.1 and PowerShell 7 in
# Constrained Language Mode: cmdlets and operators only, no Add-Type, no classes, no New-Object,
# no .NET method calls, no remote -ComputerName/-CimSession, and no network calls in Device or
# Session modes.

Set-StrictMode -Version Latest

$script:LocalCollectorVersion = '1.0.0'

function Get-AvdLocalSource {
    <#
    .SYNOPSIS
        Returns the declarative collection sources for the requested mode from local/sources.json.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Preflight', 'Host', 'Session', 'Device', 'All')]
        [string]$Mode = 'All',
        [string]$SourcesPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'local/sources.json')
    )
    if (-not (Test-Path -LiteralPath $SourcesPath -PathType Leaf)) {
        throw "Local sources catalog not found at $SourcesPath"
    }
    $doc = Get-Content -LiteralPath $SourcesPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $all = @($doc.sources)
    if ($Mode -eq 'All') {
        return $all
    }
    return @($all | Where-Object { $_.mode -ieq $Mode })
}

function Get-AvdEndpointProbe {
    <#
    .SYNOPSIS
        Returns the probe and notTested endpoint rows for a view from assess/endpoints.json.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('host', 'device', 'browser')]
        [string]$View = 'host',
        [string]$EndpointsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'assess/endpoints.json')
    )
    if (-not (Test-Path -LiteralPath $EndpointsPath -PathType Leaf)) {
        throw "Pinned endpoint map not found at $EndpointsPath"
    }
    $doc = Get-Content -LiteralPath $EndpointsPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $byId = @{}
    foreach ($ep in @($doc.endpoints)) {
        $byId["$($ep.id)"] = $ep
    }
    $viewObj = $doc.views.$View
    $probe = foreach ($id in @($viewObj.probe)) {
        if ($byId["$id"]) { $byId["$id"] }
    }
    $notTested = foreach ($id in @($viewObj.notTested)) {
        if ($byId["$id"]) { $byId["$id"] }
    }
    return @{
        View      = $View
        ReadAt    = $doc.readAt
        Probe     = @($probe)
        NotTested = @($notTested)
    }
}

function Test-AvdLocalContext {
    <#
    .SYNOPSIS
        Checks whether the current user/elevation context matches the requested mode using whoami /groups lines.
    .DESCRIPTION
        Works in Constrained Language Mode without System.Security.Principal types:
        - S-1-5-18 or System Mandatory Level (S-1-16-16384) indicates SYSTEM.
        - High Mandatory Level (S-1-16-12288) or S-1-5-32-544 with High/System mandatory level indicates elevation.
        Device and Session modes refuse SYSTEM and elevated sessions.
        Host mode requires elevation or SYSTEM.
        Preflight mode allows either context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Preflight', 'Host', 'Session', 'Device')]
        [string]$Mode,
        [string[]]$WhoamiGroups = @()
    )
    $joined = $WhoamiGroups -join "`n"
    $isSystem = ($joined -match 'S-1-5-18\b') -or ($joined -match 'S-1-16-16384\b') -or ($joined -match 'System Mandatory Level')
    $isElevated = $isSystem -or ($joined -match 'S-1-16-12288\b') -or ($joined -match 'High Mandatory Level')

    if ($Mode -in @('Device', 'Session')) {
        if ($isSystem) {
            return @{
                Allowed    = $false
                IsSystem   = $true
                IsElevated = $true
                Reason     = 'ran as SYSTEM, wrong context: Device and Session modes must run in the signed-in user context (64-bit host).'
            }
        }
        if ($isElevated) {
            return @{
                Allowed    = $false
                IsSystem   = $false
                IsElevated = $true
                Reason     = 'refused: Device and Session modes must run as the standard signed-in user, not elevated.'
            }
        }
    }

    if ($Mode -eq 'Host' -and (-not $isElevated)) {
        return @{
            Allowed    = $false
            IsSystem   = $false
            IsElevated = $false
            Reason     = 'refused: Host mode requires an elevated administrator or SYSTEM session.'
        }
    }

    return @{
        Allowed    = $true
        IsSystem   = [bool]$isSystem
        IsElevated = [bool]$isElevated
        Reason     = 'ok'
    }
}

function Test-AvdSafeLocalPath {
    <#
    .SYNOPSIS
        Verifies that a path exists, carries no ReparsePoint attribute, and stays under RootPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$RootPath
    )
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return @{ Safe = $false; Status = 'not-present'; ResolvedPath = '' }
    }
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return @{ Safe = $false; Status = 'access-denied'; ResolvedPath = '' }
    }
    $attrText = "$($item.Attributes)"
    $linkTypeProp = Get-Member -InputObject $item -Name 'LinkType' -ErrorAction SilentlyContinue
    $hasLinkType = ($null -ne $linkTypeProp) -and ("$($item.LinkType)" -ne '')
    if (($attrText -match '\bReparsePoint\b') -or $hasLinkType) {
        return @{ Safe = $false; Status = 'skipped: reparse point'; ResolvedPath = '' }
    }
    $resolvedRootObj = Resolve-Path -LiteralPath $RootPath -ErrorAction SilentlyContinue
    $resolvedItemObj = Resolve-Path -LiteralPath $LiteralPath -ErrorAction SilentlyContinue
    if ($null -eq $resolvedRootObj -or $null -eq $resolvedItemObj) {
        return @{ Safe = $false; Status = 'not-present'; ResolvedPath = '' }
    }
    $rootNorm = ("$($resolvedRootObj.Path)" -replace '[\\/]+$', '') -replace '/', '\'
    $itemNorm = ("$($resolvedItemObj.Path)" -replace '[\\/]+$', '') -replace '/', '\'
    $underRoot = ($itemNorm -ieq $rootNorm) -or ($itemNorm -ilike "$rootNorm\*")
    if (-not $underRoot) {
        return @{ Safe = $false; Status = 'skipped: outside root'; ResolvedPath = $itemNorm }
    }
    return @{ Safe = $true; Status = 'ok'; ResolvedPath = $itemNorm }
}

function Copy-AvdSafeLocalItem {
    <#
    .SYNOPSIS
        Stages a file or directory using -LiteralPath while skipping reparse points, oversized files and locked files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [long]$MaxBytes = 52428800
    )
    $check = Test-AvdSafeLocalPath -LiteralPath $LiteralPath -RootPath $RootPath
    if (-not $check.Safe) {
        return @{
            Copied = @()
            Skipped = @(@{ Path = $LiteralPath; Reason = $check.Status })
        }
    }

    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        $null = New-Item -Path $Destination -ItemType Directory -Force
    }

    $copied = @()
    $skipped = @()
    $rootItem = Get-Item -LiteralPath $LiteralPath -Force
    $candidates = if ($rootItem.PSIsContainer) {
        @(Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue)
    } else {
        @($rootItem)
    }

    foreach ($entry in $candidates) {
        $entryCheck = Test-AvdSafeLocalPath -LiteralPath $entry.FullName -RootPath $RootPath
        if (-not $entryCheck.Safe) {
            $skipped += @{ Path = $entry.FullName; Reason = $entryCheck.Status }
            continue
        }
        if ($entry.PSIsContainer) {
            $subDest = Join-Path $Destination $entry.Name
            $subResult = Copy-AvdSafeLocalItem -LiteralPath $entry.FullName -Destination $subDest -RootPath $RootPath -MaxBytes $MaxBytes
            $copied += @($subResult.Copied)
            $skipped += @($subResult.Skipped)
            continue
        }
        if ([long]$entry.Length -gt $MaxBytes) {
            $skipped += @{ Path = $entry.FullName; Reason = 'too big' }
            continue
        }
        $targetFile = Join-Path $Destination $entry.Name
        try {
            Copy-Item -LiteralPath $entry.FullName -Destination $targetFile -Force -ErrorAction Stop
            $hashObj = Get-FileHash -LiteralPath $targetFile -Algorithm SHA256 -ErrorAction Stop
            $copied += @{
                SourcePath = $entry.FullName
                StagedPath = $targetFile
                SizeBytes  = [long]$entry.Length
                Sha256     = "$($hashObj.Hash)" -replace '.*', '$0'
            }
        } catch {
            $skipped += @{ Path = $entry.FullName; Reason = 'locked, skipped' }
        }
    }

    return @{
        Copied  = @($copied)
        Skipped = @($skipped)
    }
}

function Select-AvdAllowedProperty {
    <#
    .SYNOPSIS
        Filters an object or hashtable to only the property names listed in Allowlist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Allowlist
    )
    if ($InputObject -is [hashtable]) {
        $out = @{}
        foreach ($name in $Allowlist) {
            if ($null -ne $InputObject[$name]) {
                $out[$name] = $InputObject[$name]
            }
        }
        return $out
    }
    return ($InputObject | Select-Object -Property $Allowlist)
}

function Protect-AvdFslogixLocation {
    <#
    .SYNOPSIS
        Redacts plain-text connectionString secrets in FSLogix Cloud Cache entries while keeping credential references.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Value
    )
    if ("$Value" -eq '') { return '' }
    return ($Value -replace '(?i)(connectionString\s*=\s*)[^|,\r\n]+', '$1<redacted>')
}

function ConvertTo-AvdNormalizedUserPath {
    <#
    .SYNOPSIS
        Replaces the user profile directory prefix with %USERPROFILE% for manifest.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$UserProfile = $env:USERPROFILE
    )
    if ("$UserProfile" -eq '') { return $Path }
    $trimmedProfile = $UserProfile -replace '[\\/]+$', ''
    $escaped = $trimmedProfile -replace '([\\\.\$\^\{\[\(\|\)\*\+\?])', '\$1'
    return ($Path -replace "(?i)^$escaped", '%USERPROFILE%')
}

function New-AvdLocalFactDocument {
    <#
    .SYNOPSIS
        Builds the local-facts.json document for Host or Preflight mode (docs/local-collector-spec.md section 7).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Preflight', 'Host')]
        [string]$Mode,
        [hashtable]$ReaderData = @{},
        [string]$ScriptVersion = $script:LocalCollectorVersion,
        [string]$RunUtc = '2026-10-28T00:00:00Z'
    )
    $vmId = if (($null -ne $ReaderData['vmId']) -and ("$($ReaderData['vmId'])" -ne '')) {
        "$($ReaderData['vmId'])"
    } else {
        $null
    }
    $idSource = if ($null -ne $vmId) { 'imds' } else { 'none' }
    $computerName = if (($null -ne $ReaderData['computerName']) -and ("$($ReaderData['computerName'])" -ne '')) {
        "$($ReaderData['computerName'])"
    } else {
        "$env:COMPUTERNAME"
    }

    $factsObj = if ($Mode -eq 'Preflight') {
        @{
            source                                             = 'local'
            'c11.network.hostSubnets.preflightReachableCount'   = if ($null -ne $ReaderData['reachableCount']) { [int]$ReaderData['reachableCount'] } else { 0 }
            'c11.network.hostSubnets.preflightUnreachableCount' = if ($null -ne $ReaderData['unreachableCount']) { [int]$ReaderData['unreachableCount'] } else { 0 }
            'c11.network.hostSubnets.preflightProxyConfigured'  = if ($null -ne $ReaderData['proxyConfigured']) { [bool]$ReaderData['proxyConfigured'] } else { $false }
            'c11.network.hostSubnets.preflightImdsReachable'    = if ($null -ne $ReaderData['imdsReachable']) { [bool]$ReaderData['imdsReachable'] } else { [bool]($null -ne $vmId) }
        }
    } else {
        @{
            source                                            = 'local'
            'c11.hostPool.sessionHosts.localAgentVersion'       = if ($null -ne $ReaderData['agentVersion']) { "$($ReaderData['agentVersion'])" } else { 'unknown' }
            'c11.hostPool.sessionHosts.localFslogixEnabled'     = if ($null -ne $ReaderData['fslogixEnabled']) { [bool]$ReaderData['fslogixEnabled'] } else { $false }
            'c11.hostPool.sessionHosts.localTeamsOptimized'     = if ($null -ne $ReaderData['teamsOptimized']) { [bool]$ReaderData['teamsOptimized'] } else { $false }
            'c11.hostPool.sessionHosts.localShortpathEnabled'   = if ($null -ne $ReaderData['shortpathEnabled']) { [bool]$ReaderData['shortpathEnabled'] } else { $false }
            'c11.hostPool.sessionHosts.localPendingReboot'      = if ($null -ne $ReaderData['pendingReboot']) { [bool]$ReaderData['pendingReboot'] } else { $false }
            'c11.hostPool.sessionHosts.localUrlToolUnreachable' = if ($null -ne $ReaderData['urlToolUnreachable']) { [int]$ReaderData['urlToolUnreachable'] } else { 0 }
        }
    }

    return @{
        schemaVersion = 'avd-local-facts/v1'
        mode          = $Mode
        scriptVersion = $ScriptVersion
        runUtc        = $RunUtc
        privacyClass  = 'private'
        identity      = @{
            vmId         = $vmId
            idSource     = $idSource
            computerName = $computerName
        }
        facts         = $factsObj
    }
}

function New-AvdLocalHealthSummary {
    <#
    .SYNOPSIS
        Builds health.json as plain-language values without uncited judgments (avd-linecheck spec 17.7).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [hashtable]$ReaderData = @{},
        [string]$RunUtc = '2026-10-28T00:00:00Z'
    )
    $freeDiskGiB = $ReaderData['freeDiskGiB']
    $uptimeHours = $ReaderData['uptimeHours']
    $pendingReboot = if ($null -ne $ReaderData['pendingReboot']) { [bool]$ReaderData['pendingReboot'] } else { $false }
    $crashCount = if ($null -ne $ReaderData['crashCount']) { [int]$ReaderData['crashCount'] } else { 0 }
    $defenderEnabled = if ($null -ne $ReaderData['defenderEnabled']) { [bool]$ReaderData['defenderEnabled'] } else { $null }

    return @{
        schemaVersion = 'avd-local-health/v1'
        runUtc        = $RunUtc
        privacyClass  = 'private'
        items         = @(
            @{ id = 'disk.freeGiB'; label = 'Free disk space (GiB)'; value = $freeDiskGiB },
            @{ id = 'os.uptimeHours'; label = 'System uptime (hours)'; value = $uptimeHours },
            @{ id = 'os.pendingReboot'; label = 'Pending reboot'; value = $pendingReboot },
            @{ id = 'stability.crashesInWindow'; label = 'Application crashes in time window'; value = $crashCount },
            @{ id = 'defender.realTimeProtection'; label = 'Microsoft Defender real-time protection'; value = $defenderEnabled }
        )
    }
}

function New-AvdLocalManifest {
    <#
    .SYNOPSIS
        Builds manifest.json for a local collection bundle (avd-linecheck spec 17.3 and 17.4).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Preflight', 'Host', 'Session', 'Device')]
        [string]$Mode,
        [object[]]$Files = @(),
        [object[]]$Skipped = @(),
        [int]$Hours = 24,
        [string]$RequestedBy = '',
        [switch]$AllUsers,
        [string]$ScriptVersion = $script:LocalCollectorVersion,
        [string]$RunUtc = '2026-10-28T00:00:00Z',
        [string]$UserProfile = $env:USERPROFILE
    )
    $normalizedFiles = foreach ($f in $Files) {
        $src = if ($f -is [hashtable]) {
            if ($null -ne $f['SourcePath']) { "$($f['SourcePath'])" } else { "$($f['Path'])" }
        } else {
            $hasSourcePath = $null -ne (Get-Member -InputObject $f -Name 'SourcePath' -ErrorAction SilentlyContinue)
            if ($hasSourcePath) { "$($f.SourcePath)" } else { "$($f.Path)" }
        }
        @{
            sourcePath = ConvertTo-AvdNormalizedUserPath -Path $src -UserProfile $UserProfile
            sizeBytes  = [long]$f.SizeBytes
            sha256     = "$($f.Sha256)"
        }
    }
    $normalizedSkipped = foreach ($s in $Skipped) {
        @{
            sourcePath = ConvertTo-AvdNormalizedUserPath -Path "$($s.Path)" -UserProfile $UserProfile
            reason     = "$($s.Reason)"
        }
    }

    return @{
        schemaVersion        = 'avd-local-manifest/v1'
        mode                 = $Mode
        scriptVersion        = $ScriptVersion
        runUtc               = $RunUtc
        windowHours          = $Hours
        containsPersonalData = ($Mode -in @('Session', 'Device')) -or [bool]$AllUsers
        allUsers             = [bool]$AllUsers
        requestedBy          = $RequestedBy
        files                = @($normalizedFiles)
        skipped              = @($normalizedSkipped)
    }
}

function Invoke-AvdLocalCollector {
    <#
    .SYNOPSIS
        Runs the local collector in Preflight, Host, Session or Device mode, or lists sources with -ListSources.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Preflight', 'Host', 'Session', 'Device')]
        [string]$Mode,
        [string]$OutputPath,
        [int]$Hours = 24,
        [switch]$AllUsers,
        [string]$RequestedBy = '',
        [switch]$Bundle,
        [switch]$ListSources,
        [string[]]$Add = @(),
        [string[]]$WhoamiGroups = @(),
        [hashtable]$ReaderData = @{},
        [string]$RunUtc = '2026-10-28T00:00:00Z',
        [string]$UserProfile = $env:USERPROFILE
    )
    $sources = @(Get-AvdLocalSource -Mode $Mode)
    if ($ListSources) {
        return @{
            Mode                 = $Mode
            ContainsPersonalData = ($Mode -in @('Session', 'Device'))
            Sources              = $sources
        }
    }

    if ($WhoamiGroups.Count -eq 0) {
        $whoamiExe = Join-Path $env:SystemRoot 'System32\whoami.exe'
        if (Test-Path -LiteralPath $whoamiExe -PathType Leaf) {
            $WhoamiGroups = @(& $whoamiExe /groups 2>$null)
        }
    }

    $ctx = Test-AvdLocalContext -Mode $Mode -WhoamiGroups $WhoamiGroups
    if (-not $ctx.Allowed) {
        throw $ctx.Reason
    }

    if ("$OutputPath" -eq '') {
        $OutputPath = Join-Path $UserProfile 'Downloads'
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
    }

    $stageDir = Join-Path $OutputPath ("avd-local-stage-" + ($Mode -replace '[^a-zA-Z0-9]', ''))
    if (Test-Path -LiteralPath $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    }
    $null = New-Item -Path $stageDir -ItemType Directory -Force

    $copiedFiles = @()
    $skippedSources = @()

    foreach ($addPath in $Add) {
        if ("$addPath" -eq '') { continue }
        $parentRoot = Split-Path -Path $addPath -Parent
        if ("$parentRoot" -eq '') { $parentRoot = $OutputPath }
        $stageRes = Copy-AvdSafeLocalItem -LiteralPath $addPath -Destination $stageDir -RootPath $parentRoot
        $copiedFiles += @($stageRes.Copied)
        $skippedSources += @($stageRes.Skipped)
    }

    $factsPath = $null
    if ($Mode -in @('Preflight', 'Host')) {
        $factsDoc = New-AvdLocalFactDocument -Mode $Mode -ReaderData $ReaderData -RunUtc $RunUtc
        $factsPath = Join-Path $OutputPath 'local-facts.json'
        $factsDoc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $factsPath -Encoding UTF8
        $factsHash = Get-FileHash -LiteralPath $factsPath -Algorithm SHA256
        $factsItem = Get-Item -LiteralPath $factsPath -Force
        $copiedFiles += @{
            SourcePath = $factsPath
            StagedPath = $factsPath
            SizeBytes  = [long]$factsItem.Length
            Sha256     = "$($factsHash.Hash)"
        }
    }

    $healthDoc = New-AvdLocalHealthSummary -ReaderData $ReaderData -RunUtc $RunUtc
    $healthPath = Join-Path $stageDir 'health.json'
    $healthDoc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $healthPath -Encoding UTF8
    $healthHash = Get-FileHash -LiteralPath $healthPath -Algorithm SHA256
    $healthItem = Get-Item -LiteralPath $healthPath -Force
    $copiedFiles += @{
        SourcePath = $healthPath
        StagedPath = $healthPath
        SizeBytes  = [long]$healthItem.Length
        Sha256     = "$($healthHash.Hash)"
    }

    $manifestDoc = New-AvdLocalManifest -Mode $Mode -Files $copiedFiles -Skipped $skippedSources `
        -Hours $Hours -RequestedBy $RequestedBy -AllUsers:$AllUsers -RunUtc $RunUtc -UserProfile $UserProfile
    $manifestPath = Join-Path $stageDir 'manifest.json'
    $manifestDoc | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $topManifestPath = Join-Path $OutputPath 'manifest.json'
    Copy-Item -LiteralPath $manifestPath -Destination $topManifestPath -Force

    $zipPath = $null
    $shouldZip = ($Mode -in @('Session', 'Device')) -or [bool]$Bundle
    if ($shouldZip) {
        $stamp = ($RunUtc -replace '[^0-9]', '')
        if ($stamp -match '^(\d{8})(\d{4})') {
            $stamp = "$($Matches[1])-$($Matches[2])"
        } else {
            $stamp = '20261028-0000'
        }
        $modeSlug = if ($Mode -eq 'Device') { 'device' } elseif ($Mode -eq 'Session') { 'session' } elseif ($Mode -eq 'Host') { 'host' } else { 'preflight' }
        $zipPath = Join-Path $OutputPath "avd-linecheck-$modeSlug-$stamp.zip"
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }
        $stageItems = @(Get-ChildItem -LiteralPath $stageDir -Force | ForEach-Object { $_.FullName })
        if ($stageItems.Count -gt 0) {
            Compress-Archive -LiteralPath $stageItems -DestinationPath $zipPath -Force
        }
    }

    return @{
        schemaVersion = 'avd-local-summary/v1'
        mode          = $Mode
        runUtc        = $RunUtc
        factsPath     = $factsPath
        manifestPath  = $topManifestPath
        zipPath       = $zipPath
        fileCount     = $copiedFiles.Count
        skippedCount  = $skippedSources.Count
    }
}

Export-ModuleMember -Function @(
    'Get-AvdLocalSource',
    'Get-AvdEndpointProbe',
    'Test-AvdLocalContext',
    'Test-AvdSafeLocalPath',
    'Copy-AvdSafeLocalItem',
    'Select-AvdAllowedProperty',
    'Protect-AvdFslogixLocation',
    'ConvertTo-AvdNormalizedUserPath',
    'New-AvdLocalFactDocument',
    'New-AvdLocalHealthSummary',
    'New-AvdLocalManifest',
    'Invoke-AvdLocalCollector'
)
