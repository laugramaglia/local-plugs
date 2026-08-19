#!/usr/bin/env bash
# Move ONE use case through its states in tracks/<area>/use-cases.json.
#
# Usage: mark-usecase-status.sh <area> <case-id> <status> [flags]
#        mark-usecase-status.sh <area> --next            # print the next pending case
#        mark-usecase-status.sh <area> --summary         # counts per status
#
#   <case-id>  a row id from spec.md's Use cases table, e.g. RF-1.2
#   <status>   pending | red | pinned | green | refactored | covered | blocked
#
#   --by <case-id>            required for 'covered'
#   --reason <key> ["text"]   required for 'blocked'
#
# Why this is a script and not a jq one-liner in SKILL.md: the loop is the
# only thing that mutates run state, it does so once per transition, and the
# transition has to be legal. An agent hand-rolling `jq '.cases[0].status=...'`
# gets the index wrong on the second track it sees.
#
# ---------------------------------------------------------------- the two paths
#
# A case's Mode decides which path it walks, and the two are not interchangeable:
#
#   red-first        pending -> red    -> green -> refactored
#   characterization pending -> pinned -> green -> refactored
#
# Both require TWO observations of the test, before and after the change, and
# that symmetry is the point. `red` is "I watched it fail"; `pinned` is "I watched
# it pass before I touched anything". A characterization case asserts
# must-not-break behaviour, so demanding a red from it asks the loop to make a
# passing test fail — which is why `red` is refused on those rows and `pinned` is
# refused on red-first ones. Before `pinned` existed, characterization rows had no
# legal terminal state at all and got parked in `blocked`, where they read as
# "waiting on a human" while meaning "already done".
#
# Refusing an illegal jump is the point: "green" straight from "pending" means
# no failing test was ever observed, which is the one thing a TDD loop must
# never record. That's not bookkeeping pedantry — a row that goes green
# without ever having been red is a test that never proved it tests anything.
#
# ------------------------------------------------------------------ covered
#
# One edit often satisfies several enumerated cases: RF-3.1 and RF-3.4 fall to
# the same change, so RF-3.4 can never be observed red on its own. That is not a
# blockage and not a green — it's coverage, and it gets its own terminal state:
#
#   mark-usecase-status.sh <area> RF-3.4 covered --by RF-3.1
#
# `--by` must name a case that has actually been through the loop (green,
# refactored, or itself covered). Covering a row against a `pending` one proves
# exactly as much as `pending -> green` does, which is why both are refused.
# `covered` is proof that another case's test covers this row. It is NOT proof
# that a test exists for it, and the summary counts it separately so nobody reads
# it as one.
#
# ------------------------------------------------------------------ blocked
#
# `blocked` requires a reason from a closed enum, because one number covering two
# opposite meanings is how a track reports "39 blocked" and tells you nothing.
# The keys map onto /sdd-implement's stop conditions:
#
#   missing-module       the red test needs a module that doesn't exist  (stop 1)
#   wont-go-red          a red-first case passed on first run            (stop 2)
#   already-broken       a characterization case was red before any change (stop 3)
#   needs-business-rule  a limit / error code / precedence nobody wrote down (stop 4)
#   dirty-worktree       the worktree would have to be worked around     (stop 6)
#   spec-wrong           the row itself is wrong — back to intake
#   other                anything else; requires free text after the key
#
# Read-only modes (--next/--summary) never write and never confirm: they're
# how the loop decides what to do next.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_tools jq || exit 1
TRACKS_DIR_REL="$(tracks_dir_rel)"

VALID_STATUS="pending red pinned green refactored covered blocked"
VALID_REASONS="missing-module wont-go-red already-broken needs-business-rule dirty-worktree spec-wrong other"

# Statuses a `covered --by` target may hold: it must have been through the loop.
COVERABLE_BY="green refactored covered"

