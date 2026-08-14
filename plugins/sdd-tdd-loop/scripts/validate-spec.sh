#!/usr/bin/env bash
# Lightweight structural check of spec.md — NOT semantic, doesn't validate
# business content, only shape:
#   1. The Gaps section exists.
#   2. RF-N/AC-N headers weren't renumbered relative to the baseline.
#
# The baseline for (2) is `specBaseline` in the config:
#   "git" (default)  compare against this file's version in git HEAD
#   "off"            skip the comparison (non-git projects, or a project that
#                    wants this plugin to touch git not at all)
# Either way nothing is written to git — the check is a read.
#
# Usage: validate-spec.sh <area>
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

TRACKS_DIR_REL="$(tracks_dir_rel)"

area="${1:-}"
if [ -z "$area" ]; then
  echo "Usage: validate-spec.sh <area>"
  exit 2
fi

spec="$REPO_ROOT/$TRACKS_DIR_REL/$area/spec.md"
if [ ! -f "$spec" ]; then
  echo "FAIL: $spec doesn't exist"
  exit 1
fi

ok=1

if ! grep -qiE '^#+ *gaps' "$spec"; then
  echo "FAIL: $spec has no '## Gaps' section (always required)."
  ok=0
else
  echo "OK: Gaps section present."
fi

if [ -s "$spec" ] && [ "$(wc -l < "$spec")" -le 3 ]; then
  echo "FAIL: $spec looks empty/placeholder (<=3 lines)."
  ok=0
fi

baseline="$(cfg '.specBaseline' 'git')"
case "$baseline" in
  off)
    echo "INFO: specBaseline=off — RF/AC renumbering not checked."
    ;;
  git)
    if ! command -v git >/dev/null 2>&1 \
       || ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      echo "INFO: not a git repo (or no git) — nothing to compare RF/AC headers against."
    elif git -C "$REPO_ROOT" cat-file -e "HEAD:$TRACKS_DIR_REL/$area/spec.md" 2>/dev/null; then
      prev_headers=$(git -C "$REPO_ROOT" show "HEAD:$TRACKS_DIR_REL/$area/spec.md" \
        | grep -oE '\b(RF|AC)-[0-9]+\b' | sort -u)
      curr_headers=$(grep -oE '\b(RF|AC)-[0-9]+\b' "$spec" | sort -u)
      removed=$(comm -23 <(echo "$prev_headers") <(echo "$curr_headers"))
      if [ -n "$removed" ]; then
        echo "FAIL: these RF/AC headers existed in HEAD and are now gone — looks like a renumbering, not an addition:"
        echo "$removed" | sed 's/^/  - /'
        ok=0
      else
        echo "OK: no previous RF/AC header disappeared relative to HEAD."
      fi
    else
      echo "INFO: spec.md has no previous version in HEAD (new track) — nothing to compare."
    fi
    ;;
  *)
    # Not a silent fallback: an unrecognised value means someone meant something
    # by it, and quietly picking a mode would hide that.
    echo "FAIL: specBaseline '$baseline' is not one of: git | off"
    ok=0
    ;;
esac

if [ "$ok" -eq 1 ]; then
  echo "validate-spec: OK"
else
  echo "validate-spec: FAIL"
  exit 1
fi
