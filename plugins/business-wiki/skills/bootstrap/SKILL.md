---
name: bootstrap
description: First run of the business wiki in a repo. Detects the stack, proposes the feature list from the real routes/screens/endpoints, and scaffolds business-wiki/ plus the derived formats.
---

# Bootstrap the business wiki

Set up the wiki-as-source-of-truth system in this repository. Stack-agnostic: what you find in the repo decides the shape, not any assumption about the framework.

Config (fall back to the defaults when unset): `${CLAUDE_PLUGIN_OPTION_WIKI_ROOT}` → `business-wiki`, `${CLAUDE_PLUGIN_OPTION_RULES_ROOT}` → `business-rules`, `${CLAUDE_PLUGIN_OPTION_OPENAPI_PATH}` → `openapi/api.yaml`, `${CLAUDE_PLUGIN_OPTION_CONTRACT_SOURCE}`.

Templates: `${CLAUDE_PLUGIN_ROOT}/templates/`. Read each one before writing from it.

## 0. Refuse to overwrite

If the wiki root already exists and has any `features/*/index.md`, stop and tell the user to use `/business-wiki:feature` instead. Bootstrap is a first run, not a reset.

## 1. Detect the stack

Look, don't assume. Manifests (`pubspec.yaml`, `package.json`, `go.mod`, `Cargo.toml`, `requirements.txt`, `*.csproj`, `Gemfile`), then the shape of the source tree. Determine:

- **The client surface**, if any: what defines a screen or a route, and where state lives (view models, stores, reducers, controllers).
- **The server surface**, if any: the router or route table, the handlers, and where the wire contract is declared. This becomes `contract_source` if it is not already configured.
- **The data layer**: migrations, schema files, ORM models. Migration comments and constraints are dense with business rules — read them.
- **The tests**: they are the executable spec.
- **Existing docs**: READMEs, plans, TODOs, ADRs, design prompts. These hold decisions that must move into `decisions/`, and they are where doc-vs-code contradictions hide.

## 2. Propose the feature list

A feature is a unit a **product** person would name — not a code layer. Derive candidates from routes/screens, then from server endpoints and content models for things with no screen (grading, content authoring, taxonomy).

Rules for the list:

- Split a flow into separate features when its pages have genuinely different rules (play vs results vs review), keep them together when they do not.
- Include features that exist only as placeholders, marked `status: stub`. Documenting an absence is the point.
- Include backend-only concerns as their own features when they own rules (the thing that computes the score is a feature).

Show the user the proposed list with a one-line justification each, and let them correct it before you write anything.

## 3. Scaffold

Create, from the templates:

```
<wiki root>/README.md                     index, maintenance rules, how the 3 formats relate
<wiki root>/decisions/                    (empty; ADRs come in step 5)
<wiki root>/features/<feature>/           the 11-file page set per feature
<wiki root>/shared/                       glossary.md, data-types.md, error-codes.md,
                                          divergences.md, a11y.md, + any cross-cutting
                                          concern this project actually has
                                          (i18n, offline, theming, security, performance)
<wiki root>/shared/templates/             copies of the plugin templates, for humans
<rules root>/README.md  <rules root>/_schema.json
<openapi path>          openapi/README.md  (skip entirely if openapi_path is empty)
```

Only create `shared/` pages for concerns this project has. An empty `security.md` in a project with no auth is noise.

## 4. Author the features

Hand each feature to `business-wiki:wiki-keeper`, one at a time, giving it the paths you found in step 1. It authors the page set with every claim traced to code. Do not author the pages yourself in this skill — the keeper owns prose so the standard stays uniform.

Author the highest-value feature first (the one that owns money, scoring, or correctness) so the user sees the format on real content early.

## 5. Migrate existing decisions into ADRs

Every decision already recorded in a plan/README/TODO becomes an ADR under `decisions/`, quoting the original wording and citing the source document. Also write the meta-ADR that records this system itself: the wiki is the source, the other two formats are derived, divergences resolve in the wiki's favour.

Leave the original documents in place. Deleting them is the user's call, not a side effect of bootstrap.

## 6. Derive

Run `business-wiki:business-rules-keeper` for every authored feature, then `business-wiki:openapi-keeper` if there is an HTTP surface.

## 7. Verify and report

Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/wiki-health.sh"` then `check-wiki.sh`, `check-rules.sh`, `check-openapi.sh`. Fix what they flag.

Report: the feature list, how many rules landed, the ADRs written, the divergences found (these are the payoff — list them explicitly), and what you deliberately left as `stub`.
