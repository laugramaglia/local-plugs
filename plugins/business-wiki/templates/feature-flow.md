---
feature: FEATURE_SLUG
page: flow
status: stub
source_of_truth: wiki
code_refs:
  - PATH/TO/CODE
updated: YYYY-MM-DD
---

# FEATURE_NAME — flow

## Happy path

1. Step, in the user's terms. What the system does, and the rule that governs it.
2. …

## Preconditions

What must be true before this flow can start.

## Postconditions

What is true afterwards, including what was persisted and what was discarded.

## Branches

| Branch | When | Outcome |
| --- | --- | --- |

## Timing and automatic behaviour

Anything that happens without user input: timers, auto-advance, debounces, retries, force-submits. Quote the interval and its source constant — these are the rules most often mis-remembered.

## What is deliberately not here

Behaviour a reader might expect that this flow does not do, with the ADR or divergence that explains why.
