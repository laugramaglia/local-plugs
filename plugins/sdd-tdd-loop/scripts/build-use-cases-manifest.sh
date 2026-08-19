#!/usr/bin/env bash
# Derive tracks/<area>/use-cases.json from spec.md's "## Use cases" tables.
#
# Why: use cases are the handoff from this plugin to whatever implements
# the TDD loop later. A markdown table inside a prose document is a fine
# HUMAN surface and a terrible machine contract — the consumer would have to
# re-parse prose, and any column reshuffle silently changes its meaning. This
# script makes the interface explicit: markdown stays what people read and
# review in the PR, use-cases.json is what a loop consumes. Generated, never
# hand-edited; spec.md remains the single source of truth.
#
# Each case gets a `status` field (pending/red/green/refactored), defaulted to
# "pending" here and mutated afterwards only by mark-usecase-status.sh (never
# by hand, never by re-running this builder — see that script's header for why
# a second invocation of THIS script must not reset progress already made).
#
# Expected row shape (7 columns):
#   | # | Type | Level | Mode | Arrange | Act | Assert |
#
#   #        RF-N.M — stable id, the join key with the eventual test
#   Type     success | error | <any other state: pending/blocked/expired/...>
#   Level    the test seam, named by THIS repo's seam profile (see
#            seam-profile.sh) plus `manual`. With no profile that's the built-in
#            unit | widget | golden | integration | viewport-control | manual.
#            (validate against probe-test-seams.sh — a level the repo doesn't
#            have means introducing it, which belongs in Gaps)
#   Mode     red-first       — new behavior; the test must fail before the fix
#            characterization — must-not-break; green before AND after
#            —                — manual rows, which no loop will drive
#   Arrange  concrete starting state (real values, not predicates)
#   Act      what triggers it
#   Assert   the observable check, in a form an assertion can be written from
#
# Usage: build-use-cases-manifest.sh <area> [--check|--json]
#
# NOTE: the CLI flag lives in $output_mode, NOT $mode — the row parser below
# assigns $mode per row (the Mode column), so a shared name silently made
# --json behave like whatever the last row's Mode happened to be.
#   --check  validate and report a one-line summary; don't write use-cases.json
#   --json   print the manifest to stdout; don't write use-cases.json (this is
#            what validate-use-cases.sh consumes, so the two never disagree about
#            what a valid row is)
set -uo pipefail

# shellcheck source=seam-profile.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seam-profile.sh"

require_tools jq || exit 1
TRACKS_DIR_REL="$(tracks_dir_rel)"

area="${1:-}"
output_mode="write"
case "${2:-}" in
  --check) output_mode="check" ;;
  --json)  output_mode="json" ;;
  "")      ;;
  *) echo "Unknown option '${2}'. Usage: build-use-cases-manifest.sh <area> [--check|--json]"; exit 2 ;;
esac
if [ -z "$area" ]; then
  echo "Usage: build-use-cases-manifest.sh <area> [--check|--json]"
  exit 2
fi

spec="$REPO_ROOT/$TRACKS_DIR_REL/$area/spec.md"
out="$REPO_ROOT/$TRACKS_DIR_REL/$area/use-cases.json"
if [ ! -f "$spec" ]; then
  echo "FAIL: $spec doesn't exist"
  exit 1
fi

# The legal Level vocabulary is the repo's seam profile, plus manual — the same
# list probe-test-seams.sh reported at intake. It is NOT a constant here, and it
# used to be: `unit widget golden integration manual` was hardcoded, so a .NET
# repo whose seams are `unit integration golden` could not name a level it has,
# a Flutter repo could name `widget` it doesn't have, and `viewport-control` —
# which the probe has always reported — was rejected by this validator. One
# definition, in seam-profile.sh, so intake and validation cannot disagree.
seam_profile_resolve || exit 1
VALID_LEVEL="$(seam_levels)"
VALID_MODE="red-first characterization —"

