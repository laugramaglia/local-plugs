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
WIKI_NL='
'

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

# page_fields <root> <file> — everything the index needs from a page's content,
# in one pass, as a keyed record stream. Every record has at most one trailing
# field that may be empty, because `read` with IFS=TAB collapses runs of tabs
# and would otherwise shift the columns.
#
#   K<TAB>feature|page|status|updated<TAB>value
#   T<TAB>title
#   W<TAB>name      a [[wikilink]]
#   M<TAB>path      a relative Markdown link, resolved to a wiki-relative path
#   A<TAB>slug      an `affects:` entry in an ADR's frontmatter
#
# The Markdown links matter as much as the wikilinks: the feature `decisions.md`
# pages cite ADRs as [ADR-0007](../../decisions/0007-slug.md), which is a real
# edge that a wikilink-only parser cannot see — and that left every ADR in the
# graph with zero backlinks.
#
# This is one awk pass because the per-field shell helpers cost about thirty
# forks per page, which was twenty seconds of index build on a thousand pages.
page_fields() {
	awk -v self="$2" -v root="$1" '
		function norm(p,   n, i, parts, out, k, s) {
			n = split(p, parts, "/")
			k = 0
			for (i = 1; i <= n; i++) {
				if (parts[i] == "." || parts[i] == "") continue
				if (parts[i] == "..") { if (k > 0) k--; continue }
				out[++k] = parts[i]
			}
			s = ""
			for (i = 1; i <= k; i++) s = s (i > 1 ? "/" : "") out[i]
			return s
		}
		BEGIN {
			dir = self
			sub(/\/[^\/]*$/, "", dir)
		}
		{
			line = $0

			# fences and code spans are excluded from every link form: a page
			# documenting the syntax is illustrating it, not linking
			if (line ~ /^[[:space:]]*(```|~~~)/) {
				fence = 1 - fence
			} else if (!fence) {
				l = line
				gsub(/`[^`]*`/, "", l)

				t = l
				while (match(t, /\[\[[^]]*\]\]/)) {
					nm = substr(t, RSTART + 2, RLENGTH - 4)
					if (!(nm in seenw)) { seenw[nm] = 1; printf "W\t%s\n", nm }
					t = substr(t, RSTART + RLENGTH)
				}

				t = l
				while (match(t, /\]\([^)]*\.md[^)]*\)/)) {
					href = substr(t, RSTART + 2, RLENGTH - 3)
					t = substr(t, RSTART + RLENGTH)
					sub(/#.*$/, "", href)
					if (href ~ /^[a-z]+:/ || href ~ /^\//) continue
					full = norm(dir "/" href)
					# only a link that resolves to a real file is an
					# edge. A dead relative link belongs to check-wiki,
					# which reports it with a line number; putting it in
					# the graph would invent a node for a page that does
					# not exist.
					if (index(full, root "/") == 1 && !(full in seenm) &&
						(getline junk < full) >= 0) {
						close(full)
						seenm[full] = 1
						printf "M\t%s\n", full
					}
				}
			}

			# frontmatter
			if (NR == 1) { if (line == "---") { fm = 1; next } }
			if (fm) {
				if (line ~ /^---[[:space:]]*$/) { fm = 0; next }
				if (match(line, /^[A-Za-z_][A-Za-z0-9_]*:/)) {
					k = substr(line, 1, RLENGTH - 1)
					v = substr(line, RLENGTH + 1)
					sub(/^[[:space:]]+/, "", v)
					sub(/[[:space:]]+$/, "", v)
					gsub(/\t/, " ", v)
					if (!(k in val)) {
						val[k] = v
						if (k == "feature" || k == "page" || k == "status" || k == "updated" || k == "date")
							printf "K\t%s\t%s\n", k, v
					}
					inaffects = (k == "affects")
					next
				}
				# an ADR names the features it binds in frontmatter. That is an
				# authored edge, and until now nothing read it.
				if (inaffects && match(line, /^[[:space:]]*-[[:space:]]*/)) {
					a = substr(line, RLENGTH + 1)
					gsub(/^["'"'"']|["'"'"']$/, "", a)
					sub(/[[:space:]]+$/, "", a)
					if (a != "") printf "A\t%s\n", a
					next
				}
				if (line ~ /^[^[:space:]]/) inaffects = 0
				next
			}

			# body — the first H1 is the title
			if (title == "" && line ~ /^#[[:space:]]/) {
				title = line
				sub(/^#[[:space:]]*/, "", title)
				gsub(/\t/, " ", title)
				printf "T\t%s\n", title
			}
		}
		END {
			if (!("updated" in val) && ("date" in val)) printf "K\tupdated\t%s\n", val["date"]
		}
	' "$2"
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
	awk -v self="$1" '
		function norm(p,   n, i, parts, out, k, s) {
			n = split(p, parts, "/")
			k = 0
			for (i = 1; i <= n; i++) {
				if (parts[i] == "." || parts[i] == "") continue
				if (parts[i] == "..") { if (k > 0) k--; continue }
				out[++k] = parts[i]
			}
			s = ""
			for (i = 1; i <= k; i++) s = s (i > 1 ? "/" : "") out[i]
			return s
		}
		BEGIN {
			dir = self
			sub(/\/[^\/]*$/, "", dir)
		}
		{
			line = $0

			# links — whole file, fences and code spans excluded
			if (line ~ /^[[:space:]]*(```|~~~)/) {
				lfence = 1 - lfence
			} else if (!lfence) {
				l = line
				gsub(/`[^`]*`/, "", l)

				t = l
				while (match(t, /\[\[[^]]*\]\]/)) {
					printf "L\t%d\t%s\n", NR, substr(t, RSTART + 2, RLENGTH - 4)
					t = substr(t, RSTART + RLENGTH)
				}

				# relative Markdown links to other pages — the other half of
				# the graph, and until now completely unvalidated
				t = l
				while (match(t, /\]\([^)]*\.md[^)]*\)/)) {
					href = substr(t, RSTART + 2, RLENGTH - 3)
					t = substr(t, RSTART + RLENGTH)
					sub(/#.*$/, "", href)
					if (href ~ /^[a-z]+:/ || href ~ /^\//) continue
					printf "D\t%d\t%s\t%s\n", NR, norm(dir "/" href), href
				}
			}

			# leftover template placeholders — whole file, first three
			if (nph < 3 && line ~ /FEATURE_SLUG|FEATURE_NAME|PROJECT_NAME|PATH\/TO|NNNN-slug|YYYY-MM-DD/) {
				nph++
				txt = substr(line, 1, 60)
				gsub(/\t/, " ", txt)
				printf "P\t%d\t%s\n", NR, txt
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
