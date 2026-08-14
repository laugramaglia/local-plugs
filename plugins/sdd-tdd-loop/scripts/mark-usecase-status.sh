#!/usr/bin/env bash
# Move ONE use case through the red-green-refactor states in
# tracks/<area>/use-cases.json.
#
# Usage: mark-usecase-status.sh <area> <case-id> <status>
#        mark-usecase-status.sh <area> --next            # print the next pending case
#        mark-usecase-status.sh <area> --summary         # counts per status
#
#   <case-id>  a row id from spec.md's Use cases table, e.g. RF-1.2
#   <status>   pending | red | green | refactored | blocked
#
# Why this is a script and not a jq one-liner in SKILL.md: the loop is the
# only thing that mutates run state, it does so once per transition, and the
# transition has to be legal. An agent hand-rolling `jq '.cases[0].status=...'`
# gets the index wrong on the second track it sees.
#
# Legal transitions (a DAG, no going backwards):
#   pending -> red -> green -> refactored
#   any     -> blocked        (parity divergence, or a human gate needed)
#   blocked -> red|green      (whatever it was doing when it got blocked)
# Refusing an illegal jump is the point: "green" straight from "pending" means
# no failing test was ever observed, which is the one thing a TDD loop must
# never record. That's not bookkeeping pedantry — a row that goes green
# without ever having been red is a test that never proved it tests anything.
#
# Read-only modes (--next/--summary) never write and never confirm: they're
# how the loop decides what to do next.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_tools jq || exit 1
TRACKS_DIR_REL="$(tracks_dir_rel)"

area="${1:-}"
arg2="${2:-}"
new_status="${3:-}"

if [ -z "$area" ] || [ -z "$arg2" ]; then
  echo "Usage: mark-usecase-status.sh <area> <case-id> <status>"
  echo "       mark-usecase-status.sh <area> --next"
  echo "       mark-usecase-status.sh <area> --summary"
  echo "  status: pending | red | green | refactored | blocked"
  exit 2
fi

manifest="$REPO_ROOT/$TRACKS_DIR_REL/$area/use-cases.json"
if [ ! -f "$manifest" ]; then
  echo "STOP HERE: $TRACKS_DIR_REL/$area/use-cases.json doesn't exist."
  echo "Run build-use-cases-manifest.sh $area first (it's generated from spec.md)."
  exit 1
fi
if ! jq -e . "$manifest" >/dev/null 2>&1; then
  echo "STOP HERE: $manifest is not valid JSON."
  exit 1
fi

# ------------------------------------------------------------- read-only modes

if [ "$arg2" = "--summary" ]; then
  jq -r '
    (.cases | group_by(.status) | map({key: .[0].status, value: length}) | from_entries) as $by
    | "area: \(.area)  total: \(.cases | length)"
    , "  " + ([$by | to_entries[] | "\(.key)=\(.value)"] | join("  "))
    , "  automatable pending: \([.cases[] | select(.automatable and .status == "pending")] | length)"' \
    "$manifest"
  exit 0
fi

if [ "$arg2" = "--next" ]; then
  # Only automatable rows: a manual row is QA acceptance, and handing one to
  # the loop would ask it to write a test for "se ve completo".
  next=$(jq -r '[.cases[] | select(.automatable and .status == "pending")][0] // empty' "$manifest")
  if [ -z "$next" ]; then
    echo "NONE — no automatable case left in 'pending'."
    jq -r '
      ([.cases[] | select(.automatable and .status == "blocked")] | length) as $b
      | if $b > 0 then "  (\($b) blocked — those need a human, not the loop)" else "" end' \
      "$manifest" | grep -v '^$' || true
    exit 3
  fi
  echo "$next" | jq -r '
    "NEXT \(.id)",
    "  rf:      \(.rf)",
    "  type:    \(.type)",
    "  level:   \(.level)",
    "  mode:    \(.mode)",
    "  arrange: \(.arrange)",
    "  act:     \(.act)",
    "  assert:  \(.assert)"'
  exit 0
fi

# ------------------------------------------------------------------ transition

case_id="$arg2"
if [ -z "$new_status" ]; then
  echo "Usage: mark-usecase-status.sh <area> <case-id> <status>"
  exit 2
fi

case "$new_status" in
  pending|red|green|refactored|blocked) ;;
  *)
    echo "STOP HERE: '$new_status' is not a status."
    echo "Valid: pending | red | green | refactored | blocked"
    exit 2
    ;;
esac

current=$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .status' "$manifest")

# A manifest generated before the status field existed has the case but no
# status, which surfaced as the baffling "illegal transition 'null' -> 'red'".
# Say the actual problem and the one-line fix instead: rebuilding is safe and
# non-destructive (the builder carries forward any status already recorded).
if [ "$current" = "null" ]; then
  echo "STOP HERE: $case_id has no 'status' — this use-cases.json predates the TDD loop."
  echo "Rebuild it (safe, preserves any status already recorded):"
  echo "  build-use-cases-manifest.sh $area"
  exit 1
fi

if [ -z "$current" ]; then
  echo "STOP HERE: no case '$case_id' in $TRACKS_DIR_REL/$area/use-cases.json."
  echo "Known ids:"
  jq -r '.cases[].id' "$manifest" | sed 's/^/  - /'
  exit 1
fi

automatable=$(jq -r --arg id "$case_id" '.cases[] | select(.id == $id) | .automatable' "$manifest")
if [ "$automatable" != "true" ]; then
  echo "STOP HERE: $case_id is a manual case (Level=manual) — no loop drives it."
  echo "Manual rows are QA acceptance; they stay 'pending' until a human walks them."
  exit 1
fi

legal=0
case "$current->$new_status" in
  # The happy path.
  "pending->red"|"red->green"|"green->refactored") legal=1 ;;
  # Anything can get blocked (parity divergence, missing business data, a gate).
  *"->blocked") legal=1 ;;
  # Coming back from blocked, to whatever stage it had reached.
  "blocked->red"|"blocked->green"|"blocked->refactored") legal=1 ;;
  # Idempotent re-assert: re-running a step that already landed is not an error,
  # so a retried run doesn't die on its own previous progress.
  "red->red"|"green->green"|"refactored->refactored"|"pending->pending"|"blocked->blocked") legal=1 ;;
esac

if [ "$legal" -ne 1 ]; then
  echo "STOP HERE: illegal transition for $case_id: '$current' -> '$new_status'."
  case "$current->$new_status" in
    "pending->green"|"pending->refactored")
      echo "A case cannot go green without having been red first: that records a"
      echo "test that never proved it fails, which is the one thing this loop"
      echo "exists to prevent. Write the failing test and mark it 'red' first."
      ;;
    *)
      echo "Legal: pending->red->green->refactored, anything->blocked,"
      echo "       blocked->(red|green|refactored)."
      ;;
  esac
  exit 1
fi

tmp="$manifest.tmp.$$"
jq --arg id "$case_id" --arg st "$new_status" \
  '(.cases[] | select(.id == $id) | .status) = $st
   | .summary.by_status = (.cases | group_by(.status) | map({key: .[0].status, value: length}) | from_entries)' \
  "$manifest" > "$tmp" || { echo "STOP HERE: jq failed writing $tmp"; rm -f "$tmp"; exit 1; }
mv "$tmp" "$manifest"

echo "$case_id: $current -> $new_status"
jq -r '"  remaining pending (automatable): \([.cases[] | select(.automatable and .status == "pending")] | length)"' "$manifest"
