#!/bin/sh
# Ends a passed test: back to the default branch, merges the pull request (merge commit), removes
# the agent's worktree and local branch, moves the agent to [done] without color, and counts the
# merge in the release manager's name (🚀).
#   merge.sh <pr-number>
set -eu

pr=${1:?pull request number}
here=$(cd "$(dirname "$0")" && pwd)
root=$(git rev-parse --show-toplevel)
base=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
branch=$(gh pr view "$pr" --json headRefName --jq .headRefName)

git switch -q "$base"
gh pr merge "$pr" --merge
git pull -q --ff-only origin "$base" || true
if [ -d "$root/.claude/worktrees/$branch" ]; then
	git worktree remove "$root/.claude/worktrees/$branch"
fi
git branch -D "$branch" >/dev/null 2>&1 || true
sh "$here/set-state.sh" "$branch" "done"

# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
mkdir -p "$counters_dir"
echo $(($(merged_today) + 1)) >"$counters_dir/merged-$(date +%F)"
sh "$here/sync-names.sh" manager >/dev/null 2>&1 || true
