# business-wiki

**The wiki is the source. OpenAPI and JSON are precise context.**

Most projects scatter their business rules across prose docs, type definitions, SQL comments, and hard-coded constants in view models. Nobody can answer "what is the rule?" without reading code, and nothing notices when the code stops matching the docs.

This plugin sets up three formats with one direction of authority:

| Format | Written by | Read by | Authority |
| --- | --- | --- | --- |
| `business-docs/wiki/` (Markdown) | AI, human-reviewed | humans, agents by default | **the source** |
| `business-docs/rules/<feature>.json` | derived | agents needing a keyed lookup | derived |
| `business-docs/openapi/api.yaml` | derived | agents touching an endpoint, codegen | derived |

A divergence between the three is **always** resolved in the wiki's favour. Decisions, divergences, and prose live only in the wiki and are never duplicated into the derived formats.

It is not "JSON first, then wiki". It is **wiki by default; OpenAPI and JSON when you need precision** — an agent about to change an endpoint reads that one path, not the whole spec.

## Install

```bash
/plugin marketplace add ~/Documents/workspace/local-plugs
/plugin install business-wiki@local-plugs
/business-wiki:bootstrap
```

## Commands

| Command | Use it when |
| --- | --- |
| `/business-wiki:bootstrap` | First run in a repo. Detects the stack, proposes the feature list, scaffolds the wiki. |
| `/business-wiki:feature <name>` | Author or refresh one feature's page set. |
| `/business-wiki:adr <title>` | Record a decision as the next-numbered ADR and link it from the features it affects. |
| `/business-wiki:derive [feature]` | Regenerate the rules JSON and the OpenAPI fragments from the wiki. |
| `/business-wiki:check` | Run the validators. |
| `/business-wiki:harvest` | End of a track: what did we learn that belongs in the wiki? |

## Agents

| Agent | Role |
| --- | --- |
| `business-wiki:wiki-keeper` | Authors and maintains the wiki. The only agent that writes prose. |
| `business-wiki:business-rules-keeper` | Derives `business-docs/rules/<feature>.json`; opens the **inverse** change when code has a rule the wiki lacks. |
| `business-wiki:openapi-keeper` | Derives the OpenAPI document from the wiki's `api.md` plus the real code contract. |
| `business-wiki:source-drift-watcher` | Read-only four-way compare: wiki ↔ rules ↔ OpenAPI ↔ code. Reports; never fixes. |

## Structure it creates

One root, three trees. The split inside it is the authority boundary: `wiki/` is authored and reviewed, `rules/` and `openapi/` are machine output.

```
business-docs/
├── README.md                     how the three formats relate and which one wins
├── wiki/                         ← the source
│   ├── README.md                 the wiki's own index: features, where to start
│   ├── decisions/                ADRs — 0001-slug.md, linkable from code comments
│   ├── features/<feature>/
│   │   ├── index.md              overview + the feature's rule table
│   │   ├── flow.md               happy path
│   │   ├── screens.md            screens and their IDs
│   │   ├── states.md             states + transitions
│   │   ├── errors.md             error catalogue and how each surfaces
│   │   ├── copy.md               user-visible strings with business weight
│   │   ├── validations.md        client-side validation rules
│   │   ├── api.md                only the endpoints this feature touches
│   │   ├── decisions.md          the ADRs that apply here
│   │   └── related.md            neighbouring features, shared components
│   └── shared/                   glossary, data types, error codes, divergences, a11y…
├── rules/                        ← derived
│   └── README.md  _schema.json  <feature>.json
└── openapi/                      ← derived
    └── api.yaml  README.md  examples/
```

All three paths are configurable, so a project that already has a `docs/` tree can point `wiki_root` at `docs/wiki` and keep the same shape.

## Configuration

Set at install time (`/plugin` → business-wiki → configure), all optional:

| Option | Default | Meaning |
| --- | --- | --- |
| `wiki_root` | `business-docs/wiki` | Where the wiki lives. |
| `rules_root` | `business-docs/rules` | Where the derived rules live. |
| `openapi_path` | `business-docs/openapi/api.yaml` | Derived spec. Empty ⇒ the project has no HTTP surface and OpenAPI steps are skipped. |
| `contract_source` | *(empty)* | Where the real endpoints are defined, e.g. `worker/src`. |
| `strict_check` | `false` | `true` makes validator warnings fatal. |

## Validators

