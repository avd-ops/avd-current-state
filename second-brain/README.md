# AVD Second Brain

An organisational second brain for an Azure Virtual Desktop estate: one place that remembers
what the environment looked like, what changed, what is broken, what the team decided, and
how things get fixed. It is meant to outlive any one engineer's memory.

The collector and validator each capture a single point in time. The second brain strings
those points together and puts the team's own knowledge next to them.

```
 collector run ─┐                         ┌─ environments/<sub>/README.md   overview + your notes
                ├─► avd_second_brain.ps1 ─┼─ environments/<sub>/timeline.md every run
 validator run ─┘        (offline)        ├─ environments/<sub>/drift/      what changed
                                          ├─ environments/<sub>/findings.md open / resolved issues
                                          └─ README.md                      estate overview
 people ──────────────────────────────────► decisions/ runbooks/ lessons/ glossary.md inbox/
```

## What it gives you

| Question | Where the answer lives |
|---|---|
| What do we run, and where? | `environments/<sub>/README.md` and the latest inventory snapshot |
| What changed since last month? | `environments/<sub>/drift/`, generated from consecutive inventory snapshots |
| What is broken, and for how long? | `environments/<sub>/findings.md`: every validator FAIL / WARN with first-seen date, closed only when the same check passes again |
| Why is it built this way? | `decisions/`: one ADR per decision, linked to the environments it affects |
| How do I fix this finding? | `runbooks/`: a runbook that lists the check in `resolves-checks` is linked from the finding automatically |
| What went wrong before? | `lessons/` |
| What does this codename mean? | `glossary.md` |

## Design choices

- **Plain Markdown in Git.** Readable on GitHub, in any editor, and as an
  [Obsidian](https://obsidian.md) vault. History, review and blame come from Git.
- **Its own private repository.** The vault holds subscription IDs, resource names and
  findings, so it is kept apart from this tooling repository. One vault per organisation or
  customer.
- **Condensed evidence only.** Raw evidence packages stay where they are. The vault keeps
  the facts that matter for history: host pools, session host health, resource IDs, dataset
  counts and every validator result.
- **Generated and human content side by side.** The script rewrites only what it owns: the
  `<!-- brain:generated -->` blocks, `timeline.md`, `findings.md`, `drift/` and `snapshots/`.
  Everything else is yours.
- **Order-independent and repeatable.** Drift and findings are rebuilt from all snapshots
  on every ingest. A backfilled package slots into history as if it had been ingested on
  the day, and a re-run with nothing new changes nothing.
- **AI-ready.** The vault ships a `CLAUDE.md` and `/ask`, `/brief` and `/capture` commands
  so Claude Code (or any agent that reads the repository) answers from evidence with
  citations, and files raw notes into the right place.

## Set up

```powershell
# 1. Create the vault in its own folder, then make it a private Git repository
.\avd_second_brain.ps1 -BrainPath ..\avd-brain -Init
git -C ..\avd-brain init

# 2. Ingest evidence: a package folder, a ZIP, or a folder full of either
.\avd_second_brain.ps1 -BrainPath ..\avd-brain -PackagePath .\avd-current-state-20261015T091500
.\avd_second_brain.ps1 -BrainPath ..\avd-brain -PackagePath D:\Assessments

# 3. Review and commit
git -C ..\avd-brain add -A
git -C ..\avd-brain commit -m "Ingest October evidence"
```

Running `-Init` again against an existing vault adds any new template files and never
overwrites yours. Already-ingested packages are skipped; `-Force` re-ingests them.

## Keeping it alive

A second brain is only as good as its habits.

| Cadence | Habit |
|---|---|
| Every collector or validator run | Ingest the package and commit. Schedule the collector (e.g. a weekly Automation runbook or pipeline) so drift is caught without anyone remembering to look |
| Every change | Write or update the ADR before or alongside the change, and link it from the environment page |
| Every fix | If the fix will be needed again, it is a runbook. Add the validator check name to `resolves-checks` |
| Every incident | A short lesson, linked to the decisions or runbooks it changed |
| Weekly | Empty `inbox/` (or run `/capture` in Claude Code). Skim each environment's open findings |
| Monthly | Run `/brief` for a status page per environment and share it |

## Vault layout

```
avd-brain/
├── README.md                 # estate overview (generated block) + ways of working
├── CLAUDE.md                 # how agents read and write the vault
├── glossary.md
├── environments/
│   └── sub-avd-prod/
│       ├── README.md         # generated overview + owners, purpose, quirks
│       ├── timeline.md
│       ├── findings.md
│       ├── drift/20261001T090000--20261015T090000.md
│       └── snapshots/20261015T090000-inventory.{md,json}
│                     20261016T100000-validation-postdeployment.{md,json}
├── decisions/ADR-0001-....md
├── runbooks/
├── lessons/
├── inbox/
├── _templates/               # decision, runbook, lesson, environment notes
├── .claude/commands/         # /ask, /brief, /capture
└── .brain/state.json         # ingest state; do not edit
```

## Limits

- The vault knows only what the collector and validator saw. Their [limitations](../README.md#limitations)
  apply: no OS-level, Intune, Entra ID or effective-network state.
- Environments are keyed by subscription ID. A subscription's folder name is fixed the first
  time it is seen, so a later rename keeps its history.
- Drift lists at most 50 added or removed resources per pair of snapshots; the evidence
  packages hold the full lists.
- A finding is keyed by phase, category, check and scope. If a later validator version
  renames a check, the finding under the old name stays open and has to be judged by a person.
