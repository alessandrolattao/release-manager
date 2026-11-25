#!/bin/sh
# QA for a delicate task: an issue with the label `qa` is tested by a separate agent on its developer's
# branch, in the main checkout, before the pull request is opened. The records are keyed by the issue, with
# the head they are about.
#   qa.sh request <issue>     the developer, once its branch is pushed: you wait (purple) and the plugin starts
#                             a QA agent on your branch, which writes its outcome on the issue
#   qa.sh pass <issue> | fail <issue>   the QA agent: records the outcome for the head it tested, with its time
#                             (UTC)
#   qa.sh needed <issue>      prints yes when the issue carries the label qa
# merge.sh refuses a pull request of a `qa` issue that has no pass for its head, or a pass recorded before the
# issue's latest `## Technical decisions`.
set -eu

action=${1:?request, pass, fail or needed}
issue=${2:?issue number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
me=${CLAUDE_CODE_SESSION_ID:-}
record="$repo_dir/qa/$issue"
mkdir -p "$repo_dir/qa"
# pushed <branch>: the head of the branch on origin, what the QA agent tests; empty when it is not pushed.
pushed() { git ls-remote origin "refs/heads/$1" 2>/dev/null | cut -f1; }

case "$action" in
needed)
	gh issue view "$issue" --json labels --jq 'if any(.labels[]; .name == "qa") then "yes" else "no" end'
	;;
request)
	# The developer's branch: its session's, else the one checked out here.
	branch=$(jq -r '.branch // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
	[ -n "$branch" ] || branch=$(git rev-parse --abbrev-ref HEAD)
	head=$(pushed "$branch")
	[ -n "$head" ] || {
		echo "$branch is not on origin: push it, then ask for QA" >&2
		exit 1
	}
	printf 'requested\t%s\t%s\t%s\t%s\n' "$head" "$issue" "$me" "$branch" >"$record"
	[ -z "$me" ] || state_set "$me" others "waits for QA on #$issue"
	echo "QA requested for issue #$issue on $branch at ${head%"${head#???????}"}: the plugin starts a QA agent"
	;;
pass | fail)
	# The head the QA agent tested in the main checkout (checkout.sh take records it); a push made while it
	# tested is not passed with it. Without one, the branch's pushed head: the session's branch, else the
	# one the request names.
	head=$(jq -r '.tested_head // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
	if [ -z "$head" ]; then
		branch=$(jq -r '.branch // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
		[ -n "$branch" ] || branch=$(cut -f5 "$record" 2>/dev/null || true)
		[ -z "$branch" ] || head=$(pushed "$branch")
	fi
	[ -n "$head" ] || {
		echo "no head to record: take the checkout (checkout.sh take) and test there" >&2
		exit 1
	}
	printf '%s\t%s\t%s\n' "$action" "$head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$record"
	echo "QA $action recorded for issue #$issue at ${head%"${head#???????}"}"
	;;
*)
	echo "usage: qa.sh request|pass|fail|needed <issue>" >&2
	exit 2
	;;
esac