POSIX `sh`, no runtime dependencies. Run them from the project root.

```bash
sh "$PLUGIN/scripts/wiki-health.sh"     # is the system installed at all?
sh "$PLUGIN/scripts/check-wiki.sh"      # frontmatter, sections, [[links]], code_refs, ADR refs
sh "$PLUGIN/scripts/check-rules.sh"     # rules JSON shape + wiki cross-reference
sh "$PLUGIN/scripts/check-openapi.sh"   # spec parses; every real route documented
bash test/run-tests.sh                  # 61 assertions, offline, no writes outside a sandbox
bash test/run-tests.sh provenance       # only matching groups
```

A `PostToolUse` hook runs `check-wiki.sh --changed` after any Write/Edit, so a broken link or a missing frontmatter key is caught the moment it is written. It exits silently for files outside the wiki.

### `code_refs` are checked as citations, not as paths

The citations **are** the authority model: a page is trustworthy because it points at the code it describes. So `check-wiki.sh` resolves each `code_refs` entry properly —

- a path that no longer exists is an **error**;
- `path:line` past the end of that file is an **error** (`score.dart:88` in a 40-line file is a dead citation that a plain existence check calls fine);
- a ref whose file changed after the page's own `updated` date is a **warning** — not wrong on its own, but it is where wrongness accumulates. Silent outside a git repo, and skipped in hook mode so a keystroke-time check never waits on `git log`.

### Provenance: `derived_by`

The keepers are agents. If one can't run — no authorization, a headless session — the
derive can still produce a correct-looking file, because a model writing carefully
produces valid JSON. What it can't produce is a **reproducible** file: a second derive
won't be a no-op, and the idempotence this plugin claims becomes unprovable.

So every derived file records which side produced it: `derived_by` in the rules JSON
(`business-rules-keeper` | `hand`), `info.x-derived-by` in the OpenAPI. `check-rules.sh`
and `check-openapi.sh` **warn** on `hand` and on a missing stamp — fatal under
`strict_check` — until a real derive replaces it. `_generated_by` is the pre-provenance
spelling and is reported as deprecated rather than as hand-written.

The derive's verdict line carries the same discipline for the gate itself:

```
drift:      0 high / 2 medium     | drift: NOT RUN (source-drift-watcher unavailable)
keepers:    business-rules-keeper | keepers: not-run (hand-derived)
validators: check-rules pass, check-openapi pass (1 warn)
```

`drift: NOT RUN` is a legal outcome — "no watcher" is not the same as "no findings",
and a derive that couldn't compare documentation to code must not read like one that
did.

The point is that a hand-derive stays *visible*. Silent degradation into "the model did
it carefully" is a worse failure than not deriving at all, because nobody knows to
re-check it.

### What the validators do NOT check

They check that the output is **well-formed and internally consistent** — the YAML parses, referenced paths resolve, ids line up. None of them compares a documented rule against what the code actually does.

That distinction is not academic: `check-rules.sh` and `check-openapi.sh` both **passed** on a repo whose OpenAPI still described a response shape an accepted ADR had already replaced. Agreement with code is `source-drift-watcher`'s job, it is semantic, and `/business-wiki:derive` now runs it **as a gate before regenerating anything** — a `high` finding not already recorded in `shared/divergences.md` stops the derive. Deriving from a wiki the code contradicts launders the contradiction into a machine-readable artifact that everything downstream then trusts.

## Who maintains what

The AI is the author. The human's job is to (1) approve the diff and (2) point at gaps. The loops that keep the three formats in step:

| Loop | Trigger | Effect |
| --- | --- | --- |
| Derive rules | `business-docs/wiki/features/<x>/` changed | `business-rules-keeper` regenerates `<x>.json`; a rule found only in code becomes a proposed **wiki** edit |
| Derive OpenAPI | `features/<x>/api.md` or the code contract changed | `openapi-keeper` regenerates that fragment |
| Detect drift | **before every derive**, plus nightly if you want it | `source-drift-watcher` compares all four and reports; a new `high` finding blocks the derive |
| Auto-improve | end of a track (`/business-wiki:harvest`) | spec-vs-code deltas, decisions without an ADR, divergences, and rules cited in code but undocumented all become proposed wiki edits |

`/business-wiki:harvest` also posts a `wiki-delta` note on the sdd-tdd task when that plugin is in use — `task.sh state <id> done` refuses without one, so a track can't be called finished having never looked at the wiki.
