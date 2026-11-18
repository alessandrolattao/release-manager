#!/bin/sh
# Moves an agent to a state: renames its session "[state]<icons> <branch>".
#   set-state.sh <branch> <dev|review|test|fix|ask|ready|done>
# [ready] is a finished pull request the user tests and/or merges: only the user can go on, so entering it
# tells the planner, which keeps it in its 🙋 until the user tests or merges it. ready-sweep.sh moves the
# agent to [done] after the user's merge.
set -eu

branch=${1:?branch}
state=${2:?state}
case "$state" in
dev | review | test | fix | ask | ready | done) ;;
*)
	echo "unknown state '$state': dev, review, test, fix, ask, ready or done" >&2
	exit 2
	;;
esac
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"

# The agent is the background session whose name is "[<state>]<icons> <branch>".
id=$(claude agents --json 2>/dev/null | jq -r --arg b "$branch" \
	'[.[] | select((.name // "") | test("^\\[[a-z]+\\][^ ]* " + ($b | gsub("[.^$*+?()\\[\\]{}|\\\\]"; "\\\\\\(.)")) + "$"))][0].sessionId // empty')
[ -n "$id" ] || {
	echo "no agent session for branch $branch" >&2
	exit 1
}
# shellcheck source=skills/run/scripts/session-dir.sh
. "$here/session-dir.sh"
if [ "$state" = done ] && waiting_in_chat "$id"; then
	echo "the agent of $branch still waits for an answer in its chat: $(sed -n 4p "$sessions_dir/$id/asked")" >&2
	echo "answer it first (SendMessage), or ask the user: it is not done" >&2
	exit 1
fi
pr=""
if [ "$state" = ready ]; then
	pr=$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty')
	[ -n "$pr" ] || {
		echo "no open pull request for $branch: [ready] is a finished pull request" >&2
		exit 1
	}
fi
name=$(sh "$here/agent-name.sh" "$branch" "$state")
sh "$here/rename.sh" "$id" "$name"

if [ "$state" != ready ]; then
	ready_forget "$branch"
	exit 0
fi
# Entering [ready] once is one message, however many times the state is set.
record="$counters_dir/waiting/ready-$pr"
[ ! -f "$record" ] || exit 0
mkdir -p "$counters_dir/waiting"
sentence="PR #$pr ready, your turn"
printf '%s\n%s\n%s\n' "$(date +%s)" "$sentence" "$branch" >"$record"
printf '%s\n\nBranch %s: the user tests and/or merges it.\n' "$sentence" "$branch" |
	sh "$here/tell.sh" planner question --recorded >/dev/null 2>&1 || true
