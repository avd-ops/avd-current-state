#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Offline tests for the HTML reports and the Mermaid theme (lib/AvdReport.psm1). The fixtures in tests/report/
# are synthetic copies of what the validator and the collector write (contoso names, all-zero IDs).

BeforeAll {
  $script:root = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $script:root 'lib/AvdReport.psm1') -Force
  $script:asset = Get-AvdcsReportAsset -Root $script:root
  $script:css = [System.IO.File]::ReadAllText((Join-Path $script:root 'site/assets/avd-ops.css'))
  $md = Get-Content (Join-Path $script:root 'tests/report/validation-report.md') -Encoding UTF8
  $script:validation = ConvertTo-AvdcsReportHtml -Markdown $md -Asset $script:asset -Kind 'Deployment validator'
  $md = Get-Content (Join-Path $script:root 'tests/report/summary.md') -Encoding UTF8
  $script:summary = ConvertTo-AvdcsReportHtml -Markdown $md -Asset $script:asset -Kind 'Collector'
}

Describe 'Get-AvdcsReportAsset' {
  It 'inlines every font and the mark, from the pinned design system copy' {
    $script:asset.Css | Should -Not -Match 'url\("fonts/'
    # Every font face the pinned copy ships (the lock's .woff2 files), so a face lost from avd-ops.css fails here.
    $lockFonts = @((Get-Content -Raw (Join-Path $script:root 'site/assets/design-system.lock.json') | ConvertFrom-Json).files.PSObject.Properties.Name | Where-Object { $_ -like 'fonts/*.woff2' })
    $lockFonts.Count | Should -BeGreaterThan 0
    ([regex]::Matches($script:asset.Css, 'data:font/woff2;base64,')).Count | Should -Be $lockFonts.Count
    $script:asset.MarkUri | Should -Match '^data:image/svg\+xml;base64,'
    $lock = Get-Content -Raw (Join-Path $script:root 'site/assets/design-system.lock.json') | ConvertFrom-Json
    $script:asset.Version | Should -Be $lock.tag.Substring(4)
  }

  It 'returns nothing when the files are not beside the script' {
    Get-AvdcsReportAsset -Root (Join-Path $TestDrive 'lonely') | Should -BeNullOrEmpty
  }
}

