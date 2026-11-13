#!/bin/sh
# Colors the release manager by its state when its turn ends (Stop), without the model: orange when it
# needs the user (an issue waits on a question, an agent is stuck in [ask], the default branch's CI is
# red), green otherwise (all is well: agents at work, CI running, or nothing to do).
# Only for a session whose name starts with "release manager"; every other session exits at once.
#   manager-color.sh   (hook payload on stdin)
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"

role_is "release manager" is-manager || exit 0

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")
# `--cwd` takes the repository (given the worktrees folder it lists nothing); the agents are the
# sessions under .claude/worktrees.
asking=$(claude agents --json --cwd "$root" 2>/dev/null |
	jq --arg w "$root/.claude/worktrees/" \
		'[.[] | select((.cwd | startswith($w)) and ((.name // "") | startswith("[ask]")))] | length' 2>/dev/null || echo 0)
questions=$(cd "$cwd" && gh issue list --label question --assignee @me --state open --limit 200 --json number --jq length 2>/dev/null || echo 0)
red_main="${XDG_STATE_HOME:-$HOME/.local/state}/release-manager/$(git -C "$cwd" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '/' '_')/main-red"
if [ "${asking:-0}" -gt 0 ] || [ "${questions:-0}" -gt 0 ] || [ -f "$red_main" ]; then want=orange; else want=green; fi

sh "$scripts/color.sh" "$sid" "$want"
