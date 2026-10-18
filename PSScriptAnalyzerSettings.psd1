# PSScriptAnalyzer settings for the facts snapshot script (used by CI and locally).
@{
  Severity     = @('Error', 'Warning')
  ExcludeRules = @(
    # Console tools; colored Write-Host output is intended.
    'PSAvoidUsingWriteHost'
  )
}
