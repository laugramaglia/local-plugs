---
name: sdd-task
description: >-
  Create, list, inspect and move a local sdd-tdd task. The task store is a
  single committed JSON file — this plugin's replacement for a board — and it is
  what /sdd-spec reads to know what to write a spec for. Use it whenever the
  user describes work to be done, asks what's in flight, or wants a task moved
  to another state.
---

# /sdd-task — the local task store

Usage:

```
/sdd-task new <description of the work>
/sdd-task list [<state>]
/sdd-task show <id>
/sdd-task state <id> <state>
/sdd-task note <id> <what happened>
/sdd-task remove <id>
```

Everything here is `scripts/task.sh`. **Never hand-edit the JSON store** — the
transition rule (forward-only along the project's `states`, `blocked` reachable
from anywhere) lives in that script, and an agent editing the file by hand
bypasses it and gets the array index wrong on the second task it sees.

## Creating a task — the only step with judgement in it

`new` is where the work gets its title, its description and its area, and all
three are yours to derive rather than to ask about.

1. **Title** — one line, imperative, specific enough to recognise in a list.
   Strip house prefixes and ticket noise the user pasted in; the id is already
   the id.
2. **Description** — everything the user told you that a spec would need:
   the observed behaviour, the wanted behaviour, concrete values, the screen or
   endpoint involved, anything they said about edge cases. Write it to a scratch
   file and pass `--description-file`; don't try to squeeze a paragraph through
   shell quoting.
   **Don't invent requirements to pad it.** A thin description is a fact about
   the task, and `/sdd-spec` is where the gap gets named.
3. **Area** — derive it, don't ask:
   `scripts/slugify.sh --area 3 "<title>"`, and prefer 2-3 meaningful words you
   pick from the title yourself over the mechanical fallback (`loan-simulation`,
   not `correccion-visualizacion-importe`). Pass it as `--area` **only if a
   track for it already plausibly exists** — otherwise leave it off and let
   `/sdd-spec` link the task once `locate-track.sh` has actually decided.

```bash
scripts/task.sh new "Loan simulation clips the amount when the keyboard opens" \
  --description-file /tmp/task-desc.md
```

Report the id it prints. That id is how every later command refers to the task.

## The other subcommands

- `list` — no argument lists everything with a by-state tally; `list <state>`
  filters. A state the project never declared is an error, not an empty list.
- `show <id>` — title, state, area, description and every note.
- `state <id> <state>` — moves it. `@spec` and `@implement` resolve through the
  config's `advanceTo`, which is what the two loop skills pass; a human naming a
  state directly is fine too. Backwards needs `--force`, and you should say why
  you're using it.
- `note <id>` — append a dated note. This is the channel for anything a human
  needs to read later: cross-check findings, why a run stopped, what a blocked
  case is waiting on. Write the text to a scratch file and pass the path.
- `remove <id>` — deletes the task, never its track.

## What this skill does not do

It doesn't write specs, doesn't create tracks and doesn't run tests. A task is
an intention; `/sdd-spec` turns it into a specification and `/sdd-implement`
turns that into tests and code. If the user's ask is "and now do it", the answer
is to hand off to those, not to widen this one.
