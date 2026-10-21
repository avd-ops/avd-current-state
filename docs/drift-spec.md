# Spec: drift and conformance checks (report first, fix on approval)

Status: draft v2, 2026-10-21, after a red team (17 findings) and a code review (11 findings), all folded in (section 9). Prior art and design only. Nothing is built, nothing runs in Azure, no spend.

The ask: something run again and again (a script, a pipeline, a scheduled job) that compares a live Azure Virtual Desktop estate with a declared desired state, says what drifted in plain language, and changes nothing until a person approves the fix. No Terraform. Azure and Microsoft tooling, and open source only.

## 0. Answer first

**Recommendation: build a thin drift check here, in avd-current-state, on top of Azure Resource Graph and the rebuild map this repo already has. Adopt nothing new as the engine.** Fixes stay with avd-landing-zone's existing deploy workflow, which already shows a what-if and waits for a person. The declared state is what the landing zone last deployed: the parameters in its deployment record, read as plain Reader.

Why this shape:

1. Nothing outside does the AVD part. No open source tool reads host pools, session hosts, scaling plans and app groups against a *declared* state. PSRule for Azure has one AVD rule. Steampipe has no AVD tables. Prowler and ScoutSuite check generic security posture. Azure Policy can say "this setting must be X", but only for one setting at a time, with no link to the deployment that declared it.
2. The family already has three quarters of it. The collector reads the estate through Resource Graph and REST (`rebuild/scope.json`), `lib/AvdRebuildMap.psm1` maps what it read back to the landing zone's 55 parameters, and `Get-LzRoundTripResult` already shows the pattern for comparing two parameter sets (it reports match or no match without values, so the drift module keeps the values from the map). What's missing is a declared side to compare against, attribution of who changed what, a schedule and a report.
3. Resource Graph is free, reads as plain Reader, and keeps a change log with who made each change (`resourcechanges`, 14 days). The Activity Log covers what that log doesn't (session hosts, role assignments, policy assignments), for 90 days, also free and also Reader. Together they turn "this is different" into "someone changed this in the portal on Tuesday", and they catch changes to settings that no parameter declares.
4. A what-if can't be the nightly check. It needs deployment rights, not Reader. Over Azure Verified Modules it reports changes that aren't real (the brain's operations spec, red-team M8). It also needs the deployment's inputs. It stays where it works: in the fix step, on a pull request.

The smallest version (section 3) is one read-only script plus a sample scheduled workflow for the operator's private repo. It opens or updates one GitHub issue and needs no Azure write access at all.

## 1. Prior art, compared

What "drift" means in each row: **declared** = compared with a state someone wrote down; **baseline** = compared with best practice, not your own declaration; **deploy time** = checks a template before it's deployed and doesn't watch a live estate.

Checked 2026-10-21 on Microsoft Learn, the projects' own pages and package feeds. GitHub search from this environment is blocked, so maintenance comes from releases on PowerShell Gallery and PyPI, and from vendor posts; "not verified" says where that wasn't possible.

### 1.1 Native Azure and Microsoft

| Tool | What it covers in AVD | Drift? | Keyless, CI | License, status | Verdict |
|---|---|---|---|---|---|
| **Azure Resource Graph** (`resources`, `desktopvirtualizationresources`, `resourcechanges`) | Every ARM property of host pools, app groups, workspaces, scaling plans, VMs, NICs, disks, storage, network, policy and role assignments | Live state. `resourcechanges` keeps 14 days of property-level changes with `changedBy`, `clientType` and `operation`, but only for types in the `resources`, `resourcecontainers` and `healthresources` tables: session hosts, role assignments, locks and policy assignments aren't in it | Reader, managed identity or OIDC; REST or CLI | Platform, free | **Use as the engine** |
| **Activity Log** (management events) | Every control-plane write in the subscription, including the types `resourcechanges` skips | Who, when, operation and correlation ID; no property values | Reader; 90 days, free | Platform | **Use as the second attribution source** |
| **Bicep what-if** (`az deployment sub what-if`) | Whatever the template deploys | Declared, but reports noise over modules: `reference()`, secure parameters and nested templates aren't evaluated, and modules short-circuit (Azure Verified Modules known issue) | Needs `Microsoft.Resources/deployments/*` and, by default, write on the resources. `--validation-level ProviderNoRbac` checks only read on each resource, so Reader plus `deployments/*` might be enough: a later option to test, not a Reader job | Platform | **Use in the fix step only**, on a PR |
| **Deployment stacks** | Whatever the stack manages | Declared. Stack what-if filters noise against a baseline recorded at the last deploy (stacks created or updated on or after 2026-08-13). Noise reduction doesn't remove everything (reordered lists still show). Deny settings *prevent* changes, they don't report them | Creating a what-if result is a write (`deploymentStacksWhatIfResults/write`) | Platform | **Later.** The landing zone doesn't deploy as a stack, and moving it is a change to its default deployment (question 3) |
| **Azure Policy** (Audit, AuditIfNotExists, Deny, DeployIfNotExists, Modify) | Built-in AVD definitions cover host pool public network access and private endpoints only; everything else is custom | Baseline rules, evaluated continuously; compliance readable in Resource Graph (`policyresources`) | Reading compliance needs Reader; remediation needs the assignment's own identity with write | Platform, free for Azure resources | **Read compliance; don't author policy for drift.** DeployIfNotExists and Modify fix silently, which is the opposite of report first |
| **Machine Configuration** (formerly guest configuration) | Inside session hosts: registry, services, files, so FSLogix settings and the host security baseline | Declared, three modes: `Audit`, `ApplyAndMonitor`, `ApplyAndAutoCorrect`. Results land in Resource Graph (`guestconfigurationresources`) | Extension and a system-assigned identity on each VM, the package in storage the VMs can reach, Guest Configuration endpoints reachable from private estates; reading results needs Reader | Platform, free on Azure VMs (charged for Arc machines); custom packages GA, authored with the GuestConfiguration module (4.12.0, 2026-06) | **Phase 2 for in-guest drift, Audit mode only** |
| Azure Automation State Configuration | Same as above, older | Declared | Automation account | **Retires 2027-09-30** | No |
| Automanage machine best practices | Onboards VMs to backup, updates, monitoring | Fixes drift from its profile automatically | Automanage account gets Contributor | **Retires 2027-09-30** | No |
| **Defender for Cloud** recommendations | VM, storage, network and identity posture; secure score | Baseline (Microsoft cloud security benchmark, free in Foundational CSPM) | Reader on `securityresources` | Platform; other standards need paid Defender CSPM | **Read** what's already there |
| **Azure Update Manager** | Pending updates per host | Baseline (missing patches) | Reader on `patchassessmentresources` | Platform | **Read** when periodic assessment is on |
| Azure Monitor and AVD Insights | Connection, host and agent health from Log Analytics | Health, not configuration | Log Analytics Reader | Platform | Out of scope; health stays in the validator and the Insights work |
| AVD session host configuration (pooled pools) | Image, size, network and domain join of new hosts | Keeps hosts consistent by rebuilding them on update | AVD service | Platform; pooled pools only, and it replaces the landing zone's way of adding hosts | Prior art for "one declared host shape" |
| **Microsoft Entra Tenant Governance configuration management** (Graph Tenant Configuration Management APIs) | Conditional Access, Entra, Intune, Exchange, Teams, Defender and Purview resources | Declared JSON baseline, monitored every six hours, drift objects per property | Graph app permissions granted to the service's own service principal by a Global or Privileged Role Administrator; reading results is a Graph call | GA, **needs Microsoft Entra ID P1 or above**; limits: 30 monitors, 200 resources per baseline, 800 resource checks a day, fixed six-hour cycle; editing a baseline deletes that monitor's results and drifts | **Phase 3 for Intune and Entra**: read its drift, don't rebuild it |
| Az.DesktopVirtualization module | Host pools, session hosts, app groups | No drift logic, only reads | Az sign-in | MIT, 6.0.1-preview (2026-08) | The family reads REST instead (landing zone decision 0002) |

### 1.2 Microsoft and community AVD tooling

| Tool | Covers | Drift? | Status | Verdict |
|---|---|---|---|---|
| AVD Landing Zone Accelerator (`Azure/avdaccelerator`) and Azure Landing Zones | Deploys AVD and landing zone policy | Deploy time; ALZ policy assignments are Audit and DeployIfNotExists baselines | MIT | Prior art for which policies to read |
| Cloud Adoption Framework AVD scenario | Design guidance | No tool | Docs | Cite, don't restate |
| Azure Review Checklist, AVD checklist (`Azure/review-checklists`) | Review items, some with Resource Graph queries | Baseline, run by hand | MIT, AVD checklist GA | Already mapped in avd-assess; its item IDs stay the crosswalk |
| Azure Quick Review (`azqr`) | Best-practice scan of many services | Baseline | MIT; AVD coverage not verified | Cross-check only, as decided in the shared checks spec |
| Commercial AVD management platforms | Host pool management; vendor pages talk about tenant drift and CIS compliance | No public detail of a host pool drift feature was found | Closed source | **Prior art only.** Nothing copied, no dependency |

### 1.3 Open source

| Tool | Covers | Drift? | Keyless, CI | License, status | Verdict |
|---|---|---|---|---|---|
| **PSRule for Azure** | 500+ Azure rules, **one** AVD rule (`Azure.AVD.ScheduleAgentUpdate`, AZR-000437) | Baseline; templates and live (via exported rule data) | Runs anywhere PowerShell does | MIT; last stable 1.47.0 (2026-01) | **Keep where it is**: the landing zone's CI and `-WellArchitected`. Not a drift engine |
| **Microsoft DSC v3** | Host-side configuration (registry lists from 3.3.0) | Declared `test` and `set` per resource | Local CLI; no scheduler or reporting of its own | MIT; 3.3.0 (2026-09) | Watch: candidate for authoring Machine Configuration content later |
| **Microsoft365DSC** | Intune, Entra, Exchange, Teams | Declared (`Export-`, `Compare-M365DSCConfigurations`, `Assert-M365DSCBlueprint`) | Certificate or app sign-in; heavy module set | MIT; active (2.26.1015.1, 2026-10) | Fallback for Intune and Entra if Tenant Governance doesn't fit; prior art for the baseline format |
| **Maester** | Entra and Microsoft 365 security tests on Pester | Baseline tests, not your declared state | GitHub Actions supported | MIT; 3.0 previews (2026-10) | Prior art for Conditional Access tests; not drift |
| Chef InSpec with `inspec-azure` | Azure resources, generic | Declared controls | Ruby agentless | Code Apache-2.0, but InSpec 6 runs need a license key (free tier: 10 targets, non-commercial) | No: the license tier fails the open-source test |
| Steampipe with the Azure plugin | SQL over Azure APIs | Queries, not drift | Plugin Apache-2.0, core AGPL-3.0 | No AVD tables | No: Resource Graph does this natively |
| Prowler | CIS and other benchmarks for Azure and Microsoft 365 | Baseline | Apache-2.0, active (5.45.0, 2026-10) | No AVD checks | Prior art for posture, not drift |
| ScoutSuite | Multi-cloud posture | Baseline | GPL-2.0; last release 5.14.0 (2024-05) | Stale | No |

### 1.4 What the family already has (reuse, don't rebuild)

| Piece | Where | What it gives drift |
|---|---|---|
| Collector Resource Graph reads, `rebuild/scope.json` | here | The live side: whole ARM objects for 54 types, plus 10 REST reads |
| `Get-LzRebuildMap`, `Get-LzRoundTripResult`, `rebuild/lz-parameters.json` | here (`lib/AvdRebuildMap.psm1`) | Live state as landing zone parameter values, one map per host pool, each with a status (found, derived, secret, deployTime, ambiguous, unexpressible, unknown), and a compare of two parameter sets |
| Validator post-deployment checks | here | Host pool settings, agent and image consistency across hosts, scaling, diagnostics: drift-shaped checks without a declared side |
| Shared check catalog (C22, `lib/AvdChecks.psm1`) | planned here (checks spec merged, not built) | Stable check IDs the drift findings join |
| Reader identity proposal | proposed for this repo, awaiting the owner's decision | An app-only, federated, Reader-only identity for scheduled runs |
| `Export-AvdConfiguration.ps1` | avd-landing-zone | Snapshot-to-snapshot drift of AVD objects, role assignments and budgets, with a normalizer. Covers the settings that have no parameter; phase 1 here doesn't duplicate it (section 2) |
| `Test-AvdLandingZoneReadiness.ps1 -Fix`, `-WellArchitected` | avd-landing-zone | Fixes the tenant steps; PSRule on live resources |
| `bicep snapshot` job | avd-landing-zone CI | File-to-file diff of parameter files on every PR: the "changed but not deployed" question already has a home |
| Auto shutdown runbook (decision 0011) | avd-landing-zone | The landing zone's own state machine: drain, `avd-scaling-exclude` tag, Start VM on Connect off, `avdlz-power-lock`, then resume. Drift must know it (section 3.2) |
| Host security baseline (decision 0018) | avd-landing-zone | In-guest profile with pass, departure and gap outcomes, read by Run Command (a write action) |
| `deploy.yml` with what-if and required reviewers | avd-landing-zone | The approved fix path |
| Operations spec section 4.7 | avd-second-brain | The Evolve design: drift from `resourcechanges`, what-if on PRs only, codify or revert by PR |
| Decision 0026 | avd-second-brain | Health check before work, "the setup is the desired state", a daily check that names the difference, retries only for transient errors |

## 2. What "desired state" means here

Phase 1 answers two questions, and says plainly which one each finding answers:

| Question | Declared side | Live side | Finding |
|---|---|---|---|
| Does a declared setting still hold? | The parameters of the landing zone's last successful subscription deployment, from its deployment record | The collector's read, mapped to parameters by `Get-LzRebuildMap` | **Drift**: "Max sessions per host is 12 in Azure; the last deployment set 8. Changed 2026-10-19 in the Azure portal by a user." |
| Did anything change outside a deployment? | Nothing: any write to a landing zone resource that isn't part of a deployment or of the landing zone's own automation | `resourcechanges` (14 days) and the Activity Log (90 days) | **Unexplained change**: "An NSG rule on the host subnet was added 2026-10-18 from the Azure CLI. No parameter declares NSG rules, so this can't say whether it's wrong." |

The second row is what catches settings the Bicep hard-codes with no parameter (NSG rules, diagnostic settings, RDP properties beyond the parameter, role assignments): phase 1 sees *that* they changed, not whether the new value is right. Comparing whole deployed objects with live ones is the job `Export-AvdConfiguration.ps1` already does in the landing zone, with its own normalizer. Phase 1 doesn't write a second one (question 4).

- **Why the deployment record, not the parameter file.** The record holds the compiled, non-secure parameters, so no Bicep, no template checkout and no other repo is needed at run time, and this repo stays self-contained. "The file changed but nobody deployed it" is a question for the landing zone's CI, whose `bicep snapshot` job already diffs parameter files (question 1). The record doesn't carry the commit today; a later landing zone change can tag deployments with it.
- **Secure parameters** are never read: secrets are always recreated, never carried (rebuild spec section 5.3).
- **Which host pool.** The record declares the landing zone's own host pool, found by its naming convention (`-NamePrefix`, `-Environment`). Other host pools in scope, such as a demo pool, are listed as "not declared", never compared with it.
- **How each map status is compared.** `found` and `derived` values are compared with the record. `secret` and `deployTime` are never compared and are listed under "Not checked". `ambiguous`, `unexpressible` and `unknown` become a `cant-tell` finding, never a pass; a person can acknowledge one with an exception that pins the status instead of a value.
- **Version skew.** The record doesn't say which landing zone version it came from, and the map is pinned to the version in `rebuild/lz-parameters.json`. A parameter in one and not the other is reported once as "not mapped by this version", never as drift.
- **Exceptions** live in `drift-exceptions.json` in the operator's private repo: check ID, resource, the **accepted value** (required), reason, who, expiry. A live value different from the accepted one is drift again, and an expired exception becomes a finding.
- **An estate the landing zone didn't deploy** has no deployment record. Its first run writes the live map as a **proposed baseline** that a person reviews and commits; from then on that file is the declared side. A C14 target-state manifest can be the declared side later (section 7).

## 3. The smallest repeatable version

### 3.1 Pieces

| Piece | Kind | Notes |
|---|---|---|
| `avd_current_state_drift.ps1` | New entry point, read-only | Same sign-in rules as the collector: uses an existing Az context, or the workflow's OIDC login |
| `lib/AvdDrift.psm1` | New module, pure functions | Compare, attribute, classify, render; fixtures that omit empty properties the way ARM does |
| `drift/expected-actors.json` | Reviewed rules, public, placeholders only | Which actors and changes are the landing zone's own (section 3.2 step 4) |
| `drift/runtime-paths.json` | Reviewed list, public | Properties that change at run time and are never drift |
| `checks/catalog.json` | New C22 entries | `drift-param-<name>`, `drift-unexplained-change`, `drift-exception-expired`, `drift-cant-tell`, `drift-window-gap` |
| `samples/drift.yml` | Sample workflow for the operator's **private** repo | Never runs in a public repo |
| Tests | Pester, offline | Fixtures for each finding kind; `System`, `Unknown` and `Unspecified` actors; the power lock cycle; an empty scope; a truncated page; a 429 |

### 3.2 What one run does

1. **Health check first** (decision 0026). Context, the Reader scopes it needs, Resource Graph and the Activity Log reachable, and the declared side present: the deployment record, or the committed baseline for an estate without one. When it runs in GitHub Actions, the repository must be private; a local run in Cloud Shell or on a workstation has no repository and skips that check. A missing piece stops the run with the one command that fixes it.
2. **Read**, all through Resource Graph and REST GETs, with paging followed to the end and throttling retried with backoff (decision 0026 rule 3), printing the remaining quota:
   - the collector's scope (`rebuild/scope.json`) for the landing zone's resource groups;
   - `resourcechanges` for the **full 14 days** every run, deduplicated by change ID, and the Activity Log's write and delete events for the same scopes, for the types `resourcechanges` doesn't cover;
   - `policyresources` (compliance), `securityresources` (Defender recommendations), `patchassessmentresources` (Update Manager), and `guestconfigurationresources` when Machine Configuration is assigned. Each is reported "not available" when empty, never as a pass.
3. **Compare** the deployment's parameters with the live map. Properties in `runtime-paths.json` (power state, `allowNewSession`, agent version, heartbeat, registration info, last-modified stamps) are never compared.
4. **Attribute** every change on a landing zone resource:
   - **Part of a deployment** when its correlation ID matches a landing zone deployment's. Operators deploy with their own sign-in, so matching the person or the deploy identity isn't enough.
   - **The landing zone's own automation** when `expected-actors.json` says so: the auto shutdown runbook's managed identity setting drain mode, the `avd-scaling-exclude` tag, Start VM on Connect and `avdlz-power-lock` (decision 0011); while `avdlz-power-lock` is set, Start VM on Connect off and drained hosts are expected, not drift. Scaling plans and agent updates through the AVD service, and policy remediation by a known assignment, are listed there too.
   - Otherwise **unexplained**, with when, which client and which operation. A user is shown as "a user", with the change's time and correlation ID, so the operator can look the person up in the Activity Log on request. No name or email is written, and no key is needed to hide them. `System`, `Unknown` and `Unspecified` are said as they are.
5. **Classify**: `drift`, `unexplained-change`, `accepted`, `expired-exception`, `cant-tell`, `window-gap`, `posture`, each with a suggested action: **codify** (change the parameter file to match), **revert** (redeploy the declared state), **accept** (add an exception) or **investigate**. Creates and deletes carry no property list in the change log, so they're reported by type only.
6. **Write** `drift-report.md`, `drift-results.json` (C22 shaped, same envelope as the validator) and `manifest.json` to `output/`, with every free-text value (names, tags, actor strings) rendered as a literal, never as Markdown.
7. **Exit** with the worst result: 2 if the run couldn't check (no declared host pool in scope, any read error, a truncated page), else 1 if there are open findings, including unacknowledged `cant-tell`, else 0. Only a 0 may close the issue, and an acknowledged `cant-tell` doesn't hold it open.

**Window gaps.** The run finds when it last succeeded from the workflow's own run history (the Actions API), which survives a closed issue and can't be edited by someone commenting on it; a local run takes `-Since`. When the previous run is older than 14 days, the changes in between can't be attributed from `resourcechanges`; the run says so as a `window-gap` finding and falls back to the Activity Log for that span.

### 3.3 The scheduled workflow (`samples/drift.yml`)

It follows the reader proposal's workflow controls, and a Pester test over the sample checks each one:

- `on: schedule` (daily) and `workflow_dispatch` only. Never `pull_request` or `pull_request_target`.
- `permissions: { id-token: write, contents: read, issues: write }`. `azure/login` with the reader identity's federated credential, an environment limited to the default branch, client and tenant IDs in `vars.*`. No secret.
- A ruleset protects `.github/workflows/**`, because anyone who can edit the workflow can get the reader's token. Actions are pinned by commit SHA; this repo is checked out at a pinned commit; Az modules are pinned and nothing is installed at run time from a gallery.
- The health step checks the repository is private with a real call (`gh api repos/$GITHUB_REPOSITORY --jq .private`), because a scheduled event doesn't reliably carry that field. Public means stop.
- Output goes into **one** issue per environment ("Drift: `<env>`"), edited in place, and to the opt-in private blob container when the operator has one. **Never `upload-artifact`**, and the log prints counts, not names.

### 3.4 The fix, only after approval

The drift identity can't write anything, so no fix can come from it. Each action goes through a path that exists today:

| Action | How | Who approves |
|---|---|---|
| Codify | A PR that changes the parameter file. The landing zone's PR what-if shows the effect | The person who merges, then the person who runs `deploy.yml` |
| Revert | Run the landing zone's `deploy.yml` for that environment with the unchanged file. It shows the what-if and waits on the environment's required reviewers | Required reviewers on the environment |
| Accept | A PR that adds an exception with the accepted value, a reason and an expiry | The person who merges |
| Tenant steps, in-guest | The landing zone's `Test-AvdLandingZoneReadiness.ps1 -Fix`, or a host rebuild from the image | The person who runs it |

- **What-if before every revert.** The deploy that fixes one drift must not quietly change something else. Known what-if noise is suppressed only through a reviewed file (operations spec section 4.7), each entry with the resource type, the property and the evidence.
- **One finding never deploys on its own.** A revert redeploys the whole declared state, so the issue lists every open finding it would touch.
- **No auto-fix:** no DeployIfNotExists or Modify for drift, no `ApplyAndAutoCorrect`, no bot that merges. A later bot may open draft PRs only, and it reads the report's values as data, never as instructions.

### 3.5 Cross-platform

PowerShell 7.2 or later on Cloud Shell (either prompt), Windows, macOS and Linux, with a `platforms.json` entry marked `tested` only with evidence. Operator blocks follow the run-anywhere convention: `pwsh -NoLogo -File ./avd_current_state_drift.ps1 ...` works from both Cloud Shell prompts. No Bicep CLI is needed.

## 4. What it can't see

Said in every report, under "Not checked":

- **Inside session hosts**, until Machine Configuration audit assignments exist: FSLogix registry settings, the host security baseline, local administrators, installed apps, WDOT state. Reader can't run Run Command, by design.
- **Whether a changed undeclared setting is right**: NSG rules, diagnostic settings, role assignments and other values the Bicep hard-codes are seen as *changed*, not judged, in phase 1.
- **Data planes:** file share contents and NTFS permissions, FSLogix containers, Key Vault secrets, registration tokens (a token is an action, not a read).
- **Intune and Entra**, until phase 3. Microsoft Graph is off for the reader by default.
- **Property values for types outside `resourcechanges`** (session hosts, role assignments, locks, policy assignments): the Activity Log gives who and when, not the old and new value.
- **History** older than 14 days for property changes and 90 days for the Activity Log, and changes neither records: data-plane changes and properties that arrive with a new API version.
- **Who**, when the logs say `System`, `Unknown` or `Unspecified`.
- **Anything the landing zone doesn't own:** resources added beside it are listed as "not declared", never judged. Hub networking and DNS it reads but doesn't own.
- **Secure parameters**, never read, so never compared.
- **Whether users are well**: experience and performance are Insights and Stratusphere UX questions, not configuration.

## 5. Identity and rights

- **Audit identity:** the proposed reader (`avd-current-state-reader`): app-only, federated credential on GitHub's immutable subject. **Reader on the subscription**, because a subscription deployment record can't be read with a narrower scope, and the Activity Log is read there too. That widens Resource Graph's view to every resource group, so the script filters to the landing zone's resource groups and says so. An operator who won't grant subscription Reader gets resource-group scope, with no deployment record: the "does a declared setting hold" row then needs a committed baseline (section 2). No Graph in phases 1 and 2.
- **Fix identity:** the landing zone's existing deploy path behind `deploy.yml` and its environment reviewers. Never the same identity, never the same job.
- **Phase 2:** Machine Configuration's identities on each VM belong to the landing zone's deployment (an opt-in parameter), not to the drift check.
- **Phase 3:** reading Tenant Governance drift needs a Graph read permission on the reader: the directory-read decision the reader proposal already leaves to the owner.

## 6. Public and private

| Open source, in this public repo | Private, in the operator's repo only |
|---|---|
| `avd_current_state_drift.ps1`, `lib/AvdDrift.psm1`, `expected-actors.json` and `runtime-paths.json` as rules with placeholders, the C22 entries, `samples/drift.yml`, synthetic fixtures | `drift-exceptions.json`, every report and issue, the identity's IDs (`vars.*`), the real client IDs `expected-actors.json` resolves to |
| Machine Configuration package source for FSLogix and the host baseline (phase 2), parameterized | Anything that names a tenant, subscription, domain, user, host or IP |

Fixtures use `<tenant-id>`, `contoso.com` and `10.x`. Report values never reach C11; if the brain later reads drift, it gets counts and pseudonyms through a C11 change made in three repos together, which this spec doesn't propose.

## 7. Phases

| Phase | Adds | Needs |
|---|---|---|
| 1 | Parameter drift, unexplained changes with attribution, exceptions, posture reads, the issue | The reader identity (owner's decision), subscription Reader, the C22 entries in avd-assess first |
| 2 | In-guest drift from Machine Configuration in `Audit` mode: FSLogix and the host baseline | An opt-in landing zone parameter for the extension, identities and package storage; reachability from private estates; a sandbox run with an estimate and the owner's go |
| 3 | Intune and Entra drift, read from Tenant Governance monitors | Entra ID P1 or above, an admin grant to the service's principal, the directory-read decision |
| Later | Deployed-object compare with the landing zone's normalizer, commit tags on deployments, deployment stacks, a C14 manifest as the declared side, drift facts in C11 | Each its own decision |

Build order for phase 1, each a PR, offline first: (1) C22 entries in avd-assess, pinned here; (2) `lib/AvdDrift.psm1` with fixtures and the two reviewed files; (3) the entry point; (4) `samples/drift.yml` with its tests and checklist; (5) one read-only run against the sandbox estate, which costs nothing in Azure but still waits for the owner's go.

## 8. Cost

Phase 1 adds no Azure spend: Resource Graph, its change log and the Activity Log are free, and every read is control plane. A daily run in a private repo uses a few Actions minutes, inside the free tier. Phase 2: Machine Configuration is free on Azure VMs; the package storage is a few cents a month and gets a written estimate with its sandbox run. Phase 3 needs Entra ID P1 or above (included in Microsoft 365 E3 and Business Premium).

## 9. Red team (Fable, 2026-10-21)

| # | Sev | Finding | Fix in v2 |
|---|---|---|---|
| 1 | High | `resourcechanges` doesn't cover session hosts, role assignments, locks or policy assignments | Activity Log as second source; sections 1.1, 3.2, 4 |
| 2 | High | The file-to-deployment compare needed the landing zone's Bicep at run time, and the record doesn't carry the commit | Declared side is the deployment record; "pending" left to the landing zone's `bicep snapshot`; section 2 |
| 3 | High | The landing zone's auto shutdown and scaling would look like drift every night | `expected-actors.json`, lock-aware rule, `runtime-paths.json`; section 3.2 |
| 4 | High | The sample workflow uploaded artifacts and missed the reader proposal's controls | No `upload-artifact`, ruleset, SHA pins, tests over the sample; section 3.3 |
| 5 | High | Tenant Governance isn't free | Entra ID P1, admin grant, baseline-edit data loss; sections 1.1, 7, 8 |
| 6 | Med | Attribution by identity fails when operators deploy as themselves | Correlation ID first; section 3.2 |
| 7 | Med | The parameter map misses settings with no parameter | Unexplained-change row; object compare left to the landing zone; section 2 |
| 8 | Med | Deployment records need subscription Reader | Said, with the resource-group fallback; section 5 |
| 9 | Med | Empty reads could close the issue as clean | Exit 2 on empty scope, errors, truncation, `cant-tell`; only 0 closes; section 3.2 |
| 10 | Med | "Since the last run" had nowhere to live | Full 14 days every run, last success from the run history, `window-gap`; section 3.2 |
| 11 | Med | Reports carried emails and attacker-controlled text | "A user" plus correlation ID, literal rendering; sections 3.2, 3.4 |
| 12 | Med | Exceptions kept masking after the value changed again | Accepted value required; section 2 |
| 13 | Low | What-if with `ProviderNoRbac` might work on Reader plus `deployments/*` | Noted as an option; section 1.1 |
| 14 | Low | Stack noise reduction isn't complete | Noted; section 1.1 |
| 15 | Low | Machine Configuration's prerequisites were missing | Listed; sections 1.1, 7 |
| 16 | Low | `repository.private` isn't reliable on scheduled events | Real API check; section 3.3 |
| 17 | Low | Repo choice holds only if nothing is fetched at run time | Holds: no Bicep, no checkout of another repo; section 0 |

Claude's code review on the PR then found 11 more (the map's statuses and host pools, `cant-tell` holding the issue open forever, the health check blocking local runs and the baseline path, keyless user hashes, version skew, where the watermark lives, counts). All are fixed in sections 1.4, 2 and 3.2.

## 10. Open questions for the owner

1. **Home:** detector here in avd-current-state, fixes in avd-landing-zone (recommended), or everything in the landing zone?
2. **Reader identity:** the drift check needs the reader proposal decided first, with **subscription** Reader. Yes, or resource-group scope with a committed baseline instead of the deployment record?
3. **Where it runs:** which private repo holds the schedule, the exceptions and the issue for the sandbox estate?
4. **Settings with no parameter** (NSG rules, diagnostics, role assignments): is "changed, not judged" enough for phase 1, or should a later phase reuse the landing zone's `Export-AvdConfiguration` normalizer as a shared function, and in which repo?
5. **Who reviews `expected-actors.json` and the what-if noise file,** since an entry there can hide real drift?
6. **Names in reports:** "a user" plus the correlation ID (recommended), or names in the private issue?
7. **Phase 2 and 3 go or park:** Machine Configuration on session hosts (a landing zone opt-in and a sandbox run), and Tenant Governance (needs Entra ID P1 in the sandbox tenant)?
8. **Deployment stacks:** worth a separate evaluation for the landing zone, given it changes the default deployment?
