BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Export-AvdSecurityPosture.ps1 (C34 from C11)' {
    It 'evaluates a compliant C11 facts bundle as c11-facts with 6 pass and 0 fail' {
        $scriptPath = Join-Path $repoRoot 'Export-AvdSecurityPosture.ps1'
        $c11 = @{
            schema        = 'avd-current-state-facts/v1'
            subscriptions = @(
                @{
                    defenderPlans = @{ VirtualMachines = 'Standard' }
                    policy        = @{ assignments = 6; doNotEnforce = 0 }
                    hostPools     = @(
                        @{
                            redirection  = @{ drives = 'off'; clipboard = 'off'; usb = 'off' }
                            sessionHosts = @{ total = 4; trustedLaunch = 4; encryptionAtHost = 4; edrMissing = 0 }
                        }
                    )
                }
            )
        }

        $report = & $scriptPath -Facts $c11
        $report.schema | Should -Be 'avd-security-posture/v1'
        $report.mode | Should -Be 'c11-facts'
        $report.summary.total | Should -Be 6
        $report.summary.pass | Should -Be 6
        $report.summary.fail | Should -Be 0
        $report.summary.unknown | Should -Be 0
    }

    It 'scores missing C11 telemetry as unknown and failing controls as fail' {
        $scriptPath = Join-Path $repoRoot 'Export-AvdSecurityPosture.ps1'
        $c11 = @{
            schema        = 'avd-current-state-facts/v1'
            subscriptions = @(
                @{
                    defenderPlans = @{ VirtualMachines = 'Free' }
                    policy        = @{ assignments = 0; doNotEnforce = 0 }
                    hostPools     = @(
                        @{
                            redirection  = @{ drives = 'on'; clipboard = 'off'; usb = 'off' }
                            sessionHosts = @{ total = 2; trustedLaunch = 1; encryptionAtHost = $null; edrMissing = 1 }
                        }
                    )
                }
            )
        }

        $report = & $scriptPath -Facts $c11
        $report.summary.total | Should -Be 6
        $report.summary.fail | Should -Be 5
        $report.summary.unknown | Should -Be 1
    }
}
