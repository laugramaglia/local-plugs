#!/bin/sh
# wiki-index.sh — build the wiki's index: one row per page, plus the link graph.
#
# Usage:
#   sh wiki-index.sh              print the index as TSV on stdout
#   sh wiki-index.sh --write      write it to the index path (default
#                                 business-docs/index.tsv) and say so
#   sh wiki-index.sh --check      validate: name collisions, unresolved links,
#                                 and whether the written index is current
#   sh wiki-index.sh --changed    hook mode: rewrite the index if the edited file
#                                 was a wiki page, silently; exit 0 otherwise
#   sh wiki-index.sh --rows       the rows only, from disk when it is current
#   sh wiki-index.sh --names      every name a [[link]] may resolve to
#   sh wiki-index.sh --path NAME  the file a name or alias resolves to
#   sh wiki-index.sh --row NAME   that page's whole index row
#   sh wiki-index.sh --links NAME       what NAME links out to
#   sh wiki-index.sh --backlinks NAME   what links to NAME
#   sh wiki-index.sh --synonyms TERM
#                                 the other surface forms of TERM, from the
#                                 glossary: the heading, and the per-layer names
#                                 under its "In code:" line
#   sh wiki-index.sh --mentions [--all]
#                                 pages that name another page in prose without
#                                 linking to it — where the graph is thinner
#                                 than the wiki actually is. ADR-NNNN citations
#                                 are a prose convention of their own and are
#                                 excluded unless --all is given.
#
# Columns: link_name path kind feature page status updated title aliases links_out
# `aliases` and `links_out` are comma-separated. No field may contain a tab.
#
# Exit 0 = pass (warnings allowed unless strict_check=true), 1 = failures.
# POSIX sh, no runtime dependencies. Run from the project root.

set -u

. "$(dirname "$0")/lib-wiki.sh"

WIKI_ROOT=$(wiki_root)
INDEX_PATH=$(index_path)
STRICT="${CLAUDE_PLUGIN_OPTION_STRICT_CHECK:-false}"

# emit_row reads page_fields back through a file rather than a pipe: a pipe
# would run the loop in a subshell and lose everything it accumulated.
ROW_TMP="${TMPDIR:-/tmp}/wiki-index.row.$$"
TMP="${TMPDIR:-/tmp}/wiki-index.$$"
trap 'rm -f "$ROW_TMP" "$TMP" "$TMP.names" "$TMP.rows" "$TMP.files"' EXIT INT TERM

MODE=print
ARG=""
MENTIONS_ALL=no
while [ $# -gt 0 ]; do
	case "$1" in
	--write) MODE=write ;;
	--check) MODE=check ;;
	--changed) MODE=changed ;;
	--names) MODE=names ;;
	--rows) MODE=rows ;;
	--mentions) MODE=mentions ;;
	--synonyms)
		MODE=synonyms
		shift
		ARG="${1:-}"
		;;
	--all) MENTIONS_ALL=yes ;;
	--path)
		MODE=path
		shift
		ARG="${1:-}"
		;;
	--row)
		MODE=row
		shift
		ARG="${1:-}"
		;;
	--links)
		MODE=links
		shift
		ARG="${1:-}"
		;;
	--backlinks)
		MODE=backlinks
		shift
		ARG="${1:-}"
		;;
	*)
		printf 'wiki-index: unknown argument: %s\n' "$1" >&2
		exit 2
		;;
	esac
	shift
done

# The hook mode runs in every repo, including every repo that has never heard of
# this plugin. It must be silent there, not loud.
if [ ! -d "$WIKI_ROOT" ]; then
	[ "$MODE" = changed ] && exit 0
	printf 'ERROR wiki root '\''%s'\'' does not exist — run /business-wiki:bootstrap\n' "$WIKI_ROOT" >&2
	exit 1
fi

# ------------------------------------------------------------------ generation

