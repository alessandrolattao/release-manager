#!/bin/sh
# Ends a passed test: back to the default branch, merges the pull request (merge commit), removes
# the agent's session, its worktree and its local branch, and counts the merge in the release
# manager's name (🚀). Refuses while the default branch's CI is red, except
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

# The agent's work is over: its session goes with its worktree, since a session whose folder is gone
# can no longer be opened. `claude rm` leaves a worktree it did not create, so git removes that one.
agent=$(claude agents --json --all 2>/dev/null | jq -r --arg b "$branch" \
	'[.[] | select((.name // "") | test("^\\[[a-z]+\\][^ ]* " + ($b | gsub("[.^$*+?()\\[\\]{}|\\\\]"; "\\\\\\(.)")) + "$")) | .sessionId][0] // empty')
if [ -n "$agent" ]; then
	claude rm "${agent%%-*}" >/dev/null 2>&1 || echo "could not remove the agent session ${agent%%-*}: remove it from claude agents" >&2
	# shellcheck source=skills/run/scripts/session-dir.sh
	. "$here/session-dir.sh"
	rm -rf "${sessions_dir:?}/$agent"
fi
if [ -d "$root/.claude/worktrees/$branch" ]; then
	git worktree remove "$root/.claude/worktrees/$branch"
fi
git branch -D "$branch" >/dev/null 2>&1 || true
echo "agent of $branch removed: session, worktree and local branch"

mkdir -p "$counters_dir"
echo $(($(merged_today) + 1)) >"$counters_dir/merged-$(date +%F)"
sh "$here/sync-names.sh" manager >/dev/null 2>&1 || true
