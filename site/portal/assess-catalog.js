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
    "method": 5,
    "assessCommit": "5c5696cc5050ba216dbe6a8268a4c0a7592b177d",
    "landingZoneCommit": "ae6e80b574cccde570d0053d4c62b519d31052a8",
    "checks": {
      "asm-personal-start-vm-on-connect": {
        "title": "Personal host pools use Start VM on Connect",
        "plane": "azure",
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
        "title": "Pooled host pools have at least two session hosts",
        "plane": "azure",
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
        "title": "Premium file storage is reached through a private endpoint",
        "plane": "azure",
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
        "title": "Premium file storage is zone-redundant",
        "plane": "azure",
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
        "title": "Session hosts run Trusted launch with Secure Boot and vTPM on",
        "plane": "azure",
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
        "title": "Host pools turn drive and USB redirection off",
        "plane": "azure",
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
        "title": "Defender for Cloud's Servers plan is on",
        "plane": "azure",
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
        "title": "Premium file storage allows only GCM SMB channel encryption, AES-128-GCM included",
        "plane": "azure",
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
        "title": "Subscriptions holding AVD have at least one Azure Policy assignment in scope",
        "plane": "azure",
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
        "title": "No policy assignment in scope is left in DoNotEnforce mode",
        "plane": "azure",
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
        "title": "Application groups use group-based assignment with no direct user assignments",
        "plane": "entra",
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
        "title": "Host pools with Entra-joined hosts enable Entra single sign-on",
        "plane": "entra",
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
        "title": "Conditional Access enforces MFA for AVD and Windows Cloud Login",
        "plane": "entra",
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
        "title": "AVD Conditional Access policies exclude emergency-access (break-glass) accounts",
        "plane": "entra",
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
        "title": "Azure Files Entra Kerberos service principal is configured and excluded from MFA CA",
        "plane": "entra",
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
        "title": "Session hosts requesting Intune enrollment are managed in Intune",
        "plane": "intune",
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
        "title": "Intune-managed session hosts have zero noncompliant devices",
        "plane": "intune",
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
        "title": "Intune tenant marks devices without a compliance policy as noncompliant",
        "plane": "intune",
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
        "title": "Intune Settings Catalog delivers an FSLogix profile container policy",
        "plane": "intune",
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
        "title": "Host pools have no orphaned Intune device records for deleted session hosts",
        "plane": "intune",
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
        "title": "OneDrive Silent Account Configuration and Known Folder Move are enabled for session hosts",
        "plane": "m365",
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
        "title": "Microsoft 365 Apps Shared Computer Activation is enabled for multi-session hosts",
        "plane": "m365",
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
        "title": "Microsoft Teams VDI media optimization is enabled for session hosts",
        "plane": "m365",
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
        "title": "Power Platform day-2 workflows run in a dedicated environment outside Default",
        "plane": "power-platform",
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
        "title": "Power Platform DLP policy covers the AVD environment and blocks unapproved connectors",
        "plane": "power-platform",
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
        "title": "Power Platform enterprise policy injects environments into a delegated VNet subnet",
        "plane": "power-platform",
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
      }
    }
  };
});
