---
feature: FEATURE_SLUG
page: errors
status: stub
source_of_truth: wiki
code_refs:
  - PATH/TO/CODE
updated: YYYY-MM-DD
---

# FEATURE_NAME — errors

Shared catalogue: [[error-codes]].

| Condition | Code / exception | What the user sees | Recovery |
| --- | --- | --- | --- |

## Silent failures

Every path where an error is caught and **not** surfaced — swallowed exceptions, empty catch blocks, fallbacks that degrade without telling the user. Each row is a deliberate or accidental product decision; name which. These belong in `[[divergences]]` when accidental.

| Where | What is swallowed | What the user experiences instead |
| --- | --- | --- |

## Retries

What is retried, how many times, with what delay, and what is deliberately **not** retried.
