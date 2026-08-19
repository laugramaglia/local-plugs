#!/usr/bin/env bash
# Offline test suite for sdd-tdd-loop. No network, no board, no git writes.
#
#   bash test/run-tests.sh
#   bash test/run-tests.sh slugify task manifest      # only matching groups
#
# Every test runs in a throwaway sandbox that is pointed at by CLAUDE_PROJECT_DIR
# and SDD_TDD_CONFIG, so the scripts resolve REPO_ROOT/CONFIG there rather than in
# this repo. Nothing in this suite touches the checkout it runs from.
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

# assert_contains <name> <haystack> <needle>
assert_contains() {
  [ "${SKIP_GROUP:-0}" -eq 0 ] || return 0
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "expected to contain '$3', got: $(printf '%s' "$2" | head -4 | tr '\n' '/')" ;; esac
}
assert_not_contains() {
  [ "${SKIP_GROUP:-0}" -eq 0 ] || return 0
  case "$2" in *"$3"*) bad "$1" "should NOT contain '$3'" ;; *) ok "$1" ;; esac
}
assert_eq() {
  [ "${SKIP_GROUP:-0}" -eq 0 ] || return 0
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}
assert_status() {
  [ "${SKIP_GROUP:-0}" -eq 0 ] || return 0
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got $2"; fi
}
assert_file() {
  [ "${SKIP_GROUP:-0}" -eq 0 ] || return 0
  if [ -f "$2" ]; then ok "$1"; else bad "$1" "no such file: $2"; fi
}

# --------------------------------------------------------------------- sandbox

SANDBOX_ROOT=$(mktemp -d)
trap 'rm -rf "$SANDBOX_ROOT"' EXIT

sandbox_n=0
# new_sandbox [config-json] — fresh repo root, exports CLAUDE_PROJECT_DIR and
# SDD_TDD_CONFIG. With no argument, no config file exists at all — which is a
# supported configuration and worth exercising.
new_sandbox() {
  sandbox_n=$((sandbox_n+1))
  SB="$SANDBOX_ROOT/sb$sandbox_n"
  mkdir -p "$SB/.claude" "$SB/tracks"
  export CLAUDE_PROJECT_DIR="$SB"
  export SDD_TDD_CONFIG="$SB/.claude/sdd-tdd-loop.json"
  unset SDD_TDD_ASSUME_YES
  # A leaked profile override is the worst kind of test pollution: it changes
  # what the probe reports without changing what any assertion says.
  unset SDD_TDD_SEAMS
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$1" > "$SDD_TDD_CONFIG"
  else
    rm -f "$SDD_TDD_CONFIG"
  fi
}

run() { "$@" 2>&1; }

# A spec.md with N requirements and parseable use case rows.
write_good_spec() {
  local area="$1"
  mkdir -p "$SB/tracks/$area"
  cat > "$SB/tracks/$area/spec.md" <<'EOF'
# demo — spec

## Functional requirements

**RF-1 — the amount stays visible with the keyboard open**

**RF-2 — a sub-minimum amount is rejected with a message**

## Test seams

seam=unit available=yes files=3 example=test/a_test.dart

## Use cases

### RF-1 — the amount stays visible

| # | Type | Level | Mode | Arrange | Act | Assert |
| --- | --- | --- | --- | --- | --- | --- |
| RF-1.1 | success | unit | red-first | viewInsets.bottom=300 | build() | amountRect.bottom <= viewport.bottom |
| RF-1.2 | success | manual | — | physical device, keyboard open | — | the amount is fully visible |

### RF-2 — sub-minimum rejected

| # | Type | Level | Mode | Arrange | Act | Assert |
| --- | --- | --- | --- | --- | --- | --- |
| RF-2.1 | error | unit | red-first | minAmount=5000, amount=3000 | submit() | state.error == "below-minimum" |

## Falsifiability

| # | Currently observed | Why the assert fails today |
| --- | --- | --- |
| RF-1.1 | the field is pushed off-screen by the keyboard | amountRect.bottom is below the viewport |
| RF-2.1 | no error is surfaced at all | state.error stays null |

## Gaps

- H-1 nothing yet
EOF
}

# A spec with several automatable red-first rows plus one characterization row —
# enough to exercise coverage chains and both loop paths in one track.
write_paths_spec() {
  local area="$1"
  mkdir -p "$SB/tracks/$area"
  cat > "$SB/tracks/$area/spec.md" <<'EOF'
# paths — spec

## Functional requirements

**RF-1 — the amount is validated**

**RF-2 — the other platform keeps working**

## Use cases

### RF-1 — validation

| # | Type | Level | Mode | Arrange | Act | Assert |
| --- | --- | --- | --- | --- | --- | --- |
| RF-1.1 | success | unit | red-first | minAmount=5000, amount=8000 | submit() | state.error == null |
| RF-1.2 | error | unit | red-first | minAmount=5000, amount=3000 | submit() | state.error == "below-minimum" |
| RF-1.3 | error | unit | red-first | minAmount=5000, amount=0 | submit() | state.error == "below-minimum" |

### RF-2 — parity

| # | Type | Level | Mode | Arrange | Act | Assert |
| --- | --- | --- | --- | --- | --- | --- |
| RF-2.1 | success | unit | characterization | legacy payload, minAmount absent | submit() | state.error == null |
| RF-2.2 | success | manual | — | physical device | — | it still looks right |

## Falsifiability

| # | Currently observed | Why the assert fails today |
| --- | --- | --- |
| RF-1.1 | submit() throws before reaching validation | there is no validator yet |
| RF-1.2 | no error is surfaced at all | state.error stays null |
| RF-1.3 | no error is surfaced at all | state.error stays null |

## Gaps

- H-1 nothing yet
EOF
}

# ========================================================================= run

