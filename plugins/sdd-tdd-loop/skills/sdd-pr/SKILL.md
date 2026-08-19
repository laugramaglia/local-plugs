---
name: sdd-pr
description: >-
  Open the track's pull request as a DRAFT at the start of the work, then keep it
  current: every run regenerates the body from the spec and the use-case evidence,
  pushes what's committed, and marks it ready for review only once every
  automatable case is refactored and the task is at verify. Drafts first, asks
  what it can't derive, then pushes.
---

# /sdd-pr — a draft PR from the start, kept true to the track

Usage: `/sdd-pr <area>` or `/sdd-pr #<task-id>`

Entry condition: a track with a `spec.md` (a `use-cases.json` too, normally), and
a git remote.
Exit condition: a PR that exists, is a draft until the work is genuinely done, and
whose body matches the track as it stands right now.

`SDD=${CLAUDE_PLUGIN_ROOT}/scripts` below.

## Why the PR opens before the work is finished

A PR opened at the end is a wall of diff with a description written from memory.
A **draft** opened as soon as the spec exists carries the requirements, the
enumerated cases and the falsifiability entries from minute one — so a reviewer
can disagree with the *specification* while it's still cheap, which is the review
that actually saves work. This is the one thing the ancestor plugin got for free
from its board integration, and it's back without any of the board.

Kept true is the other half. A description written once is wrong by the third
commit and nobody rewrites it, so the body is **generated** from the track on
every run, and the parts a human wrote are protected by markers rather than by
discipline:

```
<!-- sdd-tdd:begin -->   everything here is regenerated, wholesale
<!-- sdd-tdd:end -->     everything outside survives untouched
```

Reviewer notes, screenshots, deploy caveats — put them **outside** the markers and
they persist across every update. Anything inside will be overwritten, which is
worth saying out loud once in the PR itself.

## 1. Facts before anything

- The track: `$SDD/locate-track.sh <keywords>` if the area is fuzzy; a `#<id>`
  resolves through `$SDD/task.sh show <id>`.
- `$SDD/pr-body.sh <area>` — read-only. Prints a `title=` line, a `ready=yes|no`
  verdict with its reason, the `base=` it will diff against, then the body.
- The branch and the remote:

```bash
git rev-parse --abbrev-ref HEAD
git remote -v
gh pr view --json number,isDraft,url,headRefName 2>/dev/null
```

Three stops, all of them a human's call, none of them workaroundable:

- **No remote** → stop. There is nothing to open a PR against, and adding a
  remote is not this skill's decision.
- **On the base branch** (`main`/`master`) with commits to push → stop and say so.
  A PR needs a branch of its own; creating and moving one is a decision, and
  `git switch -c` here would rewrite what the user is standing on.
- **Uncommitted work** → say what's dirty and stop. A PR describes commits; a
  dirty tree means the description would be about work nobody can see.
  `/sdd-commit` first.

## 2. Draft, then ask

Show the generated title and body **in full** before anything is pushed, with
your own edits already applied:

- the `type` in the title is yours to choose, exactly as in `/sdd-commit` —
  `pr-body.sh` leaves it as `<type>` on purpose.
- add the paragraph the generator can't write: what a reviewer should look at
  first, and what you are least sure about. Put it *outside* the markers.

Then ask only what's left. Typically:

- draft or ready — and the honest default is **draft**, right up until
  `ready=yes`;
- who reviews it, if the repo doesn't assign automatically;
- whether the body's `base` is right, when `pr-body.sh` had to guess it (it says
  when it did);
- anything in the spec's `## Gaps` that should block the review rather than ride
  along in the description.

## 3. Push, then create or update

**First run** — create it as a draft:

```bash
git push -u origin HEAD
gh pr create --draft \
  --base <base> \
  --title "<the agreed title>" \
  --body-file ${TMPDIR:-/tmp}/sdd-pr-body.md
```

**Every run after** — regenerate and replace, preserving what's outside the
markers:

```bash
gh pr view --json body -q .body > ${TMPDIR:-/tmp}/sdd-pr-current.md
$SDD/pr-body.sh <area> | sed -n '/^--- body ---$/,$p' | tail -n +2 > ${TMPDIR:-/tmp}/sdd-pr-generated.md
# splice: keep everything before <!-- sdd-tdd:begin --> and after <!-- sdd-tdd:end -->
gh pr edit --body-file ${TMPDIR:-/tmp}/sdd-pr-body.md
git push
```

Do the splice yourself and show the result. If the current body has **no
markers** — someone rewrote it by hand, or it predates this skill — do not
overwrite it: append the generated block at the end, say that's what you did, and
let the human merge the two.

## 4. Ready for review is a gate, not a step

Mark it ready **only** when `pr-body.sh` says `ready=yes`: every automatable case
`refactored` or `covered`, nothing `blocked`, and the task at `verify`.

```bash
gh pr ready
```

`ready=no` is not an obstacle to route around — it's the same gate the loop
enforces everywhere else. Green tests are not a finished feature, the manual cases
are still in the body as unticked boxes, and **nothing here marks a task `done`**.
If the user asks for ready anyway, say what's outstanding in one line, then do as
they asked.

## 5. Report

- the PR url, whether it's a draft, and what changed in the body this run
- the case counts as the body now states them
- what's still outstanding for a human: the manual cases, the blocked ones,
  running the app

## What I don't do

- **Merge.** Not `gh pr merge`, not with any flag, not when the checks are green.
- **Rewrite history** to make a nicer PR — no force-push, no rebase, no squash.
- **Push to the base branch**, or open a PR from it.
- **Invent reviewers, labels or milestones** the repo doesn't already use.
- **Touch `spec.md`, `use-cases.json` or the task state** to make the body look
  better. If the body is wrong, the track is wrong, and that's an intake fix.
- **Report a PR as updated without reading back what landed.** `gh pr view` after
  the edit costs one call and is the only proof.
