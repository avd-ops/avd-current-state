# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
<#
.SYNOPSIS
    Assembles the standalone single-file local collector (avd_current_state_local.ps1) for signed releases.
.DESCRIPTION
    Implements docs/local-collector-spec.md section 4a: combines lib/AvdLocal.psm1 with embedded
    local/sources.json and assess/endpoints.json into one CLM-safe PowerShell script with zero
    external file dependencies.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if ("$OutputPath" -eq '') {
    $OutputPath = Join-Path $repoRoot 'dist/avd_current_state_local.ps1'
}

$modulePath = Join-Path $repoRoot 'lib/AvdLocal.psm1'
$sourcesPath = Join-Path $repoRoot 'local/sources.json'
$endpointsPath = Join-Path $repoRoot 'assess/endpoints.json'

foreach ($req in @($modulePath, $sourcesPath, $endpointsPath)) {
    if (-not (Test-Path -LiteralPath $req -PathType Leaf)) {
        throw "Required source file not found: $req"
    }
}

$moduleRaw = Get-Content -LiteralPath $modulePath -Raw
$sourcesRaw = (Get-Content -LiteralPath $sourcesPath -Raw).Trim()
$endpointsRaw = (Get-Content -LiteralPath $endpointsPath -Raw).Trim()

# Escape any accidental single-quoted here-string terminator inside JSON
$sourcesEsc = $sourcesRaw -replace "(?m)^'@", "' @"
$endpointsEsc = $endpointsRaw -replace "(?m)^'@", "' @"

# Strip Export-ModuleMember block from module body and inject embedded JSON literals
$body = $moduleRaw -replace '(?ms)\r?\nExport-ModuleMember\b.*$', ''
$body = $body -replace '\$script:EmbeddedLocalSourcesJson\s*=\s*\$null', ("`$script:EmbeddedLocalSourcesJson = @'`n" + $sourcesEsc + "`n'@")
$body = $body -replace '\$script:EmbeddedEndpointsJson\s*=\s*\$null', ("`$script:EmbeddedEndpointsJson = @'`n" + $endpointsEsc + "`n'@")
$body = $body -replace '(?m)^Set-StrictMode\s+-Version\s+Latest\r?\n?', ''

$header = @'
# Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.
# Assembled standalone local collector (docs/local-collector-spec.md section 4a).
[CmdletBinding()]
param(
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
    [hashtable]$ReaderData = @{},
    [string]$RunUtc = '',
    [string]$UserProfile = $env:USERPROFILE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ("$RunUtc" -eq '') {
    $RunUtc = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ'
}
'@

$footer = @'

return Invoke-AvdLocalCollector -Mode $Mode -OutputPath $OutputPath -Hours $Hours `
    -AllUsers:$AllUsers -RequestedBy $RequestedBy -Bundle:$Bundle -ListSources:$ListSources `
    -Add $Add -WhoamiGroups $WhoamiGroups -ReaderData $ReaderData -RunUtc $RunUtc -UserProfile $UserProfile
'@

$outDir = Split-Path -Path $OutputPath -Parent
if ($outDir -and (-not (Test-Path -LiteralPath $outDir -PathType Container))) {
    $null = New-Item -Path $outDir -ItemType Directory -Force
}

$assembled = $header + "`n" + $body.Trim() + "`n" + $footer.TrimStart()
$assembled | Set-Content -LiteralPath $OutputPath -Encoding UTF8

$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
$leaf = Split-Path -Path $OutputPath -Leaf
"$hash  $leaf" | Set-Content -LiteralPath "$OutputPath.sha256" -Encoding ASCII

return @{
    OutputPath = $OutputPath
    Sha256Path = "$OutputPath.sha256"
    Sha256     = $hash
}
