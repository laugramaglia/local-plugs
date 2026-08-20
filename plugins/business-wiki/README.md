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

`/business-wiki:bootstrap` is the **only** command you need for setup, and it is safe to re-run. It looks at what is on disk and picks a mode:

| On disk | Mode | What it does |
| --- | --- | --- |
| No wiki | **init** | Detects the stack, proposes the feature list from the real routes and screens, scaffolds the tree, hands each feature to `wiki-keeper`. |
| A wiki, missing something | **update** | Creates only what is absent and regenerates what is derived. Authored prose is never overwritten — a change to it becomes a `wiki-keeper` diff. |
| A wiki, validators failing | **repair** | Runs the validators first, then fixes what it flagged. |

So: run it after installing, run it after upgrading the plugin, and run it any time the wiki has fallen behind — after a `git pull`, or after someone edited a page in an editor. There is no separate migration step.

## Commands

| Command | Use it when |
| --- | --- |
| `/business-wiki:bootstrap` | **Init, update, or repair — always this one.** Detects what already exists and does the right thing. |
| `/business-wiki:feature <name>` | Author or refresh one feature's page set. |
| `/business-wiki:adr <title>` | Record a decision as the next-numbered ADR and link it from the features it affects. |
| `/business-wiki:derive [feature]` | Regenerate the rules JSON and the OpenAPI fragments from the wiki. |
| `/business-wiki:check` | Run the validators. |
| `/business-wiki:navigate` | Find and read the right part of the wiki without loading whole pages. |
| `/business-wiki:harvest` | End of a track: what did we learn that belongs in the wiki? |

## Agents

| Agent | Role |
| --- | --- |
| `business-wiki:wiki-keeper` | Authors and maintains the wiki. The only agent that writes prose. |
| `business-wiki:business-rules-keeper` | Derives `business-docs/rules/<feature>.json`; opens the **inverse** change when code has a rule the wiki lacks. |
| `business-wiki:openapi-keeper` | Derives the OpenAPI document from the wiki's `api.md` plus the real code contract. |
| `business-wiki:source-drift-watcher` | Read-only four-way compare: wiki ↔ rules ↔ OpenAPI ↔ code. Reports; never fixes. |

## Structure it creates

One root. The split inside it is the authority boundary: `wiki/` is authored and reviewed; `index.tsv`, `rules/`, and `openapi/` are machine output, regenerated from the wiki and never hand-edited.

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
│   ├── shared/                   glossary, data types, error codes, divergences, a11y…
│   └── shared/templates/         copies of the page templates, for humans
├── index.tsv                     ← derived: page index + link graph
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
| `index_path` | `business-docs/index.tsv` | Derived page index and link graph. |
| `strict_check` | `false` | `true` makes validator warnings fatal. |

## Validators

POSIX `sh`, no runtime dependencies. Run them from the project root.

### One diagnostic

```bash
sh "$PLUGIN/scripts/wiki-doctor.sh"          # diagnose everything
sh "$PLUGIN/scripts/wiki-doctor.sh" --fix    # ...and repair what a script may repair
sh "$PLUGIN/scripts/wiki-doctor.sh" --quiet  # the verdict line only
```

It runs every validator, dedupes findings that two of them report as one fact (a dangling
link is both a page-level and a graph-level failure), then **groups by category** with the
fix and the owner per category, and lists every error plus three examples per warning
category:

```
  setup      ok
  wiki       ok (131 warning(s))
  index      ok
  openapi    1 error(s), 1 warning(s)
  graph      2 page(s) with no backlinks, 130 unlinked mention(s)

BY CATEGORY
  error    1  spec-behind-code     owner: openapi-keeper
        fix: /business-wiki:derive — the spec is behind the code or the wiki
  warn   127  code-moved-since     owner: wiki-keeper
        fix: re-verify the page against the code, then bump updated:
  warn    14  provenance           owner: business-rules-keeper / openapi-keeper
        fix: /business-wiki:derive

FINDINGS
  [error/openapi] worker/src exposes 'userId' but api.yaml does not document it

  code-moved-since — 127
  [warn/wiki] .../attempts-grading/api.md:6 worker/src/routes/attempts.ts changed on 2026-08-19, ...
  ... 124 more in this category

doctor: 1 error(s), 149 warning(s)
```

The grouping is not cosmetic. That run is a real 137-page wiki mid-track: 127 of its 150
findings are one category, and *"the code moved under 127 pages"* is **one** task, not 127
things to read. The flat list buried that. Per-category caps always announce what they held
back — a silent cap reads as "that is all there is".

`--fix` rebuilds the derived index and **nothing else**, and a test enforces that. The split
is the point: a stale index is a fact about a generated file and a script can settle it,
while a broken link is a question about what the author meant — a script that guesses there
produces a wiki that validates and lies. `/business-wiki:bootstrap` and
`/business-wiki:check` both run through it.

### The individual validators

