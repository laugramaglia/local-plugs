#!/usr/bin/env bash
# Does the feature module this use case targets already exist?
#
# Usage: probe-scaffold-need.sh <feature-name> [platform ...]
#   <feature-name>  the feature's short name, e.g. `loans` (not a path)
#   [platform]      one or more keys of featureModules in the config;
#                   default: all declared platforms
#
# This is the gate for step 3 of /sdd-tdd-implement, and its ORDER is the whole
# point. The scaffold check runs AFTER the failing test is written and observed
# red — not before. Writing a test touches no feature code, so there is nothing
# to scaffold at that moment; asking earlier means asking about code that may
# never need to exist. A `characterization` row over an existing feature, for
# instance, never reaches this script at all.
#
# It answers one question and takes no action: scaffolding is a human-gated MCP
# call (Gate 1), and this script neither makes it nor pretends it could.
#
# Exit codes are the interface, so the loop can branch without parsing prose:
#   0  EXISTS      every requested platform already has the module
#   3  NEEDED      at least one platform is missing it -> Gate 1
#   4  UNDECLARED  the project didn't say where feature modules live
#
# UNDECLARED is deliberately NOT "no scaffold needed". A project with no
# featureModules block hasn't told us where to look, and answering "nothing to
# scaffold" from that would be a guess dressed as a finding.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_tools jq || exit 1

feature="${1:-}"
if [ -z "$feature" ]; then
  echo "Usage: probe-scaffold-need.sh <feature-name> [platform ...]"
  exit 2
fi
shift || true

if [ ! -f "$CONFIG" ]; then
  echo "UNDECLARED — no config at $CONFIG."
  exit 4
fi

if ! jq -e '.featureModules' "$CONFIG" >/dev/null 2>&1; then
  echo "UNDECLARED — this project declares no 'featureModules' in $CONFIG."
  echo "  Without it there is no way to know where a feature module would live,"
  echo "  so whether one needs scaffolding is a question for a human, not a guess."
  echo "  Declare it as: \"featureModules\": { \"android\": \"android/feature/{name}\" }"
  exit 4
fi

# Which platforms to probe: explicit args win, else every declared key.
platforms=()
if [ "$#" -gt 0 ]; then
  for p in "$@"; do platforms+=("$p"); done
else
  while IFS= read -r p; do
    [ -n "$p" ] && platforms+=("$p")
  done < <(jq -r '.featureModules | keys[]' "$CONFIG")
fi

if [ "${#platforms[@]}" -eq 0 ]; then
  echo "UNDECLARED — 'featureModules' in $CONFIG has no platforms."
  exit 4
fi

# {name} -> loans, {Name} -> Loans. Two placeholders because the two platforms
# genuinely disagree about casing (android/feature/loans vs FeatureLoans), and
# forcing one convention on both would just move the special case elsewhere.
name_lower=$(printf '%s' "$feature" | tr '[:upper:]' '[:lower:]')
first=$(printf '%s' "$name_lower" | cut -c1 | tr '[:lower:]' '[:upper:]')
rest=$(printf '%s' "$name_lower" | cut -c2-)
name_upper="$first$rest"

missing=0
unknown_platform=0

for p in "${platforms[@]}"; do
  template=$(jq -r --arg p "$p" '.featureModules[$p] // empty' "$CONFIG")
  if [ -z "$template" ]; then
    echo "  $p: STOP HERE — '$p' is not a key of featureModules."
    echo "     Known: $(jq -r '.featureModules | keys | join(", ")' "$CONFIG")"
    unknown_platform=1
    continue
  fi

  path="${template//\{name\}/$name_lower}"
  path="${path//\{Name\}/$name_upper}"

  if [ -d "$REPO_ROOT/$path" ]; then
    echo "  $p: exists    $path"
  else
    echo "  $p: MISSING   $path"
    missing=1
  fi
done

# A typo'd platform key must not read as "nothing missing" — that's the same
# fail-open shape as a WIQL query with a wrong state name returning zero items.
if [ "$unknown_platform" -eq 1 ]; then
  echo "UNDECLARED — at least one requested platform isn't declared."
  exit 4
fi

if [ "$missing" -eq 1 ]; then
  echo "NEEDED — '$feature' has no module on at least one platform."
  echo "  Scaffolding is Gate 1: a human approves scope + the contract delta first."
  echo "  The loop must stop here and record it as a note on the task; it must"
  echo "  not generate the module itself."
  exit 3
fi

echo "EXISTS — '$feature' already has a module on every requested platform."
echo "  No scaffold, no Gate 1: go straight to making the red test pass."
exit 0
