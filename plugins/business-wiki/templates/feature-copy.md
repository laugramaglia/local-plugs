---
feature: FEATURE_SLUG
page: copy
status: stub
source_of_truth: wiki
code_refs:
  - PATH/TO/STRINGS
updated: YYYY-MM-DD
---

# FEATURE_NAME — copy

User-visible strings with business weight: anything that states a rule, a number, a promise, or a verdict. Decorative labels do not need an entry.

| Key | Source text | Placeholders | Where it appears |
| --- | --- | --- | --- |

## Copy that asserts a rule

Strings that make a factual claim to the user ("10 questions", "2:00 on the clock", "single choice"). For each, say whether the claim is **enforced** by code or is merely **copy** — a hard-coded promise the payload can contradict is a divergence, not a translation issue.

## Not localized

Hard-coded strings that bypass the localization system, with their locations. Each is a real defect for non-default locales.

## Unused keys

Defined strings nothing renders. Either wire them or delete them; leaving them implies a behaviour that does not exist.
