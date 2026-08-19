#!/usr/bin/env bash
# Which ecosystems does this repo build in, and which shipped seam profile fits?
#
# Read-only. No confirmation needed.
#
# Usage: detect-stack.sh [scope-path ...]     (defaults to the whole repo)
#
# This answers one narrow question — what MANIFESTS are here — and deliberately
# stops there. It does not guess the test framework, the test command or the
# naming convention: that's language knowledge, it differs per repo even within
# one ecosystem, and a script that guesses it produces confident wrong answers
# nobody re-checks. /sdd-init reads the repo and writes those into a repo-local
# language skill instead, where a human reviews them once.
#
# Output is line-oriented:
#   stack=<profile-name> files=<n> example=<path>
#   profile=<path to the shipped starter profile>
# then a `## suggested profile` block, then `unmatched=...` when manifests exist
# that no shipped profile claims — which is a real answer, not a failure: it
# means this repo writes its own profile from scratch.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

PLUGIN_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="$PLUGIN_ROOT_DIR/templates/seam-profiles"

require_tools jq || exit 1

scopes=("$@")
[ "${#scopes[@]}" -eq 0 ] && scopes=(".")
for s in "${scopes[@]}"; do
  if [ ! -d "$REPO_ROOT/$s" ]; then
    echo "STOP HERE: scope path '$s' doesn't exist under $REPO_ROOT."
    exit 1
  fi
done

echo "# stack probe"
echo "scope=${scopes[*]}"
echo

# find, not grep: the signal is a file's NAME (Foo.csproj, pubspec.yaml), and
# the excludes are the same ones the seam probe uses — a manifest inside
# node_modules or a build dir says nothing about what this repo is.
find_manifests() {
  local globs=("$@") args=() g first=1
  for g in "${globs[@]}"; do
    if [ "$first" -eq 1 ]; then first=0; else args+=(-o); fi
    args+=(-name "$g")
  done
  find "${scopes[@]/#/$REPO_ROOT/}" \
    \( -name build -o -name .git -o -name node_modules -o -name dist \
       -o -name .dart_tool -o -name .venv -o -name vendor -o -name bin \
       -o -name obj -o -name target -o -name coverage \) -prune -o \
    -type f \( "${args[@]}" \) -print 2>/dev/null \
    | sed -e "s|^$REPO_ROOT/||" -e 's|^\./||' 
}

matched=0
declare -a matched_names=()
for pf in "$PROFILES_DIR"/*.json; do
  [ -f "$pf" ] || continue
  name="$(jq -r '.name' "$pf")"
  # `while read`, not `mapfile`: macOS ships bash 3.2 and mapfile is a bash 4
  # builtin, so the array came back unset and every stack went undetected.
  globs=()
  while IFS= read -r g; do [ -n "$g" ] && globs+=("$g"); done < <(jq -r '.detect[]? // empty' "$pf")
  [ "${#globs[@]}" -gt 0 ] || continue
  hits="$(find_manifests "${globs[@]}")"
  count="$(printf '%s' "$hits" | grep -c . || true)"
  [ "$count" -gt 0 ] || continue
  matched=1
  matched_names+=("$name")
  echo "stack=$name files=$count example=$(printf '%s' "$hits" | head -1)"
  echo "profile=templates/seam-profiles/$(basename "$pf")"
done

echo
echo "## suggested profile"
if [ "$matched" -eq 0 ]; then
  echo "NONE of the shipped starter profiles matched this scope."
  echo "That is a normal outcome, not an error: write .claude/sdd-tdd/seams.json"
  echo "by hand from the shape in seam-profile.sh, naming the seams this repo"
  echo "actually writes and the marker each one unavoidably contains."
elif [ "${#matched_names[@]}" -eq 1 ]; then
  echo "One stack: ${matched_names[0]}. Copy that profile to .claude/sdd-tdd/seams.json"
  echo "and delete the seams this repo doesn't really write — an unavailable seam"
  echo "is honest, a seam nobody writes is a Level intake shouldn't promise."
else
  echo "Several stacks: ${matched_names[*]}. A seam profile is per REPO, so merge"
  echo "them into one file — seam names are shared, globs and markers are unioned"
  echo "(e.g. one \`unit\` seam whose globs cover *.cs and *.ts). Then probe each"
  echo "package separately: the probe's scope argument is what keeps a monorepo's"
  echo "answer about the package the task touches."
fi
