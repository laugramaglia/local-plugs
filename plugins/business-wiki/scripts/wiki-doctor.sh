#!/bin/sh
# wiki-doctor.sh — one diagnostic over the whole system, and the safe half of
# the repair.
#
#   sh wiki-doctor.sh           diagnose: run every validator, classify every
#                               finding, say what fixes it and who owns it
#   sh wiki-doctor.sh --fix     also repair what can be repaired mechanically:
#                               the derived index. Never touches authored prose.
#   sh wiki-doctor.sh --quiet   the verdict line only
#
# Exit 0 = no errors (warnings allowed unless strict_check=true), 1 = errors.
#
# The split matters. A stale index is a fact about a derived file and a script
# can fix it. A broken link is a question about what the author meant, and a
# script that guesses at that produces a wiki that validates and lies.
#
# POSIX sh, no runtime dependencies. Run from the project root.

set -u

HERE=$(dirname "$0")
. "$HERE/lib-wiki.sh"

WIKI_ROOT=$(wiki_root)
INDEX_PATH=$(index_path)
STRICT="${CLAUDE_PLUGIN_OPTION_STRICT_CHECK:-false}"

FIX=no
QUIET=no
for a in "$@"; do
	case "$a" in
	--fix) FIX=yes ;;
	--quiet) QUIET=yes ;;
	*)
		printf 'wiki-doctor: unknown argument: %s\n' "$a" >&2
		exit 2
		;;
	esac
done

OUT="${TMPDIR:-/tmp}/wiki-doctor.$$"
trap 'rm -f "$OUT" "$OUT".*' EXIT INT TERM

say() { [ "$QUIET" = yes ] || printf '%s\n' "$*"; }

# ------------------------------------------------------------------ the fixes
#
# Which finding is fixed by what, and by whom. Keeping this in one table is the
# point of the script: a wall of validator output tells you what is wrong and
# nothing about what to do next.
classify() { # <message> <validator> -> FIX_HINT, FIX_OWNER, FIX_AUTO
	FIX_AUTO=no
	case "$1" in
	*"not set up"* | *"does not exist — run /business-wiki:bootstrap"*)
		FIX_HINT="/business-wiki:bootstrap"
		FIX_OWNER="you"
		;;
	*"is out of date"* | *"index.tsv does not exist"*)
		FIX_HINT="sh wiki-index.sh --write"
		FIX_OWNER="derived"
		FIX_AUTO=yes
		;;
	*"claimed by more than one page"*)
		FIX_HINT="rename one of the two files"
		FIX_OWNER="wiki-keeper"
		;;
	*"contains a comma"*)
		FIX_HINT="rename the file without the comma"
		FIX_OWNER="wiki-keeper"
		;;
	*"does not resolve to a wiki page"*)
		FIX_HINT="fix the [[link]], or write the page it names"
		FIX_OWNER="wiki-keeper"
		;;
	*"relative link does not resolve"*)
		FIX_HINT="correct the href — usually a renamed ADR whose citation was left behind"
		FIX_OWNER="wiki-keeper"
		;;
	*"code_refs path does not exist"* | *"code_refs cites"*)
		FIX_HINT="update the citation; check git log --diff-filter=D before deleting the rule"
		FIX_OWNER="wiki-keeper"
		;;
	*"after this page's updated"*)
		FIX_HINT="re-verify the page against the code, then bump updated:"
		FIX_OWNER="wiki-keeper"
		;;
	*"frontmatter missing required key"* | *"not one of"* | *"is not YYYY-MM-DD"* | *"does not match"*)
		FIX_HINT="correct the frontmatter"
		FIX_OWNER="wiki-keeper"
		;;
	*"unreplaced template placeholder"*)
		FIX_HINT="write the page, or set status: stub and say what is missing"
		FIX_OWNER="wiki-keeper"
		;;
	*"ADR missing"*)
		FIX_HINT="add the missing section to the ADR"
		FIX_OWNER="wiki-keeper"
		;;
	*"but "*"does not exist"*)
		FIX_HINT="write the ADR, or correct the citation in the code"
		FIX_OWNER="wiki-keeper"
		;;
	*"declares no rules"*)
		FIX_HINT="the wiki states no rules for this feature yet — author it, or /business-wiki:derive"
		FIX_OWNER="wiki-keeper"
		;;
	*"status: stub"*)
		FIX_HINT="/business-wiki:feature <name> — or leave it, an honest stub is not a defect"
		FIX_OWNER="wiki-keeper"
		;;
	*"page has frontmatter but no content"* | *"is it really authored"*)
		FIX_HINT="author the page, or set status: stub"
		FIX_OWNER="wiki-keeper"
		;;
	*"/business-wiki:derive"*)
		FIX_HINT="/business-wiki:derive"
		FIX_OWNER="business-rules-keeper"
		;;
	*"hand-derived"* | *"derived_by"* | *"x-derived-by"*)
		FIX_HINT="/business-wiki:derive"
		FIX_OWNER="business-rules-keeper / openapi-keeper"
		;;
	*)
		# Nothing matched. The validator that reported it is a better guide to
		# the owner than any keyword: an undocumented endpoint is the
		# openapi-keeper-s problem however it happens to be worded.
		case "${2:-wiki}" in
		openapi)
			FIX_HINT="/business-wiki:derive — the spec is behind the code or the wiki"
			FIX_OWNER="openapi-keeper"
			;;
		rules)
			FIX_HINT="/business-wiki:derive"
			FIX_OWNER="business-rules-keeper"
			;;
		setup)
			FIX_HINT="/business-wiki:bootstrap"
			FIX_OWNER="you"
			;;
		*)
			FIX_HINT="see the validator that reported it"
			FIX_OWNER="wiki-keeper"
			;;
		esac
		;;
	esac
}

