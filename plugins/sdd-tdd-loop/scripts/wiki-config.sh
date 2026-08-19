#!/usr/bin/env bash
# Is there a business wiki to check requirements against, and where is it?
#
# Usage: wiki-config.sh
#
# This is the plugin's ONLY configuration, and it exists because it's the only
# question whose answer genuinely differs per project. Everything else — where
# tracks live, what the states are, where a phase ends — is a fixed constant in
# _common.sh, because a loop a human runs per task doesn't need to be told those.
#
# Resolution, in order:
#   1. `wikiRoot` in .claude/sdd-tdd-loop.json
#   2. business-docs/wiki/ if it exists (what the business-wiki plugin creates)
#   3. nothing — mode=off, silently
#
# Output is line-oriented so a skill reads it without parsing prose:
#   mode=off|optional|required
#   wiki=<repo-relative path>        (absent when mode=off)
#   rules=<repo-relative path>       (absent when there is no derived rules dir)
#   features=<n>
#
# mode=off is a SUPPORTED configuration, not a degraded one: plenty of projects
# have no documented business source, and the cross-check step is simply absent
# there — no warning, no gap entry blaming a missing wiki.
#
# mode=required (`"wikiRequired": true`) is for a project whose rule is that a
# spec derived from the code instead of the documented behaviour is worse than
# no spec. There, a missing wiki is a hard stop, and this script exits 1 to say
# so rather than quietly downgrading.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_config || exit 1

required="$(cfg '.wikiRequired' 'false')"
wiki_rel="$(cfg '.wikiRoot')"
rules_rel="$(cfg '.rulesRoot')"

configured=1
if [ -z "$wiki_rel" ]; then
  configured=0
  wiki_rel="business-docs/wiki"
fi

if [ ! -d "$REPO_ROOT/$wiki_rel" ]; then
  if [ "$required" = "true" ]; then
    echo "mode=required"
    echo "wiki=$wiki_rel"
    echo "STOP HERE: wikiRequired is true but $wiki_rel doesn't exist." >&2
    echo "Either create it (/business-wiki:bootstrap) or drop wikiRequired." >&2
    exit 1
  fi
  if [ "$configured" -eq 1 ]; then
    # An explicitly configured path that isn't there is a typo, not a project
    # without a wiki. Saying mode=off would hide it.
    echo "mode=off"
    echo "WARNING: wikiRoot '$wiki_rel' is configured but doesn't exist — treating as off." >&2
    exit 0
  fi
  echo "mode=off"
  exit 0
fi

# The derived rules dir is business-wiki's sibling of the wiki. Looked up rather
# than assumed, because a project may have the wiki and not run /derive.
if [ -z "$rules_rel" ]; then
  rules_rel="$(dirname "$wiki_rel")/rules"
fi

if [ "$required" = "true" ]; then
  echo "mode=required"
else
  echo "mode=optional"
fi
echo "wiki=$wiki_rel"
[ -d "$REPO_ROOT/$rules_rel" ] && echo "rules=$rules_rel"

if [ -d "$REPO_ROOT/$wiki_rel/features" ]; then
  n=$(find "$REPO_ROOT/$wiki_rel/features" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)
  echo "features=${n:-0}"
else
  # A wiki with no features/ dir is a bootstrapped-but-unwritten one. Worth
  # saying, because "the wiki exists" and "the wiki documents anything" are
  # different facts and only the second one helps write a spec.
  echo "features=0"
fi
