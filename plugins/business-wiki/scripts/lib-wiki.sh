#!/bin/sh
# lib-wiki.sh — the parsing the business-wiki scripts share. Source it, do not
# run it:
#
#   . "$(dirname "$0")/lib-wiki.sh"
#
# Every function is POSIX sh with no runtime dependencies, and none of them
# write anything. Paths are relative to the project root, which is the caller's
# current directory.

WIKI_TAB=$(printf '\t')

# ------------------------------------------------------------------- the roots

wiki_root() {
	printf '%s' "${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-business-docs/wiki}"
}

# The index is derived, so it lives beside rules/ and openapi/ rather than
# inside the wiki: everything under the wiki root is authored and reviewed.
index_path() {
	if [ -n "${CLAUDE_PLUGIN_OPTION_INDEX_PATH:-}" ]; then
		printf '%s' "$CLAUDE_PLUGIN_OPTION_INDEX_PATH"
		return
	fi
	d=$(dirname "$(wiki_root)")
	if [ "$d" = "." ]; then printf 'index.tsv'; else printf '%s/index.tsv' "$d"; fi
}

# wiki_pages <root> — every page the system owns, one per line. The human copies
# of the templates are not pages: they are full of placeholders on purpose.
wiki_pages() {
	find "$1" -name '*.md' -type f 2>/dev/null |
		grep -v "^$1/shared/templates/" |
		LC_ALL=C sort
}

# hook_edited_path — the file a PostToolUse payload is about, relative to the
# project root, or nothing. Reads stdin; jq is not assumed to be installed.
hook_edited_path() {
	edited=$(
		cat 2>/dev/null |
			tr ',{}' '\n\n\n' |
			grep '"file_path"' |
			head -1 |
			sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"//; s/".*//'
	)
	[ -n "$edited" ] || return 1
	case "$edited" in
	"$PWD"/*) edited=$(printf '%s' "$edited" | cut -c $((${#PWD} + 2))-) ;;
	esac
	printf '%s' "$edited"
}

# ------------------------------------------------------------------ frontmatter

# frontmatter <file> — the YAML body, without the --- fences
frontmatter() {
	awk 'NR==1 { if ($0 != "---") exit 0; next } /^---[[:space:]]*$/ { exit } { print }' "$1"
}

# has_key <frontmatter> <key>
has_key() {
	printf '%s\n' "$1" | grep -q "^$2:"
}

# value_of <frontmatter> <key>
value_of() {
	printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

# list_items <frontmatter> <key> — YAML block-sequence values under <key>
list_items() {
	printf '%s\n' "$1" | awk -v k="$2" '
		$0 ~ "^"k":" { inblock = 1; next }
		inblock && /^[[:space:]]*-[[:space:]]*/ {
			sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print; next
		}
		inblock && /^[^[:space:]]/ { inblock = 0 }
	'
}

# ------------------------------------------------------------------- the body

# page_title <file> — the first H1 of the body
page_title() {
	awk '
		NR == 1 && $0 == "---" { fm = 1; next }
		fm && /^---[[:space:]]*$/ { fm = 0; next }
		fm { next }
		/^#[[:space:]]/ { sub(/^#[[:space:]]*/, ""); print; exit }
	' "$1" | tr '\t' ' '
}

