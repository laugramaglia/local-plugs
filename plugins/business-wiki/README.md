# business-wiki

**The wiki is the source. OpenAPI and JSON are precise context.**

Most projects scatter their business rules across prose docs, type definitions, SQL comments, and hard-coded constants in view models. Nobody can answer "what is the rule?" without reading code, and nothing notices when the code stops matching the docs.

This plugin sets up three formats with one direction of authority:

| Format | Written by | Read by | Authority |
| --- | --- | --- | --- |
| `business-wiki/` (Markdown) | AI, human-reviewed | humans, agents by default | **the source** |
| `business-rules/<feature>.json` | derived | agents needing a keyed lookup | derived |
| `openapi/api.yaml` | derived | agents touching an endpoint, codegen | derived |

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
| `business-wiki:business-rules-keeper` | Derives `business-rules/<feature>.json`; opens the **inverse** change when code has a rule the wiki lacks. |
| `business-wiki:openapi-keeper` | Derives the OpenAPI document from the wiki's `api.md` plus the real code contract. |
| `business-wiki:source-drift-watcher` | Read-only four-way compare: wiki ↔ rules ↔ OpenAPI ↔ code. Reports; never fixes. |

## Structure it creates

```
business-wiki/
├── README.md                 index + how it is maintained + how the 3 formats relate
├── decisions/                ADRs — 0001-slug.md, linkable from code comments
├── features/<feature>/
│   ├── index.md              overview + links to everything else
│   ├── flow.md               happy path
│   ├── screens.md            screens and their IDs
│   ├── states.md             states + transitions
│   ├── errors.md             error catalogue and how each surfaces
│   ├── copy.md               user-visible strings with business weight
│   ├── validations.md        client-side validation rules
│   ├── api.md                only the endpoints this feature touches
│   ├── rules.json            index → business-rules/<feature>.json
│   ├── decisions.md          the ADRs that apply here
│   └── related.md            neighbouring features, shared components
└── shared/                   glossary, data types, error codes, divergences, a11y…
business-rules/
├── README.md  _schema.json  <feature>.json
openapi/
└── api.yaml  README.md  examples/
```

## Configuration

Set at install time (`/plugin` → business-wiki → configure), all optional:

| Option | Default | Meaning |
| --- | --- | --- |
| `wiki_root` | `business-wiki` | Where the wiki lives. |
| `rules_root` | `business-rules` | Where the derived rules live. |
| `openapi_path` | `openapi/api.yaml` | Derived spec. Empty ⇒ the project has no HTTP surface and OpenAPI steps are skipped. |
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
| Derive rules | `business-wiki/features/<x>/` changed | `business-rules-keeper` regenerates `<x>.json`; a rule found only in code becomes a proposed **wiki** edit |
| Derive OpenAPI | `features/<x>/api.md` or the code contract changed | `openapi-keeper` regenerates that fragment |
| Detect drift | on demand or nightly | `source-drift-watcher` compares all four and reports |
| Auto-improve | end of a track (`/business-wiki:harvest`) | spec-vs-code deltas, decisions without an ADR, divergences, and rules cited in code but undocumented all become proposed wiki edits |
