#!/bin/sh
# check-rules.sh — validate the derived rules JSON against its schema's
# expectations and against the wiki it was derived from.
#
# Usage: sh check-rules.sh
# Exit 0 = pass, 1 = failures. POSIX sh; uses python3 only if present, for a
# JSON syntax check. Run from the project root.

set -u

WIKI_ROOT="${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-business-wiki}"
RULES_ROOT="${CLAUDE_PLUGIN_OPTION_RULES_ROOT:-business-rules}"
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

[ -d "$RULES_ROOT" ] || {
	err "rules root '$RULES_ROOT' does not exist — run /business-wiki:derive"
	exit 1
}
[ -f "$RULES_ROOT/_schema.json" ] || err "$RULES_ROOT/_schema.json is missing"

VALID_STATUS='enforced documented-not-enforced aspirational'
VALID_PAGES='index flow screens states errors copy validations api decisions related'

json_strings() { # json_strings <file> <key> -> one value per line
	grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null |
		sed "s/.*:[[:space:]]*\"//; s/\"$//"
}

# ------------------------------------------------ every wiki feature is derived

if [ -d "$WIKI_ROOT/features" ]; then
	for d in "$WIKI_ROOT"/features/*/; do
		[ -d "$d" ] || continue
		feat=$(basename "$d")
		# a feature with every page still a stub has nothing to derive yet
		if [ ! -f "$RULES_ROOT/$feat.json" ]; then
			if grep -rq '^status: authored' "$d" 2>/dev/null; then
				err "$RULES_ROOT/$feat.json is missing for authored feature '$feat' — run /business-wiki:derive $feat"
			else
				wrn "$feat has no derived rules file (all pages are stubs)"
			fi
		fi
	done
fi

# ---------------------------------------------------------- each derived file

for f in "$RULES_ROOT"/*.json; do
	[ -f "$f" ] || continue
	base=$(basename "$f")
	[ "$base" = "_schema.json" ] && continue
	feat=$(basename "$f" .json)

	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null ||
			err "$f is not valid JSON"
	fi

	for k in _source feature updated rules; do
		grep -q "\"$k\"" "$f" || err "$f missing required key '$k'"
	done

	fv=$(json_strings "$f" feature | head -1)
	[ "$fv" = "$feat" ] || err "$f has feature '$fv' but is named '$base'"

	src=$(json_strings "$f" _source | head -1)
	if [ -n "$src" ]; then
		[ -d "$src" ] || err "$f _source '$src' is not an existing directory"
	fi

	upd=$(json_strings "$f" updated | head -1)
	printf '%s' "$upd" | grep -q '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$' ||
		err "$f updated '$upd' is not YYYY-MM-DD"

	ids=$(json_strings "$f" id)
	[ -n "$ids" ] || wrn "$f declares no rules"

	dupes=$(printf '%s\n' "$ids" | sort | uniq -d)
	[ -z "$dupes" ] || for d in $dupes; do err "$f duplicate rule id '$d'"; done

	for st in $(json_strings "$f" status | sort -u); do
		echo "$VALID_STATUS" | grep -qw "$st" || err "$f invalid rule status '$st'"
	done

	for pg in $(json_strings "$f" page | sort -u); do
		echo "$VALID_PAGES" | grep -qw "$pg" || err "$f invalid page '$pg'"
		[ -f "$WIKI_ROOT/features/$feat/$pg.md" ] ||
			err "$f references page '$pg' but $WIKI_ROOT/features/$feat/$pg.md does not exist"
	done

	# a documented-not-enforced rule must be in the divergence ledger
	if grep -q '"documented-not-enforced"' "$f"; then
		[ -f "$WIKI_ROOT/shared/divergences.md" ] ||
			err "$f has documented-not-enforced rules but $WIKI_ROOT/shared/divergences.md does not exist"
	fi

	# adrs must exist
	for a in $(grep -o '"[0-9][0-9][0-9][0-9]"' "$f" 2>/dev/null | tr -d '"' | sort -u); do
		ls "$WIKI_ROOT/decisions/$a"-*.md >/dev/null 2>&1 ||
			wrn "$f references ADR $a but $WIKI_ROOT/decisions/$a-*.md does not exist"
	done

	# the wiki's own index must agree with what was derived
	idx="$WIKI_ROOT/features/$feat/rules.json"
	if [ -f "$idx" ]; then
		for id in $(grep -o '"[a-z0-9][a-z0-9-]*"' "$idx" 2>/dev/null | tr -d '"' | sort -u); do
			case "$id" in
			_source | _derived | _comment | feature | rule_ids | "$feat") continue ;;
			esac
			printf '%s\n' "$ids" | grep -qx "$id" ||
				err "$idx lists rule id '$id' which is not in $f — re-derive"
		done
	else
		wrn "$WIKI_ROOT/features/$feat/rules.json (index) is missing"
	fi
done

if [ "$fails" -gt 0 ]; then
	printf 'check-rules: %d error(s), %d warning(s)\n' "$fails" "$warns" >&2
	exit 1
fi
if [ "$warns" -gt 0 ] && [ "$STRICT" = "true" ]; then
	printf 'check-rules: %d warning(s), strict_check=true\n' "$warns" >&2
	exit 1
fi
printf 'check-rules: pass (%d warning(s))\n' "$warns"
exit 0
