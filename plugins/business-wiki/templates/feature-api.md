---
feature: FEATURE_SLUG
page: api
status: stub
source_of_truth: wiki
code_refs:
  - PATH/TO/HANDLER
updated: YYYY-MM-DD
---

# FEATURE_NAME — API

Detailed schemas live in the OpenAPI document. This page says **which** endpoints this feature touches and **what they mean here**; it never duplicates the schemas.

| Method + path | OpenAPI tag | Handler | Called from |
| --- | --- | --- | --- |

Spec: [`openapi/api.yaml`](../../../openapi/api.yaml)

## Request rules that matter here

Defaults, clamps, and mutually-exclusive parameters — with the exact expression from the handler.

## Response rules that matter here

What the client is and is not told. Fields stripped before sending, computed values and their definition, and any field whose name does not mean what it appears to mean.

## Planned

Endpoints referenced by plans or TODOs but not implemented. Listed here so the OpenAPI document never invents them.
