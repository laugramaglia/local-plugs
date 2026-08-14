#!/bin/sh
# wiki-health.sh — is the system installed in this repo at all?
# No network, no MCP, no dependencies. Run from the project root.
# Exit 0 = healthy, 1 = not set up (run /business-wiki:bootstrap).

set -u

WIKI_ROOT="${CLAUDE_PLUGIN_OPTION_WIKI_ROOT:-business-wiki}"
RULES_ROOT="${CLAUDE_PLUGIN_OPTION_RULES_ROOT:-business-rules}"
SPEC="${CLAUDE_PLUGIN_OPTION_OPENAPI_PATH:-openapi/api.yaml}"

ok=0
check() {
	if [ "$1" = ok ]; then
		printf '  ok    %s\n' "$2"
	else
		printf '  FAIL  %s\n' "$2"
		ok=1
	fi
}

printf 'business-wiki health:\n'

[ -f "$WIKI_ROOT/README.md" ] && check ok "$WIKI_ROOT/README.md" || check fail "$WIKI_ROOT/README.md"
[ -d "$WIKI_ROOT/decisions" ] && check ok "$WIKI_ROOT/decisions/" || check fail "$WIKI_ROOT/decisions/"
[ -d "$WIKI_ROOT/shared" ] && check ok "$WIKI_ROOT/shared/" || check fail "$WIKI_ROOT/shared/"
[ -d "$RULES_ROOT" ] && check ok "$RULES_ROOT/" || check fail "$RULES_ROOT/"
[ -f "$RULES_ROOT/_schema.json" ] && check ok "$RULES_ROOT/_schema.json" || check fail "$RULES_ROOT/_schema.json"

n=$(find "$WIKI_ROOT/features" -name index.md -type f 2>/dev/null | wc -l | tr -d ' ')
[ "${n:-0}" -gt 0 ] && check ok "$n feature index page(s)" || check fail "no features/*/index.md"

if [ -n "$SPEC" ]; then
	if [ -f "$SPEC" ]; then
		check ok "$SPEC"
	else
		# Same discovery rule as check-openapi.sh: a project that named its spec
		# something else is configured fine, not broken.
		dir=$(dirname "$SPEC")
		[ "$dir" = "." ] && dir=openapi
		found=$(find "$dir" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) 2>/dev/null | sort)
		n=$(printf '%s\n' "$found" | grep -c .)
		if [ "$n" -eq 1 ]; then
			check ok "$(printf '%s' "$found") (discovered)"
		else
			check fail "$SPEC"
		fi
	fi
else
	printf '  skip  OpenAPI (openapi_path is empty)\n'
fi

if [ "$ok" -eq 0 ]; then
	printf 'healthy\n'
else
	printf 'not set up — run /business-wiki:bootstrap\n'
fi
exit "$ok"
