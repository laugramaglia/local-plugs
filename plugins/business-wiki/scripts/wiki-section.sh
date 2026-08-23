#!/bin/sh
# wiki-section.sh — read one section of a page, not the page.
#
#   sh wiki-section.sh <page> <heading>
#
# <page> is a path or a link name/alias. <heading> is matched case-insensitively
# against the heading text, with or without its leading #s, and a prefix is
# enough. The section runs to the next heading of the same or a higher level.
#
# POSIX sh, no runtime dependencies. Run from the project root.

set -u

HERE=$(dirname "$0")
. "$HERE/lib-wiki.sh"

if [ $# -lt 2 ]; then
	printf 'usage: sh wiki-section.sh <page> <heading>\n' >&2
	exit 2
fi

f=$(sh "$HERE/wiki-index.sh" --path "$1") || exit 1
[ -f "$f" ] || {
	printf 'wiki-section: %s is not a file\n' "$f" >&2
	exit 1
}

want=$(printf '%s' "$2" | sed 's/^#*[[:space:]]*//')

out=$(awk -v want="$want" '
	function lower(s) { return tolower(s) }
	NR == 1 && $0 == "---" { fm = 1; next }
	fm && /^---[[:space:]]*$/ { fm = 0; next }
	fm { next }
	/^[[:space:]]*(```|~~~)/ { fence = 1 - fence; if (inside) print; next }
	fence { if (inside) print; next }
	/^#{1,6}[[:space:]]/ {
		line = $0
		n = 0
		while (substr(line, n + 1, 1) == "#") n++
		text = line
		sub(/^#+[[:space:]]*/, "", text)
		if (inside && n <= level) { inside = 0 }
		if (!inside && !done && index(lower(text), lower(want)) == 1) {
			inside = 1; level = n; done = 1; print; next
		}
	}
	inside { print }
' "$f")

if [ -z "$out" ]; then
	printf 'wiki-section: no heading in %s starts with "%s"\n' "$f" "$want" >&2
	printf 'available:\n' >&2
	page_headings "$f" | awk -F'\t' '{ printf "  %s\n", $3 }' >&2
	exit 1
fi

printf '%s\n' "$out"
