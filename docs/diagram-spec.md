# Spec: a redacted estate diagram (wrap and enhance ARI)

Status: draft, 2026-10-20. Nothing is built. No Azure, no spend.

This is an **opt-in step** in avd-current-state that draws a shareable diagram of what is deployed. It wraps the diagram code of [Azure Resource Inventory](https://github.com/microsoft/ARI) (ARI, MIT) and adds what ARI lacks: redaction before anything is drawn, an AVD overlay, stable output and our styling. The collector, the validator and the facts snapshot (contract C11) never need it, and their package formats don't change (avd-second-brain v1 review, decision D18).

## 1. Why ARI, and why only after a bake-off

The owner's direction (2026-10-20): ours must do everything ARI's diagram already does, and wrapping ARI makes sense because it is well known. Before locking that route we ran every credible candidate offline on the same fake estate and scored them. The result and the rule are below. The bake-off scripts and outputs are working notes, not in this repo; phase 1 brings the fixture in as the first test fixture.

### 1.1 The fixture

The ARI spike's nine fake Resource Graph rows, extended: a hub VNet with a `GatewaySubnet` (the rule ARI uses to color a hub), a spoke with a hosts subnet and two session host VMs reached through their NICs, a private endpoint subnet, a peering hub to spoke, a broken peering held by the hub **and** one held by the spoke (both to a VNet not in the rows), one host pool with two session hosts (`resourceId` to the VM), one desktop app group and one workspace, one subscription under two management groups. Every name is a pseudonym; prefixes are 10.x.

### 1.2 Results

PowerShell 7.4.6 on Linux, ARI `main` at `4cc602c` (2026-10-17). Times are wall clock for one run, including module load.

| | ARI diagram + our post-processor | Our Mermaid writer | Graphviz through PSGraph | Diagrammer.Core |
|---|---|---|---|---|
| Ran offline on the fixture | Yes, 4.7 to 5.5 s | Yes, 0.7 s | Yes, 1.2 s | Its exporter hung on Linux (default path is a bundled Windows `dot.exe`); stopped |
| ARI parity (org tree, subscription page with resource counts, VNets, subnets, peerings with flags, hub coloring, broken peering, 30+ resource kinds inside subnets, on-premises, ExpressRoute, VPN, Virtual WAN, Azure icons) | All of it, by definition | Org tree, resource group counts, VNets, subnets, peerings, hub, broken peerings. The rest would be a rewrite of about 6,000 lines of ARI's logic. No Azure icons | Same as the Mermaid writer (we wrote the logic) | Not reached |
| Broken peering held by the spoke | **Missed** (only the hub's was drawn) | Drawn | Drawn | |
| Private endpoint subnet | Labeled "1 Network Interface" | "1 private endpoint" | Not written in the trial | |
| AVD overlay | Worked as a post-process of about 20 lines: the subnet's VM group becomes the host pool with the AVD icon, with app group and workspace as attributes. App group and workspace aren't drawn as boxes; the label overlaps the subnet text | Native: host pool on the subnet, app group and workspace as nodes with edges | Native, same as Mermaid | |
| Two runs identical | Raw: no (random cell IDs, a date label, and per-VNet subnet files merged in random-name order). After the post-processor (drop the date, sort each page's cells by a key that ignores IDs, renumber): byte-identical over three runs | Yes, by construction | SVG yes; the DOT text no (PSGraph writes attributes in hashtable order) | |
| Renders | draw.io: editable; the post-processed file rendered in the draw.io viewer. GitHub doesn't render `.drawio` inline | GitHub renders it inline; avd-ops can render it with Mermaid JS. Weak styling: a class on a subgraph didn't apply and subgraph titles overlapped | Best cluster layout; SVG and PNG | |
| What it needs | PowerShell 7. `Install-Module AzureResourceInventory` pulled 98 MB (ARI plus ImportExcel and six Az modules) that drawing doesn't use; loading only the seven diagram scripts (6,170 lines) needs nothing else | Nothing in PowerShell; 5.1-compatible. A browser renders it | The Graphviz binary (not verified in Cloud Shell) and PSGraph (last commit 2019) | 91 MB module with 102 bundled Windows Graphviz binaries, plus PSGraph |
| License | MIT (see 1.4) | Ours, MIT | Graphviz EPL, PSGraph MIT | MIT |
| Upstream fit | Every fix reaches ARI's users | None | None | None |

**Dropped without a trial, and why:**

- **AzViz** (MIT): its network mode draws from the Network Watcher topology API, live, per resource group. Feeding it the fixture means faking a Microsoft API we don't otherwise hold. Last commit 2025-02.
- **Microsoft's azure-resource-visualizer skill** (MIT): a model decides the relationships, which breaks "a model never decides" and isn't repeatable. Its edge rules stay a reference.
- **Network Watcher topology** (Azure service): portal only, real names, not scriptable into a package. Linked in docs as the live view.
- **AzureResourceMap** (MIT): .NET, reads ARM live, author calls it a first pass.
- **D2**: needs a binary; nothing it does that Graphviz didn't show here.

### 1.3 What the bake-off found that the spike didn't

1. **ARI's hub rule is a subnet named `GatewaySubnet`.** Redaction must keep Azure's reserved subnet names (section 4), or every hub is drawn as a spoke.
2. **The instability has a second cause besides random IDs:** ARI writes one cache file per VNet under a random name and merges them in name order. Renumbering alone isn't enough; the post-processor must also sort.
3. **Post-processing is enough for overlay and stability,** so none of our needs waits on an upstream change.
4. **Two ARI gaps confirmed on the extended fixture:** a spoke's own broken peering isn't drawn, and a private endpoint subnet reads as a NIC.
5. **PowerShell Gallery was reachable from this container** (`Save-Module` worked), unlike earlier sessions. Don't rely on it in CI.

### 1.4 License

The repo's `LICENSE` is MIT. The Gallery package (3.6.15) carries the same diagram scripts as the repo at `4cc602c`, identical apart from line endings; its manifest's `Copyright` field says "(c) Claudio Merola. All rights reserved." and its `LicenseUri` points to the repo's MIT `LICENSE`. We read that field as the manifest's usual copyright line, with MIT as the grant. Either way, this design **calls** ARI's scripts from a pinned copy and copies none of them into this repo, so the question only matters if we ever vendor them; then both notices travel with the files. This is a reading, not legal advice.

### 1.5 Decision rule, and the answer

The ARI route is locked when, on the extended fixture, its wrapped output (a) draws every item on ARI's parity list that the fixture contains, (b) carries the AVD overlay, (c) is byte-identical over three runs, (d) passes the presence check (section 7), and (e) renders in draw.io. A writer of our own replaces it only if ARI fails one of these and post-processing can't fix it.

**All five passed, so the ARI route is locked.** The bake-off didn't change the recommendation; it changed the plan in three places: the post-processor sorts as well as renumbers, redaction keeps reserved subnet names, and the wrapper reports what ARI misses (spoke-held broken peerings) instead of trusting it.

What our own writer does better (GitHub rendering, PowerShell 5.1, AVD-native boxes, the spoke peering) is real but narrow: an AVD-only view, not a replacement. It is phase 4, optional (section 10).

**Reopen** the choice if a sandbox run shows ARI failing on real Resource Graph rows in a way post-processing can't fix, or a new ARI pin changes the diagram scripts' shape.

## 2. Where it lives and how it is invoked

- A new entry point, `avd_current_state_diagram.ps1`, with pure functions in `AvdCurrentStateDiagram.psm1` (prefix `Get-` for functions that only build data). The notice sits at the top of both.
- **PowerShell 7.4 only.** The collector, the validator and the facts script stay Windows PowerShell 5.1-compatible and never load this module.
- Two modes, so the drawing is always offline:
  - `-Collect`: one live, read-only read of Resource Graph (section 3), written to `output/diagram/<timestamp>/rows.json` in the operator's session. Reader on the subscriptions is enough.
  - default (draw): reads `rows.json` and the estate key, redacts, draws, checks, writes `estate.drawio` and `diagram-report.json` (findings, counts, no names). No network except the one-time ARI fetch (section 2.1).
- `-KeyPath` is the same estate key the facts script uses, so `hp-`, `sub-` and `st-` pseudonyms match the C11 snapshot.
- Nothing reads avd-second-brain or avd-swarm. The landing zone and current-state pair stays self-contained.

### 2.1 How ARI is obtained

| Option | Verdict |
|---|---|
| `Install-Module AzureResourceInventory` | **No.** 98 MB of modules drawing doesn't use, a floating version, and PSGallery is unreliable in CI containers |
| A pinned ARI commit, only the seven diagram scripts, checked by hash | **Yes.** `ari-pin.json` holds the commit and each script's SHA-256 over LF-normalized text. The wrapper fetches the seven files from github.com at that commit, or takes `-AriPath` to a local copy (an ARI clone or an installed module at the pinned version; the Gallery copy hashes the same once line endings are normalized). A hash mismatch stops the run before anything is drawn |
| Vendor the seven scripts | Not now. MIT allows it with both notices, but we'd own 6,170 lines. Revisit only if fetching is blocked for operators |

Bumping the pin is a PR that reruns the golden tests (section 7).

## 3. What the step reads

The owner's rule wins over the handoff's question "collector additions": the collector's package format doesn't change, so `-Collect` reads its own rows. It uses Resource Graph REST (`POST /providers/Microsoft.ResourceGraph/resources`) through `Invoke-AzRestMethod`, which Az.Accounts already provides, one query per resource type (avd-assess collection method, step 1), paging until the result is empty or an error (avd-landing-zone lesson 0008). Raw ARM shape, the shape ARI reads; no cmdlet reshaping.

Types: management group chain for each subscription; resource groups; `virtualnetworks` (subnets and peerings inline), `networkinterfaces`, `virtualmachines`, `virtualmachinescalesets`, `privateendpoints`, `virtualnetworkgateways`, `connections`, `localnetworkgateways`, `expressroutecircuits`, `virtualwans`, `virtualhubs`, `vpnsites`, `azurefirewalls`, `bastionhosts`, `loadbalancers`, `applicationgateways`, `natgateways`, `networksecuritygroups`, `routetables`, `publicipaddresses`, `managedclusters`; AVD `hostpools`, `hostpools/sessionhosts` (from `desktopvirtualizationresources`), `applicationgroups`, `workspaces`. Advisor recommendations are not read (cost advice isn't part of a topology diagram; ARI's page stays empty).

The collector is meant to become a complete current-state record (enough, later, to regenerate the landing zone as is or toward a target state), and that work is separate from this spec. When the collector's package carries these rows in raw ARM shape, draw mode reads them from the package and `-Collect` stays only as a fallback for older packages. Either way the diagram step adds no collection of its own beyond this list.

## 4. Redaction

Runs on the rows before ARI sees them. Same HMAC as the facts script: `<kind>-<8 hex>` over `"<kind>|<lowercased resource ID>"` with the estate key. `Get-Pseudonym` moves into one shared file both scripts load, with a test that both give the same pseudonym for the same ID.

- **New kinds:** `mg`, `rg`, `vnet`, `snet`, `nic`, `vm`, `vmss`, `pe`, `peer`, `gw`, `conn`, `lgw`, `er`, `vwan`, `vhub`, `fw`, `lb`, `agw`, `nsg`, `rt`, `pip`, `aks`, `ag`, `ws`, `sh`, and `res` for anything else. Existing: `sub`, `hp`, `st`.
- **IDs keep their shape.** Every name segment in an ARM ID is swapped for its pseudonym; provider, type and `subscriptions`/`resourceGroups` segments stay; every `/` stays where it was (ARI reads by position). The same resource gets the same pseudonym wherever its ID appears.
- **Kept as is (public Azure values):** region, VM size, image publisher, offer and SKU, OS type, disk size, peering state and flags, host pool type, app group type, and Azure's reserved subnet names: `GatewaySubnet`, `AzureFirewallSubnet`, `AzureFirewallManagementSubnet`, `AzureBastionSubnet`, `RouteServerSubnet`.
- **Type hints ARI needs:** a NIC whose real name starts `aks-` or `gwhost` gets a pseudonym that keeps that prefix (`aks-<8 hex>`, `gwhost<8 hex>`).
- **Dropped:** tags, DNS server addresses, NIC and public IP addresses, descriptions and every other free-text property, and any property not on the allowlist.
- **Address prefixes:** replaced by their length (`10.1.0.0/16` becomes `/16`). The avd-assess collection method allows no addresses in facts, and the diagram follows the same rule. An operator who wants real prefixes and names runs ARI itself on their own estate; this step never writes an unredacted diagram.
- **Fails closed.** Before writing, scan the final XML for a GUID, an email address, a UNC path, an FQDN, a non-documentation IPv4 address, or any original name of four or more characters from the rows. On a hit, write no diagram, and report the kind of hit and the cell it was in, never the value.

## 5. AVD overlay

Post-process ARI's draw.io XML (proved in the bake-off). For each VM group ARI draws in a subnet (an object carrying `VirtualMachine-NNN` attributes), when all its VMs are session hosts of one host pool: label it `<hp-pseudonym>`, `<n> session hosts`, switch the icon to ARI's own `Windows_Virtual_Desktop.svg`, and add `AVD_Host_Pool`, `AVD_App_Group` and `AVD_Workspace` attributes. Then add app group and workspace boxes beside the subnet with edges, and move the label so it doesn't overlap the subnet name (both seen in the bake-off render). A group mixing session hosts of two pools gets one label per pool. An upstream change to `Build-ARIDiagramSubnet` comes later (section 9).

## 6. Stable output

The post-processor (proved in the bake-off): replace the date label with a fixed line, sort each page's cells by a key that ignores IDs (parent's label, own label, geometry, style), then renumber every ID in document order. Known gap: two cells with the same label, parent and geometry fall back to their old random IDs for order; add a pseudonym attribute to every cell before sorting so the key is always unique.

## 7. Checks

ARI drops errors silently (the network step's empty `catch`), so the wrapper trusts nothing:

- Every VNet and subnet in the rows appears in the output (the bake-off's presence check).
- Every subnet that holds session hosts carries the overlay.
- Every peering to a VNet not in the rows appears as a broken peering. ARI misses those held by a spoke, so the wrapper adds them in the post-processor and records each in `diagram-report.json` until ARI draws them.
- Offline Pester tests on the extended fixture, plus AKS and gateway-host NICs, an Azure Firewall and an ExpressRoute circuit; a golden `estate.drawio` compared byte for byte; the redaction scan tested with planted leaks (a real-looking GUID, IP and name) that must stop the run. ARI's seven scripts come from the pinned commit in CI.

## 8. Styling and publishing

- The post-processor maps ARI's fills to avd-ops design tokens (light values; draw.io has no theme variables): hub `#dae8fc`/`#6c8ebf` to `--accent-soft`/`--accent`, spoke `#d5e8d4`/`#82b366` to `--sunken`/`--line-strong`, broken `#fad9d5`/`#ae4132` to `--bad-soft`/`--bad`, AVD to `--s-design-bg`/`--s-design-fg`. ARI's Azure icons stay.
- Output is `estate.drawio`. SVG is the operator's choice with draw.io desktop (`drawio -x -f svg`); the step doesn't ship a browser.
- **C11 gets no `topology` section.** The diagram stays a local output in `output/` (git-ignored), like every package. A contract change would touch three repos and isn't needed for this.

## 9. Upstream plan (each step waits for the owner's yes)

Open an issue on microsoft/ARI first, then a PR only if the maintainers want it, in this order:

1. Deterministic subnet merge order and an option to omit the date (small, general, and it makes ARI's own output diffable).
2. Draw broken peerings held by a spoke (confirm on a real estate first).
3. Classify a private endpoint subnet as private endpoints, not NICs.
4. AVD host pool on subnets in `Build-ARIDiagramSubnet` ("AVD is a thing people do").

Redaction stays ours. When ARI takes a change, the matching post-processor step is removed at the next pin bump.

## 10. Phases

| Phase | What | Azure | Cost |
|---|---|---|---|
| 0 | This spec | None | $0 |
| 1 | Entry point, module, redaction, post-processor, checks, Pester on the fixture | None | $0 |
| 2 | One sandbox run of `-Collect` against the existing sandbox landing zone, then draw. Needs a written cost estimate and the owner's go first; Resource Graph reads are free, the cost is whatever the landing zone runs while it's up | Read only | Estimate first |
| 3 | Upstream issues (section 9) | None | $0 |
| 4, optional | An AVD-only Mermaid view from the same redacted rows, for GitHub and avd-ops pages (the bake-off's 90-line writer) | None | $0 |

## 11. Open questions

- Whether Cloud Shell can fetch the pinned scripts from github.com in every tenant (some block it); `-AriPath` is the fallback.
- Whether ARI's diagram code needs `ImportExcel` on a path the fixture didn't touch (on-premises, Virtual WAN).
- Whether the phase 4 Mermaid view is wanted at all.

## References

- avd-second-brain KB, assessment page, "Diagrams from what is deployed".
- avd-second-brain `docs/v1-review.md`, D18.
- avd-assess `methods/collection.md`, steps 1, 3 and 7.
