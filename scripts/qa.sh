#!/bin/sh
# QA for a delicate task: an issue with the label `qa` is tested by a separate agent on its developer's
# branch, in the main checkout, last of all: once the code review passed, before the pull request is opened.
# The records are keyed by the issue, with the head they are about.
#   qa.sh request <issue>     the developer, once its branch is pushed and the code review passed on its head
#                             (review.sh): you wait (purple) and the plugin starts a QA agent on your branch,
#                             which writes its outcome on the issue. The QA agent of an earlier round, still
#                             there after a fail, is woken instead with a comment, and goes on where it stopped.
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
# pushed <branch>: the head of the branch on the repository's remote ($remote, repo_remote), what the QA agent
# tests; empty when it is not pushed.
pushed() { git ls-remote "$remote" "refs/heads/$1" 2>/dev/null | cut -f1; }

case "$action" in
needed)
	gh issue view "$issue" --json labels --jq 'if any(.labels[]; .name == "qa") then "yes" else "no" end'
	;;
request)
	remote=$(repo_remote) || exit 1
	# The developer's branch: its session's, else the one checked out here.
	branch=$(jq -r '.branch // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
	[ -n "$branch" ] || branch=$(git rev-parse --abbrev-ref HEAD)
	head=$(pushed "$branch")
	[ -n "$head" ] || {
		echo "$branch is not on $remote: push it, then ask for QA" >&2
		exit 1
	}
	short=${head%"${head#???????}"}
	# QA comes at the end: on a head the code review passed.
	[ "$(cut -f1 "$repo_dir/review/$issue" 2>/dev/null || true)" = "$head" ] || {
		echo "the code review has not passed $branch at $short: review.sh request $issue, then QA once it passed" >&2
		exit 1
	}
	# The QA agent of an earlier round, still there (it waits after a fail): a comment wakes it, and it tests
	# the new head. A new one only when none is left.
	tester=""
	for other in $(sessions_of qa "$issue"); do
		[ "$(jq -r .state "$sessions_dir/$other/status")" = done ] || tester=$other
	done
	if [ -n "$tester" ]; then
		# Taken by that agent: the dispatcher starts no other one.
		printf 'testing\t%s\t%s\t%s\t%s\n' "$head" "$issue" "$me" "$branch" >"$record"
		# The comment sets your wait on it, until its outcome.
		printf 'QA again on `%s` at %s, where the code review passed. Go on from where you stopped: first what failed, then the criteria you had not reached yet; take the main checkout again (checkout.sh take).\n' "$branch" "$short" |
			sh "$here/comment.sh" "$issue" qa >/dev/null
		echo "QA requested for issue #$issue on $branch at $short: its QA agent ($(address_of "$tester")) is woken to go on"
	else
		printf 'requested\t%s\t%s\t%s\t%s\n' "$head" "$issue" "$me" "$branch" >"$record"
		[ -z "$me" ] || state_set "$me" others "waits for QA on #$issue"
		echo "QA requested for issue #$issue on $branch at $short: the plugin starts a QA agent"
	fi
	;;
pass | fail)
	# The head the QA agent tested in the main checkout (checkout.sh take records it); a push made while it
	# tested is not passed with it. Without one, the branch's pushed head: the session's branch, else the
	# one the request names.
	head=$(jq -r '.tested_head // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
	if [ -z "$head" ]; then
		branch=$(jq -r '.branch // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
		[ -n "$branch" ] || branch=$(cut -f5 "$record" 2>/dev/null || true)
		if [ -n "$branch" ]; then
			remote=$(repo_remote) || exit 1
			head=$(pushed "$branch")
		fi
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
