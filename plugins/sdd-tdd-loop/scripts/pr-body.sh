#!/usr/bin/env bash
# The pull-request body for one track, rendered from the track itself.
#
# READ-ONLY, like commit-draft.sh: it reads spec.md, use-cases.json, the task
# store and `git log`, and prints. It never pushes and never calls `gh` — the PR
# skill does that, in the conversation, so a human sees the command.
#
# Usage: pr-body.sh <area> [--base <ref>]
#   --base  what the PR would merge into; defaults to origin/HEAD, then main,
#           then master. Only used for the commit list.
#
# Why generate it instead of writing it once: the PR is opened as a DRAFT at the
# start of the work, when the spec exists and nothing is green yet, and it is
# rewritten every time a case lands. A body written by hand at minute one is
# wrong by minute thirty and nobody edits it; a generated one is the only kind
# that stays true. Everything between the two markers is replaced wholesale on
# each update, and everything outside them — a reviewer's note, a screenshot, a
# deploy caveat — survives untouched. That boundary is the whole contract:
#
#   <!-- sdd-tdd:begin --> … generated, yours to overwrite … <!-- sdd-tdd:end -->
#
# Output:
#   title=<one line>
#   ready=yes|no  <why>
#   then the body on stdout after a `--- body ---` line, so a caller can split
#   the two without parsing markdown.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

require_tools jq || exit 1

area="${1:-}"
base=""
shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 || true ;;
    *) echo "Unknown option '$1'. Usage: pr-body.sh <area> [--base <ref>]"; exit 2 ;;
  esac
done
if [ -z "$area" ]; then
  echo "Usage: pr-body.sh <area> [--base <ref>]"
  exit 2
fi
require_track "$area" || exit 1

dir="$(track_dir "$area")"
spec="$dir/spec.md"
cases="$dir/use-cases.json"
changelog="$dir/CHANGELOG.md"

g() { git -C "$REPO_ROOT" "$@"; }
in_git=no
g rev-parse --git-dir >/dev/null 2>&1 && in_git=yes

if [ -z "$base" ] && [ "$in_git" = yes ]; then
  # origin/HEAD is the only answer that isn't a guess; the fallbacks are, so the
  # body says which one was used rather than implying the diff is against main.
  base="$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -z "$base" ]; then
    for c in main master; do
      g rev-parse --verify --quiet "$c" >/dev/null 2>&1 && { base="$c"; break; }
    done
  fi
fi

