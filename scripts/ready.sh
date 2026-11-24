#!/bin/sh
# Marks an issue ready for development (label "ready for development", created when missing), or takes it back.
#   ready.sh <issue-number>           the issue enters the queue: the dispatcher starts a developer on it
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
	# The label lets a developer take the issue: never before its technical decisions are posted.
	decided=$(gh issue view "$issue" --json comments --jq '[.comments[].body | select(startswith("## Technical decisions"))] | length')
	[ "${decided:-0}" -gt 0 ] || {
		echo "issue $issue has no '## Technical decisions' comment yet: post the decisions first, then mark it ready" >&2
		exit 1
	}
	gh label list --limit 200 --json name --jq '.[].name' | grep -qxF "$label" ||
		gh label create "$label" --color 0E8A16 --description "Technical decisions taken: a developer may build it" >/dev/null
	gh issue edit "$issue" --add-label "$label" >/dev/null
	echo "issue $issue: ready for development"
	# The tech lead who makes it ready follows it: its developer's questions reach that tech lead.
	if [ "$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/team/sessions/${CLAUDE_CODE_SESSION_ID:-none}/role" 2>/dev/null)" = tech-lead ]; then
		sh "$(dirname "$0")/follow.sh" "$issue" >/dev/null 2>&1 || true
	fi
else
	gh issue edit "$issue" --remove-label "$label" >/dev/null
	echo "issue $issue: back to the backlog"
fi
