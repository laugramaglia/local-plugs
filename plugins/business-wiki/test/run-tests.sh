#!/usr/bin/env bash
# Offline test suite for business-wiki. No network, no MCP, no writes outside a
# throwaway sandbox.
#
#   bash test/run-tests.sh
#   bash test/run-tests.sh code-refs hooks      # only matching groups
#
# The scripts under test are POSIX sh and resolve their roots from the CURRENT
# DIRECTORY plus CLAUDE_PLUGIN_OPTION_* env vars, so every test cds into a fresh
# sandbox rather than pointing the scripts at this checkout.
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
FILTERS=("$@")

pass=0; fail=0; group=""
FAILED_NAMES=()

group() {
  group="$1"
  if [ "${#FILTERS[@]}" -gt 0 ]; then
    local want=0 f
    for f in "${FILTERS[@]}"; do [[ "$group" == *"$f"* ]] && want=1; done
    SKIP_GROUP=$([ "$want" -eq 1 ] && echo 0 || echo 1)
  else
    SKIP_GROUP=0
  fi
  [ "$SKIP_GROUP" -eq 0 ] && printf '\n== %s\n' "$group"
}

ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); FAILED_NAMES+=("$group: $1"); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_contains() {
  [ "${SKIP_GROUP:-0}" -eq 0 ] || return 0
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to contain '$3', got: $(printf '%s' "$2" | head -6 | tr '\n' '/')" ;; esac
}
assert_not_contains() {
  [ "${SKIP_GROUP:-0}" -eq 0 ] || return 0
  case "$2" in *"$3"*) bad "$1" "should NOT contain '$3'" ;; *) ok "$1" ;; esac
}
assert_status() {
  [ "${SKIP_GROUP:-0}" -eq 0 ] || return 0
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got $2"; fi
}

# --------------------------------------------------------------------- sandbox

SANDBOX_ROOT=$(mktemp -d)
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

sandbox_n=0
# new_sandbox — a fresh project root, cd'd into, with the default wiki layout and
# one authored feature page. The scripts read the CWD, so this is the whole of
# their configuration.
new_sandbox() {
  sandbox_n=$((sandbox_n+1))
  SB="$SANDBOX_ROOT/sb$sandbox_n"
  mkdir -p "$SB/business-docs/wiki/features/quiz" \
           "$SB/business-docs/wiki/decisions" \
           "$SB/business-docs/wiki/shared" \
           "$SB/lib/quiz"
  cd "$SB" || exit 1
  unset CLAUDE_PLUGIN_OPTION_WIKI_ROOT CLAUDE_PLUGIN_OPTION_STRICT_CHECK
  printf '# the wiki\n' > "$SB/business-docs/wiki/README.md"
  # A 12-line source file, so a :20 citation is provably dead.
  : > "$SB/lib/quiz/score.dart"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf '// line %s\n' "$i" >> "$SB/lib/quiz/score.dart"
  done
}

# page <name> <code_refs-yaml-items...>
page() {
  local name="$1"; shift
  {
    printf -- '---\n'
    printf 'feature: quiz\n'
    printf 'page: %s\n' "$name"
    printf 'status: authored\n'
    printf 'source_of_truth: wiki\n'
    printf 'updated: 2026-01-01\n'
    if [ "$#" -gt 0 ]; then
      printf 'code_refs:\n'
      for r in "$@"; do printf '  - %s\n' "$r"; done
    fi
    printf -- '---\n\n'
    printf '# quiz — %s\n\nUnanswered questions are excluded from the denominator.\nThe score is the ratio of correct answers to answered questions.\n' "$name"
  } > "$SB/business-docs/wiki/features/quiz/$name.md"
}

# shared_page <name> <body...>
shared_page() {
  local name="$1"; shift
  {
    printf -- '---\npage: %s\nstatus: authored\nupdated: 2026-01-01\n---\n\n' "$name"
    printf '# %s\n\n' "$name"
    if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else printf 'One.\nTwo.\nThree.\nFour.\n'; fi
  } > "$SB/business-docs/wiki/shared/$name.md"
}

# adr <NNNN> <slug>
adr() {
  {
    printf -- '---\nadr: %s\ntitle: T\nstatus: accepted\ndate: 2026-01-01\n---\n\n' "$1"
    printf '# ADR-%s — T\n\n## Context\nc\n\n## Decision\nd\n\n## Consequences\ne\n' "$1"
  } > "$SB/business-docs/wiki/decisions/$1-$2.md"
}

check() { sh "$SCRIPTS/check-wiki.sh" "$@" 2>&1; }
index() { sh "$SCRIPTS/wiki-index.sh" "$@" 2>&1; }
outline() { sh "$SCRIPTS/wiki-outline.sh" "$@" 2>&1; }
section() { sh "$SCRIPTS/wiki-section.sh" "$@" 2>&1; }
search() { sh "$SCRIPTS/wiki-search.sh" "$@" 2>&1; }
hook_json() { printf '{"tool_input":{"file_path":"%s/%s"}}' "$SB" "$1"; }

# ========================================================================= run

