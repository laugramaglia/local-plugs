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

WIKI_ROOT="${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-business-docs/wiki}"
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
	# PostToolUse delivers JSON on stdin; pull the first file_path out of it
	# without assuming jq is installed.
	edited=$(
		cat 2>/dev/null |
			tr ',{}' '\n\n\n' |
			grep '"file_path"' |
			head -1 |
			sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"//; s/".*//'
	)
	[ -n "$edited" ] || exit 0
	# absolute -> relative to the project root
	case "$edited" in
	"$PWD"/*) edited=$(printf '%s' "$edited" | cut -c $((${#PWD} + 2))-) ;;
	esac
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

ALL_PAGES=$(find "$WIKI_ROOT" -name '*.md' -type f |
	grep -v "^$WIKI_ROOT/shared/templates/" |
	sort)

if [ -z "$TARGETS" ]; then
	TARGETS="$ALL_PAGES"
fi

# ------------------------------------------------------------ link name index
# features/<f>/<page>.md -> "<f>-<page>";  shared/<x>.md -> "<x>"

emit_link_names() {
	for f in $ALL_PAGES; do
		rel=${f#"$WIKI_ROOT"/}
		case "$rel" in
		features/*/*.md)
			feat=$(printf '%s' "$rel" | cut -d/ -f2)
			page=$(basename "$rel" .md)
			printf '%s-%s\n' "$feat" "$page"
			;;
		shared/*.md)
			basename "$rel" .md
			;;
		esac
	done
}

link_index=$(emit_link_names | sort -u)

# --------------------------------------------------------------------- helpers

# print the frontmatter body (without the --- fences) of $1
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

# list_items <frontmatter> <key>  — YAML block-sequence values under <key>
list_items() {
	printf '%s\n' "$1" | awk -v k="$2" '
		$0 ~ "^"k":" { inblock = 1; next }
		inblock && /^[[:space:]]*-[[:space:]]*/ {
			sub(/^[[:space:]]*-[[:space:]]*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print; next
		}
		inblock && /^[^[:space:]]/ { inblock = 0 }
	'
}