# emit_row <path> — one index row, or nothing when the path is not a page.
# Two forks: page_fields, and the awk that assembles and sorts the row.
emit_row() {
	link_name_for "$WIKI_ROOT" "$1" || return 0
	[ -n "$LINK_NAME" ] || return 0
	aliases_for "$WIKI_ROOT" "$1"
	kind_of "$WIKI_ROOT" "$1"
	_name=$LINK_NAME
	_al=$LINK_ALIASES
	_kd=$PAGE_KIND
	_path=$1

	page_fields "$WIKI_ROOT" "$1" > "$ROW_TMP"

	_feat="" _pg="" _st="" _up="" _ti="" _lnks=""
	while IFS="$WIKI_TAB" read -r _rec _a _b; do
		case "$_rec" in
		K)
			case "$_a" in
			feature) _feat=$_b ;;
			page) _pg=$_b ;;
			status) _st=$_b ;;
			updated) _up=$_b ;;
			esac
			;;
		T) _ti=$_a ;;
		W | A) _lnks="$_lnks$_a$WIKI_NL" ;;
		M)
			# a relative Markdown link, already resolved to a wiki path
			if link_name_for "$WIKI_ROOT" "$_a" && [ -n "$LINK_NAME" ]; then
				_lnks="$_lnks$LINK_NAME$WIKI_NL"
			fi
			;;
		esac
	done < "$ROW_TMP"

	printf '%s' "$_lnks" | awk -v n="$_name" -v p="$_path" -v k="$_kd" \
		-v f="$_feat" -v pg="$_pg" -v st="$_st" -v up="$_up" -v ti="$_ti" -v al="$_al" '
		$0 != "" && !($0 in seen) { seen[$0] = 1; L[++c] = $0 }
		END {
			for (i = 2; i <= c; i++) {
				v = L[i]
				for (j = i - 1; j >= 1 && L[j] > v; j--) L[j + 1] = L[j]
				L[j + 1] = v
			}
			out = ""
			for (i = 1; i <= c; i++) out = out (i > 1 ? "," : "") L[i]
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", n, p, k, f, pg, st, up, ti, al, out
		}'
}

# normalize_links — rewrite links_out so every edge names a page's canonical
# link name rather than one of its aliases. [[quiz]] and an ADR's `affects: quiz`
# both mean quiz-index; without this, --backlinks quiz-index misses them.
#
# It needs the whole row set to build the alias map, so it runs over the
# complete output — including the spliced set in --changed mode, which is the
# same set a full build sees. That is what keeps the two byte-identical.
normalize_links() {
	awk -F'\t' '
		{
			rows[++n] = $0
			canon[$1] = $1
			if ($9 != "") { c = split($9, a, ","); for (i = 1; i <= c; i++) canon[a[i]] = $1 }
		}
		END {
			for (r = 1; r <= n; r++) {
				m = split(rows[r], f, "\t")
				if (f[10] != "") {
					c = split(f[10], a, ",")
					delete seen
					k = 0
					for (i = 1; i <= c; i++) {
						t = (a[i] in canon) ? canon[a[i]] : a[i]
						if (!(t in seen)) { seen[t] = 1; L[++k] = t }
					}
					for (i = 2; i <= k; i++) {
						v = L[i]
						for (j = i - 1; j >= 1 && L[j] > v; j--) L[j + 1] = L[j]
						L[j + 1] = v
					}
					s = ""
					for (i = 1; i <= k; i++) s = s (i > 1 ? "," : "") L[i]
					f[10] = s
				}
				out = f[1]
				for (i = 2; i <= 10; i++) out = out "\t" f[i]
				print out
			}
		}
	'
}

emit_rows() {
	wiki_pages "$WIKI_ROOT" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		emit_row "$f"
	done
}

generate() {
	printf '# link_name\tpath\tkind\tfeature\tpage\tstatus\tupdated\ttitle\taliases\tlinks_out\n'
	printf '# generated by wiki-index.sh from %s — derived, do not hand-edit\n' "$WIKI_ROOT"
	emit_rows | normalize_links
}

# read_index — the index as rows, without the header. From disk when it is
# there, otherwise generated on the spot, so the query modes work in a repo that
# has never written one.
read_index() {
	if [ -f "$INDEX_PATH" ]; then
		grep -v '^#' "$INDEX_PATH"
	else
		generate | grep -v '^#'
	fi
}

# --------------------------------------------------------------------- modes

case "$MODE" in
print)
	generate
	exit 0
	;;

