# Spec: a redacted estate diagram (Mermaid with icons)

Status: draft, 2026-10-20. Nothing is built. No Azure, no spend.

This is an **opt-in, offline step** in avd-current-state that draws a shareable diagram of what is deployed, from the rows the collector already saved. It writes Mermaid with Azure-style icons. The collector, the validator and the facts snapshot (contract C11) never need it. [Azure Resource Inventory](https://github.com/microsoft/ARI) (ARI, MIT) is prior art and a parity checklist only. It is never the inventory or the diagram engine (avd-second-brain v1 review, decision D18, as the owner restated it on 2026-10-20).

## 1. How we got here

### 1.1 The bake-off

On 2026-10-20 we ran four approaches offline on one fake estate. The estate had a hub VNet with a `GatewaySubnet`, a spoke with two session hosts, a private endpoint subnet, a hub-to-spoke peering, and broken peerings held by the hub and by the spoke. It also had a host pool with an app group and a workspace, and a subscription under two management groups. All names were pseudonyms and all prefixes were 10.x.

| | ARI diagram + post-processor | Our Mermaid writer | Graphviz through PSGraph | Diagrammer.Core |
|---|---|---|---|---|
| Ran offline | Yes, about 5 s | Yes, 0.7 s | Yes, 1.2 s | Exporter hung on Linux (bundled Windows `dot.exe`) |
| Breadth | All of ARI's diagram | VNets, subnets, peerings, hub, broken peerings, org tree, resource group counts | Same as ours | Not reached |
| Broken peering held by a spoke | Missed | Drawn | Drawn | |
| Private endpoint subnet | Read as "1 Network Interface" | "1 private endpoint" | Not written | |
| AVD overlay | A post-process of about 20 lines | Native | Native | |
| Two runs identical | Only after sorting and renumbering | Yes, by construction | SVG yes, DOT text no (hashtable order) | |
| Footprint | PowerShell 7; 98 MB of modules from the Gallery, or 7 pinned scripts (6,170 lines) | None; PowerShell 5.1-compatible | Graphviz binary and PSGraph (last commit 2019) | 91 MB with Windows binaries |

AzViz (reads the live Network Watcher topology API), Microsoft's azure-resource-visualizer skill (a model decides the edges), Network Watcher topology (portal only), AzureResourceMap (live .NET) and D2 (needs a binary) were dropped without a trial.

### 1.2 The decision

ARI won on breadth, but the owner chose **Mermaid with icons** and **our own inventory**: "mermaid + icons", and "we need our own inventory or a different one if there's a better one". The reasons are in the table. Our writer had no dependency, stayed PowerShell 5.1-compatible and produced stable output for free. It was AVD-native and right where ARI was wrong. Its gap was breadth, and the collector's Resource Graph rows (draft PR #15, `docs/rebuild-fidelity-spec.md`) close that gap without taking on ARI.

### 1.3 What we keep from ARI: the parity checklist

The diagram must show everything ARI's diagram shows (read from `Modules/Public/PublicFunctions/Diagram/` at `4cc602c`), plus what ARI gets wrong:

- Management group tree with subscriptions; per subscription, resource groups with a count of each resource type.
- VNets with address space (redacted, section 4), DDoS protection and whether custom DNS is set.
- **Hub coloring: ARI's rule is a VNet with a subnet named `GatewaySubnet`.** We use the same rule and also call a VNet with an `AzureFirewallSubnet` a hub.
- Peerings with state, gateway transit, forwarded traffic and VNet access. A peering to a VNet not in the rows is a **broken peering**, whichever side holds it. ARI misses the ones a spoke holds.
- Inside each subnet: VMs (size, OS, image), scale sets, load balancers, gateways, firewalls, private endpoints (as private endpoints, not NICs), application gateways, Bastion and AKS, found through NICs. Also delegations, and the NSG and route table on the subnet.
- On-premises side: local network gateways, VPN connections, ExpressRoute circuits with peering location, Virtual WAN hubs and VPN sites.
- **AVD, which ARI lacks:** session hosts shown as their host pool on their subnet, app groups and workspaces linked to it, and scaling plans.
- **Stable output, which ARI lacks:** the same rows give the same bytes.

ARI's Advisor cost page is not carried over, because it isn't topology.

## 2. Where it lives and how it is invoked

- A new entry point, `avd_current_state_diagram.ps1`, with pure functions in `AvdCurrentStateDiagram.psm1` (`Get-` for functions that only build data) and the notice at the top of both.
- **Windows PowerShell 5.1 and PowerShell 7.** It writes text only, so there is no reason to drop 5.1 the way the ARI route had to.
- **Offline only.** It reads a collector package and the estate key, and makes no Azure call and no network call. There is no `-Collect` mode: if a package lacks rows (section 3), the step says which ones and asks for a collector run.
- `-KeyPath` is the facts script's estate key, so `hp-`, `sub-` and `st-` match the C11 snapshot.
- Nothing reads avd-second-brain or avd-swarm. The landing zone and current-state pair stays self-contained.

## 3. What it reads

The full Resource Graph objects the collector saves under `rebuild/resources/` (draft PR #15), and nothing else. The diagram and the collector's datasets therefore come from one read and never disagree.

The collector's `rebuild/scope.json` already covers VNets (with subnets and peerings), NICs, VMs, private endpoints, NSGs, route tables, NAT gateways, public IPs, resource groups and the AVD objects. The parity list also needs gateways and connections, local network gateways, ExpressRoute circuits, Virtual WAN and hubs, VPN sites, firewalls, Bastion, load balancers, application gateways, scale sets, AKS and the management group chain. **These belong in the collector as inventory**, since the owner wants our own inventory, not a second read path in the diagram step. That is a change to `scope.json` for the collector's thread to make, with `serves` naming "diagram" or "inventory" where no landing zone parameter applies. Until those types are there, the diagram draws what the package has and lists what it couldn't draw in `diagram-report.json`.

## 4. Redaction

Runs on the rows before anything is drawn. Same HMAC as the facts script: `<kind>-<8 hex>` over `"<kind>|<lowercased resource ID>"` with the estate key. `Get-Pseudonym` moves into one shared file that both scripts load, with a test that both give the same pseudonym for the same ID.

- **Kinds:** existing `sub`, `hp`, `st`; new `mg`, `rg`, `vnet`, `snet`, `nic`, `vm`, `vmss`, `pe`, `peer`, `gw`, `conn`, `lgw`, `er`, `vwan`, `vhub`, `fw`, `lb`, `agw`, `nsg`, `rt`, `pip`, `aks`, `ag`, `ws`, `sh`, `sp` (scaling plan), and `res` for anything else.
- **Kept as is (public Azure values):** region, VM size, image publisher, offer and SKU, OS type, peering state and flags, host pool type, app group type, and Azure's reserved subnet names (`GatewaySubnet`, `AzureFirewallSubnet`, `AzureFirewallManagementSubnet`, `AzureBastionSubnet`, `RouteServerSubnet`). The hub rule depends on them.
- **Address prefixes become their length** (`10.1.0.0/16` becomes `/16`), following avd-assess's collection method, step 3 (no addresses in facts).
- **Dropped:** tags, DNS server addresses, NIC and public IP addresses, descriptions and other free text, and any property not on the allowlist.
- **Fails closed.** Before writing, scan every output for a GUID, an email address, a UNC path, an FQDN, a non-documentation IPv4 address, or any original name of four or more characters from the rows. On a hit, write nothing, and report the kind of hit and the node it was in, never the value.

There is no unredacted mode. An operator who wants real names draws from the collector's own datasets in their private package.

## 5. Output

Three files in `output/diagram/<timestamp>/` (git-ignored):

| File | What | Renders where |
|---|---|---|
| `estate.mmd` | A plain Mermaid flowchart: subgraphs for VNets and subnets, text nodes, classes for hub, spoke, broken and AVD. **No icon syntax.** | GitHub, any Mermaid viewer, and as a text diff |
| `estate.icons.mmd` | The same graph with Mermaid icon shapes (`node@{ icon: "azure:hostpool", label: "...", pos: "b" }`, Mermaid 11.3 or later) | Only where an icon pack is registered |
| `estate.html` | One self-contained page holding a pinned Mermaid build, the icon pack and the diagram, styled with avd-ops tokens for light and dark, with a "Save SVG" button | Any browser, offline (Cloud Shell can download it) |

One writer builds the graph once and emits both texts, so the plain and icon versions can't drift. Node IDs come from pseudonyms and every list is sorted, so the same rows give the same bytes. Pester compares against golden files.

### 5.1 Icons: what GitHub can show

GitHub renders Mermaid with its own build, and a repository can't register an icon pack there. Icon packs are registered by page JavaScript (`mermaid.registerIconPacks`), which GitHub doesn't run. In the spike, an icon shape whose pack isn't registered rendered as a grey "?" box (Mermaid 11.4.1). Whether GitHub's build accepts the icon-shape syntax at all wasn't verified. So **icons show only where we render**: `estate.html`, an avd-ops page that vendors Mermaid and the pack, or an SVG saved from either. `estate.mmd` is the GitHub copy.

### 5.2 Icons: which set

Microsoft's terms for the [Azure architecture icons](https://learn.microsoft.com/azure/architecture/icons/) (set V24, page updated 2026-10-09) allow their use in architecture diagrams, training and documentation: "You can copy, distribute, and display the icons only for the permitted use unless granted explicit permission by Microsoft. Microsoft reserves all other rights." They also say not to crop, flip, rotate or distort them, to use them only for the Microsoft product they stand for, and to put the product name near each icon. That isn't an open license, so **the Azure SVGs are never committed to an MIT repo**: not here, not in avd-ops.

- **Azure icons, operator-supplied.** `-AzureIconsPath` points at the zip the operator downloaded from that page, accepting the terms there. The step converts the needed SVGs into a local Mermaid icon pack in `output/`. The SVG markup is unchanged except that IDs inside each icon are prefixed, so gradients from different icons don't collide. A diagram drawn with them is an architecture diagram, which is the permitted use. Each icon node carries its label below it.
- **Open icons by default.** Without `-AzureIconsPath`, the step uses a small subset of [Tabler Icons](https://github.com/tabler/tabler-icons) (MIT) for network, subnet, server, desktop, apps, router and broken link. These can be vendored here and on avd-ops with their license.
- avd-ops pages that show sample diagrams use the open set, unless the owner decides to host Azure icons on the site under Microsoft's documentation terms.

The spike rendered all three on the fake estate: Azure icons, Tabler icons, and no pack ("?" boxes).

### 5.3 Styling

The page uses avd-ops tokens: hub `--accent-soft`/`--accent`, spoke `--sunken`/`--line-strong`, broken `--bad-soft`/`--bad` dashed, AVD `--s-design-bg`/`--s-design-fg`, light and dark. Two spike findings to fix in phase 1: a `class` on a subgraph didn't apply its fill in Mermaid 11.4.1 (use `style <subgraph> ...` lines instead), and the default theme's label backgrounds clash with the tokens (set `themeVariables`).

## 6. Checks

- Every VNet, subnet, peering and AVD object in the rows appears in the graph. This is counted from the graph before writing, not read back from a render.
- Every peering to a VNet not in the rows is drawn as broken, whichever side holds it.
- Every subnet holding session hosts carries its host pool.
- Offline Pester tests on the fake estate, extended with a firewall, Bastion, an ExpressRoute circuit, a scale set and AKS, with golden `estate.mmd` and `estate.icons.mmd`. The redaction scan is tested with planted leaks (a GUID, an IP, a real-looking name) that must stop the run. The icon pack converter is tested on a two-icon fixture made of our own shapes, never on Microsoft's files.
- The rendered page is checked once per Mermaid pin bump in a headless browser. That is a manual step in a container, not in CI.

## 7. Publishing and contracts

- **C11 gets no `topology` section.** The diagram stays a local output, like every package. A contract change would touch three repos and isn't needed.
- The pinned Mermaid build (MIT) is fetched by version and SHA-256, or taken from `-MermaidPath`, and inlined into `estate.html`. It isn't committed to this repo. avd-ops vendors its own copy for its pages, the way it vendors its design system.

## 8. Upstream

Nothing goes to microsoft/ARI now. The spoke-held broken peering and the private endpoint label are worth reporting as issues one day, with the owner's yes.

## 9. Phases

| Phase | What | Azure | Cost |
|---|---|---|---|
| 0 | This spec | None | $0 |
| 1 | Writer, redaction, icon pack converter, `estate.html`, checks, Pester on the fake estate | None | $0 |
| 2 | Collector scope additions for the parity types (collector's thread) | None | $0 |
| 3 | Draw from a sandbox collector run. Needs a written cost estimate and the owner's go first | Read only, through the collector | Estimate first |
| 4 | avd-ops page with a sample diagram (open icons) | None | $0 |

## 10. Open questions

- GitHub's Mermaid version and whether it accepts icon-shape syntax (decides whether `estate.icons.mmd` can ever be the GitHub copy).
- Layout at estate size: Mermaid's flowchart layout on 50 VNets is untested. The ELK layout is the fallback to try.
- Whether avd-ops should host Azure icons under Microsoft's documentation terms (the owner's call).

## References

- avd-second-brain KB, assessment page, "Diagrams from what is deployed".
- avd-second-brain `docs/v1-review.md`, D18.
- avd-assess `methods/collection.md`, steps 1, 3 and 7.
- This repo's draft `docs/rebuild-fidelity-spec.md` (PR #15).
- [Mermaid icon packs](https://mermaid.js.org/config/icons.html); [Azure architecture icons and terms](https://learn.microsoft.com/azure/architecture/icons/).