group slugify
if [ "$SKIP_GROUP" -eq 0 ]; then
  s() { bash "$SCRIPTS/slugify.sh" "$@"; }
  assert_eq "folds accents"            "$(s 'Corrección visual')"                      "correccion-visual"
  assert_eq "no apostrophe artefact"   "$(s 'Corrección')"                              "correccion"
  assert_eq "lowercases and joins"     "$(s 'Loan Simulation Amount')"                  "loan-simulation-amount"
  assert_eq "collapses punctuation"    "$(s 'a -- b__c')"                               "a-b-c"
  assert_eq "empty title -> empty"     "$(s '')"                                        ""
  assert_eq "drops leading number"     "$(s --drop-leading-number '67857 - importe')"   "importe"
  assert_eq "keeps it by default"      "$(s '67857 - importe')"                         "67857-importe"
  assert_eq "first N words"            "$(s --words 2 'one two three four')"            "one-two"
  assert_eq "--area strips noise"      "$(s --area 3 '67857 - GI0219 - Corrección de visualización del importe')" "correccion-visualizacion-importe"
  assert_eq "--max cuts on a boundary" "$(s --max 12 'alpha beta gamma')"               "alpha-beta"
  assert_eq "--strip-prefix, any case" "$(s --strip-prefix 'Tracking:' 'TRACKING: importe')" "importe"
  # The output contract every caller relies on.
  out=$(s '  ***  weird 42 input  ')
  if [[ "$out" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then ok "output matches the slug contract"; else bad "output matches the slug contract" "got '$out'"; fi
fi

group task-store
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  out=$(run bash "$SCRIPTS/task.sh" list)
  assert_contains "list with no store explains itself" "$out" "No task store yet"

  out=$(run bash "$SCRIPTS/task.sh" new "Loan simulation clips the amount")
  assert_contains "new prints the id"        "$out" "TASK #1 created"
  assert_contains "new lands in first state" "$out" "state=new"
  assert_file     "store was created"        "$SB/.sdd-tdd/tasks.json"

  out=$(run bash "$SCRIPTS/task.sh" new "Second thing" --description "some detail" --area loan-simulation)
  assert_contains "ids are monotonic" "$out" "TASK #2 created"
  assert_contains "area is accepted"  "$out" "area=loan-simulation"

  out=$(run bash "$SCRIPTS/task.sh" list)
  assert_contains "list shows both"    "$out" "#1"
  assert_contains "list tallies state" "$out" "new=2"

  out=$(run bash "$SCRIPTS/task.sh" show 1)
  assert_contains "show renders title" "$out" "Loan simulation clips the amount"
  out=$(run bash "$SCRIPTS/task.sh" show '#1')
  assert_contains "show accepts #N"    "$out" "task #1"

  out=$(run bash "$SCRIPTS/task.sh" show 99)
  assert_status "unknown id fails"      "$?" 1
  assert_contains "unknown id lists known ids" "$out" "Known ids"

  # Description via file, which is how a skill passes a paragraph.
  printf 'line one\nline two\n' > "$SB/desc.md"
  out=$(run bash "$SCRIPTS/task.sh" new "From a file" --description-file "$SB/desc.md")
  id=$(printf '%s' "$out" | sed -n 's/^TASK #\([0-9]*\).*/\1/p')
  out=$(run bash "$SCRIPTS/task.sh" show "$id")
  assert_contains "--description-file is read" "$out" "line two"

  # Transitions.
  out=$(run bash "$SCRIPTS/task.sh" state 1 specced)
  assert_contains "forward move works" "$out" "#1: new -> specced"
  out=$(run bash "$SCRIPTS/task.sh" state 1 new); rc=$?
  assert_status   "backwards is refused"        "$rc" 1
  assert_contains "and says how to mean it"     "$out" "--force"
  out=$(run bash "$SCRIPTS/task.sh" state 1 new --force)
  assert_contains "--force allows it"           "$out" "#1: specced -> new"
  out=$(run bash "$SCRIPTS/task.sh" state 1 blocked)
  assert_contains "blocked from anywhere"       "$out" "#1: new -> blocked"
  out=$(run bash "$SCRIPTS/task.sh" state 1 implementing)
  assert_contains "and back out of blocked"     "$out" "#1: blocked -> implementing"
  out=$(run bash "$SCRIPTS/task.sh" state 1 implementing)
  assert_contains "same state is a no-op"       "$out" "already in 'implementing'"
  out=$(run bash "$SCRIPTS/task.sh" state 1 nonsense); rc=$?
  assert_status   "undeclared state is refused" "$rc" 1
  assert_contains "and prints the workflow"     "$out" "new -> specced -> implementing"

  # The two states the loop skills set, and the one only a human sets.
  out=$(run bash "$SCRIPTS/task.sh" state 2 specced)
  assert_contains "sdd-spec's end state"     "$out" "#2: new -> specced"
  out=$(run bash "$SCRIPTS/task.sh" state 2 verify)
  assert_contains "sdd-implement's end state" "$out" "#2: specced -> verify"
  out=$(run bash "$SCRIPTS/task.sh" state 2 done)
  assert_contains "and done, which is a human's word" "$out" "#2: verify -> done"

  # Notes.
  printf '## findings\n\nRF-1: NEW\n' > "$SB/note.md"
  out=$(run bash "$SCRIPTS/task.sh" note 1 "$SB/note.md" --title "sdd-spec")
  assert_contains "note is added"     "$out" "note added (sdd-spec"
  out=$(run bash "$SCRIPTS/task.sh" show 1)
  assert_contains "note is rendered"  "$out" "RF-1: NEW"
  printf '' > "$SB/empty.md"
  out=$(run bash "$SCRIPTS/task.sh" note 1 "$SB/empty.md"); rc=$?
  assert_status "an empty note is refused" "$rc" 1
  out=$(printf 'from stdin\n' | run bash "$SCRIPTS/task.sh" note 1 -)
  assert_contains "note reads stdin" "$out" "note added"

  # area
  out=$(run bash "$SCRIPTS/task.sh" area 1 loan-simulation)
  assert_contains "area is linked"                  "$out" "#1 area = loan-simulation"
  assert_contains "and a missing track is flagged"  "$out" "doesn't exist yet"
  out=$(run bash "$SCRIPTS/task.sh" area 1 'Not An Area'); rc=$?
  assert_status "a bad area is refused"             "$rc" 1

  # next / list filtering
  out=$(run bash "$SCRIPTS/task.sh" next --state done)
  assert_contains "next finds one in a state" "$out" "NEXT #2"
  out=$(run bash "$SCRIPTS/task.sh" next --state verify); rc=$?
  assert_status   "next exits 3 on none"      "$rc" 3
  assert_contains "and says so"               "$out" "NONE"
  out=$(run bash "$SCRIPTS/task.sh" list --state nonsense); rc=$?
  assert_status "filtering on an undeclared state fails rather than showing zero" "$rc" 1

  # remove
  out=$(run bash "$SCRIPTS/task.sh" remove 2)
  assert_contains "remove works"           "$out" "#2 deleted"
  out=$(run bash "$SCRIPTS/task.sh" show 2); rc=$?
  assert_status   "and it's gone"           "$rc" 1

  # A corrupt store must never be silently reinitialised.
  printf 'not json' > "$SB/.sdd-tdd/tasks.json"
  out=$(run bash "$SCRIPTS/task.sh" list); rc=$?
  assert_status   "a corrupt store fails loud" "$rc" 1
  assert_contains "and says which file"        "$out" "tasks.json is not valid JSON"

  # The workflow is fixed, and a config file cannot bend it: the whole point of
  # collapsing the configuration was that two projects can't disagree about what
  # `specced` means.
  new_sandbox '{"states":["todo","doing"],"wikiRoot":"business-docs/wiki"}'
  run bash "$SCRIPTS/task.sh" new "fixed" >/dev/null
  out=$(run bash "$SCRIPTS/task.sh" show 1)
  assert_contains "the first state is always 'new'"    "$out" "state:   new"
  out=$(run bash "$SCRIPTS/task.sh" state 1 doing); rc=$?
  assert_status   "a config-invented state is refused" "$rc" 1
  out=$(run bash "$SCRIPTS/task.sh" state 1 verify)
  assert_contains "the fixed workflow still applies"   "$out" "#1: new -> verify"
fi

group done-gate
if [ "$SKIP_GROUP" -eq 0 ]; then
  # No wiki: the gate must be completely absent, not merely quiet.
  new_sandbox
  run bash "$SCRIPTS/task.sh" new "no wiki here" >/dev/null
  run bash "$SCRIPTS/task.sh" state 1 verify >/dev/null
  out=$(run bash "$SCRIPTS/task.sh" state 1 done)
  assert_contains "with no wiki, done just works" "$out" "#1: verify -> done"
  assert_not_contains "and nothing mentions a delta" "$out" "wiki-delta"

  # A wiki exists: done needs evidence the wiki was considered.
  new_sandbox
  mkdir -p "$SB/business-docs/wiki/features/quiz"
  echo '# quiz' > "$SB/business-docs/wiki/features/quiz/index.md"
  run bash "$SCRIPTS/task.sh" new "sailing quiz denominator" >/dev/null
  run bash "$SCRIPTS/task.sh" state 1 verify >/dev/null
  out=$(run bash "$SCRIPTS/task.sh" state 1 done); rc=$?
  assert_status   "done is refused without a wiki delta" "$rc" 1
  assert_contains "and names the wiki"                   "$out" "business-docs/wiki"
  assert_contains "and points at harvest"                "$out" "business-wiki:harvest"
  assert_contains "and offers the explicit waiver"        "$out" "--no-wiki-delta"
  out=$(run bash "$SCRIPTS/task.sh" show 1)
  assert_contains "and the task didn't move"             "$out" "state:   verify"

  # The waiver needs a reason, and the reason is recorded.
  out=$(run bash "$SCRIPTS/task.sh" state 1 done --no-wiki-delta); rc=$?
  assert_status   "an unexplained waiver is refused" "$rc" 1
  assert_contains "and says why"                     "$out" "needs a reason"
  out=$(run bash "$SCRIPTS/task.sh" state 1 done --no-wiki-delta "pure refactor, no business rule changed")
  assert_contains "an explained waiver lets it through" "$out" "#1: verify -> done"
  out=$(run bash "$SCRIPTS/task.sh" show 1)
  assert_contains "and the waiver is on the record" "$out" "wiki-delta waived"
  assert_contains "with its reason"                 "$out" "pure refactor"

  # The note /business-wiki:harvest leaves is the evidence the gate wants.
  new_sandbox
  mkdir -p "$SB/business-docs/wiki/features/quiz"
  run bash "$SCRIPTS/task.sh" new "sailing quiz denominator" >/dev/null
  run bash "$SCRIPTS/task.sh" state 1 verify >/dev/null
  printf 'features/quiz/validations.md — unanswered questions are excluded\n' > "$SB/delta.md"
  run bash "$SCRIPTS/task.sh" note 1 "$SB/delta.md" --title "wiki-delta" >/dev/null
  out=$(run bash "$SCRIPTS/task.sh" state 1 done)
  assert_contains "a wiki-delta note satisfies the gate" "$out" "#1: verify -> done"
  assert_not_contains "with no waiver recorded"          "$out" "waived"

  # The flag belongs to the terminal state only.
  new_sandbox
  run bash "$SCRIPTS/task.sh" new "x" >/dev/null
  out=$(run bash "$SCRIPTS/task.sh" state 1 specced --no-wiki-delta "irrelevant"); rc=$?
  assert_status "--no-wiki-delta elsewhere is refused" "$rc" 1

  # A broken wiki config is not a task you can call finished.
  new_sandbox '{"wikiRequired":true}'
  run bash "$SCRIPTS/task.sh" new "x" >/dev/null
  run bash "$SCRIPTS/task.sh" state 1 verify >/dev/null
  out=$(run bash "$SCRIPTS/task.sh" state 1 done); rc=$?
  assert_status   "wikiRequired with no wiki blocks done" "$rc" 1
  assert_contains "and says the config is the problem"    "$out" "wiki configuration is broken"
fi

group scaffold-track
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  out=$(run bash "$SCRIPTS/scaffold-track.sh" loan-simulation)
  assert_contains "reports what it created" "$out" "Created: tracks/loan-simulation"
  assert_file "spec.md"     "$SB/tracks/loan-simulation/spec.md"
  assert_file "contract.md" "$SB/tracks/loan-simulation/contract.md"
  assert_file "CHANGELOG.md" "$SB/tracks/loan-simulation/CHANGELOG.md"
  assert_contains "spec has a Gaps section" "$(cat "$SB/tracks/loan-simulation/spec.md")" "## Gaps"
  assert_contains "spec has a Use cases section" "$(cat "$SB/tracks/loan-simulation/spec.md")" "## Use cases"
  # Single codebase: no per-platform parity columns to leave empty forever.
  assert_not_contains "contract has no Kotlin column here" "$(cat "$SB/tracks/loan-simulation/contract.md")" "Kotlin"

  out=$(run bash "$SCRIPTS/scaffold-track.sh" loan-simulation); rc=$?
  assert_status   "refuses to overwrite" "$rc" 1
  assert_contains "and says why"         "$out" "already exists"

  out=$(run bash "$SCRIPTS/scaffold-track.sh" 'Bad Area'); rc=$?
  assert_status "refuses a non-slug area" "$rc" 1
  out=$(run bash "$SCRIPTS/scaffold-track.sh" _lib); rc=$?
  assert_status "refuses _lib"            "$rc" 1

  out=$(run bash "$SCRIPTS/scaffold-track.sh" loan-simulation 7)
  assert_contains "a variant warns about the live track" "$out" "not a replacement"
  assert_file     "variant folder is suffixed"           "$SB/tracks/loan-simulation_7/spec.md"

  # Two native codebases: now the parity columns earn their place.
  new_sandbox
  mkdir -p "$SB/android" "$SB/ios"
  run bash "$SCRIPTS/scaffold-track.sh" accounts >/dev/null
  assert_contains "contract gains parity columns in a two-platform repo" \
    "$(cat "$SB/tracks/accounts/contract.md")" "Kotlin"
fi

group validate-spec
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  write_good_spec demo
  out=$(run bash "$SCRIPTS/validate-spec.sh" demo)
  assert_contains "a good spec passes"    "$out" "validate-spec: OK"
  assert_contains "and says why git said nothing" "$out" "nothing to compare"

  out=$(run bash "$SCRIPTS/validate-spec.sh" nosuch); rc=$?
  assert_status "a missing spec fails" "$rc" 1

  grep -v '## Gaps' "$SB/tracks/demo/spec.md" > "$SB/tracks/demo/spec.tmp" && mv "$SB/tracks/demo/spec.tmp" "$SB/tracks/demo/spec.md"
  out=$(run bash "$SCRIPTS/validate-spec.sh" demo); rc=$?
  assert_status   "no Gaps section fails" "$rc" 1
  assert_contains "and names the section" "$out" "no '## Gaps' section"

fi

group validate-use-cases
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  write_good_spec demo
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" demo)
  assert_contains "a good spec passes"          "$out" "validate-use-cases: OK"
  assert_contains "and counts the cases"        "$out" "3 use cases machine-readable"
  assert_contains "and separates manual"        "$out" "2 automatable, 1 manual"

  # A freshly scaffolded track has RF-1 only in prose. It must not be read as a
  # declared requirement — nor as a pass.
  new_sandbox
  run bash "$SCRIPTS/scaffold-track.sh" fresh >/dev/null
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" fresh); rc=$?
  assert_status   "a scaffolded-but-unwritten spec fails" "$rc" 1
  assert_contains "and says no RF is declared"            "$out" "no RF-N requirement declared"

  # A requirement with no enumerated cases.
  new_sandbox
  write_good_spec demo
  cat >> "$SB/tracks/demo/spec.md" <<'EOF'
EOF
  perl -0pi -e 's/\*\*RF-2 — a sub-minimum amount is rejected with a message\*\*/**RF-2 — a sub-minimum amount is rejected with a message**\n\n**RF-3 — nobody enumerated me**/' "$SB/tracks/demo/spec.md"
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" demo); rc=$?
  assert_status   "an unenumerated RF fails"  "$rc" 1
  assert_contains "and names it"              "$out" "RF-3 has no enumerated"

  # All-manual requirement: legal, but the human has to see it at intake.
  new_sandbox
  mkdir -p "$SB/tracks/manualonly"
  cat > "$SB/tracks/manualonly/spec.md" <<'EOF'
# manualonly — spec

## Functional requirements

**RF-1 — it looks right on a physical device**

## Use cases

| # | Type | Level | Mode | Arrange | Act | Assert |
| --- | --- | --- | --- | --- | --- | --- |
| RF-1.1 | success | manual | — | physical device | — | the amount is fully visible |

## Gaps
EOF
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" manualonly)
  assert_contains "an all-manual RF still passes" "$out" "validate-use-cases: OK"
  assert_contains "but warns loudly"              "$out" "WARNING: only manual cases for: RF-1"
fi

group falsifiability
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The gate that would have caught the ARB row at intake instead of during red.
  new_sandbox
  write_good_spec demo
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" demo)
  assert_contains "a spec with the section passes" "$out" "every red-first case states what it observes today"

  # Section removed entirely.
  new_sandbox
  write_good_spec demo
  perl -0pi -e 's/## Falsifiability.*?(?=## Gaps)//s' "$SB/tracks/demo/spec.md"
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" demo); rc=$?
  assert_status   "no Falsifiability section fails" "$rc" 1
  assert_contains "and names the section"           "$out" "no '## Falsifiability' section"

  # Section present, one red-first row unaccounted for.
  new_sandbox
  write_good_spec demo
  perl -0pi -e 's/^\| RF-2\.1 \| no error.*\n//m' "$SB/tracks/demo/spec.md"
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" demo); rc=$?
  assert_status   "a missing row fails"  "$rc" 1
  assert_contains "and names the case"   "$out" "- RF-2.1"

  # characterization and manual rows are exempt — they are not expected to fail.
  new_sandbox
  write_paths_spec paths
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" paths)
  assert_contains "characterization needs no row" "$out" "validate-use-cases: OK"
  assert_not_contains "and isn't reported missing" "$out" "RF-2.1"

  # A leftover row for a row that stopped being red-first is stale, not fatal.
  new_sandbox
  write_paths_spec paths
  perl -0pi -e 's/\| RF-1\.3 \| no error is surfaced at all \| state\.error stays null \|/| RF-1.3 | no error is surfaced at all | state.error stays null |\n| RF-2.1 | leftover | from an earlier draft |/' "$SB/tracks/paths/spec.md"
  out=$(run bash "$SCRIPTS/validate-use-cases.sh" paths)
  assert_contains "a stale row still passes" "$out" "validate-use-cases: OK"
  assert_contains "but is called out"        "$out" "aren't red-first: RF-2.1"

  # The shape heuristics: warnings, never failures.
  warn_row() {
    local name="$1" row="$2" needle="$3"
    new_sandbox
    mkdir -p "$SB/tracks/w"
    { echo '# w'; echo; echo '## Functional requirements'; echo; echo '**RF-1 — x**'; echo;
      echo '## Use cases'; echo;
      echo '| # | Type | Level | Mode | Arrange | Act | Assert |';
      echo '| --- | --- | --- | --- | --- | --- | --- |';
      echo "$row"; echo;
      echo '## Falsifiability'; echo;
      echo '| # | Currently observed | Why the assert fails today |';
      echo '| --- | --- | --- |';
      echo '| RF-1.1 | something else | because |'; echo;
      echo '## Gaps'; } > "$SB/tracks/w/spec.md"
    local o rc
    o=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" w); rc=$?
    assert_status   "$name still exits 0" "$rc" 0
    assert_contains "$name warns"         "$o" "$needle"
  }
  warn_row "an assert with no comparison" \
    '| RF-1.1 | success | unit | red-first | amount=3000 | submit() | the error shows up |' \
    "no comparison at all"
  warn_row "an assert restating arrange" \
    '| RF-1.1 | success | unit | red-first | amount=3000 | submit() | amount=3000 |' \
    "restates Arrange verbatim"
  warn_row "an expected value already in arrange" \
    '| RF-1.1 | success | unit | red-first | title="Quiz" in both locales | build() | title == "Quiz" |' \
    "can this fail?"

  # A healthy row warns about nothing, and the warnings ride inside the JSON so
  # --json stays parseable.
  new_sandbox
  write_good_spec demo
  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" demo)
  assert_not_contains "a healthy spec warns about nothing" "$out" "WARNING"
  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" demo --json)
  if printf '%s' "$out" | jq -e '.warnings == []' >/dev/null 2>&1; then
    ok "--json carries an empty warnings array"
  else
    bad "--json carries an empty warnings array" "$out"
  fi
fi

group manifest
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  write_good_spec demo
  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" demo)
  assert_contains "writes the manifest" "$out" "Wrote tracks/demo/use-cases.json"
  assert_file     "manifest exists"     "$SB/tracks/demo/use-cases.json"
  m="$SB/tracks/demo/use-cases.json"
  assert_eq "total"        "$(jq -r '.summary.total' "$m")"       "3"
  assert_eq "automatable"  "$(jq -r '.summary.automatable' "$m")" "2"
  assert_eq "manual"       "$(jq -r '.summary.manual' "$m")"      "1"
  assert_eq "rf grouping"  "$(jq -r '.summary.by_rf["RF-1"]' "$m")" "2"
  assert_eq "status starts pending" "$(jq -r '.cases[0].status' "$m")" "pending"
  assert_eq "arrange keeps real values" "$(jq -r '.cases[2].arrange' "$m")" "minAmount=5000, amount=3000"

  # Status must survive a rebuild — spec.md gaining an RF cannot reset progress.
  bash "$SCRIPTS/mark-usecase-status.sh" demo RF-1.1 red >/dev/null
  run bash "$SCRIPTS/build-use-cases-manifest.sh" demo >/dev/null
  assert_eq "rebuild carries status forward" "$(jq -r '.cases[] | select(.id=="RF-1.1") | .status' "$m")" "red"

  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" demo --check)
  assert_contains "--check doesn't write"  "$out" "not written (--check)"
  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" demo --json)
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "--json emits JSON"; else bad "--json emits JSON" "$out"; fi

  # The 7-column contract, one rejection per rule.
  reject() {
    local name="$1" row="$2"
    new_sandbox
    mkdir -p "$SB/tracks/r"
    { echo '# r'; echo; echo '## Functional requirements'; echo; echo '**RF-1 — x**'; echo;
      echo '## Use cases'; echo;
      echo '| # | Type | Level | Mode | Arrange | Act | Assert |';
      echo '| --- | --- | --- | --- | --- | --- | --- |';
      echo "$row"; echo; echo '## Gaps'; } > "$SB/tracks/r/spec.md"
    local o rc
    o=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" r); rc=$?
    if [ "$rc" -ne 0 ]; then ok "$name"; else bad "$name" "accepted: $row"; fi
  }
  reject "rejects an unknown Level"            '| RF-1.1 | success | e2e | red-first | a | b | c |'
  reject "rejects an unknown Mode"             '| RF-1.1 | success | unit | maybe | a | b | c |'
  reject "rejects manual with a real Mode"     '| RF-1.1 | success | manual | red-first | a | b | c |'
  reject "rejects a real Level with Mode —"    '| RF-1.1 | success | unit | — | a | b | c |'
  reject "rejects an empty Assert"             '| RF-1.1 | success | unit | red-first | a | b |  |'
  reject "rejects a 5-column row"              '| RF-1.1 | success | unit | red-first | a |'
  reject "rejects a section with no rows"      '| not-an-id | success | unit | red-first | a | b | c |'
fi

group usecase-status
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  write_good_spec demo
  run bash "$SCRIPTS/build-use-cases-manifest.sh" demo >/dev/null

  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo --summary)
  assert_contains "summary counts pending" "$out" "pending=3"
  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo --next)
  assert_contains "--next returns the first automatable case" "$out" "NEXT RF-1.1"
  assert_contains "with all seven columns"                    "$out" "assert:"

  # The one transition the loop must never record.
  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-1.1 green); rc=$?
  assert_status   "pending -> green is refused" "$rc" 1
  assert_contains "and explains what it means"  "$out" "without a prior observation"
  assert_contains "and offers coverage as the honest alternative" "$out" "covered --by"

  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-1.1 red)
  assert_contains "pending -> red"        "$out" "RF-1.1: pending -> red"
  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-1.1 green)
  assert_contains "red -> green"          "$out" "RF-1.1: red -> green"
  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-1.1 refactored)
  assert_contains "green -> refactored"   "$out" "RF-1.1: green -> refactored"
  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-1.1 refactored)
  assert_contains "re-asserting is idempotent, not an error" "$out" "refactored -> refactored"

  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-2.1 blocked --reason needs-business-rule)
  assert_contains "anything -> blocked"   "$out" "RF-2.1: pending -> blocked (needs-business-rule)"
  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-2.1 red)
  assert_contains "blocked -> red"        "$out" "RF-2.1: blocked -> red"
  m="$SB/tracks/demo/use-cases.json"
  assert_eq "leaving blocked drops the stale reason" \
    "$(jq -r '.cases[] | select(.id=="RF-2.1") | has("blocked_reason")' "$m")" "false"

  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-1.2 red); rc=$?
  assert_status   "a manual case is refused" "$rc" 1
  assert_contains "as QA acceptance"         "$out" "manual case"

  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-9.9 red); rc=$?
  assert_status   "an unknown case id fails" "$rc" 1
  assert_contains "and lists the real ids"   "$out" "RF-1.1"

  # RF-1.1 refactored, RF-2.1 red: nothing automatable left in pending.
  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo --next); rc=$?
  assert_status   "--next exits 3 when nothing is pending" "$rc" 3
  assert_contains "and says NONE"                          "$out" "NONE"

  new_sandbox
  write_good_spec demo
  out=$(run bash "$SCRIPTS/mark-usecase-status.sh" demo RF-1.1 red); rc=$?
  assert_status   "no manifest fails"       "$rc" 1
  assert_contains "and names the fix"       "$out" "build-use-cases-manifest.sh"