usage() {
  echo "Usage: mark-usecase-status.sh <area> <case-id> <status> [--by <id>] [--reason <key> [text]]"
  echo "       mark-usecase-status.sh <area> --next"
  echo "       mark-usecase-status.sh <area> --summary"
  echo "  status: $VALID_STATUS"
}

area="${1:-}"
arg2="${2:-}"
new_status="${3:-}"

if [ -z "$area" ] || [ -z "$arg2" ]; then
  usage
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

# The one renderer for "where does this track stand", shared by --summary and
# read by status.sh's own copy of the same shape. Two surfaces that count the
# same manifest differently is a bug report waiting to happen.
if [ "$arg2" = "--summary" ]; then
  jq -r '
    (.cases | group_by(.status) | map({key: .[0].status, value: length}) | from_entries) as $by
    | "area: \(.area)  total: \(.cases | length)"
    , "  " + ([$by | to_entries[] | "\(.key)=\(.value)"] | join("  "))
    , (([.cases[] | select(.status == "blocked")] | length) as $b
       | if $b > 0 then
           "  blocked: " + ([.cases[] | select(.status == "blocked")
             | (.blocked_reason.key // "unspecified")]
             | group_by(.) | map("\(.[0])=\(length)") | join("  "))
         else empty end)
    , (([.cases[] | select(.status == "covered")] | length) as $c
       | if $c > 0 then
           "  covered: \($c) row(s) satisfied by another case'"'"'s test"
         else empty end)
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
  usage
  exit 2
fi

case " $VALID_STATUS " in
  *" $new_status "*) ;;
  *)
    echo "STOP HERE: '$new_status' is not a status."
    echo "Valid: $VALID_STATUS"
    exit 2
    ;;
esac

covered_by=""
reason_key=""
reason_text=""
shift 3 2>/dev/null || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --by)
      covered_by="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --reason)
      reason_key="${2:-}"
      shift 2 2>/dev/null || shift
      # A bare word after the key is the free text `other` needs. Anything
      # starting with '-' is the next flag, not the text.
      case "${1:-}" in
        ""|-*) ;;
        *) reason_text="$1"; shift ;;
      esac
      ;;
    *)
      echo "STOP HERE: unknown argument '$1'."
      usage
      exit 2
      ;;
  esac
done

# One read of the row, not four: the fields below are all used together.
row=$(jq -c --arg id "$case_id" '.cases[] | select(.id == $id)' "$manifest")

if [ -z "$row" ]; then
  echo "STOP HERE: no case '$case_id' in $TRACKS_DIR_REL/$area/use-cases.json."
  echo "Known ids:"
  jq -r '.cases[].id' "$manifest" | sed 's/^/  - /'
  exit 1
fi

current=$(printf '%s' "$row" | jq -r '.status')
mode=$(printf '%s' "$row" | jq -r '.mode')
automatable=$(printf '%s' "$row" | jq -r '.automatable')

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

if [ "$automatable" != "true" ]; then
  echo "STOP HERE: $case_id is a manual case (Level=manual) — no loop drives it."
  echo "Manual rows are QA acceptance; they stay 'pending' until a human walks them."
  exit 1
fi

# ----------------------------------------------------------- mode-aware refusals
#
# Checked before the transition table, so `blocked -> red` on a characterization
# row gets the mode explanation rather than a generic "illegal transition".

if [ "$new_status" = "red" ] && [ "$mode" != "red-first" ]; then
  echo "STOP HERE: $case_id has Mode=$mode — it cannot be 'red'."
  echo "A characterization case asserts must-not-break behaviour: the test is green"
  echo "before the change and green after it. Record the pre-change observation with"
  echo "'pinned' instead. If it really is red before you changed anything, something"
  echo "is already broken — that's a bug report, not a step in this loop:"
  echo "  mark-usecase-status.sh $area $case_id blocked --reason already-broken"
  exit 1
fi

if [ "$new_status" = "pinned" ] && [ "$mode" != "characterization" ]; then
  echo "STOP HERE: $case_id has Mode=$mode — 'pinned' is for characterization rows."
  echo "A red-first case must be observed FAILING before the change. Use 'red'."
  exit 1
