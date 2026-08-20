#!/bin/sh
# check-wiki.sh — validate the wiki: frontmatter, required sections, [[links]],
# code_refs that still exist, ADR citations from code, leftover placeholders.
#
# Usage:
#   sh check-wiki.sh              validate the whole wiki
#   sh check-wiki.sh --changed    hook mode: read the edited path from stdin JSON
#                                 and validate only that file; exit 0 silently for
#                                 anything outside the wiki.
#   sh check-wiki.sh <path>...    validate specific files
#
# Exit 0 = pass (warnings allowed unless strict_check=true), 1 = failures.
# POSIX sh, no runtime dependencies. Run from the project root.

set -u

. "$(dirname "$0")/lib-wiki.sh"

WIKI_ROOT=$(wiki_root)
STRICT="${CLAUDE_PLUGIN_OPTION_STRICT_CHECK:-false}"

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

# ---------------------------------------------------------------- target files

HOOK_MODE=no
TARGETS=""

if [ $# -gt 0 ] && [ "$1" = "--changed" ]; then
	HOOK_MODE=yes
	shift
	edited=$(hook_edited_path) || exit 0
	# only care about markdown inside the wiki
	case "$edited" in
	"$WIKI_ROOT"/*.md) TARGETS="$edited" ;;
	*) exit 0 ;;
	esac
elif [ $# -gt 0 ]; then
	TARGETS="$*"
fi

if [ ! -d "$WIKI_ROOT" ]; then
	err "wiki root '$WIKI_ROOT' does not exist — run /business-wiki:bootstrap"
	exit 1
fi

ALL_PAGES=$(wiki_pages "$WIKI_ROOT")

if [ -z "$TARGETS" ]; then
	TARGETS="$ALL_PAGES"
fi

# ------------------------------------------------------------ link name index
#
# The naming rule itself lives in lib-wiki.sh, because the index and the
# navigation tools resolve links against exactly the same set.

emit_link_names() {
	for f in $ALL_PAGES; do
		link_name_for "$WIKI_ROOT" "$f" && printf '%s\n' "$LINK_NAME"
		aliases_for "$WIKI_ROOT" "$f"
		[ -n "$LINK_ALIASES" ] && printf '%s\n' "$LINK_ALIASES" | tr ',' '\n'
	done
}

link_index=$(emit_link_names | sort -u)

# Membership is tested with a case glob rather than `grep -qx` per link: on a
# large wiki that was two forks for every [[link]] on every page.
WIKI_NL='
'
link_index_flat="$WIKI_NL$link_index$WIKI_NL"

# --------------------------------------------------------------------- helpers

# line_of <file> <pattern> — first matching line number, or 1
line_of() {
	n=$(grep -n "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1)
	[ -n "$n" ] && printf '%s' "$n" || printf '1'
}

# A case glob rather than printf|grep: this runs several times per page, and two
# forks each is measurable across a large wiki.
is_date() {
	case "$1" in
	[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
	esac
	return 1
}

# A scratch file so the code_refs loop reads from a redirect rather than a pipe:
# in a pipeline the loop body runs in a subshell, where err()/wrn() increment a
# copy of the counters and every finding is lost on the way out.
SCAN_TMP="${TMPDIR:-/tmp}/check-wiki.scan.$$"
trap 'rm -f "$SCAN_TMP"' EXIT INT TERM

# Memo for `git log -1` results, as one string, looked up with parameter
# expansion so a repeated code_refs path costs no fork at all. Wiki pages cite
# the same handful of source files constantly.
GIT_DATES="|"
git_last_change() { # <path> -> GIT_DATE
	case "$GIT_DATES" in
	*"|$1="*)
		GIT_DATE=${GIT_DATES#*"|$1="}
		GIT_DATE=${GIT_DATE%%"|"*}
		;;
	*)
		GIT_DATE=$(git log -1 --format=%cd --date=short -- "$1" 2>/dev/null)
		GIT_DATES="$GIT_DATES$1=$GIT_DATE|"
		;;
	esac
}

# The staleness check is a nice-to-have: outside a git repo it must vanish
# silently rather than reporting every page as fresh, and it stays out of hook
# mode entirely so a keystroke-time check never waits on `git log`.
GIT_OK=no
if [ "$HOOK_MODE" = no ] && command -v git >/dev/null 2>&1 &&
	git rev-parse --git-dir >/dev/null 2>&1; then
	GIT_OK=yes
fi

# ------------------------------------------------------------------- per file

for f in $TARGETS; do
	[ -f "$f" ] || {
		err "$f:1 file does not exist"
		continue
	}

	rel=${f#"$WIKI_ROOT"/}

	# the wiki README and the human-facing template copies are exempt
	case "$rel" in
	README.md | shared/templates/*) continue ;;
	esac

	# ------ one pass over the page; everything below reads the result
	page_scan "$f" > "$SCAN_TMP"

	nofm=no
	fm_lines=0
	body_lines=0
	sections=" "
	# k_<key>=1 when present, v_<key> its value, l_<key> its line
	p_adr=no p_title=no p_status=no p_date=no
	p_feature=no p_page=no p_sot=no p_updated=no
	v_adr="" v_status="" v_date="" v_feature="" v_page="" v_updated=""
	l_adr=1 l_status=1 l_date=1 l_feature=1 l_page=1 l_updated=1 l_refs=1
	refs=""
	links=""
	placeholders=""

	while IFS="$WIKI_TAB" read -r rec a b c; do
		case "$rec" in
		X) nofm=yes ;;
		M) fm_lines=$a ;;
		B) body_lines=$a ;;
		S) sections="$sections$a " ;;
		R) refs="$refs$a$WIKI_TAB" ;;
		L) links="$links$a:$b$WIKI_TAB" ;;
		P) placeholders="$placeholders$a:$b$WIKI_TAB" ;;
		K)
			case "$a" in
			adr) p_adr=yes v_adr=$c l_adr=$b ;;
			title) p_title=yes ;;
			status) p_status=yes v_status=$c l_status=$b ;;
			date) p_date=yes v_date=$c l_date=$b ;;
			feature) p_feature=yes v_feature=$c l_feature=$b ;;
			page) p_page=yes v_page=$c l_page=$b ;;
			source_of_truth) p_sot=yes ;;
			updated) p_updated=yes v_updated=$c l_updated=$b ;;
			code_refs) l_refs=$b ;;
			esac
			;;
		esac
	done < "$SCAN_TMP"

	if [ "$nofm" = yes ]; then
		err "$f:1 missing frontmatter (file must start with ---)"
		continue
	fi
	if [ "$fm_lines" -eq 0 ]; then
		err "$f:1 empty or unterminated frontmatter block"
		continue
	fi

	case "$rel" in
	decisions/*.md)
		[ "$p_adr" = yes ] || err "$f:1 frontmatter missing required key 'adr'"
		[ "$p_title" = yes ] || err "$f:1 frontmatter missing required key 'title'"
		[ "$p_status" = yes ] || err "$f:1 frontmatter missing required key 'status'"
		[ "$p_date" = yes ] || err "$f:1 frontmatter missing required key 'date'"
		case "$v_status" in
		proposed | accepted | superseded | rejected | "") ;;
		*) err "$f:$l_status status '$v_status' not one of proposed|accepted|superseded|rejected" ;;
		esac
		is_date "$v_date" || err "$f:$l_date date '$v_date' is not YYYY-MM-DD"
		num=${rel##*/}
		num=${num%%-*}
		[ "$num" = "$v_adr" ] || err "$f:$l_adr frontmatter adr '$v_adr' does not match filename number '$num'"
		case "$sections" in *" Context "*) ;; *) err "$f:1 ADR missing '## Context'" ;; esac
		case "$sections" in *" Decision "*) ;; *) err "$f:1 ADR missing '## Decision'" ;; esac
		case "$sections" in *" Consequences "*) ;; *) err "$f:1 ADR missing '## Consequences'" ;; esac
		;;
	*)
		# feature and shared pages
		[ "$p_page" = yes ] || err "$f:1 frontmatter missing required key 'page'"
		[ "$p_status" = yes ] || err "$f:1 frontmatter missing required key 'status'"
		[ "$p_updated" = yes ] || err "$f:1 frontmatter missing required key 'updated'"
		case "$rel" in
		features/*)
			[ "$p_feature" = yes ] || err "$f:1 frontmatter missing required key 'feature'"
			[ "$p_sot" = yes ] || err "$f:1 frontmatter missing required key 'source_of_truth'"
			;;
		esac

		case "$v_status" in
		authored | stub) ;;
		*) err "$f:$l_status status '$v_status' not one of authored|stub" ;;
		esac

		is_date "$v_updated" || err "$f:$l_updated updated '$v_updated' is not YYYY-MM-DD"

		case "$rel" in
		features/*)
			feat_dir=${rel#features/}
			feat_dir=${feat_dir%%/*}
			[ "$feat_dir" = "$v_feature" ] || err "$f:$l_feature frontmatter feature '$v_feature' does not match directory '$feat_dir'"
			page_file=${rel##*/}
			page_file=${page_file%.md}
			[ "$v_page" = "$page_file" ] || err "$f:$l_page frontmatter page '$v_page' does not match filename '$page_file'"
			;;
		esac

		# body must not be empty
		if [ "$body_lines" -eq 0 ]; then
			err "$f:1 page has frontmatter but no content"
		elif [ "$v_status" = "authored" ] && [ "$body_lines" -lt 4 ]; then
			wrn "$f:1 status is 'authored' but the body is $body_lines lines — is it really authored?"
		fi

		[ "$v_status" = "stub" ] && wrn "$f:1 status: stub"
		;;
	esac

	# ------ code_refs must still resolve
	#
	# The citations ARE the authority model: a page is only trustworthy because it
	# points at the code it describes. So a ref is checked as a citation, not as a
	# path — `lib/quiz/score.dart:88` in a file that is 40 lines long is dead, and
	# a plain existence check calls it fine.
	page_date=$v_updated
	[ -n "$page_date" ] || page_date=$v_date

	saved_ifs=$IFS
	IFS=$WIKI_TAB
	for ref in $refs; do
		IFS=$saved_ifs
		[ -n "$ref" ] || continue

		# path:line — only a trailing all-digits segment counts, so a Windows-ish
		# or colon-bearing path isn't mistaken for a line number.
		ref_path=$ref
		ref_line=""
		case $ref in
		*:*)
			maybe=${ref##*:}
			case $maybe in
			*[!0-9]* | "") ;;
			*)
				ref_path=${ref%:*}
				ref_line=$maybe
				;;
			esac
			;;
		esac

		if [ ! -e "$ref_path" ]; then
			err "$f:$l_refs code_refs path does not exist: $ref_path"
			IFS=$WIKI_TAB
			continue
		fi

		if [ -n "$ref_line" ]; then
			if [ ! -f "$ref_path" ]; then
				err "$f:$l_refs code_refs cites line $ref_line of $ref_path, which is not a file"
				IFS=$WIKI_TAB
				continue
			fi
			n_lines=$(wc -l < "$ref_path" | tr -d ' ')
			if [ "$ref_line" -gt "${n_lines:-0}" ]; then
				err "$f:$l_refs code_refs cites $ref_path:$ref_line but that file has $n_lines line(s)"
				IFS=$WIKI_TAB
				continue
			fi
		fi

		# The code moved after the page said it was current. Not wrong on its own,
		# but it is where wrongness accumulates — source-drift-watcher's comparison
		# 6, made cheap enough to run on every check.
		if [ "$GIT_OK" = yes ] && is_date "$page_date"; then
			git_last_change "$ref_path"
			if is_date "$GIT_DATE" && [ "$GIT_DATE" \> "$page_date" ]; then
				wrn "$f:$l_refs $ref_path changed on $GIT_DATE, after this page's updated: $page_date"
			fi
		fi
		IFS=$WIKI_TAB
	done
	IFS=$saved_ifs

	# ------ [[links]] must resolve
	#
	# extract_links reported the real line and skipped code spans; page_scan does
	# the same, so a page documenting the syntax in backticks is not a broken link.
	seen_links=" "
	IFS=$WIKI_TAB
	for lnk_rec in $links; do
		IFS=$saved_ifs
		[ -n "$lnk_rec" ] || continue
		lnk_line=${lnk_rec%%:*}
		lnk=${lnk_rec#*:}
		case "$seen_links" in *" $lnk "*) IFS=$WIKI_TAB; continue ;; esac
		seen_links="$seen_links$lnk "
		case "$link_index_flat" in
		*"$WIKI_NL$lnk$WIKI_NL"*) ;;
		*) err "$f:$lnk_line [[$lnk]] does not resolve to a wiki page" ;;
		esac
		IFS=$WIKI_TAB
	done
	IFS=$saved_ifs

	# ------ leftover template placeholders
	if [ "$v_status" = "authored" ] && [ -n "$placeholders" ]; then
		IFS=$WIKI_TAB
		for ph in $placeholders; do
			IFS=$saved_ifs
			[ -n "$ph" ] || continue
			printf 'ERROR %s:%s unreplaced template placeholder: %s\n' "$f" "${ph%%:*}" "${ph#*:}" >&2
			fails=$((fails + 1))
			IFS=$WIKI_TAB
		done
		IFS=$saved_ifs
	fi