# ----------------------------------------------------------------- the checks

run_check() { # <label> <command...>
	label=$1
	shift
	"$@" > "$OUT.raw" 2>&1
	rc=$?
	e=$(grep -c '^ERROR' "$OUT.raw" 2>/dev/null)
	w=$(grep -c '^WARN' "$OUT.raw" 2>/dev/null)
	e=${e:-0}
	w=${w:-0}
	printf '%s\t%s\t%s\t%s\n' "$label" "$rc" "$e" "$w" >> "$OUT.summary"
	sed -n 's/^ERROR /error\t'"$label"'\t/p' "$OUT.raw" >> "$OUT.findings"
	sed -n 's/^WARN  */warn\t'"$label"'\t/p' "$OUT.raw" >> "$OUT.findings"
	# a validator can fail without printing a single ERROR line (health does)
	if [ "$rc" -ne 0 ] && [ "$e" -eq 0 ]; then
		grep -v '^$' "$OUT.raw" | tail -1 | sed 's/^/error\t'"$label"'\t/' >> "$OUT.findings"
	fi
}

: > "$OUT.summary"
: > "$OUT.findings"

say "business-wiki doctor — $WIKI_ROOT"
say ""

run_check setup sh "$HERE/wiki-health.sh"
if [ -d "$WIKI_ROOT" ]; then
	run_check wiki sh "$HERE/check-wiki.sh"
	run_check index sh "$HERE/wiki-index.sh" --check
	run_check rules sh "$HERE/check-rules.sh"
	SPEC="${CLAUDE_PLUGIN_OPTION_OPENAPI_PATH-business-docs/openapi/api.yaml}"
	[ -n "$SPEC" ] && run_check openapi sh "$HERE/check-openapi.sh"
fi

# ------------------------------------------------------------------- the fix

fixed=0
if [ "$FIX" = yes ] && [ -d "$WIKI_ROOT" ]; then
	if grep -q 'index' "$OUT.findings" 2>/dev/null &&
		grep -qE 'is out of date|index.tsv does not exist' "$OUT.findings" 2>/dev/null; then
		if sh "$HERE/wiki-index.sh" --write >/dev/null 2>&1; then
			fixed=$((fixed + 1))
			say "fixed: rebuilt $INDEX_PATH"
			# re-run the checks it affects, so the report is post-fix
			: > "$OUT.summary"
			: > "$OUT.findings"
			run_check setup sh "$HERE/wiki-health.sh"
			run_check wiki sh "$HERE/check-wiki.sh"
			run_check index sh "$HERE/wiki-index.sh" --check
			run_check rules sh "$HERE/check-rules.sh"
			[ -n "${SPEC:-}" ] && run_check openapi sh "$HERE/check-openapi.sh"
			say ""
		fi
	fi
