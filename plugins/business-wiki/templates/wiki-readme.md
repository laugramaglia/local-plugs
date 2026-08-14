# PROJECT_NAME wiki

The source of truth for this project's business rules. How this relates to the derived formats, and how the whole thing is maintained, is one level up: [`../README.md`](../README.md).

## Layout

```
README.md          this file
decisions/         ADRs — NNNN-slug.md, citable from code as ADR-NNNN
features/<x>/      index, flow, screens, states, errors, copy, validations,
                   api, decisions, related
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
- Need a rule by key instead of by page? `../rules/<feature>.json`, regenerated from these pages.

## What belongs here

Every claim carries a `file:line`. A rule that cannot be traced to code, a migration, a test, or an explicit human decision is marked unverified or left `stub` — never smoothed over with plausible prose. Documenting an absence (a stub, a no-op, a planned-but-absent endpoint) is as valuable as documenting a behaviour.