# Slice out the Use cases section: from its heading to the next heading of
# the SAME level (##). Sub-headings (### RF-N) must not terminate it — that
# exact bug made validate-use-cases.sh report OK while parsing nothing.
section=$(awk '
  /^## +[Uu]se cases/ {flag=1; next}
  /^## / {if (flag) exit}
  flag
' "$spec")

if [ -z "$section" ]; then
  echo "FAIL: no '## Use cases' section found in $spec."
  exit 1
fi

rows_file=$(mktemp)
problems_file=$(mktemp)
warnings_file=$(mktemp)
trap 'rm -f "$rows_file" "$problems_file" "$warnings_file"' EXIT

# Parse the table rows. A data row starts with '|' and its first cell matches
# RF-N.M; header and separator rows therefore drop out on their own without
# needing to be recognised.
while IFS= read -r line; do
  case "$line" in
    \|*) ;;
    *) continue ;;
  esac

  # Strip the leading/trailing pipe, then split on '|'. Cell text can't
  # contain a literal '|' (it would break the markdown table too), so this
  # separator is safe here — unlike in probe-test-seams.sh, where the data
  # was regexes.
  body="${line#|}"
  body="${body%|}"
  IFS='|' read -r -a cells <<< "$body"

  trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

  id=$(trim "${cells[0]:-}")
  [[ "$id" =~ ^RF-[0-9]+\.[0-9]+$ ]] || continue

  if [ "${#cells[@]}" -lt 7 ]; then
    echo "$id: has ${#cells[@]} columns, expected 7 (# Type Level Mode Arrange Act Assert)" >> "$problems_file"
    continue
  fi

  type=$(trim "${cells[1]}")
  level=$(trim "${cells[2]}")
  mode=$(trim "${cells[3]}")
  arrange=$(trim "${cells[4]}")
  act=$(trim "${cells[5]}")
  assert=$(trim "${cells[6]}")
  rf="${id%%.*}"

  case " $VALID_LEVEL " in
    *" $level "*) ;;
    *) echo "$id: Level '$level' is not one of: $VALID_LEVEL (from $SEAM_PROFILE_LABEL)" >> "$problems_file"; continue ;;
  esac
  case " $VALID_MODE " in
    *" $mode "*) ;;
    *) echo "$id: Mode '$mode' is not one of: $VALID_MODE" >> "$problems_file"; continue ;;
  esac
  if [ "$level" = "manual" ] && [ "$mode" != "—" ]; then
    echo "$id: Level=manual must have Mode='—' (no loop will drive it), got '$mode'" >> "$problems_file"
    continue
  fi
  if [ "$level" != "manual" ] && [ "$mode" = "—" ]; then
    echo "$id: Level=$level needs a real Mode (red-first or characterization)" >> "$problems_file"
    continue
  fi
  if [ -z "$assert" ] || [ "$assert" = "-" ]; then
    echo "$id: empty Assert — nothing for a test to check" >> "$problems_file"
    continue
  fi

  # --------------------------------------------- shape checks on the assertion
  #
  # WARNINGS, never rejections. The real question — can this assertion fail
  # today? — is semantic, and no grep answers it: `quiz_main_title == "Quiz"` is
  # a perfectly-shaped assertion that cannot fail, because the string is "Quiz"
  # in both locales. That's what the spec's `## Falsifiability` section is for
  # (validate-use-cases.sh enforces it). These three heuristics only catch the
  # shapes that are suspicious on their face, and a false FAIL at intake would be
  # worse than a false warning.
  if [ "$level" != "manual" ]; then
    if ! printf '%s' "$assert" | grep -qE '(==|!=|>=|<=|<|>|\bis[A-Z]|\bcontains\b|\bthrows\b|\bequals\b|\bmatches\b|\bexcludes\b|\bnot\b)'; then
      echo "$id: Assert has no comparison at all ('$assert') — an assertion has to compare something" >> "$warnings_file"
    fi
    norm_assert=$(printf '%s' "$assert" | tr -s '[:space:]' ' ')
    norm_arrange=$(printf '%s' "$arrange" | tr -s '[:space:]' ' ')
    if [ "$norm_assert" = "$norm_arrange" ]; then
      echo "$id: Assert restates Arrange verbatim — it asserts the setup, not an outcome" >> "$warnings_file"
    else
      # A quoted expected value that is already in Arrange is usually a row
      # asserting the input it was handed.
      quoted=$(printf '%s' "$assert" | grep -oE '"[^"]+"' | head -1 | tr -d '"')
      if [ -n "$quoted" ] && printf '%s' "$arrange" | grep -qF -- "$quoted"; then
        echo "$id: Assert expects \"$quoted\", which Arrange already sets — can this fail?" >> "$warnings_file"
      fi
    fi
  fi

  automatable=true
  [ "$level" = "manual" ] && automatable=false

  jq -nc \
    --arg id "$id" --arg rf "$rf" --arg type "$type" --arg level "$level" \
    --arg mode "$mode" --arg arrange "$arrange" --arg act "$act" \
    --arg assert "$assert" --argjson automatable "$automatable" \
    '{id:$id, rf:$rf, type:$type, level:$level, mode:$mode,
      arrange:$arrange, act:$act, assert:$assert, automatable:$automatable,
      status:"pending"}' \
    >> "$rows_file"
done <<< "$section"

problems=$(cat "$problems_file")
# `grep -c` already prints a number and exits 1 on zero matches, so a
# `|| echo 0` fallback appends a SECOND line — making $count "0\n0", which
# `[ -eq 0 ]` then errors on rather than matching. That silently disabled the
# empty-parse guard below, which is the one guard that must not fail open.
count=$(grep -c . "$rows_file" 2>/dev/null)
[ -n "$count" ] || count=0

