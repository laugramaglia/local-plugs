---
feature: FEATURE_SLUG
page: index
status: stub
source_of_truth: wiki
code_refs:
  - PATH/TO/PRIMARY/CODE
updated: YYYY-MM-DD
---

# FEATURE_NAME

One paragraph: what this feature is for, from the user's point of view, and where it starts and ends.

## At a glance

| | |
| --- | --- |
| Entry points | how a user gets here |
| Owns | the rules this feature is authoritative for |
| Does not own | rules that live in a neighbouring feature, with a `[[link]]` |
| Status | shipped / partial / stub |

## Pages

- [[FEATURE_SLUG-flow]] — the happy path
- [[FEATURE_SLUG-screens]] — screens and their IDs
- [[FEATURE_SLUG-states]] — states and transitions
- [[FEATURE_SLUG-errors]] — error catalogue
- [[FEATURE_SLUG-copy]] — user-visible strings with business weight
- [[FEATURE_SLUG-validations]] — client-side validation
- [[FEATURE_SLUG-api]] — the endpoints this feature touches
- [[FEATURE_SLUG-decisions]] — the ADRs that apply
- [[FEATURE_SLUG-related]] — neighbours and shared components

## Rules

Indexed machine-readable form: `business-rules/FEATURE_SLUG.json`.

| id | Rule | Value | Where |
| --- | --- | --- | --- |
| `rule-id` | One sentence. | `literal` | `path/to/file.ext` |

## Not real yet

Anything in this feature that is a stub, a no-op, hard-coded placeholder data, or planned-but-absent. Be explicit — the next reader will otherwise assume it works.
