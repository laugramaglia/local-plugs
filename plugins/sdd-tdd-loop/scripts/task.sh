#!/usr/bin/env bash
# The local task store — this plugin's replacement for a board.
#
# Usage:
#   task.sh new <title> [--description-file <path>|--description <text>]
#                       [--area <slug>] [--state <key>]
#   task.sh list [--state <key>] [--json]
#   task.sh show <id> [--json]
#   task.sh state <id> <state> [--force]
#   task.sh area  <id> <area-slug>
#   task.sh note  <id> <file|-> [--title <heading>]
#   task.sh next  [--state <key>]
#   task.sh remove <id>
#
# <id> may be given as `3` or `#3`.
#
# Why a script and not "the agent edits the JSON": the store is the one piece of
# shared, ordered state in the loop. An agent hand-rolling
# `jq '.tasks[0].state="done"'` gets the index wrong on the second task it sees,
# and nothing stops it moving a task backwards or into a state the project never
# declared. The transition rule below is the whole reason this file exists.
#
# Transitions are forward-only along the fixed workflow (see _common.sh), plus
# `blocked` as an escape hatch from and back to anywhere. A backwards move needs
# --force — reopening work is a real thing, but it should be a decision, not a
# typo.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

require_tools jq || exit 1

STORE="$(tasks_path)"
STORE_REL="$(tasks_path_rel)"

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ------------------------------------------------------------------ store I/O

ensure_store() {
  if [ -f "$STORE" ]; then
    if ! jq -e . "$STORE" >/dev/null 2>&1; then
      # stderr, because every caller redirects ensure_store's chatter to
      # /dev/null to suppress the "created" notice — and a corrupt store must
      # never be one of the things that suppresses.
      echo "STOP HERE: $STORE_REL is not valid JSON. Fix or delete it; nothing else in" >&2
      echo "this plugin will touch it while it can't be read." >&2
      return 1
    fi
    return 0
  fi
  mkdir -p "$(dirname "$STORE")" || return 1
  printf '%s\n' '{"version":1,"nextId":1,"tasks":[]}' > "$STORE"
  echo "Created $STORE_REL (empty task store)."
  return 0
}

