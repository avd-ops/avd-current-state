<#
    Branded HTML copies of the reports the scripts write (validation-report.md, summary.md) and the avd-ops
    look for Mermaid diagrams, both built from the pinned design system copy in site/assets/.

    Personal project, not for production use. Provided as is, without warranty of any kind (MIT License,
    see LICENSE). Not affiliated with the author's employer, with Liquidware or with Microsoft.

    An HTML report is one file: the design system's stylesheets, its fonts and the mark are inlined, it has
    no script, and its Content-Security-Policy allows nothing from the network, so it opens offline from
    Cloud Shell, Windows or macOS and prints to PDF. It shows exactly what the Markdown report holds, no more.
    Get-AvdcsReportAsset reads the files; the other functions are pure. Windows PowerShell 5.1 and
    PowerShell 7.
#>

Set-StrictMode -Version Latest

# Case-sensitive: the scripts write results in capitals, and "Info" or "Skip" in a data column is not a result.
$script:Results = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
foreach ($r in 'FAIL', 'WARN', 'PASS', 'INFO', 'SKIP') { $script:Results[$r] = 'r-' + $r.ToLowerInvariant() }
$script:Verdicts = @{ 'READY' = 'v-good'; 'READY WITH WARNINGS' = 'v-caution'; 'NOT READY' = 'v-bad' }
$script:Csp = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'"

function Get-AvdcsReportAsset {
    <#
    .SYNOPSIS
        Reads the pinned design system copy and the report layout into one stylesheet, with each font as a
        data URI, and the mark as a data URI. Returns $null when a file is missing (a copy of a script on
        its own has no site/ or lib/ beside it), so the caller writes only the Markdown report.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )
    # .NET reads resolve against the process folder, not the PowerShell location, so resolve -Root first.
    $resolved = Resolve-Path -LiteralPath $Root -ErrorAction SilentlyContinue
    if (-not $resolved) { return $null }
    $Root = $resolved.ProviderPath
    $assets = Join-Path $Root 'site/assets'
    $files = @((Join-Path $assets 'avd-ops.css'), (Join-Path $assets 'avd-ops-shell.css'), (Join-Path $Root 'lib/report/report.css'), (Join-Path $assets 'brand/mark.svg'))
    foreach ($f in $files) { if (-not (Test-Path -LiteralPath $f)) { return $null } }
    $tokens = [System.IO.File]::ReadAllText($files[0])
    $fontRefs = [regex]::Matches($tokens, 'url\("(fonts/[a-z0-9-]+\.woff2)"\)')
    foreach ($m in $fontRefs) {
        $path = Join-Path $assets $m.Groups[1].Value
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $uri = 'data:font/woff2;base64,' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))
        $tokens = $tokens.Replace($m.Value, 'url("' + $uri + '")')
    }
    $version = ''
    $v = [regex]::Match($tokens, 'avd-ops design system v(\d+\.\d+\.\d+)')
    if ($v.Success) { $version = $v.Groups[1].Value }
    @{
        Css     = $tokens + "`n" + [System.IO.File]::ReadAllText($files[1]) + "`n" + [System.IO.File]::ReadAllText($files[2])
        MarkUri = 'data:image/svg+xml;base64,' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($files[3]))
        Version = $version
    }
}

function ConvertTo-AvdcsHtmlText {
    # Escapes a Markdown line's text, then applies the inline marks the reports use: **bold**, *italic*, `code`.
    # Code spans are cut out first, so an asterisk inside one (a wildcard such as *.wvd.microsoft.com) stays.
    param([string]$Text)
    $parts = [regex]::Split($Text, '(`[^`]+`)')
    $sb = New-Object System.Text.StringBuilder
    foreach ($part in $parts) {
        if ($part.Length -ge 2 -and $part.StartsWith('`') -and $part.EndsWith('`')) {
            [void]$sb.Append('<code>' + (ConvertTo-AvdcsEscaped $part.Substring(1, $part.Length - 2)) + '</code>')
            continue
        }
        $t = ConvertTo-AvdcsEscaped $part
        $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<strong>$1</strong>')
        $t = [regex]::Replace($t, '(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])', '<em>$1</em>')
        [void]$sb.Append($t)
    }
    $sb.ToString()
}

