#!/bin/sh
# Colors the release manager by its state when its turn ends (Stop), without the model (a color can only
# change between turns), the first that holds:
#   orange  it needs the user: an issue waits on a question, an agent is stuck in [ask], the default
#           branch's CI is red;
#   yellow  work is under way: one of its agents is running, it is testing a pull request (the main
#           checkout is detached), the default branch's CI is running;
#   green   nothing to do.
# Only for a session whose name starts with "release manager"; every other session exits at once.
#   manager-color.sh   (hook payload on stdin)
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"

role_is "release manager" is-manager || exit 0

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")
# `--cwd` takes the repository (given the worktrees folder it lists nothing); the agents are the
# running sessions under .claude/worktrees.
agents=$(claude agents --json --cwd "$root" 2>/dev/null |
	jq -c --arg w "$root/.claude/worktrees/" '[.[] | select(.cwd | startswith($w)) | (.name // "")]' 2>/dev/null || echo '[]')
asking=$(printf '%s' "$agents" | jq '[.[] | select(startswith("[ask]"))] | length' 2>/dev/null || echo 0)
running=$(printf '%s' "$agents" | jq 'length' 2>/dev/null || echo 0)
questions=$(cd "$cwd" && gh issue list --label question --assignee @me --state open --limit 200 --json number --jq length 2>/dev/null || echo 0)
red_main="${XDG_STATE_HOME:-$HOME/.local/state}/release-manager/$(git -C "$cwd" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '/' '_')/main-red"

if [ "${asking:-0}" -gt 0 ] || [ "${questions:-0}" -gt 0 ] || [ -f "$red_main" ]; then
	want=orange
elif [ "${running:-0}" -gt 0 ] || ! git -C "$root" symbolic-ref -q HEAD >/dev/null 2>&1; then
	want=yellow
else
	base=$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
	ci=0
	if [ -n "$base" ]; then
		ci=$(cd "$root" && gh run list --branch "$base" --limit 10 --json status \
			--jq '[.[] | select(.status != "completed")] | length' 2>/dev/null || echo 0)
	fi
	if [ "${ci:-0}" -gt 0 ]; then want=yellow; else want=green; fi
fi

sh "$scripts/color.sh" "$sid" "$want"