# write_store <json> — atomic: a half-written store is worse than none, because
# the next read reports "not valid JSON" on data that was fine a second ago.
write_store() {
  local json="$1" tmp="$STORE.tmp.$$"
  printf '%s\n' "$json" | jq -e . > "$tmp" 2>/dev/null || {
    echo "STOP HERE: refusing to write invalid JSON to $STORE_REL."
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$STORE"
}

norm_id() { printf '%s' "${1#\#}"; }

task_json() {
  jq -c --argjson id "$1" '.tasks[] | select(.id == $id)' "$STORE" 2>/dev/null
}

require_task() {
  local id="$1"
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "STOP HERE: '$id' is not a task id (expected a number, e.g. 3 or #3)."
    return 1
  fi
  if [ -z "$(task_json "$id")" ]; then
    echo "STOP HERE: no task #$id in $STORE_REL."
    echo "Known ids:"
    jq -r '.tasks[] | "  - #\(.id) [\(.state)] \(.title)"' "$STORE" 2>/dev/null
    return 1
  fi
  return 0
}

render_task() {
  jq -r --argjson id "$1" '
    .tasks[] | select(.id == $id) |
    "# task #\(.id) — \(.title)",
    "",
    "state:   \(.state)",
    "area:    \(.area // "(none — no track linked yet)")",
    "created: \(.createdAt)",
    "updated: \(.updatedAt)",
    "",
    "## description",
    "",
    (if (.description // "") == "" then "(none)" else .description end),
    "",
    "## notes (\(.notes | length))",
    "",
    (if (.notes | length) == 0 then "(none)"
     else (.notes | map("### \(.title // "note") — \(.at)\n\n\(.text)") | join("\n\n"))
     end)' "$STORE"
}

# ------------------------------------------------------------------- commands

cmd_new() {
  local title="" description="" area="" state=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --description)      description="${2:-}"; shift 2 ;;
      --description-file) description=$(cat "${2:-}" 2>/dev/null) || {
                            echo "STOP HERE: can't read ${2:-}"; return 1; }
                          shift 2 ;;
      --area)             area="${2:-}"; shift 2 ;;
      --state)            state="${2:-}"; shift 2 ;;
      -*) echo "Unknown option '$1'."; return 2 ;;
      *)  [ -z "$title" ] && title="$1" || title="$title $1"; shift ;;
    esac
  done

  if [ -z "$title" ]; then
    echo "STOP HERE: a task needs a title."
    echo "Usage: task.sh new <title> [--description-file <path>] [--area <slug>]"
    return 2
  fi

  [ -z "$state" ] && state="$(first_state)"
  if ! state_exists "$state"; then
    echo "STOP HERE: '$state' is not a state. The workflow is: $(states_arrow)"
    return 1
  fi
  if [ -n "$area" ] && ! [[ "$area" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "STOP HERE: area '$area' doesn't match ^[a-z][a-z0-9-]*\$."
    return 1
  fi

  ensure_store || return 1

  local id now updated
  id=$(jq -r '.nextId' "$STORE")
  now="$(now_utc)"
  updated=$(jq \
    --argjson id "$id" --arg title "$title" --arg state "$state" \
    --arg area "$area" --arg desc "$description" --arg now "$now" \
    '.nextId = ($id + 1)
     | .tasks += [{
         id: $id, title: $title, state: $state,
         area: (if $area == "" then null else $area end),
         description: $desc, createdAt: $now, updatedAt: $now, notes: []
       }]' "$STORE") || return 1
  write_store "$updated" || return 1

  echo "TASK #$id created — state=$state${area:+ area=$area}"
  echo "  $title"
  echo "  store: $STORE_REL"
}

cmd_list() {
  local want_state="" as_json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) want_state="${2:-}"; shift 2 ;;
      --json)  as_json=1; shift ;;
      *) echo "Unknown option '$1'."; return 2 ;;
    esac
  done
  if [ ! -f "$STORE" ]; then
    echo "No task store yet ($STORE_REL). Create the first task with:"
    echo "  task.sh new \"<title>\""
    return 0
  fi
  ensure_store >/dev/null || return 1

  if [ -n "$want_state" ] && ! state_exists "$want_state"; then
    # A filter on a state the project never declared returns zero tasks, which
    # is indistinguishable from "nothing to do". Fail loud instead.
    echo "STOP HERE: '$want_state' is not a state. The workflow is: $(states_arrow)"
    return 1
  fi

  local filter='.tasks'
  [ -n "$want_state" ] && filter='[.tasks[] | select(.state == $s)]'

  if [ "$as_json" -eq 1 ]; then
    jq --arg s "$want_state" "$filter" "$STORE"
    return 0
  fi

  local count
  count=$(jq --arg s "$want_state" "$filter | length" "$STORE")
  if [ "$count" -eq 0 ]; then
    echo "NONE — no tasks${want_state:+ in state '$want_state'}."
    return 0
  fi
  jq -r --arg s "$want_state" "$filter"' | .[] |
    "#\(.id)\t[\(.state)]\t\(.area // "-")\t\(.title)"' "$STORE" \
    | column -t -s $'\t' 2>/dev/null \
    || jq -r --arg s "$want_state" "$filter"' | .[] | "#\(.id) [\(.state)] \(.area // "-") \(.title)"' "$STORE"
  echo
  jq -r '.tasks | group_by(.state) | map("\(.[0].state)=\(length)") | "by state: " + join("  ")' "$STORE"
}

cmd_show() {
  local id as_json=0
  id="$(norm_id "${1:-}")"; shift || true
  [ "${1:-}" = "--json" ] && as_json=1
  ensure_store >/dev/null || return 1
  require_task "$id" || return 1
  if [ "$as_json" -eq 1 ]; then
    task_json "$id" | jq .
  else
    render_task "$id"
  fi
}

