#!/usr/bin/env bash
# Shared resolution for every script in this plugin. SOURCE this, don't execute:
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#
# There is almost nothing to configure here, and that's deliberate. This is a
# loop a human runs once per task, not an unattended agent that has to be told
# how to behave. So the layout, the states and the phase transitions are FIXED
# CONSTANTS below rather than config keys: a knob nobody turns is a knob that
# only ever produces two projects that disagree about where tracks live.
#
# Two things genuinely vary between projects, and both are about the world outside
# the loop rather than the loop itself: whether there's a business wiki to check
# requirements against (`.claude/sdd-tdd-loop.json` — see wiki-config.sh), and what
# this repo can actually test (`.claude/sdd-tdd/seams.json` — see seam-profile.sh).
# The second one is not a preference: a process that carried its own list of test
# levels would be claiming to know the repo's language, and it doesn't.
#
# This plugin makes no network calls and no git mutations. `git` is read in
# exactly one place (validate-spec.sh's renumbering baseline) and that read
# degrades to a no-op outside a git repo.

# Resolved once, on source. CLAUDE_PROJECT_DIR wins because an agent's Bash may
# start anywhere; the git toplevel is the fallback; pwd is the last resort so
# this still works in a directory that isn't a repo at all (the test sandboxes).
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONFIG="${SDD_TDD_CONFIG:-$REPO_ROOT/.claude/sdd-tdd-loop.json}"
export REPO_ROOT CONFIG

# --- the fixed layout -------------------------------------------------------

TASKS_PATH_REL=".sdd-tdd/tasks.json"
TRACKS_DIR_REL="tracks"

tasks_path_rel() { printf '%s' "$TASKS_PATH_REL"; }
tasks_path()     { printf '%s/%s' "$REPO_ROOT" "$TASKS_PATH_REL"; }
tracks_dir_rel() { printf '%s' "$TRACKS_DIR_REL"; }
tracks_dir()     { printf '%s/%s' "$REPO_ROOT" "$TRACKS_DIR_REL"; }
track_dir()      { printf '%s/%s/%s' "$REPO_ROOT" "$TRACKS_DIR_REL" "$1"; }

# --- the fixed workflow -----------------------------------------------------
#
# Five states, and each boundary is a real handover:
#
#   new           nobody has specified it yet
#   specced       /sdd-spec finished: requirements + use cases exist and validate
#   implementing  /sdd-implement is working through the cases
#   verify        every automatable case is refactored — a human runs it now
#   done          a human confirmed it
#
# plus `blocked`, reachable from and back to anywhere.
#
# `verify` and `done` are two states rather than one because green tests are not
# a finished feature: nothing in this plugin ever sets `done`.

STATES=(new specced implementing verify done blocked)

states_list() { printf '%s\n' "${STATES[@]}"; }
state_exists() { states_list | grep -qxF "$1"; }
first_state() { printf '%s' "${STATES[0]}"; }

# last_state — the end of the forward chain, which is NOT ${STATES[-1]}: `blocked`
# sits last in the array because it's the escape hatch, not the finish line.
last_state() {
  local s last=""
  for s in "${STATES[@]}"; do
    [ "$s" = "blocked" ] && continue
    last="$s"
  done
  printf '%s' "$last"
}

# state_index <state> — 0-based position, or empty if unknown. `blocked` has a
# position like any other; the transition rule in task.sh special-cases it.
state_index() {
  states_list | grep -nxF "$1" | head -1 | cut -d: -f1 | awk '{print $1-1}'
}

# states_arrow — the workflow on one line: "new -> specced -> ...".
# NOT `paste -sd' -> '`: paste treats its delimiter argument as a LIST of
# single-character delimiters and cycles through them, rendering that as
# "new specced-implementing>verify".
states_arrow() { states_list | awk 'NR==1{printf "%s", $0; next} {printf " -> %s", $0} END{print ""}'; }

# --- tool availability ------------------------------------------------------

require_tools() {
  local missing=0 t
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      case "$t" in
        jq) echo "STOP HERE: missing 'jq' (required to read the task store)." ;;
        *)  echo "STOP HERE: missing '$t'." ;;
      esac
      missing=1
    fi
  done
  [ "$missing" -eq 0 ]
}

# --- config -----------------------------------------------------------------
#
# The config file is optional. When it exists it holds the wiki keys, and — for a
# repo that would rather keep one file than two — a `seams` key holding what
# .claude/sdd-tdd/seams.json otherwise holds. Nothing else: anything more would be
# a setting this plugin promised to honour and then had to keep honouring.

have_config() { [ -f "$CONFIG" ]; }

require_config() {
  if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1 && ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    echo "STOP HERE: $CONFIG exists but is not valid JSON."
    return 1
  fi
  return 0
}

# cfg <jq-path> [default] — read one scalar, degrading to the default when jq or
# the config is missing.
cfg() {
  local path="$1" default="${2:-}" value
  if [ ! -f "$CONFIG" ] || ! command -v jq >/dev/null 2>&1; then
    printf '%s' "$default"
    return 0
  fi
  value=$(jq -r "$path // empty" "$CONFIG" 2>/dev/null)
  [ -n "$value" ] && [ "$value" != "null" ] || value="$default"
  printf '%s' "$value"
}

# --- tracks -----------------------------------------------------------------

# require_track <area> — the track must exist and hold a spec.md. Only the file
# matters, not the folder layout.
require_track() {
  local area="$1" dir
  dir="$(track_dir "$area")"
  if [ ! -d "$dir" ]; then
    echo "STOP HERE: $TRACKS_DIR_REL/$area doesn't exist."
    return 1
  fi
  if [ ! -f "$dir/spec.md" ]; then
    echo "STOP HERE: $TRACKS_DIR_REL/$area has no spec.md."
    return 1
  fi
  return 0
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
