---
name: adr
description: Record an architecture/business decision as the next-numbered ADR and link it from the features it affects.
argument-hint: <decision title>
---

# Record a decision

Decision to record: `$ARGUMENTS` (if empty, ask what was decided and what it rules out).

Config: `${CLAUDE_PLUGIN_OPTION_WIKI_ROOT}` → `business-docs/wiki`. Template: `${CLAUDE_PLUGIN_ROOT}/templates/adr.md`.

## Steps

1. **Check it is an ADR.** A decision earns one when it closed off a real alternative and future work must respect it: an invariant, a contract policy, a deliberate product rule, a "we do not do X" position. A rule that simply describes how something works is a feature-page rule, not an ADR — put it there instead and say so.

2. **Check for a duplicate or a supersession.** Read the existing `decisions/` titles. If this revisits an earlier decision, write the new ADR and mark the old one `Superseded by ADR-NNNN` rather than editing its content — the record of what was previously believed is the value of an ADR.

3. **Number it.** Next integer after the highest existing `decisions/NNNN-*.md`, zero-padded to four digits, slug in kebab-case.

4. **Write it** from the template. Non-negotiable content:
   - **Context** — the forces that made a choice necessary, in the project's own terms.
   - **Decision** — stated in the active voice, present tense, as a rule someone can obey.
   - **Consequences** — including what is now harder, and what someone is likely to try that this forbids.
   - **Alternatives considered** — with the actual reason each was rejected. An ADR with no rejected alternative is not a decision, it is a note.
   - Where the decision came from: a human call, a plan document (quote it), or a constraint discovered in code (cite `file:line`).

5. **Link it** from `decisions.md` in every affected feature, and from `shared/` if it is cross-cutting.

6. **Suggest a code citation.** Name the exact file and function where a `// ADR-NNNN: <one line>` comment would pay off — the point where someone might innocently break the invariant. Propose it; do not scatter comments across the codebase unasked.

7. `sh "${CLAUDE_PLUGIN_ROOT}/scripts/check-wiki.sh"`, then report the ADR path and the features linked.