cmd_state() {
  local id target force=0 waive=0 waive_reason="" record_waiver=0
  id="$(norm_id "${1:-}")"
  target="${2:-}"
  shift 2 2>/dev/null || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)          force=1; shift ;;
      --no-wiki-delta)  waive=1; waive_reason="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) echo "Unknown option '$1'."; return 2 ;;
    esac
  done

  if [ -z "$id" ] || [ -z "$target" ]; then
    echo "Usage: task.sh state <id> <state> [--force] [--no-wiki-delta \"<reason>\"]"
    return 2
  fi
  ensure_store >/dev/null || return 1
  require_task "$id" || return 1

  if ! state_exists "$target"; then
    echo "STOP HERE: '$target' is not a state. The workflow is:"
    echo "  $(states_arrow)"
    return 1
  fi

  local current ci ti
  current=$(task_json "$id" | jq -r '.state')
  if [ "$current" = "$target" ]; then
    echo "#$id is already in '$target' — nothing to do."
    return 0
  fi

  ci=$(state_index "$current"); ti=$(state_index "$target")
  local legal=0
  if [ "$target" = "blocked" ] || [ "$current" = "blocked" ]; then
    legal=1
  elif [ -n "$ci" ] && [ -n "$ti" ] && [ "$ti" -gt "$ci" ]; then
    legal=1
  fi

  if [ "$legal" -ne 1 ] && [ "$force" -ne 1 ]; then
    echo "STOP HERE: '$current' -> '$target' moves #$id backwards through"
    echo "  $(states_arrow)"
    echo "Reopening work is legitimate, but it should be deliberate: re-run with"
    echo "--force if that's what you mean."
    return 1
  fi

  # ------------------------------------------------------ the wiki delta gate
  #
  # Reaching the terminal state on a project WITH a business wiki, having changed
  # nothing in it, is the seam these two plugins used to leave open: the closeout
  # was mandatory only because CLAUDE.md said so, and nothing structural noticed
  # when it was skipped. Only the last state is gated, and only when a wiki is
  # actually configured — `mode=off` is a supported project shape and must stay
  # completely silent here.
  if [ "$target" = "$(last_state)" ]; then
    local wiki_mode="" wiki_path="" wiki_conf=""
    if wiki_conf=$(bash "$SCRIPT_DIR/wiki-config.sh" 2>/dev/null); then
      wiki_mode=$(printf '%s\n' "$wiki_conf" | sed -n 's/^mode=//p')
      wiki_path=$(printf '%s\n' "$wiki_conf" | sed -n 's/^wiki=//p')
    else
      # wikiRequired with no wiki. That's a hard stop for the whole workflow, so
      # it certainly isn't a task you can call finished.
      echo "STOP HERE: the wiki configuration is broken, so '$target' can't be verified:"
      bash "$SCRIPT_DIR/wiki-config.sh" 2>&1 | sed -n 's/^STOP HERE: /  /p'
      return 1
    fi

    if [ -n "$wiki_mode" ] && [ "$wiki_mode" != "off" ]; then
      local has_delta
      has_delta=$(task_json "$id" | jq -r '[.notes[]? | select(.title == "wiki-delta")] | length')
      if [ "${has_delta:-0}" -eq 0 ] && [ "$waive" -eq 0 ]; then
        echo "STOP HERE: #$id has no 'wiki-delta' note and this project has a wiki ($wiki_path)."
        echo "Work that changed business behaviour and left the wiki untouched is work"
        echo "the next spec will contradict. Register it:"
        echo "  /business-wiki:harvest"
        echo "Or say outright that there was nothing to register:"
        echo "  task.sh state $id $target --no-wiki-delta \"<why nothing changed>\""
        return 1
      fi
      if [ "$has_delta" -eq 0 ] && [ "$waive" -eq 1 ] && [ -z "$waive_reason" ]; then
        echo "STOP HERE: --no-wiki-delta needs a reason."
        echo "An unexplained waiver records that the gate was skipped while saying"
        echo "nothing about why — worse than no gate."
        return 1
      fi
      # The waiver is recorded after the move lands, not here: a cancelled
      # confirmation must not leave a reason behind on a task that never advanced.
      [ "$has_delta" -eq 0 ] && [ "$waive" -eq 1 ] && record_waiver=1
    fi
  elif [ "$waive" -eq 1 ]; then
    echo "STOP HERE: --no-wiki-delta only applies to '$(last_state)', not '$target'."
    return 1
  fi

  echo "About to move task #$id: $current -> $target"
  # shellcheck source=_confirm.sh
  source "$SCRIPT_DIR/_confirm.sh"
  if ! confirm_or_yes "move #$id to '$target'"; then
    echo "Cancelled. #$id stays in '$current'."
    return 0
  fi

  local updated
  updated=$(jq --argjson id "$id" --arg st "$target" --arg now "$(now_utc)" \
    --argjson waive "$record_waiver" --arg wt "$waive_reason" \
    '(.tasks[] | select(.id == $id)) |= (
       .state = $st
       | .updatedAt = $now
       | if $waive == 1
         then .notes += [{at: $now, title: "wiki-delta waived", text: $wt}]
         else . end
     )' "$STORE") || return 1
  write_store "$updated" || return 1
  echo "#$id: $current -> $target"
  [ "$record_waiver" -eq 1 ] && echo "  wiki delta waived: $waive_reason"
  return 0
}

