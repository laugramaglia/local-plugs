---
name: sdd-implement
description: >-
  The red-green-refactor loop over one track's enumerated use cases. Takes a
  track whose spec.md and use-cases.json /sdd-spec already wrote and validated,
  and drives each automatable case through: write the failing test, observe it
  red, make it green, refactor. One case at a time, to completion. Stops at the
  human verification gate — it never marks a task done.
---

# Drive a track's use cases to green

Usage: `/sdd-implement <area>` or `/sdd-implement #<task-id>`

## Mission

Turn each enumerated use case into **one test that was observed failing and then
observed passing**, and stop at the human verification gate.

**Core Principle**: The evidence is the product. A green test proves nothing on its
own — anyone can write an assertion that always holds. What proves the behaviour is
green *after* it was red, on the same test, with the change in between. Every rule
below exists to keep those two observations real.

**Key Philosophy**: *One case at a time, to completion.* Batching — write all the
tests, then implement all of them — destroys the only thing this loop provides: the
evidence that each specific test failed before its specific fix.

Entry condition: a track with a validated `spec.md` and a `use-cases.json` carrying at
least one automatable case still `pending` — i.e. `/sdd-spec` has already run.
Exit condition: every automatable case `refactored`, the task in `verify`, and the work
stopped at the human gate.

**This is a loop, and it runs on one task with a human present.** It repeats over use
cases, not over tasks: it never picks up the next task by itself, and every stop
condition hands control back rather than working around the problem.

`SDD=${CLAUDE_PLUGIN_ROOT}/scripts` in every command below.

## What I don't do, ever

Not prompts, not gates, not preferences — absent from the procedure:

- **Edit `spec.md`, `contract.md` or `CHANGELOG.md`.** Those are intake's output. A
  loop that rewrites its own requirements is not testing anything. A wrong case is a
  stop with a note, not a spec edit.
- **Hand-edit `use-cases.json`.** It's generated. Its `status` moves only through
  `mark-usecase-status.sh`, which refuses illegal jumps.
- **Create a feature module on my own.** See phase 3.
- **Move a task to `done`.** Green tests are not a finished feature; `verify` is as far
  as this goes.
- **Claim a case is green on a build that didn't run the test.**

## The ordering rule that defines this loop

**The test comes first, and the missing-module question comes after the test is red.**

```
1. write the failing test        <- touches only the test source set
2. run it, observe RED           <- the evidence
3. does the module exist?        <- ONLY NOW, and only if red says it's missing
4. make it GREEN
5. refactor
```

Writing a failing test touches no feature code, so at the moment the test is written
there is nothing to create. Asking earlier means asking about code the evidence hasn't
yet shown is needed. A `characterization` case over existing behaviour never reaches
phase 3 at all — neither does any case whose module is already there, which is most of
them.

---

## The two paths, and which one a row walks

The case's **Mode** decides it, and they are not interchangeable:

```
red-first          pending -> red    -> green -> refactored
characterization   pending -> pinned -> green -> refactored
```

Both demand **two observations of the test**, before and after the change. `red` is "I
watched it fail"; `pinned` is "I watched it pass before I touched anything". A
characterization case asserts must-not-break behaviour, so asking it for a red asks you
to make a passing test fail — `mark-usecase-status.sh` refuses `red` on those rows and
`pinned` on red-first ones, and says which one it wants.

**A third terminal state: `covered`.** One edit often satisfies several enumerated rows
— RF-3.1 and RF-3.4 fall to the same change, so RF-3.4 can never be observed red on its
own. That is neither a green nor a blockage:

```bash
$SDD/mark-usecase-status.sh <area> RF-3.4 covered --by RF-3.1
```

`--by` must name a case that has actually been through the loop (`green`, `refactored`,
or itself `covered`) — covering a row against a `pending` one proves exactly as much as
`pending -> green` does. Say in the report which rows were covered and by what:
`covered` is proof that another case's test covers the row, **not** proof that a test
exists for it.

**Never park a finished row in `blocked`.** `blocked` means a human is needed. A row
that is genuinely done and simply has no red of its own is `covered`.

## Red for the right reason

Phase 2 has two different failures and they mean opposite things:

| The red test fails because… | Meaning | Next |
| --- | --- | --- |
| the assertion didn't hold | the behaviour is genuinely missing | phase 4, no module question |
| the module/type doesn't exist (won't compile) | there's nothing to implement *into* | phase 3 |

Don't collapse these. A compile error is not a red test — it's the absence of a place to
put the code. Say which one you observed when you record the case red.

---

## The Loop

### Phase 0: Resolve the track and its cases

- Given `#<id>`: `$SDD/task.sh show <id>`. Its `area` is the track; no area is **stop 5**
  — run `/sdd-spec` first.
- Given `<area>`: use it directly, and find the task pointing at it with
  `$SDD/task.sh list --json` so the notes have somewhere to land.
