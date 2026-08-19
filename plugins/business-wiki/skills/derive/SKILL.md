---
name: derive
description: Regenerate the derived formats — business-rules JSON and the OpenAPI document — from the wiki, gated on a drift check, and show one combined diff. Use after wiki pages change, or to prove the derived formats still agree with the code.
argument-hint: [feature-slug]
---

# Derive the machine-readable formats

## Feature scope: $ARGUMENTS

If a feature slug is given, that feature. Otherwise every feature whose wiki pages
changed since the last derive (`git diff --name-only` against the last commit that
touched the rules root, falling back to all features).

## Mission

Regenerate `rules/<feature>.json` and the OpenAPI document **from the wiki**, and prove
along the way that the wiki still describes the code.

**Core Principle**: The wiki is the source. A derived format never gains a rule the
wiki lacks — when a keeper finds an undocumented rule in code, the fix is a **wiki**
edit followed by a re-derive, not a quiet addition to the JSON.

**Key Philosophy**: *A derive that couldn't check itself must say so.* Deriving from a
wiki the code contradicts launders the contradiction into a machine-readable artifact
that everything downstream then trusts. So the drift check is a gate, not an extra —
and when the gate couldn't run, the report says that instead of reading like a clean
run.

Config: `${CLAUDE_PLUGIN_OPTION_WIKI_ROOT}`, `${CLAUDE_PLUGIN_OPTION_RULES_ROOT}`,
`${CLAUDE_PLUGIN_OPTION_OPENAPI_PATH}`, `${CLAUDE_PLUGIN_OPTION_CONTRACT_SOURCE}`.
`WIKI=${CLAUDE_PLUGIN_ROOT}/scripts` below.

---

## Process

### Phase 0: Gate — is the wiki still true?

Before regenerating anything:

**1. Citations resolve.**

```bash
sh "$WIKI/check-wiki.sh"
```

A page whose `code_refs` no longer resolve is not a source of truth for a generated
format. Errors here stop the derive.

**2. Semantic drift.** Run `business-wiki:source-drift-watcher` over the features in
scope. **Any `high` finding that `shared/divergences.md` does not already record stops
the derive.** Fix the format the watcher names — or record the divergence deliberately
— then start again.

| Watcher outcome | What it means | Action |
| --- | --- | --- |
| no new findings | wiki, rules, OpenAPI and code agree | proceed |
| `medium` / `low` only | real drift, no immediate wrong-code risk | proceed, and carry the findings into the report |
| new `high` | an agent acting on the documented rule would write incorrect code | **stop** |
| `high`, already in `divergences.md` | a divergence the team accepted | proceed — the ledger is what makes it a decision rather than a bug |
| **the watcher can't run** | nothing compared documentation to code | proceed **only** with `drift: NOT RUN` in the report, and never call the result clean |

### Phase 1: Rules

Run `business-wiki:business-rules-keeper` for each feature in scope.

Stamp provenance in the output: `"derived_by": "business-rules-keeper"`.

**If the keeper cannot be spawned** you may write the file yourself — but stamp
`"derived_by": "hand"`, and say so in the report's verdict line. This is not a
preference. Hand-written output and keeper output are byte-indistinguishable, everything
downstream trusts both equally, and idempotence is unprovable for the hand version. An
unstamped hand-derive is the failure mode this stamp exists to make visible;
`check-rules.sh` warns on the stamp so the next real derive is forced.

### Phase 2: OpenAPI

Run `business-wiki:openapi-keeper` if `openapi_path` is set **and** any feature in scope
has an `api.md` with endpoints, or the contract source changed.

Same provenance rule, in `info.x-derived-by`.

### Phase 3: Validate

```bash
sh "$WIKI/check-rules.sh"
sh "$WIKI/check-openapi.sh"
```

### Phase 4: One diff, then the verdict

Show **one** combined diff, grouped by format, then the summary. A clean derive and an
unchecked one must not read the same, so the verdict line carries all three facts
explicitly:

```
drift:      0 high / 2 medium          | drift: NOT RUN (source-drift-watcher unavailable)
keepers:    business-rules-keeper, openapi-keeper | keepers: not-run (hand-derived)
validators: check-rules pass, check-openapi pass (1 warn)
```

`drift: NOT RUN` is a legal outcome. "No watcher" is not the same as "no findings", and
writing the absence down is the only thing that makes the difference recoverable later.

---

## Why phase 0 is a gate and phase 3 isn't the same check

They answer different questions, and conflating them is how this went wrong once
already: `check-rules.sh` and `check-openapi.sh` both **passed** while the OpenAPI still
described a response shape an accepted ADR had replaced.

| Check | Question | Catches | Misses |
| --- | --- | --- | --- |
| phase 3 validators | is the output well-formed and internally consistent? | unparseable YAML, a rule citing a page that doesn't exist, ids that don't line up | anything where the documentation and the code simply disagree |
| phase 0 watcher | does the documentation still describe the code? | a wiki saying 120s against a constant of 90; a response shape an ADR replaced | nothing about format hygiene — it never edits |

That comparison is semantic, it is the watcher's job, and it has to happen **before** the
keepers run.

## Direction of authority

The derived formats never gain a rule the wiki lacks.

- A keeper reporting an **undocumented rule found in code** → surface it prominently as
  a proposed **wiki** edit. Don't fold it into the JSON.
- A **wiki rule the code contradicts** → it lands as `status: documented-not-enforced`
  and goes into `shared/divergences.md`.

## Idempotence

A second run with no wiki change must produce **no diff.** If it does, that is a bug in
a keeper's ordering or timestamp handling, not an acceptable outcome — report it, because
a format that churns on every run teaches everyone to ignore its diffs.

---

## Quality Criteria

### The gate actually ran ✓

- [ ] `check-wiki.sh` passed before anything was regenerated
- [ ] The watcher ran over every feature in scope, **or** the report says `drift: NOT RUN`
- [ ] Every new `high` finding either stopped the derive or is recorded in
      `divergences.md`

### Provenance is in the artifact ✓

- [ ] Every regenerated `rules/<feature>.json` carries `derived_by`
- [ ] The OpenAPI carries `info.x-derived-by`
- [ ] Any `hand` stamp is repeated in the verdict line, not left only in the file

### Authority held ✓

- [ ] No rule exists in a derived format that the wiki doesn't state
- [ ] Every undocumented-rule finding is a proposed wiki edit, not a JSON addition
- [ ] Every code-contradicts-wiki finding is in `divergences.md`

### The diff is readable ✓

- [ ] One combined diff, grouped by format
- [ ] Rules reported by **id**: added / changed / removed
- [ ] OpenAPI reported by path and schema
- [ ] Key-order-only churn treated as a bug, not shipped as a diff

## Success Metrics

**Nothing derived from an unchecked wiki** — every regenerated file is downstream of a
phase 0 that either passed or is declared as not-run.

**Provenance is never implicit** — no reader has to guess whether a keeper produced a
file.

**Idempotent** — an immediate second run produces an empty diff.

## Report

- Rules added / changed / removed, by id
- OpenAPI paths and schemas touched
- Inverse proposals: rules found in code that belong in the wiki first
- Divergences recorded or already known
- The three-line verdict from phase 4 — `drift`, `keepers`, `validators`
