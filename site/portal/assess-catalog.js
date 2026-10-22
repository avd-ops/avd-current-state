/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
   assess-catalog.js: what the Plan stage needs from the pinned avd-assess method (assess/method.json, contract C20):
   each check's title, pillar, severity, claims and remediation hint, and the method's version and landing zone
   commit. Copied here because the page makes no network request and Pages publishes only site/;
   tests/portal/assess-core.test.mjs keeps it equal to assess/method.json at the commit in assess/PINS.json. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AssessCatalog = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';
  return {
    "method": 3,
    "assessCommit": "a5f4df1564178e84bc3c52fec123c0c3db59d395",
    "landingZoneCommit": "ae6e80b574cccde570d0053d4c62b519d31052a8",
    "checks": {
      "asm-defender-servers": {
        "title": "Defender for Cloud's Servers plan is on",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#G03.04",
          "ref:avd-security-guide#defender-for-cloud"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "name": "enableDefenderForCloud",
          "to": true
        }
      },
      "asm-drive-usb-redirection-off": {
        "title": "Host pools turn drive and USB redirection off",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#G02.06",
          "ref:avd-security-guide#device-redirection"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "name": "rdpProperties"
        }
      },
      "asm-files-private-endpoint": {
        "title": "Premium file storage is reached through a private endpoint",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#F01.10"
        ],
        "remediation": {
          "kind": "lz-setting",
          "name": "profile-storage-private-endpoint"
        }
      },
      "asm-files-smb-gcm": {
        "title": "Premium file storage allows only GCM SMB channel encryption, AES-128-GCM included",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:mcsb-avd-baseline#DP-3"
        ],
        "remediation": {
          "kind": "lz-setting",
          "name": "profile-storage-smb-gcm"
        }
      },
      "asm-files-zone-redundant": {
        "title": "Premium file storage is zone-redundant",
        "pillar": "reliability",
        "severity": "high",
        "claims": [
          "ref:review-checklists-avd#A03.05",
          "ref:psrule-azure#AZR-000195"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "name": "profileStorageSku",
          "to": "Premium_ZRS"
        }
      },
      "asm-hosts-trusted-launch": {
        "title": "Session hosts run Trusted launch with Secure Boot and vTPM on",
        "pillar": "security",
        "severity": "medium",
        "claims": [
          "ref:review-checklists-avd#G02.03",
          "ref:avd-security-guide#trusted-launch"
        ],
        "remediation": {
          "kind": "manual",
          "code": "rebuild-hosts"
        }
      },
      "asm-personal-start-vm-on-connect": {
        "title": "Personal host pools use Start VM on Connect",
        "pillar": "cost",
        "severity": "low",
        "claims": [
          "ref:review-checklists-avd#E01.05"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "name": "startVmOnConnect",
          "to": true
        }
      },
      "asm-pooled-host-redundancy": {
        "title": "Pooled host pools have at least two session hosts",
        "pillar": "reliability",
        "severity": "medium",
        "claims": [
          "ref:waf-reliability-checklist#RE:05"
        ],
        "remediation": {
          "kind": "lz-parameter",
          "name": "sessionHostCount",
          "to": 2
        }
      }
    }
  };
});
