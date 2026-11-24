#!/bin/sh
# Records what a session is in the team and gives it its name. The tech lead skill runs it when it starts;
# the scripts that start developers, QA and spikes run it for the session they start.
#   role.sh <session-id> tech-lead [topic]        (from the main checkout)
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
	topic=$arg
	# Two tech leads alive on the same topic would share an address: the second gets a number.
	n=1
	while :; do
		taken=no
		for other in $(sessions_of tech-lead); do
			[ "$other" != "$id" ] || continue
			alive "$other" || continue
			[ "$(jq -r '.topic // ""' "$sessions_dir/$other/status")" != "$topic" ] || taken=yes
		done
		[ "$taken" = yes ] || break
		n=$((n + 1))
		topic="${arg:+$arg }$n"
	done
	name=$(tech_lead_name "$topic")
	status_set "$id" --arg r tech-lead --arg repo "$repo_full" --arg n "$name" --arg t "$topic" --arg p "$place" \
		'.role = $r | .repo = $repo | .name = $n | .topic = $t | .place = $p | del(.issue)'
	state_set "$id" working "con te"
	;;
dev | qa)
	issue=${arg:?issue number}
	title=$(gh issue view "$issue" --json title --jq .title 2>/dev/null || true)
	if [ "$role" = dev ]; then name=$(dev_name "$issue" "${branch:-$issue-$title}"); else name=$(qa_name "$issue"); fi
	status_set "$id" --arg r "$role" --arg repo "$repo_full" --arg n "$name" --argjson i "$issue" --arg t "$title" \
		--arg p "$place" --arg b "$branch" '.role = $r | .repo = $repo | .name = $n | .issue = $i | .title = $t | .place = $p | .branch = $b'
	state_set "$id" working "parte"
	;;
spike)
	name=$(spike_name "${arg:?topic}")
	status_set "$id" --arg r spike --arg repo "$repo_full" --arg n "$name" --arg t "$arg" --arg p "$place" \
		'.role = $r | .repo = $repo | .name = $n | .topic = $t | .place = $p'
	state_set "$id" working "analizza"
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
