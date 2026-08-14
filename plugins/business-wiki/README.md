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
```

A `PostToolUse` hook runs `check-wiki.sh --changed` after any Write/Edit, so a broken link or a missing frontmatter key is caught the moment it is written. It exits silently for files outside the wiki.

## Who maintains what

The AI is the author. The human's job is to (1) approve the diff and (2) point at gaps. The loops that keep the three formats in step:

| Loop | Trigger | Effect |
| --- | --- | --- |
| Derive rules | `business-docs/wiki/features/<x>/` changed | `business-rules-keeper` regenerates `<x>.json`; a rule found only in code becomes a proposed **wiki** edit |
| Derive OpenAPI | `features/<x>/api.md` or the code contract changed | `openapi-keeper` regenerates that fragment |
| Detect drift | on demand or nightly | `source-drift-watcher` compares all four and reports |
| Auto-improve | end of a track (`/business-wiki:harvest`) | spec-vs-code deltas, decisions without an ADR, divergences, and rules cited in code but undocumented all become proposed wiki edits |
