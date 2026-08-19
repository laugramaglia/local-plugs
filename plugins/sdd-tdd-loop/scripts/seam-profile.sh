#!/usr/bin/env bash
# Which test seams does THIS repo have, and how are they recognised?
#
# SOURCE this for the functions; RUN it to print the resolved profile:
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seam-profile.sh"
#   seam_profile_resolve || exit 1
#
# Why this file exists: the seam probe used to carry a hardcoded marker table for
# Dart/Kotlin/Swift, TS/JS and Python. That made the *process* — spec, enumerated
# use cases, red/green/refactor — pretend to be language knowledge, and a repo in
# any other ecosystem paid for it twice: the probe reported "no test suite", and
# intake then marked every use case `manual`. A C# repo with a full xunit suite
# probed as NONE.
#
# So the marker table is data now. The plugin ships the old table as the default
# (templates/seams.default.json), a repo overrides it with a profile of its own,
# and language knowledge lives in the repo that speaks the language — see
# /sdd-init, which writes both the profile and a repo-local language skill.
#
# Resolution, in order — first hit wins, nothing is merged:
#   1. $SDD_TDD_SEAMS                       (a file path; for tests and one-offs)
#   2. .claude/sdd-tdd/seams.json
#   3. `.seams` in .claude/sdd-tdd-loop.json  (with an optional `.testFilePattern`)
#   4. templates/seams.default.json          the built-in table
#
# A profile that exists but is wrong is a STOP, never a silent fall-through to
# the default: degrading quietly reproduces the original bug invisibly, and the
# only symptom is a spec full of `manual` rows nobody questions.
#
# Profile shape:
#   {
#     "testFilePattern": "<regex: which files are TEST files>",
#     "seams": [ { "name": "unit", "globs": ["*.cs"], "marker": "<regex>" } ]
#   }
#
# Seam names ARE the `Level` vocabulary of the use-case tables, which is why they
# are validated here rather than in the probe: build-use-cases-manifest.sh reads
# the same list, so a repo that drops `widget` and keeps `unit integration golden`
# gets a table that can't promise a level it has no way to test. `manual` is
# always legal and never a seam — no probe can detect a human.

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

PLUGIN_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEAM_DEFAULT_PROFILE="$PLUGIN_ROOT_DIR/templates/seams.default.json"
SEAMS_CONFIG_REL=".claude/sdd-tdd/seams.json"

# Set by seam_profile_resolve. The JSON is carried in a variable rather than a
# path because source 3 isn't a file — it's a key inside the config file — and
# every reader downstream should be unable to tell the difference.
SEAM_PROFILE_JSON=""
SEAM_PROFILE_LABEL=""
SEAM_PROFILE_ORIGIN=""
SEAM_TEST_FILE_RE=""
SEAM_PATTERN_INHERITED=0

_seam_default_pattern() {
  jq -r '.testFilePattern' "$SEAM_DEFAULT_PROFILE" 2>/dev/null
}

