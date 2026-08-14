---
feature: FEATURE_SLUG
page: states
status: stub
source_of_truth: wiki
code_refs:
  - PATH/TO/STATE
updated: YYYY-MM-DD
---

# FEATURE_NAME — states

## State shape

The fields that make up this feature's state, and what each one means. Include derived values and the expression that derives them — a derived getter is a rule.

| Field | Type | Meaning | Default |
| --- | --- | --- | --- |

## Transitions

| From | Event | To | Guard |
| --- | --- | --- | --- |

## Resolution order

Where a status is resolved by an if/else chain, write the order explicitly and note what each fallback means. `?? false` is a business rule: say which outcome a missing value produces.

## Lifetime

What holds this state, when it is created, when it is disposed, and anything that deliberately outlives it (keep-alive snapshots, caches). Note which screens depend on that survival.
