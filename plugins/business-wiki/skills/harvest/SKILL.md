---
name: harvest
description: End-of-track sweep — work out what this track taught us that belongs in the wiki, and propose the edits. Run before opening a PR or after merging one.
argument-hint: [branch, PR number, or commit range]
---

# Harvest a track into the wiki

Scope: `$ARGUMENTS` if given (a branch, a PR number, a commit range); otherwise the current branch against its merge base with the default branch.

## Steps

1. **Read the actual change.** `git diff <base>...HEAD`, the commit messages, and the PR body if there is one.

2. **Hand it to `business-wiki:wiki-keeper` in harvest mode** with the four questions:
   - What did the spec or plan say, and what did the code end up doing? The delta is either a wiki update or an admission the plan changed.
   - Which decisions were taken in this track that have no ADR?
   - Which divergences surfaced that are not in `shared/divergences.md`?
   - Which rules are now cited or implemented in code but absent from the wiki (and so from `business-docs/rules/`)?

3. **Re-derive** the affected features with `/business-wiki:derive`.

4. **Check** with `/business-wiki:check`.

5. **Report** the proposed edits as a reviewable diff, grouped: wiki pages, new ADRs, new divergences, derived-format changes.

6. **Record the delta on the task, if this repo tracks tasks that way.** When
   `.sdd-tdd/tasks.json` exists and the track has a task, post the list of pages
   this harvest touched as a note titled exactly `wiki-delta`:

   ```bash
   scripts/task.sh note <id> <file listing the pages> --title "wiki-delta"
   ```

   `task.sh state <id> done` refuses without that note on a project that has a
   wiki, which is what stops a track from being called finished having never
   looked at the wiki. **An empty harvest still gets a note** — one line saying
   which rules were checked and why nothing changed. "Nothing to register" is a
   finding; a silent absence is indistinguishable from a skipped step.

## Honesty

An empty harvest is a legitimate result — a refactor that changed no rule should produce no wiki edit. Say "nothing to harvest" in one line rather than manufacturing a page to look productive.

Do not commit, and do not amend the track's commits. The human reviews the harvest as its own change.
