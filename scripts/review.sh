#!/bin/sh
# The code review of a change: a reviewer, a session of its own (briefs/reviewer.md), reads the code of the
# developer's pushed branch against the issue and the repository's patterns and standards, before the pull
# request is opened. The records are keyed by the issue, with the head they are about:
# "requested <head> <issue> <session> <branch>" once asked, "reviewing ..." once a reviewer took it
# (start-review.sh), then "<head> <time (UTC)> <summary>" once it passed.
#   review.sh request <issue>     the developer, once its branch is pushed: you wait (purple) and the plugin
#                                 starts a reviewer on the pushed head, which writes its outcome on the issue
#   review.sh pass <issue> "<one line: what the reviewer checked>"
#                                 the reviewer: records the pass for the head it read
# merge.sh refuses a pull request whose head has no pass, or a pass recorded before the issue's latest
# `## Technical decisions`; qa.sh refuses QA on a pushed head with no pass.
set -eu

action=${1:?request or pass}
issue=${2:?issue number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
me=${CLAUDE_CODE_SESSION_ID:-}
record="$repo_dir/review/$issue"
mkdir -p "$repo_dir/review"
# pushed <branch>: the head of the branch on origin, what the reviewer reads; empty when it is not pushed.
pushed() { git ls-remote origin "refs/heads/$1" 2>/dev/null | cut -f1; }

case "$action" in
request)
	# The developer's branch: its session's, else the one checked out here.
	branch=$(jq -r '.branch // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
	[ -n "$branch" ] || branch=$(git rev-parse --abbrev-ref HEAD)
	head=$(pushed "$branch")
	[ -n "$head" ] || {
		echo "$branch is not on origin: push it, then ask for the code review" >&2
		exit 1
	}
	# One round at a time: a reviewer at work would record its pass over this request.
	for other in $(sessions_of review "$issue"); do
		if alive "$other" && [ "$(jq -r .state "$sessions_dir/$other/status")" != done ]; then
			echo "a code review of issue #$issue is at work: wait for its outcome on the issue" >&2
			exit 1
		fi
	done
	printf 'requested\t%s\t%s\t%s\t%s\n' "$head" "$issue" "$me" "$branch" >"$record"
	[ -z "$me" ] || state_set "$me" others "waits for the code review on #$issue"
	echo "code review requested for issue #$issue on $branch at ${head%"${head#???????}"}: the plugin starts a reviewer"
	;;
pass)
	summary=${3:?one line: what the reviewer checked}
	# The head the reviewer read: the one its round started on (start-review.sh records it in its status),
	# else the one the request names.
	head=$(jq -r '.head // empty' "$sessions_dir/$me/status" 2>/dev/null || true)
	if [ -z "$head" ]; then
		case "$(cut -f1 "$record" 2>/dev/null || true)" in
		requested | reviewing) head=$(cut -f2 "$record") ;;
		esac
	fi
	[ -n "$head" ] || {
		echo "no head to record: no code review of issue #$issue was asked for (review.sh request $issue)" >&2
		exit 1
	}
	printf '%s\t%s\t%s\n' "$head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$summary" >"$record"
	echo "code review passed for issue #$issue at ${head%"${head#???????}"}"
	;;
*)
	echo "usage: review.sh request <issue> | review.sh pass <issue> \"<what the reviewer checked>\"" >&2
	exit 2
	;;
esac
