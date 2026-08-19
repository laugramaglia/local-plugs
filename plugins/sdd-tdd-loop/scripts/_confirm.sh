#!/usr/bin/env bash
# Shared confirmation gate. SOURCE this, don't execute it.
#
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_confirm.sh"
#   confirm_or_yes "create tracks/foo/" || exit 0
#
# Interactively it's a plain `Confirm? [y/N]`: a non-`y` answer returns 1, and
# the caller prints its own "Cancelled." line and exits 0.
#
# The no-TTY branch is the important case, not the exception. These scripts are
# driven by an agent, and an agent's Bash has no TTY — so `read` can NEVER
# succeed there. Blocking would mean the skill can't run its own procedure and
# has to ask the human to paste shell commands, which is exactly the dead end
# this plugin removes. The human gate lives one level up, in the conversation:
# each SKILL.md says what to report before crossing a gate.
#
# SDD_TDD_ASSUME_YES=1 turns every gate into a logged auto-yes. Nothing in this
# plugin sets it — there is no poller here — so it exists for a caller driving
# the scripts from a script of their own.

confirm_or_yes() {
  local action="${1:-proceed}"

  if [ "${SDD_TDD_ASSUME_YES:-0}" = "1" ]; then
    echo "[auto-yes] $action (SDD_TDD_ASSUME_YES=1)"
    return 0
  fi

  if [ ! -t 0 ]; then
    echo "[no-tty] proceeding: $action"
    return 0
  fi

  local confirm
  read -r -p "Confirm? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    return 1
  fi
  return 0
}
