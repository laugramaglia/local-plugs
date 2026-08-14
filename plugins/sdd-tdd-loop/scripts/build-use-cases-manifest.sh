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
#   Level    the test seam: unit | widget | golden | integration | manual
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

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

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

VALID_LEVEL="unit widget golden integration manual"
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
trap 'rm -f "$rows_file" "$problems_file"' EXIT

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
    *) echo "$id: Level '$level' is not one of: $VALID_LEVEL" >> "$problems_file"; continue ;;
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
count=$(grep -c . "$rows_file" 2>/dev/null || echo 0)

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

# Carry forward any status already recorded for a row's id across a rebuild
# (e.g. spec.md gained a new RF after the loop already turned earlier rows
# green) — a case's id (RF-N.M) is stable, so re-parsing spec.md must not
# reset progress the implement loop already made on it.
prior_statuses='{}'
if [ -f "$out" ] && jq -e . "$out" >/dev/null 2>&1; then
  prior_statuses=$(jq -c '[.cases[] | {(.id): .status}] | add // {}' "$out")
fi

manifest=$(jq -s \
  --arg area "$area" \
  --arg source "$TRACKS_DIR_REL/$area/spec.md" \
  --argjson prior "$prior_statuses" \
  '{
     area: $area,
     source: $source,
     generated_by: "sdd-tdd-loop/build-use-cases-manifest.sh",
     cases: map(.status = ($prior[.id] // .status)),
     summary: {
       total: length,
       automatable: (map(select(.automatable)) | length),
       manual: (map(select(.automatable | not)) | length),
       by_level: (group_by(.level) | map({key: .[0].level, value: length}) | from_entries),
       by_mode: (group_by(.mode) | map({key: .[0].mode, value: length}) | from_entries),
       by_rf: (group_by(.rf) | map({key: .[0].rf, value: length}) | from_entries)
     }
   }' "$rows_file")

if [ "$output_mode" = "json" ]; then
  printf '%s\n' "$manifest"
  exit 0
fi
if [ "$output_mode" = "check" ]; then
  echo "$manifest" | jq -r '"OK: \(.summary.total) use cases parsed (\(.summary.automatable) automatable, \(.summary.manual) manual) — not written (--check)"'
  exit 0
fi

printf '%s\n' "$manifest" > "$out"
echo "Wrote $TRACKS_DIR_REL/$area/use-cases.json"
echo "$manifest" | jq -r '
  "  total: \(.summary.total)  automatable: \(.summary.automatable)  manual: \(.summary.manual)",
  "  by level: \(.summary.by_level | to_entries | map("\(.key)=\(.value)") | join(" "))",
  "  by mode:  \(.summary.by_mode  | to_entries | map("\(.key)=\(.value)") | join(" "))"'
