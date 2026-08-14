---
feature: FEATURE_SLUG
page: screens
status: stub
source_of_truth: wiki
code_refs:
  - PATH/TO/VIEW
updated: YYYY-MM-DD
---

# FEATURE_NAME — screens

| Screen ID | Route | Implementation | Notes |
| --- | --- | --- | --- |
| `screen_id` | `/route` | `path/to/view.ext` | pushed / replaced / tab |

## Navigation contract

How each screen is entered and left — pushed, replaced, popped — and the condition that triggers each transition. Name the code that performs it. A screen reached by `pushReplacement` cannot be returned to; say so where it matters.

## Composition

If the screens are assembled from server-driven or configured blocks, list the blocks in render order with the config keys each one reads.
