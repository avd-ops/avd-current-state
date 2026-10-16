---
description: File raw notes into the vault as decisions, runbooks, lessons or glossary entries
argument-hint: "[path in inbox/ or pasted text]"
---

Turn raw knowledge into vault notes.

Input: $ARGUMENTS (an `inbox/` file, or pasted text). If empty, process every file in `inbox/`.

1. Read the input and split it into distinct pieces of knowledge.
2. Classify each piece as a decision, runbook, lesson, glossary term, or environment note (owners, purpose, quirks).
3. For each piece, check whether an existing note already covers it. Update that note rather than creating a duplicate.
4. Otherwise create a note from the matching file in `_templates/`, fill the front matter, and link the environments, findings and decisions it relates to.
5. Environment notes go in the human section of `environments/<name>/README.md`, outside the generated markers.
6. Once an inbox file is fully filed, delete it.
7. Finish with a short list of the notes created or changed and anything you could not classify.
