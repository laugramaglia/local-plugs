---
name: derive
description: Regenerate the derived formats — business-rules JSON and the OpenAPI document — from the wiki, and show one combined diff.
argument-hint: [feature-slug]
---

# Derive the machine-readable formats

Scope: `$ARGUMENTS` if a feature slug is given; otherwise every feature whose wiki pages changed since the last derive (`git diff --name-only` against the last commit that touched the rules root, falling back to all features).

Config: `${CLAUDE_PLUGIN_OPTION_WIKI_ROOT}`, `${CLAUDE_PLUGIN_OPTION_RULES_ROOT}`, `${CLAUDE_PLUGIN_OPTION_OPENAPI_PATH}`, `${CLAUDE_PLUGIN_OPTION_CONTRACT_SOURCE}`.

## Steps

1. Run `business-wiki:business-rules-keeper` for each feature in scope.
2. Run `business-wiki:openapi-keeper` if `openapi_path` is set and any feature in scope has an `api.md` with endpoints, or the contract source changed.
3. Run `sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-rules.sh"` and `check-openapi.sh`.
4. Show **one** combined diff, grouped by format, then the summary.

## Direction of authority

The derived formats never gain a rule the wiki lacks. When a keeper reports an undocumented rule found in code, the fix is a **wiki** edit followed by a re-derive — surface those proposals prominently rather than folding them into the JSON. Same for a wiki rule the code contradicts: it lands as `status: documented-not-enforced` and goes into `shared/divergences.md`.

## Idempotence

A second run with no wiki change must produce **no diff**. If it does not, that is a bug in the keeper's ordering or timestamp handling, not an acceptable outcome — report it, because a format that churns on every run teaches everyone to ignore its diffs.

Report: rules added/changed/removed by id, OpenAPI paths and schemas touched, inverse-PR proposals, validator result.
