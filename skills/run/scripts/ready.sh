#!/bin/sh
# Marks an issue ready for development (label "ready for development", created when missing), or takes it back.
#   ready.sh <issue-number>           the issue enters the release manager's queue
#   ready.sh --remove <issue-number>  back to the backlog
set -eu

label="ready for development"
action=add
if [ "${1:-}" = --remove ]; then
	action=remove
	shift
fi
issue=${1:?issue number}
if [ "$action" = add ]; then
	# The label lets the release manager take the issue: never before its technical decisions are posted.
	decided=$(gh issue view "$issue" --json comments --jq '[.comments[].body | select(startswith("## Technical decisions"))] | length')
	[ "${decided:-0}" -gt 0 ] || {
		echo "issue $issue has no '## Technical decisions' comment yet: post the decisions first, then mark it ready" >&2
		exit 1
	}
	gh label list --limit 200 --json name --jq '.[].name' | grep -qxF "$label" ||
		gh label create "$label" --color 0E8A16 --description "Technical decisions taken: the release manager may build it" >/dev/null
	gh issue edit "$issue" --add-label "$label" >/dev/null
	echo "issue $issue: ready for development"
else
	gh issue edit "$issue" --remove-label "$label" >/dev/null
	echo "issue $issue: back to the backlog"
fi
# The planner's 🧠 counts the issues still to prepare.
sh "$(dirname "$0")/sync-names.sh" planner >/dev/null 2>&1 || true
