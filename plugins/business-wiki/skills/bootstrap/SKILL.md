---
name: bootstrap
description: The one entry point for the business wiki — init, update, or repair. Detects what already exists: scaffolds business-docs/ on a first run, adds what is missing on an existing wiki, and fixes what the validators flag. Run it after installing the plugin, after upgrading it, and any time the wiki has fallen behind.
---

# Bootstrap the business wiki

The single entry point for this system in a repository: **init, update, and repair are one command**. You work out which of the three applies from what is on disk, and you say which one you are doing before you do it.

Stack-agnostic: what you find in the repo decides the shape, not any assumption about the framework.

Config (fall back to the defaults when unset): `${CLAUDE_PLUGIN_OPTION_WIKI_ROOT}` → `business-docs/wiki`, `${CLAUDE_PLUGIN_OPTION_RULES_ROOT}` → `business-docs/rules`, `${CLAUDE_PLUGIN_OPTION_OPENAPI_PATH}` → `business-docs/openapi/api.yaml`, `${CLAUDE_PLUGIN_OPTION_CONTRACT_SOURCE}`.

Templates: `${CLAUDE_PLUGIN_ROOT}/templates/`. Read each one before writing from it.

## 0. Work out which run this is

Always start here. One command, before anything else:

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/wiki-doctor.sh"
```

It runs every validator, dedupes the findings, and prints for each one **what fixes it and who owns it**, ending in a verdict line. That verdict is what tells you which run this is:

- `setup FAILED` / "not set up" → **init**.
- errors or warnings, with a wiki that is set up → **update and repair**.
- `0 error(s), 0 warning(s)` and nothing missing → there is nothing to do; say so and stop rather than manufacturing work.

Then route on what you find:

| On disk | Mode | What you do |
| --- | --- | --- |
| No wiki root, or a wiki root with no `features/*/index.md` | **init** | Everything below, steps 1–7. |
| A wiki with authored features, and something missing or behind | **update** | Steps 1–3 and 6–7, **additively**. Skip step 4 except for genuinely new features. |
| A wiki with authored features, and validators failing | **repair** | Step 7 first, then only what the doctor flagged. |

Update and repair usually apply together — a wiki that has fallen behind is normally also a wiki with a broken link or two. Do both in one run.

**Say which mode you are in, and why, before you touch a file.** "Update: 6 features authored, `index.tsv` missing, 2 routes in code with no feature page" is the sentence the user needs to decide whether to let you continue.

### The rule that makes re-running safe

**Never overwrite authored prose.** A page with `status: authored` is a human-reviewed artifact; in update and repair mode you may only:

- **create** what does not exist (a missing `shared/` page, a new feature's page set, a missing scaffold file);
- **regenerate** what is derived (`index.tsv`, `rules/*.json`, the OpenAPI document);
- **propose** a change to authored prose by handing it to `business-wiki:wiki-keeper`, which writes a diff for the human.

If you are about to rewrite a page you did not just create, you are in the wrong mode. Stop and hand it to the keeper.

### What "update" usually means in practice

- The plugin was upgraded and added something the repo does not have yet — most often `<group root>/index.tsv`, which did not exist before 0.2.0. `sh wiki-index.sh --write` is the whole fix.
- The code grew a feature the wiki has never heard of. That is a real new page set: step 4 for that feature only.
- A `shared/` concern became real (the project grew auth, or i18n) and has no page.
- The derived formats are behind the wiki. That is step 6.

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
<group root>/README.md                    the authority story, from templates/docs-readme.md
<wiki root>/README.md                     the wiki's own index, from templates/wiki-readme.md
<wiki root>/decisions/                    (empty; ADRs come in step 5)
<wiki root>/features/<feature>/           the 10-page set per feature
<wiki root>/shared/                       glossary.md, data-types.md, error-codes.md,
                                          divergences.md, a11y.md, + any cross-cutting
                                          concern this project actually has
                                          (i18n, offline, theming, security, performance)
<wiki root>/shared/templates/             copies of the plugin templates, for humans
<group root>/index.tsv                     derived: the page index and link graph
<rules root>/README.md  <rules root>/_schema.json
<openapi path>          <openapi dir>/README.md  (skip entirely if openapi_path is empty)
```

`<group root>` is the deepest directory that contains the wiki, rules, and OpenAPI paths — `business-docs` with the defaults. When the three are configured into unrelated trees there is no group root: skip that README and fold the authority story into `<wiki root>/README.md` instead.

Only create `shared/` pages for concerns this project has. An empty `security.md` in a project with no auth is noise.

## 4. Author the features

*Init: every feature. Update: only the ones that have no page set yet — an existing feature that has drifted is `/business-wiki:feature` or `/business-wiki:harvest`, not this.*

Hand each feature to `business-wiki:wiki-keeper`, one at a time, giving it the paths you found in step 1. It authors the page set with every claim traced to code. Do not author the pages yourself in this skill — the keeper owns prose so the standard stays uniform.

Author the highest-value feature first (the one that owns money, scoring, or correctness) so the user sees the format on real content early.

## 5. Migrate existing decisions into ADRs

*Init only, plus any decision document that appeared since the last run.*

Every decision already recorded in a plan/README/TODO becomes an ADR under `decisions/`, quoting the original wording and citing the source document. Also write the meta-ADR that records this system itself: the wiki is the source, the other two formats are derived, divergences resolve in the wiki's favour.

Leave the original documents in place. Deleting them is the user's call, not a side effect of bootstrap.

## 6. Derive

Run `business-wiki:business-rules-keeper` for every authored feature, then `business-wiki:openapi-keeper` if there is an HTTP surface.

## 7. Verify and report

*Every mode, and in repair mode this comes first.*

Diagnose, and let it repair what a script is allowed to repair:

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/wiki-doctor.sh" --fix
```

`--fix` rebuilds the derived index and nothing else. That split is deliberate: a stale index is a fact about a generated file and a script can settle it, while a broken link is a question about what the author meant — a script that guesses there produces a wiki that validates and lies.

Then work the remaining findings **in the order the doctor prints them**, errors first. Each carries its own fix and owner. Respect the rule in step 0: a failure inside authored prose is a proposal for `wiki-keeper`, not an edit you make here.

Re-run `wiki-doctor.sh` until it is clean or until what is left is deliberate, and quote the final verdict line in your report.

The individual validators are still there when you want one in isolation:

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-wiki.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/wiki-index.sh" --check
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-rules.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-openapi.sh"
``` Commit `<group root>/index.tsv` along with the wiki: it is derived, like the rules JSON, and it belongs in the review.

Nothing rebuilds the index outside a Claude session, so this step is also the answer to "the wiki changed under me": a `git pull`, a page edited in an editor, a fresh plugin upgrade. Running `/business-wiki:bootstrap` is always safe and is the intended way to catch up.

Report, and lead with the mode:

- **init** — the feature list, how many rules landed, the ADRs written, the divergences found (these are the payoff — list them explicitly), and what you deliberately left as `stub`.
- **update** — what you created, what you regenerated, and what you deliberately did not touch.
- **repair** — each failure, whether you fixed it or handed it to a keeper, and what is still red.
