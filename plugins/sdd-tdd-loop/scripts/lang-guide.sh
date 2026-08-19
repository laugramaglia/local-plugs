#!/usr/bin/env bash
# Where is this repo's language guide — the thing that says how a test at each
# seam is actually written HERE?
#
# Read-only. No confirmation needed.
#
# Usage: lang-guide.sh
#
# The plugin is a process: task -> spec -> enumerated use cases -> red, green,
# refactored. It knows nothing about xunit, pubspec, vitest or pytest, and it
# shouldn't: the same process runs over a Flutter app and a .NET API, and every
# language fact baked into a plugin script is a fact that's wrong in some repo
# that installed it.
#
# So the language half lives in the repo, as a normal Claude Code skill under
# `.claude/skills/sdd-lang-*/`. /sdd-init generates it by reading the repo. The
# loop reads it before writing the first test — above all for the command that
# runs ONE test, because the red and green observations are the evidence this
# whole plugin produces and "I ran the suite" is not that evidence.
#
# This script exists so discovery is deterministic. The alternative is each
# skill guessing at paths, which fails silently in the one direction that
# matters: no guide found, tests written from stock knowledge of the ecosystem,
# and nobody can tell afterwards which of the two happened.
#
# Output:
#   guides=<n>
#   guide=<repo-relative path>      (one line per guide, in sort order)
# and when there are none, the one-line instruction to run /sdd-init.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

found=()
for d in "$REPO_ROOT"/.claude/skills/sdd-lang-*/SKILL.md; do
  [ -f "$d" ] && found+=("${d#"$REPO_ROOT"/}")
done
# A plain file is honoured too. Not everyone wants a skill in .claude/skills,
# and the loop only ever reads this — it never invokes it as a skill.
for f in "$REPO_ROOT"/.claude/sdd-tdd/language.md "$REPO_ROOT"/.claude/sdd-tdd/language-*.md; do
  [ -f "$f" ] && found+=("${f#"$REPO_ROOT"/}")
done

echo "guides=${#found[@]}"
if [ "${#found[@]}" -eq 0 ]; then
  echo "No repo-local language guide. The loop will be writing tests from generic"
  echo "knowledge of the ecosystem rather than from this repo's conventions —"
  echo "run /sdd-init to generate one, and say so in the report if you proceed."
  exit 0
fi
printf 'guide=%s\n' "${found[@]}" | sort -u