group code-refs
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  page validations 'lib/quiz/score.dart'
  out=$(check); rc=$?
  assert_status   "a resolving path passes" "$rc" 0
  assert_contains "and says so"             "$out" "check-wiki: pass"

  # The regression this group exists for: a citation past end of file.
  new_sandbox
  page validations 'lib/quiz/score.dart:20'
  out=$(check); rc=$?
  assert_status   "a line past EOF fails"     "$rc" 1
  assert_contains "and quotes both numbers"   "$out" "score.dart:20 but that file has 12 line(s)"

  new_sandbox
  page validations 'lib/quiz/score.dart:12'
  out=$(check); rc=$?
  assert_status "the last line is in range" "$rc" 0

  new_sandbox
  page validations 'lib/quiz/score.dart:1'
  out=$(check); rc=$?
  assert_status "the first line is in range" "$rc" 0

  # A missing path still fails, with or without a line.
  new_sandbox
  page validations 'lib/quiz/gone.dart'
  out=$(check); rc=$?
  assert_status   "a missing path fails"  "$rc" 1
  assert_contains "and names it"          "$out" "does not exist: lib/quiz/gone.dart"

  new_sandbox
  page validations 'lib/quiz/gone.dart:4'
  out=$(check); rc=$?
  assert_status   "a missing path with a line fails once" "$rc" 1
  assert_contains "reporting the path, not the line"      "$out" "does not exist: lib/quiz/gone.dart"

  # A directory can be cited, but not with a line number.
  new_sandbox
  page validations 'lib/quiz'
  out=$(check); rc=$?
  assert_status "a directory ref passes" "$rc" 0
  new_sandbox
  page validations 'lib/quiz:5'
  out=$(check); rc=$?
  assert_status   "a directory with a line fails" "$rc" 1
  assert_contains "saying it isn't a file"        "$out" "is not a file"

  # Several refs on one page: every finding must survive the loop. Before this,
  # the loop ran in a pipeline and its counter increments were lost in a subshell.
  new_sandbox
  page validations 'lib/quiz/score.dart:99' 'lib/quiz/missing.dart' 'lib/quiz/score.dart'
  out=$(check); rc=$?
  assert_status   "two bad refs on one page fail" "$rc" 1
  assert_contains "the dead line is reported"     "$out" "score.dart:99"
  assert_contains "the missing path too"          "$out" "missing.dart"
  assert_contains "and both are counted"          "$out" "2 error(s)"
fi

group staleness
if [ "$SKIP_GROUP" -eq 0 ]; then
  # Outside a git repo the check must be silent, not optimistic.
  new_sandbox
  page validations 'lib/quiz/score.dart'
  out=$(check)
  assert_not_contains "no git: nothing about dates" "$out" "after this page's updated"

  # Inside one, code that moved after the page's `updated` is a warning.
  new_sandbox
  page validations 'lib/quiz/score.dart'
  git init -q . >/dev/null 2>&1
  git config user.email t@example.com; git config user.name t
  git add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE='2026-06-01T10:00:00' GIT_COMMITTER_DATE='2026-06-01T10:00:00' \
    git commit -qm 'code' >/dev/null 2>&1
  out=$(check); rc=$?
  assert_status   "staleness is a warning, not a failure" "$rc" 0
  assert_contains "and names the date it moved"           "$out" "changed on 2026-06-01"
  assert_contains "against the page's own date"           "$out" "updated: 2026-01-01"

  # strict_check turns every warning into a failure, staleness included.
  out=$(CLAUDE_PLUGIN_OPTION_STRICT_CHECK=true check); rc=$?
  assert_status "strict_check promotes it to a failure" "$rc" 1

  # Code committed BEFORE the page's date is current, and says nothing.
  new_sandbox
  page validations 'lib/quiz/score.dart'
  git init -q . >/dev/null 2>&1
  git config user.email t@example.com; git config user.name t
  git add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE='2025-12-01T10:00:00' GIT_COMMITTER_DATE='2025-12-01T10:00:00' \
    git commit -qm 'code' >/dev/null 2>&1
  out=$(check)
  assert_not_contains "older code is not stale" "$out" "after this page's updated"
fi

group hook-mode
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The PostToolUse hook runs on every Write/Edit. A file outside the wiki must
  # exit 0 in silence, and the git staleness walk must not run at all.
  new_sandbox
  page validations 'lib/quiz/score.dart'
  out=$(printf '{"tool_input":{"file_path":"%s/lib/quiz/score.dart"}}' "$SB" | check --changed); rc=$?
  assert_status "a non-wiki edit exits 0" "$rc" 0
  if [ -z "$out" ]; then ok "and says nothing"; else bad "and says nothing" "$out"; fi

  out=$(printf '{"tool_input":{"file_path":"%s/business-docs/wiki/features/quiz/validations.md"}}' "$SB" | check --changed); rc=$?
  assert_status "a clean wiki edit exits 0" "$rc" 0

  new_sandbox
  page validations 'lib/quiz/score.dart:99'
  out=$(printf '{"tool_input":{"file_path":"%s/business-docs/wiki/features/quiz/validations.md"}}' "$SB" | check --changed); rc=$?
  assert_status   "a bad citation fails in hook mode too" "$rc" 1
  assert_contains "naming the ref"                        "$out" "score.dart:99"

  # Hook mode skips the repo-wide ADR-citation scan, which is the slow part.
  new_sandbox
  page validations 'lib/quiz/score.dart'
  printf '// see ADR-0099\n' > "$SB/lib/quiz/other.dart"
  out=$(check); rc=$?
  assert_status   "a full run catches an ADR that doesn't exist" "$rc" 1
  assert_contains "and names it"                                 "$out" "ADR-0099"
  out=$(printf '{"tool_input":{"file_path":"%s/business-docs/wiki/features/quiz/validations.md"}}' "$SB" | check --changed); rc=$?
  assert_status "but hook mode stays out of it" "$rc" 0
fi