# page_headings <file> — "line<TAB>level<TAB>text" for every ATX heading in the
# body. Fenced blocks are skipped, so a `# comment` in a shell sample is not a
# heading.
page_headings() {
	awk '
		NR == 1 && $0 == "---" { fm = 1; next }
		fm && /^---[[:space:]]*$/ { fm = 0; next }
		fm { next }
		/^[[:space:]]*(```|~~~)/ { fence = 1 - fence; next }
		fence { next }
		/^#{1,6}[[:space:]]/ {
			line = $0
			n = 0
			while (substr(line, n + 1, 1) == "#") n++
			sub(/^#+[[:space:]]*/, "", line)
			gsub(/\t/, " ", line)
			printf "%d\t%d\t%s\n", NR, n, line
		}
	' "$1"
}

# extract_links <file> — "line<TAB>name" for every [[wikilink]] in the file.
#
# Inline code spans and fenced blocks are stripped first: a page that documents
# the link syntax writes `[[link]]` in backticks, and that is an illustration,
# not an edge in the graph.
extract_links() {
	awk '
		/^[[:space:]]*(```|~~~)/ { fence = 1 - fence; next }
		fence { next }
		{
			line = $0
			gsub(/`[^`]*`/, "", line)
			while (match(line, /\[\[[^]]*\]\]/)) {
				printf "%d\t%s\n", NR, substr(line, RSTART + 2, RLENGTH - 4)
				line = substr(line, RSTART + RLENGTH)
			}
		}
	' "$1"
}

# page_fields <file> — everything the index needs from a page's CONTENT, in one
# pass: "feature<TAB>page<TAB>status<TAB>updated<TAB>title<TAB>links_out".
#
# This exists for speed, and the speed is not academic: the per-field helpers
# above cost about thirty forks per page, which is twenty seconds of index build
# on a thousand-page wiki. It must stay behaviourally identical to
# value_of + page_title + extract_links, which is what the tests pin.
page_fields() {
	awk '
		{
			line = $0

			# links — whole file, code spans and fences excluded, first
			# occurrence wins, exactly as extract_links sees it
			if (line ~ /^[[:space:]]*(```|~~~)/) {
				fence = 1 - fence
			} else if (!fence) {
				l = line
				gsub(/`[^`]*`/, "", l)
				while (match(l, /\[\[[^]]*\]\]/)) {
					nm = substr(l, RSTART + 2, RLENGTH - 4)
					if (!(nm in seen)) { seen[nm] = 1; link[++nl] = nm }
					l = substr(l, RSTART + RLENGTH)
				}
			}

			# frontmatter — first value for a key wins
			if (NR == 1) { if (line == "---") { fm = 1; next } }
			if (fm) {
				if (line ~ /^---[[:space:]]*$/) { fm = 0; next }
				if (match(line, /^[A-Za-z_][A-Za-z0-9_]*:/)) {
					k = substr(line, 1, RLENGTH - 1)
					v = substr(line, RLENGTH + 1)
					sub(/^[[:space:]]+/, "", v)
					sub(/[[:space:]]+$/, "", v)
					if (!(k in val)) val[k] = v
				}
				next
			}

			# body — the first H1 is the title
			if (title == "" && line ~ /^#[[:space:]]/) {
				title = line
				sub(/^#[[:space:]]*/, "", title)
			}
		}
		END {
			# insertion sort: a handful of links, and a stable order keeps the
			# file diffable and an incremental write identical to a full one
			for (i = 2; i <= nl; i++) {
				v = link[i]
				for (j = i - 1; j >= 1 && link[j] > v; j--) link[j + 1] = link[j]
				link[j + 1] = v
			}
			out = ""
			for (i = 1; i <= nl; i++) out = out (i > 1 ? "," : "") link[i]
			up = ("updated" in val) ? val["updated"] : (("date" in val) ? val["date"] : "")
			gsub(/\t/, " ", title)
			printf "%s\t%s\t%s\t%s\t%s\t%s\n", \
				("feature" in val ? val["feature"] : ""), \
				("page" in val ? val["page"] : ""), \
				("status" in val ? val["status"] : ""), \
				up, title, out
		}
	' "$1"
}

# page_scan <file> — everything check-wiki.sh needs from one page, in one pass,
# as a keyed record stream:
#
#   X<TAB>nofm                 line 1 is not "---"
#   M<TAB>n                    lines inside the frontmatter fences
#   K<TAB>key<TAB>line<TAB>value   first occurrence of a top-level YAML key
#   R<TAB>item                 a code_refs block-sequence item
#   L<TAB>line<TAB>name        a [[wikilink]], code spans and fences excluded
#   S<TAB>heading              an ADR section heading that is present
#   P<TAB>line<TAB>text        a leftover template placeholder (first 3)
#   B<TAB>n                    non-blank body lines
#
# Same job as head + frontmatter + has_key + value_of + line_of + list_items +
# extract_links + two greps, which together cost about forty forks per page and
# forty-seven seconds of full validation on a thousand-page wiki.
page_scan() {
	awk '
		{
			line = $0

			# links — whole file, fences and code spans excluded
			if (line ~ /^[[:space:]]*(```|~~~)/) {
				lfence = 1 - lfence
			} else if (!lfence) {
				l = line
				gsub(/`[^`]*`/, "", l)
				while (match(l, /\[\[[^]]*\]\]/)) {
					printf "L\t%d\t%s\n", NR, substr(l, RSTART + 2, RLENGTH - 4)
					l = substr(l, RSTART + RLENGTH)
				}
			}

			# leftover template placeholders — whole file, first three
			if (nph < 3 && line ~ /FEATURE_SLUG|FEATURE_NAME|PROJECT_NAME|PATH\/TO|NNNN-slug|YYYY-MM-DD/) {
				nph++
				t = substr(line, 1, 60)
				gsub(/\t/, " ", t)
				printf "P\t%d\t%s\n", NR, t
			}

			# ADR sections — whole file, presence only
			if (line ~ /^## Context/) printf "S\tContext\n"
			if (line ~ /^## Decision/) printf "S\tDecision\n"
			if (line ~ /^## Consequences/) printf "S\tConsequences\n"

			# frontmatter
			if (NR == 1) {
				if (line == "---") { fm = 1; next }
				printf "X\tnofm\n"
			}
			if (fm) {
				if (line ~ /^---[[:space:]]*$/) { fm = 0; closed = 1; next }
				fmlines++
				if (match(line, /^[A-Za-z_][A-Za-z0-9_]*:/)) {
					k = substr(line, 1, RLENGTH - 1)
					v = substr(line, RLENGTH + 1)
					sub(/^[[:space:]]+/, "", v)
					gsub(/\t/, " ", v)
					if (!(k in seenk)) { seenk[k] = 1; printf "K\t%s\t%d\t%s\n", k, NR, v }
					inrefs = (k == "code_refs")
					next
				}
				if (inrefs && match(line, /^[[:space:]]*-[[:space:]]*/)) {
					r = substr(line, RLENGTH + 1)
					gsub(/^["'"'"']|["'"'"']$/, "", r)
					printf "R\t%s\n", r
					next
				}
				if (line ~ /^[^[:space:]]/) inrefs = 0
				next
			}

			if (closed && NF) bodyc++
		}
		END {
			printf "M\t%d\n", fmlines + 0
			printf "B\t%d\n", bodyc + 0
		}
	' "$1"
}

# ------------------------------------------------------------------ link names

# The naming rule, in one place: it is what [[links]] resolve against and what
# the index is keyed by.
#
#   features/<f>/<page>.md -> <f>-<page>
#   shared/<x>.md          -> <x>
#   decisions/NNNN-slug.md -> NNNN-slug
#   README.md              -> README

# link_name_for <root> <path> — sets LINK_NAME; returns 1 when the path is not a
# page. It assigns rather than prints so callers need no command substitution:
# a fork per page per field is what made the index build slow.
link_name_for() {
	LINK_NAME=""
	rel=${2#"$1"/}
	case "$rel" in
	features/*/*.md)
		lnf=${rel#features/}
		lnf=${lnf%%/*}
		lnb=${rel##*/}
		LINK_NAME="$lnf-${lnb%.md}"
		;;
	shared/*.md | decisions/*.md)
		lnb=${rel##*/}
		LINK_NAME=${lnb%.md}
		;;
	README.md) LINK_NAME=README ;;
	*) return 1 ;;
	esac
	return 0
}

# aliases_for <root> <path> — sets LINK_ALIASES, comma-joined: the other names a
# page answers to.
# A feature's index page answers to the bare feature slug, and an ADR to its
# ADR-NNNN citation, because that is how both get referred to in prose.
aliases_for() {
	LINK_ALIASES=""
	rel=${2#"$1"/}
	case "$rel" in
	features/*/index.md)
		alf=${rel#features/}
		LINK_ALIASES=${alf%%/*}
		;;
	decisions/*.md)
		alb=${rel##*/}
		case "$alb" in
		[0-9][0-9][0-9][0-9]-*) LINK_ALIASES="ADR-${alb%%-*}" ;;
		esac
		;;
	esac
}

# kind_of <root> <path> — sets PAGE_KIND
kind_of() {
	rel=${2#"$1"/}
	case "$rel" in
	features/*) PAGE_KIND=feature ;;
	shared/*) PAGE_KIND=shared ;;
	decisions/*) PAGE_KIND=decision ;;
	*) PAGE_KIND=root ;;
	esac
}
