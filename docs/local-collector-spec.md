# Spec: current-state on hosts and devices (the local collector)

Status: draft, 2026-10-21. Nothing is built. No Azure, no spend. Red-teamed (section 12); open questions in section 13.

The owner, 2026-10-21: avd-current-state "has been approached as an admin tool but could also become a collector/validator that runs in the target AVD environment for the preflight and also on the end-user device for troubleshooting as well as session host collector too", and "maybe the collector should be an optional part of avd-current-state". Today every script here runs from Cloud Shell or a workstation and reads Azure Resource Manager. This spec adds an **optional local collector**: one script that runs on the machine it describes, reads only that machine, and writes only to a local folder. The avd-linecheck log bundle (avd-linecheck `docs/spec.md` section 17) is built here as two of its modes, so there is one on-box collector in the family instead of two. The owner set the roles the same day: "avd-assess should be the map and the dictionary, avd-current-state is the collector/validator, landing zone is the deployment engine, linecheck is the enduser portal".

## 1. Rules it keeps

- **Self-contained.** avd-current-state still runs end to end with nothing else: the local collector needs no brain, no avd-swarm, no landing zone and no linecheck page, and the admin scripts never need the local collector. What it uses from avd-assess (fact IDs, the endpoint map) is a pinned, hash-checked copy, as today; nothing is fetched at run time.
- **Read-only.** The local collector reads files, the registry, event logs, CIM classes and performance counters, and writes only its own output folder. It never changes a setting, starts or stops a service or installs anything, and writes no event of its own (Windows still logs the run as it logs any script, through script block logging and AMSI where they are on). avd-current-state ships **no code that starts it remotely** (no Run Command, no Intune call): starting a script on a host is an action on the estate, so it belongs to whoever owns writes there (section 5).
- **No identity, no secrets.** The local collector never signs in to Azure, Entra or Graph, never asks for a token (the instance metadata service is read for metadata only, never `/metadata/identity`), and holds no key, SAS or password. Nothing it writes leaves the machine unless a person copies it.
- **Nothing uploaded, ever, by this tool.** Not by default and not as an option in version 1 (avd-linecheck 17.3). The person who runs it decides where the output goes.
- **Facts, not data, go upward.** Raw logs and inventory stay in a private local bundle. Only what `avd_current_state_facts.ps1` turns into counts, public values and pseudonyms reaches C11 (section 7). An end-user device never reaches C11 at all.
- **Upper layers are never a dependency** (avd-second-brain decision 0020). When the brain and avd-swarm are in use they read what this emits; they are not needed to run it.

## 2. Three places it runs

| Mode | Runs on | Started by | Answers |
|---|---|---|---|
| **Admin** (today, unchanged) | Cloud Shell or a workstation | An operator | What is deployed, from Azure Resource Manager and Resource Graph, with Reader |
| **Environment** (new) | A Windows VM inside the target AVD network: a preflight VM or the landing zone's jumpbox before any host exists (`-Mode Preflight`), or a session host (`-Mode Host`, elevated; `-Mode Session`, as the signed-in user) | An operator on the VM, or a delivery path the owner chose (section 5) | What only a machine on that network or that host can see: name resolution, reachability, in-guest configuration, host logs |
| **Device** (new) | The user's own Windows device (`-Mode Device`) | The user, with a script their helpdesk deployed | Why this user's connection, Windows App or Teams misbehaves, with the device's own logs, inventory and health |

`-Mode Session` and `-Mode Device` are the two halves of the avd-linecheck log bundle (its 17.2 "inside the remote session" and "the user's own device"); `-Mode Host` is its "admin switch". `-Mode Preflight` and `-Mode Host` are new.

## 3. What each mode collects and checks

Every source is a row in `local/sources.json`: the mode, the source (file pattern, registry path, channel, CIM class, counter set), the property allowlist where there is one, whether it needs admin (yes, no, unknown), the privacy class (section 6), and the Learn page and anchor it comes from. A source the script cannot read is recorded as `access-denied`, `not-present` or `locked`, never a failure of the run and never silently skipped (avd-linecheck 17.2).

Every check is an entry in the shared catalog (`checks/catalog.json`, contract C22, [checks-spec.md](checks-spec.md)) with one more field, `runsOn` (`admin`, `preflight`, `host`, `session`, `device`), so a check exists once whichever machine runs it, and the landing zone's vendored copy carries the same IDs. Checks stay pure functions over facts, tested offline with fixtures.

### 3.1 Preflight, on a VM in the target subnet

What Azure Resource Manager cannot tell the validator from outside. Results are keyed to the **subnet** the probe VM sits on (the admin run already knows the subnet and gives it a pseudonym), because network security groups, routes and firewalls differ per subnet; the probe VM's `vmId` (section 7) proves where it ran. The probes go only to names in the endpoint map, which lives in avd-assess as part of the map (owner, 2026-10-21; avd-linecheck question 6, avd-current-state #28), each row citing its Learn pin, and is carried here as a pinned, hash-checked copy like the other avd-assess files plus the names the operator passes; a test keeps the probe list equal to the map.

