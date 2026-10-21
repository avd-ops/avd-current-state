# Spec: one definition of the preflight and postflight checks

Status: accepted by the owner, 2026-10-21 (option A and the three open questions as recommended). Nothing is built yet. No Azure, no spend; every phase is offline first.

The owner asked (2026-10-20) for the preflight and postflight checks to be shared between this repo and [avd-landing-zone](https://github.com/nickprignano/avd-landing-zone), with this repo also running the [avd-assess](https://github.com/nickprignano/avd-assess) method. The checks live here; the landing zone refers out to them. The research behind this spec (prior art, an inventory of both repos' checks, five options) is summarized in section 6.

## 1. Rules it keeps

- **avd-current-state is self-contained.** It runs end to end from this repo. What it needs from avd-assess (`method.json`, `index.json`, the C22 schema) are pinned byte-identical copies, checked by hash. Nothing is fetched at run time, and nothing here needs the landing zone, the brain or avd-swarm.
- **Code flows one way between the pair:** this repo to the landing zone, never back (the same rule as [assessment-portal-spec.md](assessment-portal-spec.md)).
- **This repo only reads.** Fixes belong to the landing zone. No catalog entry and no function here writes to an estate.
- **One definition.** A check exists once, here, with one ID. The landing zone's copy is a hash-checked copy, never edited.
- **avd-assess says what should be checked and why.** The method's checks (`asm-*`) stay in its `method.json` and run through the same evaluator. Operational checks (quota, providers, naming) aren't assessment method, so they live in this repo's catalog and cite avd-assess references where one exists.

## 2. The pieces

| Piece | Where | What |
|---|---|---|
| `lib/AvdChecks.psm1` | here | Readers, the evaluator, coded checks. Windows PowerShell 5.1 and PowerShell 7 |
| `checks/catalog.json` | here | Every preflight and postflight check: ID, title, phase, gate, pillar, severity, fact IDs, claims, and a `rule` or an `impl` |
| C22 `avd-check-catalog/v1` | avd-assess `contracts/schemas/check-catalog.schema.json`, pinned here | The catalog's schema. avd-assess is the authority for foundation formats ([its contracts README](https://github.com/nickprignano/avd-assess/blob/main/contracts/README.md)); C22 was reserved for this |
| `assess/` with `PINS.json` | here | `method.json`, `index.json` from avd-assess at a commit (avd-assess phase 4) |
| `avd_deployment_validator.ps1` | here | The one runner: `-Mode Preflight\|PostDeployment\|Both [-Assess] [-IntakePath]` |
| `vendor/avd-current-state/` with `PINS.json` | avd-landing-zone | Byte-identical copies of `lib/AvdChecks.psm1` and `checks/catalog.json` at a commit here, and a hash test |

### 2.1 `lib/AvdChecks.psm1`

- **Readers** turn live ARM, Resource Graph and AVD reads into one in-memory facts document keyed by fact register (C15) IDs. Raw values stay in memory; only the facts script's redacted C11 snapshot is written. Readers use REST (`Invoke-AzRestMethod`, Resource Graph), as the collector already does, and count properties the way ARM returns them: an empty property is absent.
- **The evaluator**, `Invoke-AvdAssessCheck` (avd-assess phase 4), runs declarative rules (`each`, `where`, `expect`) over a facts document or a C11 snapshot. A missing property makes that subject `unknown`, never a failure. The same function runs catalog rules and the method's `asm-*` checks.
- **Coded checks** for what a rule can't express: quota arithmetic, NSG port coverage, policy effects, endpoint probes, version consistency. Each is a pure function from facts to results, named in the catalog by `impl`, tested offline with fixtures. The catalog never holds code.

### 2.2 `checks/catalog.json` (C22)

One entry per check:

| Field | Meaning |
|---|---|
| `id` | Stable, kebab case. Reuses the landing zone's portal IDs where they exist (`quota`, `hostpool-region`, `registering`, ...), and `asm-*` IDs for method checks listed here |
| `title` | One line, as the report and both portals show it |
| `phase` | `preflight`, `postflight` or both |
| `gate` | `block` (the deployment or the estate can't work) or `advise` (a recommendation) |
| `pillar`, `severity` | As in C20 |
| `facts` | C15 fact IDs the check reads, never script variables or raw property paths |
| `claims` | `ref:` claims in avd-assess's references, or `gap:` when none exists |
| `rule` or `impl` | A C20-shaped rule, or the name of a coded check |
| `remediation` | A hint for the plan (C24) and the landing zone parameter it maps to, if known; never a command that writes |
| `fixable` | `true` when the landing zone has a fixer for this ID; informational here |

Method checks (`asm-*`) are listed by ID with `"source": "method"` and no rule of their own, so the rule exists once, in avd-assess.

### 2.3 One run, one report

`avd_deployment_validator.ps1 -Mode Both -Assess -IntakePath ./intake.json` reads once, runs the catalog's checks for the phases asked for, then hands the same reads to the facts step, which writes the redacted C11 snapshot and runs the pinned `method.json` over it into C21 `assessment.json`. One output folder holds the readiness results (with IDs, as today's CSV and JSON plus the `id` column), `assessment.json`, and the state line (`lib/AvdPortalState.psm1`).

Outcomes: readiness checks keep PASS, WARN, FAIL, INFO, SKIP; method checks keep C21's pass, warn, gap, unknown. The report maps a `gap` on an `advise` check to WARN in the readiness summary, and an `unknown` to INFO.

## 3. The landing zone

- It carries `vendor/avd-current-state/` and `PINS.json`, as it carries `contracts/` today. Its Cloud Shell blocks still clone one repo, and its offline scenarios (`AzMock.psm1`) keep running.
- `AvdLandingZone.psm1` imports the copy and maps each shared result onto `Add-AvdCheckResult` with the same ID, so the deployment portal (`portal-core.js`) reads what it reads today.
- It keeps a **fixer map**, check ID to fix function: providers and EncryptionAtHost, Entra groups and membership, the AVD service principal, admin consent, the cloud group SID tag, the Conditional Access exclusion, the profile share root ACL, deleted Key Vault recovery. `-Fix` runs the shared check, fixes, reruns the shared check, and reports Fixed only if the rerun passes.
- It keeps **its own checks about its own plan:** tooling, parameter file compile, sizing and cost from the plan, the landing zone by name, the size change warning, hub VNet and firewall parameters.
- Pin bumps are a landing zone PR: copy the files, update the hashes, run its tests.

## 4. Decisions (owner, 2026-10-21)

1. **Entra checks move here as reads, fixes stay in the landing zone,** once the Graph sign-in app is settled (groups and members, the AVD service principal, Conditional Access, security defaults, admin consent, Intune licensing). This repo then reads Azure and Graph, still read-only.
2. **The landing zone carries a vendored copy,** not a pinned fetch at run time: one clone in Cloud Shell, offline CI, and the pattern the family already uses.
3. **The catalog is its own contract, C22,** not a section of C20: operational checks aren't assessment method.

## 5. Build order (each a PR, offline first)

| Phase | Repo | What |
|---|---|---|
| 0 | here | This spec |
| 1 | avd-assess | C22 schema and example in `contracts/`, `check_contracts.py` covers it |
| 2 | here | Stable IDs on every validator result, no behavior change; fixture tests assert IDs |
| 3 | here | `lib/AvdChecks.psm1`: readers to facts (REST and Resource Graph), coded checks as pure functions with fixtures; the validator calls the module; `checks/catalog.json` pinned against C22 |
| 4 | here | avd-assess phase 4: `assess/PINS.json`, the evaluator, `-Assess`, C21 from the same run |
| 5 | avd-landing-zone | Vendor the module and catalog; replace its duplicate checks (providers, caller roles, quota, region, names, power role, storage reads) with the shared ones; fixer map by ID; portal IDs unchanged |
| 6 | both | Fold `-WellArchitected` findings that read the same facts (zone spread, diagnostics, backup) into catalog checks with `waf-` IDs; PSRule stays in the landing zone |
| 7 | here, then the landing zone | Entra reads (decision 1), when the Graph sign-in app is settled |

## 6. Research summary (2026-10-20)

**Prior art.** No open, read-only AVD validator covering both preflight and postflight was found. Microsoft covers pieces, which we read as evidence and don't rebuild: the agent's [session host health checks](https://learn.microsoft.com/azure/virtual-desktop/session-host-status-health-checks), the [required URL check tool](https://learn.microsoft.com/azure/virtual-desktop/check-access-validate-required-fqdn-endpoint) on each host, [Azure Advisor's AVD recommendations](https://learn.microsoft.com/azure/virtual-desktop/azure-advisor-recommendations), [APRL](https://github.com/Azure/Azure-Proactive-Resiliency-Library-v2) and [WARA](https://github.com/Azure/Well-Architected-Reliability-Assessment) (MIT, already the family's reliability engine), [azqr](https://github.com/Azure/azqr) (MIT, a cross-check only) and [PSRule for Azure](https://azure.github.io/PSRule.Rules.Azure/) (MIT, kept in the landing zone). [maester](https://github.com/maester365/maester) (MIT) is the closest open pattern for "one check is an ID, code and a page"; the archived [Operation Validation Framework](https://github.com/PowerShell/Operation-Validation-Framework) had the idea of shipping ops tests with the code. GitHub was checked repo by repo; its search API answers 403 from build containers.

**Overlap.** The validator has 96 distinct checks (preflight 44, profile storage 9, postflight 43). The landing zone has about 36 check sites, about a third of them duplicating the validator's (caller roles, providers, SKU and quota, AVD metadata region, name collisions, Start VM on Connect and the power role, storage reads, session host health and diagnostics). The validator's versions are usually deeper. Only the landing zone has the Entra checks and the checks about its own plan; only the validator has policy, locks, subnet, image, LDAP and session checks.

**Options weighed.** A (checks here, landing zone vendors a pinned copy and adds fixers), B (the same with a pinned fetch at run time), C (checks in the landing zone, vendored here), D (a new shared engine repo), E (the catalog as data in avd-assess with code in both repos). Only A and B pass the first test (this repo self-contained) without putting read-only checks in the repo that writes or adding a repo. A wins on Cloud Shell and offline CI. D adds a repo for two plug points (the fixers and the method data) that A already has. E needs two evaluators and puts operational checks in a methodology repo.
