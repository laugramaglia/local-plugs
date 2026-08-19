#!/usr/bin/env bash
# Locate the track: does this task belong to an existing tracks/<area>/?
# Usage: locate-track.sh <keyword> [keyword...]
# Looks for matches in the folder NAME and in spec.md's title/H1.
#
# Standalone to this plugin on purpose: sdd-tdd-loop doesn't call any other
# plugin's scripts, so it owns this logic itself rather than depending on
# where another plugin happens to be installed.
#
# Checks ALL tracks that match, not just a single canonical name: a feature
# can have a live track (tracks/<area>/, no suffix) plus variant tracks
# (tracks/<area>_<tracknumber>/). <tracknumber> is whatever created the
# variant — here, typically the local task id — never a
# date, never auto-generated here.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

TRACKS_DIR_REL="$(tracks_dir_rel)"
TRACKS_DIR="$(tracks_dir)"

if [ "$#" -eq 0 ]; then
  echo "Usage: locate-track.sh <keyword> [keyword...]"
  exit 2
fi

if [ ! -d "$TRACKS_DIR" ]; then
  echo "NO MATCH — $TRACKS_DIR_REL/ doesn't exist yet, so no track can match."
  echo "scaffold-track.sh creates it on the first track."
  exit 3
fi

pattern=$(printf '%s\n' "$@" | paste -sd'|' -)
matched_names=()

for dir in "$TRACKS_DIR"/*/; do
  # An empty tracks/ leaves the glob unexpanded, and printing a literal '*' as a
  # folder name reads like a real track called '*'.
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  if [[ "$name" == _* ]]; then
    continue
  fi

  hit=""
  if echo "$name" | grep -qiE "$pattern"; then
    hit="folder name"
  elif [ -f "$dir/spec.md" ] && head -5 "$dir/spec.md" | grep -qiE "$pattern"; then
    hit="spec.md title"
  fi

  if [ -n "$hit" ]; then
    matched_names+=("$name")
  fi
done

if [ "${#matched_names[@]}" -eq 0 ]; then
  echo "NO MATCH — no existing track matches: $*"
  echo "Current folders in $TRACKS_DIR_REL/:"
  found=0
  for dir in "$TRACKS_DIR"/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    [[ "$name" == _* ]] && continue
    echo "  - $name"
    found=1
  done
  [ "$found" -eq 0 ] && echo "  (none yet)"
  exit 3
fi

bases=()
for name in "${matched_names[@]}"; do
  base="${name%%_*}"
  already=0
  for seen in "${bases[@]:-}"; do
    [ "$seen" = "$base" ] && already=1 && break
  done
  [ "$already" -eq 0 ] && bases+=("$base")
done

for base in "${bases[@]}"; do
  family=()
  for name in "${matched_names[@]}"; do
    if [ "${name%%_*}" = "$base" ]; then
      family+=("$name")
    fi
  done

  if [ "${#family[@]}" -gt 1 ]; then
    echo "MATCH FAMILY '$base' — ${#family[@]} related tracks found, not just one:"
  else
    echo "MATCH '$base':"
  fi

  for name in "${family[@]}"; do
    tag="variant"
    [ "$name" = "$base" ] && tag="live"
    spec_status="no spec.md"
    [ -f "$TRACKS_DIR/$name/spec.md" ] && spec_status="has spec.md"

    # Tracks in this repo come in two shapes: the lean one this plugin
    # scaffolds (spec.md/contract.md/CHANGELOG.md) and an older one from a
    # previous flow (context.md/index.md/metadata.json/plan.md/STATUS.md).
    # Both are real tracks and both hold a spec.md, so neither is an error —
    # but /sdd-tdd-implement needs use-cases.json, which only the lean shape
    # generates. Naming the shape here is what stops the loop from reading a
    # legacy track's silence as "no use cases enumerated yet".
    shape="lean"
    if [ -f "$TRACKS_DIR/$name/metadata.json" ] || [ -f "$TRACKS_DIR/$name/STATUS.md" ]; then
      shape="legacy"
    fi
    uc_status="no use-cases.json"
    [ -f "$TRACKS_DIR/$name/use-cases.json" ] && uc_status="has use-cases.json"
    echo "  - $TRACKS_DIR_REL/$name  ($tag, $shape, $spec_status, $uc_status)"
  done

  if [ "${#family[@]}" -gt 1 ]; then
    echo "  WARNING: multiple tracks share the '$base' feature — confirm with the"
    echo "  user which one this task actually belongs to before proceeding. Per"
    echo "  convention the live track (no suffix) is the default one to use;"
    echo "  suffixed variants (<area>_<tracknumber>) link a specific external"
    echo "  task/ticket, and their number is never dated or auto-generated."
  fi
done