- `$SDD/locate-track.sh` reports each track's **shape**. A `legacy` track has a
  `spec.md` but no `use-cases.json` — it was never through intake. **That's stop 5, not
  a reason to invent cases**: run `/sdd-spec` on it first.
- `$SDD/mark-usecase-status.sh <area> --summary` — where the track stands. Re-invoking
  this skill on a half-done track is normal and expected: it picks up at the first
  `pending` case and leaves finished ones alone.
- `$SDD/lang-guide.sh`, and **read what it names.** This plugin holds the process and
  none of the language: how a test at each seam is written in this repo — where the file
  goes, what it's named, the framework idiom, and above all **the command that runs one
  single test** — lives in a repo-local guide `/sdd-init` generated. Read it once here,
  not per case.
  - No guide (`guides=0`) is not a stop. It means the commands and conventions below are
    yours to infer, and the report has to say so in one line: an inferred test command
    and a specified one are indistinguishable afterwards, and only one of them was
    checked by a human.
- `$SDD/task.sh state <id> implementing`, once.

### Phase 1: Take the next case

- `$SDD/mark-usecase-status.sh <area> --next` returns the first **automatable** case
  still `pending`, with all seven columns. Exit code 3 (`NONE`) means every automatable
  case is done → phase 6.
- **Manual cases are never yours.** `--next` already filters them out; they're QA
  acceptance and stay `pending` until a human walks them. Don't write a test for "it
  looks right".
- Work **one case at a time, to completion.**

### Phase 2: Write the failing test, and watch it fail

**Read before writing:**