group provenance
if [ "$SKIP_GROUP" -eq 0 ]; then
  # rules_json <extra-key-line> — a minimal derived file for feature quiz. The
  # caller supplies the provenance line (or nothing) because that is the whole
  # subject of this group.
  rules_json() {
    mkdir -p business-docs/rules
    cp "$PLUGIN_DIR/templates/rules-schema.json" business-docs/rules/_schema.json
    {
      printf '{\n  "_source": "business-docs/wiki/features/quiz",\n'
      [ -n "${1:-}" ] && printf '  %s,\n' "$1"
      printf '  "feature": "quiz",\n  "updated": "2026-01-01",\n'
      printf '  "rules": [ { "id": "score-ratio", "statement": "The score is the ratio of correct answers to answered questions.", "page": "validations", "status": "enforced" } ]\n}\n'
    } > business-docs/rules/quiz.json
  }
  rules() { sh "$SCRIPTS/check-rules.sh" 2>&1; }

  new_sandbox; page validations
  rules_json '"derived_by": "business-rules-keeper"'
  out=$(rules); rc=$?
  assert_status       "a keeper-stamped file passes"   "$rc" 0
  assert_not_contains "with nothing said about it"     "$out" "derived_by"

  # The retro's case: the derive ran, the keepers didn't, and the output was
  # indistinguishable from generated.
  new_sandbox; page validations
  rules_json '"derived_by": "hand"'
  out=$(rules); rc=$?
  assert_status   "a hand-derived file still passes"  "$rc" 0
  assert_contains "but says so"                      "$out" "is hand-derived"
  assert_contains "and names the fix"                "$out" "/business-wiki:derive"

  CLAUDE_PLUGIN_OPTION_STRICT_CHECK=true; export CLAUDE_PLUGIN_OPTION_STRICT_CHECK
  out=$(rules); rc=$?
  assert_status "strict_check makes a hand-derive fatal" "$rc" 1
  unset CLAUDE_PLUGIN_OPTION_STRICT_CHECK

  new_sandbox; page validations
  rules_json ''
  out=$(rules); rc=$?
  assert_status   "no provenance at all still passes" "$rc" 0
  assert_contains "and is reported as unrecorded"     "$out" "has no 'derived_by'"

  # Files written before the stamp existed must not read as hand-derived.
  new_sandbox; page validations
  rules_json '"_generated_by": "business-rules-keeper"'
  out=$(rules); rc=$?
  assert_status   "the deprecated spelling passes" "$rc" 0
  assert_contains "and is named as deprecated"     "$out" "pre-provenance spelling"

  new_sandbox; page validations
  rules_json '"derived_by": "vibes"'
  out=$(rules); rc=$?
  assert_status   "an unknown provenance fails" "$rc" 1
  assert_contains "and quotes it"               "$out" "derived_by 'vibes'"

  # --- the OpenAPI side, same rule
  spec() { # spec <x-derived-by-line-or-empty>
    mkdir -p business-docs/openapi
    {
      printf 'openapi: 3.1.0\n'
      printf 'info:\n  title: t\n  version: "1"\n'
      [ -n "${1:-}" ] && printf '  x-derived-by: %s\n' "$1"
      printf 'paths:\n  /quiz:\n    get:\n      summary: x\n'
    } > business-docs/openapi/api.yaml
    sh "$SCRIPTS/check-openapi.sh" 2>&1
  }

  new_sandbox
  out=$(spec openapi-keeper); rc=$?
  assert_status       "a keeper-stamped spec passes" "$rc" 0
  assert_not_contains "silently"                     "$out" "x-derived-by"

  new_sandbox
  out=$(spec hand); rc=$?
  assert_status   "a hand-written spec passes"  "$rc" 0
  assert_contains "but says so"                "$out" "is hand-derived"

  new_sandbox
  out=$(spec ''); rc=$?
  assert_contains "an unstamped spec is reported" "$out" "no 'info.x-derived-by'"

  new_sandbox
  out=$(spec vibes); rc=$?
  assert_status   "an unknown spec provenance fails" "$rc" 1
  assert_contains "and quotes it"                    "$out" "x-derived-by 'vibes'"
fi

group route-detection
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The regression this group exists for: `.get` is also how frameworks read a
  # value. Hono's `c.get('userId')` was reported as an undocumented endpoint on
  # a real worker, and the "fix" for that finding would have been to document an
  # endpoint that does not exist.
  new_sandbox
  mkdir -p worker/src business-docs/openapi
  {
    printf "app.get('/health', h)\n"
    printf "app.post('/attempts', h)\n"
    printf "const userId = c.get('userId') as string\n"
    printf "const page = url.searchParams.get('page')\n"
  } > worker/src/index.ts
  {
    printf 'openapi: 3.1.0\ninfo:\n  title: t\n  version: "1"\n  x-derived-by: openapi-keeper\n'
    printf 'paths:\n  /health:\n    get:\n      summary: x\n  /attempts:\n    post:\n      summary: y\n'
  } > business-docs/openapi/api.yaml
  out=$(CLAUDE_PLUGIN_OPTION_CONTRACT_SOURCE=worker/src sh "$SCRIPTS/check-openapi.sh" 2>&1); rc=$?
  assert_status       "a context read is not a route"  "$rc" 0
  assert_not_contains "and is never reported"          "$out" "userId"
  assert_not_contains "nor is a query-param read"      "$out" "'page'"

  # A genuinely undocumented route still fails.
  printf "app.get('/secret', h)\n" >> worker/src/index.ts
  out=$(CLAUDE_PLUGIN_OPTION_CONTRACT_SOURCE=worker/src sh "$SCRIPTS/check-openapi.sh" 2>&1); rc=$?
  assert_status   "an undocumented route still fails" "$rc" 1
  assert_contains "and is named"                      "$out" "exposes '/secret'"
fi