fi

# --------------------------------------------------------------- flag validation

if [ "$new_status" = "covered" ]; then
  if [ -z "$covered_by" ]; then
    echo "STOP HERE: 'covered' needs --by <case-id> naming the case whose test covers this row."
    echo "A coverage claim with no coverer is not coverage — that's a blocked case:"
    echo "  mark-usecase-status.sh $area $case_id blocked --reason other \"<why>\""
    exit 1
  fi
  if [ "$covered_by" = "$case_id" ]; then
    echo "STOP HERE: $case_id cannot be covered by itself."
    exit 1
  fi

  by_row=$(jq -c --arg id "$covered_by" '.cases[] | select(.id == $id)' "$manifest")
  if [ -z "$by_row" ]; then
    echo "STOP HERE: --by names '$covered_by', which is not a case in this track."
    echo "Known ids:"
    jq -r '.cases[].id' "$manifest" | sed 's/^/  - /'
    exit 1
  fi
  by_status=$(printf '%s' "$by_row" | jq -r '.status')
  by_automatable=$(printf '%s' "$by_row" | jq -r '.automatable')

  if [ "$by_automatable" != "true" ]; then
    echo "STOP HERE: $covered_by is a manual case — it has no test to cover anything with."
    exit 1
  fi
  case " $COVERABLE_BY " in
    *" $by_status "*) ;;
    *)
      echo "STOP HERE: $covered_by is '$by_status' — covering a case against one that"
      echo "never went through the loop proves nothing, exactly like 'pending -> green'."
      echo "Drive $covered_by to green or refactored first, then record the coverage."
      exit 1
      ;;
  esac

  # Follow the covered_by chain from the target. It can only pass through
  # `covered` rows and must end at a green/refactored one; if it comes back to
  # this case, the two rows are covering each other and neither has a test.
  hop="$covered_by"
  guard=0
  while [ -n "$hop" ]; do
    guard=$((guard + 1))
    if [ "$guard" -gt 64 ]; then
      echo "STOP HERE: the covered_by chain from $covered_by doesn't terminate."
      exit 1
    fi
    hop_row=$(jq -c --arg id "$hop" '.cases[] | select(.id == $id)' "$manifest")
    [ -n "$hop_row" ] || break
    [ "$(printf '%s' "$hop_row" | jq -r '.status')" = "covered" ] || break
    hop=$(printf '%s' "$hop_row" | jq -r '.covered_by // ""')
    if [ "$hop" = "$case_id" ]; then
      echo "STOP HERE: that would make $case_id and $covered_by cover each other."
      echo "A coverage cycle means no row in it has a test of its own."
      exit 1
    fi
  done
elif [ -n "$covered_by" ]; then
  echo "STOP HERE: --by only applies to 'covered', not '$new_status'."
  exit 1
fi

if [ "$new_status" = "blocked" ]; then
  if [ -z "$reason_key" ]; then
    echo "STOP HERE: 'blocked' needs --reason <key>."
    echo "One 'blocked' count covering several different meanings tells a human nothing."
    echo "Valid keys:"
    echo "  missing-module       the red test needs a module that doesn't exist"
    echo "  wont-go-red          a red-first case passed on first run"
    echo "  already-broken       a characterization case was red before any change"
    echo "  needs-business-rule  a limit / error code / precedence nobody wrote down"
    echo "  dirty-worktree       the worktree would have to be worked around"
    echo "  spec-wrong           the row itself is wrong — back to intake"
    echo "  other                anything else; add the free text after the key"
    exit 1
  fi
  case " $VALID_REASONS " in
    *" $reason_key "*) ;;
    *)
      echo "STOP HERE: '$reason_key' is not a blocked reason."
      echo "Valid: $VALID_REASONS"
      exit 1
      ;;
  esac
  if [ "$reason_key" = "other" ] && [ -z "$reason_text" ]; then
    echo "STOP HERE: --reason other needs the free text saying what happened."
    echo "  mark-usecase-status.sh $area $case_id blocked --reason other \"<what happened>\""
    exit 1
  fi