done

# ------------------------------------------- ADR citations from code must exist

if [ "$HOOK_MODE" = no ] && [ -d "$WIKI_ROOT/decisions" ]; then
	cited=$(grep -rEho 'ADR-[0-9]{4}' . \
		--exclude-dir=.git \
		--exclude-dir=node_modules \
		--exclude-dir=build \
		--exclude-dir=.dart_tool \
		--exclude-dir="$WIKI_ROOT" \
		2>/dev/null | sort -u)
	for c in $cited; do
		n=${c#ADR-}
		if ! ls "$WIKI_ROOT/decisions/$n"-*.md >/dev/null 2>&1; then
			where=$(grep -rl "$c" . --exclude-dir=.git --exclude-dir="$WIKI_ROOT" 2>/dev/null | head -1)
			err "${where:-code} cites $c but $WIKI_ROOT/decisions/$n-*.md does not exist"
		fi
	done
fi

# ------------------------------------------------------------------- verdict

if [ "$fails" -gt 0 ]; then
	printf 'check-wiki: %d error(s), %d warning(s)\n' "$fails" "$warns" >&2
	exit 1
fi
if [ "$warns" -gt 0 ] && [ "$STRICT" = "true" ]; then
	printf 'check-wiki: %d warning(s), strict_check=true\n' "$warns" >&2
	exit 1
fi
[ "$HOOK_MODE" = yes ] && exit 0
printf 'check-wiki: pass (%d warning(s))\n' "$warns"
exit 0
