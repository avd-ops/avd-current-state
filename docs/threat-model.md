# Threat model: avd-current-state

> **Personal project, not for production, provided as is, and not affiliated with the author's employer, Liquidware or Microsoft.**

This document records the assets, trust boundaries, identities, and top threats for `avd-current-state` (tracked in [`avd-ops#49`](https://github.com/avd-ops/avd-ops/issues/49) and the family [security review map](https://avd-ops.dev/security.html)). Every mitigation points to the file or test in this repo that enforces it.

## 1. Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| **Raw collector & validator evidence packages** | Operator's local output directory (`~/clouddrive` or private engagement vault) | Contains unredacted subscription IDs, resource names, Conditional Access policies, Intune profiles, and KQL rows; must never leave the operator's private environment |
| **Pseudonymization key** | Operator's local secret (`-KeyPath` / environment variable) | Keyed HMAC-SHA256 secret used to map resource IDs to deterministic pseudonyms (`hp-3fa2c1d0`); whoever holds both the key and the resource list can reverse a pseudonym |
| **Redacted `C11` facts & `C25` Tier 2 benchmark snapshots** | Local output JSON (`avd-current-state-facts/v1`, `avd-benchmark-result/v1`) | Shared with `avd-second-brain` and the assessment portal; must contain only counts, closed enums, public Azure SKUs/regions, banded sample counts, and keyed pseudonyms |
| **Assessment portal state & review artifacts** | `site/portal/` (static HTML/JS in the operator's browser) | Processes intake (`C19`), assessment (`C21`), review (`C23`), and remediation plan (`C24`) JSON locally in the browser |

## 2. Trust boundaries

1. **Collector / Validator scripts vs. Azure & five control planes:** `avd_current_state_collector.ps1` and `avd_deployment_validator.ps1` cross from the operator's shell into Azure Resource Graph, ARM REST (`GET` / Resource Graph query `POST`), Microsoft Graph (`GET`), and Power Platform BAP (`GET`). Every outbound endpoint is cataloged in [`rebuild/scope.json`](../rebuild/scope.json) and verified read-only in CI.
2. **Raw collector output vs. redacted `C11` / `C25` snapshots:** `avd_current_state_facts.ps1` and `lib/AvdBenchmark.psm1` cross the privacy boundary from raw estate data to shareable facts. A strict post-serialization leak scanner refuses to write the output file if any GUID, email address, UNC path, IPv4 address, or domain name remains.
3. **Browser assessment portal vs. GitHub Pages / public issues:** `site/portal/` runs entirely client-side under a strict Content Security Policy with zero telemetry or network uploads. Issue reports pass through `site/portal/assess-core.js` before the user reviews and files them.

## 3. Identities and scopes

| Identity | Type | Scope & permissions | Evidence |
|---|---|---|---|
| **Azure Reader** | Signed-in operator or read-only service principal (`avd_ops_reader.ps1`) | `Reader` (and optionally `Desktop Virtualization Reader` / `Log Analytics Reader`) on target subscriptions; zero write roles | [`README.md`](../README.md), [`avd_ops_reader.ps1`](../avd_ops_reader.ps1), [`rebuild/scope.json`](../rebuild/scope.json) |
| **Microsoft Graph & BAP reader** | Delegated read-only Graph scopes | `Directory.Read.All`, `Policy.Read.All`, `DeviceManagementConfiguration.Read.All`, `DeviceManagementManagedDevices.Read.All`, `CloudPC.Read.All`, `Organization.Read.All`, `Reports.Read.All`; runtime and CI guards reject `.ReadWrite.*` and `.Manage.*` | [`lib/AvdRebuild.psm1`](../lib/AvdRebuild.psm1), [`rebuild/scope.json`](../rebuild/scope.json), [`tests/ReadOnlyGuard.Tests.ps1`](../tests/ReadOnlyGuard.Tests.ps1) |
| **GitHub Actions CI** | Ephemeral workflow runner | `contents: read` (plus `pages: write` / `id-token: write` on `pages.yml` only); never connects to an Azure tenant | [`.github/workflows/test.yml`](../.github/workflows/test.yml), [`.github/workflows/pages.yml`](../.github/workflows/pages.yml) |

## 4. Top threats and mitigations

| Threat | Impact | Mitigation | Evidence |
|---|---|---|---|
| **T1. Collector or validator script gains a mutating cmdlet or non-GET request** | Accidental modification of an inspected customer or lab estate | AST and regex CI guard (`tests/ReadOnlyGuard.Tests.ps1`) scans every `.ps1` and `.psm1` file and fails if any write cmdlet (`Set-Az*`, `New-Az*`, `Remove-Az*`), non-read REST method (outside the Resource Graph query endpoint), or `.ReadWrite.*` Graph scope appears | [`tests/ReadOnlyGuard.Tests.ps1`](../tests/ReadOnlyGuard.Tests.ps1), [`rebuild/scope.json`](../rebuild/scope.json) |
| **T2. Tenant IDs, subscription IDs, resource names, or user UPNs leak into a `C11` or `C25` snapshot** | Private customer identifiers enter a vault or shared artifact | Keyed HMAC-SHA256 pseudonymization replaces identifiers, closed-enum allowlists map unknown strings to `other`, and a post-serialization leak guard refuses to emit any file containing a GUID, email, UNC path, or IPv4 address | [`avd_current_state_facts.ps1`](../avd_current_state_facts.ps1), [`lib/AvdBenchmark.psm1`](../lib/AvdBenchmark.psm1), [`tests/Facts.Tests.ps1`](../tests/Facts.Tests.ps1), [`tests/BenchmarkEvidence.Tests.ps1`](../tests/BenchmarkEvidence.Tests.ps1) |
| **T3. Private values leak through the `AVDCS-STATE` line or assessment portal issue reports** | Operator pastes terminal output into the portal and exposes subscription or storage names | `AVDCS-STATE` carries only counts and pseudonyms (`tests/PortalState.Tests.ps1`), and `site/portal/assess-core.js` strips GUIDs, emails, subscription names, resource groups, storage accounts, and operator-supplied custom terms before building an issue report | [`tests/PortalState.Tests.ps1`](../tests/PortalState.Tests.ps1), [`site/portal/assess-core.js`](../site/portal/assess-core.js), [`tests/portal/assess-core.test.mjs`](../tests/portal/assess-core.test.mjs) |
| **T4. Unverified or tampered assessment method/contracts reach the validator or portal** | Validator evaluates manipulated rules or emits invalid contract files | `assess/PINS.json` and `contracts/PINS.json` pin `avd-assess` by commit SHA, release tag, and SHA-256 manifest digest; CI verifies GitHub build provenance attestation (`gh attestation verify`) and checks every vendored file hash | [`assess/PINS.json`](../assess/PINS.json), [`contracts/PINS.json`](../contracts/PINS.json), [`.github/workflows/test.yml`](../.github/workflows/test.yml), [`tests/Facts.Tests.ps1`](../tests/Facts.Tests.ps1) |
| **T5. Supply-chain drift or secrets committed to git history** | Malicious action tag replacement or accidental credential commit | All GitHub Actions are pinned to 40-character commit SHAs and Gitleaks scans full git history on every push and pull request | [`.github/workflows/secrets.yml`](../.github/workflows/secrets.yml), [`.github/workflows/test.yml`](../.github/workflows/test.yml), [`tests/portal/assess-core.test.mjs`](../tests/portal/assess-core.test.mjs) |