group links
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The regression this group exists for: a page that DOCUMENTS the link syntax
  # writes [[link]] in backticks. That is an illustration, not an edge, and the
  # old grep-based extractor reported it as a broken link.
  new_sandbox
  shared_page glossary
  page index 'lib/quiz/score.dart'
  printf 'Link a neighbour with a `[[link]]`, like this.\nReal one: [[glossary]].\n' \
    >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(check); rc=$?
  assert_status       "a [[link]] in a code span is not an edge" "$rc" 0
  assert_not_contains "and is not reported"                      "$out" "[[link]]"
  assert_not_contains "while the real link resolves"             "$out" "[[glossary]]"

  # Same for a fenced block.
  new_sandbox
  page index 'lib/quiz/score.dart'
  printf '\n```\nSee [[nowhere]].\n```\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(check); rc=$?
  assert_status "a link inside a fence is not an edge" "$rc" 0

  # A genuinely broken link still fails, and now with its real line number
  # rather than the first textual match.
  new_sandbox
  page index 'lib/quiz/score.dart'
  printf '\nSee [[nowhere]].\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(check); rc=$?
  assert_status   "a dangling link still fails"  "$rc" 1
  assert_contains "naming it"                    "$out" "[[nowhere]] does not resolve"
  assert_contains "at the line it is on"         "$out" "index.md:16"

  # Aliases: a feature's index answers to the bare slug, an ADR to its citation.
  new_sandbox
  page index 'lib/quiz/score.dart'
  page flow 'lib/quiz/score.dart'
  adr 0001 first
  printf '\nSee [[quiz]] and [[ADR-0001]] and [[0001-first]].\n' \
    >> "$SB/business-docs/wiki/features/quiz/flow.md"
  out=$(check); rc=$?
  assert_status "the feature slug, ADR-NNNN, and the file stem all resolve" "$rc" 0
fi

group index
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  page index 'lib/quiz/score.dart'
  page flow 'lib/quiz/score.dart'
  shared_page glossary
  adr 0001 first
  printf '\nTerms: [[glossary]].\n' >> "$SB/business-docs/wiki/features/quiz/index.md"

  out=$(index --write)
  assert_contains "--write reports the file" "$out" "business-docs/index.tsv"
  [ -f business-docs/index.tsv ] && ok "and the file is there" || bad "and the file is there" ""

  # Derived output lives beside rules/ and openapi/, never inside the wiki: the
  # wiki root is the authored half and stays hand-written.
  if [ -e business-docs/wiki/index.tsv ]; then
    bad "the index stays out of the wiki" "found business-docs/wiki/index.tsv"
  else
    ok "the index stays out of the wiki"
  fi

  cols=$(grep -v '^#' business-docs/index.tsv | awk -F'\t' '{print NF}' | sort -u)
  assert_contains "every row has 10 columns" "$cols" "10"
  if [ "$(printf '%s' "$cols" | wc -l | tr -d ' ')" -eq 0 ]; then ok "and only 10"; else bad "and only 10" "$cols"; fi

  out=$(index --path quiz)
  assert_contains "an alias resolves to a path" "$out" "features/quiz/index.md"
  out=$(index --path ADR-0001)
  assert_contains "so does an ADR citation" "$out" "decisions/0001-first.md"
  out=$(index --path quiz-flow)
  assert_contains "and a link name" "$out" "features/quiz/flow.md"

  out=$(index --backlinks glossary)
  assert_contains "backlinks find the page that links here" "$out" "quiz-index"
  out=$(index --links quiz-index)
  assert_contains "and links-out is its inverse" "$out" "glossary"

  out=$(index --check); rc=$?
  assert_status "--check passes on a written, current index" "$rc" 0

  # Stale is a warning, because the hook normally prevents it — and fatal under
  # strict_check, because a stale index answers with yesterday's graph.
  printf '\nMore: [[glossary]].\n' >> "$SB/business-docs/wiki/features/quiz/flow.md"
  out=$(index --check); rc=$?
  assert_status   "a stale index is a warning" "$rc" 0
  assert_contains "that names the fix"         "$out" "--write"
  out=$(CLAUDE_PLUGIN_OPTION_STRICT_CHECK=true index --check); rc=$?
  assert_status "and is fatal under strict_check" "$rc" 1

  # The collision the old sort -u hid: two files claiming one link name.
  new_sandbox
  page flow 'lib/quiz/score.dart'
  shared_page quiz-flow
  out=$(index --check); rc=$?
  assert_status   "a link name claimed twice fails" "$rc" 1
  assert_contains "naming both files"               "$out" "claimed by more than one page"

  # aliases/links_out are comma-joined inside a TSV field. That is safe only
  # because link names come from filenames — so the index asserts it instead of
  # trusting it, or a page's backlinks vanish without a word.
  new_sandbox
  page index 'lib/quiz/score.dart'
  shared_page 'a,b'
  out=$(index --check); rc=$?
  assert_status   "a comma in a link name fails" "$rc" 1
  assert_contains "and says to rename the file"  "$out" "contains a comma"

  # --check sees dangling links at the graph level, without a per-page walk.
  new_sandbox
  page index 'lib/quiz/score.dart'
  printf '\nSee [[nowhere]].\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(index --check); rc=$?
  assert_status   "a dangling link fails --check" "$rc" 1
  assert_contains "and is named"                  "$out" "[[nowhere]]"
fi