| Check | How (built-in only) | Source |
|---|---|---|
| Required AVD endpoints reachable from the subnet | TCP connect to 443 per name with `Test-NetConnection` (no payload; the validator's own probe uses `System.Net.Sockets.TcpClient`, which CLM blocks, so the two are not shared code); no TLS handshake, which has no cmdlet in Windows PowerShell 5.1 and would need .NET calls; wildcards are listed as "not testable". When a WinHTTP proxy is configured (next row), a direct connect that fails is WARN "direct path closed, proxy in use", not FAIL, because hosts may reach the endpoints through it; whether the proxy itself lets them through is not tested in version 1 | Required FQDNs and endpoints for AVD (`learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint`) |
| Instance metadata reachable (the host's `MetaDataServiceCheck`) | A metadata `GET` with `Metadata: true` through `Invoke-RestMethod`; Windows PowerShell 5.1 has no `-NoProxy`, so a proxy that intercepts it shows as a failure with the proxy named, which is the finding | Troubleshoot the AVD agent, "MetaDataServiceCheck" |
| Proxy that hosts would use | WinHTTP proxy (`netsh winhttp show proxy`) | Proxy guidelines for AVD |
| Private endpoints resolve to private addresses | `Resolve-DnsName` for each storage and Key Vault endpoint the admin run found; records "public answer" or "private answer", never the address in facts | Private endpoint DNS |
| Profile share reachable | TCP 445 to the share's endpoint | FSLogix and Azure Files prerequisites |
| Domain controllers reachable on core ports (AD DS or hybrid only; not proof that a join will work) | DC locator SRV lookup and TCP 389, 88, 445 to the answers | AD DS join prerequisites |
| Windows activation and time | TCP 1688 to the Azure KMS name; time source (`w32tm /query /source`) | Azure KMS for Windows VMs |

Results come back to the validator: `avd_deployment_validator.ps1 -Mode Preflight -LocalPath <folder>` reads the local results as more facts for the same run and one report (checks-spec 2.3), with the same IDs, PASS/WARN/FAIL/INFO/SKIP, and `SKIP` where no local run was made. The admin preflight keeps working without them.

### 3.2 Host, on a session host (elevated)

Point-in-time in-guest state that Reader cannot see (rebuild-fidelity-spec section 6: FSLogix on hosts the landing zone did not build is `unknown` today) and the host's own logs.

| Area | Built-in source | Goes into facts | Stays in the bundle |
|---|---|---|---|
| AVD agent stack | Agent, boot loader, side-by-side stack and Geneva monitoring agent versions from the uninstall keys, by product name (never `Win32_Product`, which Learn's URL tool steps use and which triggers Windows Installer consistency checks and repairs) | Versions | Agent and boot loader logs, installer logs |
| Required endpoints from the host | `WVDAgentUrlTool.exe` from the installed agent folder, when present (Microsoft ships it with agent 1.0.2944.400 and later; it needs .NET Framework 4.6.2, its `.config` beside it, and an elevated prompt). It probes names from its own config, not the pinned map, so it is the one named exception to the probe-list test. Before running it as admin or SYSTEM the script checks its path is under `%ProgramFiles%\Microsoft RDInfra` and its Authenticode publisher is Microsoft. It explains a failed `UrlsAccessibleCheck` from the API rather than repeating it. Otherwise the preflight probes | Count reachable, count not | The tool's output |
| FSLogix | Version; `HKLM\SOFTWARE\FSLogix\Profiles` and `HKLM\SOFTWARE\Policies\FSLogix\ODFC` by an allowlist of value names, both `VHDLocations` and `CCDLocations` (Cloud Cache), policy keys taking precedence where both exist (`learn.microsoft.com/fslogix/reference-configuration-settings`) | Enabled, container type, size set or not, number of locations, location kind (Azure Files, Azure NetApp Files, other SMB, page blob through Cloud Cache) | The location paths themselves, with any `connectionString=` part of a Cloud Cache entry replaced by `<redacted>` (a plain-text entry can hold a storage key; only a `\|fslogix/<name>\|` credential reference is kept), and the profile and ODFC logs (they name users) |
| Remote protocol | RDP Shortpath and UDP settings, multimedia redirection and Teams optimization installed (WebRTC redirector or the new VDI plugin), `IsWVDEnvironment` | On, off or not present | |
| Image and servicing | OS build and last update, pending reboot, the landing zone's WDOT stamp (avd-landing-zone #98) | Values | |
| Health | Disk free, uptime, Defender status and signature age, crashes in the window (Reliability Monitor) | Values with labels, never verdicts without a cited line (avd-linecheck 17.7) | |
| Events | The channels AVD Insights collects (AVD Insights glossary, "Windows Event Logs") in the time window | Counts by channel and event ID only, never message text | All matching events, every user's |

**Unattended by default.** The owner, 2026-10-21: "host side should assume remote run/scheduled run". So host mode is designed for nobody at the console: a remote run (a managed Run Command) or a scheduled one (section 5.1), with the interactive Bastion run as the fallback for a broken host. It follows that:

- **The default output is facts only.** An unattended run collects the facts in this table and writes them as the compact, name-free summary its caller reads back (5.1). It does not build a bundle of logs and events, because nobody is there to take it off the host and a scheduled run would pile up every user's events on a shared disk. `-Bundle` adds the bundle, for one host and one ticket, and is never set by a schedule.
- **Nothing to answer.** No prompt, no confirmation, no consent screen (Run Command cannot prompt); the routine and its switches come from the caller, and anything missing is an error in the summary, not a question.
- **Safe to repeat.** Runs are idempotent: each writes a new `local-facts.json` over the last one in its own admin-only folder, so a schedule leaves one current file, not a growing pile. Overwriting its own last facts file is the one replace it does; the copy that counts is the one the caller read back.
- **Light on a busy host.** A scheduled run reads facts only (a few seconds, no event export, no zip), takes no performance sample, and the schedule's owner puts it outside working hours.

**Where a host bundle goes (with `-Bundle`).** A host bundle holds every user's events, and a pooled host is shared and often reimaged, so where it lands matters:

- The script creates a new, randomly named folder that must not already exist and must not be a reparse point, under a root only administrators and SYSTEM can read (it removes inherited access on its own folder, since a folder under `%ProgramData%` inherits read access for Users), or under `-OutputPath` if the operator names one with the same checks.
- It prints that path in its last lines, inside the compact summary (section 5), so the operator knows what to fetch.
- The bundle on the host is a working copy, not evidence. The operator copies it off (a Bastion file transfer or the organization's own tooling) into the private evidence package; only that copy counts for "never delete the last copy" (avd-second-brain decision 0016), and a reimage that removes the host copy loses nothing that was kept. Until it is copied off, the script's last screen says so.
- Host mode can run while users are signed in; it reads event logs and zips up to 200 MB, so the README says to run it on a drained host or out of hours where possible (question 9).

### 3.3 Session, inside the remote session (as the user)

Exactly avd-linecheck 17.2 "inside the remote session": new Teams logs and the Ctrl+Alt+Shift+1 file, `Vdi_debug.txt`, the events the user can read, FSLogix profile status, a performance sample with the per-session RemoteFX and user input delay counters. Nothing from this mode goes into facts: it is one user's troubleshooting.

### 3.4 Device, on the user's own Windows device

Exactly avd-linecheck 17.2 "the user's own device" and 17.7 (inventory, health, performance with property allowlists, CLM-safe sources), plus 17.6's added files (screenshots, a recording, `comments.txt`) and the latest avd-linecheck result JSON if it is in Downloads. macOS, iOS and Android point to the Windows App's in-app log steps; Linux thin clients and Windows 365 Link get nothing on the device side (avd-linecheck 17.1). Nothing from this mode goes into facts.

### 3.5 What the local collector does not do

- **No continuous collection.** Fleet-wide host events and counters are AVD Insights' job (Azure Monitor Agent and its data collection rule). The admin run reads them from Log Analytics, an opt-in read already proposed in the diagnostics pillar (avd-assess `gaps/diagnostics-scope.md`); the local collector covers what that does not: in-guest configuration, files and a point in time.
- **No compliance engine.** Where the estate runs Azure Machine Configuration in audit mode, its results are ARM resources the admin run reads (drift spec phase 2, avd-current-state #37). The local collector is for hosts without it and for logs.
- **No remediation.** A finding becomes a plan in its owning pillar (avd-assess `gaps/remediation-plan.md`); the landing zone or avd-swarm makes the change.

## 4. One entry point that runs anywhere

The owner, 2026-10-21: avd-current-state "becomes the orchestrator that can run anywhere and invoke the right sub routine". So the repo gets one front door, `avd_current_state.ps1` (name to confirm, question 1), and every script behind it becomes a routine it calls:

| Routine | Today | Where it runs |
|---|---|---|
| `collect` | `avd_current_state_collector.ps1` | Cloud Shell, Windows, macOS, Linux (PowerShell 7, Az modules) |
| `validate` | `avd_deployment_validator.ps1` | The same |
| `facts` | `avd_current_state_facts.ps1` | The same, offline |
| `assess` | `facts -Assess` and the method runner | The same, offline |
| `local` | The local collector, `-Mode Preflight\|Host\|Session\|Device` (sections 3 and 5) | Windows: Windows PowerShell 5.1 or PowerShell 7 |

**PowerShell, not Python.** Windows PowerShell 5.1 is on every Windows host and device and is what App Control and Constrained Language Mode govern; Python is not on Windows by default and installing it on a session host or a user's device is exactly what the on-box modes must not need. Cloud Shell, macOS and Linux run the same file through `pwsh`, and bash calls it through `pwsh -NoProfile -File`, the family's run-anywhere convention (avd-ops decision 0006), so no Python twin is needed.

**How it picks a routine.** `avd_current_state.ps1` with no arguments looks only at local signals, prints what it found and what it would run, and runs nothing until the person confirms or passes the routine:

| Signal (read locally, no network call) | Suggests |
|---|---|
| Cloud Shell's environment, or a non-Windows system, or the Az modules with a signed-in context | `collect` or `validate` (asks which) |
| The AVD agent is installed and the process is elevated | `local -Mode Host` |
| The AVD agent is installed and the user is in a remote session | `local -Mode Session` |
| Windows with no AVD agent | `local -Mode Device` |
| Anything else, or two signals at once | Lists the routines and asks |

`-Mode Preflight` is never guessed: a preflight VM looks like any other Windows VM, so the operator names it. Detection never elevates, never signs in and never probes the network (device mode allows none), and an explicit routine always wins over a guess (`avd_current_state.ps1 local -Mode Host -AllUsers`, `avd_current_state.ps1 validate -Mode Preflight`). Without a console (Run Command, an Intune script) there is nobody to confirm, so the routine must be passed or the script exits with the list.

**One file per release asset, by audience.** The front door dispatches to the scripts in a clone for the admin routines, as the existing scripts keep working unchanged when called directly. The **signed** release asset for helpdesks is the front door with only the `local` routine assembled in (one CLM-safe file, the rest of this section); the admin routines are not in it, because they need the Az modules and a clone anyway and 0008 leaves them unsigned. Both are built from the same sources, and a test checks the dispatch table is the same in both.

## 4a. The local routine, built for locked-down machines

- **One signed `.ps1`** in the release: the front door with the `local` routine (section 4), assembled from `lib/AvdLocal.psm1` (pure functions: source list, manifest, path normalization, allowlists, caps, fact extraction) and `local/sources.json`. A test compares the assembled script with its sources.
- **Windows PowerShell 5.1 first,** because it is on every Windows host and device; it also runs in PowerShell 7. Written for **Constrained Language Mode**, because session hosts and managed devices run App Control as often as user devices do. The rule is CLM's own: no types outside its allowed list (no `Add-Type`, no classes, no `New-Object` or method calls on types it does not allow), elevation read from `whoami /groups`, the rest of avd-linecheck 17.5. A signed script may run in Full Language Mode; it is written not to need it. CI runs the functions in a child runspace with `ConstrainedLanguage` on a `windows-latest` job in Windows PowerShell, since the Linux job has no event log, counters or CIM.
- **Trusted sources only.** Modules are imported by full path, never by name: DnsClient, NetTCPIP, Storage and Defender from `$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules` (in PowerShell 7, `$PSHOME` is the pwsh folder and lacks them), and CimCmdlets, Microsoft.PowerShell.Diagnostics and Microsoft.PowerShell.Archive from `$PSHOME\Modules` in either edition, so a module planted in a user's `Documents\WindowsPowerShell\Modules` is not loaded; programs run by full path from one allowlist per mode in `sources.json` (`$env:SystemRoot\System32\netsh.exe`, `w32tm.exe`, `whoami.exe`, `powercfg.exe`, and the URL tool's checked path); every documented command line starts PowerShell with `-NoProfile`.
- **Never follows a link.** Host and session modes copy from folders users can write to. Every copy uses `-LiteralPath`, skips any file or folder whose attributes carry `ReparsePoint` (recorded as "skipped: reparse point"), checks that the resolved path stays under the source's root, and applies the same rules to `-Add` paths and the "add files" folder, so a junction a user plants in their own profile cannot pull another user's files or a system file into an elevated collection. S1 has a junction fixture.
- **Network rule per mode.** Device and session modes make no network call at all, enforced by the source test in avd-linecheck 17.5. Preflight and host modes make only the probes in 3.1 and 3.2, to names from the pinned map or the operator's list (the URL tool is the one exception, 3.2); a test fails on any other web cmdlet, `System.Net` type or program, and on any `-ComputerName` or `-CimSession` argument (no reaching into another machine).
- **Refuses the wrong privilege and the wrong context.** Device and session modes refuse to run elevated or as SYSTEM, and say "ran as SYSTEM, wrong context" in their first line, which is what an Intune platform script or remediation deployed with its defaults would do (they run as SYSTEM; platform scripts default to a 32-bit host); the README gives the settings that work (run in the user's context, 64-bit host, signature check on). Host mode refuses to run without elevation and says why; preflight works either way.
- **Never prompts in host mode.** Run Command does not support interactive scripts, so host mode has no consent screen: `-AllUsers` is the explicit acknowledgment, and `-RequestedBy <text>` (a person's note or an approved plan ID, never a secret) goes into the manifest, because under Run Command the account the script sees is SYSTEM.
- **`-ListSources`** prints what a mode would read, with the admin need and privacy class of each source, and reads nothing: the dry run a helpdesk or a security reviewer checks first.
- **Every output file has a `schemaVersion`.**
- **Bounded:** a time window (24 hours by default), a cap per source (50 MB) and for the whole output (200 MB), a performance sample of at most 5 minutes, and the budget table of avd-linecheck 17.3. Logs are staged before zipping because of `Compress-Archive`'s limits on open files (17.3).
- **Localized systems:** counter sets by index, events by ID and channel, folders by known-folder ID, never by display text (17.7).
- **Platforms.** `platforms.json` gets an entry with `winps51` and `windows` for every mode; `macos` and the Cloud Shell columns are `no` for the local collector (Cloud Shell is not on a host or a device). A macOS device mode is a later decision (question 5).

## 5. How each mode reaches the machine, and why it is trusted

| Mode | Delivery | Trust |
|---|---|---|
| Admin | As today: clone a release tag in Cloud Shell (avd-ops decision 0008, section 5.1) | Release tag and attestation, no Authenticode (0008 says why) |
| Preflight | An operator on the jumpbox (avd-landing-zone decision 0019) or a preflight VM, through Bastion | The signed release, verified with `Get-AuthenticodeSignature` and `gh attestation verify` before it runs |
| Host | (a) an operator on one host through Bastion; (b) a **managed Run Command**, created by the landing zone or an approved avd-swarm plan, never by this repo; (c) the organization's own tooling: Intune Remediations or platform scripts, Group Policy, an RMM product | The signed release. Run Command checks no signature or hash itself, so for (b) the creator pins the immutable release asset by URL and hash, and that pin (or App Control on the host) is the trust anchor; a script checking its own signature proves nothing, so it does not claim to; for (c) the organization re-signs or pins the hash (0008, section 5.2) |
| Session | The user's helpdesk deploys it to the host image or offers it in the session (Intune, Company Portal) | The signed release |
| Device | The helpdesk deploys it (Intune, Company Portal) or runs it with the user; the linecheck page explains it and never shows a command to paste (avd-linecheck 17.5) | The signed release |

Facts that shape the Run Command path (`learn.microsoft.com/azure/virtual-machines/windows/run-command`, "Restrictions" and "Limiting access to Run Command"; `run-command-managed`, "Limiting access to Run Command"; `run-command-overview`, "Compare feature support"):

- There are two kinds. An **action** Run Command needs `Microsoft.Compute/virtualMachines/runCommand/action`, runs as SYSTEM, returns only the last 4,096 bytes of output, and allows one at a time. A **managed** Run Command needs `Microsoft.Compute/virtualMachines/runCommands/write`, is an ARM child resource, runs as SYSTEM or a named user, takes a `scriptUri`, and can append its output to a blob using the VM's managed identity, with no SAS. The landing zone already uses managed Run Commands (`Configure-FSLogix`, `Register-AvdAgent`), so phase 5 uses the managed kind.
- Both are write-capable permissions (Virtual Machine Contributor or above), and running one installs the Run Command extension on the host. So it is a write the landing zone owns, the optional reader identity (Reader only, still a proposal awaiting the owner) can never start host mode, and in an estate with the brain it is an avd-swarm plan with a person's approval, like every other action.
- Whatever starts it, host mode prints only a compact, name-free summary (counts, enums, and the bundle's path on the host when `-Bundle` was set) that fits in 4,096 bytes, and keeps any bundle on the host's disk (3.2). Sending the bundle itself to a blob in the run store is phase 5's choice, made in the landing zone with its own review, since it moves personal data off the host.
- Run Command needs outbound 443 to Azure, and does not run when the VM agent is not ready, so a broken host is exactly where it may fail: the Bastion path stays the fallback. Hosts that are not Azure VMs differ: Windows 365 Cloud PCs have no Run Command and use paths (a) and (c); Arc-enabled servers, Azure Local VMs among them, have their own Run Command (`Microsoft.HybridCompute/machines/runCommands`, preview, written with `runCommands/write`), which phase 5 treats the same way as the VM kind, and their own metadata service, so their `vmId` comes from the Arc agent or stays `none` (question 10).

### 5.1 Remote and scheduled host runs

Host mode assumes it was started remotely or on a schedule (3.2). The design keeps every write with the landing zone and every read with avd-current-state:

1. **The landing zone owns the run.** On each host it builds, it creates one managed Run Command (`avdcs-local`, alongside its `Configure-FSLogix` and `Register-AvdAgent`), whose `scriptUri` is the immutable signed release asset, pinned by tag and hash, with `local -Mode Host` and no `-Bundle`. A remote run is the landing zone (or an approved avd-swarm plan) updating that resource; a **scheduled run** is the landing zone re-running it on a timer from its existing Automation account and managed identity (the pattern of its auto-shutdown runbook, avd-landing-zone decision 0011), outside working hours, on running hosts only (it never starts a deallocated host, so it never turns the meter on).
2. **avd-current-state only reads the result.** The managed Run Command keeps its last output in `instanceView`, limited to the last 4 KB, which a `GET .../runCommands/avdcs-local?$expand=instanceView` returns (`learn.microsoft.com/azure/virtual-machines/windows/run-command-managed`, "Get output details"). That is a read, so the admin `collect` routine picks up every host's last facts with Reader, alongside the rest of the estate, with no identity on the host, no storage write, no SAS and nothing to copy. The summary is designed for that limit: name-free counts and enums, a `schemaVersion`, the run time and the script version. A host whose summary is missing, older than the window (section 7) or from another script version is `unknown`, never a pass.
3. **The join is free.** The Run Command is a child of the VM resource, so the result already belongs to the right session host; the `vmId` check of section 7 still runs, as a guard against a summary from a reimaged host.
4. **Bundles stay on demand.** `-Bundle` is set only for a one-off remote run on one host, by a person or an approved plan, and retrieval follows 3.2.
5. **Without the landing zone** (a brownfield estate), the same script runs as a scheduled task the organization deploys through Intune, Group Policy or an RMM tool, writing `local-facts.json` to its admin-only folder; the operator collects those files (`-LocalPath`, section 7). avd-current-state still starts nothing.

Signing: the code-signing convention (avd-ops decision 0008, section 5.2) was written for the avd-linecheck log bundle. Since the bundle is built here, the same design moves with it: the release workflow, the `environment:release` federated credential and the Artifact Signing profile belong to `avd-ops/avd-current-state` instead of `avd-ops/avd-linecheck`, and 0008 is amended to say so (an avd-ops PR). Like every repo, this one gets immutable releases, a `v*` tag ruleset and attestations at no cost (0008 section 5.1); the Artifact Signing account is created only when the first on-box release is ready. The admin scripts stay unsigned as 0008 section 5.1 decided. Signing remains a prerequisite for shipping any on-box mode; its account is parked in roadmap issue avd-current-state #41 (moved from avd-linecheck #3, now closed).

## 6. Privacy

Three classes, written into every source row and every output file:

| Class | What | Where it may go |
|---|---|---|
| **facts** | Counts, booleans, enums, versions, keyed to the machine by name only inside the private package | Through `avd_current_state_facts.ps1` into C11 as counts and pseudonyms |
| **private** | Host and device names, paths, installed-app lists, inventory, `local-facts.json` itself | The operator's private evidence package, like the collector package today |
| **personal** | Logs, events, Teams files, screenshots, recordings, comments, performance samples | The local bundle only: a zip in the operator's output folder (preflight, host) or the user's Downloads (session, device). Never into this repo, an issue, a fixture, C11 or the brain |

- **A shared host shows other people.** On a multi-session host the Application, System and session manager logs carry every user's names and sessions, and most events carry no session ID (avd-linecheck 17.2). Host mode collects them only with `-AllUsers`, recorded in the manifest with `-RequestedBy`; session mode reads only what the signed-in user can read and says that some of it may still be other users'. An organization's notice to its users is not the same as a user's consent, and whether it is enough depends on the law where the users are; the README leaves that decision to the organization and says so plainly, and this repo makes no claim either way.
- **Consent screens** for session and device modes as in avd-linecheck 17.4: the list of sources, "contains personal data: yes", and no scrubbing claimed.
- **Metadata is private:** the instance metadata service returns the subscription, VM name, tags and addresses, so only `vmId` is kept, in the private class. **Facts extraction reads values, not text:** event counts by ID, never message text; FSLogix location kind, never the path; app presence by product name from an allowlist, never the installed-apps list.
- **Retention:** the zip stays where it was written until someone deletes it; the last screen and the README say when to delete it (avd-linecheck 17.3). Copies the operator has taken into the private evidence package are evidence, so the family rule applies: nothing here deletes them (avd-second-brain decision 0016). The working copy left on a host (3.2) is not; the README tells the operator to delete it once the copy is checked, and the script never deletes anything itself.

## 7. How the output feeds the contracts

Each run writes, in its output folder:

- `local-facts.json`: `schemaVersion`, the mode, the script version, the run time, the machine's identity (the Azure `vmId` from the metadata service when reachable, with `idSource: imds`; otherwise `idSource: none` and no ID, because the SMBIOS UUID is not guaranteed to match `vmId` byte for byte; plus the computer name; all private) and the facts by proposed fact ID. It is a private file this repo defines and reads; it is not a contract, because nothing outside avd-current-state reads it.
- `manifest.json` and the bundle zip, as in avd-linecheck 17.3.

Then:

1. **C11.** `avd_current_state_facts.ps1 -LocalPath <folder of local-facts files>` matches each host's file to its session host in the admin package by **`vmId`** (the session host API carries `virtualMachineId`), and by name only when the file has no `vmId`, because the computer name, its FQDN, the session host name (`hostpool/host.domain`) and the VM resource name differ, and two pools can reuse a computer name. Duplicates and name-only matches that hit more than one host are reported as `ambiguous` and left out. It refuses a file whose run time is outside the window the operator sets (7 days before the admin run by default), a file whose mode is not `Host` or `Preflight`, and keeps only the newest file per `vmId`, with a warning. Every merged file's name and SHA-256 goes into the private manifest, and each local fact carries `source: local`, so a check can say "from a local run, not verified by Azure". Then it adds per-host-pool counts to the snapshot: hosts with a local run, FSLogix enabled, Teams optimization present, WDOT applied, pending reboot, the agent versions seen, endpoints unreachable. Pseudonyms and redaction work as today. A host pool with no local runs gets no local facts, so its checks are `unknown`, never a pass. Preflight results become per-host-subnet facts next to the register's existing `c11.network.hostSubnets.*` facts (proposed `c11.network.hostSubnets.preflight*`), counted per subnet pseudonym, never per subscription. Device and session files are refused by the facts script.
2. **The fact register (C15).** The new facts are proposed in avd-assess first (`proposed:c11.hostPool.sessionHosts.local*`, `proposed:c11.network.hostSubnets.preflight*`), then `specified`, then `built`, the way every pillar adds facts. A C11 schema change follows the foundation contract rule (avd-assess first, then this repo and avd-second-brain re-pin).
3. **C21.** The assess method runs over the snapshot as today. The new facts let method checks that are `unknown` now resolve: the host baseline profile (`gaps/host-baseline-profile.md`), the FSLogix and Teams optimization rows, the diagnostics pillar's step 7 ("go to the host ... only when the flow says so").
4. **C22.** Each local check carries `runsOn`; proposed with the C22 schema in avd-assess (checks-spec, build order phase 1).
5. **Clients.** The fleet view of client devices comes from the service's own connection records in Log Analytics (`WVDConnections` client type, OS and version), which the endpoints pillar proposes as facts in avd-assess (#34; not yet in the register), not from device bundles. A device bundle informs one ticket; it never becomes an estate fact.

Nothing here needs the brain or avd-swarm. When they are in use, the brain reads C11 as it does now; avd-swarm sees only cited C11 facts; a host-mode Run Command is an action in avd-swarm's catalog, which is a paired avd-second-brain and avd-swarm change when it is built (question 6).

## 8. Prior art: build or adopt

The family rule: adopt only what is the best at the job and open source; the Microsoft platform is exempt (avd-ops `docs/build-or-adopt.md`).

| Prior art | What it does | Decision |
|---|---|---|
| AVD session host health checks in the API | Agent, stack, domain, URL, metadata and monitoring checks per host, readable with Reader | Adopt: the admin run reads them; host mode does not repeat them |
| AVD Insights (Azure Monitor Agent, data collection rule) | Continuous host events and counters in Log Analytics | Adopt for fleet data through the admin run's Log Analytics read; host mode is for what it does not hold |
| `WVDAgentUrlTool.exe` | Ships with the agent; lists required URLs a host cannot reach (not wildcards) | Adopt: host mode runs it where present |
| Azure Machine Configuration (audit) | In-guest compliance as ARM resources | Adopt where deployed (drift spec phase 2); not required |
| Intune "Collect diagnostics" | Remote action for corporate-owned Windows; a fixed collection, uploaded to Microsoft storage for 28 days, which Microsoft personnel may access; Help Desk Operator role; collected and downloaded from the admin center (`learn.microsoft.com/intune/device-management/actions/collect-diagnostics`; Graph has a log collection request for some cases, to be checked in S3) | Link as the helpdesk's built-in path for enrolled devices; not used, because it uploads and its list is not AVD-specific. Spike S3 compares its list with `sources.json` |
| Intune Remediations, Group Policy, RMM | Ways to run a script on many machines | Delivery paths the organization owns (section 5), not collectors |
| TSS with MSRD-Collect | Microsoft's full Remote Desktop collector; elevated; licensed only to help Microsoft troubleshoot, no redistribution | Link as the escalation path; nothing copied, not even a source list (avd-linecheck 17.2) |
| Windows App in-app logs, the web client's "Capture logs" | The client's own log capture | Link for macOS, mobile and the web client |
| osquery | Open-source inventory engine with SQL tables | A third-party binary and agent to install; parity checklist only (avd-linecheck 17.9) |
| Velociraptor offline collector, CyLR, `sos report`, Replicated `support-bundle` | Self-contained collection bundles with manifests, caps and redactors | Design prior art for the manifest and caps; licenses to be read from each license file before anything is reused |
| Community AVD and FSLogix log scripts | Many on GitHub, most without a license | Reference only (guardrails); the `kb-prior-art` run of 2026-10-21 is linked in the PR |
| "Remote Desktop Analyzer" | Named in the request; no Microsoft Learn page found under that name (2026-10-21) | To be identified (question 7) |

So this repo builds only the join: one source list, one allowlisted fact extraction, one manifest, one signed script, on top of what Windows and AVD already ship.

## 9. avd-linecheck

- The **page stays page-first** and never depends on the collector (avd-linecheck section 3). It links to the collector's signed release and explains who deploys it.
- **avd-linecheck spec section 17 stays the design** of the session and device modes (sources, privacy, CLM, bundle layout, user-added files). Its layout in 17.8 (`collector/` in avd-linecheck) becomes `lib/AvdLocal.psm1`, `local/sources.json` and the assembled script here, and 17.8 and question 11 there point at this spec. That edit is made in avd-linecheck by its own thread, not here.
- The signing account is roadmap issue avd-current-state #41 (moved from avd-linecheck #3); the federated credential names this repository. avd-linecheck #5 points its 17.8 and question 11 here.
- **linecheck is the end-user portal** and is hosted on GitHub Pages, so anyone who clones it can use it for free (owner, 2026-10-21). The collector is not part of the page and is not served from it; the page links to this repo's release.
- The page's **guided steps** (avd-linecheck section 18, PR #4) are the user's path on any device; the collector is the helpdesk's path on managed Windows. A step page may say "your helpdesk can collect logs for you" and link the collector's README, never a command.

## 10. Spikes and build order

Spikes, offline or free first:

- **S1 (offline):** readers return plain objects; fixtures are JSON captured from the readers, so the pure functions run on Linux; `lib/AvdLocal.psm1` against a synthetic profile and registry tree with a junction in it; the CLM runspace and reader tests on a Windows job; the network and program-allowlist tests; the assembled script test (which strips the signature block and checks the family notice comes first).
- **S2 (free):** device and session modes on a Windows 11 device as a standard user (avd-linecheck S5a: one spike, run once, recorded here).
- **S3 (free, reading):** Intune Collect diagnostics' list against `sources.json`.
- **S4 (sandbox):** preflight on the landing zone's jumpbox and host mode on one landing zone host, elevated and not, recording which sources need admin and how Run Command's 4 KB limit holds. Needs a cost estimate and the owner's exact `go batch <id> $<total>`; it can ride a batch that already deploys a landing zone, with avd-linecheck S5b.

Build order, each a PR, offline first:

| Phase | Repo | What |
|---|---|---|
| 0 | here | This spec |
| 1 | avd-assess | Proposed fact IDs and `runsOn` in the C22 proposal |
| 2 | here | `lib/AvdLocal.psm1`, `local/sources.json`, `-Mode Device` and `-Mode Session` (the linecheck bundle), unsigned, CI only, no release |
| 3 | here | `-Mode Host` and `-Mode Preflight`, `local-facts.json`, the validator's `-LocalPath`, the facts script's `-LocalPath` |
| 4 | here, avd-ops | Release workflow with Artifact Signing once the signing account exists (#41, the owner's go and cost line) |
| 5 | avd-landing-zone, then here, then avd-second-brain and avd-swarm | The landing zone's `avdcs-local` managed Run Command and its schedule (5.1); `collect` reads its `instanceView`; the swarm action for a remote run, paired |

## 11. Cost

Phases 0 to 3 cost nothing. Running the collector costs nothing: Run Command, Bastion sessions the estate already has and Intune scripts carry no charge from this tool. Signing is avd-ops decision 0008's line (Artifact Signing Basic, $9.99 a month, on the owner's go). S4 is the only cloud run and gets its own estimate.

## 12. Red team

Fable, 2026-10-21. Fifteen findings, all folded in above:

1. A host bundle of every user's events had no location, access or retrieval path, and a pooled host is reimaged: a new SYSTEM- and admin-only folder that must not pre-exist, its path in the summary, the host copy is a working copy until copied off (3.2, questions 8 and 9).
2. Elevated copies from user-writable folders followed junctions: `-LiteralPath`, reparse points skipped, resolved paths kept under the root, a junction fixture (4a).
3. A TLS handshake and a proxy bypass need .NET calls in Windows PowerShell 5.1, and the CLM rule was misstated: TCP connect only, the real CLM rule, metadata through the proxy as a finding (3.1, 4a).
4. The program allowlist and the URL tool were inconsistent: one allowlist per mode with full paths; the URL tool's path and publisher checked, its own name list the one exception; never `Win32_Product` (3.2, 4a).
5. Matching local files to hosts by name was unsound: join on `vmId`, name as fallback, `ambiguous` on duplicates (7).
6. No defense against stale or edited files: a time window, mode check, newest per host, hashes in the manifest, `source: local` (7).
7. Managed and action Run Command were mixed up, and the landing zone already uses the managed kind: corrected, managed for phase 5, no SAS needed, the extension install named as a write, Run Command checks no signature (5).
8. Host mode cannot prompt and sees SYSTEM as its account: no consent screen, `-AllUsers` and `-RequestedBy` (4a, 6).
9. Intune's defaults (SYSTEM, 32-bit) break device and session modes quietly: the settings that work in the README, a first-line context check (4a).
10. Module and program planting in an operator's profile: modules from `$PSHOME`, programs by full path, `-NoProfile` (4a).
11. "Writes no event" was too strong: the run is logged by Windows as any script is (1).
12. The FSLogix ODFC key and Cloud Cache locations were wrong or missing (3.2).
13. Preflight results differ per subnet, and four open ports do not prove a domain join (3.1).
14. Linux CI cannot run the readers or CLM: plain-object readers with JSON fixtures, a Windows job (4a, 10).
15. Missing questions and details: retrieval, hosts signed in, non-Azure hosts, Azure Government, `-ListSources`, `schemaVersion`, notice versus consent, Intune's Graph request (4a, 6, 8, 13).

The code review (Claude code-review skill) caught ten more, also fixed: a Cloud Cache entry can carry a storage key in plain text (redacted); the SMBIOS UUID is no stand-in for `vmId` (no ID instead); the validator's probe uses a type CLM blocks (not shared); a configured proxy turns a failed direct connect into WARN; `$PSHOME` in PowerShell 7 lacks the Windows modules (System32 path); a self-checking signature is no trust anchor (the pin is); Arc and Azure Local do have Run Command; host working copies versus evidence retention made consistent; the client fleet facts are proposed, not registered; preflight facts stay per subnet.

## 13. Open questions for Nick

1. **Name.** The front door `avd_current_state.ps1` with routines `collect`, `validate`, `facts`, `assess`, `local -Mode Preflight|Host|Session|Device` (section 4), or another name (after a name check). The existing script names keep working either way.
2. **Where the log bundle lives.** Answered 2026-10-21: here, as the session and device modes ("avd-current-state is the collector/validator"). Follow-ups: avd-linecheck 17.8, question 11 and #3 point here (the linecheck thread), avd-ops decision 0008 section 5.2 names this repo, and the endpoint map goes to avd-assess.
3. **Host-side collector.** This settles the host half of the open "host-side and directory read-only collectors" decision (avd-assess map plan, section 6) as: a local script, started by a person or by the landing zone or an approved avd-swarm plan, never by avd-current-state. Agree, or prefer another path (for example only Machine Configuration and Log Analytics, no script on hosts).
4. **Order.** Device and session modes first, since avd-linecheck already designed them (recommended), or host and preflight first, since they unlock `unknown` assess checks.
5. **macOS.** Point macOS devices to the Windows App's own logs (recommended for version 1), or plan a PowerShell 7 or bash device mode later.
6. **Run Command delivery.** Answered 2026-10-21: host mode assumes a remote or scheduled run. The proposal in 5.1 (the landing zone owns a managed Run Command and its schedule, `collect` reads the result with Reader) needs a yes, and a schedule: daily outside working hours is the suggested default.
7. **"Remote Desktop Analyzer".** Which tool was meant, so it can be checked as prior art.
8. **Host bundle retrieval.** Bundles are on demand only (`-Bundle`, never on a schedule). Retrieve them by operator copy through Bastion or the organization's tooling (recommended for version 1), or also let the landing zone send them to the run store blob.
9. **Host mode with users signed in.** Scheduled facts-only runs are light enough to run anytime; a `-Bundle` run warns when users are signed in (recommended), or refuses unless the host is drained.
10. **Hosts that are not Azure VMs.** Windows 365 Cloud PCs and Azure Local or Arc hosts in version 1 through paths (a) and (c) only (recommended), or later.
11. **Azure Government.** Commercial endpoint map only, as the rest of this repo (recommended), or a second map.
