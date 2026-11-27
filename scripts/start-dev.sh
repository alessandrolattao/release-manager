#!/bin/sh
# Starts the developer agent of one issue: the branch linked to the issue, a worktree of it, and a
# background session "<repo> · dev #<n> · <title>" with the brief briefs/dev.md, once this machine has taken the issue
# on GitHub (claim.sh).
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
# The branch is fetched from the repository's remote: with none, nothing is claimed or started.
remote=$(repo_remote) || exit 1

# One developer per issue: a session of it that is not done holds it, alive or not (a dead one is resumed
# by the dispatcher), and so does one being started right now.
for other in $(sessions_of dev "$issue"); do
	if [ "$(jq -r .state "$sessions_dir/$other/status")" != done ]; then
		echo "issue $issue already has a developer: $(jq -r .name "$sessions_dir/$other/status") ($other). If it is dead, resume it: claude --bg --resume $other" >&2
		exit 1
	fi
done
starting="$repo_dir/starting.$issue"
mkdir -p "$repo_dir"
if ! mkdir "$starting" 2>/dev/null; then
	[ -n "$(find "$starting" -maxdepth 0 -mmin +5 2>/dev/null)" ] || {
		echo "a developer of issue $issue is being started right now" >&2
		exit 1
	}
fi
trap 'rmdir "$starting" 2>/dev/null || true' EXIT INT TERM

# One machine per issue: this one takes it on GitHub first (30 seconds), and gives up when another one has
# it. Taking it sets the issue In progress.
sh "$here/claim.sh" take "$issue" || exit 1

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
git -C "$root" fetch -q "$remote" "$branch"
if [ ! -d "$worktree" ]; then
	git -C "$root" worktree add -q "$worktree" "$branch" 2>/dev/null ||
		git -C "$root" worktree add -q -b "$branch" "$worktree" "$remote/$branch"
fi

brief=$(sed -e "s|{{ISSUE}}|$issue|g" -e "s|{{BRANCH}}|$branch|g" -e "s|{{REPO}}|$repo_full|g" \
	-e "s|{{WORKTREE}}|$worktree|g" -e "s|{{ROOT}}|$root|g" -e "s|{{BASE}}|$base|g" \
	-e "s|{{SCRIPTS}}|$here|g" "$here/../briefs/dev.md")

cd "$worktree"
name=$(dev_name "$issue" "$(gh issue view "$issue" --json title --jq .title 2>/dev/null || true)" "in progress")
# Taken just before the launch: the developer reads the issue with all its comments after it, so none written
# before wakes it (role.sh, dispatch.sh).
started=$(date +%s)
id=$(launch "$name" "$brief")
sh "$here/role.sh" "$id" dev "$issue" "$branch" "$started" >/dev/null
echo "started $name ($id)"
echo "branch   $branch"
echo "worktree $worktree"