```bash
sh "$PLUGIN/scripts/wiki-health.sh"     # is the system installed at all?
sh "$PLUGIN/scripts/check-wiki.sh"      # frontmatter, sections, [[links]], code_refs, ADR refs
sh "$PLUGIN/scripts/wiki-index.sh" --check   # name collisions, dangling links, index freshness
sh "$PLUGIN/scripts/check-rules.sh"     # rules JSON shape + wiki cross-reference
sh "$PLUGIN/scripts/check-openapi.sh"   # spec parses; every real route documented
bash test/run-tests.sh                  # 192 assertions, offline, no writes outside a sandbox
bash test/run-tests.sh provenance       # only matching groups
```

A `PostToolUse` hook runs `check-wiki.sh --changed` and `wiki-index.sh --changed` after any Write/Edit, so a broken link is caught the moment it is written and the index stays current while you work. Both exit silently for files outside the wiki and in a repo that has never installed the plugin, and the index is only rewritten when the graph actually changed, so an unrelated edit does not show up in the diff.

Everything else is manual on purpose. A wiki edited outside a Claude session — a `git pull`, a page fixed in an editor, a fresh upgrade of this plugin — leaves the index behind, and nothing repairs it behind your back:

```bash
sh "$PLUGIN/scripts/wiki-index.sh" --check   # says whether it is stale, and names the fix
sh "$PLUGIN/scripts/wiki-index.sh" --write   # rebuild it
```

`/business-wiki:check` runs the first of those, so the staleness surfaces wherever you were already looking.

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

### A route is a path, not any `.get`

`check-openapi.sh` finds the routes a codebase exposes by matching
`.get('/x')` / `.post("/x")` and friends. The argument has to start with `/`, because `.get`
is also how frameworks *read* a value — Hono's `c.get('userId')`, a `URLSearchParams.get('page')`,
a `Map`. Without that constraint the validator reported a real Worker as exposing an
undocumented endpoint called `userId`, and the only way to satisfy that finding would have
been to document an endpoint that does not exist. A validator that can be silenced by
writing something false is worse than no validator.

### What the validators do NOT check

They check that the output is **well-formed and internally consistent** — the YAML parses, referenced paths resolve, ids line up. None of them compares a documented rule against what the code actually does.

That distinction is not academic: `check-rules.sh` and `check-openapi.sh` both **passed** on a repo whose OpenAPI still described a response shape an accepted ADR had already replaced. Agreement with code is `source-drift-watcher`'s job, it is semantic, and `/business-wiki:derive` now runs it **as a gate before regenerating anything** — a `high` finding not already recorded in `shared/divergences.md` stops the derive. Deriving from a wiki the code contradicts launders the contradiction into a machine-readable artifact that everything downstream then trusts.

## Navigation: the index and the four tools

A wiki is not a pile of documents. It is already structured — typed pages, YAML
frontmatter, `[[wikilinks]]` — and the cheapest retrieval is the one that uses that
structure instead of rediscovering it.

`business-docs/index.tsv` is derived from the wiki, one row per page:

```
link_name  path  kind  feature  page  status  updated  title  aliases  links_out
```

`link_name` is what a `[[link]]` resolves to (`features/<f>/<page>.md` → `<f>-<page>`,
`shared/<x>.md` → `<x>`, `decisions/NNNN-slug.md` → `NNNN-slug`). `aliases` are the other
names a page answers to: a feature's `index.md` answers to the bare feature slug, an ADR
to its `ADR-NNNN` citation. It is a TSV so it diffs one line per page in review.

On top of it, four read-only tools:

```bash
sh "$PLUGIN/scripts/wiki-search.sh" <query> [--feature f] [--page p] [--status s] [--kind k]
sh "$PLUGIN/scripts/wiki-outline.sh" <page>            # frontmatter, headings, links, backlinks
sh "$PLUGIN/scripts/wiki-section.sh" <page> <heading>  # only that section
sh "$PLUGIN/scripts/wiki-index.sh" --backlinks <name>  # what depends on this page
sh "$PLUGIN/scripts/wiki-index.sh" --synonyms <term>   # the other names for one concept
sh "$PLUGIN/scripts/wiki-index.sh" --mentions          # edges the prose implies but never drew
```

`<page>` takes a path, a link name, or an alias. `wiki-search.sh` resolves an exact name,
alias, or title deterministically and reports it *above* the body matches — a query that
is a term rather than a phrase never needs ranking at all. The body pass uses `ripgrep`
when it is installed and `grep` otherwise, over exactly the files the filters allow.

**Backlinks are the point.** Before changing a rule, `--backlinks` says which pages state
or rely on it. That is the question a text search structurally cannot answer, and skipping
it is how a wiki starts contradicting itself.

### The graph is what is written, not only what is bracketed

Three things are edges, because all three are authored:

- `[[wikilinks]]`;
- **relative Markdown links** — the feature `decisions.md` pages cite ADRs as
  `[ADR-0007](../../decisions/0007-slug.md)`, and a wikilink-only parser cannot see them;
- an ADR's **`affects:` frontmatter**, which names the features the decision binds.