# line_of <file> <pattern> — first matching line number, or 1
line_of() {
	n=$(grep -n "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1)
	[ -n "$n" ] && printf '%s' "$n" || printf '1'
}

is_date() {
	printf '%s' "$1" | grep -q '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$'
}

# A scratch file so the code_refs loop reads from a redirect rather than a pipe:
# in a pipeline the loop body runs in a subshell, where err()/wrn() increment a
# copy of the counters and every finding is lost on the way out.
REFS_TMP="${TMPDIR:-/tmp}/check-wiki.refs.$$"
trap 'rm -f "$REFS_TMP"' EXIT INT TERM

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

	if [ "$(head -1 "$f")" != "---" ]; then
		err "$f:1 missing frontmatter (file must start with ---)"
		continue
	fi

	fm=$(frontmatter "$f")
	if [ -z "$fm" ]; then
		err "$f:1 empty or unterminated frontmatter block"
		continue
	fi

	case "$rel" in
	decisions/*.md)
		for k in adr title status date; do
			has_key "$fm" "$k" || err "$f:1 frontmatter missing required key '$k'"
		done
		st=$(value_of "$fm" status)
		case "$st" in
		proposed | accepted | superseded | rejected | "") ;;
		*) err "$f:$(line_of "$f" '^status:') status '$st' not one of proposed|accepted|superseded|rejected" ;;
		esac
		d=$(value_of "$fm" date)
		is_date "$d" || err "$f:$(line_of "$f" '^date:') date '$d' is not YYYY-MM-DD"
		num=$(basename "$rel" | cut -d- -f1)
		adr=$(value_of "$fm" adr)
		[ "$num" = "$adr" ] || err "$f:$(line_of "$f" '^adr:') frontmatter adr '$adr' does not match filename number '$num'"
		grep -q '^## Context' "$f" || err "$f:1 ADR missing '## Context'"
		grep -q '^## Decision' "$f" || err "$f:1 ADR missing '## Decision'"
		grep -q '^## Consequences' "$f" || err "$f:1 ADR missing '## Consequences'"
		;;
	*)
		# feature and shared pages
		req="page status updated"
		case "$rel" in
		features/*) req="feature page status source_of_truth updated" ;;
		esac
		for k in $req; do
			has_key "$fm" "$k" || err "$f:1 frontmatter missing required key '$k'"
		done

		st=$(value_of "$fm" status)
		case "$st" in
		authored | stub) ;;
		*) err "$f:$(line_of "$f" '^status:') status '$st' not one of authored|stub" ;;
		esac

		u=$(value_of "$fm" updated)
		is_date "$u" || err "$f:$(line_of "$f" '^updated:') updated '$u' is not YYYY-MM-DD"

		case "$rel" in
		features/*)
			feat_dir=$(printf '%s' "$rel" | cut -d/ -f2)
			feat_fm=$(value_of "$fm" feature)
			[ "$feat_dir" = "$feat_fm" ] || err "$f:$(line_of "$f" '^feature:') frontmatter feature '$feat_fm' does not match directory '$feat_dir'"
			page_fm=$(value_of "$fm" page)
			page_file=$(basename "$rel" .md)
			[ "$page_fm" = "$page_file" ] || err "$f:$(line_of "$f" '^page:') frontmatter page '$page_fm' does not match filename '$page_file'"
			;;
		esac

		# body must not be empty
		body_lines=$(awk 'NR==1{next} /^---[[:space:]]*$/ && !seen {seen=1; next} seen && NF {c++} END{print c+0}' "$f")
		if [ "$body_lines" -eq 0 ]; then
			err "$f:1 page has frontmatter but no content"
		elif [ "$st" = "authored" ] && [ "$body_lines" -lt 4 ]; then
			wrn "$f:1 status is 'authored' but the body is $body_lines lines — is it really authored?"
		fi

		[ "$st" = "stub" ] && wrn "$f:1 status: stub"
		;;
	esac

	# ------ code_refs must still resolve
	#
	# The citations ARE the authority model: a page is only trustworthy because it
	# points at the code it describes. So a ref is checked as a citation, not as a
	# path — `lib/quiz/score.dart:88` in a file that is 40 lines long is dead, and
	# a plain existence check calls it fine.
	page_date=$(value_of "$fm" updated)
	[ -n "$page_date" ] || page_date=$(value_of "$fm" date)
	refs_line=$(line_of "$f" '^code_refs:')

	list_items "$fm" code_refs > "$REFS_TMP"
	while IFS= read -r ref; do
		[ -n "$ref" ] || continue

		# path:line — only a trailing all-digits segment counts, so a Windows-ish
		# or colon-bearing path isn't mistaken for a line number.
		ref_path=$ref
		ref_line=""
		case $ref in
		*:*)
			maybe=${ref##*:}
			if printf '%s' "$maybe" | grep -q '^[0-9][0-9]*$'; then
				ref_path=${ref%:*}
				ref_line=$maybe
			fi
			;;
		esac

		if [ ! -e "$ref_path" ]; then
			err "$f:$refs_line code_refs path does not exist: $ref_path"
			continue
		fi

		if [ -n "$ref_line" ]; then
			if [ ! -f "$ref_path" ]; then
				err "$f:$refs_line code_refs cites line $ref_line of $ref_path, which is not a file"
				continue
			fi
			n_lines=$(wc -l < "$ref_path" | tr -d ' ')
			if [ "$ref_line" -gt "${n_lines:-0}" ]; then
				err "$f:$refs_line code_refs cites $ref_path:$ref_line but that file has $n_lines line(s)"
				continue
			fi
		fi

		# The code moved after the page said it was current. Not wrong on its own,
		# but it is where wrongness accumulates — source-drift-watcher's comparison
		# 6, made cheap enough to run on every check.
		if [ "$GIT_OK" = yes ] && is_date "$page_date"; then
			last=$(git log -1 --format=%cd --date=short -- "$ref_path" 2>/dev/null)
			if is_date "$last" && [ "$last" \> "$page_date" ]; then
				wrn "$f:$refs_line $ref_path changed on $last, after this page's updated: $page_date"
			fi
		fi
	done < "$REFS_TMP"

	# ------ [[links]] must resolve
	for lnk in $(grep -o '\[\[[^]]*\]\]' "$f" 2>/dev/null | sed 's/^\[\[//; s/\]\]$//' | sort -u); do
		if ! printf '%s\n' "$link_index" | grep -qx "$lnk"; then
			err "$f:$(line_of "$f" "\[\[$lnk\]\]") [[$lnk]] does not resolve to a wiki page"
		fi
	done

	# ------ leftover template placeholders
	if [ "$(value_of "$fm" status)" = "authored" ]; then
		ph=$(grep -nE 'FEATURE_SLUG|FEATURE_NAME|PROJECT_NAME|PATH/TO|NNNN-slug|YYYY-MM-DD' "$f" | head -3)
		if [ -n "$ph" ]; then
			printf '%s\n' "$ph" | while IFS=: read -r ln rest; do
				printf 'ERROR %s:%s unreplaced template placeholder: %s\n' "$f" "$ln" "$(printf '%s' "$rest" | cut -c1-60)" >&2
			done
			fails=$((fails + $(printf '%s\n' "$ph" | wc -l | tr -d ' ')))
		fi
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
