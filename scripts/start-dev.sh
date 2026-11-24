#!/bin/sh
# Starts the developer agent of one issue: the branch linked to the issue, a worktree of it, and a
# background session "dev #<n> · <repo> · <slug>" with the brief briefs/dev.md and the user's rules.
# The dispatcher runs it for the next workable issue; a tech lead runs it when the user asks for one now.
#   start-dev.sh <issue-number>    (from the main checkout)
set -eu

issue=${1:?issue number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# shellcheck source=scripts/launch.sh
. "$here/launch.sh"
base=$(base_branch)

for other in $(sessions_of dev "$issue"); do
	if alive "$other" && [ "$(jq -r .state "$sessions_dir/$other/status")" != done ]; then
		echo "issue $issue already has a developer: $(jq -r .name "$sessions_dir/$other/status")" >&2
		exit 1
	fi
done

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

brief=$(sed -e "s|{{ISSUE}}|$issue|g" -e "s|{{BRANCH}}|$branch|g" -e "s|{{REPO}}|$repo_full|g" \
	-e "s|{{WORKTREE}}|$worktree|g" -e "s|{{ROOT}}|$root|g" -e "s|{{BASE}}|$base|g" \
	-e "s|{{SCRIPTS}}|$here|g" -e "s|{{BRIEFS}}|$here/../briefs|g" "$here/../briefs/dev.md")
brief=$(printf '%s\n\n%s\n' "$brief" "$(sh "$here/rules.sh" show --context 2>/dev/null || true)")

cd "$worktree"
name=$(dev_name "$issue" "$branch")
id=$(launch "$name" "$brief")
sh "$here/role.sh" "$id" dev "$issue" "$branch" >/dev/null
sh "$here/project.sh" "$issue" "In Progress" >/dev/null 2>&1 || true
echo "started $name ($id)"
echo "branch   $branch"
echo "worktree $worktree"
