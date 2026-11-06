#!/bin/sh
# Ends a passed test: back to the default branch, merges the pull request (merge commit), removes
# the agent's worktree and local branch, moves the agent to [done] without color, and counts the
# merge in the release manager's name (🚀). Refuses while the default branch's CI is red, except
# for the pull request that closes the bug opened for it. Then run main-ci.sh --wait.
#   merge.sh <pr-number>
set -eu

pr=${1:?pull request number}
here=$(cd "$(dirname "$0")" && pwd)
root=$(git rev-parse --show-toplevel)
base=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
branch=$(gh pr view "$pr" --json headRefName --jq .headRefName)

# A broken default branch takes no more merges, except the fix for it.
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
if [ -f "$counters_dir/main-red" ]; then
	bug=$(sed -n 2p "$counters_dir/main-red")
	closes=$(gh pr view "$pr" --json closingIssuesReferences --jq '[.closingIssuesReferences[].number] | map(tostring) | join(" ")' 2>/dev/null || true)
	case " $closes " in
	*" $bug "*) ;;
	*)
		echo "the CI of $base is red (issue #$bug): no merge until it is green, except the pull request that closes #$bug" >&2
		exit 1
		;;
	esac
fi

git switch -q "$base"
gh pr merge "$pr" --merge
git pull -q --ff-only origin "$base" || true
if [ -d "$root/.claude/worktrees/$branch" ]; then
	git worktree remove "$root/.claude/worktrees/$branch"
fi
git branch -D "$branch" >/dev/null 2>&1 || true
sh "$here/set-state.sh" "$branch" "done"

mkdir -p "$counters_dir"
echo $(($(merged_today) + 1)) >"$counters_dir/merged-$(date +%F)"
sh "$here/sync-names.sh" manager >/dev/null 2>&1 || true