group index-hook
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  page index 'lib/quiz/score.dart'
  shared_page glossary
  index --write >/dev/null
  before=$(cat business-docs/index.tsv)

  out=$(hook_json lib/quiz/score.dart | sh "$SCRIPTS/wiki-index.sh" --changed 2>&1); rc=$?
  assert_status "an edit outside the wiki exits 0" "$rc" 0
  if [ -z "$out" ]; then ok "in silence"; else bad "in silence" "$out"; fi
  if [ "$before" = "$(cat business-docs/index.tsv)" ]; then ok "leaving the index untouched"; else bad "leaving the index untouched" ""; fi

  # An edit that does not change the graph must not touch the file either, or
  # the index turns up in every unrelated diff.
  out=$(hook_json business-docs/wiki/features/quiz/index.md | sh "$SCRIPTS/wiki-index.sh" --changed 2>&1); rc=$?
  assert_status "a no-op wiki edit exits 0" "$rc" 0
  if [ "$before" = "$(cat business-docs/index.tsv)" ]; then ok "and rewrites nothing"; else bad "and rewrites nothing" ""; fi

  printf '\nTerms: [[glossary]].\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  hook_json business-docs/wiki/features/quiz/index.md | sh "$SCRIPTS/wiki-index.sh" --changed >/dev/null 2>&1
  out=$(grep '^quiz-index' business-docs/index.tsv)
  assert_contains "a real wiki edit refreshes the graph" "$out" "glossary"
  out=$(index --check); rc=$?
  assert_status "so --check finds nothing to say" "$rc" 0

  # The invariant the whole optimisation rests on: the hook splices ONE row
  # instead of rebuilding, so the spliced file must be byte-identical to a full
  # build. If it drifts, --check reports the index as permanently stale.
  index > "$SANDBOX_ROOT/full.tsv"
  if cmp -s "$SANDBOX_ROOT/full.tsv" business-docs/index.tsv; then
    ok "a spliced index equals a full build, byte for byte"
  else
    bad "a spliced index equals a full build, byte for byte" "$(diff "$SANDBOX_ROOT/full.tsv" business-docs/index.tsv | head -4)"
  fi

  # A new page and a deleted page are splices too, not just edits.
  adr 0002 second
  hook_json business-docs/wiki/decisions/0002-second.md | sh "$SCRIPTS/wiki-index.sh" --changed >/dev/null 2>&1
  out=$(index --path ADR-0002)
  assert_contains "a new page is spliced in" "$out" "0002-second.md"
  index > "$SANDBOX_ROOT/full.tsv"
  if cmp -s "$SANDBOX_ROOT/full.tsv" business-docs/index.tsv; then
    ok "and the file still matches a full build"
  else
    bad "and the file still matches a full build" ""
  fi

  rm business-docs/wiki/decisions/0002-second.md
  hook_json business-docs/wiki/decisions/0002-second.md | sh "$SCRIPTS/wiki-index.sh" --changed >/dev/null 2>&1
  if grep -q '0002-second' business-docs/index.tsv; then
    bad "a deleted page is spliced out" "row still present"
  else
    ok "a deleted page is spliced out"
  fi
fi

group graph
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The gap this group exists for: on a real 137-page wiki every one of the 44
  # ADRs had zero backlinks, because the decisions.md pages cite them as
  # [ADR-0007](../../decisions/0007-slug.md) and nothing parsed that.
  new_sandbox
  page index 'lib/quiz/score.dart'
  page decisions 'lib/quiz/score.dart'
  adr 0001 first
  printf '\n| [ADR-0001](../../decisions/0001-first.md) | why | binds |\n' \
    >> "$SB/business-docs/wiki/features/quiz/decisions.md"
  index --write >/dev/null

  out=$(index --backlinks 0001-first)
  assert_contains "a relative Markdown link is an edge" "$out" "quiz-decisions"
  out=$(check); rc=$?
  assert_status "and the page still validates" "$rc" 0

  # A dead relative link is reported by check-wiki with its real line and href,
  # and must NOT become a phantom node in the graph.
  new_sandbox
  page index 'lib/quiz/score.dart'
  printf '\nSee [ADR-0009](../../decisions/0009-gone.md).\n' \
    >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(check); rc=$?
  assert_status   "a dead relative link fails"   "$rc" 1
  assert_contains "naming the href as written"   "$out" "0009-gone.md"
  assert_contains "at the line it is on"         "$out" "index.md:16"
  out=$(index --write; grep '^quiz-index' business-docs/index.tsv)
  assert_not_contains "and it is not in the graph" "$out" "0009-gone"

  # An ADR names the features it binds in frontmatter. That is an authored edge.
  new_sandbox
  page index 'lib/quiz/score.dart'
  {
    printf -- '---\nadr: 0002\ntitle: T\nstatus: accepted\ndate: 2026-01-01\naffects:\n  - quiz\n---\n\n'
    printf '# ADR-0002 — T\n\n## Context\nc\n\n## Decision\nd\n\n## Consequences\ne\n'
  } > "$SB/business-docs/wiki/decisions/0002-affects.md"
  index --write >/dev/null
  out=$(index --links 0002-affects)
  assert_contains "affects: is an edge to the feature" "$out" "quiz-index"
  out=$(index --backlinks quiz-index)
  assert_contains "so the feature sees the decision" "$out" "0002-affects"

  # affects: names the feature slug, which is an ALIAS. Edges are stored
  # canonically, or --backlinks on the real name would miss them.
  out=$(grep '^0002-affects' business-docs/index.tsv | cut -f10)
  assert_contains     "edges are stored canonically" "$out" "quiz-index"
  assert_not_contains "not as the alias"             "$out" "quiz,"

  # Same for a wikilink written as an alias.
  new_sandbox
  page index 'lib/quiz/score.dart'
  page flow 'lib/quiz/score.dart'
  printf '\nSee [[quiz]].\n' >> "$SB/business-docs/wiki/features/quiz/flow.md"
  index --write >/dev/null
  out=$(index --backlinks quiz-index)
  assert_contains "an aliased [[link]] resolves to the canonical name" "$out" "quiz-flow"
fi

group placeholders
if [ "$SKIP_GROUP" -eq 0 ]; then
  # A real wiki documents a date format as `YYYY-MM-DD`. That is finished prose,
  # not an unreplaced template placeholder, and calling it one was four false
  # positives out of eight findings on a real 137-page wiki.
  new_sandbox
  page index 'lib/quiz/score.dart'
  printf '\nDates on the wire are civil dates, `YYYY-MM-DD`, regex-checked.\n' \
    >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(check); rc=$?
  assert_status       "a format documented in a code span is not a placeholder" "$rc" 0
  assert_not_contains "and is not reported"                                     "$out" "placeholder"

  # A genuinely unreplaced one still fails.
  new_sandbox
  page index 'lib/quiz/score.dart'
  printf '\nOwned by FEATURE_NAME, see PATH/TO/CODE.\n' \
    >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(check); rc=$?
  assert_status   "a real leftover placeholder still fails" "$rc" 1
  assert_contains "and is named"                            "$out" "unreplaced template placeholder"
