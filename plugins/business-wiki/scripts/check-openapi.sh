#!/bin/sh
# check-openapi.sh — the derived spec parses, every path the wiki references
# exists in it, and every route the code exposes is documented.
#
# Usage: sh check-openapi.sh
# Exits 0 immediately when openapi_path is unset/empty (project has no HTTP
# surface). POSIX sh; uses python3 for a YAML/JSON parse only if available.

set -u

WIKI_ROOT="${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-business-wiki}"
SPEC="${CLAUDE_PLUGIN_OPTION_OPENAPI_PATH:-openapi/api.yaml}"
CONTRACT_SRC="${CLAUDE_PLUGIN_OPTION_CONTRACT_SOURCE:-}"
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

if [ -z "$SPEC" ]; then
	printf 'check-openapi: skipped (openapi_path is empty — no HTTP surface)\n'
	exit 0
fi

[ -f "$SPEC" ] || {
	err "$SPEC does not exist — run /business-wiki:derive"
	exit 1
}

# ------------------------------------------------------------------ it parses

if command -v python3 >/dev/null 2>&1; then
	python3 - "$SPEC" <<'PY' 2>/dev/null || err "$SPEC does not parse as YAML/JSON"
import sys
p = sys.argv[1]
try:
    import yaml
except ImportError:
    # no PyYAML: fall back to JSON, and treat YAML as unverified
    import json
    if p.endswith(('.json',)):
        json.load(open(p))
    sys.exit(0)
d = yaml.safe_load(open(p))
assert isinstance(d, dict), 'top level is not a mapping'
assert 'openapi' in d, "missing 'openapi' version key"
assert 'paths' in d and d['paths'], "missing or empty 'paths'"
PY
fi

grep -q '^openapi:' "$SPEC" || err "$SPEC has no top-level 'openapi:' version key"
grep -q '^paths:' "$SPEC" || err "$SPEC has no top-level 'paths:'"

# paths declared in the spec (two-space indented keys starting with /)
spec_paths=$(sed -n '/^paths:/,/^[a-z]/p' "$SPEC" | sed -n 's/^  \(\/[A-Za-z0-9_{}\/:.-]*\):[[:space:]]*$/\1/p' | sort -u)
[ -n "$spec_paths" ] || err "$SPEC declares no paths"

# ------------------------------------------- wiki api.md references must resolve

for f in "$WIKI_ROOT"/features/*/api.md; do
	[ -f "$f" ] || continue
	# A path reference in a wiki table looks like `GET /taxonomy` or `POST /quiz`.
	# Everything from a '## Planned' heading onward names endpoints that deliberately
	# do NOT exist yet, so it is excluded — documenting an absence is not a broken ref.
	refs=$(awk '/^##[[:space:]]+Planned/ { exit } { print }' "$f" |
		grep -oE '\`(GET|POST|PUT|PATCH|DELETE)[[:space:]]+/[A-Za-z0-9_{}/:.-]*\`' 2>/dev/null |
		tr -d '`' | awk '{print $2}' | sort -u)
	for p in $refs; do
		printf '%s\n' "$spec_paths" | grep -qx "$p" ||
			err "$f references '$p' which is not a path in $SPEC"
	done
done

# ------------------------------------------ every real route must be documented

if [ -n "$CONTRACT_SRC" ] && [ -e "$CONTRACT_SRC" ]; then
	# Common router registration shapes: app.get('/x'), router.post("/x"),
	# @app.route('/x'), get '/x'. Collect the quoted first argument.
	code_paths=$(grep -rhoE "\.(get|post|put|patch|delete)\(['\"][^'\"]+['\"]" "$CONTRACT_SRC" 2>/dev/null |
		sed "s/.*(['\"]//; s/['\"]$//" | sort -u)
	for p in $code_paths; do
		case "$p" in
		'*' | /\* | '') continue ;;
		esac
		printf '%s\n' "$spec_paths" | grep -qx "$p" ||
			err "$CONTRACT_SRC exposes '$p' but $SPEC does not document it"
	done
	for p in $spec_paths; do
		printf '%s\n' "$code_paths" | grep -qx "$p" ||
			wrn "$SPEC documents '$p' but no route for it was found in $CONTRACT_SRC"
	done
else
	wrn "contract_source is unset or missing — cannot verify the spec against real routes"
fi

if [ "$fails" -gt 0 ]; then
	printf 'check-openapi: %d error(s), %d warning(s)\n' "$fails" "$warns" >&2
	exit 1
fi
if [ "$warns" -gt 0 ] && [ "$STRICT" = "true" ]; then
	printf 'check-openapi: %d warning(s), strict_check=true\n' "$warns" >&2
	exit 1
fi
printf 'check-openapi: pass (%d warning(s))\n' "$warns"
exit 0
