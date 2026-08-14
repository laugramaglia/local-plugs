#!/usr/bin/env bash
# Shared resolution for every script in this plugin. SOURCE this, don't execute:
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
#
# It resolves configuration and reports problems. It does NOT decide policy:
# confirmation gates live in _confirm.sh, task mutation in task.sh. One concern
# each, so two scripts can't drift into disagreeing about the same question.
#
# Every function here is safe to call from a script running unattended: they
# write to stdout and return non-zero, never `exit`, so the caller decides
# whether a missing tool is fatal.
#
# This plugin makes no network calls and no git mutations. `git` is read in
# exactly one place (validate-spec.sh's renumbering baseline) and that read is
# optional — see specBaseline.

# Resolved once, on source. CLAUDE_PROJECT_DIR wins because an agent's Bash may
# start anywhere; the git toplevel is the fallback; pwd is the last resort so
# this still works in a directory that isn't a repo at all (the test sandboxes).
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONFIG="${SDD_TDD_CONFIG:-$REPO_ROOT/.claude/sdd-tdd-loop.json}"
export REPO_ROOT CONFIG

# --- tool availability ------------------------------------------------------

# require_tools jq  -> 0 if all present; else prints one line per missing tool
# and returns 1. The caller decides what that means.
require_tools() {
  local missing=0 t
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      case "$t" in
        jq) echo "STOP HERE: missing 'jq' (required to read $CONFIG and the task store)." ;;
        *)  echo "STOP HERE: missing '$t'." ;;
      esac
      missing=1
    fi
  done
  [ "$missing" -eq 0 ]
}

# --- config -----------------------------------------------------------------
#
# The config is OPTIONAL in this plugin, unlike its board-driven ancestor.
# There is no org, no project, no credentials — every key has a defensible
# default, so a repo with no config file still works. require_config exists for
# the one case that needs it: a config file that's present but unparseable.

have_config() { [ -f "$CONFIG" ]; }

require_config() {
  if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1 && ! jq -e . "$CONFIG" >/dev/null 2>&1; then
    echo "STOP HERE: $CONFIG exists but is not valid JSON."
    return 1
  fi
  return 0
}

# cfg <jq-path> [default] — read one scalar. Degrades to the default when jq or
# the config is missing, so a caller that only wants tracksDir needn't guard.
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

# cfg_raw [jq-options...] <jq-filter> — for structures (arrays/objects/keys)
# rather than scalars. Every argument is forwarded to jq, so `--arg`/`--argjson`
# work: cfg_raw --arg k "$key" '.advanceTo[$k]'.
cfg_raw() {
  [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1 || return 1
  jq -r "$@" "$CONFIG" 2>/dev/null
}

# --- tracks -----------------------------------------------------------------

tracks_dir_rel() { cfg '.tracksDir' 'tracks'; }
tracks_dir()     { printf '%s/%s' "$REPO_ROOT" "$(tracks_dir_rel)"; }
track_dir()      { printf '%s/%s/%s' "$REPO_ROOT" "$(tracks_dir_rel)" "$1"; }

# require_track <area> — the track must exist and hold a spec.md. Only the file
# matters, not the folder layout.
require_track() {
  local area="$1" dir
  dir="$(track_dir "$area")"
  if [ ! -d "$dir" ]; then
    echo "STOP HERE: $(tracks_dir_rel)/$area doesn't exist."
    return 1
  fi
  if [ ! -f "$dir/spec.md" ]; then
    echo "STOP HERE: $(tracks_dir_rel)/$area has no spec.md."
    return 1
  fi
  return 0
}

# --- tasks ------------------------------------------------------------------
# The local task store is this plugin's replacement for a board: one JSON file,
# committed with the repo, mutated only by task.sh. A single file rather than a
# file per task because every interesting question ("what's in `new`?", "which
# task owns this area?") is a query across all of them, and jq answers those in
# one read without a directory walk that can half-fail.

tasks_path_rel() { cfg '.tasksPath' '.sdd-tdd/tasks.json'; }
tasks_path()     { printf '%s/%s' "$REPO_ROOT" "$(tasks_path_rel)"; }

# states_list — the project's ordered state keys, one per line. Order IS the
# workflow: "later in this list" is what makes a transition forward.
states_list() {
  local out
  out=$(cfg_raw '.states[]?' 2>/dev/null) || out=""
  if [ -z "$out" ]; then
    printf '%s\n' new specced implementing verify done blocked
    return 0
  fi
  printf '%s\n' "$out"
}

state_exists() {
  states_list | grep -qxF "$1"
}

# state_index <state> — 0-based position in states_list, or empty if unknown.
# `blocked` deliberately has a position like any other state; the transition
# rule in task.sh special-cases it, not this lookup.
state_index() {
  states_list | grep -nxF "$1" | head -1 | cut -d: -f1 | awk '{print $1-1}'
}

first_state() { states_list | head -1; }

# advance_target <phase> — resolve advanceTo.<phase> to a state key. This is why
# the skills pass `@spec` / `@implement` rather than a literal state name: which
# state a phase ends in is per-project configuration, not something baked into a
# SKILL.md. Empty output means unresolvable, and the caller must say so rather
# than guessing.
advance_target() {
  local phase="$1" value
  value=$(cfg_raw --arg p "$phase" '.advanceTo[$p] // empty' 2>/dev/null)
  if [ -z "$value" ]; then
    case "$phase" in
      spec)      value="specced" ;;
      implement) value="verify" ;;
    esac
  fi
  printf '%s' "$value"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
