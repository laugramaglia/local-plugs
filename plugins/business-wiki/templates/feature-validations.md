---
feature: FEATURE_SLUG
page: validations
status: stub
source_of_truth: wiki
code_refs:
  - PATH/TO/CODE
updated: YYYY-MM-DD
---

# FEATURE_NAME — validations

| Input | Rule | Enforced where | Message on failure |
| --- | --- | --- | --- |

## Client vs server

Which side enforces each rule. A rule enforced on only one side is a finding: client-only is bypassable, server-only means the user learns about it late.

| Rule | Client | Server |
| --- | --- | --- |

## Not validated

Inputs that reach the system unchecked, including anything typed as an opaque/unknown value at a trust boundary. State it plainly; this is where the next security review will start.
