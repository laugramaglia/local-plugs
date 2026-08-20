#!/bin/sh
# wiki-search.sh — lexical search over the wiki, scoped by the index.
#
#   sh wiki-search.sh <query> [--feature f] [--page p] [--status s] [--kind k]
#                             [--paths-only]
#
# Three passes, deterministic first:
#   1. name resolution — a query that IS a link name, alias, or page title
#      resolves straight to its file, with no search at all.
#   2. glossary expansion — a query that is a glossary term, or one of the
#      per-layer names under its "In code:" line, also searches the others. The
#      glossary exists because the client, the wire and the database name the
#      same concept differently; that is exactly the gap a lexical search cannot
#      close on its own, and it is closed here by a table a human reviewed
#      rather than by an embedding. --no-synonyms turns it off.
#   3. body search — ripgrep (or grep) over exactly the files the filters allow.
#
# --page is the page kind inside a feature (flow, states, validations, ...),
# --kind is feature|shared|decision|root.
#
# POSIX sh; uses ripgrep when it is on PATH and grep otherwise. Run from the
# project root.

set -u

HERE=$(dirname "$0")
. "$HERE/lib-wiki.sh"

QUERY=""
F_FEATURE=""
F_PAGE=""
F_STATUS=""
F_KIND=""
PATHS_ONLY=no
SYNONYMS=yes

while [ $# -gt 0 ]; do
	case "$1" in
	--feature) shift; F_FEATURE="${1:-}" ;;
	--page) shift; F_PAGE="${1:-}" ;;
	--status) shift; F_STATUS="${1:-}" ;;
	--kind) shift; F_KIND="${1:-}" ;;
	--paths-only) PATHS_ONLY=yes ;;
	--no-synonyms) SYNONYMS=no ;;
	-*)
		printf 'wiki-search: unknown flag: %s\n' "$1" >&2
		exit 2
		;;
	*) [ -n "$QUERY" ] || QUERY="$1" ;;
	esac
	shift
done

if [ -z "$QUERY" ] && [ -z "$F_FEATURE$F_PAGE$F_STATUS$F_KIND" ]; then
	printf 'usage: sh wiki-search.sh <query> [--feature f] [--page p] [--status s] [--kind k]\n' >&2
	exit 2
fi

TMP="${TMPDIR:-/tmp}/wiki-search.$$"
trap 'rm -f "$TMP"' EXIT INT TERM

sh "$HERE/wiki-index.sh" --rows |
	awk -F'\t' -v feat="$F_FEATURE" -v pg="$F_PAGE" -v st="$F_STATUS" -v kd="$F_KIND" '
		feat != "" && $4 != feat { next }
		pg   != "" && $5 != pg   { next }
		st   != "" && $6 != st   { next }
		kd   != "" && $3 != kd   { next }
		{ print }
	' > "$TMP"

if [ ! -s "$TMP" ]; then
	printf 'wiki-search: no page matches those filters\n' >&2
	exit 1
fi

if [ "$PATHS_ONLY" = yes ] || [ -z "$QUERY" ]; then
	cut -f2 "$TMP"
	exit 0
fi

# ---- pass 1: the query is a name. No ranking needed, and no false neighbours.
exact=$(awk -F'\t' -v q="$QUERY" '
	function lower(s) { return tolower(s) }
	lower($1) == lower(q) || lower($8) == lower(q) { print; next }
	$9 != "" {
		c = split($9, a, ",")
		for (i = 1; i <= c; i++) if (lower(a[i]) == lower(q)) { print; next }
	}
' "$TMP")

if [ -n "$exact" ]; then
	printf 'exact name match:\n'
	printf '%s\n' "$exact" | awk -F'\t' '{ printf "  %-28s %s\n", $1, $2 }'
	printf '\n'
fi

# ---- pass 2: the glossary as a synonym table
PATTERN=$QUERY
if [ "$SYNONYMS" = yes ]; then
	syn=$(sh "$HERE/wiki-index.sh" --synonyms "$QUERY" 2>/dev/null)
	if [ -n "$syn" ]; then
		printf 'glossary: "%s" is also written' "$QUERY"
		alt=""
		printf '%s\n' "$syn" | while IFS= read -r one; do
			[ -n "$one" ] && printf ' %s' "$one"
		done
		printf '\n\n'
		# One alternation for a single search pass. The terms are identifiers
		# and glossary headings, so they are escaped as literals.
		alt=$(printf '%s\n%s\n' "$QUERY" "$syn" | sed 's/[][\.^$*+?(){}|\\\/]/\\&/g' | paste -sd'|' -)
		[ -n "$alt" ] && PATTERN=$alt
	fi
fi

# ---- pass 3: the body, over the allowed files only
set -- $(cut -f2 "$TMP" | tr '\n' ' ')
[ $# -gt 0 ] || exit 0

if command -v rg >/dev/null 2>&1; then
	rg --no-heading --line-number --smart-case --color never -e "$PATTERN" "$@" || true
else
	grep -nEi -e "$PATTERN" "$@" /dev/null || true
fi
