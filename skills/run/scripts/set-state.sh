#!/bin/sh
# Moves an agent to a state: renames its session "[state]<icons> <branch>" and, for done, takes its color away.
#   set-state.sh <branch> <dev|review|test|fix|ask|done>
set -eu

branch=${1:?branch}
state=${2:?state}
case "$state" in
dev | review | test | fix | ask | done) ;;
*)
	echo "unknown state '$state': dev, review, test, fix, ask or done" >&2
	exit 2
	;;
esac
here=$(cd "$(dirname "$0")" && pwd)

# The agent is the background session whose name is "[<state>]<icons> <branch>".
id=$(claude agents --json 2>/dev/null | jq -r --arg b "$branch" \
	'[.[] | select((.name // "") | test("^\\[[a-z]+\\][^ ]* " + ($b | gsub("[.^$*+?()\\[\\]{}|\\\\]"; "\\\\\\(.)")) + "$"))][0].sessionId // empty')
[ -n "$id" ] || {
	echo "no agent session for branch $branch" >&2
	exit 1
}
name=$(sh "$here/agent-name.sh" "$branch" "$state")
sh "$here/rename.sh" "$id" "$name"
if [ "$state" = "done" ]; then
	sh "$here/color.sh" "$id" default
fi
