---
name: sdd-spec
description: >-
  Intake for one task. Resolves which task is meant, then hands the whole of
  intake to the sdd-track-planner agent: locate or create the track, check the
  business wiki, probe the real test seams, go and look at the values each
  red-first assertion contradicts, write spec.md and the use-case tables,
  validate, generate use-cases.json, and move the task to specced. Relays the
  agent's report. Stops there — writing the tests is /sdd-implement's job.
---

# /sdd-spec — task → track → spec + use cases → specced

Usage: `/sdd-spec #<task-id>` or `/sdd-spec <description of the task>`

Entry condition: a task in the store, in `new`.
Exit condition: that task in `specced`, with a track holding a validated
`spec.md` and a generated `use-cases.json`.

**This skill resolves the task and then delegates.** Intake's real work is
fact-finding — read every wiki page the lookup names, probe the seams where the
test will actually be written, and open the ARB / constant / provider behind
every red-first assertion. That's a lot of file reading whose *conclusions* are
what matters, so it runs in `sdd-track-planner`'s own context and comes back as a
report.

## Sequence

### 1. Find the task — yours, not the agent's

- `scripts/task.sh list`, or `task.sh next` for the first one in `new`. Given
  `#<id>`, that id is the task: confirm it with `task.sh show <id>` and move on.
- Given a description with no id, match it against the list. More than one
  plausible match, or none, and you stop **here**: don't invent a task and don't
  create one silently. If the user clearly means "and make a task for this", say
  so and use `/sdd-task new` first.
- Derive the **scope path** the task touches — the package or module, e.g.
  `packages/features/loans`. The agent's seam probe needs it, and a repo-root
  probe is worse than useless.

### 2. Hand it to `sdd-track-planner`

Spawn `sdd-tdd-loop:sdd-track-planner` with the task id and that scope path. The
procedure lives in the agent file — one copy, in the place where it executes.
Don't restate it, don't second-guess it, and don't run its steps yourself
alongside it.

### 3. Relay what it returns

- A report → relay it, lead with the track path and the case counts, and go to
  step 4.
- `STOPPED: <condition>` on the first line → **relay it and stop.** The task is
  still in `new` and the reason is on the task as a note. Every stop condition
  the agent has is a decision that belongs to a human: a track family it can't
  disambiguate, a requirement that contradicts a documented rule, a red-first row
  whose value already satisfies its own assert. **Don't work around it** — that's
  the gate doing its job.
- Any builder **warnings** in the report get relayed too. A suspicious assertion
  is exactly the thing that survives validation and wastes a red-green cycle.

### 3b. If the agent can't run

If `sdd-track-planner` is unavailable to you, say so in one line, then run its
procedure inline from
`${CLAUDE_PLUGIN_ROOT}/agents/sdd-track-planner.md` — and record `planned_by: hand`
in the note.

The stamp is the point. Output the main loop wrote carefully and output the agent
produced are otherwise indistinguishable, and everything downstream trusts both
equally. Degrading silently is a worse failure than not running at all, because
nobody knows to re-check it.

### 4. Stop here, explicitly

Tell the user where this ends: the task is `specced`, the track has a validated
`spec.md` and a `use-cases.json`, and **no test has been written**.
`/sdd-implement <area>` is the next step, and it's a separate decision.

## Don't outsource the shell

Every script in this plugin works without a TTY: it prints
`[no-tty] proceeding: <action>` and continues. **Never ask the user to run one for
you.** If one seems to need a terminal, that's a bug in the script — report it,
don't delegate it. Same for anything derivable: the area comes from the title
through `slugify.sh`, the wiki path from `wiki-config.sh`, the honest test levels
from `probe-test-seams.sh` (which reads this repo's seam profile, not a table baked
into the plugin), this repo's test conventions from whatever `lang-guide.sh` names,
and the states are fixed. None of those are questions.

## Configuration

The workflow, the states and the paths are fixed — `tracks/<area>/` and
`.sdd-tdd/tasks.json`, `new → specced → implementing → verify → done` (+
`blocked`). The only thing configurable is the wiki connection, in
`.claude/sdd-tdd-loop.json`:

```json
{ "wikiRoot": "business-docs/wiki", "rulesRoot": "business-docs/rules", "wikiRequired": false }
```

All three are optional. With no file at all, `business-docs/wiki/` is
auto-detected if it exists, and the agent's wiki step is skipped if it doesn't.

The other per-repo file is `.claude/sdd-tdd/seams.json` — the **seam profile**: which
test levels this repo has and how each one is recognised. It's what makes the `Level`
vocabulary the repo's own rather than the plugin's, and `/sdd-init` writes it alongside
the repo-local language skill. Without it the probe falls back to a built-in marker
table that only knows Dart/Kotlin/Swift, TS/JS and Python — in any other ecosystem that
reads as "this repo has no tests" and pushes every use case to `manual`, which is
intake's **stop 8**, not a spec to approve.