fi

group mentions
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  page index 'lib/quiz/score.dart'
  shared_page glossary
  printf '\nThe glossary defines the terms.\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  index --write >/dev/null

  out=$(index --mentions)
  assert_contains "a named page mentioned in prose is reported" "$out" "glossary"
  assert_contains "with the page that mentions it"              "$out" "quiz/index.md"

  # Once it is linked it is not a finding any more.
  printf '\nSee [[glossary]].\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  index --write >/dev/null
  out=$(index --mentions)
  assert_not_contains "a linked mention is not reported" "$out" "quiz/index.md"

  # Frontmatter is metadata, not prose: `feature: quiz` is not quiz/states.md
  # failing to link to quiz-index.
  new_sandbox
  page index 'lib/quiz/score.dart'
  page states 'lib/quiz/score.dart'
  index --write >/dev/null
  out=$(index --mentions)
  assert_not_contains "frontmatter is not a mention" "$out" "quiz/states.md"

  # ADR-NNNN in prose is this wiki's own citation form, not a missing link.
  new_sandbox
  page index 'lib/quiz/score.dart'
  adr 0001 first
  printf '\nThis follows ADR-0001 exactly.\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  index --write >/dev/null
  out=$(index --mentions)
  assert_not_contains "an ADR citation is not a finding by default" "$out" "0001-first"
  out=$(index --mentions --all)
  assert_contains "but --all reports it" "$out" "0001-first"
fi

group synonyms
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The glossary is a hand-written synonym table: it exists because the client,
  # the wire and the database name one concept three ways.
  new_sandbox
  page index 'lib/quiz/score.dart'
  {
    printf -- '---\npage: glossary\nstatus: authored\nupdated: 2026-01-01\n---\n\n'
    printf '# Glossary\n\n## Question version\n\nOne immutable revision.\n\n'
    printf -- '- **In code:** `question_version.id` (DB) / `questionVersionId` (wire).\n\n'
    printf '## Body\n\nThe JSONB payload.\n'
  } > "$SB/business-docs/wiki/shared/glossary.md"
  index --write >/dev/null

  out=$(index --synonyms questionVersionId)
  assert_contains "the DB name is a synonym of the wire name" "$out" "question_version.id"
  assert_contains "and so is the glossary heading"            "$out" "Question version"
  out=$(index --synonyms question_version.id)
  assert_contains "and the relation is symmetric" "$out" "questionVersionId"

  # The precision guard, measured on a real wiki: expanding to the bare word
  # "question" took one query from 4 matches to 779. Only specific forms —
  # phrases, dotted or underscored names, camelCase — may be expanded to.
  out=$(index --synonyms Body)
  if [ -z "$out" ]; then ok "a plain single word expands to nothing"; else bad "a plain single word expands to nothing" "$out"; fi

  # And the search reports the expansion rather than doing it invisibly.
  printf '\nThe `question_version.id` column is the key.\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(search questionVersionId)
  assert_contains "search says it expanded"        "$out" "glossary:"
  assert_contains "and finds the other spelling"   "$out" "question_version.id"
  out=$(search questionVersionId --no-synonyms)
  assert_not_contains "--no-synonyms turns it off" "$out" "glossary:"
fi

group index-quiet
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The PostToolUse hook fires in EVERY repo, including every repo that has
  # never installed the plugin. Loud there is a bug.
  quiet_sb=$(mktemp -d)
  cd "$quiet_sb" || exit 1
  out=$(printf '{"tool_input":{"file_path":"/x/y.md"}}' | sh "$SCRIPTS/wiki-index.sh" --changed 2>&1); rc=$?
  assert_status "--changed in a repo with no wiki exits 0" "$rc" 0
  if [ -z "$out" ]; then ok "and says nothing"; else bad "and says nothing" "$out"; fi
  # An explicit run must still report it: silence is for the hook, not for humans.
  out=$(sh "$SCRIPTS/wiki-index.sh" --check 2>&1); rc=$?
  assert_status   "but --check still fails there" "$rc" 1
  assert_contains "pointing at bootstrap"         "$out" "/business-wiki:bootstrap"
  cd "$PLUGIN_DIR" || exit 1
  rm -rf "$quiet_sb"
fi

group navigate
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  page index 'lib/quiz/score.dart'
  shared_page glossary
  printf '\nTerms: [[glossary]].\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  cat > "$SB/business-docs/wiki/features/quiz/flow.md" <<'EOF'
---
feature: quiz
page: flow
status: authored
source_of_truth: wiki
updated: 2026-01-01
---

# quiz — flow

## Happy path

The user answers and the score appears.

### Scoring

Unanswered questions are excluded from the denominator.

## Edge cases

Zero answered questions yields no score.
EOF
  index --write >/dev/null

  out=$(outline quiz-flow)
  assert_contains "outline lists the headings"        "$out" "## Happy path"
  assert_contains "with their line numbers"           "$out" "11"
  assert_contains "and nests the deeper ones"         "$out" "### Scoring"
  assert_not_contains "without repeating the H1"      "$out" "# quiz — flow