elif [ -n "$reason_key" ]; then
  echo "STOP HERE: --reason only applies to 'blocked', not '$new_status'."
  exit 1
fi

# ------------------------------------------------------------ transition table

legal=0
case "$current->$new_status" in
  # The two happy paths. The mode gate above already rejected the wrong one.
  "pending->red"|"pending->pinned"|"red->green"|"pinned->green"|"green->refactored") legal=1 ;;
  # Anything can get blocked (a missing rule, a missing module, a human gate).
  *"->blocked") legal=1 ;;
  # Coming back from blocked, to whatever stage it had reached.
  "blocked->red"|"blocked->pinned"|"blocked->green"|"blocked->refactored") legal=1 ;;
  # Coverage: claimable from the start or after a block, and terminal once made.
  "pending->covered"|"blocked->covered") legal=1 ;;
  # Idempotent re-assert: re-running a step that already landed is not an error,
  # so a retried run doesn't die on its own previous progress.
  "red->red"|"pinned->pinned"|"green->green"|"refactored->refactored") legal=1 ;;
  "pending->pending"|"blocked->blocked"|"covered->covered") legal=1 ;;
esac

if [ "$legal" -ne 1 ]; then
  echo "STOP HERE: illegal transition for $case_id: '$current' -> '$new_status'."
  case "$current->$new_status" in
    "pending->green"|"pending->refactored")
      echo "A case cannot go green without a prior observation of the test: that records"
      echo "a test that never proved anything, which is the one thing this loop exists"
      echo "to prevent."
      if [ "$mode" = "characterization" ]; then
        echo "This row is characterization — mark it 'pinned' (green before the change) first."
      else
        echo "Write the failing test and mark it 'red' first."
      fi
      echo "If another case's test already covers this row, that's coverage, not green:"
      echo "  mark-usecase-status.sh $area $case_id covered --by <case-id>"
      ;;
    "covered->"*)
      echo "'covered' is terminal: this row has no test of its own to advance."
      echo "Only 'blocked' leaves it — and if the coverage claim was wrong, that's"
      echo "  mark-usecase-status.sh $area $case_id blocked --reason spec-wrong"
      ;;
    *)
      echo "Legal: pending->red->green->refactored (red-first),"
      echo "       pending->pinned->green->refactored (characterization),"
      echo "       pending|blocked->covered, anything->blocked,"
      echo "       blocked->(red|pinned|green|refactored)."
      ;;
  esac
  exit 1
fi

# ------------------------------------------------------------------- write it
#
# The two side fields are cleared on any transition that isn't setting them, so a
# row that leaves `blocked` doesn't keep advertising why it once was.

tmp="$manifest.tmp.$$"
jq --arg id "$case_id" --arg st "$new_status" \
   --arg by "$covered_by" --arg rk "$reason_key" --arg rt "$reason_text" \
  '(.cases[] | select(.id == $id)) |= (
     .status = $st
     | if $st == "covered" then .covered_by = $by else del(.covered_by) end
     | if $st == "blocked"
       then .blocked_reason = ({key: $rk} + (if $rt == "" then {} else {text: $rt} end))
       else del(.blocked_reason) end
   )
   | .summary.by_status = (.cases | group_by(.status) | map({key: .[0].status, value: length}) | from_entries)' \
  "$manifest" > "$tmp" || { echo "STOP HERE: jq failed writing $tmp"; rm -f "$tmp"; exit 1; }
mv "$tmp" "$manifest"

line="$case_id: $current -> $new_status"
[ "$new_status" = "covered" ] && line="$line (by $covered_by, $by_status)"
[ "$new_status" = "blocked" ] && line="$line ($reason_key${reason_text:+: $reason_text})"
echo "$line"
jq -r '"  remaining pending (automatable): \([.cases[] | select(.automatable and .status == "pending")] | length)"' "$manifest"