cmd_area() {
  local id area
  id="$(norm_id "${1:-}")"
  area="${2:-}"
  if [ -z "$id" ] || [ -z "$area" ]; then
    echo "Usage: task.sh area <id> <area-slug>"
    return 2
  fi
  if ! [[ "$area" =~ ^[a-z][a-z0-9-]*(_[A-Za-z0-9][A-Za-z0-9-]*)?$ ]]; then
    echo "STOP HERE: area '$area' doesn't look like a track folder name."
    return 1
  fi
  ensure_store >/dev/null || return 1
  require_task "$id" || return 1

  # Not an error if the track doesn't exist yet — the skill links the task before
  # scaffolding in some orders — but say so, because a typo'd area is otherwise
  # invisible until validate-spec.sh can't find a spec.
  [ -d "$(track_dir "$area")" ] || echo "NOTE: $(tracks_dir_rel)/$area doesn't exist yet."

  local updated
  updated=$(jq --argjson id "$id" --arg area "$area" --arg now "$(now_utc)" \
    '(.tasks[] | select(.id == $id)) |= (.area = $area | .updatedAt = $now)' "$STORE") || return 1
  write_store "$updated" || return 1
  echo "#$id area = $area"
}

cmd_note() {
  local id src title="note"
  id="$(norm_id "${1:-}")"
  src="${2:-}"
  shift 2 2>/dev/null || true
  [ "${1:-}" = "--title" ] && title="${2:-note}"

  if [ -z "$id" ] || [ -z "$src" ]; then
    echo "Usage: task.sh note <id> <file|-> [--title <heading>]"
    return 2
  fi
  ensure_store >/dev/null || return 1
  require_task "$id" || return 1

  local text
  if [ "$src" = "-" ]; then
    text=$(cat)
  else
    text=$(cat "$src" 2>/dev/null) || { echo "STOP HERE: can't read $src"; return 1; }
  fi
  if [ -z "$text" ]; then
    echo "STOP HERE: the note is empty. An empty note records that something"
    echo "happened while saying nothing about what — worse than no note."
    return 1
  fi

  local updated
  updated=$(jq --argjson id "$id" --arg t "$text" --arg h "$title" --arg now "$(now_utc)" \
    '(.tasks[] | select(.id == $id)) |=
       (.notes += [{at: $now, title: $h, text: $t}] | .updatedAt = $now)' "$STORE") || return 1
  write_store "$updated" || return 1
  echo "#$id: note added ($title, $(printf '%s' "$text" | wc -l | tr -d ' ') lines)"
}

cmd_next() {
  local want_state=""
  [ "${1:-}" = "--state" ] && want_state="${2:-}"
  [ -z "$want_state" ] && want_state="$(first_state)"
  if ! state_exists "$want_state"; then
    echo "STOP HERE: '$want_state' is not a state. The workflow is: $(states_arrow)"
    return 1
  fi
  if [ ! -f "$STORE" ]; then
    echo "NONE — no task store yet ($STORE_REL)."
    return 3
  fi
  ensure_store >/dev/null || return 1

  local next
  next=$(jq -c --arg s "$want_state" '[.tasks[] | select(.state == $s)][0] // empty' "$STORE")
  if [ -z "$next" ]; then
    echo "NONE — no task in state '$want_state'."
    return 3
  fi
  printf '%s' "$next" | jq -r '
    "NEXT #\(.id)",
    "  title: \(.title)",
    "  state: \(.state)",
    "  area:  \(.area // "-")"'
}

cmd_remove() {
  local id
  id="$(norm_id "${1:-}")"
  [ -n "$id" ] || { echo "Usage: task.sh remove <id>"; return 2; }
  ensure_store >/dev/null || return 1
  require_task "$id" || return 1

  echo "About to delete task #$id ($(task_json "$id" | jq -r '.title')) and its notes."
  echo "This does not touch its track — $(tracks_dir_rel)/ is left alone."
  # shellcheck source=_confirm.sh
  source "$SCRIPT_DIR/_confirm.sh"
  if ! confirm_or_yes "delete task #$id"; then
    echo "Cancelled. Nothing was deleted."
    return 0
  fi
  local updated
  updated=$(jq --argjson id "$id" '.tasks |= map(select(.id != $id))' "$STORE") || return 1
  write_store "$updated" || return 1
  echo "#$id deleted."
}

# ---------------------------------------------------------------------- entry

sub="${1:-}"
shift || true
case "$sub" in
  new)    cmd_new "$@" ;;
  list)   cmd_list "$@" ;;
  show)   cmd_show "$@" ;;
  state)  cmd_state "$@" ;;
  area)   cmd_area "$@" ;;
  note)   cmd_note "$@" ;;
  next)   cmd_next "$@" ;;
  remove) cmd_remove "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "Unknown subcommand '$sub'."; echo; usage; exit 2 ;;
esac