"
  assert_contains "it carries the frontmatter"        "$out" "source_of_truth: wiki"
  assert_not_contains "but not the body"              "$out" "denominator"

  out=$(outline glossary)
  assert_contains "backlinks point at what depends on a page" "$out" "quiz-index"

  out=$(outline quiz)
  assert_contains "an alias works as a target" "$out" "features/quiz/index.md"

  out=$(section quiz-flow 'Happy path')
  assert_contains     "a section returns its own heading" "$out" "## Happy path"
  assert_contains     "and its body"                      "$out" "The user answers"
  assert_contains     "including deeper headings inside"  "$out" "### Scoring"
  assert_not_contains "and stops at the next H2"          "$out" "Edge cases"

  out=$(section quiz-flow scoring)
  assert_contains     "matching is case-insensitive" "$out" "### Scoring"
  assert_not_contains "and an H3 stops at the next H2" "$out" "Zero answered"

  out=$(section quiz-flow 'Nope'); rc=$?
  assert_status   "a missing heading fails"      "$rc" 1
  assert_contains "listing what is available"    "$out" "Happy path"

  out=$(search denominator)
  assert_contains "search finds body text with its line" "$out" "flow.md:17"

  out=$(search glossary)
  assert_contains "a query that is a name resolves exactly" "$out" "exact name match"

  out=$(search score --page flow)
  assert_contains     "filters scope the search" "$out" "flow.md"
  assert_not_contains "to those pages only"      "$out" "index.md"

  out=$(search '' --kind shared --paths-only)
  assert_contains     "--paths-only lists the pages a filter allows" "$out" "shared/glossary.md"
  assert_not_contains "and nothing else"                             "$out" "features/"
fi

group doctor
if [ "$SKIP_GROUP" -eq 0 ]; then
  doctor() { CLAUDE_PLUGIN_OPTION_OPENAPI_PATH= sh "$SCRIPTS/wiki-doctor.sh" "$@" 2>&1; }
  rules_ok() {
    mkdir -p business-docs/rules
    cp "$PLUGIN_DIR/templates/rules-schema.json" business-docs/rules/_schema.json
    printf '{\n  "_source": "business-docs/wiki/features/quiz",\n  "derived_by": "business-rules-keeper",\n  "feature": "quiz",\n  "updated": "2026-01-01",\n  "rules": [ { "id": "r", "statement": "s", "page": "index", "status": "enforced" } ]\n}\n' > business-docs/rules/quiz.json
    printf '# docs\n' > business-docs/README.md
  }

  # A repo with no wiki must be told to bootstrap, not handed a wall of noise.
  quiet_sb=$(mktemp -d); cd "$quiet_sb" || exit 1
  out=$(doctor); rc=$?
  assert_status   "no wiki: the doctor fails"  "$rc" 1
  assert_contains "and names the one fix"      "$out" "/business-wiki:bootstrap"
  cd "$PLUGIN_DIR" || exit 1; rm -rf "$quiet_sb"

  # Every finding carries what fixes it and who owns it — that is the whole
  # point of the script over running four validators by hand.
  new_sandbox
  page index 'lib/quiz/score.dart'
  rules_ok
  printf '\nSee [[nowhere]] and [ADR-0009](../../decisions/0009-gone.md).\n' \
    >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(doctor); rc=$?
  assert_status   "a broken wiki fails"          "$rc" 1
  assert_contains "the dangling link is a finding" "$out" "[[nowhere]]"
  assert_contains "the dead relative link too"     "$out" "0009-gone.md"
  assert_contains "each carries a fix"             "$out" "fix:"
  assert_contains "and an owner"                   "$out" "owner: wiki-keeper"

  # check-wiki reports a dangling link per page with its line; wiki-index
  # --check reports the same edge at graph level. One fact, one finding.
  n=$(printf '%s\n' "$out" | grep -c '\[\[nowhere\]\]')
  if [ "$n" -eq 1 ]; then ok "two validators, one finding"; else bad "two validators, one finding" "counted $n"; fi

  # --fix repairs the derived index and NOTHING authored.
  new_sandbox
  page index 'lib/quiz/score.dart'
  rules_ok
  before=$(cat "$SB/business-docs/wiki/features/quiz/index.md")
  out=$(doctor --fix); rc=$?
  assert_status   "a healthy wiki passes"     "$rc" 0
  assert_contains "and the index was built"   "$out" "rebuilt"
  [ -f business-docs/index.tsv ] && ok "the file exists" || bad "the file exists" ""
  if [ "$before" = "$(cat "$SB/business-docs/wiki/features/quiz/index.md")" ]; then
    ok "authored prose was not touched"
  else
    bad "authored prose was not touched" ""
  fi

  # A second run has nothing to say and nothing to do.
  out=$(doctor)
  assert_contains     "a clean run says so"        "$out" "0 error(s)"
  assert_not_contains "and claims no repair"       "$out" "fixed"

  # --fix must never invent a fix for something only a human can decide.
  new_sandbox
  page index 'lib/quiz/score.dart'
  rules_ok
  printf '\nSee [[nowhere]].\n' >> "$SB/business-docs/wiki/features/quiz/index.md"
  out=$(doctor --fix); rc=$?
  assert_status   "--fix still fails on a broken link" "$rc" 1
  assert_contains "leaving it as a finding"            "$out" "[[nowhere]]"

  # An unmatched message takes its owner from the validator that reported it: an
  # undocumented endpoint belongs to openapi-keeper however it is worded.
  new_sandbox
  page index 'lib/quiz/score.dart'
  rules_ok
  mkdir -p business-docs/openapi
  printf 'openapi: 3.1.0\ninfo:\n  title: t\n  version: "1"\n  x-derived-by: vibes\npaths: {}\n' \
    > business-docs/openapi/api.yaml
  out=$(CLAUDE_PLUGIN_OPTION_OPENAPI_PATH=business-docs/openapi/api.yaml sh "$SCRIPTS/wiki-doctor.sh" 2>&1)
  assert_contains "an OpenAPI finding is owned by openapi-keeper" "$out" "openapi-keeper"

  # Grouping exists because a flat list buries the shape: on a real wiki 127 of
  # 150 findings were one category, and "the code moved under 127 pages" is one
  # task, not 127 findings to read.
  new_sandbox
  rules_ok
  for pg in index flow states errors validations; do
    page "$pg" 'lib/quiz/score.dart'
    printf '\nSee [[gone-%s]].\n' "$pg" >> "$SB/business-docs/wiki/features/quiz/$pg.md"
  done
  out=$(doctor)
  assert_contains "the report groups by category"   "$out" "BY CATEGORY"
  assert_contains "naming the category"             "$out" "dangling-wikilink"
  assert_contains "with a count"                    "$out" "5  dangling-wikilink"
  assert_contains "an owner per category"           "$out" "owner: wiki-keeper"
  assert_contains "and a fix per category"          "$out" "fix: fix the [[link]]"

  # Warnings are capped per category, and the cap says how many it held back —
  # a silent cap reads as "that is all there is".
  new_sandbox
  rules_ok
  for pg in index flow states errors validations api; do
    page "$pg" 'lib/quiz/score.dart'
    sed -i.bak 's/^status: authored/status: stub/' "$SB/business-docs/wiki/features/quiz/$pg.md"
    rm -f "$SB/business-docs/wiki/features/quiz/$pg.md.bak"
  done
  out=$(doctor)
  assert_contains "warnings are grouped too"        "$out" "stub — 6"
  assert_contains "and the cap is announced"        "$out" "more in this category"

  out=$(doctor --quiet)
  assert_contains     "--quiet prints the verdict" "$out" "doctor:"
  assert_not_contains "and nothing else"           "$out" "FINDINGS"
  assert_not_contains "not even the table"         "$out" "BY CATEGORY"
