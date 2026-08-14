#!/usr/bin/env bash
# Which subagents does THIS project use to implement and audit a use case?
#
# Usage: agents-config.sh [--platform <key>]
#
# Same principle as crosscheck-config.sh: the plugin names no project's agents
# anywhere in its code. /sdd-tdd-implement asks here instead of carrying a
# specific per-platform agent name around in its instructions — such an agent
# exists in exactly one repo, and a skill that names it is a skill that only
# works in that repo. The test suite asserts this file stays free of them.
#
# Output is line-oriented (`key=value`), one fact per line, so a skill can read
# it without parsing prose:
#   implement_<platform>=<agent name>   one per declared platform
#   parity=<agent name>                 or absent
#   mode=agents|self
#
# mode=self is a supported answer, not a degraded one: it means the project
# declared no agents and the loop should do the work itself, in the same order.
# Inventing an agent name would be worse than doing it inline.
set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

want_platform=""
if [ "${1:-}" = "--platform" ]; then
  want_platform="${2:-}"
  [ -n "$want_platform" ] || { echo "Usage: agents-config.sh [--platform <key>]"; exit 2; }
fi

if ! require_config; then
  echo "mode=self"
  exit 0
fi
if ! require_tools jq >/dev/null 2>&1; then
  echo "mode=self"
  exit 0
fi

if ! jq -e '.implementAgents' "$CONFIG" >/dev/null 2>&1; then
  echo "mode=self"
  echo "# No 'implementAgents' declared in $CONFIG."
  echo "# The loop writes the test and the implementation itself, same order."
  exit 0
fi

if [ -n "$want_platform" ]; then
  agent=$(cfg_raw --arg p "$want_platform" '.implementAgents[$p] // empty')
  if [ -z "$agent" ]; then
    echo "STOP HERE: '$want_platform' is not a key of implementAgents in $CONFIG."
    echo "Known: $(cfg_raw '.implementAgents | keys | join(", ")')"
    exit 1
  fi
  echo "implement_$want_platform=$agent"
  exit 0
fi

echo "mode=agents"
cfg_raw '.implementAgents | to_entries[] | "implement_\(.key)=\(.value)"'

parity=$(cfg '.parityAgent')
if [ -n "$parity" ]; then
  echo "parity=$parity"
else
  # Not a warning: parity only means something with two or more platforms, and
  # plenty of projects have one.
  echo "# no parityAgent declared — skip the parity step"
fi
