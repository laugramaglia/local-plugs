#!/usr/bin/env bash
# Resolve the domain-knowledge cross-check configuration and print it as
# shell-ish key=value lines, so the skill has one place to read it from instead
# of a hardcoded MCP name.
#
# Usage: crosscheck-config.sh          # key=value lines
#        crosscheck-config.sh --tools  # just the tool names, one per line
#
# Why this exists: naming a specific MCP server here would make the plugin
# unusable on any project without that server, and would turn a transient MCP
# outage into a hard abort. The source of domain truth is a per-project choice:
# name its tools in `crossCheck.tools` and pick how strict it is with
# `crossCheck.mode`.
#
# `crossCheck` may be null or absent entirely — that is a supported, silent
# configuration meaning "this project has no domain-knowledge MCP". No warning,
# no degraded-mode noise: mode=off and the procedure simply doesn't have that
# step. Same for `crossCheck.tools` being null or {}.
#
# Modes:
#   required  the cross-check must run. If the tools aren't available the run
#             ABORTS without writing a spec. Pick this when a project's rules
#             say a spec derived from code instead of documented rules is worse
#             than no spec — a project whose rules say business behaviour is
#             never inferred from code wants this.
#   optional  (default when tools ARE declared) try it; if the tools aren't
#             there, SKIP the cross-check, record that fact in spec.md's Gaps
#             and in the task note, and carry on. The spec still gets
#             written — it just says, in writing, that nothing was verified
#             against a domain source.
#   off       no cross-check at all. Implied by a null/absent `crossCheck`.
#
# Availability is decided by the CALLER, not here: an agent knows which MCP
# tools it actually has, and no shell test can tell "server configured" from
# "server responding". This script only reports what's configured.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

mode="off"
label="domain knowledge source"
tools=""
declared="no"

if [ -f "$CONFIG" ] && command -v jq >/dev/null 2>&1; then
  # null and absent are the same thing here, and both are legitimate.
  if jq -e '.crossCheck != null' "$CONFIG" >/dev/null 2>&1; then
    declared="yes"
    tools=$(jq -r '(.crossCheck.tools // {}) | to_entries[] | "\(.key)=\(.value)"' "$CONFIG" 2>/dev/null)

    m=$(jq -r '.crossCheck.mode // empty' "$CONFIG")
    case "$m" in
      required|optional|off) mode="$m" ;;
      "") [ -n "$tools" ] && mode="optional" ;;   # tools declared, strictness not
      *)  mode="optional"
          echo "WARNING: crossCheck.mode '$m' is not one of required|optional|off — treating as optional." >&2 ;;
    esac

    l=$(jq -r '.crossCheck.label // empty' "$CONFIG")
    [ -n "$l" ] && label="$l"
  fi
fi

# A mode that needs a source but has none named is a config error worth saying
# out loud — but only when someone actually declared crossCheck. A project that
# left it null gets silence.
if [ -z "$tools" ] && [ "$mode" != "off" ]; then
  echo "WARNING: crossCheck.mode is '$mode' but crossCheck.tools names nothing — treating as off." >&2
  mode="off"
fi

# Nothing declared at all: stay silent. This is a normal configuration.
[ "$declared" = "no" ] && mode="off"

if [ "${1:-}" = "--tools" ]; then
  [ -n "$tools" ] && echo "$tools" | sed 's/^[^=]*=//'
  exit 0
fi

echo "mode=$mode"
echo "label=$label"
[ -n "$tools" ] && echo "$tools" | sed 's/^/tool_/'