Measured on a real 137-page wiki: reading all three took the graph from **656 to 1,076
edges (+64%)** and pages with no backlinks at all from **45 to 2**. All 44 of that wiki's
ADRs were graph orphans — `--backlinks` on a decision returned nothing — while 210
Markdown links and 148 `affects:` entries already encoded exactly those edges.

Edges are stored under a page's **canonical** name, so `[[quiz]]`, `affects: quiz`, and
`[[quiz-index]]` are one edge and `--backlinks quiz-index` finds all three.

Dead relative links are `check-wiki.sh`'s business, reported with the line and the href as
written, and never enter the graph — a broken link must not invent a node. That check
found four dead ADR citations sitting in a real wiki that nothing had ever looked at.

### The glossary as a synonym table

`shared/glossary.md` exists because the client, the wire, and the database name one concept
three ways — the mismatch it documents is exactly the gap a lexical search cannot bridge.
`wiki-search.sh` reads it and expands the query, reporting that it did:

```
$ wiki-search.sh questionVersionId
glossary: "questionVersionId" is also written Question version question_version.id
```

Measured on the same wiki: `question_version.id` went from 18 matches to 48 (**2.7x**),
`questionVersionId` from 28 to 48 (**1.7x**).

Only *specific* forms are expanded to — phrases, dotted or underscored names, camelCase.
The first version also expanded to bare glossary headings, and searching `questionId` went
from 4 matches to **779**: the heading "Question" is half the prose in a quiz wiki.
`--no-synonyms` turns the whole thing off.

### Placeholders are checked outside code spans

A finished wiki documents a date format as `` `YYYY-MM-DD` ``. Treating that as an
unreplaced template placeholder was four false positives out of eight findings on a real
wiki — half the report. Code spans are excluded here for the same reason they are excluded
from link extraction: inside backticks, it is an illustration.

### `--mentions`: where the graph is thinner than the wiki

Pages that name another page in prose without linking to it — Obsidian calls these unlinked
mentions, and each is an edge the writer meant and did not draw. **130** on the real wiki,
led by `taxonomy-index` (19) and `offline` (16). `ADR-NNNN` citations in prose are a
convention of their own and are excluded unless you pass `--all`, which raises the count to
523.

### Cost

Measured on a synthetic wiki, macOS, ripgrep present:

| | 200 pages | 1000 pages |
| --- | --- | --- |
| `--backlinks` / `--section` / `--search` / `--outline` | 10–70 ms | 10–80 ms |
| **per edit** — `wiki-index --changed` | 20 ms | 30 ms |
| **per edit** — `check-wiki --changed` | 60 ms | 220 ms |
| `wiki-index --write` (full rebuild) | 0.5 s | 2.5 s |
| `check-wiki` (full validation) | 1.0 s | 5.3 s |

Reads are flat because they scan a text table; the serialisation format is
nowhere near the bottleneck at this scale. What did cost real time was **forks**:
the per-field shell helpers (`value_of` alone is three processes, called five
times a page) added up to roughly forty processes per page, which was
forty-seven seconds of full validation on a thousand-page wiki. `page_fields`
and `page_scan` in `lib-wiki.sh` replace all of them with one `awk` pass per
file, and the `git log` staleness lookup is memoised across pages, so a wiki
citing the same handful of source files pays for each one once.

The hook is flat for a different reason: it **splices a single row** rather than
rebuilding. Editing a page can only change that page's row, since backlinks are
derived from `links_out` at query time. A spliced index is byte-identical to a
full build — asserted in the test suite, because if it ever drifted, `--check`
would report the index as permanently stale.

### Why there are no embeddings here

A generated wiki of a few hundred typed pages, written and read by the same agents against
a shared glossary, is the corpus where lexical search plus the link graph is both exact and
instant. A vector index would add a model dependency, a build step, and — worst — a second
source of truth that goes stale exactly when the wiki is being edited most. Every part of
the retrieval story here is regenerated from the Markdown in one pass, by a shell script,
with no runtime dependencies. That is the property worth protecting.

## Who maintains what

The AI is the author. The human's job is to (1) approve the diff and (2) point at gaps. The loops that keep the three formats in step:

| Loop | Trigger | Effect |
| --- | --- | --- |
| Derive rules | `business-docs/wiki/features/<x>/` changed | `business-rules-keeper` regenerates `<x>.json`; a rule found only in code becomes a proposed **wiki** edit |
| Derive OpenAPI | `features/<x>/api.md` or the code contract changed | `openapi-keeper` regenerates that fragment |
| Detect drift | **before every derive**, plus nightly if you want it | `source-drift-watcher` compares all four and reports; a new `high` finding blocks the derive |
| Auto-improve | end of a track (`/business-wiki:harvest`) | spec-vs-code deltas, decisions without an ADR, divergences, and rules cited in code but undocumented all become proposed wiki edits |

`/business-wiki:harvest` also posts a `wiki-delta` note on the sdd-tdd task when that plugin is in use — `task.sh state <id> done` refuses without one, so a track can't be called finished having never looked at the wiki.