function ConvertTo-AvdcsEscaped {
    param([string]$Text)
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Split-AvdcsTableRow {
    # Splits "| a | b \| c |" into cells; an escaped pipe stays inside its cell.
    param([string]$Line)
    $inner = $Line.Trim()
    if ($inner.StartsWith('|')) { $inner = $inner.Substring(1) }
    if ($inner.EndsWith('|') -and -not $inner.EndsWith('\|')) { $inner = $inner.Substring(0, $inner.Length - 1) }
    , @([regex]::Split($inner, '(?<!\\)\|') | ForEach-Object { $_.Trim().Replace('\|', '|') })
}

function ConvertTo-AvdcsTableHtml {
    param([string[]]$Rows)
    $head = Split-AvdcsTableRow $Rows[0]
    $body = @($Rows | Select-Object -Skip 2 | ForEach-Object { , (Split-AvdcsTableRow $_) })
    # A column of whole numbers aligns right; a column of results only is as narrow as its pills.
    $numeric = @()
    $resultCol = @()
    for ($c = 0; $c -lt $head.Count; $c++) {
        $cells = @($body | ForEach-Object { if ($c -lt $_.Count) { $_[$c] } })
        $numeric += ($cells.Count -gt 0) -and -not @($cells | Where-Object { $_ -notmatch '^\d+$' }).Count
        $resultCol += ($cells.Count -gt 0) -and -not @($cells | Where-Object { -not $script:Results.ContainsKey($_) }).Count
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="tbl"><table><thead><tr>')
    for ($c = 0; $c -lt $head.Count; $c++) {
        $cls = ''
        if ($numeric[$c]) { $cls = ' class="num"' } elseif ($resultCol[$c]) { $cls = ' class="fit"' }
        [void]$sb.Append("<th scope=""col""$cls>" + (ConvertTo-AvdcsHtmlText $head[$c]) + '</th>')
    }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in $body) {
        [void]$sb.Append('<tr>')
        for ($c = 0; $c -lt $row.Count; $c++) {
            $cell = $row[$c]
            if ($script:Results.ContainsKey($cell)) {
                [void]$sb.Append('<td><span class="res ' + $script:Results[$cell] + '">' + $cell + '</span></td>')
            } elseif ($c -lt $numeric.Count -and $numeric[$c]) {
                [void]$sb.Append('<td class="num">' + $cell + '</td>')
            } else {
                [void]$sb.Append('<td>' + (ConvertTo-AvdcsHtmlText $cell) + '</td>')
            }
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    $sb.ToString()
}

function ConvertTo-AvdcsReportHtml {
    <#
    .SYNOPSIS
        Turns one of the scripts' Markdown reports into a one-file HTML page in the avd-ops look. Reads the
        Markdown the scripts write (headings, label lines, tables, lists, quotes, rules); the result word
        in a table cell becomes a pill and the "Overall" line a verdict banner, always with the word.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Markdown,
        [Parameter(Mandatory = $true)][hashtable]$Asset,
        [Parameter(Mandatory = $true)][string]$Kind
    )
    $title = 'Report'
    $out = New-Object System.Text.StringBuilder
    $i = 0
    $n = $Markdown.Count
    while ($i -lt $n) {
        $line = $Markdown[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { $i++; continue }
        if ($line -match '^(#{1,4}) (.+)$') {
            $level = $Matches[1].Length
            $text = $Matches[2]
            if ($level -eq 1) {
                $title = $text
                [void]$out.Append('<p class="eyebrow">avd-current-state &middot; ' + (ConvertTo-AvdcsHtmlText $Kind) + '</p>')
            }
            [void]$out.Append("<h$level>" + (ConvertTo-AvdcsHtmlText $text) + "</h$level>")
            $i++; continue
        }
        if ($line -match '^\*\*Overall: (.+)\*\*$') {
            $word = $Matches[1]
            $cls = 'v-caution'
            if ($script:Verdicts.ContainsKey($word)) { $cls = $script:Verdicts[$word] }
            [void]$out.Append('<div class="verdict ' + $cls + '" role="status"><span><span class="lbl">Overall</span><br>' + (ConvertTo-AvdcsHtmlText $word) + '</span></div>')
            $i++; continue
        }
        # Two or more label lines in a row are run details; a single one ("**Important:** ...") is prose.
        if ($line -match '^\*\*[^*]+:\*\* ' -and $i + 1 -lt $n -and $Markdown[$i + 1] -match '^\*\*[^*]+:\*\* ') {
            [void]$out.Append('<dl class="run">')
            while ($i -lt $n -and $Markdown[$i] -match '^\*\*([^*]+):\*\* (.*)$') {
                [void]$out.Append('<dt>' + (ConvertTo-AvdcsHtmlText $Matches[1]) + '</dt><dd>' + (ConvertTo-AvdcsHtmlText $Matches[2]) + '</dd>')
                $i++
            }
            [void]$out.Append('</dl>')
            continue
        }
        if ($line -match '^-{3,}$') { [void]$out.Append('<hr>'); $i++; continue }
        if ($line.StartsWith('|')) {
            $rows = New-Object System.Collections.Generic.List[string]
            while ($i -lt $n -and $Markdown[$i].StartsWith('|')) { $rows.Add($Markdown[$i]); $i++ }
            if ($rows.Count -ge 2 -and $rows[1] -match '^\|(\s*:?-+:?\s*\|)+\s*$') {
                [void]$out.Append((ConvertTo-AvdcsTableHtml $rows.ToArray()))
            } else {
                # Not a table: keep every line as text rather than drop it.
                foreach ($r in $rows) { [void]$out.Append('<p>' + (ConvertTo-AvdcsHtmlText $r) + '</p>') }
            }
            continue
        }
        if ($line.StartsWith('>')) {
            [void]$out.Append('<blockquote>')
            while ($i -lt $n -and $Markdown[$i].StartsWith('>')) {
                [void]$out.Append('<p>' + (ConvertTo-AvdcsHtmlText ($Markdown[$i] -replace '^>\s?', '')) + '</p>')
                $i++
            }
            [void]$out.Append('</blockquote>')
            continue
        }
        if ($line -match '^(- |\d+\. )') {
            $tag = 'ul'
            $item = '^- (.*)$'
            if ($line -match '^\d+\. ') { $tag = 'ol'; $item = '^\d+\. (.*)$' }
            [void]$out.Append("<$tag>")
            while ($i -lt $n -and $Markdown[$i] -match $item) {
                [void]$out.Append('<li>' + (ConvertTo-AvdcsHtmlText $Matches[1]) + '</li>')
                $i++
            }
            [void]$out.Append("</$tag>")
            continue
        }
        [void]$out.Append('<p>' + (ConvertTo-AvdcsHtmlText $line) + '</p>')
        $i++
    }

    $docTitle = (ConvertTo-AvdcsHtmlText ($title -replace '\*', '')) + ' | avd-current-state'
    $lines = @(
        '<!doctype html>'
        '<!-- avd-current-state report in the avd-ops look (design system ' + $Asset.Version + '). Personal project, not for production, as is; not affiliated with the author''s employer, Liquidware or Microsoft. -->'
        '<html lang="en">'
        '<head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
        '<meta http-equiv="Content-Security-Policy" content="' + $script:Csp + '">'
        '<meta name="color-scheme" content="light dark">'
        "<title>$docTitle</title>"
        '<link rel="icon" href="' + $Asset.MarkUri + '">'
        '<style>'
        $Asset.Css
        '</style>'
        '</head>'
        '<body class="shell report">'
        '<header class="bar"><div class="bar-in"><a class="brand" href="https://avd-ops.dev/"><img class="mark" src="' + $Asset.MarkUri + '" alt="" width="28" height="28"><span class="word">avd-ops</span></a><span class="what">avd-current-state</span></div></header>'
        '<details class="notice"><summary><strong class="long">Personal project. Research and learning only. Not for production. No warranty.</strong><strong class="short">Research project, not for production.</strong><span class="more">Read the notice</span></summary>'
        '<div class="full"><ul><li>Built on my own time for research and learning. Not affiliated with, endorsed by or supported by my employer, Liquidware or Microsoft.</li>'
        '<li>This report is read-only evidence, not a production-readiness certification, a compliance attestation or a security audit.</li>'
        '<li>Provided "as is", without warranty of any kind, under the MIT License. You use it at your own risk.</li>'
        '<li>It holds what the run read from your subscription. Share it only where that subscription''s details may go.</li></ul></div></details>'
        '<div class="layout solo"><main id="main"><div class="col">'
        $out.ToString()
        '</div></main></div>'
        '<footer class="foot"><div class="in"><p>Written by avd-current-state, part of the avd-ops family. The scripts only read; nothing in Azure was changed.</p>'
        '<p>Every repo is open source, under MIT unless a folder says otherwise. Azure, Azure Virtual Desktop, Microsoft Entra, Intune and FSLogix are trademarks of Microsoft.</p>'
        '<p class="credit">A <a href="https://prignano.ai/">prignano.ai</a> production</p></div></footer>'
        '</body>'
        '</html>'
    )
    $lines -join "`n"
}

function Get-AvdcsDesignToken {
    <#
    .SYNOPSIS
        Reads the color tokens of avd-ops.css for one theme: the first :root block for light, the
        :root[data-theme="dark"] block for dark. Returns a hashtable of token name (without --) to value.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][string]$Css,
        [ValidateSet('light', 'dark')][string]$Theme = 'light'
    )
    $pattern = '(?m)^:root\{([^}]*)\}'
    if ($Theme -eq 'dark') { $pattern = ':root\[data-theme="dark"\]\{([^}]*)\}' }
    $block = [regex]::Match($Css, $pattern)
    if (-not $block.Success) { throw "No $Theme token block in the design system stylesheet." }
    $tokens = @{}
    foreach ($m in [regex]::Matches($block.Groups[1].Value, '--([a-z0-9-]+):\s*([^;]+);')) { $tokens[$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
    $tokens
}

function Get-AvdcsMermaidTheme {
    <#
    .SYNOPSIS
        The avd-ops look for a Mermaid flowchart in one theme, from the design system's tokens.
        Init: an init directive with the colors and spacing, for a .mmd file read anywhere (GitHub included).
        Config: the JSON for mermaid.initialize() on a page we render (estate.html), which adds the fonts and
        the shapes (8px nodes like the cards, 14px containers); Mermaid's init directive turns quotes inside
        a value into a broken config, so fonts and CSS travel only this way. The page loads the fonts before
        it renders, or Mermaid measures labels in a fallback font and cuts them off.
        ClassDefs: one line per node class; Styles: the same strings for "style <id> ..." lines, because a
        class on a subgraph doesn't apply its fill in Mermaid 11 (docs/diagram-spec.md section 5.3).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Css,
        [ValidateSet('light', 'dark')][string]$Theme = 'light'
    )
    $t = Get-AvdcsDesignToken -Css $Css -Theme $Theme
    $vars = [ordered]@{
        darkMode            = ($Theme -eq 'dark')
        background          = $t['bg']
        primaryColor        = $t['surface']
        primaryTextColor    = $t['fg']
        primaryBorderColor  = $t['line-strong']
        secondaryColor      = $t['sunken']
        tertiaryColor       = $t['bg']
        lineColor           = $t['muted']
        textColor           = $t['fg']
        nodeTextColor       = $t['fg']
        titleColor          = $t['fg']
        clusterBkg          = $t['sunken']
        clusterBorder       = $t['line-strong']
        edgeLabelBackground = $t['surface']
    }
    $flowchart = [ordered]@{ curve = 'basis'; padding = 12; nodeSpacing = 36; rankSpacing = 48 }
    $init = [ordered]@{ theme = 'base'; themeVariables = $vars; flowchart = $flowchart }

    $pageVars = [ordered]@{}
    foreach ($k in $vars.Keys) { $pageVars[$k] = $vars[$k] }
    $pageVars['fontFamily'] = '"Source Sans 3","Segoe UI",system-ui,sans-serif'
    $pageVars['fontSize'] = '15px'
    $themeCss = '.node rect{rx:8px;ry:8px}.cluster rect{rx:14px;ry:14px}' +
        '.cluster-label,.cluster-label span{font-family:"Schibsted Grotesk","Segoe UI",system-ui,sans-serif;font-weight:600}' +
        '.edgeLabel{font-size:13px}'
    $config = [ordered]@{ startOnLoad = $false; securityLevel = 'strict'; theme = 'base'; themeVariables = $pageVars; themeCSS = $themeCss; flowchart = $flowchart }

    $classes = [ordered]@{
        resource = "fill:$($t['surface']),stroke:$($t['line-strong']),color:$($t['fg']),stroke-width:1px"
        hub      = "fill:$($t['accent-soft']),stroke:$($t['accent']),color:$($t['fg']),stroke-width:1.5px"
        spoke    = "fill:$($t['sunken']),stroke:$($t['line-strong']),color:$($t['fg']),stroke-width:1px"
        avd      = "fill:$($t['s-design-bg']),stroke:$($t['s-design-fg']),color:$($t['s-design-fg']),stroke-width:1px"
        broken   = "fill:$($t['bad-soft']),stroke:$($t['bad']),color:$($t['bad']),stroke-width:1.5px,stroke-dasharray:5 4"
    }
    [pscustomobject]@{
        Init       = '%%{init: ' + ($init | ConvertTo-Json -Depth 4 -Compress) + '}%%'
        Config     = ($config | ConvertTo-Json -Depth 4 -Compress)
        ClassDefs  = @($classes.Keys | ForEach-Object { "classDef $_ $($classes[$_])" })
        Styles     = $classes
        BrokenLink = "stroke:$($t['bad']),stroke-width:1.5px,stroke-dasharray:5 4"
    }
}

Export-ModuleMember -Function Get-AvdcsReportAsset, ConvertTo-AvdcsReportHtml, Get-AvdcsDesignToken, Get-AvdcsMermaidTheme