# seam_profile_resolve — find, validate and load the profile. Returns 1 with a
# STOP HERE on stdout when the profile is unusable.
seam_profile_resolve() {
  require_tools jq || return 1

  local raw=""
  if [ -n "${SDD_TDD_SEAMS:-}" ]; then
    if [ ! -f "$SDD_TDD_SEAMS" ]; then
      echo "STOP HERE: SDD_TDD_SEAMS points at '$SDD_TDD_SEAMS', which isn't a file."
      return 1
    fi
    raw="$(cat "$SDD_TDD_SEAMS")"
    SEAM_PROFILE_LABEL="$SDD_TDD_SEAMS"
    SEAM_PROFILE_ORIGIN="env"
  elif [ -f "$REPO_ROOT/$SEAMS_CONFIG_REL" ]; then
    raw="$(cat "$REPO_ROOT/$SEAMS_CONFIG_REL")"
    SEAM_PROFILE_LABEL="$SEAMS_CONFIG_REL"
    SEAM_PROFILE_ORIGIN="repo"
  elif [ -f "$CONFIG" ] && jq -e '.seams' "$CONFIG" >/dev/null 2>&1; then
    raw="$(jq '{testFilePattern: .testFilePattern, seams: .seams}' "$CONFIG" 2>/dev/null)"
    SEAM_PROFILE_LABEL="$(basename "$CONFIG") (.seams)"
    SEAM_PROFILE_ORIGIN="config"
  else
    raw="$(cat "$SEAM_DEFAULT_PROFILE" 2>/dev/null)"
    SEAM_PROFILE_LABEL="built-in default"
    SEAM_PROFILE_ORIGIN="default"
    if [ -z "$raw" ]; then
      echo "STOP HERE: the built-in seam profile is missing from the plugin"
      echo "($SEAM_DEFAULT_PROFILE). Reinstall the plugin."
      return 1
    fi
  fi

  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    echo "STOP HERE: the seam profile ($SEAM_PROFILE_LABEL) is not valid JSON."
    return 1
  fi

  local n
  n="$(printf '%s' "$raw" | jq -r 'if (.seams|type) == "array" then (.seams|length) else -1 end')"
  if [ "$n" = "-1" ]; then
    echo "STOP HERE: the seam profile ($SEAM_PROFILE_LABEL) has no \`seams\` array."
    echo "Shape: { \"testFilePattern\": \"<regex>\", \"seams\": [ { \"name\": …, \"globs\": […], \"marker\": \"<regex>\" } ] }"
    return 1
  fi
  if [ "$n" = "0" ]; then
    # An empty list would probe as "this repo can test nothing", i.e. every use
    # case manual — the failure this whole mechanism exists to stop.
    echo "STOP HERE: the seam profile ($SEAM_PROFILE_LABEL) lists no seams."
    echo "A profile with no seams makes every use case manual. Delete the file to"
    echo "fall back to the built-in table, or run /sdd-init to generate one."
    return 1
  fi

  # Per-seam validation. Reported all at once: fixing a profile one error per run
  # is the kind of loop that ends in someone deleting the file.
  local problems i name marker globs
  problems=""
  for ((i = 0; i < n; i++)); do
    name="$(printf '%s' "$raw" | jq -r ".seams[$i].name // \"\"")"
    marker="$(printf '%s' "$raw" | jq -r ".seams[$i].marker // \"\"")"
    globs="$(printf '%s' "$raw" | jq -r "if (.seams[$i].globs|type) == \"array\" then (.seams[$i].globs|length) else -1 end")"

    if ! printf '%s' "$name" | grep -qE '^[a-z][a-z0-9-]*$'; then
      problems+="  seams[$i]: name '$name' must match ^[a-z][a-z0-9-]* — it becomes a \`Level\` value"$'\n'
      continue
    fi
    if [ "$name" = "manual" ]; then
      problems+="  seams[$i]: 'manual' is not a seam — no probe detects a human. It is always a legal Level."$'\n'
      continue
    fi
    [ -n "$marker" ] || problems+="  seams[$i] ($name): no \`marker\` regex"$'\n'
    [ "$globs" != "-1" ] && [ "$globs" != "0" ] || problems+="  seams[$i] ($name): \`globs\` must be a non-empty array, e.g. [\"*.cs\"]"$'\n'
  done
  if [ -n "$problems" ]; then
    echo "STOP HERE: the seam profile ($SEAM_PROFILE_LABEL) is malformed:"
    printf '%s' "$problems"
    return 1
  fi

  local dupes
  dupes="$(printf '%s' "$raw" | jq -r '[.seams[].name] | group_by(.) | map(select(length>1) | .[0]) | join(", ")')"
  if [ -n "$dupes" ]; then
    echo "STOP HERE: the seam profile ($SEAM_PROFILE_LABEL) repeats seam name(s): $dupes."
    return 1
  fi

  SEAM_TEST_FILE_RE="$(printf '%s' "$raw" | jq -r '.testFilePattern // ""')"
  if [ -z "$SEAM_TEST_FILE_RE" ]; then
    # Inherited rather than required: a hand-written profile that only names
    # markers is a reasonable thing to write, and the built-in pattern already
    # covers test/, __tests__/, *_test.*, *Tests.*, conftest.py. The probe prints
    # that it was inherited, because a wrong answer has to stay traceable.
    SEAM_TEST_FILE_RE="$(_seam_default_pattern)"
    SEAM_PATTERN_INHERITED=1
  fi

  SEAM_PROFILE_JSON="$raw"
  return 0
}

# seam_count / seam_at <i> <field> — the loaded profile, read one field at a
# time. `globs` comes back space-separated, which is what grep --include wants.
seam_count() { printf '%s' "$SEAM_PROFILE_JSON" | jq -r '.seams | length'; }

seam_at() {
  local i="$1" field="$2"
  case "$field" in
    globs) printf '%s' "$SEAM_PROFILE_JSON" | jq -r ".seams[$i].globs | join(\" \")" ;;
    *)     printf '%s' "$SEAM_PROFILE_JSON" | jq -r ".seams[$i].$field // \"\"" ;;
  esac
}

# seam_names — one per line, in profile order.
seam_names() { printf '%s' "$SEAM_PROFILE_JSON" | jq -r '.seams[].name'; }

# seam_levels — the legal `Level` vocabulary: every seam, plus manual. This is
# the single definition; build-use-cases-manifest.sh has no list of its own.
seam_levels() { { seam_names; echo manual; } | tr '\n' ' ' | sed 's/ $//'; }

# Run directly: report what resolved. Useful on its own ("which profile am I
# getting?") and it's what /sdd-init prints after writing one.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  seam_profile_resolve || exit 1
  echo "profile=$SEAM_PROFILE_LABEL"
  echo "origin=$SEAM_PROFILE_ORIGIN"
  echo "seams=$(seam_names | tr '\n' ' ' | sed 's/ $//')"
  echo "levels=$(seam_levels)"
  echo "testFilePattern=$SEAM_TEST_FILE_RE"
  [ "$SEAM_PATTERN_INHERITED" -eq 1 ] && echo "note=testFilePattern inherited from the built-in default"
  exit 0
fi
