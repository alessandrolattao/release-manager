# Sourced by every script and hook: where the team keeps its state. One place serves every Claude Code
# account, since session ids are unique across them.
#   $team_state/sessions/<id>/   one folder per session: role, cwd, config, alive, idle, status, color, name,
#                                asked, blocked, wake, commented (what the hooks module and the scripts read
#                                and write)
#   $team_state/repos/<key>/     one folder per repository: the checkout lock, the dispatcher's lock and
#                                cursor, QA and review records, the board
#   $team_data/                  what is kept: the tech leads' notes, spike reports, other repositories' messages
# The status of a session is one JSON object, written by the scripts and the hooks, never by the model:
#   {"role", "repo", "name", "issue", "title", "topic", "place", "state", "detail", "since", "branch",
#    "busy_until", "tested_head", "asked_on", "waits_on"}
# asked_on: the issue where the session asked the user on GitHub (comment.sh); absent when it asked in its
# own chat (hooks/asks.sh), where the user answers it directly.
# waits_on: whom the session waits on since it wrote to them on GitHub (comment.sh, or dispatch.sh posting a
# question it left in its chat): the address ("tech lead", "dev #42", "qa #42"), or "the user" for a tech
# lead's question to the user. A comment from them ends the wait (hooks/sessions.tsx); every state_set
# removes it, and a new wait records its own.
# state: working (cyan), others (purple: waits on another agent or the checkout), you (yellow: waits on
# the user), stuck (red: dead, failing or silent), idle (green: a tech lead waiting for work), done (no
# color, then the session goes away).
# shellcheck shell=sh disable=SC2034 # the variables are used by the files that source this one

team_state="${XDG_STATE_HOME:-$HOME/.local/state}/team"
team_data="${XDG_DATA_HOME:-$HOME/.local/share}/team"
sessions_dir="$team_state/sessions"

# want <session-id> <file> <value>: writes one file of a session's folder in one step, so the hooks
# module never reads half of it.
want() {
	mkdir -p "$sessions_dir/$1"
	printf '%s\n' "$3" >"$sessions_dir/$1/$2.tmp"
	mv "$sessions_dir/$1/$2.tmp" "$sessions_dir/$1/$2"
}

# status_set <session-id> <jq filter> [jq args...]: changes a session's status in one step.
status_set() {
	id=$1
	shift
	file="$sessions_dir/$id/status"
	mkdir -p "$sessions_dir/$id"
	tmp="$file.$$.tmp"
	{ cat "$file" 2>/dev/null || echo '{}'; } | jq -c "$@" >"$tmp" 2>/dev/null && mv "$tmp" "$file" || rm -f "$tmp"
}

# state_set <session-id> <state> <detail>: the session's state and what it means in a few words; `since`
# moves only when one of the two changes. Whom it waited on goes: a new wait records its own (comment.sh).
state_set() {
	status_set "$1" --arg s "$2" --arg d "$3" --argjson now "$(date +%s)" \
		'(if .state == $s and .detail == $d then . else .since = $now end) | .state = $s | .detail = $d | del(.waits_on)'
}

# commented_on <session-id> <issue> [to]: the session wrote on that issue's thread (an issue and the pull
# requests that close it), to that address (empty for a note): one line of `commented`, <time> <issue> <to>.
# A wake for a comment it answered since is dropped (hooks/sessions.tsx). Nothing outside a team session.
commented_on() {
	[ -n "$1" ] && [ -d "$sessions_dir/$1" ] || return 0
	printf '%s\t%s\t%s\n' "$(date +%s)" "$2" "${3:-}" >>"$sessions_dir/$1/commented"
}

# waiting_in_chat <session-id>: true when an agent's last turn ended asking something in its own chat
# (hooks/asks.sh) and no turn has started since (hooks/sessions.tsx empties `idle` when one does).
waiting_in_chat() { [ -f "$sessions_dir/$1/asked" ] && [ -s "$sessions_dir/$1/idle" ]; }