fi

group characterization
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  write_paths_spec paths
  run bash "$SCRIPTS/build-use-cases-manifest.sh" paths >/dev/null
  ms() { run bash "$SCRIPTS/mark-usecase-status.sh" paths "$@"; }

  # The characterization path, which had no legal terminal state at all before.
  out=$(ms RF-2.1 pinned)
  assert_contains "pending -> pinned"      "$out" "RF-2.1: pending -> pinned"
  out=$(ms RF-2.1 green)
  assert_contains "pinned -> green"        "$out" "RF-2.1: pinned -> green"
  out=$(ms RF-2.1 refactored)
  assert_contains "green -> refactored"    "$out" "RF-2.1: green -> refactored"

  # Each mode is refused the other's pre-state, with the reason spelled out.
  new_sandbox
  write_paths_spec paths
  run bash "$SCRIPTS/build-use-cases-manifest.sh" paths >/dev/null
  out=$(ms RF-2.1 red); rc=$?
  assert_status   "red on a characterization row is refused" "$rc" 1
  assert_contains "and points at pinned"                     "$out" "'pinned' instead"
  assert_contains "and at already-broken for a real red"     "$out" "already-broken"
  out=$(ms RF-1.1 pinned); rc=$?
  assert_status   "pinned on a red-first row is refused"     "$rc" 1
  assert_contains "and says it must be seen failing"         "$out" "observed FAILING"

  # pending -> green stays refused on BOTH paths, and the advice differs.
  out=$(ms RF-1.1 green); rc=$?
  assert_status   "red-first: pending -> green refused"   "$rc" 1
  assert_contains "and names red"                          "$out" "mark it 'red' first"
  out=$(ms RF-2.1 green); rc=$?
  assert_status   "characterization: pending -> green refused" "$rc" 1
  assert_contains "and names pinned"                       "$out" "mark it 'pinned'"

  # blocked -> pinned comes back to the characterization path, not the red one.
  out=$(ms RF-2.1 blocked --reason dirty-worktree)
  assert_contains "characterization can block"  "$out" "pending -> blocked"
  out=$(ms RF-2.1 pinned)
  assert_contains "and returns via pinned"      "$out" "blocked -> pinned"
