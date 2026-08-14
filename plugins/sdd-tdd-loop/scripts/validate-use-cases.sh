#!/usr/bin/env bash
# Structural check of spec.md's "## Use cases" section — NOT semantic,
# doesn't judge whether the enumerated cases are correct, only whether every
# RF-N declared in "Functional requirements" has at least one RF-N.x row
# underneath it in Use cases. A requirement with zero enumerated cases
# isn't ready for a TDD loop to turn into test cases.
#
# Usage: validate-use-cases.sh <area>
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

TRACKS_DIR_REL="$(tracks_dir_rel)"

area="${1:-}"
if [ -z "$area" ]; then
  echo "Usage: validate-use-cases.sh <area>"
  exit 2
fi

spec="$REPO_ROOT/$TRACKS_DIR_REL/$area/spec.md"
if [ ! -f "$spec" ]; then
  echo "FAIL: $spec doesn't exist"
  exit 1
fi

ok=1

if ! grep -qiE '^#+ *use cases' "$spec"; then
  echo "FAIL: $spec has no '## Use cases' section."
  ok=0
else
  echo "OK: Use cases section present."

  # Only requirements actually DECLARED as such (a heading, or a bold line
  # starting the requirement, e.g. "### RF-1" or "**RF-1 — title**") count.
  # A plain mention of "RF-1" in prose — including scaffold-track.sh's own
  # placeholder text "(RF-1, RF-2, ... — stable headers...)" in a still-empty
  # "Functional requirements" section — must NOT be treated as a declared
  # requirement, or a freshly scaffolded track FAILs against a requirement
  # nobody wrote yet.
  # Stop at the next SAME-LEVEL heading, not any heading. Matching /^#+ /
  # meant a requirement written as "### RF-1 — title" terminated the section
  # on its own first line, so the scan found zero requirements — and the
  # branch below reported OK. That's how a spec with 5 RFs and 24 cases
  # passed this gate while nothing was actually checked.
  rf_section=$(awk '/^## +Functional requirements/{flag=1; next} /^## /{if (flag) exit} flag' "$spec")
  rf_headers=$(echo "$rf_section" | grep -oE '^(#+ *|\*\*)RF-[0-9]+\b' | grep -oE 'RF-[0-9]+' | sort -u)
  if [ -z "$rf_headers" ]; then
    # Fail loud. A gate that reports OK when it parsed nothing is worse than
    # no gate: the output is indistinguishable from a real pass, so a broken
    # scan looks exactly like a clean spec.
    echo "FAIL: no RF-N requirement declared under '## Functional requirements'."
    echo "      Declare each as a bold line, e.g. '**RF-1 — title**'."
    echo "      (If the spec really has no requirements yet, it isn't ready to validate.)"
    ok=0
  else
    while IFS= read -r rf; do
      [ -z "$rf" ] && continue
      if ! grep -qE "\b${rf}\.[0-9]+\b" "$spec"; then
        echo "FAIL: $rf has no enumerated ${rf}.x rows in Use cases."
        ok=0
      fi
    done <<< "$rf_headers"
    if [ "$ok" -eq 1 ]; then
      echo "OK: every RF-N has at least one enumerated case."
    fi
  fi

  # The rows must also be machine-readable, since use-cases.json is the handoff to
  # whatever runs the TDD loop. Delegating to the manifest builder keeps one
  # parser instead of two that can disagree about what a valid row is.
  if [ "$ok" -eq 1 ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! manifest_json=$(bash "$SCRIPT_DIR/build-use-cases-manifest.sh" "$area" --json 2>&1); then
      echo "$manifest_json" | sed 's/^/  /'
      ok=0
    elif ! printf '%s' "$manifest_json" | jq -e . >/dev/null 2>&1; then
      # The builder exited 0 but didn't emit JSON. Never treat that as a pass:
      # every jq read below would fail individually and the run would still
      # end in "OK", which is the fail-open bug this gate exists to avoid.
      echo "FAIL: the manifest builder returned non-JSON on --json:"
      printf '%s\n' "$manifest_json" | head -5 | sed 's/^/  /'
      ok=0
    else
      echo "$manifest_json" | jq -r '
        "OK: \(.summary.total) use cases machine-readable (\(.summary.automatable) automatable, \(.summary.manual) manual)."'
      # An RF whose every case is manual is a requirement the TDD loop cannot
      # touch. Not an error — some behavior genuinely only a human can check —
      # but the human needs to know at intake, not at implementation.
      manual_only=$(echo "$manifest_json" | jq -r '
        [.cases | group_by(.rf)[] | select(all(.[]; .automatable | not)) | .[0].rf] | join(" ")')
      if [ -n "$manual_only" ]; then
        echo "WARNING: only manual cases for: $manual_only"
        echo "         No TDD loop can implement these — they are QA acceptance, not tests."
      fi
    fi
  fi
fi

if [ "$ok" -eq 1 ]; then
  echo "validate-use-cases: OK"
else
  echo "validate-use-cases: FAIL"
  exit 1
fi
