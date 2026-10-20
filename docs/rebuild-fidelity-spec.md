# Spec: collect enough to rebuild (rebuild fidelity)

Status: draft, 2026-10-20. Nothing is built. No Azure, no spend.

The goal of avd-current-state is full current-state visibility: enough evidence that the package can later be turned around into an [avd-landing-zone](https://github.com/nickprignano/avd-landing-zone) parameter file and deployment, either **exactly as it is** or as a **target state** with avd-assess findings applied (owner, 2026-10-20). Generating the landing zone package is not version 1. Collecting at that fidelity is.

This spec measures today's collector against what a faithful rebuild needs, lists the gaps (section 4 and the matrix in section 10), and proposes how to close them without breaking the rules that already hold:

- **Read-only.** Reader is enough; no write, no Run Command, no agent on a host.
- **Self-contained.** avd-landing-zone and avd-current-state work without the brain, avd-swarm or avd-assess. Anything from those repos arrives as a pinned, hash-checked copy, never a runtime dependency.
- **Redaction and pseudonyms stay as they are.** The facts snapshot (avd-second-brain contract C11) remains counts, public values and keyed pseudonyms. Rebuild values (names, prefixes, IDs) stay in the private evidence package and never reach C11, the brain's agents or avd-swarm.

## 1. Where rebuild fidelity lives

Two outputs, two jobs, and only one of them can carry a rebuild:

| | Evidence package (collector) | Facts snapshot (C11) |
|---|---|---|
| Holds | Names, resource IDs, address prefixes, group object IDs, settings | Counts, booleans, public Azure values, `sub-`/`hp-`/`st-` pseudonyms |
| Lives | The operator's session, then the customer's private estate vault | The vault's facts store; read by the brain's agents, cited to avd-swarm |
| Can it rebuild? | Yes, once the gaps below are closed | No, by design: a parameter file needs `10.x` prefixes and names that C11 must never hold |

So the rebuild source is the package. A later generator runs where the package is (the operator's session or the private vault), reads it, and, for a target state, also reads the decisions in a C14 manifest and the findings in a C21 report. C11 only gains the redacted facts the assess checks need (section 7).

## 2. What "faithful" means here

For each landing zone parameter, the collector must be able to say one of:

| Status | Meaning |
|---|---|
| `found` | The value is read directly (a VM size, a retention period) |
| `derived` | The value follows from evidence by a written rule (Standalone vs HubPeered from the egress path) |
| `secret` | Never collected; the rebuild generates a new one (the break-glass password, a registration token) |
| `ambiguous` | Evidence disagrees (two host pools with different session limits): the rebuild needs a person's choice |
| `unexpressible` | The estate uses something the landing zone has no parameter for (AD DS join, RemoteApp): the rebuild can't be exact until the landing zone grows |
| `unknown` | Not readable with Reader (in-guest settings on a host the landing zone didn't build, a hub in a subscription out of scope) |

Faithful for version 1 means: on an estate the landing zone built, every parameter comes back `found`, `derived` or `secret`, with the value it was deployed with. On any other estate, every difference from the landing zone's vocabulary is named, not dropped.

The landing zone also hard-codes many settings in its modules (scaling plan schedules, NSG rules, Trusted Launch, SMB security, alert rules). They aren't parameters today, but an existing estate may differ on every one of them, so "exactly as is" needs them too. The matrix covers both.

## 3. Today's collector

22 datasets, each a CSV and a JSON per subscription, with hand-picked columns: resource groups, ARM resources, VNets, subnets, NSGs, NSG rules, route tables, public IPs, VMs, VM extensions, storage accounts, Key Vaults, Log Analytics workspaces, Recovery Services vaults, private endpoints, policy assignments, role assignments, host pools, workspaces, app groups, session hosts. The validator reads more (scaling plans, file shares, diagnostic settings, backup items, gallery images, locks) but only to grade checks; its package holds results, not settings.

Against the landing zone's 55 parameters (avd-landing-zone `bicep/main.bicep` at `2c44156`):

| | Parameters |
|---|---|
| `found` or `derived` from today's datasets | 13 |
| Partly there (the value is collected but not joined, or a column is missing) | 16 |
| Not collected at all | 23 |
| `secret`, never collected | 1 (`localAdminPassword`) |
| Looked up or pinned at deploy time, not needed from the estate | 2 (`avdServicePrincipalObjectId`, `autoShutdownRunbookUri`) |

The matrix in section 10 has every row.

## 4. The gaps, grouped

1. **Scaling plans.** Not collected: schedules, time zone, ramp percentages, exclusion tag, host pool links.
2. **Profile storage beyond the account.** File share quota, identity-based auth (`AADKERB`, AD DS, Entra Domain Services), SMB versions, Kerberos ticket encryption, SMB channel encryption (landing zone lesson 0028 is the reason this matters), shared key access, share soft delete, private endpoint DNS.
3. **FSLogix configuration.** Profile size, VHD locations and the other registry values are in-guest. On hosts the landing zone built, they are the parameters of the `Configure-FSLogix` managed Run Command, which a GET returns with Reader. On other hosts they live in Group Policy, Intune or a script, outside Reader (section 6).
4. **Session host build.** Zones, encryption at host, security type (Trusted Launch, Secure Boot, vTPM), license type, OS disk type, accelerated networking, boot diagnostics, managed identity, the admin user name, the gallery image ID (today only marketplace images are recorded), the NIC's subnet, and the settings of the Entra join extension (its `mdmId` says whether Intune enrollment is on).
5. **Connectivity.** NAT Gateway, VNet peerings (both sides when readable), route next hop IP, `defaultOutboundAccess`, private DNS zones, their VNet links, and private endpoint DNS zone groups. Without these the collector can't tell Standalone from HubPeered.
6. **Monitoring.** Action groups, the AVD Insights data collection rule and its associations, scheduled query alerts, the service health alert, and diagnostic settings on every AVD, storage, Key Vault, vault and NSG resource.
7. **Governance.** Policy assignment parameters (the allowed locations list), Defender for Cloud plans, budgets, the subscription activity log export, locks.
8. **Auto shutdown.** Automation account, runbook source link, the Logic Apps' recurrence and actions, the budget action group.
9. **Backup.** Protected items (is the profile share backed up) and the backup policy's retention.
10. **Control plane details.** Host pool public network access, agent update schedule, personal assignment type, friendly names; app group assignments joined to the app group; RemoteApp applications; workspace private endpoints and public access.
11. **Images.** Galleries, image definitions (security type, Hyper-V generation, features), versions (replica regions, end of life) for the image the hosts run.

## 5. How to collect it: Resource Graph first

This is the collector's move to Resource Graph (avd-second-brain `docs/assess-spec.md` section 6.1 and phase 4; avd-assess `methods/collection.md` step 1), scoped by what a rebuild needs.

- **One query per resource type, whole objects.** For each in-scope type the collector saves the full ARM object (`id`, `name`, `type`, `location`, `zones`, `sku`, `identity`, `tags`, `properties`) from Resource Graph, not a hand-picked column list. Fidelity then comes by construction: a property Azure adds next year is already in the package. Session hosts come from `DesktopVirtualizationResources`; host pools, app groups, workspaces and scaling plans from `Resources`; role assignments from `AuthorizationResources`; policy from `PolicyResources`; Defender plans from `SecurityResources`; backup items from `RecoveryServicesResources`. Phase 1 confirms each table against Microsoft's table reference and records the cite.
- **REST where Resource Graph has no row.** Diagnostic settings, file service SMB settings and file shares, private endpoint DNS zone groups, managed Run Commands, budgets and backup policies are read with `GET` through `Invoke-AzRestMethod`, one call per parent the scope already found. A loop over remote calls ends on an error or an empty page (avd-landing-zone lesson 0008), and every failure is reported with status, code and body (lesson 0012).
- **Paging.** Resource Graph pages with a skip token; the reader follows it until it is empty and records the row count per type, so a short read can't pass silently.
- **The scope is an allowlist, not a general inventory.** `rebuild/scope.json` lists the resource types and REST reads, each with the landing zone parameters or module settings it serves. A type with no row there isn't collected. For everything else, the README keeps pointing at ARI's Excel inventory (avd-assess collection step 7).
- **Read-only still holds, with one wording change.** Resource Graph queries are `POST` requests that only read. The README's read-only section changes from "Get-* and Test-* only" to name that one exception explicitly.
- **Windows PowerShell 5.1 and PowerShell 7**, as today. `Invoke-AzRestMethod` is in Az.Accounts; no new module.

### 5.1 Package layout: additive only

New files go under a `rebuild/` folder per subscription: one JSON file per resource type (`rebuild/resources/microsoft.desktopvirtualization-scalingplans.json`) and one per REST read (`rebuild/rest/diagnostic-settings.json`). The 22 existing datasets and their columns don't change, and the facts script never opens `rebuild/` (a test proves its output is byte-identical with and without the folder). Version 1 may later read the existing datasets from the same rows, but that's a refactor for after the parity test passes, not part of this spec.

### 5.2 What is never collected

Even in the private package, the reader drops these before writing, and a final scan refuses to write the package if one gets through:

- Host pool registration tokens (`properties.registrationInfo.token`, and any `registrationToken` property).
- Anything with a SAS signature (`sig=`), Logic App callback URLs, Automation webhook URIs.
- Keys and connection strings (`primaryKey`, `secondaryKey`, `connectionString`, `accessKeys`), and any `protectedParameters` or `protectedSettings` value a Run Command or extension returns.
- Key Vault data plane: no secret names, versions or values.

The scan's patterns (JWT, SAS, account key shape) get fixtures and a test.

### 5.3 Secrets are recreated, never carried

A rebuild never moves a secret from the old estate to the new one; it recreates each one (owner, 2026-10-20). The rebuild map lists every secret the rebuild must recreate by kind and where it lives, never its value or its Key Vault name, so nothing is forgotten:

| Secret | How the rebuild recreates it |
|---|---|
| Break-glass local admin password | `deploy.sh` generates a new one and stores it in the new Key Vault (today's behavior) |
| Host pool registration token | Issued by the new host pool at deploy time and passed as a protected Run Command parameter (today's behavior) |
| Storage account keys | New account, new keys; the landing zone turns shared key access off, so nothing uses them |
| Entra Kerberos for the profile storage | The new storage account gets its own Entra app on enablement; the admin consent step is repeated, and the map flags it as a manual step |
| Logic App callback URLs, Automation webhooks | Recreated by the auto shutdown deployment |
| Anything else the estate depends on (a domain join credential in an extension's protected settings, secrets in other Key Vaults) | The collector can't see these: it never reads protected settings or the Key Vault data plane. The map lists each Key Vault and each extension with protected settings as `unknown`, so the operator knows where to look and recreates them by hand |

FSLogix profile containers are data, not secrets: moving them is a migration step outside this spec.

## 6. In-guest settings

FSLogix, the Entra Kerberos registry values, Defender exclusions and image customizations are on the host, not in ARM.

- **Hosts the landing zone built:** the managed Run Commands it creates (`Configure-FSLogix`, `Register-AvdAgent`) are ARM child resources. A `GET` returns the script source link and the non-protected parameters (`ProfileShareUncPath`, `ProfileSizeMiB`, `LocalAdminUsername`), so the FSLogix parameters come back `found` with Reader. Protected parameters are not returned.
- **Other hosts:** these settings are `unknown` in version 1. Reading them means either running something on the host (a Run Command, which is an action on the estate, not a read) or reading Intune configuration through Microsoft Graph (a new permission and a tenant-wide read). Both are owner decisions (section 9); neither is in this spec's default.

## 7. The facts snapshot (C11) and the fact register (C15)

C11 doesn't change in this spec. The assess checks will want some of the new evidence as redacted facts. These are proposals for one paired change later (avd-second-brain first, since its schema is the authority, then this repo's vendored copy and producer), each a count, boolean or public value on objects that already have pseudonyms:

| Proposed fact | Shape | Why |
|---|---|---|
| `c11.hostPool.scalingPlan` | boolean | Cost checks; today a host pool with no scaling plan is invisible |
| `c11.hostPool.publicNetworkAccess` | word | Private Link posture |
| `c11.hostPool.zones` | count map | Resilience checks (WARA's AVD recommendations) |
| `c11.hostPool.securityTypes` | count map | Trusted Launch coverage |
| `c11.hostPool.joinTypes` | count map: `entra`, `adds`, `hybrid` | Identity lane decision (`identity` in the register) |
| `c11.hostPool.intuneEnrolled` | count | Management lane |
| `c11.hostPool.diagnostics` | boolean | AVD Insights readiness |
| `c11.storage.identityAuth` | word | FSLogix lane |
| `c11.storage.smbChannelEncryption` | list of public words | Lesson 0028 |
| `c11.storage.backup` | boolean | Resilience |
| `c11.network.egress` | word: `natGateway`, `firewall`, `defaultOutbound`, `none` | Connectivity decision |
| `c11.governance.defenderPlans` | count map | Security pillar |
| `c11.rebuild.coverage` | counts per status (section 2) | Shows how close an estate is to a landing zone rebuild, the way "N of 10 decisions" does today |

No new pseudonym kind is needed: every proposal hangs off a subscription, host pool or storage account.

## 8. D18, ARI and the diagram step

- **ARI is not a rebuild source.** Its inventory is Excel with no JSON, and it doesn't read scaling plan schedules, SMB settings, diagnostic settings, Run Command parameters or extension settings. Inventory parity with ARI wouldn't give a rebuild; it would give a wider list of resources at the wrong depth.
- **The scope allowlist resolves "don't build a general inventory".** The collector goes deep on what a landing zone rebuild needs and nowhere else; ARI stays the pointer for everything else (avd-assess collection step 7) and the engine of the opt-in diagram (draft PR #13).
- **One read, two consumers.** The diagram step reads Resource Graph itself today (it must not need collector changes). Once `rebuild/` exists, the diagram step can read the same saved rows instead of querying again, so the two never disagree about what was there. That stays optional: the diagram step keeps its own read for packages made before this change.
- **D18 wording.** D18 says the collector's package format doesn't change. This spec changes it additively (section 5.1). Section 9 asks the owner to restate D18 as "existing datasets don't change; additions only".

## 9. Decisions for the owner

1. **D18: additive package change.** Default: yes, new files under `rebuild/` only, existing datasets and C11 untouched.
2. **In-guest settings on hosts the landing zone didn't build.** Default: `unknown` in version 1. Options for later: an opt-in Run Command reader (an action on hosts, so it would go through avd-swarm's approval when the brain is in use, and stand alone otherwise), or an opt-in Graph read of Intune configuration.
3. **Where the landing zone parameter list comes from.** Default: this repo keeps `rebuild/lz-parameters.json` (name, type, default, allowed values) with the avd-landing-zone commit it was taken from, and a CI job fails when that commit's `main.bicep` has parameters the file doesn't list. The pair stays self-contained: the file is a pinned copy, and the landing zone never reads this repo.
4. **Who generates the parameter file later.** Default (not version 1): avd-landing-zone reads a rebuild map from this repo the way it reads C14 today ("read, never trusted"), so generation sits beside `ConvertFrom-AvdTargetState.ps1`.

## 10. Coverage matrix

Columns: the landing zone parameter or module setting; what a rebuild reads; today's source (collector dataset, or C11 path); the gap; the version 1 source. "RG" is Resource Graph.

### 10.1 Core and identity

| Parameter | Rebuild reads | Today | Gap | v1 source |
|---|---|---|---|---|
| `namePrefix`, `environmentName` | Resource names against the landing zone's naming pattern | `resource-groups`, `arm-resources` (names) | No pattern match; brownfield names don't follow it | Derived in the rebuild map; `ambiguous` when names don't match |
| `location` | Region of the AVD resources | Every dataset; C11 `regions` | None | Existing |
| `tags` | Tags beyond the landing zone's four defaults | `arm-resources` Tags | None | Existing |
| `avdUsersGroupObjectId` | Desktop Virtualization User on the app group | `role-assignments` (ObjectId, role, scope) | Not joined to the app group | `AuthorizationResources`, joined by scope |
| `avdAdminsGroupObjectId` | VM Administrator Login on the hosts, SMB elevated contributor, Key Vault Secrets User | `role-assignments` | Not joined | `AuthorizationResources` |
| `avdServicePrincipalObjectId` | Tenant constant | `role-assignments` | None needed | Looked up at deploy |
| `enrollInIntune` | Entra join extension `settings.mdmId` | `vm-extensions` (name, version) | Extension settings not saved | RG `Resources` extensions, public settings only |
| (join type) | Entra join vs AD DS join extension | `vm-extensions` names | Not interpreted | Derived; AD DS join is `unexpressible` |

### 10.2 Connectivity

| Parameter | Rebuild reads | Today | Gap | v1 source |
|---|---|---|---|---|
| `connectivityMode` | NAT Gateway on the hosts subnet, or peering plus a default route to a virtual appliance | `route-tables` | NAT Gateway and peerings not collected | Derived from RG `Resources` (natgateways, VNet peerings) |
| `spokeAddressPrefix` | VNet address space | `virtual-networks` | None | Existing |
| `sessionHostSubnetPrefix` | Prefix of the subnet the hosts' NICs are on | `subnets` | No NIC to subnet join | RG `Resources` networkinterfaces |
| `privateEndpointSubnetPrefix` | Subnet of the private endpoints | `private-endpoints`, `subnets` | None | Existing |
| `deployImageBuildSubnets`, `imageBuildSubnetPrefix`, `imageBuildAciSubnetPrefix` | Subnets delegated to Container Instances, and their build VM neighbor | `subnets` (delegations) | Build VM subnet found by name only | Derived; `ambiguous` without the delegation pair |
| `hubVnetResourceId` | Remote VNet of the spoke's peering | None | Peerings | RG `Resources` virtualnetworks `properties.virtualNetworkPeerings` |
| `createHubToSpokePeering` | Hub side of the peering | None | Hub may be out of scope | Hub VNet read when visible, else `unknown` |
| `hubFirewallPrivateIp` | Default route next hop IP | `route-tables` (no next hop IP) | Column missing | RG `Resources` routetables |
| `dnsServers` | VNet DNS servers | `virtual-networks`; C11 `customDnsVirtualNetworks` | None | Existing |
| `centralPrivateDnsZoneResourceIds` | Zones the private endpoints register in, and whether they are linked to the spoke | None | DNS zones, links, zone groups | RG `Resources` privatednszones and virtualnetworklinks; REST privateDnsZoneGroups |
| `enableAvdPrivateLink` | Host pool private endpoint | `private-endpoints` (group IDs); C11 `privateEndpoints` | Host pool public network access | RG `Resources` hostpools |
| (module) NSG rules | Every rule, including service tags and ASGs | `nsg-rules` | Descriptions, ASGs | RG `Resources` networksecuritygroups |
| (module) Subnet `defaultOutboundAccess`, PE network policies | Subnet properties | `subnets` (PE policies only) | `defaultOutboundAccess` | RG `Resources` virtualnetworks |
| (module) NAT Gateway public IP and zones | NAT Gateway | `public-ips` | NAT Gateway | RG `Resources` natgateways |

### 10.3 Session hosts and control plane

| Parameter | Rebuild reads | Today | Gap | v1 source |
|---|---|---|---|---|
| `sessionHostCount` | Session hosts per host pool | `avd-session-hosts`; C11 `sessionHosts.total` | None | Existing |
| `sessionHostVmSize` | VM size | `virtual-machines`; C11 `vmSizes` | None | Existing |
| `sessionHostNamePrefix` | Common prefix of host names | `virtual-machines` | Not derived | Derived |
| `availabilityZones` | VM zones | None | Zones | RG `Resources` virtualmachines `zones` |
| `sessionHostImage` | Marketplace reference or gallery image version ID | `virtual-machines` (marketplace only); C11 `images` | Gallery image ID dropped | RG `Resources` virtualmachines `storageProfile.imageReference` |
| `maxSessionLimit` | Host pool | `avd-host-pools`; C11 | None | Existing |
| `encryptionAtHost` | VM security profile | None | Missing | RG `Resources` virtualmachines |
| `localAdminUsername` | VM OS profile admin user name | None | Missing | RG `Resources` virtualmachines `osProfile.adminUsername` |
| `localAdminPassword` | Never | Never | n/a | `secret` |
| `rdpProperties` | Host pool custom RDP properties | `avd-host-pools`; C11 keeps names only | None | Existing |
| `validationEnvironment` | Host pool | `avd-host-pools` | None | Existing |
| `startVmOnConnect` | Host pool | `avd-host-pools`; C11 | None | Existing |
| `scalingTimeZone` | Scaling plan time zone | None | Scaling plans not collected | RG `Resources` scalingplans |
| (module) Scaling plan schedules, ramp settings, exclusion tag, host pool link | Scaling plan | None | Missing | RG `Resources` scalingplans |
| (module) Host pool type, load balancer, preferred app group | Host pool | `avd-host-pools`; C11 | None | Existing |
| (module) Personal assignment type, agent update schedule, public network access | Host pool | None | Missing | RG `Resources` hostpools |
| (module) Trusted Launch, Secure Boot, vTPM, license type | VM | None | Missing | RG `Resources` virtualmachines |
| (module) OS disk type and size, delete options | VM | `virtual-machines` (size only) | Disk type | RG `Resources` virtualmachines, disks |
| (module) Accelerated networking | NIC | None | Missing | RG `Resources` networkinterfaces |
| (module) Boot diagnostics, system-assigned identity | VM | None | Missing | RG `Resources` virtualmachines |
| (module) AVD Insights DCR association | VM | None | Missing | RG `InsightsResources` |
| (module) App group friendly name and assignments | App group, role assignments | `avd-application-groups`, `role-assignments` | Not joined | RG `Resources`, `AuthorizationResources` |
| (estate) RemoteApp applications | App group applications | None | Missing; landing zone has no parameter | REST applications; `unexpressible` |
| (module) Workspace public access, private endpoints | Workspace | `avd-workspaces` | Missing | RG `Resources` workspaces |

### 10.4 Profiles and backup

| Parameter | Rebuild reads | Today | Gap | v1 source |
|---|---|---|---|---|
| `profileStorageSku` | Storage SKU | `storage-accounts`; C11 `sku` | None | Existing |
| `profileShareQuotaGiB` | Share quota | None (the validator reads shares for a check) | Missing | REST fileServices shares |
| `fslogixProfileSizeMiB` | FSLogix `SizeInMBs` | None | In-guest | REST managed Run Commands (landing zone hosts); else `unknown` |
| (module) VHD location to share | FSLogix `VHDLocations` | None | In-guest | Same as above |
| (module) Identity-based auth | Storage `azureFilesIdentityBasedAuthentication` | None | Missing | RG `Resources` storageaccounts |
| (module) SMB versions, auth methods, Kerberos ticket and channel encryption | File service SMB settings | None | Missing | REST fileServices |
| (module) Shared key access, public network access | Storage | `storage-accounts` (default action only) | Missing | RG `Resources` storageaccounts |
| (module) Share soft delete | File service | None | Missing | REST fileServices |
| `enableProfileBackup` | Protected item for the share | `recovery-services-vaults` (vault only) | Missing | RG `RecoveryServicesResources` |
| `profileBackupRetentionDays` | Backup policy retention | None | Missing | REST backupPolicies |

### 10.5 Operations, governance and auto shutdown

| Parameter | Rebuild reads | Today | Gap | v1 source |
|---|---|---|---|---|
| `logRetentionDays` | Workspace retention | `log-analytics-workspaces`; C11 | None | Existing |
| (module) Workspace local auth, SKU | Workspace | `log-analytics-workspaces` (SKU) | Local auth | RG `Resources` workspaces |
| `alertEmailAddresses` | Action group email receivers | None | Missing (private package only, never C11) | RG `Resources` actiongroups |
| (module) AVD Insights DCR | Counters, event logs, destination | None | Missing | RG `Resources` datacollectionrules |
| (module) Scheduled query alerts, service health alert | Alert rules | None | Missing | RG `Resources` scheduledqueryrules, activitylogalerts |
| (module) Diagnostic settings | Per AVD, storage, Key Vault, vault, NSG, Automation resource | None (validator checks some) | Missing | REST diagnosticSettings |
| `monthlyBudgetAmount`, `budgetStartDate` | Subscription budget | None | Missing | REST budgets |
| `enableAutoShutdown` | Automation account with the runbook | `arm-resources` (type only) | Settings | RG `Resources` automationaccounts, runbooks |
| `autoShutdownTime`, `autoShutdownDays`, `autoShutdownTimeZone`, `autoShutdownScheduleAction` | Schedule Logic App recurrence and action | None | Missing | RG `Resources` workflows, callback URLs stripped |
| `autoShutdownBudgetAction`, `autoShutdownBudgetPercent` | Budget notification, action group, budget Logic App | None | Missing | REST budgets; RG `Resources` |
| `autoShutdownRunbookUri` | Runbook content link | None | Pinned at deploy | Looked up at deploy; recorded when found |
| `enableDefenderForCloud` | Defender plans | None | Missing | RG `SecurityResources` pricings |
| `deploySubscriptionSettings` | Subscription activity log export | None | Missing | REST subscription diagnosticSettings |
| `enablePolicyGuardrails` | The landing zone's assignments | `policy-assignments`; C11 `policy` | Parameters not saved | RG `PolicyResources` |
| `allowedLocations` | Allowed locations assignment parameters | None | Missing | RG `PolicyResources` |
| (module) Key Vault RBAC mode, purge protection, public access | Key Vault | `key-vaults` (soft delete, purge) | RBAC mode, public access | RG `Resources` vaults |
| (estate) Locks | Resource locks | None (validator checks) | Missing; landing zone has none | RG `Resources` locks; `unexpressible` |

### 10.6 Images (`bicep/images`)

| Parameter | Rebuild reads | Today | Gap | v1 source |
|---|---|---|---|---|
| Gallery, image definitions | Security type, Hyper-V generation, features | None (validator checks) | Missing | RG `Resources` galleries, images |
| `replicaRegions`, end of life | Image version | None | Missing | RG `Resources` image versions |
| `sourceImage`, build settings | Image Builder template | None | Missing | RG `Resources` imageTemplates, when present |

## 11. Proving it: the round trip

The test that says version 1 is done:

1. **Offline.** A fixture of Resource Graph rows and REST bodies shaped like what the landing zone's `dev` parameters deploy, with every name a `contoso` placeholder and every prefix `10.x`, omitting empty properties the way ARM does (avd-landing-zone lesson 0021). A pure function, `Get-LzRebuildMap`, turns them into the parameter map, and a Pester test checks every parameter's status and value against `parameters/dev.bicepparam`. A second fixture, a brownfield estate (AD DS join, a RemoteApp group, no scaling plan), checks that each difference comes back `unexpressible` or `unknown`, never silently dropped.
2. **One sandbox run, later.** Deploy the landing zone's `dev` parameters, collect, compare, tear down. Only with a written cost estimate and the owner's go, smallest sizes, teardown evidence. When the real rows disagree with the fixture, the fixture is fixed and the case added (real runs are the source of truth).

## 12. Build order

All offline until the last step.

| Phase | What |
|---|---|
| 0 | This spec (draft PR) |
| 1 | Resource Graph and REST reader, `rebuild/scope.json`, the never-collect scrubber and scan, the additive `rebuild/` package files, tests; facts output proven unchanged |
| 2 | `rebuild/lz-parameters.json` with its pin and CI check; `Get-LzRebuildMap` and the round-trip fixtures; a private `rebuild-map.json` in the package and a coverage line in the summary |
| 3 | The paired C11 and fact register change in section 7 (avd-second-brain first) |
| 4 | Optional: the diagram step reads the saved rows |
| 5 | The sandbox round trip, with the owner's go |

## Sources

- avd-landing-zone `bicep/main.bicep` and `bicep/modules/` at `2c441569a5d584ac6beb473162ba1f1420caea3e`.
- avd-second-brain `contracts/schemas/current-state-facts.schema.json` and `contracts/fact-register.json` at `fccd644` (vendored here in `contracts/`); `docs/assess-spec.md` sections 6.1 and 10.
- avd-assess `methods/collection.md`, steps 1, 3 and 7.
- avd-second-brain `docs/v1-review.md`, D18; this repo's draft `docs/diagram-spec.md` (PR #13).
- [Azure Resource Graph table and resource type reference](https://learn.microsoft.com/azure/governance/resource-graph/reference/supported-tables-resources).
