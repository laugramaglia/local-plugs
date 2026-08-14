#!/usr/bin/env bash
# Creates tracks/<area>/ (or tracks/<area>_<tasknumber>/) with the minimal
# skeleton (spec.md, contract.md, CHANGELOG.md), ONLY when locate-track.sh found
# no match.
#
# <tasknumber> (2nd arg, optional) is never a date and never auto-generated —
# it's the local task id, passed through by the skill when a variant track
# alongside a live one is really what's wanted.
#
# Usage: scaffold-track.sh <area> [tasknumber]
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

TRACKS_DIR_REL="$(tracks_dir_rel)"
TRACKS_DIR="$(tracks_dir)"

area="${1:-}"
tasknumber="${2:-}"
if [ -z "$area" ]; then
  echo "Usage: scaffold-track.sh <area> [tasknumber]"
  exit 2
fi
if ! [[ "$area" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "STOP HERE: '$area' doesn't match ^[a-z][a-z0-9-]*\$."
  exit 1
fi
if [ "$area" = "_lib" ]; then
  echo "STOP HERE: '_lib' is a helpers folder, not a track."
  exit 1
fi
if [ -n "$tasknumber" ] && ! [[ "$tasknumber" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
  echo "STOP HERE: tasknumber '$tasknumber' doesn't match ^[A-Za-z0-9][A-Za-z0-9-]*\$."
  exit 1
fi

folder_name="$area"
if [ -n "$tasknumber" ]; then
  folder_name="${area}_${tasknumber}"
fi

target="$TRACKS_DIR/$folder_name"
if [ -e "$target" ]; then
  echo "STOP HERE: $TRACKS_DIR_REL/$folder_name already exists. Run locate-track.sh again before creating one."
  exit 1
fi

if [ -n "$tasknumber" ] && [ -d "$TRACKS_DIR/$area" ]; then
  echo "NOTE: the live track $TRACKS_DIR_REL/$area/ already exists — this creates a"
  echo "variant alongside it, not a replacement. Confirm with the human that a"
  echo "separate variant (rather than working in the live track) is really what's"
  echo "needed here."
fi

echo "About to create $TRACKS_DIR_REL/$folder_name/ with spec.md, contract.md and CHANGELOG.md."
# shellcheck source=_confirm.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_confirm.sh"
if ! confirm_or_yes "create $TRACKS_DIR_REL/$folder_name/"; then
  echo "Cancelled. Nothing was created."
  exit 0
fi

mkdir -p "$target"
area="$folder_name"

cat > "$target/spec.md" <<EOF
# ${area} — spec

**Living reference: describes how the feature is TODAY.** Updated when closing
a change that alters behavior, or before coding if the change introduces or
modifies business rules.

## Functional requirements

(Declare each as a bold line — \`**RF-1 — title**\` — or a heading. Stable
headers: never renumbered when adding a new one, because every use case id and
every test name joins on \`RF-N\`.)

## Resolved contract

## Verified current state

## Test seams

(Output of probe-test-seams.sh for the scope this work touches. Written
BEFORE the use cases — it decides which \`Level\` values below are honest.
A Level this repo doesn't have means introducing that test level as part of
the work, which belongs in Gaps.)

## Use cases

(One table per RF: the success case, every error case with how it's handled, and
any other applicable state — pending/blocked/expired/etc. Enumerated here, not
just described in prose, so the TDD loop can turn each row into a test 1:1.
\`build-use-cases-manifest.sh\` parses these tables into use-cases.json, which is
what the loop actually consumes — so the 7 columns are a contract, not a style.)

### RF-1 — <title>

| # | Type | Level | Mode | Arrange | Act | Assert |
| --- | --- | --- | --- | --- | --- | --- |
| RF-1.1 | success | unit | red-first | <concrete starting values> | <trigger> | <observable check> |

- **Level** — \`unit\` / \`widget\` / \`golden\` / \`integration\` / \`manual\`.
  Must exist per "Test seams" above.
- **Mode** — \`red-first\` (new behavior: must fail before the change) or
  \`characterization\` (must-not-break: green before AND after). \`manual\`
  rows use \`—\`.
- **Arrange** — real values, not predicates ("minAmount=5000, amount=3000",
  not "amount below minimum").
- **Assert** — something an assertion can be written from.

## Acceptance criteria

## Out of scope

## Gaps

(Whatever couldn't be verified against a source of truth goes here and gets
asked — not guessed. Includes any test level this work would have to introduce.)
EOF

# Per-platform columns only make sense when this repo is actually two native
# codebases that need to be kept in parity. A single-codebase repo has nothing
# to put in them, so contract.md would sit permanently half-empty — detect the
# shape instead of assuming it.
if [ -d "$REPO_ROOT/android" ] && [ -d "$REPO_ROOT/ios" ]; then
  cat > "$target/contract.md" <<EOF
# ${area} — shared contract

Table of names and values shared between Android and iOS. Anything NOT listed
here is resolved by each platform as it sees fit.

| Category | Name | Value / mechanism | Kotlin | Swift |
| --- | --- | --- | --- | --- |
EOF
else
  cat > "$target/contract.md" <<EOF
# ${area} — contract

Table of names and values this feature depends on (limits, enums, endpoints,
fallbacks). Single codebase — no per-platform parity columns needed.

| Category | Name | Value / mechanism |
| --- | --- | --- |
EOF
fi

cat > "$target/CHANGELOG.md" <<EOF
# ${area} — changelog

One entry per change. Appended, never rewritten.
EOF

echo "Created: $TRACKS_DIR_REL/$area/{spec.md,contract.md,CHANGELOG.md}"
