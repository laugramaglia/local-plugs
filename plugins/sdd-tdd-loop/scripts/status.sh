#!/usr/bin/env bash
# One read-only picture of where everything stands: every task, the track it
# points at, and how far that track's use cases have got.
#
# Usage: status.sh [<task-id>]
#
# Why not just `task.sh list`: a task's state and its track's progress are two
# different facts that drift apart in exactly the way that matters. A task
# sitting in `implementing` whose use cases are all still `pending` means the
# loop never ran; a task in `specced` whose cases are all `refactored` means
# somebody forgot to advance it. Printing them side by side is the only way to
# see that.
#
# Read-only: no confirmation, no writes, no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

require_tools jq || exit 1

STORE="$(tasks_path)"
TRACKS_DIR_REL="$(tracks_dir_rel)"
only_id="${1#\#}"

echo "# sdd-tdd status"
echo "states:  $(states_arrow)"
echo "tasks:   $(tasks_path_rel)"
echo "tracks:  $TRACKS_DIR_REL/"
echo

if [ ! -f "$STORE" ] || ! jq -e . "$STORE" >/dev/null 2>&1; then
  echo "No readable task store yet. Create the first task:"
  echo "  task.sh new \"<title>\""
  exit 0
fi

ids=$(jq -r --arg id "$only_id" \
  'if $id == "" then .tasks[].id else (.tasks[] | select(.id == ($id | tonumber)) | .id) end' \
  "$STORE" 2>/dev/null)

if [ -z "$ids" ]; then
  if [ -n "$only_id" ]; then
    echo "STOP HERE: no task #$only_id."
    exit 1
  fi
  echo "No tasks yet."
  exit 0
fi

while IFS= read -r id; do
  [ -n "$id" ] || continue
  jq -r --argjson id "$id" '.tasks[] | select(.id == $id) |
    "## #\(.id) [\(.state)] \(.title)",
    "   area:  \(.area // "(no track linked)")   notes: \(.notes | length)"' "$STORE"

  area=$(jq -r --argjson id "$id" '.tasks[] | select(.id == $id) | .area // ""' "$STORE")
  if [ -z "$area" ]; then
    echo "   track: —"
    echo
    continue
  fi

  dir="$REPO_ROOT/$TRACKS_DIR_REL/$area"
  if [ ! -d "$dir" ]; then
    echo "   track: MISSING — $TRACKS_DIR_REL/$area doesn't exist"
    echo
    continue
  fi

  spec="present"; [ -f "$dir/spec.md" ] || spec="MISSING"
  echo "   track: $TRACKS_DIR_REL/$area  (spec.md $spec)"

  if [ ! -f "$dir/use-cases.json" ]; then
    echo "   cases: none yet — spec.md hasn't been through build-use-cases-manifest.sh"
  elif ! jq -e . "$dir/use-cases.json" >/dev/null 2>&1; then
    echo "   cases: use-cases.json is not valid JSON"
  else
    # `blocked` and `covered` each get their own line. A single "blocked=39" is
    # the exact number that made this report useless: it covered "waiting on a
    # human" and "already done, no legal state to say so" with one word. The
    # reason keys come from mark-usecase-status.sh; a manifest written before
    # they existed shows `unspecified` rather than failing to render.
    jq -r '
      (.cases | group_by(.status) | map("\(.[0].status)=\(length)") | join("  ")) as $by
      | "   cases: \(.summary.total) total (\(.summary.automatable) automatable, \(.summary.manual) manual)"
      , "          \($by)"
      , (([.cases[] | select(.status == "blocked")] | length) as $b
         | if $b > 0 then
             "          blocked: " + ([.cases[] | select(.status == "blocked")
               | (.blocked_reason.key // "unspecified")]
               | group_by(.) | map("\(.[0])=\(length)") | join("  "))
           else empty end)
      , (([.cases[] | select(.status == "covered")] | length) as $c
         | if $c > 0 then
             "          covered: \($c) row(s) satisfied by another case'"'"'s test"
           else empty end)
      , "          automatable pending: \([.cases[] | select(.automatable and .status == "pending")] | length)"' \
      "$dir/use-cases.json"
  fi
  echo
done <<< "$ids"
