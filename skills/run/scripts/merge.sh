#!/bin/sh
# Ends a passed test: back to the default branch, merges the pull request (merge commit), removes
# the agent's worktree and local branch, and moves the agent to [done] without color.
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