changed)
	# Runs on every Write/Edit, so it must do nothing, and say nothing, unless a
	# wiki page actually moved. A hook runs commands rather than tools, so the
	# write below does not re-enter this hook.
	edited=$(hook_edited_path) || exit 0
	case "$edited" in
	"$WIKI_ROOT"/shared/templates/*) exit 0 ;;
	"$WIKI_ROOT"/*.md) ;;
	*) exit 0 ;;
	esac

	dir=$(dirname "$INDEX_PATH")
	[ -d "$dir" ] || mkdir -p "$dir"
	tmp="$INDEX_PATH.tmp.$$"

	if [ ! -f "$INDEX_PATH" ]; then
		# Nothing to splice into yet.
		generate > "$tmp" 2>/dev/null && mv "$tmp" "$INDEX_PATH" || rm -f "$tmp"
		exit 0
	fi

	# Splice one row rather than rebuilding the graph. Editing a page can only
	# change that page's row — backlinks are derived from links_out at query
	# time, so no other row depends on it. A full rebuild here costs twenty
	# seconds on a thousand-page wiki, on every save.
	#
	# wiki_pages sorts with LC_ALL=C, so re-sorting on the path column
	# reproduces a full build byte for byte, which is what --check compares to.
	{
		grep '^#' "$INDEX_PATH"
		{
			awk -F'\t' -v p="$edited" '!/^#/ && $2 != p' "$INDEX_PATH"
			[ -f "$edited" ] && emit_row "$edited"
		} | LC_ALL=C sort -t"$WIKI_TAB" -k2,2 | normalize_links
	} > "$tmp" 2>/dev/null || {
		rm -f "$tmp"
		exit 0
	}
	if cmp -s "$tmp" "$INDEX_PATH"; then
		rm -f "$tmp"
	else
		mv "$tmp" "$INDEX_PATH"
	fi
	exit 0
	;;

write)
	dir=$(dirname "$INDEX_PATH")
	[ -d "$dir" ] || mkdir -p "$dir"
	tmp="$INDEX_PATH.tmp.$$"
	generate > "$tmp" || {
		rm -f "$tmp"
		exit 1
	}
	mv "$tmp" "$INDEX_PATH"
	printf 'wiki-index: wrote %s (%d page(s))\n' "$INDEX_PATH" "$(grep -cv '^#' "$INDEX_PATH")"
	exit 0
	;;

rows)
	read_index
	exit 0
	;;

names)
	read_index | awk -F'\t' '
		{ print $1; if ($9 != "") { n = split($9, a, ","); for (i = 1; i <= n; i++) print a[i] } }
	' | sort -u
	exit 0
	;;

path | row)
	[ -n "$ARG" ] || {
		printf 'wiki-index: --%s needs a name\n' "$MODE" >&2
		exit 2
	}
	# A path given instead of a name resolves to itself, so every tool can take
	# either without the caller knowing which it has.
	if [ -f "$ARG" ] && [ "$MODE" = path ]; then
		printf '%s\n' "$ARG"
		exit 0
	fi
	hit=$(read_index | awk -F'\t' -v n="$ARG" '
		$1 == n { print; exit }
		$2 == n { print; exit }
		$9 != "" {
			c = split($9, a, ",")
			for (i = 1; i <= c; i++) if (a[i] == n) { print; exit }
		}
	')
	if [ -z "$hit" ]; then
		printf 'wiki-index: no page named '\''%s'\''\n' "$ARG" >&2
		exit 1
	fi
	if [ "$MODE" = path ]; then
		printf '%s\n' "$hit" | cut -f2
	else
		printf '%s\n' "$hit"
	fi
	exit 0
	;;

synonyms)
	# The glossary is a hand-written, human-reviewed synonym table: it exists
	# precisely because the client, the wire and the database name the same
	# concept differently, and that mismatch is what a lexical search cannot
	# bridge on its own. Using it for query expansion is the deterministic
	# answer to the one thing dense retrieval would buy here.
	[ -n "$ARG" ] || {
		printf 'wiki-index: --synonyms needs a term\n' >&2
		exit 2
	}
	g=$(read_index | awk -F'\t' '$1 == "glossary" { print $2; exit }')
	[ -n "$g" ] && [ -f "$g" ] || exit 0
	awk -v q="$ARG" '
		function lower(x) { return tolower(x) }
		# A form is only worth expanding to if it is specific. A bare lowercase
		# word like "question" is a glossary heading AND half the prose in the
		# wiki: expanding to it took one query from 4 matches to 779. Multi-word
		# phrases and code identifiers (a dot, an underscore, or camelCase) are
		# specific; single plain words are not.
		function specific(t) {
			if (t ~ /[[:space:]]/) return 1
			if (t ~ /[._]/) return 1
			if (t ~ /^.[^[:upper:]]*[[:upper:]]/) return 1
			return 0
		}
		function flush(   i) {
			if (!hit) return
			hit = 0
			for (i = 1; i <= nf; i++)
				if (lower(form[i]) != lower(q) && specific(form[i])) print form[i]
			exit
		}
		/^## / {
			flush()
			nf = 0
			hit = 0
			t = $0
			sub(/^##[[:space:]]*/, "", t)
			form[++nf] = t
            if (lower(t) == lower(q)) hit = 1
			next
		}
		nf > 0 && /In code:/ {
			l = $0
			while (match(l, /`[^`]*`/)) {
				c = substr(l, RSTART + 1, RLENGTH - 2)
				l = substr(l, RSTART + RLENGTH)
				sub(/[[:space:]]*\(.*$/, "", c)
				if (c == "") continue
				form[++nf] = c
				if (lower(c) == lower(q)) hit = 1
			}
		}
		END { flush() }
	' "$g"
	exit 0
	;;

mentions)
	# Obsidian calls these unlinked mentions, and they are the cheapest way to
	# densify the graph: the writer already used the term, they just did not
	# link it. On a real 137-page wiki this found 83.
	#
	# One awk over every page with every term loaded, rather than a grep per
	# term per page, which would be quadratic.
	read_index > "$TMP.rows"
	wiki_pages "$WIKI_ROOT" | while IFS= read -r f; do
		[ -n "$f" ] || continue
		printf '%s\n' "$f"
	done > "$TMP.files"

	awk -F'\t' -v all="$MENTIONS_ALL" '
		function lower(x) { return tolower(x) }
		# pass 1: the terms, from the index
		NR == FNR {
			name[$2] = $1
			if ($1 == "README") { out[$1] = $10; next }
			term[lower($1)] = $1
			if ($8 != "" && length($8) >= 5) term[lower($8)] = $1
			if ($9 != "") {
				c = split($9, a, ",")
				for (i = 1; i <= c; i++) {
					if (length(a[i]) < 5) continue
					# ADR-NNNN in prose is this wiki-s own citation form, not a
					# missing link: check-wiki already treats it as a citation.
					if (all != "yes" && tolower(a[i]) ~ /^adr-[0-9]/) continue
					term[lower(a[i])] = $1
				}
			}
			out[$1] = $10
			next
		}
        { files[++nf] = $0 }
		END {
			for (i = 1; i <= nf; i++) {
				f = files[i]
				self = (f in name) ? name[f] : ""
				# what this page already links to
				delete linked
				if (self != "" && out[self] != "") {
					c = split(out[self], a, ",")
					for (j = 1; j <= c; j++) linked[a[j]] = 1
				}
				delete seen
				fence = 0
				fm = 0
				n = 0
				while ((getline line < f) > 0) {
					n++
					# frontmatter is metadata, not prose: `feature: taxonomy`
					# is not a page failing to link to taxonomy-index
					if (n == 1 && line == "---") { fm = 1; continue }
					if (fm) { if (line ~ /^---[[:space:]]*$/) fm = 0; continue }
					if (line ~ /^[[:space:]]*(```|~~~)/) { fence = 1 - fence; continue }
					if (fence) continue
					l = lower(line)
					gsub(/`[^`]*`/, "", l)
					gsub(/\[\[[^]]*\]\]/, "", l)
					gsub(/\]\([^)]*\)/, "", l)
					for (t in term) {
						tgt = term[t]
						if (tgt == self || (tgt in linked) || (tgt in seen)) continue
						if (index(l, t) > 0) {
							seen[tgt] = 1
							printf "%s\t%d\t%s\t%s\n", f, n, t, tgt
						}
					}
				}
				close(f)
			}
		}
	' "$TMP.rows" "$TMP.files" |
		awk -F'\t' '
			{ rows[++n] = $0; freq[$4]++ }
			END {
				for (i = 1; i <= n; i++) {
					split(rows[i], f, "\t")
					printf "%6d\t%s\n", freq[f[4]], rows[i]
				}
			}
		' | LC_ALL=C sort -rn -k1,1 | cut -f2-
	exit 0
	;;

links)
	[ -n "$ARG" ] || {
		printf 'wiki-index: --links needs a name\n' >&2
		exit 2
	}
	read_index | awk -F'\t' -v n="$ARG" '$1 == n && $10 != "" { gsub(/,/, "\n", $10); print $10 }'
	exit 0
	;;

backlinks)
	[ -n "$ARG" ] || {
		printf 'wiki-index: --backlinks needs a name\n' >&2
		exit 2
	}
	read_index | awk -F'\t' -v n="$ARG" '
		$10 == "" { next }
		{
			c = split($10, a, ",")
			for (i = 1; i <= c; i++) if (a[i] == n) { printf "%s\t%s\n", $1, $2; next }
		}
	'
	exit 0
	;;
esac

# --------------------------------------------------------------------- --check

fails=0
warns=0
err() {
	printf 'ERROR %s\n' "$*" >&2
	fails=$((fails + 1))
}
wrn() {
	printf 'WARN  %s\n' "$*" >&2
	warns=$((warns + 1))
}

generate > "$TMP"

# A collision is invisible today: the old link index ran through `sort -u`, so
# shared/checkout-flow.md and features/checkout/flow.md both answered to
# `checkout-flow` and [[checkout-flow]] silently resolved to whichever.
grep -v '^#' "$TMP" | awk -F'\t' '
	{ print $1 "\t" $2; if ($9 != "") { n = split($9, a, ","); for (i = 1; i <= n; i++) print a[i] "\t" $2 } }
' | sort > "$TMP.names"

# The format's one soft spot: `aliases` and `links_out` are comma-joined inside a
# field, which is safe only because link names come from filenames and never
# contain a comma. Assert that rather than trusting it — a shared/a,b.md would
# otherwise split the field and make its backlinks vanish in silence.
bad_chars=$(cut -f1 "$TMP.names" | grep '[,]' || true)
for b in $bad_chars; do
	where=$(awk -F'\t' -v n="$b" '$1 == n { printf "%s ", $2 }' "$TMP.names")
	err "$where:1 link name '$b' contains a comma, which the index cannot represent — rename the file"
done

dupes=$(cut -f1 "$TMP.names" | uniq -d)
for d in $dupes; do
	where=$(awk -F'\t' -v n="$d" '$1 == n { printf "%s ", $2 }' "$TMP.names")
	err "$INDEX_PATH:1 link name '$d' is claimed by more than one page: $where"
done

# Every edge must land somewhere. check-wiki.sh reports this per page with a
# line number; here it is a graph-level count, so --check alone is conclusive.
dangling=$(grep -v '^#' "$TMP" | awk -F'\t' '
	$10 != "" { n = split($10, a, ","); for (i = 1; i <= n; i++) printf "%s\t%s\n", a[i], $2 }
' | sort -u)
if [ -n "$dangling" ]; then
	known=$(cut -f1 "$TMP.names" | sort -u)
	printf '%s\n' "$dangling" | while IFS="$WIKI_TAB" read -r lnk src; do
		[ -n "$lnk" ] || continue
		printf '%s\n' "$known" | grep -qx "$lnk" || printf '%s\t%s\n' "$lnk" "$src"
	done > "$TMP.dangling"
	while IFS="$WIKI_TAB" read -r lnk src; do
		[ -n "$lnk" ] || continue
		err "$src:1 [[$lnk]] does not resolve to a wiki page"
	done < "$TMP.dangling"
	rm -f "$TMP.dangling"
fi

# A stale index is worse than no index: it answers, and it answers with
# yesterday's graph. The PostToolUse hook normally keeps this from ever firing.
if [ ! -f "$INDEX_PATH" ]; then
	wrn "$INDEX_PATH does not exist — run: sh wiki-index.sh --write"
elif ! cmp -s "$TMP" "$INDEX_PATH"; then
	wrn "$INDEX_PATH is out of date with $WIKI_ROOT — run: sh wiki-index.sh --write"
fi

if [ "$fails" -gt 0 ]; then
	printf 'wiki-index: %d error(s), %d warning(s)\n' "$fails" "$warns" >&2
	exit 1
fi
if [ "$warns" -gt 0 ] && [ "$STRICT" = "true" ]; then
	printf 'wiki-index: %d warning(s), strict_check=true\n' "$warns" >&2
	exit 1
fi
printf 'wiki-index: pass (%d warning(s))\n' "$warns"
exit 0
