# PROJECT_NAME business wiki

**This wiki is the source of truth for business rules.** When it disagrees with anything else, the wiki is right and the other format gets regenerated.

## The three formats

| Format | Written by | Read when | Authority |
| --- | --- | --- | --- |
| `business-wiki/` | AI, human-reviewed | by default, by humans and agents alike | **source** |
| `business-rules/<feature>.json` | derived | an agent needs a rule by key, or a closed enum | derived |
| `openapi/api.yaml` | derived | an agent is about to touch an endpoint — it reads that one path, not the whole spec | derived |

Decisions, divergences, and prose live **only** here and are never duplicated into the derived formats.

## Layout

```
README.md          this file
decisions/         ADRs — NNNN-slug.md, citable from code as ADR-NNNN
features/<x>/      index, flow, screens, states, errors, copy, validations,
                   api, rules.json, decisions, related
shared/            glossary, data types, error codes, divergences, and the
                   cross-cutting concerns this project actually has
shared/templates/  the page templates, for humans
```

## Features

| Feature | Owns | Status |
| --- | --- | --- |

## Start here

- New to the project? [[glossary]], then the feature you are about to change.
- About to change a rule? Find it in the feature's pages, change it **here** first, then `/business-wiki:derive`.
- Something looks wrong? [[divergences]] — it may already be a known, accepted contradiction.

## How this is maintained

The AI authors; the human approves the diff and points at gaps.

| Loop | Trigger | Effect |
| --- | --- | --- |
| Author / refresh a feature | code changed, or a gap was found | `/business-wiki:feature <slug>` |
| Record a decision | a choice closed off an alternative | `/business-wiki:adr` |
| Derive | wiki changed | `/business-wiki:derive` |
| Detect drift | before a release, or nightly | `business-wiki:source-drift-watcher` |
| Harvest | end of a track | `/business-wiki:harvest` |
| Validate | every edit (hook) + CI | `/business-wiki:check` |

Rules for contributors, human or agent:

1. Every claim carries a `file:line`. If it cannot be traced, mark it unverified or leave the page `stub`.
2. Never hand-edit a derived file. Change the wiki and re-derive.
3. A rule found in code but not here is a **wiki** gap — fix it here, not in the JSON.
4. Document what is *not* real: stubs, no-ops, placeholder data, planned endpoints.
5. Record contradictions in [[divergences]] rather than quietly picking a side.
