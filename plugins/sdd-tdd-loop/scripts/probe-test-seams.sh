#!/usr/bin/env bash
# Probe what the repo can ACTUALLY test, before any use case is written.
#
# Why this exists: the plugin already probes the domain source (crossCheck) to
# avoid inventing business rules. It had no equivalent probe of the
# VERIFICATION surface, so use cases could describe tests the repo has no
# way to express — e.g. enumerating "the amount renders without clipping" in a
# package whose suite is 19 view-model unit tests, 1 widget test and 0 golden
# tests. Those rows look identical to real ones and only fall over at
# implementation time, long after the spec was validated and approved.
#
# A "seam" here is a test level the repo demonstrably already uses. Existing
# usage is the signal: a seam nobody has ever written in this repo is not
# something intake should promise, even if the framework technically supports
# it. `available=no` doesn't forbid a use case at that level — it means
# writing one also means introducing that test level, which is a decision to
# surface at intake rather than discover later.
#
# Read-only. No confirmation needed.
#
# Usage: probe-test-seams.sh [scope-path ...]
#   scope-path  Repo-relative dir(s) to probe, e.g. features/loans. Narrow to
#               the package the task touches — a monorepo-wide answer
#               ("some package somewhere has goldens") is worse than useless,
#               since the seam has to exist where the test will be written.
#               Defaults to the whole repo.
#
# Output is line-oriented and stable, one seam per line:
#   seam=<name> available=yes|no files=<n> example=<path>
# followed by a `## suggested use case levels` block naming the `Level`
# values that are honest for this scope.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

scopes=("$@")
if [ "${#scopes[@]}" -eq 0 ]; then
  scopes=(".")
fi

for s in "${scopes[@]}"; do
  if [ ! -d "$REPO_ROOT/$s" ]; then
    echo "STOP HERE: scope path '$s' doesn't exist under $REPO_ROOT."
    exit 1
  fi
done

echo "# test-seam probe"
echo "scope=${scopes[*]}"
echo

# Build the find-based file list once per glob set, then grep it. `grep -rl`
# over the scope with --include is simpler but re-walks the tree per seam;
# these repos are large enough for that to be noticeable.
declare -a available_seams=()

# Prints the seam's report line and appends to available_seams when found.
# Sets no other state — the count is deliberately not returned, so callers
# can't drift into re-running the probe just to read it.
probe_seam() {
  local name="$1" marker="$2" globs="$3"
  local includes=() g
  for g in $globs; do
    includes+=(--include="$g")
  done
  # Only test files count. A marker found in production code (e.g. a widget
  # that reads viewInsets) says nothing about whether tests can drive it.
  local hits count example
  hits=$(grep -rlE "$marker" "${includes[@]}" \
    --exclude-dir=build --exclude-dir=.git --exclude-dir=node_modules \
    -- "${scopes[@]/#/$REPO_ROOT/}" 2>/dev/null \
    | grep -E '(^|/)(test|tests|androidTest|integration_test)/|_test\.|Test\.|Tests\.|Spec\.' \
    || true)
  count=$(printf '%s' "$hits" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    example=$(printf '%s' "$hits" | head -1 | sed "s|^$REPO_ROOT/||")
    echo "seam=$name available=yes files=$count example=$example"
    available_seams+=("$name")
  else
    echo "seam=$name available=no files=0 example=-"
  fi
}

# Seams are probed by direct calls rather than a table of delimited strings:
# every marker is a regex full of '|' alternations, so ANY single-character
# field separator collides with the data. (It did: the first version silently
# reported "no test suite" for a package with 19 test files, because IFS='|'
# had shredded each regex at its first alternation.) Direct calls have no
# separator to collide with.
#
# Markers are what a test at that level unavoidably contains, across the
# ecosystems this plugin is used in (Flutter/Dart, Android/Kotlin, iOS/Swift).
# Probing several at once is deliberate: the same task may land in a
# Flutter monorepo or a two-native-codebase repo, and the script must not have
# to be told which.
#
# `unit` is intentionally broad — every ecosystem has it, and its absence means
# something is very wrong rather than "this level is unavailable".
probe_seam unit \
  '(^|[^a-zA-Z])(test\(|@Test|func test[A-Z]|XCTestCase)' \
  '*.dart *.kt *.swift'
probe_seam widget \
  '(pumpWidget|composeTestRule|ComposeTestRule)' \
  '*.dart *.kt'
probe_seam golden \
  '(matchesGoldenFile|assertSnapshot|[Pp]aparazzi|recordSnapshot)' \
  '*.dart *.kt *.swift'
probe_seam integration \
  '(IntegrationTestWidgetsFlutterBinding|XCUIApplication|androidTest|[Ee]spresso)' \
  '*.dart *.kt *.swift'
# A use case about keyboard overlap or responsive layout needs more than
# "widget tests exist" — it needs the ability to drive viewport/inset state.
# Probed separately because its absence is the difference between "write a
# widget test" and "write a widget test AND introduce inset plumbing".
probe_seam viewport-control \
  '(viewInsets|setSurfaceSize|LocalDensity|UIScreen\.main)' \
  '*.dart *.kt *.swift'

# Config may extend the seam list for a project whose test culture these
# markers don't describe. Same principle as crossCheck: the plugin ships
# defaults, the project gets the last word. Tab-separated because, unlike '|',
# a tab cannot appear inside a regex written on one line.
if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
  custom=$(jq -r '.testSeams // {} | to_entries[] | [.key, .value.marker, (.value.glob // "*")] | @tsv' "$CONFIG" 2>/dev/null)
  if [ -n "$custom" ]; then
    while IFS=$'\t' read -r name marker globs; do
      [ -n "$name" ] && probe_seam "$name" "$marker" "$globs"
    done <<< "$custom"
  fi
fi

echo
echo "## suggested use case levels"
if [ "${#available_seams[@]}" -eq 0 ]; then
  echo "NONE — this scope has no detectable test suite. Every use case here"
  echo "is manual until a test level is introduced. Say so in the spec's Gaps."
else
  echo "Honest 'Level' values for this scope: ${available_seams[*]} manual"
fi
echo
echo "Any use case whose Level is NOT in that list means introducing a new"
echo "test level as part of this work — a cost to name at intake, in Gaps,"
echo "not to discover at implementation time."