fi

group covered
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  write_paths_spec paths
  run bash "$SCRIPTS/build-use-cases-manifest.sh" paths >/dev/null
  m="$SB/tracks/paths/use-cases.json"
  ms() { run bash "$SCRIPTS/mark-usecase-status.sh" paths "$@"; }

  # Covering against a case that never went through the loop proves nothing.
  out=$(ms RF-1.2 covered --by RF-1.1); rc=$?
  assert_status   "covering against a pending case is refused" "$rc" 1
  assert_contains "and says why"  "$out" "never went through the loop"

  ms RF-1.1 red >/dev/null; ms RF-1.1 green >/dev/null; ms RF-1.1 refactored >/dev/null

  out=$(ms RF-1.2 covered --by RF-1.1)
  assert_contains "covering against a refactored case works" "$out" "RF-1.2: pending -> covered (by RF-1.1, refactored)"
  assert_eq "and records the coverer" "$(jq -r '.cases[] | select(.id=="RF-1.2") | .covered_by' "$m")" "RF-1.1"

  out=$(ms RF-1.2 covered); rc=$?
  assert_status   "covered without --by is refused" "$rc" 1
  assert_contains "and says what --by is for"       "$out" "--by <case-id>"

  out=$(ms RF-1.3 covered --by RF-1.3); rc=$?
  assert_status "self-coverage is refused" "$rc" 1

  out=$(ms RF-1.3 covered --by RF-9.9); rc=$?
  assert_status   "an unknown coverer is refused" "$rc" 1
  assert_contains "and lists the real ids"        "$out" "RF-1.1"

  out=$(ms RF-1.3 covered --by RF-2.2); rc=$?
  assert_status   "a manual coverer is refused" "$rc" 1
  assert_contains "as it has no test"           "$out" "no test to cover anything"

  # A chain is fine (RF-1.3 -> RF-1.2 -> RF-1.1), closing it into a cycle is not.
  out=$(ms RF-1.3 covered --by RF-1.2)
  assert_contains "a coverage chain through a covered row is allowed" "$out" "RF-1.3: pending -> covered"
  out=$(ms RF-1.2 covered --by RF-1.3); rc=$?
  assert_status   "closing the chain into a cycle is refused" "$rc" 1
  assert_contains "and says no row in it has a test"          "$out" "cover each other"

  # covered is terminal: only blocked leaves it.
  out=$(ms RF-1.2 refactored); rc=$?
  assert_status   "covered -> refactored is refused" "$rc" 1
  assert_contains "and says it is terminal"          "$out" "'covered' is terminal"
  out=$(ms RF-1.2 blocked --reason spec-wrong)
  assert_contains "but blocked still leaves it"      "$out" "covered -> blocked"
  assert_eq "and the stale coverer is dropped" \
    "$(jq -r '.cases[] | select(.id=="RF-1.2") | has("covered_by")' "$m")" "false"

  # --next must never hand a covered row back to the loop.
  new_sandbox
  write_paths_spec paths
  run bash "$SCRIPTS/build-use-cases-manifest.sh" paths >/dev/null
  ms RF-1.1 red >/dev/null; ms RF-1.1 green >/dev/null; ms RF-1.1 refactored >/dev/null
  ms RF-1.2 covered --by RF-1.1 >/dev/null
  out=$(ms --next)
  assert_contains "--next skips covered rows" "$out" "NEXT RF-1.3"
  out=$(ms --summary)
  assert_contains "summary counts coverage separately" "$out" "covered=1"
  assert_contains "and says what that means"           "$out" "satisfied by another case"

  # Run state survives a rebuild — all three fields, not just status.
  ms RF-1.3 blocked --reason other "waiting on the design review" >/dev/null
  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" paths)
  assert_eq "rebuild keeps covered"      "$(jq -r '.cases[] | select(.id=="RF-1.2") | .status' "$SB/tracks/paths/use-cases.json")" "covered"
  assert_eq "rebuild keeps the coverer"  "$(jq -r '.cases[] | select(.id=="RF-1.2") | .covered_by' "$SB/tracks/paths/use-cases.json")" "RF-1.1"
  assert_eq "rebuild keeps the reason"   "$(jq -r '.cases[] | select(.id=="RF-1.3") | .blocked_reason.key' "$SB/tracks/paths/use-cases.json")" "other"
  assert_eq "and its free text"          "$(jq -r '.cases[] | select(.id=="RF-1.3") | .blocked_reason.text' "$SB/tracks/paths/use-cases.json")" "waiting on the design review"
  assert_not_contains "a healthy rebuild warns about nothing" "$out" "dangling"

  # Drop the coverer from spec.md: the surviving claim is now dangling and must
  # be reported, not silently rewritten.
  perl -0pi -e 's/^\| RF-1\.1 \|.*\n//m' "$SB/tracks/paths/spec.md"
  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" paths)
  assert_contains "a dropped coverer is reported" "$out" "dangling coverage claim"
  assert_contains "naming both rows"              "$out" "RF-1.2 is covered by RF-1.1"
fi

group blocked-reason
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  write_paths_spec paths
  run bash "$SCRIPTS/build-use-cases-manifest.sh" paths >/dev/null
  m="$SB/tracks/paths/use-cases.json"
  ms() { run bash "$SCRIPTS/mark-usecase-status.sh" paths "$@"; }

  out=$(ms RF-1.1 blocked); rc=$?
  assert_status   "reason-less blocked is refused" "$rc" 1
  assert_contains "and prints the enum"            "$out" "needs-business-rule"

  out=$(ms RF-1.1 blocked --reason nonsense); rc=$?
  assert_status   "an invented reason is refused" "$rc" 1

  out=$(ms RF-1.1 blocked --reason other); rc=$?
  assert_status   "'other' without text is refused" "$rc" 1
  assert_contains "and says so"                     "$out" "needs the free text"

  for k in missing-module wont-go-red already-broken needs-business-rule dirty-worktree spec-wrong; do
    out=$(ms RF-1.1 blocked --reason "$k")
    assert_contains "reason $k is accepted" "$out" "($k)"
  done
  out=$(ms RF-1.1 blocked --reason other "the API is down")
  assert_contains "'other' with text is accepted" "$out" "(other: the API is down)"
  assert_eq "and the text is stored" "$(jq -r '.cases[] | select(.id=="RF-1.1") | .blocked_reason.text' "$m")" "the API is down"

  # --reason and --by belong to exactly one status each.
  out=$(ms RF-1.2 red --reason spec-wrong); rc=$?
  assert_status "--reason on a non-blocked status is refused" "$rc" 1
  out=$(ms RF-1.2 red --by RF-1.1); rc=$?
  assert_status "--by on a non-covered status is refused"     "$rc" 1

  # The reason reaches both reporting surfaces.
  ms RF-1.2 blocked --reason needs-business-rule >/dev/null
  out=$(ms --summary)
  assert_contains "summary splits blocked by reason" "$out" "blocked: needs-business-rule=1"
  assert_contains "and keeps the other key"          "$out" "other=1"

  run bash "$SCRIPTS/task.sh" new "paths work" >/dev/null
  run bash "$SCRIPTS/task.sh" area 1 paths >/dev/null
  out=$(run bash "$SCRIPTS/status.sh")
  assert_contains "status.sh splits blocked too" "$out" "blocked: needs-business-rule=1"

  # A manifest written before reasons existed must still render.
  jq '(.cases[] | select(.id=="RF-1.1")) |= (.status="blocked" | del(.blocked_reason))' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  out=$(run bash "$SCRIPTS/status.sh")
  assert_contains "a pre-reason manifest shows unspecified" "$out" "unspecified=1"
fi

group locate-track
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  write_good_spec loan-simulation
  run bash "$SCRIPTS/build-use-cases-manifest.sh" loan-simulation >/dev/null
  out=$(run bash "$SCRIPTS/locate-track.sh" loan)
  assert_contains "single match"              "$out" "MATCH 'loan-simulation'"
  assert_contains "reports the shape"         "$out" "lean"
  assert_contains "and the manifest presence" "$out" "has use-cases.json"

  out=$(run bash "$SCRIPTS/locate-track.sh" nothingatall); rc=$?
  assert_status   "no match exits 3" "$rc" 3
  assert_contains "and lists folders" "$out" "loan-simulation"

  mkdir -p "$SB/tracks/loan-simulation_7"
  out=$(run bash "$SCRIPTS/locate-track.sh" loan)
  assert_contains "a family is flagged, not resolved" "$out" "MATCH FAMILY 'loan-simulation'"
  assert_contains "with a warning to confirm"         "$out" "WARNING"

  # A legacy-shaped track has a spec but no manifest, and must not read as
  # "use cases not written yet".
  new_sandbox
  mkdir -p "$SB/tracks/legacyone"
  echo '# legacyone' > "$SB/tracks/legacyone/spec.md"
  echo '{}' > "$SB/tracks/legacyone/metadata.json"
  out=$(run bash "$SCRIPTS/locate-track.sh" legacyone)
  assert_contains "legacy shape is named" "$out" "legacy"
fi

group probe-test-seams
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  mkdir -p "$SB/features/loans/test" "$SB/features/loans/lib"
  cat > "$SB/features/loans/test/amount_test.dart" <<'EOF'
void main() {
  test('amount below minimum', () { expect(1, 1); });
  testWidgets('renders', (t) async { await t.pumpWidget(App()); });
}
EOF
  echo 'class Amount {}' > "$SB/features/loans/lib/amount.dart"
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" features/loans)
  assert_contains "finds the unit seam"       "$out" "seam=unit available=yes"
  assert_contains "finds the widget seam"     "$out" "seam=widget available=yes"
  assert_contains "reports golden as absent"  "$out" "seam=golden available=no"
  assert_contains "suggests honest levels"    "$out" "Honest 'Level' values"
  assert_contains "manual is always honest"   "$out" "manual"

  out=$(run bash "$SCRIPTS/probe-test-seams.sh" nosuch/path); rc=$?
  assert_status "a bad scope fails loud rather than reporting no seams" "$rc" 1

  # A scope with no tests at all: every use case there is manual until a level is
  # introduced, and the probe has to say that rather than shrug.
  new_sandbox
  mkdir -p "$SB/features/empty"
  echo 'nothing' > "$SB/features/empty/readme.md"
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" features/empty)
  assert_contains "no suite is stated outright" "$out" "NONE"

fi

group seam-languages
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The regression this group exists for: the probe knew only Dart/Kotlin/Swift,
  # so a TypeScript package with a full vitest suite came back "no detectable
  # test suite" and intake marked every row manual. A missing ecosystem doesn't
  # weaken the answer, it inverts it.
  new_sandbox
  mkdir -p "$SB/worker/test" "$SB/worker/src"
  cat > "$SB/worker/test/grade.test.ts" <<'EOF'
