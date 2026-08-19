---
name: sdd-status
description: >-
  Where every sdd-tdd task stands, and how far its track's use cases have got.
  Use it to answer "what's in flight", "what's next", or "why hasn't this moved"
  before starting any other sdd-tdd skill.
---

# /sdd-status — tasks and their tracks, side by side

Usage: `/sdd-status` or `/sdd-status #<task-id>`

Run `scripts/status.sh` (optionally with the id) and relay what it says. It's
read-only: no writes, no confirmation, no network.

## What to look for, not just what to print

The point of putting a task's state next to its track's case counts is that the
two drift apart in specific, diagnosable ways. Say which one you're seeing:

| Pattern | What it means | The next move |
| --- | --- | --- |
| task in the intake state, no area | never specced | `/sdd-spec #<id>` |
| area set, `cases: none yet` | track exists, spec.md never went through the manifest builder | `/sdd-spec` step 7 |
| task `specced`, all cases `pending` | intake finished, the loop never ran | `/sdd-implement <area>` |
| task `implementing`, some `red`/`green` | a loop run stopped mid-case | read the task's notes — the reason is there |
| all cases `refactored`, task still `implementing` | the loop finished but nobody moved it | `task.sh state <id> verify` |
| task in `verify` | the loop is done; a human has to run it and walk the manual cases | then `task.sh state <id> done` |
| any case `blocked` | a human gate — the `blocked:` line says which kind | see the reason table below |
| any case `covered` | another case's test covers it; one edit satisfied both | nothing — it's terminal |
| `blocked: unspecified=N` | a manifest written before reasons were required | re-mark those rows with a `--reason` |
| `track: MISSING` | the task points at an area that doesn't exist | a typo'd `task.sh area`, or the track was renamed |

## Reading the `blocked:` line

`blocked` used to be one number covering several opposite meanings — a track could
report 39 blocked where most were already done and had no legal state to say so.
Now every blocked row carries a reason key, and `status.sh` groups by it:

| Key | Waiting on | The next move |
| --- | --- | --- |
| `missing-module` | a scope + contract decision | the human decides, then `/sdd-implement` resumes |
| `wont-go-red` | a look at the test or the behaviour | the behaviour may already exist |
| `already-broken` | a bug fix | file it; this isn't loop work |
| `needs-business-rule` | a documented rule | `/business-wiki:feature`, then re-spec |
| `dirty-worktree` | the worktree | clean it and resume |
| `spec-wrong` | intake | `/sdd-spec` on that row, not `/sdd-implement` |
| `other` | read the free text | — |

Only `spec-wrong` sends work backwards. Everything else resumes where it stopped.
A `covered` count is **not** a test count: say "N rows satisfied by another case's
test" rather than folding it into the green ones.

`automatable pending` is the number that says how much work the loop can still
do on its own. A track whose only remaining cases are `manual` is finished as far
as `/sdd-implement` is concerned, and waiting on QA.

If the user asked about one task, lead with that task's diagnosis rather than the
whole table.
