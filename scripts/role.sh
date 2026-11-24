#!/bin/sh
# Records what a session is in the team and gives it its name. The tech lead skill runs it when it starts;
# the scripts that start developers, QA and spikes run it for the session they start.
#   role.sh <session-id> tech-lead                (from the main checkout; one per repository)
#   role.sh <session-id> dev|qa <issue> [branch]  (from the session's folder)
#   role.sh <session-id> spike <topic>            (from the main checkout)
# From then on the hooks module keeps the session's heartbeat and color, the monitor wakes it when there
# is something for it, and hooks/revive.sh resumes a tech lead after the machine restarts.
set -eu

id=${1:?session id}
role=${2:?tech-lead, dev, qa or spike}
arg=${3:-}
branch=${4:-}
case "$id" in
"" | *[!A-Za-z0-9-]*)
	echo "invalid session id" >&2
	exit 2
	;;
esac
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"

# "checkout" is only for the session holding the main checkout's lock (checkout.sh); a session that merely
# runs in the main checkout's folder (a tech lead, a spike, a QA agent before it takes the lock) has none.
place=""
case "$(pwd)" in
"$root/.claude/worktrees/"*) place="worktree $(basename "$(pwd)" | cut -d- -f1)" ;;
esac

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
	;;
dev | qa)
	issue=${arg:?issue number}
	title=$(gh issue view "$issue" --json title --jq .title 2>/dev/null || true)
	# A developer starts on an issue its machine just took (in progress); a QA agent on a pull request (in review).
	if [ "$role" = dev ]; then stage="in progress" name=$(dev_name "$issue" "$title" "in progress"); else stage="in review" name=$(qa_name "$issue" "$title" "in review"); fi
	status_set "$id" --arg r "$role" --arg repo "$repo_full" --arg n "$name" --argjson i "$issue" --arg t "$title" \
		--arg p "$place" --arg b "$branch" --arg s "$stage" '.role = $r | .repo = $repo | .name = $n | .issue = $i | .title = $t | .place = $p | .branch = $b | .stage = $s'
	state_set "$id" working "starting"
	;;
spike)
	name=$(spike_name "${arg:?topic}")
	status_set "$id" --arg r spike --arg repo "$repo_full" --arg n "$name" --arg t "$arg" --arg p "$place" \
		'.role = $r | .repo = $repo | .name = $n | .topic = $t | .place = $p'
	state_set "$id" working "analyzing"
	;;
*)
	echo "usage: role.sh <session-id> tech-lead|dev|qa|spike ..." >&2
	exit 2
	;;
esac
want "$id" role "$role"
want "$id" cwd "$(pwd)"
want "$id" config "${CLAUDE_CONFIG_DIR:-}"
want "$id" name "$name"
echo "$name"
