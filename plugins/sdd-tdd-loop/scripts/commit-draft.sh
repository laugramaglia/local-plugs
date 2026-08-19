#!/usr/bin/env bash
# Everything a conventional-commit message can be derived from, printed in one
# read-only pass: what changed, which scope it belongs to, what the track says
# about it, and which questions are left for a human.
#
# READ-ONLY. It runs `git status`/`diff`/`log` and NOTHING that writes: no add,
# no commit, no push. The mutation is issued by /sdd-commit itself, in the
# conversation, where a human can see the command before it runs. That's the
# same reason the rest of this plugin keeps its gates one level up.
#
# Usage: commit-draft.sh [area]
#   area  the track this work belongs to, when there is one. With it, the draft
#         can name the use case the commit closes and its evidence; without it
#         the draft is derived from the diff alone, which is a weaker but valid
#         answer — plenty of commits (a README, a config) belong to no track.
#
# Output is line-oriented, then three markdown blocks: `## subject candidates`,
# `## body`, `## open questions`. It deliberately does not pick one subject: the
# diff says which FILES changed, and a conventional-commit subject says what the
# change DOES — no script can bridge that, and one that pretended to would
# produce "update files" messages nobody reads twice.
set -uo pipefail

# shellcheck source=_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

area="${1:-}"

if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "STOP HERE: $REPO_ROOT is not a git repository — nothing to commit."
  exit 1
fi

g() { git -C "$REPO_ROOT" "$@"; }

echo "# commit draft"
echo "branch=$(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
upstream="$(g rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
echo "upstream=${upstream:-none}"

staged=$(g diff --cached --name-only | grep -c . || true)
unstaged=$(g diff --name-only | grep -c . || true)
untracked=$(g ls-files --others --exclude-standard | grep -c . || true)
echo "staged=$staged unstaged=$unstaged untracked=$untracked"

if [ "$staged" -eq 0 ] && [ "$unstaged" -eq 0 ] && [ "$untracked" -eq 0 ]; then
  echo
  echo "NOTHING TO COMMIT — the tree is clean. Not an error: say so and stop."
  exit 0
fi

# What the message will be ABOUT. Staged wins when anything is staged: a partly
# staged tree is a deliberate act, and drafting from everything would describe a
# commit the human isn't making.
if [ "$staged" -gt 0 ]; then
  echo "drafting-from=staged"
  changed="$(g diff --cached --name-only)"
else
  echo "drafting-from=worktree+untracked"
  changed="$({ g diff --name-only; g ls-files --others --exclude-standard; } | sort -u)"
fi

echo
echo "## files, grouped"
# Grouped by the second path component in a plugins/ layout, first otherwise:
# that's the unit a `scope` names, and a diff spanning two of them is the signal
# for a split rather than a scope covering both.
printf '%s\n' "$changed" | awk -F/ '
  $1 == "plugins" && NF > 1 { key = $1 "/" $2; next_key = 1 }
  $1 != "plugins" { key = (NF > 1 ? $1 : "(root)") }
  { count[key]++ }
  END { for (k in count) printf "group=%s files=%d\n", k, count[k] }
' | sort

