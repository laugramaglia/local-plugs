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

check() { sh "$SCRIPTS/check-wiki.sh" "$@" 2>&1; }

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

group hygiene
if [ "$SKIP_GROUP" -eq 0 ]; then
  cd "$PLUGIN_DIR" || exit 1
  # These scripts are the offline half of the plugin: no network, no MCP, no jq.
  hits=$(grep -lE '(^|[^a-zA-Z_])(curl|wget|gh|az) ' "$SCRIPTS"/*.sh 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "no network CLI is invoked"; else bad "no network CLI is invoked" "$hits"; fi
  hits=$(grep -nE 'git (commit|push|checkout|branch|add|merge|tag)' "$SCRIPTS"/*.sh || true)
  if [ -z "$hits" ]; then ok "no git mutation anywhere"; else bad "no git mutation anywhere" "$hits"; fi

  for f in "$SCRIPTS"/*.sh; do
    head -1 "$f" | grep -q '^#!/bin/sh' || bad "shebang in $(basename "$f")" "expected POSIX sh"
  done
  ok "every script declares /bin/sh"

  for s in bootstrap feature adr derive check harvest; do
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
