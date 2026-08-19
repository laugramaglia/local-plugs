#!/usr/bin/env bash
# What does the business wiki already say about these keywords?
#
# Usage: wiki-lookup.sh <keyword> [keyword...]
#
# Read-only. Greps the wiki's markdown and the derived rules JSON for any of the
# keywords and reports where they hit, so /sdd-spec can answer the only question
# that matters before writing a requirement: is this behaviour already
# documented, and where?
#
# It reports LOCATIONS, never conclusions. Whether a hit is "this already covers
# it" or "this contradicts what the task asks for" is a reading the agent does
# with the file open — no grep can tell those apart, and a script that guessed
# would be inventing the one thing this step exists to avoid inventing.
#
# Exit codes:
#   0  hits found
#   3  no hits (the behaviour appears undocumented — a real answer, not an error)
#   4  no wiki configured (mode=off)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "$SCRIPT_DIR/_common.sh"

if [ "$#" -eq 0 ]; then
  echo "Usage: wiki-lookup.sh <keyword> [keyword...]"
  exit 2
fi

conf=$(bash "$SCRIPT_DIR/wiki-config.sh" 2>/dev/null) || {
  bash "$SCRIPT_DIR/wiki-config.sh" >/dev/null
  exit 1
}
mode=$(printf '%s\n' "$conf" | sed -n 's/^mode=//p')
wiki=$(printf '%s\n' "$conf" | sed -n 's/^wiki=//p')
rules=$(printf '%s\n' "$conf" | sed -n 's/^rules=//p')

if [ "$mode" = "off" ]; then
  echo "NO WIKI — this project declares no business wiki."
  echo "  Skip the cross-check. Don't substitute reading the code for it."
  exit 4
fi

pattern=$(printf '%s\n' "$@" | paste -sd'|' -)
echo "# wiki lookup"
echo "keywords: $*"
echo "wiki:     $wiki"
[ -n "$rules" ] && echo "rules:    $rules"
echo

found=0

search_tree() {
  local root_rel="$1" label="$2" globs="$3"
  local abs="$REPO_ROOT/$root_rel"
  [ -d "$abs" ] || return 0

  # `set -f` around the split: $globs is an unquoted word-split on purpose, but
  # without it bash also PATHNAME-expands each glob against the caller's cwd —
  # so `*.md` silently became `--include=README.md` when run from a directory
  # holding one, and the search found nothing.
  local includes=() g
  set -f
  for g in $globs; do includes+=(--include="$g"); done
  set +f

  local hits
  hits=$(grep -rniE "$pattern" "${includes[@]}" -- "$abs" 2>/dev/null || true)
  [ -n "$hits" ] || return 0

  echo "## $label"
  # One block per file, with the matching lines under it: a flat grep dump of a
  # wiki is unreadable, and the file is the unit the agent will open next.
  #
  # Split with parameter expansion, NOT `awk -F:`. Awk rebuilds $0 with OFS after
  # you blank the first two fields, which strips every remaining colon from the
  # line — turning a matched line of rules JSON into `{"feature" "loans"}`. The
  # one tree here that is guaranteed to be full of colons is the one that broke.
  local last="" rel file rest line text
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    rel="${hit#"$abs"/}"
    file="${rel%%:*}"; rest="${rel#*:}"
    line="${rest%%:*}"; text="${rest#*:}"
    if [ "$file" != "$last" ]; then
      printf '\n- %s\n' "$file"
      last="$file"
    fi
    text="${text#"${text%%[![:space:]]*}"}"
    printf '    %s: %s\n' "$line" "${text:0:160}"
  done <<< "$hits"
  echo
  found=1
}

search_tree "$wiki" "wiki (the source of truth)" '*.md'
[ -n "$rules" ] && search_tree "$rules" "derived rules (keyed lookup)" '*.json'

if [ "$found" -eq 0 ]; then
  echo "NO HITS — nothing in the wiki mentions: $*"
  echo "  Treat every requirement here as NEW, and say so in the spec's Gaps."
  exit 3
fi

echo "Read the files above before writing any requirement they touch."
echo "Per requirement, decide: RELATED EXISTS (stay consistent with it),"
echo "or POTENTIAL CONFLICT (the task contradicts a documented rule — stop"
echo "and ask, don't spec over it)."
