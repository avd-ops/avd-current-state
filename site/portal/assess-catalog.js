/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
   assess-catalog.js: what the Plan stage needs from the pinned avd-assess method (assess/method.json, contract C20):
   each check's title, plane, pillar, severity, claims and remediation hint, and the method's version and landing zone
   commit. Copied here because the page makes no network request and Pages publishes only site/;
   tests/portal/assess-core.test.mjs keeps it equal to assess/method.json at the commit in assess/PINS.json. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AssessCatalog = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';
  return {
    "method": 9,
    "assessCommit": "19b9c7e23d4975a6789ea82c3ca3dcb6ec507291",
    "landingZoneCommit": "ae6e80b574cccde570d0053d4c62b519d31052a8",
    "checks": {
      "asm-personal-start-vm-on-connect": {
        "plane": "azure",
        "title": "Personal host pools use Start VM on Connect",
        "pillar": "cost",
        "severity": "low",
        "claims": [
          "ref:review-checklists-avd#E01.05"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "startVmOnConnect",
          "to": true
        }
      },
      "asm-pooled-host-redundancy": {
        "plane": "azure",
        "title": "Pooled host pools have at least two session hosts",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:waf-reliability-checklist#RE:05"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "sessionHostCount",
          "to": 2
        }
      },
      "asm-files-private-endpoint": {
        "plane": "azure",
        "title": "Premium file storage is reached through a private endpoint",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#F01.10"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "profile-storage-private-endpoint"
        }
      },
      "asm-files-zone-redundant": {
        "plane": "azure",
        "title": "Premium file storage is zone-redundant",
        "pillar": "reliability",
        "severity": "high",
        "claims": [
          "ref:review-checklists-avd#A03.05",
          "ref:psrule-azure#AZR-000195"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "profileStorageSku",
          "to": "Premium_ZRS"
        }
      },
      "asm-hosts-trusted-launch": {
        "plane": "azure",
        "title": "Session hosts run Trusted launch with Secure Boot and vTPM on",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#G02.03",
          "ref:avd-security-guide#trusted-launch"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "rebuild-hosts"
        }
      },
      "asm-drive-usb-redirection-off": {
        "plane": "azure",
        "title": "Host pools turn drive and USB redirection off",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#G02.06",
          "ref:avd-security-guide#device-redirection"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "rdpProperties"
        }
      },
      "asm-defender-servers": {
        "plane": "azure",
        "title": "Defender for Cloud's Servers plan is on",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#G03.04",
          "ref:avd-security-guide#defender-for-cloud"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "enableDefenderForCloud",
          "to": true
        }
      },
      "asm-files-smb-gcm": {
        "plane": "azure",
        "title": "Premium file storage allows only GCM SMB channel encryption, AES-128-GCM included",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:mcsb-avd-baseline#DP-3"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "profile-storage-smb-gcm"
        }
      },
      "asm-policy-guardrails-assigned": {
        "plane": "azure",
        "title": "Subscriptions holding AVD have at least one Azure Policy assignment in scope",
        "pillar": "operations",
        "severity": "low",
        "claims": [
          "ref:mcsb-avd-baseline#AM-2"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "enablePolicyGuardrails",
          "to": true
        }
      },
      "asm-policy-enforced": {
        "plane": "azure",
        "title": "No policy assignment in scope is left in DoNotEnforce mode",
        "pillar": "operations",
        "severity": "low",
        "claims": [
          "ref:policy-assignment-structure#do-not-enforce",
          "ref:policy-assignment-structure#do-not-enforce-for-testing"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "process"
        }
      },
      "asm-entra-no-direct-user-rbac": {
        "plane": "entra",
        "title": "Application groups use group-based assignment with no direct user assignments",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:avd-rbac#user-role",
          "ref:caf-avd-identity#groups-not-users",
          "ref:review-checklists-avd#D01.06"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "entra",
          "name": "entra-group-rbac-only"
        }
      },
      "asm-entra-sso-enabled": {
        "plane": "entra",
        "title": "Host pools with Entra-joined hosts enable Entra single sign-on",
        "pillar": "security",
        "severity": "low",
        "claims": [
          "ref:avd-sso#host-pool-property",
          "ref:review-checklists-avd#D03.04"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "enableEntraSso",
          "to": true
        }
      },
      "asm-entra-ca-avd-mfa": {
        "plane": "entra",
        "title": "Conditional Access enforces MFA for AVD and Windows Cloud Login",
        "pillar": "security",
        "severity": "high",
        "claims": [
          "ref:avd-mfa-conditional-access#target-apps",
          "ref:avd-mfa-conditional-access#two-aligned-policies",
          "ref:review-checklists-avd#G04.01"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "entra",
          "name": "deployAvdConditionalAccess",
          "to": true
        }
      },
      "asm-entra-ca-break-glass-excluded": {
        "plane": "entra",
        "title": "AVD Conditional Access policies exclude emergency-access (break-glass) accounts",
        "pillar": "reliability",
        "severity": "high",
        "claims": [
          "ref:ca-require-compliant-device#exclude-break-glass",
          "ref:mcsb-avd-baseline#IM-7"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "entra",
          "name": "ca-exclude-break-glass-group"
        }
      },
      "asm-entra-files-kerberos-ready": {
        "plane": "entra",
        "title": "Azure Files Entra Kerberos service principal is configured and excluded from MFA CA",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:files-entra-kerberos#cloud-only-and-hybrid",
          "ref:files-entra-kerberos#exclude-from-mfa",
          "ref:review-checklists-avd#D02.01"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "entra",
          "name": "entra-kerberos-consent"
        }
      },
      "asm-intune-hosts-managed": {
        "plane": "intune",
        "title": "Session hosts requesting Intune enrollment are managed in Intune",
        "pillar": "operations",
        "severity": "medium",
        "claims": [
          "ref:intune-avd-multisession#enrollment-prerequisites",
          "ref:avd-entra-joined-hosts#enroll-on-deploy"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "intune",
          "name": "intune-mdm-auto-enrollment"
        }
      },
      "asm-intune-hosts-compliant": {
        "plane": "intune",
        "title": "Intune-managed session hosts have zero noncompliant devices",
        "pillar": "security",
        "severity": "high",
        "claims": [
          "ref:intune-avd-multisession#compliance-settings-supported",
          "ref:intune-avd-multisession#compliance-device-targeted"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "intune",
          "name": "intune-session-host-compliance"
        }
      },
      "asm-intune-secure-by-default": {
        "plane": "intune",
        "title": "Intune tenant marks devices without a compliance policy as noncompliant",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:intune-compliance#no-policy-default-compliant",
          "ref:graph-device-management-settings#secure-by-default"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "intune",
          "name": "complianceSecureByDefault",
          "to": true
        }
      },
      "asm-intune-fslogix-catalog-profile": {
        "plane": "intune",
        "title": "Intune Settings Catalog delivers an FSLogix profile container policy",
        "pillar": "operations",
        "severity": "medium",
        "claims": [
          "ref:intune-avd-multisession#settings-catalog-only",
          "ref:intune-avd-multisession#admx-supported"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "intune",
          "name": "intune-settings-catalog-fslogix"
        }
      },
      "asm-intune-no-orphaned-devices": {
        "plane": "intune",
        "title": "Host pools have no orphaned Intune device records for deleted session hosts",
        "pillar": "operations",
        "severity": "low",
        "claims": [
          "ref:intune-avd-multisession#orphaned-records"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "intune",
          "code": "remove-orphaned-devices"
        }
      },
      "asm-m365-onedrive-kfm": {
        "plane": "m365",
        "title": "OneDrive Silent Account Configuration and Known Folder Move are enabled for session hosts",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:onedrive-vdi#silent-config-and-kfm",
          "ref:onedrive-vdi#files-on-demand-vdi"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "m365",
          "name": "enableOneDriveKfm",
          "to": true
        }
      },
      "asm-m365-shared-computer-activation": {
        "plane": "m365",
        "title": "Microsoft 365 Apps Shared Computer Activation is enabled for multi-session hosts",
        "pillar": "cost",
        "severity": "high",
        "claims": [
          "ref:avd-office-image#shared-computer-activation",
          "ref:review-checklists-avd#B01.09"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "m365",
          "name": "enableSharedComputerActivation",
          "to": true
        }
      },
      "asm-m365-teams-vdi-optimization": {
        "plane": "m365",
        "title": "Microsoft Teams VDI media optimization is enabled for session hosts",
        "pillar": "performance",
        "severity": "medium",
        "claims": [
          "ref:teams-on-avd#media-optimization",
          "ref:review-checklists-avd#B01.10"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "m365",
          "name": "enableTeamsVdiOptimization",
          "to": true
        }
      },
      "asm-pp-dedicated-environment": {
        "plane": "power-platform",
        "title": "Power Platform day-2 workflows run in a dedicated environment outside Default",
        "pillar": "operations",
        "severity": "medium",
        "claims": [
          "ref:power-platform-dlp#environment-coverage"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "power-platform",
          "name": "deployDedicatedEnvironment",
          "to": true
        }
      },
      "asm-pp-dlp-blocks-unapproved": {
        "plane": "power-platform",
        "title": "Power Platform DLP policy covers the AVD environment and blocks unapproved connectors",
        "pillar": "security",
        "severity": "high",
        "claims": [
          "ref:power-platform-dlp#connector-groups",
          "ref:power-platform-dlp#default-group-blocked"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "power-platform",
          "name": "power-platform-strict-dlp"
        }
      },
      "asm-pp-vnet-enterprise-policy": {
        "plane": "power-platform",
        "title": "Power Platform enterprise policy injects environments into a delegated VNet subnet",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:power-platform-vnet#enterprise-policy-subnet",
          "ref:power-platform-vnet#delegated-subnet-egress"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "power-platform",
          "name": "enableVnetEnterprisePolicy",
          "to": true
        }
      },
      "asm-insights-rtt-target": {
        "plane": "azure",
        "title": "AVD Insights p95 round-trip latency stays under 150 ms",
        "pillar": "performance",
        "severity": "medium",
        "claims": [
          "ref:avd-prerequisites#rtt-under-150",
          "ref:avd-insights-use-cases#rtt-ideal-100-poor-200"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "outside-landing-zone"
        }
      },
      "asm-insights-input-delay-target": {
        "plane": "azure",
        "title": "AVD Insights p95 user input delay stays within the 100 ms acceptable band",
        "pillar": "performance",
        "severity": "medium",
        "claims": [
          "ref:avd-insights-glossary#input-delay-bands",
          "ref:avd-insights-use-cases#input-delay-host-100"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "maxSessionLimit"
        }
      },
      "asm-insights-time-to-connect": {
        "plane": "azure",
        "title": "AVD Insights p95 time to connect stays under 30 seconds",
        "pillar": "performance",
        "severity": "low",
        "claims": [
          "ref:avd-insights-glossary#time-to-connect-stages",
          "ref:avd-insights-workbooks#queries-define-measures"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "process"
        }
      },
      "asm-insights-connection-reliability": {
        "plane": "azure",
        "title": "AVD Insights connection failure rate stays at or below 5 percent",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:avd-insights-workbooks#queries-define-measures",
          "ref:diagnostics-log-analytics#connection-states"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "process"
        }
      },
      "asm-hosts-accelerated-networking": {
        "plane": "azure",
        "title": "Session host NICs enable accelerated networking",
        "pillar": "performance",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#C01.13",
          "ref:accelerated-networking#lower-latency-jitter-cpu"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "session-host-accelerated-networking"
        }
      },
      "asm-hosts-encryption-at-host": {
        "plane": "azure",
        "title": "Session hosts enable encryption at host",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#G02.02",
          "ref:disk-encryption-options#encryption-at-host"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "encryptionAtHost",
          "to": true
        }
      },
      "asm-hosts-premium-os-disk": {
        "plane": "azure",
        "title": "Session hosts run on Premium SSD or ephemeral OS disks",
        "pillar": "performance",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#H03.01",
          "ref:avd-deploy-host-pool#premium-ssd-os-disk"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "session-host-premium-os-disk"
        }
      },
      "asm-hosts-zone-redundant": {
        "plane": "azure",
        "title": "Session hosts are pinned to availability zones",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#A01.04",
          "ref:waf-reliability-checklist#RE:05"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "availabilityZones"
        }
      },
      "asm-hostpool-diagnostics-enabled": {
        "plane": "azure",
        "title": "Host pools forward required diagnostic log categories to a workspace",
        "pillar": "operations",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#E02.02",
          "ref:review-checklists-avd#G03.05",
          "ref:avd-insights#hostpool-diagnostics"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "deploySubscriptionSettings",
          "to": true
        }
      },
      "asm-hosts-insights-agent": {
        "plane": "azure",
        "title": "Session hosts have the Azure Monitor Agent and AVD Insights DCR associated",
        "pillar": "operations",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#E02.01",
          "ref:avd-insights#host-data-ama-dcr"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "session-host-ama-insights-dcr"
        }
      },
      "asm-pooled-autoscale-attached": {
        "plane": "azure",
        "title": "Pooled host pools have an active AVD scaling plan attached",
        "pillar": "cost",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#E01.04",
          "ref:aprl-desktop-virtualization#499769ae-67c9-492e-9ca5-cfd4cece5209",
          "ref:avd-autoscale#scales-to-save-cost"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "hostpool-scaling-plan"
        }
      },
      "asm-hostpool-scheduled-agent-updates": {
        "plane": "azure",
        "title": "Host pools configure a maintenance window for scheduled agent updates",
        "pillar": "operations",
        "severity": "low",
        "claims": [
          "ref:review-checklists-avd#E01.10",
          "ref:aprl-desktop-virtualization#979ff8be-5f3a-4d8e-9aa3-407ecdd6d6f7",
          "ref:psrule-azure#AZR-000437"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "hostpool-scheduled-agent-updates"
        }
      },
      "asm-files-smb-multichannel": {
        "plane": "azure",
        "title": "Premium Azure Files profile storage enables SMB Multichannel",
        "pillar": "performance",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#H01.02",
          "ref:azure-files-smb#multichannel-ssd-only"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "profile-storage-smb-multichannel"
        }
      },
      "asm-files-backup-protected": {
        "plane": "azure",
        "title": "Premium Azure Files profile storage is protected by Azure Backup",
        "pillar": "reliability",
        "severity": "high",
        "claims": [
          "ref:review-checklists-avd#A03.02",
          "ref:azure-files-backup#snapshot-and-vaulted"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "enableProfileBackup",
          "to": true
        }
      },
      "asm-intune-assignment-filters-separate-platforms": {
        "plane": "intune",
        "title": "Intune assignment filters separate multi-session AVD hosts, Cloud PCs and physical endpoints",
        "pillar": "operations",
        "severity": "high",
        "claims": [
          "ref:windows-365-intune#assignment-filters-separate-platforms",
          "ref:intune-avd-multisession#settings-catalog-only"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "intune",
          "name": "intune-platform-assignment-filters"
        }
      },
      "asm-win365-sso-enabled": {
        "plane": "intune",
        "title": "Windows 365 provisioning policies enable Microsoft Entra single sign-on",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:windows-365-intune#provisioning-policy-sso"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "intune",
          "name": "win365EnableSingleSignOn",
          "to": true
        }
      },
      "asm-win365-no-local-admin": {
        "plane": "intune",
        "title": "Windows 365 user settings policies disable local administrator rights on Cloud PCs",
        "pillar": "security",
        "severity": "high",
        "claims": [
          "ref:windows-365-intune#user-settings-least-privilege"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "intune",
          "name": "win365-disable-local-admin"
        }
      },
      "asm-win365-restore-points-configured": {
        "plane": "intune",
        "title": "Windows 365 user settings configure automatic point-in-time restore points every 12 hours or less",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:windows-365-intune#restore-point-cadence"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "intune",
          "name": "win365RestorePointFrequencyHours",
          "to": 6
        }
      },
      "asm-win365-anc-healthy": {
        "plane": "intune",
        "title": "Windows 365 Azure Network Connections pass all health checks",
        "pillar": "reliability",
        "severity": "high",
        "claims": [
          "ref:windows-365-intune#anc-health-checks"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "intune",
          "name": "win365-anc-health-check"
        }
      },
      "asm-win365-cloudpcs-compliant": {
        "plane": "intune",
        "title": "Intune-managed Windows 365 Cloud PCs have zero noncompliant devices",
        "pillar": "security",
        "severity": "high",
        "claims": [
          "ref:windows-365-intune#cloudpc-intune-compliance",
          "ref:intune-compliance#no-policy-default-compliant"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "intune",
          "name": "intune-cloudpc-compliance"
        }
      },
      "asm-personal-deallocation": {
        "plane": "azure",
        "title": "Personal host pools with Start VM on Connect have a scaling plan attached",
        "pillar": "cost",
        "severity": "low",
        "claims": [
          "ref:review-checklists-avd#E01.06",
          "ref:start-vm-on-connect-faq#no-automatic-deallocation",
          "ref:avd-autoscale#hibernate-personal"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "hostpool-scaling-plan"
        }
      },
      "asm-cost-allocation-tags": {
        "plane": "azure",
        "title": "Host pools and session hosts carry cost allocation tags",
        "pillar": "cost",
        "severity": "low",
        "claims": [
          "ref:review-checklists-avd#E01.07",
          "ref:avd-tagging#tag-host-pools-first",
          "ref:avd-tagging#cm-resource-parent"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "tags"
        }
      },
      "asm-cost-budget-action-group": {
        "plane": "azure",
        "title": "Subscriptions configure a cost budget wired to an action group",
        "pillar": "cost",
        "severity": "medium",
        "claims": [
          "ref:waf-cost-optimization-checklist#CO:03",
          "ref:cost-management-budgets#alerts-dont-stop",
          "ref:cost-management-budgets#action-group-scopes"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "autoShutdownBudgetAction",
          "to": "Lock"
        }
      },
      "asm-cost-no-unattached-disks": {
        "plane": "azure",
        "title": "Subscriptions have zero unattached managed disk cost recommendations",
        "pillar": "cost",
        "severity": "low",
        "claims": [
          "ref:advisor-cost#unattached-disks",
          "ref:waf-cost-optimization-checklist#CO:07"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "outside-landing-zone"
        }
      },
      "asm-cost-advisor-rightsize-reviewed": {
        "plane": "azure",
        "title": "Subscriptions review Azure Advisor VM right-size and shutdown cost recommendations",
        "pillar": "cost",
        "severity": "low",
        "claims": [
          "ref:advisor-cost#right-size-or-shutdown-vms",
          "ref:waf-cost-optimization-checklist#CO:07"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "process"
        }
      },
      "asm-cost-commitment-floor-reviewed": {
        "plane": "azure",
        "title": "Subscriptions review Azure Advisor VM reservation and compute savings plan recommendations against the running-host floor",
        "pillar": "cost",
        "severity": "low",
        "claims": [
          "ref:reservations#hourly-billing-discount",
          "ref:advisor-cost#vm-reservations",
          "ref:advisor-cost#savings-plan",
          "ref:commitment-choice#right-size-first",
          "ref:waf-cost-optimization-checklist#CO:05"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "process"
        }
      },
      "asm-hosts-zone-spread": {
        "plane": "azure",
        "title": "Host pools with at least two session hosts spread them across two or more availability zones",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:avd-multiregion-bcdr#spread-and-overprovision",
          "ref:availability-zones#zonal-needs-multiple",
          "ref:review-checklists-avd#A01.04"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "availabilityZones"
        }
      },
      "asm-pooled-hosts-not-backed-up": {
        "plane": "azure",
        "title": "Pooled host pools do not back up stateless session host VMs with Azure Backup",
        "pillar": "reliability",
        "severity": "low",
        "claims": [
          "ref:caf-avd-bcdr#hosts-stateless-no-vm-backup",
          "ref:review-checklists-avd#A03.03"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "outside-landing-zone"
        }
      },
      "asm-personal-hosts-replicated": {
        "plane": "azure",
        "title": "Personal host pools protect every session host with Azure Site Recovery",
        "pillar": "reliability",
        "severity": "high",
        "claims": [
          "ref:avd-multiregion-bcdr#personal-site-recovery",
          "ref:review-checklists-avd#A03.04"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "outside-landing-zone"
        }
      },
      "asm-image-replicated": {
        "plane": "azure",
        "title": "Host pools backed by Azure Compute Gallery replicate image versions to at least two regions",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:avd-multiregion-bcdr#image-in-both-regions",
          "ref:compute-gallery#versioning-and-replication",
          "ref:review-checklists-avd#A03.01"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "outside-landing-zone"
        }
      },
      "asm-profile-backup-ran": {
        "plane": "azure",
        "title": "Protected Azure Files profile storage accounts have a succeeded most recent backup job",
        "pillar": "reliability",
        "severity": "high",
        "claims": [
          "ref:azure-files-backup#snapshot-and-vaulted",
          "ref:review-checklists-avd#A03.02"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "enableProfileBackup",
          "to": true
        }
      },
      "asm-profile-backup-offsite": {
        "plane": "azure",
        "title": "Azure Files profile storage accounts use vaulted Azure Backup so backups survive storage account loss",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:azure-files-backup#vaulted-survives-source-loss",
          "ref:review-checklists-avd#A03.02"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "plane": "azure",
          "name": "enableProfileBackup",
          "to": true
        }
      },
      "asm-hosts-edr-present": {
        "plane": "azure",
        "title": "Session hosts report a healthy endpoint protection and EDR assessment in Defender for Cloud",
        "pillar": "security",
        "severity": "high",
        "claims": [
          "ref:defender-cloud-edr-detection#agentless-edr-check",
          "ref:avd-security-guide#edr-microsoft-or-third-party",
          "ref:review-checklists-avd#G03.01"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "outside-landing-zone"
        }
      },
      "asm-hosts-vulnerability-assessment": {
        "plane": "azure",
        "title": "Session hosts report zero unhealthy Defender for Cloud vulnerability assessment findings",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:defender-compute-recommendations#vm-recommendations",
          "ref:mcsb-avd-baseline#PV-6"
        ],
        "remediation": {
          "kind": "manual",
          "plane": "azure",
          "code": "process"
        }
      },
      "asm-hosts-no-public-rdp": {
        "plane": "azure",
        "title": "Session host NSGs have zero rules allowing inbound TCP or UDP 3389 from the internet",
        "pillar": "security",
        "severity": "high",
        "claims": [
          "ref:mcsb-avd-baseline#NS-2",
          "ref:review-checklists-avd#F01.04"
        ],
        "remediation": {
          "kind": "lz-setting",
          "plane": "azure",
          "name": "session-host-nsg-no-public-rdp"
        }
      }
    }
  };
});