import { describe, expect, it } from 'vitest';
describe('grade', () => {
  it('is false for content with no correct option', () => {
    expect(grade(null)).toBe(false);
  });
});
EOF
  echo 'export function grade(x: unknown) { return false; }' > "$SB/worker/src/grade.ts"
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" worker)
  assert_contains "a vitest suite is a unit seam"  "$out" "seam=unit available=yes"
  assert_contains "and the example is the test"    "$out" "example=worker/test/grade.test.ts"
  assert_contains "a worker has no component seam" "$out" "seam=widget available=no"
  assert_contains "unit becomes an honest Level"   "$out" "Honest 'Level' values for this scope: unit manual"

  # pytest, in two of its file spellings.
  new_sandbox
  mkdir -p "$SB/api/tests"
  printf 'def test_grade():\n    assert grade(None) is False\n' > "$SB/api/tests/test_grade.py"
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" api)
  assert_contains "pytest counts as unit" "$out" "seam=unit available=yes"

  new_sandbox
  mkdir -p "$SB/api"
  printf 'def test_grade():\n    assert True\n' > "$SB/api/grade_test.py"
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" api)
  assert_contains "so does the _test.py spelling" "$out" "seam=unit available=yes"

  # testing-library is the same seam as pumpWidget: render a tree, assert on it.
  new_sandbox
  mkdir -p "$SB/web/__tests__"
  cat > "$SB/web/__tests__/card.spec.tsx" <<'EOF'
import { render, screen } from '@testing-library/react';
it('shows the title', () => {
  render(<Card title="Quiz" />);
  expect(screen.getByText('Quiz')).toBeTruthy();
});
EOF
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" web)
  assert_contains "__tests__/*.spec.tsx is a test file" "$out" "seam=unit available=yes"
  assert_contains "testing-library is the widget seam"  "$out" "seam=widget available=yes"

  new_sandbox
  mkdir -p "$SB/web/test"
  printf "it('matches', () => { expect(x).toMatchSnapshot(); });\n" > "$SB/web/test/snap.test.js"
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" web)
  assert_contains "a snapshot assertion is the golden seam" "$out" "seam=golden available=yes"

  new_sandbox
  mkdir -p "$SB/e2e"
  printf "import { test } from '@playwright/test';\ntest('flow', async ({ page }) => { await page.setViewportSize({width: 390, height: 844}); });\n" > "$SB/e2e/flow.spec.ts"
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" e2e)
  assert_contains "playwright is the integration seam"   "$out" "seam=integration available=yes"
  assert_contains "and setViewportSize is inset control" "$out" "seam=viewport-control available=yes"

  # The invariant that makes this a probe of the VERIFICATION surface: a marker
  # in production code proves nothing about whether a test can drive it.
  new_sandbox
  mkdir -p "$SB/web/src"
  cat > "$SB/web/src/router.ts" <<'EOF'
// it('...') in a comment, and calls that end in the same two letters
export function submit(x: number) { return commit(x); }
export const wait = () => exit(0);
EOF
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" web)
  assert_contains "a marker outside a test file is not a seam" "$out" "seam=unit available=no"
  assert_contains "and the scope reports no suite"             "$out" "NONE"
fi

