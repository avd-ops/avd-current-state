# Spec: the assessment portal

Status: accepted, 2026-10-20. Phase 1 built 2026-10-21 (Collect, Discover, Analyze); phase 2 built 2026-10-21 (Review); phase 3 built 2026-10-22 (Plan). See section 7. No Azure, no spend.

The owner asked (2026-10-20) for one page that walks an operator through a whole assessment, the way the [avd-landing-zone deployment portal](https://github.com/avd-ops/avd-landing-zone/tree/master/site/portal) walks them through a deployment. It lives here, because avd-current-state is the signal engine: it collects what is there now and judges it against the standards in [avd-assess](https://github.com/avd-ops/avd-assess). The landing zone stays the deployment engine; the brain and avd-swarm stay optional layers on top.

An assessment has five stages (owner, 2026-10-20): inventory collection, interview and discovery for the narrative detail, analysis against standards, review of findings, and recommendation and remediation planning. Two already have a home (the collector, and the validator running the pinned method). Three had none: the discovery narrative, a recorded review, and a plan from findings. The portal is their home.

## 1. Rules it keeps

- **Static page, no server.** Plain HTML and JavaScript in `site/portal/`, no build step, served from GitHub Pages (and later from the operator's own subscription, as the landing zone's portal does). The engine (`site/portal/assess-core.js`) runs in the browser and in Node, so it is tested offline.
- **Estate data never leaves the browser.** Pasted output and loaded files are read locally (the File API, no upload). The page makes no network request except for its own files. A test keeps it that way, as the deployment portal's does.
- **Self-contained.** The scripts work without the portal; the portal works without the brain, avd-swarm, the landing zone and any fetch from avd-assess. What it needs from avd-assess (the method's check titles and claims, the interview guide) comes from the pinned copies under `assess/` in this repo, served beside the page.
- **Foundation first, upper layers fail open.** Everything the portal writes is a foundation format in avd-assess `contracts/`. The brain and avd-swarm may import it; nothing here waits on them (avd-assess `contracts/README.md`, rules 1 to 6).
- **Free text stays private.** The narrative and any notes stay on the operator's device as a Markdown file. They never go into a contract, the state line or an issue.
- **Read-only.** The portal gives commands that read. It never gives a command that writes to an estate; changing an estate is the landing zone's job.

## 2. The five stages

The page is a stepper like the deployment portal: one panel per stage, Back and Next, a stage hidden until the run reaches it, progress and settings in the browser's local storage, a **Start over** link.

| Stage | The operator does | The page gives | Writes |
|---|---|---|---|
| **1. Collect** | Runs the collector in Cloud Shell, pastes the output | A self-contained Cloud Shell block (clone or update, `Set-Location`, sign-in check, `avd_current_state_collector.ps1` with the subscriptions from Settings); after the paste, what was collected and the rebuild coverage line (#15) | nothing (the package stays in Cloud Shell) |
| **2. Discover** | Answers the interview, with the customer if there is one | The interview guide from avd-assess (`gaps/discovery.md`, pinned): the C19 questions as a form (residency, regions, hub, identity lane, working hours, and the use case record once avd-assess adds it to C19), and a notes box per topic for the narrative | `intake.json` (C19), written into Cloud Shell by a heredoc block the page builds (structured values only, so it is safe to paste), and `discovery-notes.md` downloaded to the operator's device |
| **3. Analyze** | Runs the validator with the method, pastes the output, then loads `assessment.json` | A block running `avd_deployment_validator.ps1 -Mode Both -Assess -IntakePath ./intake.json` (phase 4 of avd-assess); a file picker or paste box for `assessment.json` (C21 holds no names, so pasting it is safe) | nothing new |
| **4. Review** | Goes through the findings and decides each one | A findings table from C21: check ID, title and claim (from the pinned `method.json` and `index.json`), outcome, pillar, the facts it used. Each row gets a disposition (**Fix**, **Accept**, **Defer**) and a reason code; an optional private note per row goes to the notes file, not the review | `review.json` (C23, new), downloaded and written back with a heredoc block; notes appended to `discovery-notes.md` |
| **5. Plan** | Reads the plan, takes it to the landing zone | The Fix rows as an ordered plan: what good is and why (the claim), the landing zone parameter or setting that changes it where one is known (from the pinned `rebuild/lz-parameters.json` of #15 and a `remediation` hint per check in the catalog), the evidence, and what is out of the landing zone's reach | `plan.json` (C24, new) and `plan.md` for people |

Stages can be skipped with Next (an operator who collected earlier, or has no customer to interview), and each panel says what is missing downstream when one is skipped: no intake means the intake facts score `unknown`; no review means the plan is every non-pass finding.

### 2.1 Where the plan goes

- **Without anything else:** the operator reads `plan.md` and edits the landing zone's parameters by hand.
- **With the landing zone's rebuild map (later, #15 phase 2 onward):** a foundation-only step in the landing zone reads `plan.json` and the rebuild map and proposes the parameter changes as a diff for the operator to apply. That reader belongs to the landing zone, beside `ConvertFrom-AvdTargetState.ps1`, and reads the plan "read, never trusted".
- **With the brain (optional):** it imports `review.json` (Accept rows become accepted risks with their reason in its lifecycle record, C18) and may design a fuller target state (C14) from `plan.json`.
- **With avd-swarm (optional):** for an estate it operates, it turns approved plan items into gated changes. The portal never talks to either.

## 3. The state line

The collector and the validator end with one machine-readable line, the same idea as the landing zone's (its decision 0007), under this repo's own tag so the two portals never misread each other:

```
<<<AVDCS-STATE {"v":1,"stage":"collect","status":"done",...} AVDCS-STATE>>>
```

| Field | Meaning |
|---|---|
| `v` | Schema version (1). Fields are added, never renamed without a bump. |
| `stage` | `collect` (the collector), `facts` (the facts script, which gives the estate its pseudonym), `analyze` (the validator) |
| `status` | `done`, `partial` (some subscriptions failed), `failed` |
| `context` | What the next block needs: `package` (the package folder's name), `estate` (the `est-` pseudonym, facts), `snapshot` (the facts file's name), `assessment` (the C21 report's file name, facts with `-Assess`), `mode` and `verdict` (analyze). `lib/AvdPortalState.psm1` refuses any other key and any value that looks like an ID, an email address or a path |
| `counts` | Collect: subscriptions, skipped, datasets, rows, host pools, session hosts, warnings; facts: subscriptions, host pools, validations, redacted; analyze: the readiness results' `fail`, `warn`, `pass`, `info`, `skip` (the C21 outcomes `pass`, `warn`, `gap`, `unknown` join when the validator's assess mode lands) |
| `coverage` | Collect: the rebuild map's counts per status (#15) |

It holds no names or IDs: only counts, relative paths and the estate pseudonym. Tests pin the line for each script.

## 4. New contracts (in avd-assess `contracts/`)

Both follow the foundation rules: no names, IDs or free text; the estate pseudonym and check IDs only; an optional `extensions` object for upper layers; additive changes only within v1.

**C23 `avd-assessment-review/v1` (`review.json`)**

| Field | Meaning |
|---|---|
| `schema`, `estate`, `reviewedOn` | As C21 |
| `assessment` | `sha256` of the `assessment.json` it reviews, and its `generatedUtc` |
| `decisions[]` | `check` (C21 check ID), `outcome` (the C21 outcome it was decided against), `disposition` (`fix`, `accept`, `defer`), `reason` (enum: `fix-planned` for a fix; `cost`, `compensating-control`, `business-need`, `not-applicable` for an accept; `needs-evidence`, `out-of-scope`, `later-phase` for a defer), optional `reviewBy` (a date to look again; never on a fix), optional `carriedForward` (true when the decision came from an earlier review) |
| `extensions` | Optional, upper layers only |

A review pins the report it reviewed. A new run produces a new report, and the portal carries the earlier dispositions forward for checks whose outcome didn't change, marked for a second look.

Built in avd-assess #18 (`contracts/schemas/assessment-review.schema.json`): the schema itself refuses a reason that doesn't fit its disposition.

**C24 `avd-remediation-plan/v1` (`plan.json`)**

| Field | Meaning |
|---|---|
| `schema`, `estate`, `plannedOn` | As C21 |
| `basis` | The `sha256` of the assessment and of the review it came from |
| `items[]` | `check`, `pillar`, `severity`, `claims[]` (avd-assess citations), `change` (`{ kind: "lz-parameter", name, from, to }`, `{ kind: "lz-setting", name }`, or `{ kind: "manual" }` with a code, never free text), `order` |
| `extensions` | Optional, upper layers only |

`from` and `to` are public values only (a SKU, a count, a boolean, a region), never names or prefixes. Where a change needs a private value, the item says `manual` and the operator fills it in their own parameter file.

The discovery notes have no contract: they are a person's notes, not data for a tool.

## 5. Look and feel

The page uses the [avd-ops design system](https://github.com/avd-ops/avd-ops/blob/main/docs/design-system.md), vendored into `site/assets/` as the landing zone's portal does, and keeps its rules (colors only through tokens, self-hosted fonts, no inline styles, dark mode, the notice first). Design pass (design-system review, 2026-10-20):

| Need | Existing | New |
|---|---|---|
| Top bar, notice, cards, tables, buttons, code | `header.top` (avd-ops / AVD assessment portal), `.disclaimer`/`.warn`, `.card`, `.tbl`, `.cta`, `pre` | none |
| Stepper, stage panel, Cloud Shell block, paste box, form fields | The deployment portal's own `.steps`, `.panel`, terminal block and `.field` (portal-only today) | **Promote** them to avd-ops (`.steps`, `.panel`, `.term`, `.paste`, `.field`) so both portals vendor one copy. Code flows one way between the pair (current-state to the landing zone), so this portal must not copy the landing zone's components; avd-ops is the shared source |
| Outcome of a check | `--good`, `--caution`, `--bad` and their `-soft` backgrounds | `.outcome.o-pass`, `.o-warn`, `.o-gap`, `.o-unknown` pills (unknown uses `--muted` on `--sunken`; never color alone: each pill carries its word) |
| A disposition per row | none | `.segmented`: a radio group styled as three joined buttons (Fix, Accept, Defer), `role="radiogroup"`, arrow keys move, the selected one uses `--accent-soft` and `--accent` |
| Load a file | none | `.filedrop`: a labeled `input type=file` with a drop zone, the file name and size after loading, and an error line on a schema mismatch. Says "read in your browser, never uploaded" |
| Download a file | `.cta.ghost` | none (a `download` link) |

Accessibility: every control is reachable by keyboard; the findings table is a real `table` with a caption and column headers; outcome and disposition are words, not just colors; focus uses `--focus`. Phones: the table becomes one card per finding below 40rem.

## 6. Tests

- `node --test "tests/portal/*.test.mjs"`: the engine against fixtures (state lines, a C21 report, a review), the heredoc builder (only structured values, quoted), the C23 and C24 writers validated against avd-assess's schemas (fetched at a pinned commit in CI), carry-forward of dispositions, and a privacy test: no `fetch`, `XMLHttpRequest`, `WebSocket` or external URL in the page.
- Playwright in a real browser (the owner's rule for portal UI): each stage on desktop and phone width, light and dark, keyboard through the segmented control.
- The notice at the top of the page and of `assess-core.js` (the entry-point test).
- American English and ASCII, as the rest of the repo.

## 7. Phases

All offline until the last.

| Phase | What |
|---|---|
| 0 | This spec |
| 1 | avd-ops: promote the portal components (design system 1.1.0), the landing zone re-vendors them. Here: `site/` with the vendored design system, the stepper shell, Settings, Collect and Analyze blocks, the state line in both scripts, Discover writing `intake.json` and the notes file, Pages workflow. **Built** 2026-10-21. Analyze runs the validator's post-deployment checks until its assess mode lands; `intake.json` is checked against avd-assess's C19 example and schema at a pinned commit in CI |
| 2 | avd-assess: C23. Here: Review (findings table, dispositions, carry-forward), `review.json`. **Built** 2026-10-21. A finding's title comes from its check ID until the check catalog (C22) gives titles, pillars and claims; the engine's `review.json` fixture and the C21 example are checked against avd-assess's schemas at a pinned commit in CI |
| 3 | avd-assess: C24. Here: Plan, `plan.json` and `plan.md`, using `rebuild/lz-parameters.json` and the check catalog's remediation hints. **Built** 2026-10-22: C24 and the hints came in avd-assess #22 (method version 3, `methods/remediation.md`); the page reads them from `site/portal/assess-catalog.js`, a copy of the pinned `assess/method.json` (a test keeps them equal and checks every `lz-parameter` hint against `rebuild/lz-parameters.json`). The engine's `plan.json` fixture is checked against avd-assess's C24 schema at a pinned commit in CI. Items carry no `from` yet: C21 doesn't report the current value |
| 4 | Publish to the operator's own subscription (the landing zone's #74 pattern), and a Report a problem button that redacts in the browser (decision 5 below) |
| 5 | One sandbox walk-through end to end, with a written cost estimate and the owner's go |

A check the pinned method doesn't have is left out of the plan and listed as such, because the plan can't cite what good is for it.

## 8. Decisions

The owner accepted all five recommendations on 2026-10-20.

1. **Promote the deployment portal's components to avd-ops** so both portals share them, rather than this page copying the landing zone's. Decided: it keeps code flowing one way between the pair.
2. **C23 and C24 as their own contracts** in avd-assess (C22 is reserved for the check catalog). Decided, rather than folding the review into C21: a review is a person's decision about a report, and pinning the report's hash keeps them apart.
3. **Heredoc blocks to move `intake.json` and `review.json` into Cloud Shell**, rather than asking the operator to upload files. Decided: it is one paste, works on an iPad, and the content is structured values only.
4. **The page path:** `site/portal/` on this repo's Pages (`avd-ops.github.io/avd-current-state/portal/`), linked from avd-ops.dev. Decided.
5. **Report a problem:** the landing zone's redaction (`report.js`) can't be copied here under the one-way rule. Decided: move its core into avd-ops as a shared script both portals vendor, in phase 4; until then the page has no report button.

## References

- avd-landing-zone `site/portal/README.md`, decisions 0007 (state line) and 0008 (issue reports), draft PR #74 (hosting).
- avd-assess `contracts/README.md` (foundation contracts and their rules), `gaps/discovery.md` (interview guide, in progress), C19 and C21 schemas.
- This repo's `docs/rebuild-fidelity-spec.md` (#15) for the rebuild map and the landing zone parameter list.
- The foundation wiring note (2026-10-20), section "The assessment, stage by stage".