# --- the task behind the track ----------------------------------------------
task_line=""
if [ -f "$(tasks_path)" ]; then
  task_line=$(jq -r --arg a "$area" '
    [.tasks[]? | select(.area == $a)] | if length == 0 then empty
    else (.[0] | "#\(.id) \(.title) — \(.state)") end' "$(tasks_path)" 2>/dev/null || true)
fi

# --- case counts -------------------------------------------------------------
have_cases=no
[ -f "$cases" ] && jq -e . "$cases" >/dev/null 2>&1 && have_cases=yes

if [ "$have_cases" = yes ]; then
  read -r n_all n_auto n_done n_cov n_green n_red n_pending n_blocked n_manual <<EOF
$(jq -r '
  (.cases // []) as $c
  | [ ($c|length),
      ([$c[]|select(.automatable)]|length),
      ([$c[]|select(.status=="refactored")]|length),
      ([$c[]|select(.status=="covered")]|length),
      ([$c[]|select(.status=="green")]|length),
      ([$c[]|select(.status=="red" or .status=="pinned")]|length),
      ([$c[]|select(.status=="pending" and .automatable)]|length),
      ([$c[]|select(.status=="blocked")]|length),
      ([$c[]|select(.automatable == false)]|length) ]
  | @tsv' "$cases")
EOF
else
  n_all=0; n_auto=0; n_done=0; n_cov=0; n_green=0; n_red=0; n_pending=0; n_blocked=0; n_manual=0
fi

# --- title -------------------------------------------------------------------
# Derived from the spec's H1, because that's the one line a human already wrote
# about this work. The type is left to the skill: `feat` vs `fix` is a claim
# about intent, and this script has no way to know which.
h1=$(sed -n 's/^# *//p' "$spec" | head -1 | sed 's/ *— *spec$//')
[ -n "$h1" ] || h1="$area"
echo "title=<type>($area): $h1"

# --- ready? ------------------------------------------------------------------
# The one question a draft PR exists to answer, and it is deliberately strict:
# `verify` means every automatable case was observed red then green, and a human
# still has to run it. Nothing here can decide that a PR is mergeable.
state=$(printf '%s' "$task_line" | sed 's/.*— //')
if [ "$have_cases" = no ]; then
  echo "ready=no  no use-cases.json — this track never went through intake"
elif [ "$n_blocked" -gt 0 ]; then
  echo "ready=no  $n_blocked blocked case(s) — a human is needed on those first"
elif [ "$n_pending" -gt 0 ] || [ "$n_red" -gt 0 ] || [ "$n_green" -gt 0 ]; then
  echo "ready=no  $((n_pending + n_red + n_green)) automatable case(s) not refactored yet"
elif [ "$state" = "verify" ] || [ "$state" = "done" ]; then
  echo "ready=yes every automatable case is refactored and the task is at $state"
else
  echo "ready=no  cases are done but the task is at '${state:-unknown}', not verify"
fi

echo "base=${base:-unknown}"
echo "--- body ---"

# --- body --------------------------------------------------------------------
echo "<!-- sdd-tdd:begin — generated by pr-body.sh; edits inside this block are overwritten -->"
echo
[ -n "$task_line" ] && { echo "**Task** $task_line"; echo; }
echo "**Track** \`tracks/$area/\` — [spec](tracks/$area/spec.md)"
echo

echo "## What this changes"
echo
# The requirement headings, verbatim: they were written to be read by a human
# reviewing the change, which is exactly this audience.
sed -n '/^## *[Ff]unctional requirements/,/^## /p' "$spec" \
  | grep -E '^\*\*RF-[0-9]+' \
  | sed -e 's/^\*\*//' -e 's/\*\*$//' -e 's/^/- /' || true
echo
echo "Requirements are the spec's, verbatim. If the change no longer matches them,"
echo "the spec is what to fix — not this description."
echo

if [ "$have_cases" = yes ]; then
  echo "## Evidence"
  echo
  echo "Each row is one test that was observed failing (or, for a characterization"
  echo "row, passing) before the change, and passing after it."
  echo
  echo "| Case | Level | Mode | Status | Assert |"
  echo "| --- | --- | --- | --- | --- |"
  jq -r '(.cases // [])[]
    | "| \(.id) | \(.level) | \(.mode) | \(.status)\(if .covered_by then " by \(.covered_by)" else "" end)\(if .blocked_reason then ": \(.blocked_reason)" else "" end) | \(.assert) |"' "$cases"
  echo
  echo "**$n_done refactored**, $n_cov covered, $n_green green, $n_red observed,"
  echo "$n_pending pending, $n_blocked blocked, of $n_auto automatable —"
  echo "plus $n_manual manual case(s) below, which no loop drives."
  echo
  if [ "$n_manual" -gt 0 ]; then
    echo "## Manual cases — for whoever reviews this"
    echo
    jq -r '(.cases // [])[] | select(.automatable == false)
      | "- [ ] **\(.id)** \(.arrange) → \(.assert)"' "$cases"
    echo
  fi
  if [ "$n_blocked" -gt 0 ]; then
    echo "## Blocked, and why"
    echo
    jq -r '(.cases // [])[] | select(.status=="blocked")
      | "- **\(.id)** \(.blocked_reason // "no reason recorded") — \(.assert)"' "$cases"
    echo
  fi
fi

if [ -f "$changelog" ]; then
  echo "## Changelog"
  echo
  sed -n '1,40p' "$changelog" | grep -vE '^# ' | sed '/^$/N;/^\n$/D'
  echo
fi

if [ "$in_git" = yes ] && [ -n "$base" ]; then
  echo "## Commits"
  echo
  if g rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
    commits="$(g log --oneline --no-decorate "$base..HEAD" 2>/dev/null | sed 's/^/- /' || true)"
    if [ -n "$commits" ]; then
      printf '%s\n' "$commits"
    else
      # Empty is a real state and worth naming: it's what a draft PR opened
      # before the first commit looks like, and it's also what you get when the
      # work went onto the base branch itself instead of a branch of its own.
      echo "- nothing ahead of \`$base\` yet"
    fi
  else
    echo "- base \`$base\` doesn't resolve here — commit list omitted rather than guessed"
  fi
  echo
fi

echo "## Gaps intake recorded"
echo
sed -n '/^## *Gaps/,$p' "$spec" | sed -n '2,20p' | grep -E '^\s*[-*]' || echo "- none"
echo
echo "<!-- sdd-tdd:end -->"