fi

group hygiene
if [ "$SKIP_GROUP" -eq 0 ]; then
  cd "$PLUGIN_DIR" || exit 1
  # These scripts are the offline half of the plugin: no network, no MCP, no jq.
  hits=$(grep -lE '(^|[^a-zA-Z_])(curl|wget|gh|az) ' "$SCRIPTS"/*.sh 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "no network CLI is invoked"; else bad "no network CLI is invoked" "$hits"; fi
  hits=$(grep -nE 'git (commit|push|checkout|branch|add|merge|tag)' "$SCRIPTS"/*.sh || true)
  if [ -z "$hits" ]; then ok "no git mutation anywhere"; else bad "no git mutation anywhere" "$hits"; fi

  # The read tools are read: only wiki-index.sh may ever write, and only the
  # index. A navigation tool that edits the wiki would corrupt the thing it is
  # supposed to describe.
  hits=$(grep -lE '(^|[^-a-zA-Z_])(mv|rm|mkdir|tee) ' "$SCRIPTS"/wiki-outline.sh "$SCRIPTS"/wiki-section.sh 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "the read tools never write"; else bad "the read tools never write" "$hits"; fi

  for f in "$SCRIPTS"/*.sh; do
    head -1 "$f" | grep -q '^#!/bin/sh' || bad "shebang in $(basename "$f")" "expected POSIX sh"
  done
  ok "every script declares /bin/sh"

  # wiki-doctor --fix may write exactly one thing: the derived index. If it ever
  # learns to edit the wiki, this fails and someone has to justify it.
  if grep -qE '(mv|rm|sed -i|>[^&])' "$SCRIPTS/wiki-doctor.sh" | grep -v index; then
    bad "the doctor only repairs derived output" "found a write outside the index"
  else
    ok "the doctor only repairs derived output"
  fi

  for s in bootstrap feature adr derive check harvest navigate; do
    f="$PLUGIN_DIR/skills/$s/SKILL.md"
    if [ -f "$f" ] && head -1 "$f" | grep -q '^---$' && grep -q "^name: $s$" "$f"; then
      ok "skill $s is well-formed"
    else
      bad "skill $s is well-formed" "$f"
    fi
  done

  # The derive gate is the whole point of part C: assert it in the skill, so a
  # future edit that drops it fails here rather than silently the next release.
  if grep -q 'source-drift-watcher' "$PLUGIN_DIR/skills/derive/SKILL.md"; then
    ok "derive gates on source-drift-watcher"
  else
    bad "derive gates on source-drift-watcher" ""
  fi
  if grep -q 'check-wiki.sh' "$PLUGIN_DIR/skills/derive/SKILL.md"; then
    ok "and runs check-wiki before deriving"
  else
    bad "and runs check-wiki before deriving" ""
  fi

  # bootstrap is the single entry point for init/update/repair. The old skill
  # refused to run on an existing wiki, which left upgrades with no command at
  # all; a future edit that reintroduces the refusal fails here.
  bs="$PLUGIN_DIR/skills/bootstrap/SKILL.md"
  miss=""
  for m in init update repair; do grep -qi "\*\*$m\*\*" "$bs" || miss="$miss $m"; done
  if [ -z "$miss" ]; then ok "bootstrap routes init/update/repair"; else bad "bootstrap routes init/update/repair" "missing:$miss"; fi
  # bootstrap must diagnose through the doctor, in both directions: routing the
  # mode in step 0, and repairing the derived half in step 7.
  if grep -q 'wiki-doctor.sh"$' "$bs" && grep -q 'wiki-doctor.sh" --fix' "$bs"; then
    ok "and diagnoses and repairs through the doctor"
  else
    bad "and diagnoses and repairs through the doctor" ""
  fi
  if grep -q 'Never overwrite authored prose' "$bs"; then
    ok "while never overwriting authored prose"
  else
    bad "while never overwriting authored prose" ""
  fi
fi

# ====================================================================== report

cd "$PLUGIN_DIR" || exit 1
printf '\n%s\n' "-----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf '\nfailures:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
