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
# WHICH seams exist and HOW they're recognised is not this script's business.
# It used to be — a hardcoded marker table for Dart/Kotlin/Swift, TS/JS and
# Python — and that made a language-agnostic process carry language knowledge:
# a C# repo with a full xunit suite probed as NONE, so intake marked every use
# case manual. The table is data now; see seam-profile.sh, and /sdd-init, which
# generates a repo's profile alongside a repo-local language skill.
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

# shellcheck source=seam-profile.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seam-profile.sh"

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

# Resolved before anything is printed: a bad profile is a stop, not a probe that
# reports "no seams" and lets a spec full of `manual` rows through.
seam_profile_resolve || exit 1

echo "# test-seam probe"
echo "scope=${scopes[*]}"
# The profile is part of the answer. A surprising result ("we do have goldens")
# is almost always the wrong profile, and without this line that's invisible.
echo "profile=$SEAM_PROFILE_LABEL"
[ "$SEAM_PATTERN_INHERITED" -eq 1 ] && echo "note=testFilePattern inherited from the built-in default"
echo

# What counts as a test FILE, by path or name — from the profile. A marker found
# in production code says nothing about whether tests can drive that seam, so
# this filter is what makes the probe about the verification surface rather than
# about the feature.
#
# Every ecosystem spells it differently and this is the whole portability
# surface: Dart/Kotlin/Swift put tests in test/ or name them *_test.dart /
# FooTest.kt; JS/TS use __tests__/, *.test.ts, *.spec.ts; Python uses tests/,
# test_*.py, *_test.py, conftest.py; .NET uses tests/, Foo.Tests/, FooTests.cs.
# Getting it wrong doesn't degrade the answer, it INVERTS it — the probe reports
# "no test suite" for a package with a suite, and intake then marks every row
# manual. That happened twice: a TypeScript worker with 7 vitest files and a C#
# project with a Tests/ folder both probed as NONE.
TEST_FILE_RE="$SEAM_TEST_FILE_RE"

# Build the find-based file list once per glob set, then grep it. `grep -rl`
# over the scope with --include is simpler but re-walks the tree per seam;
# these repos are large enough for that to be noticeable.
declare -a available_seams=()

# Prints the seam's report line and appends to available_seams when found.
# Sets no other state — the count is deliberately not returned, so callers
# can't drift into re-running the probe just to read it.
probe_seam() {
  local name="$1" marker="$2" globs="$3"
  # `set -f` around the split: $globs is an unquoted word-split on purpose, but
  # without it bash also PATHNAME-expands each glob against the caller's cwd —
  # so `*.md` silently became `--include=README.md` when run from a directory
  # holding one, and the search found nothing.
  local includes=() g
  set -f
  for g in $globs; do includes+=(--include="$g"); done
  set +f
  # Only test files count. A marker found in production code (e.g. a widget
  # that reads viewInsets) says nothing about whether tests can drive it.
  local hits count example
  hits=$(grep -rlE "$marker" "${includes[@]}" \
    --exclude-dir=build --exclude-dir=.git --exclude-dir=node_modules \
    --exclude-dir=dist --exclude-dir=coverage --exclude-dir=.dart_tool \
    --exclude-dir=.venv --exclude-dir=__pycache__ --exclude-dir=vendor \
    --exclude-dir=bin --exclude-dir=obj --exclude-dir=target \
    -- "${scopes[@]/#/$REPO_ROOT/}" 2>/dev/null \
    | grep -E "$TEST_FILE_RE" \
    || true)
  count=$(printf '%s' "$hits" | grep -c . || true)
  if [ "$count" -gt 0 ]; then
    example=$(printf '%s' "$hits" | head -1 | sed -e "s|^$REPO_ROOT/||" -e 's|^\./||')
    echo "seam=$name available=yes files=$count example=$example"
    available_seams+=("$name")
  else
    echo "seam=$name available=no files=0 example=-"
  fi
}

# One pass over the profile, in its order. Markers stay regexes full of '|'
# alternations — which is precisely why they arrive as JSON fields rather than
# delimited strings: ANY single-character field separator collides with the data.
# (It did, in the version before profiles: IFS='|' shredded each regex at its
# first alternation and a package with 19 test files reported "no test suite".)
seam_total="$(seam_count)"
for ((i = 0; i < seam_total; i++)); do
  probe_seam "$(seam_at "$i" name)" "$(seam_at "$i" marker)" "$(seam_at "$i" globs)"
done

echo
echo "## suggested use case levels"
if [ "${#available_seams[@]}" -eq 0 ]; then
  echo "NONE — this scope has no detectable test suite. Every use case here"
  echo "is manual until a test level is introduced. Say so in the spec's Gaps."
  if [ "$SEAM_PROFILE_ORIGIN" = "default" ]; then
    # The single most likely cause, stated where it will be read: the built-in
    # table only knows Dart/Kotlin/Swift, TS/JS and Python. A repo in any other
    # language needs its own profile before this answer means anything.
    echo
    echo "This ran on the built-in marker table (Dart/Kotlin/Swift, TS/JS, Python)."
    echo "If this repo tests in another language, the answer above is about the"
    echo "TABLE, not the repo — run /sdd-init to generate its seam profile first."
  fi
else
  echo "Honest 'Level' values for this scope: ${available_seams[*]} manual"
fi
echo
echo "Any use case whose Level is NOT in that list means introducing a new"
echo "test level as part of this work — a cost to name at intake, in Gaps,"
echo "not to discover at implementation time."
