#!/bin/sh
# The plugin's monitor (monitors/monitors.json): every line printed here wakes the session it runs in.
# It wakes the release manager and the planner when there is something for them, and only between their
# turns, so a turn is never interrupted and the next piece of work starts as soon as the last one ends.
#   - both: new messages in their inbox;
#   - the release manager: an agent changed state, ended or waits for an answer in its own chat, a question
#     was answered, an issue became workable, the default branch's CI is green again.
# The planner is not woken while its last message waits on the user's answer. Each thing is said once.
# Claude Code starts this in every session of the plugin: any other session ends here within a minute,
# since a running monitor makes the session look busy in `claude agents`.
#   session-events.sh   (from the session's folder, as Claude Code runs it)
set -u

sid=${CLAUDE_CODE_SESSION_ID:-}
case "$sid" in
"" | *[!A-Za-z0-9-]*) exit 0 ;;
esac
scripts="$(cd "$(dirname "$0")/.." && pwd)/skills/run/scripts"
# shellcheck source=skills/run/scripts/session-dir.sh
. "$scripts/session-dir.sh"
folder="$sessions_dir/$sid"

# The role is recorded by the skill the session starts with.
waited=0
until [ -s "$folder/role" ]; do
	[ "$waited" -lt 60 ] || exit 0
	sleep 2
	waited=$((waited + 2))
done
role=$(cat "$folder/role")
cd "$(cat "$folder/cwd")" || exit 0

# shellcheck source=skills/run/scripts/roles.sh
. "$scripts/roles.sh"
until [ -n "$repo_full" ]; do
	sleep 30
	# shellcheck source=skills/run/scripts/roles.sh
	. "$scripts/roles.sh"
done
top=$(git rev-parse --show-toplevel)
state_dir="${TMPDIR:-/tmp}/release-manager-$(id -u)"
box="$(inbox_dir "$role")/new"
red_file="$counters_dir/main-red"

# between_turns: true when the model has been stopped for a few seconds (hooks/sessions.tsx writes `idle`
# when a turn ends and empties it when one starts) and, in the planner, no question waits on the user.
between_turns() {
	since=$(cat "$folder/idle" 2>/dev/null)
	case "$since" in "" | *[!0-9]*) return 1 ;; esac
	[ $(($(date +%s) - since)) -ge 5 ] || return 1
	[ "$role" = planner ] || return 0
	asked_at=$(sed -n 1p "$state_dir/$sid.asked" 2>/dev/null)
	case "$asked_at" in "" | *[!0-9]*) return 0 ;; esac
	[ "$(cat "$state_dir/$sid.last-prompt" 2>/dev/null || echo 0)" -ge "$asked_at" ]
}

# agents: this repository's developer agents and their state, nothing when the list cannot be read.
# Names are left out: the release manager's own scripts rename the agents.
agents() {
	claude agents --json --cwd "$top" 2>/dev/null |
		jq -c --arg w "$top/.claude/worktrees/" '[.[] | select(.cwd | startswith($w)) | {id, name, state}]' 2>/dev/null
}

# changes <before> <now>: the agents that were there and changed state or ended, comma separated.
changes() {
	jq -n -r --argjson a "$1" --argjson b "$2" '
		[$a[] | . as $old | ($b | map(select(.id == $old.id))[0]) as $new
			| if $new == null then "\($old.name) ended"
			elif $new.state != $old.state then "\($new.name) is \($new.state)"
			else empty end] | join(", ")' 2>/dev/null
}

# waiting_agents: the agents whose turn ended asking something 5 minutes ago, with nobody answering since
# (the user may be talking to the agent right then), one per line and once per question.
waiting_agents() {
	claude agents --json --cwd "$top" 2>/dev/null |
		jq -r --arg w "$top/.claude/worktrees/" '.[] | select(.cwd | startswith($w)) | .sessionId' 2>/dev/null |
		while read -r agent; do
			record="$sessions_dir/$agent/asked"
			waiting_in_chat "$agent" || continue
			[ ! -f "$record.told" ] || continue
			at=$(sed -n 1p "$record")
			case "$at" in "" | *[!0-9]*) continue ;; esac
			[ $(($(date +%s) - at)) -ge 300 ] || continue
			touch "$record.told"
			printf '#%s: %s\n' "$(sed -n 3p "$record")" "$(sed -n 4p "$record")"
		done
}

# workable: the numbers of the issues that can be started, one per line.
workable() { sh "$scripts/queue.sh" 2>/dev/null | jq -r 'select(.workable) | "#\(.number)"' 2>/dev/null; }

# look_github: what only GitHub can tell. Skipped when GitHub cannot be read, so an outage says nothing.
notes=""
note() { notes="${notes:+$notes; }$1"; }
look_github() {
	gh api user --jq .login >/dev/null 2>&1 || return 0
	sh "$scripts/closed-sweep.sh" >/dev/null 2>&1
	sh "$scripts/ready-sweep.sh" >/dev/null 2>&1
	open_now=$(questions_open)
	[ "$open_now" -ge "$questions" ] || note "a question was answered"
	questions=$open_now
	list=$(workable)
	if [ -n "$list" ]; then
		fresh_issues=$(printf '%s\n' "$list" | grep -vxF "$known" | tr '\n' ' ')
		[ -z "$fresh_issues" ] || note "workable issues: ${fresh_issues% }"
		known=$list
	fi
	if [ -f "$red_file" ] && sh "$scripts/main-ci.sh" 2>/dev/null | grep -q '^GREEN'; then
		note "the default branch's CI is green again"
	fi
}

told=""
if [ "$role" = manager ]; then
	seen=$(agents)
	announced=$seen
	questions=$(questions_open)
	known=$(workable)
fi

# say: everything that waits, in one line, so it wakes the session once.
say() {
	line=""
	fresh=$(find "$box" -type f 2>/dev/null | sort | grep -vxF "$told")
	if [ -n "$fresh" ]; then
		line="$(printf '%s\n' "$fresh" | wc -l | tr -d ' ') new message(s) in your inbox, read them now: sh \"$scripts/inbox.sh\" read $role"
		told=$(find "$box" -type f 2>/dev/null | sort)
	fi
	if [ "$role" = manager ]; then
		if [ -n "$seen" ] && [ -n "$announced" ]; then
			moved=$(changes "$announced" "$seen")
			[ -z "$moved" ] || note "agents: $moved"
		fi
		[ -z "$seen" ] || announced=$seen
		if [ -n "$notes" ]; then
			line="${line:+$line; }$notes"
			notes=""
		fi
	fi
	[ -z "$line" ] || printf '%s\n' "$line"
}

tick=0
while :; do
	sleep 3
	tick=$((tick + 1))
	if [ "$role" = manager ]; then
		if [ $((tick % 10)) -eq 0 ]; then
			now=$(agents)
			[ -z "$now" ] || seen=$now
			asking=$(waiting_agents | tr '\n' ';')
			[ -z "$asking" ] || note "agents waiting for an answer in their own chat, read them with claude logs and answer with SendMessage from what is written, otherwise ask the user: ${asking%;}"
		fi
		[ $((tick % 40)) -ne 0 ] || look_github
	fi
	if between_turns; then
		say
	fi
done
