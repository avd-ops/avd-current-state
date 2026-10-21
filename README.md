# AVD Tooling for Azure Commercial

Part of [avd-ops](https://avd-ops.dev/), the open toolkit for Azure Virtual Desktop.

Read-only PowerShell tooling for Azure Virtual Desktop (AVD) environments on Azure
Commercial. The collector and validator read through Azure Resource Manager and write
nothing. Their evidence packages feed [avd-second-brain](https://github.com/avd-ops/avd-second-brain), which turns them into a
living knowledge base of the estate.

> [!WARNING]
> **Personal project. Research and learning only. Not for production. No warranty.**
>
> - This is my own personal project, built on my own time **for research and learning**. It is **not affiliated with, endorsed by or supported by my employer**, and it does not represent my employer's views, products or guidance. It is not an official Microsoft product, and it is not a certified or supported tool.
> - The scripts only read, but review the code and try them on a lab subscription first, before pointing them at subscriptions that matter. Their output is not a production-readiness certification, a compliance attestation or a security audit.
> - It is provided **"as is", without warranty of any kind**, under the [MIT License](LICENSE). You use it at your own risk. You are responsible for where you run it and for what you do with its output.
> - **Contributions and forks are welcome and encouraged.** See [Contributing](#contributing).

| Script | When to run | What it answers |
|---|---|---|
| [`avd_current_state_collector.ps1`](#current-state-collector) | Any time | *What is in this environment today?* Produces a portable evidence package. |
| [`avd_deployment_validator.ps1`](#deployment-validator) | Before and after an AVD deployment | *Is this subscription ready to deploy, and did the deployment land correctly?* Produces a pass/fail report. |
| [`avd_current_state_facts.ps1`](#facts-snapshot-for-the-brain-and-avd-swarm) | After a collector or validator run | *What can the brain's agents know about this estate?* Turns the packages into one redacted facts snapshot: counts, public values and pseudonyms, no names or IDs. |
| [`avd_second_brain.ps1`](#second-brain) (in [avd-second-brain](https://github.com/avd-ops/avd-second-brain)) | After every collector or validator run | *What changed, what is still broken, and why is it built this way?* Keeps a Markdown knowledge base of the estate over time. |

## Read-Only by Design

The collector and validator perform discovery only (the facts script reads only local files):

- They call `Get-*` and `Test-*` cmdlets exclusively, and never invoke `New-*`, `Set-*`,
  `Update-*`, `Add-*`, `Remove-*`, `Restart-*`, `Start-*` or `Stop-*` against an Azure resource.
- The collector reads through Azure Resource Graph and REST `GET` requests with
  `Invoke-AzRestMethod`. A Resource Graph query is sent as a `POST`, the one exception, and it
  only reads. Every request the collector makes is listed in [`rebuild/scope.json`](rebuild/scope.json).
- The one `Set-AzContext` call selects the target subscription. It changes local PowerShell
  session state, not Azure.
- Files are written only inside the local output folder.
- The validator's opt-in `-IncludeNetworkProbe` opens a TCP socket to each AVD required
  endpoint and closes it immediately. No payload is sent.

Neither script is a production-readiness certification, a compliance attestation, or a
security audit.

## Prerequisites

- **PowerShell 5.1+** (Windows PowerShell) or **PowerShell 7+** (cross-platform)
- **Azure identity** with at least **Reader** on the target subscriptions
  - `Desktop Virtualization Reader` is recommended for full AVD session host enumeration
  - No write role is needed by either script
- **Internet access** to the PowerShell Gallery, only if the Az modules are not pre-installed

## Az Modules

Missing modules are installed from PSGallery automatically. The exact versions used are
recorded in every output package.

| Module | Collector | Validator | Purpose |
|---|---|---|---|
| Az.Accounts | Required | Required | Authentication, subscription and context management; the collector's Resource Graph and REST reads (`Invoke-AzRestMethod`) |
| Az.Resources | Required | Required | Policy and role assignments (collector); resource groups, ARM resources, locks, providers (validator) |
| Az.Compute | — | Required | Virtual machines and extensions; VM SKU catalog and gallery images |
| Az.Network | — | Required | VNets, subnets, NSGs, route tables, public IPs, private endpoints |
| Az.Storage | — | Required | Storage accounts; Azure Files shares |
| Az.DesktopVirtualization | — | Required | Host pools, workspaces, application groups, session hosts |
| Az.OperationalInsights | — | Optional | Log Analytics workspaces |
| Az.RecoveryServices | — | Optional | Recovery Services vaults; backup coverage |
| Az.Monitor | — | Optional | Diagnostic settings |

If one of the validator's **optional** modules is unavailable, only its own checks report
`SKIP` and the run continues.

## Azure Cloud Shell

Both scripts detect Cloud Shell automatically:

- **Output defaults to `~/clouddrive/`** so the package survives the session. Override with `-OutputPath`.
- **Authentication is pre-established** — the existing context is detected and the login prompt skipped.
- **Az modules are pre-installed** — already-available modules are not reinstalled.

```powershell
# Upload the script via Cloud Shell's file upload, then:
./avd_current_state_collector.ps1
```

Output appears under `~/clouddrive/`, downloadable from the Cloud Shell file browser or via
the `download` command.

> **Timeout note:** Cloud Shell sessions idle-timeout after 20 minutes. Collection activity
> keeps the session alive, but avoid backgrounding the browser tab mid-run.

---

## Current State Collector

`avd_current_state_collector.ps1` inventories an Azure environment from an **AVD
perspective** and produces a portable evidence package with a stakeholder-ready summary.

### What It Does

Authenticates, discovers subscriptions, validates read access, and inventories AVD workload
resources plus supporting platform infrastructure. It produces:

- Per-subscription **CSV and JSON** evidence files for every collected dataset
- Per-subscription **`rebuild/`** folder: the full Azure objects a landing zone rebuild needs, one JSON file per resource type (`rebuild/resources/`) and per REST read (`rebuild/rest/`), as listed in [`rebuild/scope.json`](rebuild/scope.json). The CSV and JSON datasets are built from the same rows. Secrets (registration tokens, keys, signed URLs, protected parameters) are never written; a rebuild recreates them, and a final scan refuses to write a file that still looks like one. `rebuild/rebuild-map.json` maps each host pool onto the avd-landing-zone parameters (pinned in [`rebuild/lz-parameters.json`](rebuild/lz-parameters.json)), each with a status (found, derived, secret, deployTime, ambiguous, unexpressible, unknown), its value and its evidence; it holds names and IDs, so it stays in the private package. See [docs/rebuild-fidelity-spec.md](docs/rebuild-fidelity-spec.md)
- A **summary.md** with executive summary, AVD workload overview, architecture observations, and stakeholder takeaways
- A **manifest.json** documenting package contents, subscription outcomes, and collection metadata
- Az module version records (**az-module-versions.csv** / **az-module-versions.json**)
- A final **ZIP archive** of the entire evidence package

It is a current-state inventory tool, not a target-state gap analysis or design
recommendation engine.

### Usage

#### Default — all subscriptions

```powershell
.\avd_current_state_collector.ps1
```

Discovers and inventories **every enabled subscription** visible to the authenticated
identity. No subscription names are required.

#### Filter by subscription name

```powershell
.\avd_current_state_collector.ps1 -SubscriptionNames "Subscription-A", "Subscription-B"
```

Names that are not found or not enabled produce a warning and are skipped.

#### Custom output location

```powershell
.\avd_current_state_collector.ps1 -OutputPath "C:\Evidence"
```

#### Combined

```powershell
.\avd_current_state_collector.ps1 -SubscriptionNames "Subscription-A" -OutputPath "D:\Assessments"
```

### Run Sequence

1. Detects Azure Cloud Shell and defaults output to `~/clouddrive/` for persistence
2. Authenticates to Azure Commercial (`AzureCloud`) — prompts for login only if no active context exists
3. Discovers all enabled subscriptions visible to the identity
4. Validates lightweight read access per subscription before full collection
5. Skips inaccessible subscriptions with a warning, without halting the run
6. Collects all datasets per accessible subscription
7. Generates the summary, manifest and ZIP

### Output Package

```
avd-current-state-20260617T143022/
├── az-module-versions.csv
├── az-module-versions.json
├── summary.md
├── manifest.json
├── Subscription_A/
│   ├── resource-groups.csv / .json
│   ├── arm-resources.csv / .json
│   ├── virtual-networks.csv / .json
│   ├── subnets.csv / .json
│   ├── nsgs.csv / .json
│   ├── nsg-rules.csv / .json
│   ├── route-tables.csv / .json
│   ├── public-ips.csv / .json
│   ├── virtual-machines.csv / .json
│   ├── vm-extensions.csv / .json
│   ├── storage-accounts.csv / .json
│   ├── key-vaults.csv / .json
│   ├── log-analytics-workspaces.csv / .json
│   ├── recovery-services-vaults.csv / .json
│   ├── private-endpoints.csv / .json
│   ├── policy-assignments.csv / .json
│   ├── role-assignments.csv / .json
│   ├── avd-host-pools.csv / .json
│   ├── avd-workspaces.csv / .json
│   ├── avd-application-groups.csv / .json
│   └── avd-session-hosts.csv / .json
├── Subscription_B/
│   └── (same structure)
└── avd-current-state-20260617T143022.zip
```

### Collected Datasets

#### AVD workload (primary)

| Dataset | Description |
|---|---|
| avd-host-pools | Host pool type, load balancer, session limits, validation flag, Start VM on Connect, RDP properties |
| avd-workspaces | Workspace names, friendly names, linked application groups |
| avd-application-groups | App group type, linked host pool, friendly name |
| avd-session-hosts | Per-host-pool session hosts with status, agent version, OS version, heartbeat, assigned user |

#### Supporting platform

| Dataset | Description |
|---|---|
| resource-groups | All resource groups with location, state, tags |
| arm-resources | Full ARM resource inventory (type, location, resource group, tags) |
| virtual-networks | Address spaces, DNS, subnet count, DDoS protection |
| subnets | Address prefixes, NSG/route table associations, service endpoints, delegations |
| nsgs | Network security groups with rule counts |
| nsg-rules | Individual security rules (direction, priority, access, protocol, source/destination) |
| route-tables | UDR configuration including BGP propagation and route summaries |
| public-ips | Allocation method, SKU, associated resource |
| virtual-machines | Size, OS, image reference, power state, data disks, extensions, tags |
| vm-extensions | Per-VM extensions with publisher, type, version, provisioning state |
| storage-accounts | Kind, SKU, access tier, TLS, public access, network rules, large file shares |
| key-vaults | Soft delete, purge protection, SKU |
| log-analytics-workspaces | SKU, retention, customer ID |
| recovery-services-vaults | Vault type, provisioning state |
| private-endpoints | Subnet, VNet, target resource, group IDs, connection status |
| policy-assignments | Display name, definition, scope, enforcement mode |
| role-assignments | Principal, role, scope, object type |

---

## Deployment Validator

`avd_deployment_validator.ps1` answers two questions with a structured pass/fail report:

- **Preflight** — is this subscription, region, network, storage, image and policy posture
  ready to *receive* an AVD deployment? Run it **before** you deploy.
- **PostDeployment** — did the deployment actually land correctly? Run it **after** you deploy.

Both modes live in one script so they share the same check framework, report format and
evidence package. Use `-Mode Both` to run them back to back.

The checks are becoming one definition that avd-landing-zone carries as a pinned copy and adds its
fixes to, with the avd-assess method running through the same evaluator
([spec](docs/checks-spec.md)).

Every parameter except `-Mode` is optional. Checks whose inputs are missing report `SKIP`
with a note on what to supply, so a bare `.\avd_deployment_validator.ps1` still runs and
tells you what it could not evaluate.

### Usage

#### Preflight — before deploying

```powershell
.\avd_deployment_validator.ps1 -Mode Preflight `
    -Location eastus2 `
    -ResourceGroupName rg-avd-prod `
    -VirtualNetworkName vnet-avd -SubnetName snet-avd-hosts `
    -SessionHostCount 20 -SessionHostVmSize Standard_D4ads_v5 `
    -StorageAccountName stavdfslogix01 -FileShareName profiles `
    -LogAnalyticsWorkspaceName law-avd `
    -DomainName contoso.com
```

#### Post-deployment — after deploying

```powershell
.\avd_deployment_validator.ps1 -Mode PostDeployment `
    -ResourceGroupName rg-avd-prod `
    -HostPoolName hp-avd-prod `
    -SessionHostCount 20 `
    -StorageAccountName stavdfslogix01 -FileShareName profiles `
    -SubnetName snet-avd-hosts
```

Omit `-HostPoolName` to validate **every** host pool in the subscription.

#### Both phases from a config file

```powershell
.\avd_deployment_validator.ps1 -ConfigPath .\avd-validation.config.json
```

Copy [`avd-validation.config.example.json`](avd-validation.config.example.json) as a
starting point. Any config key can be overridden on the command line — explicit parameters
always win. Keys beginning with `_` are treated as comments.

### Parameters

| Parameter | Mode | Purpose |
|---|---|---|
| `-Mode` | both | `Preflight` (default), `PostDeployment`, or `Both` |
| `-SubscriptionName` / `-SubscriptionId` | both | Subscription to validate. Defaults to the current context |
| `-Location` | preflight | Session host region. Drives region, SKU, quota and image replication checks |
| `-MetadataLocation` | preflight | AVD control plane region. Defaults to `-Location` |
| `-ResourceGroupName` | both | Target resource group / host pool resource group |
| `-VirtualNetworkName`, `-VirtualNetworkResourceGroup`, `-SubnetName` | preflight | Session host network |
| `-SessionHostCount` | both | Planned (preflight) or expected (post-deployment) host count |
| `-SessionHostVmSize` | preflight | Planned VM size, e.g. `Standard_D4ads_v5` |
| `-HostPoolName`, `-WorkspaceName`, `-ApplicationGroupName` | both | Naming collision check (preflight); validation scope (post-deployment) |
| `-StorageAccountName`, `-StorageAccountResourceGroup`, `-FileShareName` | both | FSLogix profile storage |
| `-LogAnalyticsWorkspaceName`, `-LogAnalyticsResourceGroup` | preflight | Expected diagnostics destination |
| `-ImageId` | preflight | Compute Gallery image version or definition resource ID |
| `-DomainName` | both | AD DS domain. Enables DNS and LDAP checks |
| `-MaxHeartbeatAgeMinutes` | post | Heartbeat staleness threshold. Default `30` |
| `-IpBufferPercent` | preflight | Subnet IP headroom on top of `-SessionHostCount`. Default `20` |
| `-IncludeNetworkProbe` | both | Opt in to outbound TCP endpoint probes |
| `-ConfigPath` | both | JSON file supplying any of the above |
| `-OutputPath` | both | Report package parent directory |
| `-SkipZip` | both | Do not create a ZIP archive |
| `-FailOnWarning` | both | Return exit code 1 on `WARN` as well as `FAIL` |
| `-PassThru` | both | Emit result objects to the pipeline |

### Result Statuses

| Status | Meaning |
|---|---|
| `FAIL` | Will block deployment, or is actively broken |
| `WARN` | Works, but carries operational or resilience risk |
| `PASS` | Validated as expected |
| `INFO` | Recorded for context; no action implied |
| `SKIP` | Not evaluated — a required input or optional module is missing |

**Exit codes:** `0` = no failures · `1` = one or more `FAIL` (or `WARN` with `-FailOnWarning`)
· `2` = the validator could not run (authentication or subscription resolution failed).

### Preflight Checks

| Category | Checks |
|---|---|
| Identity | Azure Commercial environment, subscription state, Reader access, deployment role coverage, Desktop Virtualization power management role |
| Providers | Registration state of the required and recommended resource providers |
| Region | Target region availability, AVD metadata region support (read live from the resource provider) |
| Capacity | VM SKU availability and restrictions, availability zone support, Hyper-V generation, per-family vCPU quota, total regional vCPU quota, network interface quota. On a family quota failure it names the families in the region that do have headroom, and it warns when the regional ceiling is passed by less than one more host |
| Resource group | Existence, and `ReadOnly` locks that would block deployment |
| Policy | Allowed-locations and allowed-SKU policies compared against the target, deny-effect sweep that expands initiatives and resolves parameterized effects, DoNotEnforce assignments reported apart |
| Network | VNet existence and region match, custom DNS for domain join, peering health, subnet existence, usable IP capacity vs. host count plus buffer, subnet delegation, outbound egress path (NAT gateway / forced tunneling / no default route), NSG rules that would block outbound 443 to the AVD control plane |
| Storage | Account existence, premium tier, identity-based authentication, minimum TLS, large file shares, storage firewall reachability from the session host subnet, file share existence and quota |
| Image | Gallery image version existence, replication into the target region, end-of-life date, generalized OS state, and the [WDOT](https://github.com/The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool) pin the version records (the `avdlz-wdot` tag the landing zone's image pipeline writes; INFO when absent) |
| Monitoring | Log Analytics workspace existence and retention |
| Naming | Host pool / workspace / application group name collisions |
| Endpoints | Outbound TCP reachability to the AVD required endpoints (opt-in) |

### Post-Deployment Checks

| Category | Checks |
|---|---|
| Host pool | Type and load balancing (Personal pools must be Persistent), max session limit, validation environment flag, Start VM on Connect, custom RDP properties |
| Registration | Registration token presence and expiry, flagged as a security exposure while live |
| App groups | Application groups linked to the host pool, published to exactly one workspace, `Desktop Virtualization User` role assigned, preferred app group type alignment |
| Session hosts | Registered count vs. expected, availability status, drain mode, heartbeat freshness, agent / SxS stack / OS version drift, agent update state, pool utilization |
| Session host VMs | VM correlation, power state, provisioning state, image consistency (one image per pool; WARN when hosts run different images, which is expected only mid-rotation), availability zone spread, extension provisioning failures, domain join method, monitoring agent coverage, and for Microsoft Entra joined hosts a `Virtual Machine User Login` role assignment |
| Storage | Everything in the preflight storage set, plus SMB data-plane role assignments |
| Scaling | Scaling plan attached and enabled, Start VM on Connect consistency |
| Identity | Desktop Virtualization power management role, graded by whether Start VM on Connect or a scaling plan is actually in use, plus whether a scaling plan has only `Power On` when it needs `Power On Off` |
| Diagnostics | Host pool diagnostic settings and the enabled AVD log categories |
| Resilience | Azure Backup coverage for personal session host VMs |
| Sessions | Active vs. disconnected user sessions |

### Output Package

```
avd-validation-20260919T141120/
├── validation-report.md      # Executive report: summary, failures, warnings, all checks
├── validation-results.csv    # One row per check
├── validation-results.json   # Same data, structured
├── manifest.json             # Run inputs, verdict and counts, for reproducibility
├── az-module-versions.csv    # Tooling provenance
└── run-log.txt               # Full run log
avd-validation-20260919T141120.zip
```

---

## Second Brain

The estate's memory moved to **[avd-second-brain](https://github.com/avd-ops/avd-second-brain)**: one second brain for the
whole AVD lifecycle, shared with
the assessment project
and [avd-landing-zone](https://github.com/avd-ops/avd-landing-zone) (deployment and operations).
The script and its vault template are there, at `vault/avd_second_brain.ps1`, with the
same parameters plus an optional `-KnowledgePath`. This repository stays the **sensor**: the collector and the validator
produce the evidence packages the vault ingests ([contract C1](https://github.com/avd-ops/avd-second-brain/blob/main/docs/contracts.md)).

```powershell
git clone https://github.com/avd-ops/avd-second-brain.git ..\avd-second-brain
..\avd-second-brain\vault\avd_second_brain.ps1 -BrainPath ..\avd-brain -Init
..\avd-second-brain\vault\avd_second_brain.ps1 -BrainPath ..\avd-brain -PackagePath .\avd-current-state-20261015T091500, .\avd-validation-20261016T100000.zip
```

What the move adds: `-Init` seeds a vault with the organization's shared runbooks, and
`scripts/Get-VaultHarvest.ps1` proposes what a vault may contribute back to the shared
knowledge base, generalized, without tenant data. The vault itself still belongs in its own
**private** repository. See [the vault docs](https://github.com/avd-ops/avd-second-brain/blob/main/docs/vault.md).

A change to the packages' dataset names or fields is a contract change: avd-second-brain's
The brain's [tests/Connectors.Tests.ps1](https://github.com/avd-ops/avd-second-brain/blob/main/tests/Connectors.Tests.ps1) runs minimal collector and validator packages through the vault.

---

## Facts snapshot for the brain and avd-swarm

The packages hold tenant data: subscription and object IDs, resource and user names, IP
addresses, tags. They belong in the customer's private vault. `avd_current_state_facts.ps1`
makes the form of the same evidence that [avd-second-brain](https://github.com/avd-ops/avd-second-brain)'s agents read and that
[avd-swarm](https://github.com/avd-ops/avd-swarm) sees through the brain: the fact collection layer of both, defined as
[contract C11](https://github.com/avd-ops/avd-second-brain/blob/main/docs/contracts.md) (`avd-current-state-facts/v1`). avd-swarm never consumes a
package or a snapshot directly; the brain cites the facts, and avd-swarm's governance gate
re-reads live state before any change.

```powershell
# First run for an estate: -NewKey creates the estate's pseudonymization key
.\avd_current_state_facts.ps1 -PackagePath .\avd-current-state-20261015T091500, .\avd-validation-20261016T100000.zip `
    -KeyPath ..\avd-brain\.brain\facts.key -NewKey

# Later runs: the same key gives the same pseudonyms, so the brain sees trends
.\avd_current_state_facts.ps1 -PackagePath D:\Assessments -KeyPath ..\avd-brain\.brain\facts.key
```

It reads the latest collector run per subscription and the latest validator run per
subscription and mode, offline, and writes `avd-current-state-facts-<timestamp>.json`.

| Kept | Never kept |
|---|---|
| Counts, booleans, regions, VM sizes, marketplace images, SKUs, agent and OS versions, built-in role names, validator check names and statuses | Names, resource and object IDs, user names, IP addresses, tags, RDP property values, check scopes, details and recommendations |
| Subscriptions, host pools and storage accounts as keyed pseudonyms (`hp-3fa2c1d0`) | Custom role names (counted as `other`) |

- **Pseudonyms** are HMAC-SHA256 of the resource ID with the estate's key. Keep the key with
  the vault, never in a repository. Without the key and the IDs, a pseudonym can't be reversed.
- **Fail closed.** A value that doesn't match its field's pattern becomes `other`; a check
  name that contains a collected name becomes `redacted`. If anything that looks like a GUID,
  an email address, a UNC path or an IP address still gets through, the script refuses to
  write the snapshot.
- **One tenant per snapshot.** Packages from two tenants are refused.

The brain checks the snapshot again and files it in the vault:
`scripts/Import-CurrentStateFacts.ps1 -FactsPath <snapshot> -VaultPath <vault> -Apply`.

`contracts/current-state-facts.schema.json` is a copy of the brain's schema, which is the
authority. A change to it is a contract change in three repos: avd-second-brain, this one
and avd-swarm. The tests (`tests/Facts.Tests.ps1`, Pester, offline) build packages full of
names, IDs and addresses and check that none reach the snapshot.

### From inventory to a deployment-ready manifest

After writing the snapshot, the script prints its **manifest coverage**: how many of the
design decisions in a target-state manifest (avd-second-brain contract C14) this estate's
Azure-side facts can support, and which ones can't be decided from Azure at all:

```
[INFO] Manifest coverage: 5 of 10 design decisions can come from this snapshot (region, network mode, host pool type, application group, power settings).
[INFO]   Identity lane, VM size, Sessions per host, Host count, Profile share quota need measured usage: a Stratusphere UX assessment ...
```

Configuration says what someone set, not what users do. Sizing (VM size, sessions per host,
host count), the profile share and the identity lane need measured demand, concurrency, profile
sizes and app dependencies. An assessment collects them with Liquidware
Stratusphere UX over a 2 to 4 week window (appliances and a license for the window, so it is
priced before it starts), and turns them, together with this snapshot and the collector
package, into a manifest that [avd-landing-zone](https://github.com/avd-ops/avd-landing-zone) deploys. It uses the same estate
key, so its host pool pseudonyms match this snapshot's.

The decisions and facts come from `contracts/fact-register.json`, a byte-identical copy of
avd-assess's fact register (contract C15), pinned with the schema in `contracts/PINS.json`.

### The assessment method

`assess/` holds byte-identical copies of [avd-assess](https://github.com/avd-ops/avd-assess)'s
`method.json` and `index.json` (contract C20), pinned by commit and SHA-256 in `assess/PINS.json`
at the same commit as `contracts/`. `lib/AvdAssess.psm1` runs the method's checks over a snapshot
and an optional `intake.json` (C19) and builds the assessment report (C21): one row per check
(`pass`, `warn`, `gap` or `unknown`, with the pseudonyms it looked at), the pillar scores with
their coverage, and each design decision's readiness. A missing fact makes a subject `unknown`,
never a failure. Nothing is fetched at run time, and none of it needs the brain or avd-swarm. A
method update is a PR that copies the files at a new avd-assess commit and updates both PINS files;
`tests/Assess.Tests.ps1` fails if a copy drifts.

Run it with the facts script's `-Assess` switch, and give the Discover stage's `intake.json` when
you have one:

```powershell
./avd_current_state_facts.ps1 -PackagePath $out -KeyPath (Join-Path $out 'estate.key') -OutputPath $out -Assess -IntakePath (Join-Path $out 'intake.json')
```

It writes `avd-assessment-<timestamp>.json` beside the snapshot with the same timestamp, and
prints one line per pillar, the count of checks by outcome, and which design decisions the
inputs support, in place of the manifest coverage line above. Before it reads any package, it
refuses a pinned copy in `assess/` or `contracts/` that doesn't match its hash and an intake that
isn't valid C19; an intake for another estate is refused before anything is written, and so is a
report the leak scan flags. The script's output is still the snapshot's path; the report's file
name is in the log and the state line (`assessment`).

---

## Assessment portal

[`site/portal/`](site/portal/) is one static page that walks an assessment stage by stage, the way the landing zone's deployment portal walks a deployment ([spec](docs/assessment-portal-spec.md)). It gives a self-contained Cloud Shell block for each stage, reads the output you paste back, and keeps your progress in your browser. It makes no network request and every command only reads.

| Stage | What you do | What it writes |
|---|---|---|
| 1. Collect | Run the collector and the facts script, paste the output | Nothing new; the estate gets its `est-` pseudonym, and its key stays beside the packages in Cloud Shell |
| 2. Discover | Answer the discovery interview | `intake.json` (contract C19 in [avd-assess](https://github.com/avd-ops/avd-assess/tree/main/contracts)), written into Cloud Shell by a block that holds no names, and `discovery-notes.md`, your private narrative, downloaded to your device |
| 3. Analyze | Run the validator, paste the output | Nothing new |
| 4. Review | Load `assessment.json` (and an earlier `review.json` to carry decisions forward), decide each finding: fix, accept or defer, with a reason | `review.json` (contract C23), pinned to the report by its SHA-256 and holding only check IDs and reason codes; private notes per finding go into `discovery-notes.md` |
| 5. Plan | Coming next: a plan from the fixes (`plan.json`, C24) | |

Each script ends with one line the page reads, `<<<AVDCS-STATE {...} AVDCS-STATE>>>`, built by `lib/AvdPortalState.psm1`. It holds counts, the package folder's name and the estate pseudonym, never a name or an ID. The page uses the [avd-ops design system](https://github.com/avd-ops/avd-ops/blob/main/docs/design-system.md), vendored in `site/assets/`. Run it locally with `python3 -m http.server -d site` and open `http://localhost:8000/portal/`.

## Limitations

### Both scripts

- **ARM-level only.** Neither script inspects OS-level configuration, Group Policy, FSLogix registry settings, Intune policy, or Microsoft Entra conditional access. The collector reads FSLogix settings only where a managed Run Command applied them (the landing zone's session hosts).
- **Network effective state is not evaluated.** NSG effective rules, NVA and firewall inspection, and DNS resolution behavior require separate validation from inside the session host subnet.
- **No Entra ID object enumeration.** Users, groups and conditional access policies are outside ARM scope.
- **Read-only.** No Azure resource is created, modified or deleted.

### Current State Collector

- **Session host detail depends on the AVD control plane.** Powered-off or unregistered hosts may show limited metadata.
- **Single tenant per run.** Multi-tenant collection requires separate authenticated runs.

### Deployment Validator

- **Endpoint probes reflect the machine running the script**, not a session host, unless you run it on one.
- **Policy effects are read, not simulated.** Initiatives are expanded and parameterized effects are resolved, but policy conditions, exemptions and effects set by other template expressions are not evaluated, so a deny listed here may not apply to this deployment.
- **Quota reflects the moment of the run.** Another deployment can consume the headroom reported here.
- **Single subscription per run.** Deployments spanning subscriptions need one run per subscription.

---

## Troubleshooting

### Current State Collector

| Symptom | Likely cause | Resolution |
|---|---|---|
| Subscription skipped with "AccessDenied" | Identity lacks Reader on that subscription | Grant at least Reader, then re-run |
| AVD host pools show 0 | No AVD deployed, or missing `Desktop Virtualization Reader` | Verify AVD exists; check RBAC |
| Session hosts empty for a host pool | Hosts powered off, or agent not registered | Check the host pool in the portal |
| A `rebuild/` read shows `failed` in summary.md | The identity can't read that resource type (budgets need Cost Management Reader or Reader on the subscription) | The error line in the log has the HTTP status and body. Grant the read, or accept the gap |
| "not written, the final scan found ..." | A value shaped like a secret got past the scrubber | The file is withheld on purpose. Report the resource type (never the value) so the scrubber learns the property |
| Module install fails | No PSGallery access, or execution policy restriction | Pre-install the Az modules or adjust execution policy |
| Output missing after the Cloud Shell session ends | Files written outside `~/clouddrive/` are ephemeral | Re-run without `-OutputPath` so Cloud Shell detection defaults to `~/clouddrive/` |
| Cloud Shell disconnected mid-run | Idle timeout while the tab was backgrounded | Keep the tab active; use `-SubscriptionNames` to scope to fewer subscriptions per run |

### Deployment Validator

| Symptom | Likely cause | Resolution |
|---|---|---|
| Many checks report `SKIP` | Optional parameters not supplied | Supply the parameters named in each `SKIP` recommendation, or use `-ConfigPath` |
| `Host pool discovery` fails | Identity lacks `Desktop Virtualization Reader` | Grant the role at subscription or resource group scope |
| `Deployment role coverage` reports `INFO` | Role assignment enumeration needs Microsoft Graph read | Expected for a read-only identity. Confirm the deploying identity's roles separately |
| `AVD metadata region` reports `INFO` | The resource provider did not return a location list | Check the metadata region against the AVD documentation |
| A check reports "Check could not complete" | Az module output shape differs from what the check expects | The run continues. Report the check name so the property accessor can be widened |
| Diagnostics check reports `SKIP` | `Az.Monitor` is unavailable | Install `Az.Monitor`, or accept the gap |
| Endpoint probes all fail | Running from a machine without internet egress | Expected. Re-run from a session host, or ignore the probe results |

---

## Entry points

Each links its reference page, generated from the script's own help by the second brain's [Update-BrainDocs.ps1](https://github.com/avd-ops/avd-second-brain/blob/main/scripts/Update-BrainDocs.ps1). Edit the help, not the page. Changes are in [CHANGELOG.md](CHANGELOG.md).

<!-- generated:entry-points begin -->
<!-- Generated by scripts/Update-BrainDocs.ps1. Do not edit between the markers; edit the source and regenerate. -->
| Script | What it does |
|---|---|
| [`avd_current_state_facts.ps1`](docs/reference/avd_current_state_facts.md) | AVD Current State Facts -- turns collector and validator evidence packages into one redacted facts snapshot (avd-current-state-facts/v1) for avd-second-brain and avd-swarm. |
<!-- generated:entry-points end -->

## Contributing

Contributions and forks are welcome and encouraged. Fork it and make it your own, or send back what you learn: open an issue for a bug, a question or an idea, or a pull request with a fix, a test, a doc or a lesson from a real run. Small pull requests are easiest to review.

Before you open one, run the Pester tests in `tests/` and PSScriptAnalyzer as the [test workflow](.github/workflows/test.yml) does. Keep tenant data, IDs and secrets out of the repo, issues and pull requests. By contributing, you agree your contributions are licensed under the repo's [MIT License](LICENSE).

## License

This project is licensed under the [MIT License](LICENSE), provided "as is", without warranty of any kind.