group seam-profile
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The profile is what makes this plugin a process rather than a language table.
  # These tests are about the resolution ORDER and about failing loud: a profile
  # that quietly falls back to the built-in default reproduces the original bug
  # invisibly — a repo probes as "no tests" and every use case becomes manual.
  new_sandbox
  out=$(run bash "$SCRIPTS/seam-profile.sh")
  assert_contains "with nothing configured, the built-in table is used" "$out" "profile=built-in default"
  assert_contains "and its origin is named"                            "$out" "origin=default"
  assert_contains "the built-in seams are the historical five"          "$out" "seams=unit widget golden integration viewport-control"
  assert_contains "manual is always a Level"                            "$out" "levels=unit widget golden integration viewport-control manual"

  # A repo profile wins, and its seam names become the Level vocabulary.
  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd"
  cat > "$SB/.claude/sdd-tdd/seams.json" <<'EOF'
{
  "testFilePattern": "(^|/)[Tt]ests?/|[Tt]ests?\\.cs$",
  "seams": [
    { "name": "unit", "globs": ["*.cs"], "marker": "\\[(Fact|Theory)" },
    { "name": "integration", "globs": ["*.cs"], "marker": "WebApplicationFactory" }
  ]
}
EOF
  out=$(run bash "$SCRIPTS/seam-profile.sh")
  assert_contains "a repo profile wins over the default" "$out" "profile=.claude/sdd-tdd/seams.json"
  assert_contains "and defines the seams"                "$out" "seams=unit integration"
  assert_contains "so the Level vocabulary is the repo's" "$out" "levels=unit integration manual"

  # The config file can carry it too, for a repo that wants one file.
  new_sandbox '{"seams":[{"name":"unit","globs":["*.rb"],"marker":"describe "}]}'
  out=$(run bash "$SCRIPTS/seam-profile.sh")
  assert_contains "the config's .seams key is honoured" "$out" "(.seams)"
  assert_contains "and its seam is the only one"        "$out" "seams=unit"

  # A profile with markers but no testFilePattern is a reasonable thing to write
  # by hand; it inherits the built-in pattern and SAYS so, because a wrong answer
  # has to stay traceable to what produced it.
  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd"
  cat > "$SB/.claude/sdd-tdd/seams.json" <<'EOF'
{"seams":[{"name":"unit","globs":["*.cs"],"marker":"Assert\\."}]}
EOF
  out=$(run bash "$SCRIPTS/seam-profile.sh")
  assert_contains "a missing testFilePattern is inherited" "$out" "note=testFilePattern inherited"

  # Every way of being wrong is a STOP, never a fallback.
  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd"
  printf 'not json at all\n' > "$SB/.claude/sdd-tdd/seams.json"
  out=$(run bash "$SCRIPTS/seam-profile.sh"); rc=$?
  assert_status "invalid JSON stops"           "$rc" 1
  assert_contains "and says which file"        "$out" ".claude/sdd-tdd/seams.json"

  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd"
  printf '{"seams":[]}\n' > "$SB/.claude/sdd-tdd/seams.json"
  out=$(run bash "$SCRIPTS/seam-profile.sh"); rc=$?
  assert_status "an empty seam list stops"                  "$rc" 1
  assert_contains "because it would make everything manual" "$out" "makes every use case manual"

  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd"
  printf '{"seams":[{"name":"Unit","globs":["*.cs"],"marker":"x"}]}\n' > "$SB/.claude/sdd-tdd/seams.json"
  out=$(run bash "$SCRIPTS/seam-profile.sh"); rc=$?
  assert_status "a name that can't be a Level stops" "$rc" 1

  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd"
  printf '{"seams":[{"name":"manual","globs":["*.cs"],"marker":"x"}]}\n' > "$SB/.claude/sdd-tdd/seams.json"
  out=$(run bash "$SCRIPTS/seam-profile.sh"); rc=$?
  assert_status "'manual' as a seam stops"          "$rc" 1
  assert_contains "no probe detects a human"        "$out" "no probe detects a human"

  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd"
  printf '{"seams":[{"name":"unit","globs":["*.cs"],"marker":"x"},{"name":"unit","globs":["*.fs"],"marker":"y"}]}\n' > "$SB/.claude/sdd-tdd/seams.json"
  out=$(run bash "$SCRIPTS/seam-profile.sh"); rc=$?
  assert_status "a repeated seam name stops" "$rc" 1
  assert_contains "and names the duplicate"  "$out" "repeats seam name(s): unit"

  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd"
  printf '{"seams":[{"name":"unit","globs":[],"marker":"x"}]}\n' > "$SB/.claude/sdd-tdd/seams.json"
  out=$(run bash "$SCRIPTS/seam-profile.sh"); rc=$?
  assert_status "a seam with no globs stops" "$rc" 1

  # Every profile the plugin ships has to resolve, and every marker has to be a
  # regex grep accepts — an invalid regex makes grep print nothing, which reads
  # exactly like "this repo has no tests".
  new_sandbox
  for pf in "$PLUGIN_DIR"/templates/seams.default.json "$PLUGIN_DIR"/templates/seam-profiles/*.json; do
    name=$(basename "$pf")
    out=$(SDD_TDD_SEAMS="$pf" run bash "$SCRIPTS/seam-profile.sh"); rc=$?
    if [ "$rc" -ne 0 ]; then bad "shipped profile $name resolves" "$out"; continue; fi
    badre=""
    while IFS= read -r re; do
      printf '' | grep -qE "$re" 2>/dev/null
      [ "$?" -gt 1 ] && badre="$badre $re"
    done < <(jq -r '(.testFilePattern // empty), .seams[].marker' "$pf")
    if [ -z "$badre" ]; then ok "shipped profile $name resolves and its regexes compile"; else bad "shipped profile $name resolves and its regexes compile" "$badre"; fi
  done
fi

group seam-csharp
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The regression that turned the marker table into data: a C# project with a
  # full xunit suite probed as "no detectable test suite", so every use case in
  # its spec was forced to manual and the loop had nothing to drive.
  new_sandbox
  mkdir -p "$SB/src/Orders" "$SB/tests/Orders.Tests"
  printf 'public class Order { public decimal Total() => 0m; }\n' > "$SB/src/Orders/Order.cs"
  cat > "$SB/tests/Orders.Tests/OrderTests.cs" <<'EOF'
public class OrderTests {
  [Fact]
  public void Total_is_zero_for_an_empty_order() { Assert.Equal(0m, new Order().Total()); }
}
EOF
  cat > "$SB/tests/Orders.Tests/CheckoutApiTests.cs" <<'EOF'
public class CheckoutApiTests : IClassFixture<WebApplicationFactory<Program>> {
  [Theory] public void Posts_a_checkout() { }
}
EOF
  out=$(run bash "$SCRIPTS/probe-test-seams.sh" .)
  assert_contains "under the built-in table a C# suite is invisible" "$out" "seam=unit available=no"
  assert_contains "and the probe blames the table, not the repo"     "$out" "run /sdd-init"

  out=$(SDD_TDD_SEAMS="$PLUGIN_DIR/templates/seam-profiles/dotnet.json" run bash "$SCRIPTS/probe-test-seams.sh" .)
  assert_contains "with the dotnet profile xunit is the unit seam" "$out" "seam=unit available=yes"
  assert_contains "WebApplicationFactory is integration"           "$out" "seam=integration available=yes"
  assert_contains "and the honest levels are real ones"            "$out" "Honest 'Level' values for this scope: unit integration manual"
  assert_contains "the profile is part of the answer"              "$out" "profile=$PLUGIN_DIR/templates/seam-profiles/dotnet.json"

  # Production C# doesn't count, same invariant as everywhere else.
  new_sandbox
  mkdir -p "$SB/src/Orders"
  printf 'public class Order { void Assert_something() { } }\n' > "$SB/src/Orders/Order.cs"
  out=$(SDD_TDD_SEAMS="$PLUGIN_DIR/templates/seam-profiles/dotnet.json" run bash "$SCRIPTS/probe-test-seams.sh" .)
  assert_contains "a marker in production C# is not a seam" "$out" "seam=unit available=no"
fi

group detect-stack
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  mkdir -p "$SB/src/Api"
  printf '<Project Sdk="Microsoft.NET.Sdk" />\n' > "$SB/src/Api/Api.csproj"
  out=$(run bash "$SCRIPTS/detect-stack.sh")
  assert_contains "a csproj is the dotnet stack" "$out" "stack=dotnet"
  assert_contains "and it names the starter profile" "$out" "profile=templates/seam-profiles/dotnet.json"
  assert_contains "one stack gets the copy-and-cut instruction" "$out" "One stack: dotnet"

  # A monorepo: the answer is one profile for the repo, probed per package.
  mkdir -p "$SB/web"
  printf '{"name":"web"}\n' > "$SB/web/package.json"
  out=$(run bash "$SCRIPTS/detect-stack.sh")
  assert_contains "both stacks are reported" "$out" "stack=ts-node"
  assert_contains "and merging is the instruction" "$out" "merge"

  # Manifests inside build output say nothing about the repo.
  new_sandbox
  mkdir -p "$SB/node_modules/dep"
  printf '{"name":"dep"}\n' > "$SB/node_modules/dep/package.json"
  out=$(run bash "$SCRIPTS/detect-stack.sh")
  assert_contains "node_modules is not a stack" "$out" "NONE of the shipped starter profiles"

  out=$(run bash "$SCRIPTS/detect-stack.sh" nosuch/path); rc=$?
  assert_status "a bad scope fails loud" "$rc" 1
fi

group init-scaffold
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  out=$(run bash "$SCRIPTS/init-scaffold.sh" --list-profiles)
  assert_contains "the shipped profiles are listed" "$out" "profile=dotnet"
  assert_contains "with the seams each one names"   "$out" "seams=unit"

  out=$(run bash "$SCRIPTS/init-scaffold.sh" --profile dotnet)
  assert_contains "it writes the repo's profile" "$out" "wrote=.claude/sdd-tdd/seams.json"
  assert_file "and the file is there" "$SB/.claude/sdd-tdd/seams.json"
  assert_contains "then reports what resolved" "$out" "origin=repo"
  # `detect` was how /sdd-init found the profile; a repo keeping it maintains a
  # field nothing reads.
  if jq -e '.detect' "$SB/.claude/sdd-tdd/seams.json" >/dev/null 2>&1; then
    bad "the detect key is stripped from a repo profile" ""
  else
    ok "the detect key is stripped from a repo profile"
  fi

  out=$(run bash "$SCRIPTS/init-scaffold.sh" --profile dotnet)
  assert_contains "a second run keeps the existing profile" "$out" "exists=.claude/sdd-tdd/seams.json"
  assert_not_contains "and writes nothing"                  "$out" "wrote=.claude/sdd-tdd/seams.json"

  out=$(run bash "$SCRIPTS/init-scaffold.sh" --profile go --force)
  assert_contains "--force replaces it" "$out" "wrote=.claude/sdd-tdd/seams.json"
  assert_contains "with the new seams"  "$out" "seams=unit integration golden"

  out=$(run bash "$SCRIPTS/init-scaffold.sh" --profile nope); rc=$?
  assert_status "an unknown profile stops"    "$rc" 1
  assert_contains "and lists the real names"  "$out" "Shipped names:"

  # A hand-written profile is a first-class input — merging is the expected move
  # in a multi-stack repo — but it's validated before it's installed.
  new_sandbox
  printf '{"seams":[]}\n' > "$SB/mine.json"
  out=$(run bash "$SCRIPTS/init-scaffold.sh" --profile mine.json); rc=$?
  assert_status "a broken hand-written profile stops before writing" "$rc" 1
  if [ -f "$SB/.claude/sdd-tdd/seams.json" ]; then bad "and nothing was written" ""; else ok "and nothing was written"; fi

  # The wiki keys: written only when there's a wiki to point at.
  new_sandbox
  out=$(run bash "$SCRIPTS/init-scaffold.sh" --profile go --wiki auto)
  assert_contains "no wiki means no config file" "$out" "wiki=none"
  if [ -f "$SB/.claude/sdd-tdd-loop.json" ]; then bad "and the config stays absent" ""; else ok "and the config stays absent"; fi

  new_sandbox
  mkdir -p "$SB/business-docs/wiki/features"
  out=$(run bash "$SCRIPTS/init-scaffold.sh" --profile go --wiki auto)
  assert_contains "an existing wiki is configured" "$out" "wrote="
  assert_eq "with its rules sibling" "$(jq -r '.rulesRoot' "$SDD_TDD_CONFIG")" "business-docs/rules"

  new_sandbox
  out=$(run bash "$SCRIPTS/init-scaffold.sh" --profile go --wiki docs/nowhere); rc=$?
  assert_status "an absent --wiki path stops rather than configuring a typo" "$rc" 1
fi

group lang-guide
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  out=$(run bash "$SCRIPTS/lang-guide.sh")
  assert_contains "no guide is reported as a count" "$out" "guides=0"
  assert_contains "and names how to get one"        "$out" "/sdd-init"

  mkdir -p "$SB/.claude/skills/sdd-lang-dotnet"
  printf -- '---\nname: sdd-lang-dotnet\n---\n' > "$SB/.claude/skills/sdd-lang-dotnet/SKILL.md"
  out=$(run bash "$SCRIPTS/lang-guide.sh")
  assert_contains "a repo-local skill is found"     "$out" "guides=1"
  assert_contains "by its repo-relative path"       "$out" "guide=.claude/skills/sdd-lang-dotnet/SKILL.md"

  # A plain file works too — the loop reads the guide, it never invokes it.
  mkdir -p "$SB/.claude/sdd-tdd"
  printf 'how tests are written here\n' > "$SB/.claude/sdd-tdd/language.md"
  out=$(run bash "$SCRIPTS/lang-guide.sh")
  assert_contains "a plain language.md counts as well" "$out" "guides=2"
fi

group manifest-levels
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The Level vocabulary is the repo's seam profile plus manual. It used to be a
  # constant in the builder, which meant a .NET repo could not name a level it
  # has and a Flutter repo could name one it doesn't.
  new_sandbox
  mkdir -p "$SB/.claude/sdd-tdd" "$SB/tracks/orders"
  cat > "$SB/.claude/sdd-tdd/seams.json" <<'EOF'
{"seams":[{"name":"unit","globs":["*.cs"],"marker":"Assert\\."},{"name":"integration","globs":["*.cs"],"marker":"WebApplicationFactory"}]}
EOF
  cat > "$SB/tracks/orders/spec.md" <<'EOF'
# orders — spec

## Functional requirements

**RF-1 — an empty order totals zero**

## Use cases

### RF-1 — an empty order totals zero

| # | Type | Level | Mode | Arrange | Act | Assert |
| --- | --- | --- | --- | --- | --- | --- |
| RF-1.1 | success | unit | red-first | a new Order with no lines | Total() | returns 0m |
| RF-1.2 | success | integration | red-first | POST /orders with no lines | the endpoint | responds 200 with total 0 |
| RF-1.3 | success | manual | — | a real browser | — | the total reads 0,00 |

## Falsifiability

| # | Currently observed | Why the assert fails today |
| --- | --- | --- |
| RF-1.1 | Total() returns null | there is no total to compare |
| RF-1.2 | the endpoint 404s | it isn't routed yet |
EOF
  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" orders --check)
  assert_contains "a Level from the repo profile validates" "$out" "OK"

  # widget is legal under the built-in default and absent from this repo's
  # profile — and that has to fail here, or intake can promise a seam nobody
  # can write a test at.
  sed -i.bak 's/| RF-1.2 | success | integration |/| RF-1.2 | success | widget |/' "$SB/tracks/orders/spec.md"
  out=$(run bash "$SCRIPTS/build-use-cases-manifest.sh" orders --check); rc=$?
  assert_status "a Level this repo has no seam for fails" "$rc" 1
  assert_contains "and the error names the profile that decided" "$out" ".claude/sdd-tdd/seams.json"
fi

group init-contract
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The split this release is about: the plugin holds the process, the repo holds
  # the language. What's testable is that the two halves are actually wired —
  # a guide nobody reads is the same as no guide, and the failure is silent.
  INIT="$PLUGIN_DIR/skills/sdd-init/SKILL.md"
  IMPL="$PLUGIN_DIR/skills/sdd-implement/SKILL.md"
  AGENT="$PLUGIN_DIR/agents/sdd-track-planner.md"

  assert_contains "sdd-init drives the detector"        "$(cat "$INIT")" "detect-stack.sh"
  assert_contains "and the scaffolder"                  "$(cat "$INIT")" "init-scaffold.sh"
  assert_contains "and proves the profile with a probe" "$(cat "$INIT")" "probe-test-seams.sh"
  assert_contains "and writes the repo-local guide"     "$(cat "$INIT")" ".claude/skills/sdd-lang-"
  # The one claim in the guide that the loop's evidence depends on.
  assert_contains "it insists the single-test command be run, not guessed" "$(cat "$INIT")" "Run it once, before writing it down"

  assert_contains "intake reads the guide"          "$(cat "$AGENT")" "lang-guide.sh"
  assert_contains "and stops on an empty probe"     "$(cat "$AGENT")" "/sdd-init"
  assert_contains "the implement loop reads it too" "$(cat "$IMPL")" "lang-guide.sh"
  assert_contains "and runs one test, not the suite" "$(cat "$IMPL")" "the ONE test, not the suite"

  # No hardcoded level list may come back: it's what made a C# repo unspeccable.
  # Comment lines are allowed to name it — the header explaining why it stopped
  # being a constant is exactly where that string belongs.
  hits=$(grep -n 'unit widget golden integration manual' "$SCRIPTS"/*.sh \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
  if [ -z "$hits" ]; then ok "no script carries a hardcoded Level list"; else bad "no script carries a hardcoded Level list" "$hits"; fi

  # The default profile has to keep the historical table, or every repo that
  # worked before this change silently starts probing as empty.
  d="$PLUGIN_DIR/templates/seams.default.json"
  assert_file "the built-in profile ships" "$d"
  assert_eq "and still names the original five seams" \
    "$(jq -r '[.seams[].name] | join(" ")' "$d")" "unit widget golden integration viewport-control"

  assert_contains "the language skill template exists and names the seam sections" \
    "$(cat "$PLUGIN_DIR/templates/lang-skill.template.md")" "One section per seam name"
fi

group commit-draft
if [ "$SKIP_GROUP" -eq 0 ]; then
  # These two scripts are the only ones that touch git for a reason other than
  # validate-spec.sh's baseline, so what's asserted here is mostly what they
  # REFUSE to do: decide a type, stage anything, or answer a question the diff
  # can't answer.
  new_sandbox
  out=$(run bash "$SCRIPTS/commit-draft.sh"); rc=$?
  assert_status "outside a git repo it stops rather than drafting" "$rc" 1
  assert_contains "and says why"                                   "$out" "not a git repository"

  new_sandbox
  git -C "$SB" init -q . 2>/dev/null
  git -C "$SB" config user.email t@t; git -C "$SB" config user.name T
  out=$(run bash "$SCRIPTS/commit-draft.sh")
  assert_contains "a clean tree is not an error" "$out" "NOTHING TO COMMIT"

  mkdir -p "$SB/plugins/one/scripts" "$SB/plugins/two"
  printf 'echo hi\n' > "$SB/plugins/one/scripts/a.sh"
  printf '# two\n' > "$SB/plugins/two/README.md"
  out=$(run bash "$SCRIPTS/commit-draft.sh")
  assert_contains "untracked work is drafted from"     "$out" "drafting-from=worktree+untracked"
  assert_contains "files are grouped by scope unit"    "$out" "group=plugins/one"
  assert_contains "and the scope candidates named"     "$out" "scope=one"
  assert_contains "two groups means propose a split"   "$out" "SPLIT:"
  assert_contains "untracked files are a question"     "$out" "in this commit, or not yet"
  # The two lines this script exists to NOT cross: it never decides the type, and
  # it never touches the index. The second is asserted against git, not against
  # the output — the draft legitimately PRINTS `git add` as advice.
  assert_contains "it never picks the type itself" "$out" "the diff can't tell these apart"
  before=$(git -C "$SB" status --porcelain)
  run bash "$SCRIPTS/commit-draft.sh" >/dev/null
  assert_eq "and drafting leaves the tree exactly as it was" "$(git -C "$SB" status --porcelain)" "$before"

  # Staged work wins: a partly staged tree is a deliberate act, and drafting from
  # everything would describe a commit the human isn't making.
  git -C "$SB" add plugins/two/README.md 2>/dev/null
  out=$(run bash "$SCRIPTS/commit-draft.sh")
  assert_contains "staged work is what gets drafted" "$out" "drafting-from=staged"
  assert_contains "only docs changed, so type=docs"  "$out" "type=docs is the honest one"
  assert_not_contains "and the unstaged group is out of scope" "$out" "group=plugins/one"

  # With a track, the draft can name the case in flight and its Assert — the one
  # sentence a subject line should be derived from.
  new_sandbox
  git -C "$SB" init -q . 2>/dev/null
  git -C "$SB" config user.email t@t; git -C "$SB" config user.name T
  write_good_spec loans
  run bash "$SCRIPTS/build-use-cases-manifest.sh" loans >/dev/null
  run bash "$SCRIPTS/mark-usecase-status.sh" loans RF-1.1 red >/dev/null
  out=$(run bash "$SCRIPTS/commit-draft.sh" loans)
  assert_contains "the track is reported"            "$out" "track=tracks/loans"
  assert_contains "with its case counts"             "$out" "cases=3"
  assert_contains "and the case in flight by id"     "$out" "RF-1.1"
  assert_contains "carrying its Assert text"         "$out" "amountRect.bottom <= viewport.bottom"

  out=$(run bash "$SCRIPTS/commit-draft.sh" nosuch); rc=$?
  assert_status "a bad area stops" "$rc" 1
fi

group pr-body
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  git -C "$SB" init -q . 2>/dev/null
  git -C "$SB" config user.email t@t; git -C "$SB" config user.name T
  write_good_spec loans
  mkdir -p "$SB/.sdd-tdd"
  printf '{"version":1,"nextId":2,"tasks":[{"id":1,"title":"keyboard overlap","state":"implementing","area":"loans"}]}\n' > "$SB/.sdd-tdd/tasks.json"
  run bash "$SCRIPTS/build-use-cases-manifest.sh" loans >/dev/null

  out=$(run bash "$SCRIPTS/pr-body.sh" loans)
  assert_contains "the title comes from the spec's H1" "$out" "the amount stays visible"
  assert_contains "and leaves the type to the human"   "$out" "title=<type>(loans)"
  assert_contains "the task is named"                  "$out" "#1 keyboard overlap — implementing"
  assert_contains "requirements are quoted verbatim"   "$out" "RF-1 — the amount stays visible with the keyboard open"
  assert_contains "the evidence table is there"        "$out" "| Case | Level | Mode | Status | Assert |"
  assert_contains "manual cases become review boxes"   "$out" "- [ ] **RF-1.2**"
  assert_contains "gaps ride along"                    "$out" "H-1"
  assert_contains "the generated region is fenced"     "$out" "<!-- sdd-tdd:begin"
  assert_contains "and closed"                         "$out" "<!-- sdd-tdd:end -->"
  # The gate: nothing is refactored yet, so this PR is not reviewable.
  assert_contains "a track mid-flight is not ready" "$out" "ready=no"

  # Ready is every automatable case refactored AND the task at verify. Both
  # halves matter: green tests are not a finished feature.
  run bash "$SCRIPTS/mark-usecase-status.sh" loans RF-1.1 red >/dev/null
  run bash "$SCRIPTS/mark-usecase-status.sh" loans RF-1.1 green >/dev/null
  run bash "$SCRIPTS/mark-usecase-status.sh" loans RF-1.1 refactored >/dev/null
  run bash "$SCRIPTS/mark-usecase-status.sh" loans RF-2.1 red >/dev/null
  run bash "$SCRIPTS/mark-usecase-status.sh" loans RF-2.1 green >/dev/null
  run bash "$SCRIPTS/mark-usecase-status.sh" loans RF-2.1 refactored >/dev/null
  out=$(run bash "$SCRIPTS/pr-body.sh" loans)
  assert_contains "cases done but task not at verify is still not ready" "$out" "not verify"

  jq '.tasks[0].state = "verify"' "$SB/.sdd-tdd/tasks.json" > "$SB/.sdd-tdd/t.json" && mv "$SB/.sdd-tdd/t.json" "$SB/.sdd-tdd/tasks.json"
  out=$(run bash "$SCRIPTS/pr-body.sh" loans)
  assert_contains "refactored plus verify is ready" "$out" "ready=yes"

  # A blocked case outranks everything: a human is needed before review.
  run bash "$SCRIPTS/mark-usecase-status.sh" loans RF-2.1 blocked --reason spec-wrong >/dev/null
  out=$(run bash "$SCRIPTS/pr-body.sh" loans)
  assert_contains "a blocked case is never ready" "$out" "blocked case(s)"
  assert_contains "and it says why in the body"    "$out" "spec-wrong"

  out=$(run bash "$SCRIPTS/pr-body.sh" nosuch); rc=$?
  assert_status "a bad area stops" "$rc" 1
fi

group commit-pr-contract
if [ "$SKIP_GROUP" -eq 0 ]; then
  # The mutating half lives in the skills, so the contract is what they promise.
  C="$PLUGIN_DIR/skills/sdd-commit/SKILL.md"
  P="$PLUGIN_DIR/skills/sdd-pr/SKILL.md"

  assert_contains "the commit skill drafts before it asks" "$(cat "$C")" "Draft first, ask second, commit third"
  assert_contains "it uses the draft script"               "$(cat "$C")" "commit-draft.sh"
  assert_contains "it stages named paths, never -A"        "$(cat "$C")" "never -A"
  assert_contains "it refuses --no-verify"                 "$(cat "$C")" "don't"
  assert_contains "and never amends a pushed commit"       "$(cat "$C")" "Never amend a commit that is already pushed"
  assert_contains "it keeps the PR current afterwards"     "$(cat "$C")" "pr-body.sh"
  assert_contains "conventional commit shape is spelled out" "$(cat "$C")" "BREAKING CHANGE"

  assert_contains "the PR opens as a draft"          "$(cat "$P")" "gh pr create --draft"
  assert_contains "the body is generated"            "$(cat "$P")" "pr-body.sh"
  assert_contains "human prose outside the markers survives" "$(cat "$P")" "sdd-tdd:begin"
  assert_contains "ready is gated on the track"      "$(cat "$P")" "ready=yes"
  assert_contains "it never merges"                  "$(cat "$P")" "**Merge.**"
  assert_contains "and never rewrites history"       "$(cat "$P")" "no force-push"
  assert_contains "a missing remote is a stop"       "$(cat "$P")" "No remote"

  # Neither skill may quietly become a task-state transition or a done gate:
  # that's what made the ancestor plugin's PR mechanics untrustworthy.
  assert_contains "the commit skill moves no task state" "$(cat "$C")" "Move a task's state"
  assert_contains "the PR skill sets nothing done"       "$(cat "$P")" "nothing here marks a task \`done\`"
fi

group wiki-config
if [ "$SKIP_GROUP" -eq 0 ]; then
  # No config and no business-docs/: a project with no wiki. Silent, not degraded.
  new_sandbox
  out=$(run bash "$SCRIPTS/wiki-config.sh")
  assert_eq       "no wiki means mode=off" "$out" "mode=off"
  assert_not_contains "and stays silent"   "$out" "WARNING"

  # The business-wiki plugin's default layout, auto-detected with no config at all.
  new_sandbox
  mkdir -p "$SB/business-docs/wiki/features/loans" "$SB/business-docs/wiki/features/accounts" "$SB/business-docs/rules"
  echo '# loans' > "$SB/business-docs/wiki/features/loans/index.md"
  echo '{}' > "$SB/business-docs/rules/loans.json"
  out=$(run bash "$SCRIPTS/wiki-config.sh")
  assert_contains "an existing wiki is auto-detected" "$out" "mode=optional"
  assert_contains "and its path reported"             "$out" "wiki=business-docs/wiki"
  assert_contains "the derived rules dir too"         "$out" "rules=business-docs/rules"
  assert_contains "and the feature count"             "$out" "features=2"

  # No rules/ yet: has a wiki, never ran /derive. Reported by omission, not faked.
  new_sandbox
  mkdir -p "$SB/business-docs/wiki/features/loans"
  out=$(run bash "$SCRIPTS/wiki-config.sh")
  assert_contains     "a wiki without derived rules still works" "$out" "mode=optional"
  assert_not_contains "and rules= is simply absent"              "$out" "rules="

  # A bootstrapped-but-unwritten wiki: "exists" and "documents anything" differ.
  new_sandbox
  mkdir -p "$SB/business-docs/wiki"
  out=$(run bash "$SCRIPTS/wiki-config.sh")
  assert_contains "an empty wiki reports features=0" "$out" "features=0"

  # A configured path wins over the default.
  new_sandbox '{"wikiRoot":"docs/business"}'
  mkdir -p "$SB/docs/business/features/x" "$SB/docs/rules"
  out=$(run bash "$SCRIPTS/wiki-config.sh")
  assert_contains "wikiRoot from config is used"      "$out" "wiki=docs/business"
  assert_contains "and rules/ is its sibling"         "$out" "rules=docs/rules"

  new_sandbox '{"wikiRoot":"docs/business","rulesRoot":"generated/rules"}'
  mkdir -p "$SB/docs/business" "$SB/generated/rules"
  out=$(run bash "$SCRIPTS/wiki-config.sh")
  assert_contains "rulesRoot can be set outright" "$out" "rules=generated/rules"

  # A configured path that isn't there is a typo, not a project without a wiki.
  new_sandbox '{"wikiRoot":"docs/typo"}'
  out=$(run bash "$SCRIPTS/wiki-config.sh" 2>&1)
  assert_contains "a configured-but-missing wiki warns" "$out" "WARNING"
  assert_contains "and degrades to off"                 "$out" "mode=off"

  # wikiRequired with no wiki is a hard stop, never a quiet downgrade.
  new_sandbox '{"wikiRequired":true}'
  out=$(run bash "$SCRIPTS/wiki-config.sh" 2>&1); rc=$?
  assert_status   "wikiRequired without a wiki fails" "$rc" 1
  assert_contains "and says how to fix it"            "$out" "business-wiki:bootstrap"

  new_sandbox '{"wikiRequired":true}'
  mkdir -p "$SB/business-docs/wiki/features/loans"
  out=$(run bash "$SCRIPTS/wiki-config.sh")
  assert_contains "wikiRequired with a wiki is mode=required" "$out" "mode=required"

  # A malformed config must not be read as "no wiki".
  new_sandbox 'not json at all'
  out=$(run bash "$SCRIPTS/wiki-config.sh"); rc=$?
  assert_status   "an unparseable config fails loud" "$rc" 1
  assert_contains "and names the file"               "$out" "not valid JSON"
fi

group wiki-lookup
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  out=$(run bash "$SCRIPTS/wiki-lookup.sh" loans); rc=$?
  assert_status   "no wiki exits 4"            "$rc" 4
  assert_contains "and says not to fake it"    "$out" "Don't substitute reading the code"

  new_sandbox
  mkdir -p "$SB/business-docs/wiki/features/loans" "$SB/business-docs/rules"
  cat > "$SB/business-docs/wiki/features/loans/validations.md" <<'EOF'
# loans — validations

| Rule | Behaviour |
| --- | --- |
| minimum amount | 5000; below it the form shows "below-minimum" |
EOF
  echo '{"minimumAmount": 5000}' > "$SB/business-docs/rules/loans.json"

  out=$(run bash "$SCRIPTS/wiki-lookup.sh" 'minimum'); rc=$?
  assert_status   "a hit exits 0"                     "$rc" 0
  assert_contains "the wiki file is named"            "$out" "features/loans/validations.md"
  assert_contains "with the matching line number"     "$out" "5000"
  assert_contains "the derived rules are searched too" "$out" "loans.json"
  # awk -F: rebuilt the line with OFS and stripped every colon, which mangled
  # exactly the tree that is all colons. The matched text must survive verbatim.
  assert_contains "matched text keeps its colons"     "$out" "\"minimumAmount\": 5000"
  assert_contains "and it asks for a reading, not a verdict" "$out" "POTENTIAL CONFLICT"

  out=$(run bash "$SCRIPTS/wiki-lookup.sh" 'nothingwhatsoever'); rc=$?
  assert_status   "no hits exits 3"                "$rc" 3
  assert_contains "and calls the requirements NEW" "$out" "NEW"

  out=$(run bash "$SCRIPTS/wiki-lookup.sh"); rc=$?
  assert_status "no keywords is a usage error" "$rc" 2

  # Case-insensitive, and several keywords are OR'd.
  out=$(run bash "$SCRIPTS/wiki-lookup.sh" MINIMUM nosuchword)
  assert_contains "keywords are case-insensitive and OR'd" "$out" "validations.md"
fi

group status
if [ "$SKIP_GROUP" -eq 0 ]; then
  new_sandbox
  out=$(run bash "$SCRIPTS/status.sh")
  assert_contains "no store is explained" "$out" "No readable task store"

  run bash "$SCRIPTS/task.sh" new "Loan simulation clips the amount" >/dev/null
  out=$(run bash "$SCRIPTS/status.sh")
  assert_contains "an unlinked task shows no track" "$out" "no track linked"

  write_good_spec loan-simulation
  run bash "$SCRIPTS/build-use-cases-manifest.sh" loan-simulation >/dev/null
  run bash "$SCRIPTS/task.sh" area 1 loan-simulation >/dev/null
  run bash "$SCRIPTS/mark-usecase-status.sh" loan-simulation RF-1.1 red >/dev/null
  out=$(run bash "$SCRIPTS/status.sh")
  assert_contains "the track is shown"          "$out" "tracks/loan-simulation  (spec.md present)"
  assert_contains "case totals"                 "$out" "3 total (2 automatable, 1 manual)"
  assert_contains "per-status breakdown"        "$out" "red=1"
  assert_contains "the number that matters"     "$out" "automatable pending: 1"

  run bash "$SCRIPTS/task.sh" area 1 typo-area >/dev/null
  out=$(run bash "$SCRIPTS/status.sh")
  assert_contains "a dangling area is called out" "$out" "track: MISSING"

  out=$(run bash "$SCRIPTS/status.sh" '#99'); rc=$?
  assert_status "an unknown id fails" "$rc" 1
fi

group hygiene
if [ "$SKIP_GROUP" -eq 0 ]; then
  # Nothing in this plugin may reach for a board, a cloud CLI, or the network:
  # that's the whole difference from the plugin it descends from. Asserted here
  # rather than trusted, because one `az` call would reintroduce the dependency
  # silently and only fail on a machine without it.
  hits=$(grep -nE '(^|[^a-zA-Z_])(az|curl|wget) ' "$SCRIPTS"/*.sh 2>/dev/null \
    | grep -vE ':[[:space:]]*#' | grep -vE 'echo "' || true)
  if [ -z "$hits" ]; then ok "no board/network CLI is invoked"; else bad "no board/network CLI is invoked" "$hits"; fi

  # git is READ in four named places and written in none.
  # `(^|space)git space` and not `.git ` — probe-test-seams.sh legitimately
  # passes --exclude-dir=.git, which a naive 'git ' match reads as a git call.
  hits=$(grep -lE '(^|[[:space:]])git[[:space:]]' "$SCRIPTS"/*.sh \
    | grep -vE '(validate-spec|_common|commit-draft|pr-body)\.sh' || true)
  if [ -z "$hits" ]; then ok "git is read only where it's declared to be"; else bad "git is read only where it's declared to be" "$hits"; fi

  # The invariant that survived /sdd-commit and /sdd-pr: no SCRIPT mutates git or
  # calls gh. Those two skills do both — in the conversation, one command at a
  # time, where a human sees `git add <paths>` before it runs. A script that
  # staged and committed on its own would be the one part of this plugin whose
  # effect nobody reviews. The message-drafting and body-rendering halves are
  # scripts precisely because they only read.
  #
  # `git add`/`git commit`/`git push` appear in these scripts' PROSE (the commands
  # they tell the caller to run), so comment and echo lines are excluded — what's
  # banned is executing one.
  hits=$(grep -nE '(^|[^#[:alnum:]])git (commit|push|checkout|switch|branch|add|merge|rebase|tag|reset|restore)' "$SCRIPTS"/*.sh \
    | grep -vE ':[[:space:]]*#' | grep -vE 'echo "' || true)
  if [ -z "$hits" ]; then ok "no script mutates git"; else bad "no script mutates git" "$hits"; fi
  hits=$(grep -nE '(^|[^a-zA-Z_])gh ' "$SCRIPTS"/*.sh | grep -vE ':[[:space:]]*#' | grep -vE 'echo "' || true)
  if [ -z "$hits" ]; then ok "no script calls gh"; else bad "no script calls gh" "$hits"; fi

  for f in "$SCRIPTS"/*.sh; do
    head -1 "$f" | grep -q '^#!/usr/bin/env bash' || bad "shebang in $(basename "$f")" ""
  done
  ok "every script declares bash"

  # One resolution path for REPO_ROOT/CONFIG. A script that re-derives them is
  # how the ancestor plugin ended up with two disagreeing implementations of the
  # same question.
  hits=$(grep -l 'REPO_ROOT=' "$SCRIPTS"/*.sh | grep -v '_common.sh' || true)
  if [ -z "$hits" ]; then ok "only _common.sh derives REPO_ROOT"; else bad "only _common.sh derives REPO_ROOT" "$hits"; fi

  # Every skill this plugin ships must be reachable and have frontmatter.
  for s in sdd-task sdd-spec sdd-implement sdd-status sdd-init sdd-commit sdd-pr; do
    f="$PLUGIN_DIR/skills/$s/SKILL.md"
    if [ -f "$f" ] && head -1 "$f" | grep -q '^---$' && grep -q "^name: $s$" "$f"; then
      ok "skill $s is well-formed"
    else
      bad "skill $s is well-formed" "$f"
    fi
  done

  # The example config must actually parse, and must not name any real project.
  if jq -e . "$PLUGIN_DIR/sdd-tdd-loop.example.json" >/dev/null 2>&1; then
    ok "the example config is valid JSON"
  else
    bad "the example config is valid JSON" ""
  fi
fi

group planner-contract
if [ "$SKIP_GROUP" -eq 0 ]; then
  # Intake is an agent now, so what's testable is the contract around it: the file
  # exists, it keeps the parts a human decision depends on, and the skill that
  # calls it doesn't quietly reimplement the procedure.
  AGENT="$PLUGIN_DIR/agents/sdd-track-planner.md"
  if [ -f "$AGENT" ] && head -1 "$AGENT" | grep -q '^---$' && grep -q '^name: sdd-track-planner$' "$AGENT"; then
    ok "the planner agent is well-formed"
  else
    bad "the planner agent is well-formed" "$AGENT"
  fi

  # It must not fan out. A citation relayed through a nested agent is a citation
  # nobody read, and the Evidence block is the whole deliverable.
  if grep -qE '^(tools|allowed-tools):.*\b(Task|Agent)\b' "$AGENT"; then
    bad "the planner agent grants no delegation tool" "$(grep -nE '^(tools|allowed-tools):' "$AGENT")"
  else
    ok "the planner agent grants no delegation tool"
  fi
  assert_contains "delegation is refused in prose too" "$(cat "$AGENT")" "You do not delegate"

  # All of intake's stops live in one place. sdd-spec used to hold them; if a copy
  # reappears there the two will disagree within a release. Eight since seam
  # profiles landed: stop 8 is "the probe found nothing under the built-in marker
  # table", which is a statement about the table and not about the repo.
  missing=""
  for n in 1 2 3 4 5 6 7 8; do
    grep -qE "^$n\. " "$AGENT" || missing="$missing $n"
  done
  if [ -z "$missing" ]; then ok "all eight stop conditions survived the move"; else bad "all eight stop conditions survived the move" "missing:$missing"; fi
  # And exactly eight. Every stop has to be one a human can act on, and the list
  # is what /sdd-spec relays verbatim — a stop nobody can name is a stop that
  # gets worked around.
  if grep -qE '^9\. ' "$AGENT"; then bad "no ninth stop condition" ""; else ok "no ninth stop condition"; fi

  # The 7-column header is a parser contract, so the example the agent copies
  # from has to be the header the builder accepts.
  assert_contains "the agent's use-case header matches the parser" "$(cat "$AGENT")" \
    '| # | Type | Level | Mode | Arrange | Act | Assert |'
  assert_contains "the agent keeps use-cases.json generated" "$(cat "$AGENT")" \
    "Hand-write \`use-cases.json\`"
  assert_contains "the agent's write scope excludes feature code" "$(cat "$AGENT")" \
    "Blast radius"
  assert_contains "research precedes the first write" "$(cat "$AGENT")" \
    "Research completes before the first Write"

  # The agent fills the scaffold's skeleton, so the section names in its template
  # have to be the ones scaffold-track.sh writes and the validators look for. A
  # template inventing its own heading produces a spec that parses as empty.
  missing=""
  for s in "Functional requirements" "Resolved contract" "Verified current state" \
           "Test seams" "Use cases" "Falsifiability" "Acceptance criteria" \
           "Out of scope" "Gaps"; do
    grep -q "^## $s$" "$AGENT" || missing="$missing [$s]"
    grep -q "^## $s\$" "$SCRIPTS/scaffold-track.sh" || missing="$missing [scaffold:$s]"
  done
  if [ -z "$missing" ]; then ok "the agent's template matches the scaffold's sections"; else bad "the agent's template matches the scaffold's sections" "$missing"; fi

  SPECSKILL="$PLUGIN_DIR/skills/sdd-spec/SKILL.md"
  assert_contains "sdd-spec spawns the planner" "$(cat "$SPECSKILL")" "sdd-track-planner"
  assert_contains "sdd-spec relays a stop instead of routing around it" "$(cat "$SPECSKILL")" "STOPPED:"
  # Silent degradation is the failure this stamp exists to prevent: an inline
  # fallback that reads exactly like an agent run.
  assert_contains "an inline fallback is stamped" "$(cat "$SPECSKILL")" "planned_by: hand"
fi

# ====================================================================== report

printf '\n%s\n' "-----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  printf '\nfailures:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
