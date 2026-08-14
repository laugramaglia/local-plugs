---
name: check
description: Run the business-wiki validators and report failures with file and line.
---

# Check the wiki

Run all four validators from the project root, in this order, and report every failure — do not stop at the first one:

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/wiki-health.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-wiki.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-rules.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-openapi.sh"
```

If `wiki-health.sh` fails, the system is not installed here — say so and point at `/business-wiki:bootstrap` instead of reporting a wall of downstream errors.

## Reporting

Group by validator, quote each failure with its `file:line`, and for each say what would fix it and who owns it:

| Failure | Fix | Owner |
| --- | --- | --- |
| missing/invalid frontmatter, missing section, broken `[[link]]`, dead `code_refs` path, dangling `ADR-NNNN` | edit the page | `wiki-keeper` |
| rules JSON out of step with the wiki, schema violation | re-derive | `business-rules-keeper` |
| undocumented route, spec/code shape mismatch | re-derive | `openapi-keeper` |

A dead `code_refs` path usually means the code moved, not that the rule died — check `git log --diff-filter=D` before proposing to delete a page.

Offer to fix what you found, but do not fix it in this skill without being asked; `check` is a read of the system's health.

End with a one-line verdict: pass, or N failures across which validators.
