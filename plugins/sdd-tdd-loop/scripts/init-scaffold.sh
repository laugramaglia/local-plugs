#!/usr/bin/env bash
# Write the two files a repo needs before the loop can run in it: its seam
# profile, and (only when there's a wiki) its wiki connection.
#
# Usage:
#   init-scaffold.sh --list-profiles
#   init-scaffold.sh --profile <name|path> [--wiki auto|<repo-rel-path>] [--force]
#
#   --profile   a shipped starter profile by name (see --list-profiles) or a
#               path to one you wrote or merged yourself. Merging is expected in
#               a multi-stack repo: the profile is per REPO, not per package.
#   --wiki      auto  -> write the wiki keys only if business-docs/wiki exists
#               <path> -> write that path explicitly
#               omitted -> don't touch the config at all
#   --force     overwrite an existing seams.json. Off by default: a repo whose
#               profile someone tuned by hand must not lose it to a re-run.
#
# What this script deliberately does NOT write:
#   - the task store — task.sh creates it on first use, and two writers of one
#     file is how a store ends up reset
#   - tracks/ — scaffold-track.sh owns that, per track
#   - the repo-local language skill — that's prose about how tests are written
#     here, read out of the repo by /sdd-init. A script can only produce a
#     stock template, and a stock template that looks reviewed is worse than
#     no guide at all
#
# Idempotent: run it twice and the second run reports what already exists and
# changes nothing.
set -uo pipefail

# shellcheck source=seam-profile.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/seam-profile.sh"
# shellcheck source=_confirm.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_confirm.sh"

PROFILES_DIR="$PLUGIN_ROOT_DIR/templates/seam-profiles"

require_tools jq || exit 1

if [ "${1:-}" = "--list-profiles" ]; then
  echo "# shipped starter profiles"
  for pf in "$PROFILES_DIR"/*.json; do
    [ -f "$pf" ] || continue
    printf 'profile=%s detect=%s\n' \
      "$(jq -r '.name' "$pf")" \
      "$(jq -r '[.detect[]?] | join(",")' "$pf")"
    printf '  seams=%s\n' "$(jq -r '[.seams[].name] | join(" ")' "$pf")"
  done
  echo
  echo "None of them is a match for your repo until the probe proves it: copy,"
  echo "delete the seams this repo doesn't write, then run probe-test-seams.sh."
  exit 0
fi

profile_arg=""
wiki_arg=""
force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) profile_arg="${2:-}"; shift 2 || true ;;
    --wiki)    wiki_arg="${2:-}"; shift 2 || true ;;
    --force)   force=1; shift ;;
    *) echo "Unknown option '$1'. Usage: init-scaffold.sh --profile <name|path> [--wiki auto|<path>] [--force]"; exit 2 ;;
  esac
done

if [ -z "$profile_arg" ]; then
  echo "Usage: init-scaffold.sh --profile <name|path> [--wiki auto|<path>] [--force]"
  echo "       init-scaffold.sh --list-profiles"
  exit 2
fi

# A name resolves against the shipped profiles; anything with a slash or a .json
# suffix is taken as a path, resolved against the repo when it's relative.
src=""
if [ -f "$PROFILES_DIR/$profile_arg.json" ]; then
  src="$PROFILES_DIR/$profile_arg.json"
elif [ -f "$profile_arg" ]; then
  src="$profile_arg"
elif [ -f "$REPO_ROOT/$profile_arg" ]; then
  src="$REPO_ROOT/$profile_arg"
else
  echo "STOP HERE: no profile '$profile_arg' — not a shipped name and not a readable file."
  echo "Shipped names: $(for pf in "$PROFILES_DIR"/*.json; do basename "$pf" .json; done | tr '\n' ' ')"
  exit 1
fi

# Validated BEFORE anything is written, against the same resolver the probe uses.
# A profile that only fails at probe time reads as "this repo can test nothing",
# which is the failure mode this whole mechanism exists to remove.
if ! SDD_TDD_SEAMS="$src" bash "$(dirname "${BASH_SOURCE[0]}")/seam-profile.sh" >/dev/null; then
  echo "STOP HERE: '$src' is not a usable seam profile:"
  SDD_TDD_SEAMS="$src" bash "$(dirname "${BASH_SOURCE[0]}")/seam-profile.sh"
  exit 1
fi

target="$REPO_ROOT/$SEAMS_CONFIG_REL"
wrote_seams=0
if [ -f "$target" ] && [ "$force" -eq 0 ]; then
  echo "exists=$SEAMS_CONFIG_REL (kept — pass --force to replace it)"
else
  confirm_or_yes "write $SEAMS_CONFIG_REL from $(basename "$src")" || { echo "Cancelled."; exit 0; }
  mkdir -p "$(dirname "$target")"
  # `detect` is stripped: it's how /sdd-init FOUND this profile, and leaving it
  # in a repo's own profile invites someone to maintain a field nothing reads.
  jq 'del(.detect)' "$src" > "$target" || { echo "STOP HERE: couldn't write $target."; exit 1; }
  echo "wrote=$SEAMS_CONFIG_REL"
  wrote_seams=1
fi

if [ -n "$wiki_arg" ]; then
  cfg_rel="${CONFIG#"$REPO_ROOT"/}"
  if [ -f "$CONFIG" ]; then
    echo "exists=$cfg_rel (kept — the wiki connection is never rewritten)"
  else
    wiki_rel=""
    if [ "$wiki_arg" = "auto" ]; then
      [ -d "$REPO_ROOT/business-docs/wiki" ] && wiki_rel="business-docs/wiki"
    else
      wiki_rel="$wiki_arg"
      if [ ! -d "$REPO_ROOT/$wiki_rel" ]; then
        # Loud, because a configured-but-absent wikiRoot is a typo, and
        # wiki-config.sh will warn about it on every run from here on.
        echo "STOP HERE: --wiki '$wiki_rel' doesn't exist under the repo."
        exit 1
      fi
    fi
    if [ -z "$wiki_rel" ]; then
      echo "wiki=none (no business-docs/wiki — nothing to configure, the wiki step is simply absent)"
    else
      confirm_or_yes "write $cfg_rel pointing at $wiki_rel" || { echo "Cancelled."; exit 0; }
      mkdir -p "$(dirname "$CONFIG")"
      jq -n --arg w "$wiki_rel" --arg r "$(dirname "$wiki_rel")/rules" \
        '{wikiRoot: $w, rulesRoot: $r, wikiRequired: false}' > "$CONFIG" \
        || { echo "STOP HERE: couldn't write $CONFIG."; exit 1; }
      echo "wrote=$cfg_rel"
    fi
  fi
fi

echo
# The resolved profile, from the repo's point of view rather than the source
# file's — so a --force that didn't take, or a stale file, shows up here.
bash "$(dirname "${BASH_SOURCE[0]}")/seam-profile.sh"
echo
if [ "$wrote_seams" -eq 1 ]; then
  echo "Next: probe-test-seams.sh <the package a task would touch>. If a seam this"
  echo "repo really writes reports available=no, the marker is wrong, not the repo."
else
  echo "Next: probe-test-seams.sh <scope> to check the existing profile still"
  echo "describes this repo."
fi