- The case row's seven columns — `Arrange` / `Act` / `Assert`, its `Level`, its `Mode`.
- The rows of `contract.md` the case touches.
- The spec's **`## Falsifiability`** row for this case *and* its **`## Verified current
  state`** entry. The row says why the assertion contradicts the code; the entry cites
  the `file:line` intake read that from. If the value it names already satisfies the
  assert, that's **stop 7** — not something to work around.

**Not from the spec.** One row is the change order. If this project has specialised
implementation subagents available, give them that same single row, not the whole spec.
Otherwise do it yourself, in the same order. **Don't invent an agent name to delegate
to.**

**Then run it — the ONE test, not the suite — and record what you saw:**

Use the single-test command from the language guide. This matters more than it looks:
a test that only ever ran inside the whole suite can be green because another test set
the state up, and then the red/green pair proves nothing about the change. If the guide
names no single-test invocation, find one and say in the report that you did.


| Mode | The observation | Record |
| --- | --- | --- |
| `red-first` | it fails — say which failure, per the table above | `mark-usecase-status.sh <area> <id> red` |
| `characterization` | it **passes** — that's the pre-change observation | `mark-usecase-status.sh <area> <id> pinned` |

A `red-first` case that doesn't fail → **stop 2**. A `characterization` case that's red
→ **stop 3**.

### Phase 3: Missing-module gate — only now, and only if red says so

Skip this phase entirely unless phase 2's red was **doesn't-compile because the module
is absent**. For everything else, go to phase 4.

Check whether the module exists. If it doesn't, **stop** (stop 1): report the path you
looked for and what the test needs, and let the human decide the scope and the contract
delta. Adding a feature module is not a step in this loop.

### Phase 4: Make it green

- The minimal change that makes **this one test** pass. No opportunistic scope.
- Compile and **run the tests** before continuing — this case's test by itself first,
  with the guide's single-test command, then the package's suite to catch what the
  change broke. `BUILD SUCCESSFUL` from an up-to-date task that executed nothing is not
  a green test — verify the test actually ran, and say so.
- `$SDD/mark-usecase-status.sh <area> <case-id> green`
- A missing business rule → **stop 4**.

### Phase 5: Refactor

- Cleanup with the tests as the safety net: duplication the change introduced, naming,
  anything the minimal green step left behind. **No new behaviour.**
- The tests must still pass afterwards — if the refactor breaks one, it's the refactor
  that's wrong.
- `$SDD/mark-usecase-status.sh <area> <case-id> refactored`

A finished case is the natural commit boundary — one case, one commit, with the
red-then-green observation in the body. `/sdd-commit <area>` drafts it and, when
the branch already has a draft PR, refreshes the PR from the track. Offer it;
committing is the user's call, and this loop never commits on its own.

Then back to phase 1.

### Phase 6: Record progress, then stop at the human gate

Once `--next` reports `NONE`:

```markdown
- Track: tracks/<area>/
- Cases: <N automatable — X refactored, Y covered> (<M> manual, for QA)
- Reds observed: <X assertion-failed, Y doesn't-compile>
- Covered: RF-3.4 by RF-3.1 (same edit satisfies both)
- Blocked: RF-2.2 needs-business-rule — <one line>
- Modules: <all existed | a decision was requested for <feature>>
- Language guide: <.claude/skills/sdd-lang-<stack>/SKILL.md | none — commands inferred>
- Still open for a human: run it, walk the manual cases, write the CHANGELOG entry
```

Report `covered` rows with their coverer and blocked rows with their reason key. Those
two lines are what `status.sh` can no longer be made to lie about, and prose in a note
is no longer where that truth lives.

```bash
$SDD/task.sh note <id> <that file> --title "sdd-implement"
$SDD/task.sh state <id> verify
```

**Then stop and say so plainly.** What remains is human work and is deliberately outside
this skill: run the app, walk the `manual` cases, write the track's `CHANGELOG.md`
entry, and — if the project has a wiki — register what this work established there
(`/business-wiki:harvest`).

**`done` is a human's word.** Nothing here sets it. And on a project with a wiki,
`task.sh state <id> done` refuses until the harvest has left its `wiki-delta` note, so
the closeout is a gate rather than a habit.

---

## Stop Conditions

On any of these: mark the case `blocked` **with its reason key**, write a short report,
post it with `$SDD/task.sh note <id> <file> --title "sdd-implement stopped"`, and stop
**without moving the task to `verify`**:

| # | Stop | `--reason` |
| --- | --- | --- |
| 1 | **A feature module the red test needs doesn't exist** (phase 3). Creating one is a scope decision plus a contract delta, and both are the human's. | `missing-module` |
| 2 | **The red test won't go red** — it passes on first run in `red-first` mode. Either the behaviour already exists or the test doesn't test what it says. Silently accepting a green "red" step is how a never-failing test gets recorded as proof. | `wont-go-red` |
| 3 | **A `characterization` case is red before any change.** It asserts must-not-break behaviour, so red at the start means something is *already* broken — a bug report, not a task for this loop. | `already-broken` |
| 4 | **The change needs a business rule nobody wrote down** — a limit, an error code, a precedence between two validations. Don't substitute your own judgement for a business rule. If the project has a wiki that's where the answer belongs, and `/business-wiki:feature` is how it gets there. | `needs-business-rule` |
| 5 | **The track has no `use-cases.json`**, or every automatable case is already done. Say so and stop — this is not an error, and nothing gets marked blocked. | — |
| 6 | **The worktree is dirty in a way you'd have to work around.** Never reach for `git add -A`. | `dirty-worktree` |
| 7 | **The row itself is wrong** — its assertion can't fail, or it contradicts the spec's own Falsifiability entry. Back to intake, not a fix here. | `spec-wrong` |

```bash
$SDD/mark-usecase-status.sh <area> <case-id> blocked --reason needs-business-rule
```

The reason is **required**, and that's the point: one `blocked` count covering several
different meanings is a number that tells a human nothing. `--reason other "<text>"`
exists for anything genuinely outside the list — reach for it last, because a key is
what `status.sh` can group by.

---

## Quality Criteria

### Two real observations per row ✓

- [ ] Every `red-first` row was recorded `red` from a run I watched fail
- [ ] Every `characterization` row was recorded `pinned` from a run I watched pass
- [ ] No row went `pending -> green`, and none was recorded green on a build that
      executed no tests
- [ ] Each red is labelled: assertion-failed, or doesn't-compile

### Minimal, per row ✓

- [ ] Each green change is the smallest one that passes **that** test
- [ ] No feature code was written before its test was red
- [ ] No module was created without a human decision
- [ ] Refactors added no behaviour, and the tests still pass

### Honest bookkeeping ✓

- [ ] Every `covered` row names a coverer that actually ran
- [ ] Every `blocked` row carries a reason key from the enum
- [ ] No finished row is parked in `blocked`
- [ ] `spec.md` / `contract.md` / `CHANGELOG.md` are untouched

### Stopped, not worked around ✓

- [ ] Every stop is a note on the task with the reason key, not a workaround
- [ ] The task is in `verify`, never `done`
- [ ] Manual cases are still `pending`, and named as QA's work

## Success Metrics

**Evidence completeness** — for every automatable row, two recorded observations of the
same test, in order.

**Zero silent greens** — no case is `green` without a test run whose output was read.

**`status.sh` tells the truth without prose** — the `blocked:` and `covered:` lines
alone explain where the track stands, and the note adds detail rather than the facts.

**Confidence score** — #/10 that the human's verify pass finds nothing the loop should
have caught, plus the one row most likely to be it.

## Report

Final message, short, in this order: the track, the case counts (refactored / covered /
blocked / manual), each blocked row with its reason key, each covered row with its
coverer, whether any module decision was requested, and what remains for the human —
run it, walk the manual cases, write the CHANGELOG entry, and harvest to the wiki.

## Configuration

None that affects this skill. The layout and the workflow are fixed; the only
configurable thing in the plugin is the wiki connection, which `/sdd-spec` uses.