fi

# ---------------------------------------------------------------- the report

# Two validators reporting one fact is one finding. check-wiki reports a
# dangling link per page with its real line; wiki-index --check reports the same
# edge at graph level, anchored at line 1. Dedupe on the message with the line
# number normalised away, and keep the first — which is the one with the line.
awk -F'\t' '{ k = $3; sub(/:[0-9]+ /, " ", k); if (!seen[k]++) print }' \
	"$OUT.findings" > "$OUT.dedup"


if [ "$QUIET" = no ]; then
	while IFS="$WIKI_TAB" read -r label rc e w; do
		if [ "$e" -gt 0 ]; then
			printf '  %-10s %d error(s), %d warning(s)\n' "$label" "$e" "$w"
		elif [ "$w" -gt 0 ]; then
			printf '  %-10s ok (%d warning(s))\n' "$label" "$w"
		elif [ "$rc" -ne 0 ]; then
			printf '  %-10s FAILED\n' "$label"
		else
			printf '  %-10s ok\n' "$label"
		fi
	done < "$OUT.summary"

	# Graph health has no validator of its own: an orphan page and an unlinked
	# mention are not errors, they are places the graph is thinner than the wiki.
	if [ -d "$WIKI_ROOT" ] && [ -f "$INDEX_PATH" ]; then
		orph=$(grep -v '^#' "$INDEX_PATH" | awk -F'\t' '
			{ name[$1] = 1; if ($10 != "") { c = split($10, a, ","); for (i = 1; i <= c; i++) tgt[a[i]] = 1 } }
			END { n = 0; for (k in name) if (!(k in tgt)) n++; print n }')
		ment=$(sh "$HERE/wiki-index.sh" --mentions 2>/dev/null | grep -c .)
		ment=${ment:-0}
		printf '  %-10s %d page(s) with no backlinks, %d unlinked mention(s)\n' graph "$orph" "$ment"
	fi
	printf '\n'
fi

nerr=$(grep -c '^error' "$OUT.dedup" 2>/dev/null)
nwarn=$(grep -c '^warn' "$OUT.dedup" 2>/dev/null)
nerr=${nerr:-0}
nwarn=${nwarn:-0}

if [ "$QUIET" = no ] && [ -s "$OUT.dedup" ]; then
	printf 'FINDINGS — errors first\n'
	{
		grep '^error' "$OUT.dedup" 2>/dev/null
		grep '^warn' "$OUT.dedup" 2>/dev/null
	} > "$OUT.sorted"
	shown=0
	while IFS="$WIKI_TAB" read -r sev label msg; do
		[ -n "$msg" ] || continue
		shown=$((shown + 1))
		if [ "$sev" = warn ] && [ "$shown" -gt 40 ]; then
			continue
		fi
		classify "$msg" "$label"
		printf '  [%s/%s] %s\n' "$sev" "$label" "$msg"
		printf '        fix: %s   owner: %s\n' "$FIX_HINT" "$FIX_OWNER"
	done < "$OUT.sorted"
	if [ "$shown" -gt 40 ]; then
		printf '  ... %d more warning(s) not listed\n' "$((shown - 40))"
	fi
	printf '\n'
fi

auto=0
while IFS="$WIKI_TAB" read -r sev label msg; do
	[ -n "$msg" ] || continue
	classify "$msg" "$label"
	[ "$FIX_AUTO" = yes ] && auto=$((auto + 1))
done < "$OUT.dedup"

printf 'doctor: %d error(s), %d warning(s)' "$nerr" "$nwarn"
[ "$fixed" -gt 0 ] && printf ', %d fixed' "$fixed"
if [ "$auto" -gt 0 ] && [ "$FIX" = no ]; then
	printf ' — %d auto-fixable, re-run with --fix' "$auto"
fi
printf '\n'

[ "$nerr" -gt 0 ] && exit 1
if [ "$nwarn" -gt 0 ] && [ "$STRICT" = "true" ]; then
	exit 1
fi
exit 0
