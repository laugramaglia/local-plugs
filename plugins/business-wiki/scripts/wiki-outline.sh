#!/bin/sh
# wiki-outline.sh — what a page is, without reading it.
#
#   sh wiki-outline.sh <page>     <page> is a path or a link name/alias
#
# Prints the frontmatter, the heading outline with line numbers, the links out,
# and the backlinks. This is the cheap first read: it costs a fraction of the
# page and answers "is this the page I want, and which section of it".
#
# POSIX sh, no runtime dependencies. Run from the project root.

set -u

HERE=$(dirname "$0")
. "$HERE/lib-wiki.sh"

WIKI_ROOT=$(wiki_root)

if [ $# -lt 1 ]; then
	printf 'usage: sh wiki-outline.sh <page>\n' >&2
	exit 2
fi

f=$(sh "$HERE/wiki-index.sh" --path "$1") || exit 1
[ -f "$f" ] || {
	printf 'wiki-outline: %s is not a file\n' "$f" >&2
	exit 1
}

link_name_for "$WIKI_ROOT" "$f" || LINK_NAME="$1"
name=${LINK_NAME:-$1}
fm=$(frontmatter "$f")

printf '%s  [%s]\n' "$f" "$name"
title=$(page_title "$f")
[ -n "$title" ] && printf '%s\n' "$title"

printf '\nfrontmatter:\n'
if [ -n "$fm" ]; then
	printf '%s\n' "$fm" | sed 's/^/  /'
else
	printf '  (none)\n'
fi

printf '\noutline:\n'
outline=$(page_headings "$f")
if [ -n "$outline" ]; then
	# The H1 is the title, already printed above; the outline is what you can
	# ask wiki-section.sh for.
	printf '%s\n' "$outline" | awk -F'\t' '
		$2 == 1 { next }
		{
			indent = ""
			for (i = 2; i < $2; i++) indent = indent "  "
			hashes = ""
			for (i = 0; i < $2; i++) hashes = hashes "#"
			printf "  %5d  %s%s %s\n", $1, indent, hashes, $3
		}
	'
else
	printf '  (no headings)\n'
fi

printf '\nlinks out:\n'
out=$(sh "$HERE/wiki-index.sh" --links "$name" 2>/dev/null | grep -v '^$')
if [ -n "$out" ]; then
	printf '%s\n' "$out" | while IFS= read -r l; do
		p=$(sh "$HERE/wiki-index.sh" --path "$l" 2>/dev/null)
		printf '  %-28s %s\n' "$l" "${p:-(unresolved)}"
	done
else
	printf '  (none)\n'
fi

# The question this page exists to answer: what breaks if this rule changes.
printf '\nbacklinks:\n'
back=$(sh "$HERE/wiki-index.sh" --backlinks "$name" 2>/dev/null)
if [ -n "$back" ]; then
	printf '%s\n' "$back" | awk -F'\t' '{ printf "  %-28s %s\n", $1, $2 }'
else
	printf '  (none)\n'
fi
