#!/usr/bin/env bash
# Turn a task title into a filesystem-safe slug, by one rule that the skill and
# task.sh both use — so the task's `area`, the track folder name and anything a
# project derives from either can't drift apart or need a human to invent them.
#
# Usage: slugify.sh "67857 - GI0219 - Corrección de visualización del importe"
#        slugify.sh --max 40 "<title>"
#        slugify.sh --words 4 "<title>"     # first N words
#        slugify.sh --area 3 "<title>"      # short folder name: drops the
#                                           # ticket number, ticket codes like
#                                           # GI0219, and filler words, then
#                                           # takes the first N that are left
#
# `--area` is a FALLBACK. The skill should pick 2-3 meaningful words from the
# title itself (it can read the title; this can't) and pass those through here
# just to normalise them. Use --area when that yields nothing usable.
#
# Rules, in order:
#   - strip accents (Corrección -> Correccion) so the branch is pure ASCII
#   - lowercase
#   - anything that isn't [a-z0-9] becomes a single '-'
#   - collapse repeats, trim leading/trailing '-'
#   - drop a leading numeric segment when it's just a ticket number that the
#     caller is already carrying separately (--drop-leading-number)
#   - truncate to --max (default 60) without leaving a trailing '-'
#
# The output always matches ^[a-z0-9][a-z0-9-]*$ (or is empty, which the caller
# must treat as "couldn't derive one").
set -uo pipefail

max=60
words=0
drop_leading_number=0
strip_noise=0
prefixes=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max)   max="${2:-60}"; shift 2 ;;
    --words) words="${2:-0}"; shift 2 ;;
    --area)  words="${2:-3}"; drop_leading_number=1; strip_noise=1; max=40; shift 2 ;;
    --drop-leading-number) drop_leading_number=1; shift ;;
    --strip-noise) strip_noise=1; shift ;;
    # Repeatable. A literal prefix to remove from the front of the title, e.g.
    # --strip-prefix "Tracking:". Boards often carry a house prefix on every
    # title, and it names nothing.
    --strip-prefix) prefixes+=("${2:-}"); shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

raw="${1:-}"
[ -n "$raw" ] || { echo ""; exit 0; }

# Strip configured prefixes, case-insensitively, before anything else.
for p in ${prefixes+"${prefixes[@]}"}; do
  [ -n "$p" ] || continue
  lower_raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  lower_p=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  case "$lower_raw" in
    "$lower_p"*) raw="${raw:${#p}}" ;;
  esac
done
# Leading separators/whitespace left behind by the strip.
raw=$(printf '%s' "$raw" | sed 's/^[[:space:]:_-]\{1,\}//')

# Accent folding via Unicode decomposition: decompose, then drop the combining
# marks, so "Corrección" -> "Correccion".
#
# NOT iconv: on macOS `iconv -t ASCII//TRANSLIT` renders ó as "'o", which turns
# into "correcci-on" once punctuation becomes a separator. Perl's
# Unicode::Normalize is core and gives the right answer on both platforms.
folded=""
if command -v perl >/dev/null 2>&1; then
  folded=$(printf '%s' "$raw" \
    | perl -CSD -MUnicode::Normalize -pe '$_=NFD($_); s/\p{NonspacingMark}//g' 2>/dev/null || true)
fi
# No perl: drop non-ASCII outright. The accented letter is lost rather than
# transliterated, which is worse but still yields a usable, valid slug.
[ -z "$folded" ] && folded=$(printf '%s' "$raw" | tr -cd '\11\12\15\40-\176')

slug=$(printf '%s' "$folded" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-\{1,\}//; s/-\{1,\}$//')

# A leading pure-number segment is usually the task id, which callers pass
# separately — keeping it would double it up in the branch name.
if [ "$drop_leading_number" = "1" ]; then
  slug=$(printf '%s' "$slug" | sed 's/^[0-9]\{1,\}-//')
fi

# Drop the tokens that carry no meaning in a folder name: ticket codes
# (letters immediately followed by digits, e.g. gi0219), bare numbers, and
# Spanish/English filler. Without this, "--words 3" on
# "67857 - GI0219 - Corrección de visualización..." yields
# "gi0219-correccion-de", which names nothing.
if [ "$strip_noise" = "1" ]; then
  slug=$(printf '%s' "$slug" | tr '-' '\n' | awk '
    BEGIN {
      split("de del la el los las en y a un una the of for to in on at and or " \
            "con por para su sus lo al es se que no si", sw, " ")
      for (i in sw) stop[sw[i]] = 1
    }
    {
      if ($0 == "") next
      if ($0 in stop) next
      if ($0 ~ /^[0-9]+$/) next          # bare number (ticket id)
      if ($0 ~ /^[a-z]+[0-9]+$/) next    # ticket code: gi0219, abc123
      print
    }' | paste -sd '-' -)
fi

# Keep only the first N words when asked (used for the short `area` name).
if [ "$words" -gt 0 ]; then
  slug=$(printf '%s' "$slug" | cut -d- -f1-"$words")
fi

# Truncate on a word boundary — "...-en-la-s" reads like a typo, "...-en-la"
# reads like a shortened title.
if [ "${#slug}" -gt "$max" ]; then
  cut_char="${slug:$max:1}"
  slug="${slug:0:$max}"
  if [ -n "$cut_char" ] && [ "$cut_char" != "-" ]; then
    case "$slug" in *-*) slug="${slug%-*}" ;; esac
  fi
  slug=$(printf '%s' "$slug" | sed 's/-\{1,\}$//')
fi

# Must start with a letter or digit.
slug=$(printf '%s' "$slug" | sed 's/^-\{1,\}//')

printf '%s\n' "$slug"
