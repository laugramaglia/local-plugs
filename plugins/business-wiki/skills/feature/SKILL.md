---
name: feature
description: Create or refresh one feature's wiki page set, then regenerate its derived rules. Pass the feature slug.
argument-hint: <feature-slug>
---

# Author or refresh a feature

Target feature: `$ARGUMENTS` (if empty, list the features under `<wiki root>/features/` plus any feature you can see in the code that has no wiki entry, and ask which one).

Config: `${CLAUDE_PLUGIN_OPTION_WIKI_ROOT}` → `business-wiki`, `${CLAUDE_PLUGIN_OPTION_RULES_ROOT}` → `business-rules`. Templates at `${CLAUDE_PLUGIN_ROOT}/templates/`.

## Steps

1. **Locate the feature in code** before reading its wiki pages, so you form the picture from the source rather than from what the wiki claims. Routes/screens, state holder, server handlers, persistence, tests.

2. **Delegate the authoring** to `business-wiki:wiki-keeper`, telling it:
   - the feature slug and whether this is a new page set or a refresh
   - every code path you found, grouped by layer
   - for a refresh: what changed since the page's `updated` date (`git log --oneline --since` on the `code_refs`)

3. **Review the keeper's diff yourself** before showing the user. Check the three failure modes that matter:
   - a rule stated without a `file:line` you can verify
   - a threshold or default quoted from prose rather than from the code
   - a `[[link]]` to a page written in the same pass but not actually created

4. **Derive.** `business-wiki:business-rules-keeper` for this feature; `business-wiki:openapi-keeper` if the feature touches an endpoint.

5. **Check.** `sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-wiki.sh"` and `check-rules.sh`.

6. **Report** the rules added or changed by id, any new divergence, and anything left `stub` with the reason.

If the work surfaced a decision that closed off a real alternative, say so and offer `/business-wiki:adr` — do not bury a decision inside a feature page.
