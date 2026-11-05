#!/bin/sh
# Colors the release manager by its state, without the model: PreToolUse means it works (green);
# Stop means its turn ended, so it waits: on its agents (yellow) or on the user (red).
# Only for a background session whose name starts with "release manager"; every other session exits at once.
#   manager-color.sh working|idle   (hook payload on stdin)
set -eu

mode=${1:?working or idle}
# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"

role_is "release manager" is-manager || exit 0

if [ "$mode" = working ]; then
	want=green
else
	root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")
	busy=$(claude agents --json --cwd "$root/.claude/worktrees" 2>/dev/null |
		jq '[.[] | select((.name // "") | test("^\\[(dev|review|test|fix)\\]"))] | length' 2>/dev/null || echo 0)
	if [ "${busy:-0}" -gt 0 ]; then want=yellow; else want=red; fi
fi

# One color change at a time; a later one waits its turn so the last state always wins.
lock="$state_dir/$sid.lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
	waited=$((waited + 1))
	[ "$waited" -gt 300 ] && exit 0
	sleep 0.1
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

last="$state_dir/$sid.color"
[ "$(cat "$last" 2>/dev/null)" = "$want" ] && exit 0
sh "$scripts/color.sh" "$sid" "$want" >/dev/null 2>&1 && echo "$want" >"$last"
