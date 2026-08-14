# local-plugs

Lau's Claude Code plugin marketplace. One repo, many plugins.

## Install

```bash
# from any project
/plugin marketplace add ~/Documents/workspace/local-plugs
/plugin install business-wiki@local-plugs
```

Once this repo is on GitHub, `/plugin marketplace add <owner>/local-plugs` works the same way.

## Plugins

| Plugin | What it gives you |
| --- | --- |
| [`business-wiki`](plugins/business-wiki) | A `business-docs/` tree — `wiki/` as the source of truth for business rules, with derived `rules/*.json` and `openapi/` — plus four keeper agents that regenerate them and report drift. |

## Adding a plugin

1. `mkdir -p plugins/<name>/.claude-plugin` and write `plugin.json` (only `name` is required).
2. Put components at the **plugin root** — `agents/`, `skills/<name>/SKILL.md`, `hooks/hooks.json`, `scripts/`. Never inside `.claude-plugin/`.
3. Add an entry to `.claude-plugin/marketplace.json` with `"source": "./plugins/<name>"`.
4. `claude plugin validate ./plugins/<name>`, then `/plugin marketplace update`.
