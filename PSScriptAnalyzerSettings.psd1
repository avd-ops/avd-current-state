# PSScriptAnalyzer settings for the facts snapshot script (used by CI and locally).
@{
  # ParseError is its own severity: without it a script that doesn't parse passes the analyzer.
  Severity     = @('Error', 'Warning', 'ParseError')
  ExcludeRules = @(
    # Console tools; colored Write-Host output is intended.
    'PSAvoidUsingWriteHost'
  )
  # Runs anywhere (avd-ops docs/run-anywhere.md): flag syntax, commands and .NET types missing from
  # Windows PowerShell 5.1 (the README supports it) or from PowerShell 7 on Linux (Cloud Shell, macOS)
  # and Windows. The bundled 7.0 profiles stand in for 7.2 and later.
  Rules        = @{
    PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
    PSUseCompatibleCommands = @{
      Enable         = $true
      TargetProfiles = @(
        'ubuntu_x64_18.04_7.0.0_x64_3.1.2_core'
        'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core'
        'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
      )
      # Write-Log is the scripts' own function (its name is in the union profile); Test-Json is
      # 7.x only and every call is guarded, with a warning on Windows PowerShell.
      IgnoreCommands = @('Write-Log', 'Test-Json')
    }
    PSUseCompatibleTypes    = @{
      Enable         = $true
      TargetProfiles = @(
        'ubuntu_x64_18.04_7.0.0_x64_3.1.2_core'
        'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core'
        'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
      )
    }
  }
}
