---
name: check
description: Run the business-wiki diagnostic — every validator, each finding with what fixes it and who owns it — and report the verdict.
---

# Check the wiki

Run the diagnostic from the project root:

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/wiki-doctor.sh"
```

It runs every validator, dedupes findings that two of them report as one fact, and prints each with the fix and the owner, worst first. Report every finding — do not stop at the first one.

Add `--fix` only when the user asked you to repair: it rebuilds the derived index and touches nothing authored.

To isolate one validator:

```sh
sh "${CLAUDE_PLUGIN_ROOT}/scripts/wiki-health.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-wiki.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/wiki-index.sh" --check
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-rules.sh"
sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-openapi.sh"
```

If `wiki-health.sh` fails, the system is not installed here — say so and point at `/business-wiki:bootstrap` instead of reporting a wall of downstream errors.

## Reporting

Group by validator, quote each failure with its `file:line`, and for each say what would fix it and who owns it:

| Failure | Fix | Owner |
| --- | --- | --- |
| missing/invalid frontmatter, missing section, broken `[[link]]`, dead relative Markdown link, dead `code_refs` path, dangling `ADR-NNNN` | edit the page | `wiki-keeper` |
| link name claimed by two pages | rename one of them | `wiki-keeper` |
| `business-docs/index.tsv` missing or out of date | `sh wiki-index.sh --write` | anyone — it is derived |
| rules JSON out of step with the wiki, schema violation | re-derive | `business-rules-keeper` |
| undocumented route, spec/code shape mismatch | re-derive | `openapi-keeper` |

A dead `code_refs` path usually means the code moved, not that the rule died — check `git log --diff-filter=D` before proposing to delete a page.

Offer to fix what you found, but do not fix it in this skill without being asked; `check` is a read of the system's health.

End with the doctor's own verdict line, verbatim.
