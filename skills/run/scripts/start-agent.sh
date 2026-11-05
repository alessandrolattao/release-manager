#!/bin/sh
# Starts the developer agent of one issue: the branch linked to the issue, a worktree of it, and a
# background session named after the branch, on the same Claude Code account as this session.
#   start-agent.sh <issue-number> <release-manager-session-name>
# Run it from the main checkout. Prints the branch, the worktree and the agent id.
set -eu

issue=${1:?issue number}
manager=${2:?name of the release-manager session}
here=$(cd "$(dirname "$0")" && pwd)
root=$(git rev-parse --show-toplevel)
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
base=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)

# The linked branch: reuse it when the issue already has one, otherwise let GitHub create <n>-<slug>.
branch=$(gh issue develop "$issue" --list 2>/dev/null | awk 'NR==1 {print $1}')
if [ -z "$branch" ]; then
	gh issue develop "$issue" --base "$base" >/dev/null
	branch=$(gh issue develop "$issue" --list | awk 'NR==1 {print $1}')
fi
[ -n "$branch" ] || {
	echo "no linked branch for issue $issue" >&2
	exit 1
}

worktree="$root/.claude/worktrees/$branch"
git -C "$root" fetch -q origin "$branch"
if [ ! -d "$worktree" ]; then
	git -C "$root" worktree add -q "$worktree" "$branch" 2>/dev/null ||
		git -C "$root" worktree add -q -b "$branch" "$worktree" "origin/$branch"
fi

brief=$(sed -e "s|{{ISSUE}}|$issue|g" -e "s|{{BRANCH}}|$branch|g" -e "s|{{REPO}}|$repo|g" \
	-e "s|{{MANAGER}}|$manager|g" -e "s|{{WORKTREE}}|$worktree|g" "$here/../agent-brief.md")

# Same account as this session: keep CLAUDE_CONFIG_DIR, drop every other CLAUDE* variable so the
# agent and its supervisor do not inherit this session's identity.
unset_args=$(env | grep -o -E '^CLAUDE[A-Z_]*' | grep -v '^CLAUDE_CONFIG_DIR$' | sed 's/^/-u /' | tr '\n' ' ')
cd "$worktree"
# shellcheck disable=SC2086 # unset_args is a list of -u flags
out=$(env $unset_args claude --bg --name "$branch" "$brief" 2>&1)

echo "branch   $branch"
echo "worktree $worktree"
echo "$out" | tail -5