# Fail loud on an empty parse. "Found nothing, reporting OK" is the worst
# property a gate can have: it's indistinguishable from "checked everything".
if [ "$count" -eq 0 ]; then
  echo "FAIL: parsed 0 use cases rows from $spec."
  echo "      Rows must start with an RF-N.M id and have 7 columns:"
  echo "      | # | Type | Level | Mode | Arrange | Act | Assert |"
  [ -n "$problems" ] && { echo "      Rejected rows:"; echo "$problems" | sed 's/^/        /'; }
  exit 1
fi

if [ -n "$problems" ]; then
  echo "FAIL: $(echo "$problems" | grep -c .) row(s) rejected:"
  echo "$problems" | sed 's/^/  /'
  exit 1
fi

# Carry forward the run state already recorded for a row's id across a rebuild
# (e.g. spec.md gained a new RF after the loop already turned earlier rows
# green) — a case's id (RF-N.M) is stable, so re-parsing spec.md must not
# reset progress the implement loop already made on it.
#
# All three fields travel together in one `prior` object. `covered_by` and
# `blocked_reason` are as much run state as `status` is: dropping them on a
# rebuild would leave a row saying "covered" or "blocked" with the reason gone,
# which is worse than resetting it outright.
prior='{}'
if [ -f "$out" ] && jq -e . "$out" >/dev/null 2>&1; then
  prior=$(jq -c '[.cases[] | {(.id): {status, covered_by, blocked_reason}}] | add // {}' "$out")
fi

# Warnings travel INSIDE the manifest rather than on stdout/stderr, so --json
# stays parseable and every consumer (validate-use-cases.sh, a skill reading the
# file) sees the same list without re-deriving it.
warnings_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' < "$warnings_file")

manifest=$(jq -s \
  --arg area "$area" \
  --arg source "$TRACKS_DIR_REL/$area/spec.md" \
  --argjson prior "$prior" \
  --argjson warnings "$warnings_json" \
  '{
     area: $area,
     source: $source,
     generated_by: "sdd-tdd-loop/build-use-cases-manifest.sh",
     warnings: $warnings,
     cases: map(
       ($prior[.id] // {}) as $p
       | .status = ($p.status // .status)
       | if ($p.covered_by     // null) != null then .covered_by     = $p.covered_by     else . end
       | if ($p.blocked_reason // null) != null then .blocked_reason = $p.blocked_reason else . end
     ),
     summary: {
       total: length,
       automatable: (map(select(.automatable)) | length),
       manual: (map(select(.automatable | not)) | length),
       by_status: (group_by(.status) | map({key: .[0].status, value: length}) | from_entries),
       by_level: (group_by(.level) | map({key: .[0].level, value: length}) | from_entries),
       by_mode: (group_by(.mode) | map({key: .[0].mode, value: length}) | from_entries),
       by_rf: (group_by(.rf) | map({key: .[0].rf, value: length}) | from_entries)
     }
   }' "$rows_file")

# --json must emit NOTHING but the manifest, on either stream: validate-use-cases.sh
# captures it with 2>&1 and parses it, so a warning line here would read as a
# builder that "exited 0 without emitting JSON".
if [ "$output_mode" = "json" ]; then
  printf '%s\n' "$manifest"
  exit 0
fi
if [ "$output_mode" = "check" ]; then
  echo "$manifest" | jq -r '"OK: \(.summary.total) use cases parsed (\(.summary.automatable) automatable, \(.summary.manual) manual) — not written (--check)"'
  exit 0
fi

printf '%s\n' "$manifest" > "$out"

# A rebuild can drop the row a surviving `covered` claim points at — spec.md
# deleted RF-3.1 while RF-3.4 was recorded as covered by it. The claim is now
# dangling: RF-3.4 says a test covers it and there is no such case. Report it and
# name both ids; don't silently rewrite the row, because which of the two the
# human meant to keep is not derivable here.
echo "Wrote $TRACKS_DIR_REL/$area/use-cases.json"
echo "$manifest" | jq -r '
  "  total: \(.summary.total)  automatable: \(.summary.automatable)  manual: \(.summary.manual)",
  "  by level: \(.summary.by_level | to_entries | map("\(.key)=\(.value)") | join(" "))",
  "  by mode:  \(.summary.by_mode  | to_entries | map("\(.key)=\(.value)") | join(" "))"'
if [ -s "$warnings_file" ]; then
  echo "WARNING: $(grep -c . "$warnings_file") row(s) with a suspicious assertion:"
  sed 's/^/  /' "$warnings_file"
fi

dangling=$(jq -r '
  (.cases | map(.id)) as $ids
  | [.cases[] | select(.status == "covered")
     | select((.covered_by // "") as $b | ($ids | index($b)) == null)
     | "\(.id) is covered by \(.covered_by // "(nothing)"), which no longer exists"]
  | .[]' "$out")
if [ -n "$dangling" ]; then
  echo "WARNING: dangling coverage claim(s) after this rebuild:"
  printf '%s\n' "$dangling" | sed 's/^/  /'
  echo "  Re-point or re-open those rows with mark-usecase-status.sh."
fi
