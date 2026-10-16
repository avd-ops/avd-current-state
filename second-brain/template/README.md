# AVD Second Brain

The shared memory for our Azure Virtual Desktop estate: what exists, what changed, what
is broken, what we decided, and how we fix things. Start here.

> Generated sections are rebuilt by `avd_second_brain.ps1` on every ingest. Write
> anywhere outside the `<!-- brain:generated -->` markers and your text is kept.

<!-- brain:generated:start -->
_No evidence ingested yet. Run `avd_second_brain.ps1 -BrainPath <this folder> -PackagePath <package>`._
<!-- brain:generated:end -->

## How this vault is organised

| Folder | Holds | Written by |
|---|---|---|
| `environments/` | One folder per subscription: overview, timeline, open findings, drift, snapshots | The ingest script (plus your notes in the overview) |
| `decisions/` | Architecture and operational decisions, one per file, never edited after acceptance (supersede instead) | People |
| `runbooks/` | Repeatable procedures: how to fix a finding, how to scale out, how to rotate a token | People |
| `lessons/` | Incident write-ups and "we learned this the hard way" notes | People |
| `inbox/` | Raw notes, meeting jots, half-formed ideas waiting to be filed | Anyone |
| `glossary.md` | Names, acronyms and codenames used across the estate | People |
| `_templates/` | Starting points for each note type | — |

## Ways of working

1. **Capture first, file later.** Drop raw notes in `inbox/`. Filing them is a weekly chore, not a blocker.
2. **Evidence, not memory.** After every collector or validator run, ingest the package. The timeline and drift notes are only as good as the cadence.
3. **Link everything.** A decision links to the environment it affects; a runbook links to the finding it resolves; a lesson links to the decision it changed. Use `[[wiki-links]]` or relative Markdown links.
4. **One fact, one place.** If you are copying a paragraph, link to it instead.
5. **Supersede, don't rewrite.** Decisions keep their history: mark the old one `superseded-by` and write a new one.
