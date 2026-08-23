# PROJECT_NAME business docs

Three formats, one direction of authority. **`wiki/` is the source of truth for business rules.** When it disagrees with anything in `rules/` or `openapi/`, the wiki is right and the other format gets regenerated.

| Format | Written by | Read when | Authority |
| --- | --- | --- | --- |
| [`wiki/`](wiki/README.md) | AI, human-reviewed | by default, by humans and agents alike | **source** |
| `rules/<feature>.json` | derived | an agent needs a rule by key, or a closed enum | derived |
| `openapi/api.yaml` | derived | an agent is about to touch an endpoint — it reads that one path, not the whole spec | derived |
| `index.tsv` | derived | an agent is looking for a page, a section, or what links to one | derived |

It is not "JSON first, then wiki". It is **wiki by default; OpenAPI and JSON when you need precision.**

Decisions, divergences, and prose live **only** in the wiki and are never duplicated into the derived formats — a rule that exists only in a derived file is invisible to humans and unowned.

## Layout

```
README.md    this file — the authority story
wiki/        the source: features, decisions (ADRs), shared concerns
rules/       derived: one <feature>.json per feature, plus _schema.json
openapi/     derived: api.yaml, examples/
```

## How this is maintained

The AI authors; the human approves the diff and points at gaps.

| Loop | Trigger | Effect |
| --- | --- | --- |
| Author / refresh a feature | code changed, or a gap was found | `/business-wiki:feature <slug>` |
| Record a decision | a choice closed off an alternative | `/business-wiki:adr` |
| Derive | the wiki changed | `/business-wiki:derive` |
| Detect drift | before a release, or nightly | `business-wiki:source-drift-watcher` |
| Harvest | end of a track | `/business-wiki:harvest` |
| Validate | every edit (hook) + CI | `/business-wiki:check` |

Rules for contributors, human or agent:

1. Every claim carries a `file:line`. If it cannot be traced, mark it unverified or leave the page `stub`.
2. Never hand-edit a file under `rules/` or `openapi/`. Change the wiki and re-derive.
3. A rule found in code but not in the wiki is a **wiki** gap — fix it there, not in the JSON.
4. Document what is *not* real: stubs, no-ops, placeholder data, planned endpoints.
5. Record contradictions in `wiki/shared/divergences.md` rather than quietly picking a side.
