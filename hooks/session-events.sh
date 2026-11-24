#!/bin/sh
# The plugin's monitor (monitors/monitors.json): every line printed here wakes the session it runs in, only
# between its turns, so a turn is never interrupted.
#   - every team session: a GitHub comment written to it (the dispatcher drops it in the session's `wake`
#     file), or the main checkout freed for it;
#   - a tech lead: also messages other repositories left in its inbox (tell.sh). A tech lead whose last
#     message waits on the user's answer is not woken: the user is talking to it.
# Claude Code starts this in every session of the plugin: a session outside the team ends here within a
# minute, since a running monitor makes the session look busy in `claude agents`.
#   session-events.sh   (from the session's folder, as Claude Code runs it)
set -u

sid=${CLAUDE_CODE_SESSION_ID:-}
case "$sid" in
"" | *[!A-Za-z0-9-]*) exit 0 ;;
esac
scripts="$(cd "$(dirname "$0")/.." && pwd)/scripts"
# shellcheck source=scripts/session-dir.sh
. "$scripts/session-dir.sh"
folder="$sessions_dir/$sid"

# The role is recorded by the skill or the script that starts the session.
waited=0
until [ -s "$folder/role" ]; do
	[ "$waited" -lt 60 ] || exit 0
	sleep 2
	waited=$((waited + 2))
done
role=$(cat "$folder/role")
# How many lines of `wake` were delivered, beside it, so a restart of the machine does not deliver them again.
read_lines="$folder/wake-read"
box=""
if [ "$role" = tech-lead ]; then
	repo=$(git -C "$(cat "$folder/cwd")" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^.*github\.com[:/]##' | tr '/' '_')
	box="$team_data/inbox/$repo/new"
fi

# between_turns: the model has been stopped for a few seconds (hooks/sessions.tsx writes `idle` when a turn
# ends and empties it when one starts) and, for a tech lead, no question it asked in its own chat waits on
# the user (one asked on GitHub, asked_on, is answered there, so its answer wakes it).
between_turns() {
	since=$(cat "$folder/idle" 2>/dev/null)
	case "$since" in "" | *[!0-9]*) return 1 ;; esac
	[ $(($(date +%s) - since)) -ge 5 ] || return 1
	[ "$role" = tech-lead ] || return 0
	[ "$(jq -r 'if .state == "you" and .asked_on == null then "chat" else "" end' "$folder/status" 2>/dev/null)" != chat ]
}

told=""
while :; do
	sleep 3
	between_turns || continue
	line=""
	done_lines=$(cat "$read_lines" 2>/dev/null || echo 0)
	total=$(wc -l <"$folder/wake" 2>/dev/null | tr -d ' ' || echo 0)
	total=${total:-0}
	[ "$done_lines" -le "$total" ] 2>/dev/null || done_lines=0
	if [ "$total" -gt "$done_lines" ]; then
		new=$(sed -n "$((done_lines + 1)),${total}p" "$folder/wake" |
			awk -F '\t' '{ printf "%s%s: %s%s", (NR > 1 ? "; " : ""), $2, $3, ($4 != "" ? " (" $4 ")" : "") }')
		line="for you on GitHub: $new"
		echo "$total" >"$read_lines.tmp" && mv "$read_lines.tmp" "$read_lines"
	fi
	if [ -n "$box" ]; then
		fresh=$(find "$box" -type f 2>/dev/null | sort | grep -vxF "$told")
		if [ -n "$fresh" ]; then
			line="${line:+$line; }$(printf '%s\n' "$fresh" | wc -l | tr -d ' ') message(s) from other repositories: sh \"$scripts/inbox.sh\" read"
			told=$(find "$box" -type f 2>/dev/null | sort)
		fi
	fi
	[ -z "$line" ] || printf '%s\n' "$line"
done
