---
description: Write a status brief for one environment or the whole estate
argument-hint: "[environment name]"
---

Write a one-page brief for `$ARGUMENTS` (or every environment when empty), from vault evidence only:

1. Current shape: host pools, session hosts, latest validator verdict per mode.
2. What changed since the previous snapshot (from `drift/`).
3. Open findings, oldest first, with the runbook that resolves each where one exists.
4. Decisions taken or lessons recorded in the last 30 days.
5. Gaps: missing evidence, stale runs, findings with no runbook.

Cite note paths. Save the brief to `inbox/brief-<environment>-<yyyy-mm-dd>.md` and print it.
