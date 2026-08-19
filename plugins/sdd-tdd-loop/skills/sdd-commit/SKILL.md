---
name: sdd-commit
description: >-
  Commit the work in front of you as one Conventional Commit. Drafts the message
  first — from the diff and, when there is one, from the track's use cases and
  their red/green evidence — then asks only the questions the diff can't answer,
  then stages the paths it named and commits. Pushes and refreshes the draft PR
  when the branch already has one. Never `git add -A`, never amends a pushed
  commit.
---

# /sdd-commit — draft, ask, then commit

Usage: `/sdd-commit`, `/sdd-commit <area>`, or `/sdd-commit #<task-id>`

Entry condition: a dirty worktree.
Exit condition: one commit (or a named few), and the branch's draft PR current if
it has one.

`SDD=${CLAUDE_PLUGIN_ROOT}/scripts` below.

## The order, and why it is this order

**Draft first, ask second, commit third.** A question asked before the draft
exists is a question the human has to answer in the abstract ("what type is
this?"), and most of them the diff already answers. A draft shown first turns the
conversation into review — which is the only form in which a commit message gets
better instead of longer.

## 1. Draft

`$SDD/commit-draft.sh [area]` — read-only. It reports the branch, what's staged
versus merely dirty, the changed files grouped by the unit a `scope` names, the
evidence for a `type`, and — with an area — the track's cases in flight with
their `Assert` text.

Then read the actual diff. `git diff` / `git diff --cached`, and `git log
--oneline -10` for how *this repo* writes messages: match its voice rather than a
generic house style.

Write the message to a scratch file (`${TMPDIR:-/tmp}/sdd-commit-msg.txt`) and
**show it in full**:

```
<type>(<scope>): <what it does, imperative, lower case, no period>

<why the previous behaviour was wrong or missing — concretely, the failure and
not the file list. Then why this shape and not the obvious alternative.>

<the evidence: which test was observed red, then green.>

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

Rules worth being strict about, because they're what makes the log readable:

- **`type` is a claim about intent, and the diff can't make it.** `feat` is
  behaviour that wasn't there; `fix` is behaviour that was wrong — and a `fix`
  body that doesn't say what it did wrong is a `feat` in disguise. `refactor`
  means the tests are unchanged, so if a test changed it isn't one.
- **`scope`** is the plugin, package or track — one word, the unit a reader would
  grep for. No scope is better than a scope that covers two things.
- **The subject says what the change does; the body says why.** "update
  probe-test-seams.sh" describes the diff, which the reader already has.
- **A breaking change is `type(scope)!:` plus a `BREAKING CHANGE:` footer**
  naming what a caller has to do differently.
- **RF ids go in the body**, or the subject's tail at most. `RF-1.2` means
  nothing to whoever reads the log next year.

## 2. Ask — only what's left

`commit-draft.sh` prints its `## open questions`; add the ones reading the diff
raised. Ask them **in one round**, with your draft on the table, and keep them
about intent:

- the split: the draft flags a diff spanning several groups. One commit per group,
  in dependency order — unless they are genuinely one change, which is a call
  only the author can make.
- untracked files: in or out. **Never `git add -A` to decide** — that is how a
  scratch file, a `.env` or a coverage dir gets committed, and it's why this skill
  stages explicit paths.
- code changed with no test: deliberate, or a missing test.
- `feat` versus `fix`: what was the behaviour before.

Nothing to ask is a valid outcome. Say the draft stands and go on.

## 3. Commit

```bash
git add <the exact paths, named>            # never -A, never .
git commit -F ${TMPDIR:-/tmp}/sdd-commit-msg.txt
```

Then `git log --oneline -1` and `git status --short`, and report both: what
landed, and what is deliberately still dirty.

- **A pre-commit hook that fails is a stop.** Report its output; don't
  `--no-verify`.
- **Never amend a commit that is already pushed**, and never rewrite history to
  tidy a message. A follow-up commit is cheap.
- When the answers produced several commits, do them one at a time, each with its
  own message and its own `git add` — and check the tests still pass between them
  if a commit could stand alone.

## 4. Keep the PR current

If the branch has a PR (`gh pr view --json number,isDraft,url` succeeds), the
commit isn't finished until the PR reflects it:

```bash
git push
$SDD/pr-body.sh <area> > ${TMPDIR:-/tmp}/sdd-pr-body.md
gh pr edit --body-file ${TMPDIR:-/tmp}/sdd-pr-body.md
```

That's the whole point of the draft PR: it carries the spec and the case
evidence, so it has to be regenerated whenever a case moves. Details, including
what happens to prose a reviewer added, are in `/sdd-pr` — call it rather than
reimplementing it here. No PR yet, and no push: say so in one line, and name
`/sdd-pr` as the next step if that's what the user wants.

## What I don't do

- **`git add -A` / `git add .`** — see above.
- **Push a branch that has no PR**, unless asked. A push is visible to other
  people; the commit isn't.
- **Commit `.sdd-tdd/tasks.json` silently along with code.** It's a real file
  worth committing, but bundling the task store into a code commit hides both.
  Name it, or give it its own `chore(tasks):` commit.
- **Move a task's state.** That's `task.sh`, driven by the loop's own skills. A
  commit is not a state transition.
- **Invent evidence.** "observed red, then green" belongs in a message only when
  it happened, in this session or recorded in `use-cases.json`.