groups=$(printf '%s\n' "$changed" | awk -F/ '
  $1 == "plugins" && NF > 1 { print $1 "/" $2; next }
  { print (NF > 1 ? $1 : "(root)") }
' | sort -u | grep -c . || true)

echo
echo "## scope candidates"
printf '%s\n' "$changed" | awk -F/ '$1 == "plugins" && NF > 1 { print "scope=" $2 }' | sort -u
[ -n "$area" ] && echo "scope=$area (the track)"
printf '%s\n' "$changed" | awk -F/ 'NF == 1 { print "scope=(root — omit it)" }' | sort -u

if [ "$groups" -gt 1 ]; then
  echo
  echo "SPLIT: this diff spans $groups groups. One commit per group, in dependency"
  echo "order — a scope that covers two unrelated changes is a scope that means"
  echo "nothing, and it's the reason a bisect lands on a 600-line commit."
fi

echo
echo "## type evidence"
# Evidence, not a verdict. Which files changed is a fact; whether the change is
# a feat or a fix is a claim about intent, and only the person who made it knows.
prod=0; tests=0; docs=0; chore=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    */test/*|*/tests/*|*_test.*|*.test.*|*.spec.*|test/*) tests=$((tests+1)) ;;
    *.md)                                                 docs=$((docs+1)) ;;
    *.json|*.yml|*.yaml|.gitignore|*.lock)                chore=$((chore+1)) ;;
    *)                                                    prod=$((prod+1)) ;;
  esac
done <<EOF
$changed
EOF
echo "code=$prod tests=$tests docs=$docs config=$chore"
if [ "$prod" -eq 0 ] && [ "$tests" -gt 0 ] && [ "$docs" -eq 0 ]; then
  echo "type=test is the honest one — only test files changed."
elif [ "$prod" -eq 0 ] && [ "$docs" -gt 0 ] && [ "$tests" -eq 0 ]; then
  echo "type=docs is the honest one — only prose changed."
else
  echo "type: feat | fix | refactor | perf — the diff can't tell these apart."
  echo "  feat     behaviour that wasn't there before"
  echo "  fix      behaviour that was wrong; say what it did wrong, in the body"
  echo "  refactor same behaviour, and the tests that prove it are unchanged"
fi
added=$(g diff --cached --diff-filter=A --name-only 2>/dev/null | grep -c . || true)
deleted=$(g diff --cached --diff-filter=D --name-only 2>/dev/null | grep -c . || true)
[ "$staged" -eq 0 ] && deleted=$(g diff --diff-filter=D --name-only | grep -c . || true)
echo "added=$added deleted=$deleted"
[ "$deleted" -gt 0 ] && echo "note: $deleted deletion(s) — say in the body what replaced them, or a reader has to guess."

# --- the track, when there is one -------------------------------------------
if [ -n "$area" ]; then
  echo
  echo "## the track"
  spec="$(track_dir "$area")/spec.md"
  cases="$(track_dir "$area")/use-cases.json"
  if [ ! -f "$spec" ]; then
    echo "STOP HERE: tracks/$area has no spec.md — wrong area, or intake hasn't run."
    exit 1
  fi
  echo "track=tracks/$area"
  if [ -f "$cases" ] && command -v jq >/dev/null 2>&1; then
    jq -r '
      (.cases // []) as $c
      | "cases=\($c|length) refactored=\([$c[]|select(.status=="refactored")]|length) green=\([$c[]|select(.status=="green")]|length) red=\([$c[]|select(.status=="red" or .status=="pinned")]|length) pending=\([$c[]|select(.status=="pending")]|length) blocked=\([$c[]|select(.status=="blocked")]|length)"
    ' "$cases" 2>/dev/null || echo "cases=unreadable"
    # The cases in flight are what this commit is most likely about, and their
    # Assert column is the one sentence a subject line should be derived from.
    echo
    echo "in flight (a subject line derives from the Assert, not from the file list):"
    jq -r '(.cases // [])[] | select(.status=="red" or .status=="pinned" or .status=="green")
           | "  \(.id) \(.level)/\(.mode) status=\(.status) assert=\(.assert)"' "$cases" 2>/dev/null || true
  else
    echo "cases=none (no use-cases.json — this track never went through intake)"
  fi
fi

echo
echo "## subject candidates"
echo '<type>(<scope>): <what the change does, imperative, no trailing period>'
echo
echo "Rules this repo's history already follows, so match them:"
echo "  - lower-case subject, no period, imperative mood"
echo "  - one line, under ~72 chars; the WHY goes in the body"
echo "  - a breaking change is 'type(scope)!: …' plus a BREAKING CHANGE footer"
echo "  - RF ids belong in the body or the subject's tail, never as the whole subject:"
echo "    'RF-1.2' tells a reader nothing a year later"

echo
echo "## body"
echo "What a reader needs and cannot get from the diff:"
echo "  - what was wrong / missing before, concretely (the failure, not the file)"
echo "  - why this shape and not the obvious alternative"
echo "  - the evidence: which test was observed red, then green"
echo "  - anything deliberately left out, and why"

echo
echo "## open questions"
q=0
if [ "$groups" -gt 1 ]; then echo "  - split into $groups commits, or is this genuinely one change?"; q=$((q+1)); fi
if [ "$staged" -eq 0 ] && [ "$untracked" -gt 0 ]; then
  echo "  - $untracked untracked file(s): in this commit, or not yet? Never 'git add -A' to decide."
  q=$((q+1))
fi
if [ "$prod" -gt 0 ] && [ "$tests" -eq 0 ]; then
  echo "  - code changed and no test did. Deliberate, or is the test missing?"
  q=$((q+1))
fi
if [ -z "$area" ]; then
  echo "  - which track is this? Pass the area to tie the message to its use cases."
  q=$((q+1))
fi
[ "$q" -eq 0 ] && echo "  (none the diff can raise — ask about intent, not about files.)"

echo
echo "## commands (yours to run, after the message is agreed)"
echo "  git add <the paths you named>        # never -A"
echo "  git commit -F <message-file>"
