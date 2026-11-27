#!/bin/sh
# Records what a session is in the team and gives it its name. The tech lead skill runs it when it starts;
# the scripts that start developers, reviewers, QA and spikes run it for the session they start.
#   role.sh <session-id> tech-lead                                 (from the main checkout; one per repository)
#                    where the user can only read the repository, a line before the name says so (read_only, repo.sh)
#   role.sh <session-id> dev|review|qa <issue> [branch] [started]  (from the session's folder)
#   role.sh <session-id> spike <topic>                      (from the main checkout)
# started: when the script that started a developer, a reviewer or a QA agent launched it (epoch seconds), recorded once
# and never overwritten, so a resume keeps it: the agent read the issue with all its comments after it, so the
# dispatcher wakes it for none written before (dispatch.sh).
# From then on the hooks module keeps the session's heartbeat and color, and wakes it between turns when there
# is something for it, and hooks/revive.sh resumes a tech lead after the machine restarts.
set -eu

id=${1:?session id}
role=${2:?tech-lead, dev, review, qa or spike}
arg=${3:-}
branch=${4:-}
started=${5:-}
case "$id" in
"" | *[!A-Za-z0-9-]*)
	echo "invalid session id" >&2
	exit 2
	;;
esac
case "$started" in
*[!0-9]*)
	echo "invalid start time" >&2
	exit 2
	;;
esac
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"

# "checkout" is only for the session holding the main checkout's lock (checkout.sh); a session that merely
# runs in the main checkout's folder (a tech lead, a spike, a reviewer, a QA agent before it takes the lock) has none.
place=""
! is_worktree "$(pwd)" || place="worktree $(basename "$(pwd)" | cut -d- -f1)"

case "$role" in
tech-lead)
	# One tech lead per repository: the user talks to one, and every question about an issue goes to it.
	for other in $(sessions_of tech-lead); do
		[ "$other" != "$id" ] || continue
		if alive "$other"; then
			echo "this repository already has a tech lead on this machine: $(jq -r .name "$sessions_dir/$other/status") ($other)."
			echo "Tell the user in one line, and stop here."
			exit 0
		fi
	done
	name=$(tech_lead_name)
	status_set "$id" --arg r tech-lead --arg repo "$repo_full" --arg n "$name" --arg p "$place" \
		'.role = $r | .repo = $repo | .name = $n | .place = $p | del(.issue) | del(.topic)'
	state_set "$id" working "with you"
	# Where the user cannot write, nothing can be labelled, claimed or merged: the tech lead tells the user.
	read_only
	;;
dev | review | qa)
	issue=${arg:?issue number}
	title=$(gh issue view "$issue" --json title --jq .title 2>/dev/null || true)
	# A developer starts on an issue its machine just took, a reviewer and a QA agent on its developer's branch
	# before the pull request opens: the issue is in progress for all of them.
	stage="in progress"
	case "$role" in
	dev) name=$(dev_name "$issue" "$title" "$stage") ;;
	review) name=$(review_name "$issue" "$title" "$stage") ;;
	*) name=$(qa_name "$issue" "$title" "$stage") ;;
	esac
	status_set "$id" --arg r "$role" --arg repo "$repo_full" --arg n "$name" --argjson i "$issue" --arg t "$title" \
		--arg p "$place" --arg b "$branch" --arg s "$stage" --arg st "$started" \
		'.role = $r | .repo = $repo | .name = $n | .issue = $i | .title = $t | .place = $p | .branch = $b | .stage = $s
		| if $st == "" then . else .started //= ($st | tonumber) end'
	state_set "$id" working "starting"
	;;
spike)
	name=$(spike_name "${arg:?topic}")
	status_set "$id" --arg r spike --arg repo "$repo_full" --arg n "$name" --arg t "$arg" --arg p "$place" \
		'.role = $r | .repo = $repo | .name = $n | .topic = $t | .place = $p'
	state_set "$id" working "analyzing"
	;;
*)
	echo "usage: role.sh <session-id> tech-lead|dev|review|qa|spike ..." >&2
	exit 2
	;;
esac
want "$id" role "$role"
want "$id" cwd "$(pwd)"
want "$id" config "${CLAUDE_CONFIG_DIR:-}"
want "$id" name "$name"
echo "$name"