Describe 'ConvertTo-AvdcsReportHtml' {
  It 'makes no request: no script, a CSP that allows only inline style and data URIs' {
    foreach ($h in @($script:validation, $script:summary)) {
      $h | Should -Not -Match '<script'
      $h | Should -Match ([regex]::Escape("content=""default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'"""))
      $h | Should -Not -Match '(src|url\()\s*=?\s*"?https?:'
      $h | Should -Not -Match '<link rel="stylesheet"'
      @([regex]::Matches($h, 'href="(https?://[^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) |
        Should -Be @('https://avd-ops.dev/', 'https://prignano.ai/')
    }
  }

  It 'carries the shell, the notice and the credit line' {
    foreach ($h in @($script:validation, $script:summary)) {
      $h | Should -Match '<body class="shell report">'
      $h | Should -Match 'Personal project\. Research and learning only\. Not for production\. No warranty\.'
      $h | Should -Match '<p class="credit">A <a href="https://prignano.ai/">prignano.ai</a> production</p>'
      $h | Should -Match 'trademarks of Microsoft'
    }
  }

  It 'shows the verdict and every result as a word, never color alone' {
    $script:validation | Should -Match '<div class="verdict v-bad" role="status"><span><span class="lbl">Overall</span><br>NOT READY</span></div>'
    foreach ($r in 'fail', 'warn', 'pass', 'info', 'skip') {
      $script:validation | Should -Match ('<span class="res r-' + $r + '">' + $r.ToUpper() + '</span>')
    }
    $script:validation | Should -Match '<th scope="col" class="fit">Status</th><th scope="col" class="num">Count</th>'
  }

  It 'reads the label lines, tables, escaped pipes, lists and quotes' {
    $script:validation | Should -Match '<title>AVD Deployment Validation Report \| avd-current-state</title>'
    $script:validation | Should -Match '<dt>Mode</dt><dd>PostDeployment</dd>'
    $script:validation | Should -Match '<td>The host pool has no scaling plan \| autoscale is off\.</td>'
    $script:validation | Should -Match '<td>The profile share is 82% full \(<code>profiles</code>\)\.</td>'
    $script:validation | Should -Match '<blockquote><p>This validator is read-only'
    $script:validation | Should -Match '<li><strong>Read-only\.</strong> No Azure resource'
    $script:summary | Should -Match '<ol><li>Review the AVD workload overview above\.</li>'
    $script:summary | Should -Match '<h3>contoso-shared <em>\(skipped\)</em></h3>'
    $script:summary | Should -Match '<td class="num">12</td>'
  }

  It 'escapes what the run read, so a name cannot become markup' {
    $h = ConvertTo-AvdcsReportHtml -Markdown @('# T', '| Status | Check |', '|---|---|', '| PASS | <script>alert(1)</script> & "x" |') -Asset $script:asset -Kind 'Test'
    $h | Should -Not -Match '<script>'
    $h | Should -Match '<td>&lt;script&gt;alert\(1\)&lt;/script&gt; &amp; &quot;x&quot;</td>'
  }

  It 'reads the edge cases the code review found' {
    $h = ConvertTo-AvdcsReportHtml -Markdown @(
      '# T'
      'Allow `*.wvd.microsoft.com` and `*.servicebus.windows.net` outbound.'
      '| only one line |'
      '**Important:** one label line is prose.'
      '- a'
      '1. b'
      '| Level | Status |'
      '|---|---|'
      '| Info | PASS |'
    ) -Asset $script:asset -Kind 'Test'
    $h | Should -Match '<p>Allow <code>\*\.wvd\.microsoft\.com</code> and <code>\*\.servicebus\.windows\.net</code> outbound\.</p>'
    $h | Should -Match '<p>\| only one line \|</p>'
    $h | Should -Match '<p><strong>Important:</strong> one label line is prose\.</p>'
    $h | Should -Not -Match '<dl class="run">'
    $h | Should -Match '<ul><li>a</li></ul><ol><li>b</li></ol>'
    $h | Should -Match '<td>Info</td><td><span class="res r-pass">PASS</span></td>'
  }

  It 'finds the files from a relative root too' {
    Push-Location $script:root
    try { (Get-AvdcsReportAsset -Root '.').Css | Should -Match 'avd-ops design system' } finally { Pop-Location }
  }

  It 'holds no text the <Name> Markdown does not' -ForEach @(@{ Name = 'validation-report'; Kind = 'Deployment validator' }, @{ Name = 'summary'; Kind = 'Collector' }) {
    $html = ConvertTo-AvdcsReportHtml -Markdown (Get-Content (Join-Path $script:root "tests/report/$Name.md") -Encoding UTF8) -Asset $script:asset -Kind $Kind
    $body = [regex]::Match($html, '<main id="main">(.*)</main>', 'Singleline').Groups[1].Value
    $text = [System.Net.WebUtility]::HtmlDecode(($body -replace '<[^>]+>', ' '))
    $mdWords = @([regex]::Matches((Get-Content (Join-Path $script:root "tests/report/$Name.md") -Raw -Encoding UTF8), '\w+') | ForEach-Object { $_.Value })
    # The eyebrow names the tool and the kind of report; everything else comes from the Markdown.
    $extra = @('avd', 'current', 'state', 'Deployment', 'validator', 'Collector')
    $added = @([regex]::Matches($text, '\w+') | ForEach-Object { $_.Value } | Where-Object { $mdWords -cnotcontains $_ -and $extra -cnotcontains $_ } | Sort-Object -Unique)
    $added | Should -BeNullOrEmpty
  }
}

Describe 'Get-AvdcsMermaidTheme' {
  It 'takes every color from the design system tokens, in both themes' {
    $light = Get-AvdcsDesignToken -Css $script:css -Theme light
    $dark = Get-AvdcsDesignToken -Css $script:css -Theme dark
    $light['accent'] | Should -Be '#0b7a6e'
    $dark['accent'] | Should -Be '#3cc8b4'
    foreach ($theme in 'light', 'dark') {
      $tokens = Get-AvdcsDesignToken -Css $script:css -Theme $theme
      $values = @($tokens.Values)
      $m = Get-AvdcsMermaidTheme -Css $script:css -Theme $theme
      foreach ($line in @($m.ClassDefs) + @($m.BrokenLink)) {
        foreach ($c in [regex]::Matches($line, '#[0-9a-f]{3,8}')) { $values | Should -Contain $c.Value }
      }
      $init = ($m.Init -replace '^%%\{init: ', '' -replace '\}%%$', '') | ConvertFrom-Json
      foreach ($p in $init.themeVariables.PSObject.Properties) {
        if ($p.Value -is [string]) { $values | Should -Contain $p.Value }
      }
      $init.themeVariables.background | Should -Be $tokens['bg']
    }
  }

  It 'keeps quotes out of the init directive, and fonts and shapes in the page config' {
    $m = Get-AvdcsMermaidTheme -Css $script:css -Theme light
    $m.Init | Should -Not -Match "['\\]"
    $cfg = $m.Config | ConvertFrom-Json
    $cfg.securityLevel | Should -Be 'strict'
    $cfg.themeVariables.fontFamily | Should -Match '^"Source Sans 3"'
    $cfg.themeCSS | Should -Match '\.node rect\{rx:8px;ry:8px\}\.cluster rect\{rx:14px;ry:14px\}'
    @($m.ClassDefs) | Should -Be @(
      'classDef resource fill:#ffffff,stroke:#bfc9d6,color:#152232,stroke-width:1px'
      'classDef hub fill:#e0f2ef,stroke:#0b7a6e,color:#152232,stroke-width:1.5px'
      'classDef spoke fill:#eef2f6,stroke:#bfc9d6,color:#152232,stroke-width:1px'
      'classDef avd fill:#e4edfb,stroke:#1d4785,color:#1d4785,stroke-width:1px'
      'classDef broken fill:#fbe7e7,stroke:#b42323,color:#b42323,stroke-width:1.5px,stroke-dasharray:5 4'
    )
  }
}
