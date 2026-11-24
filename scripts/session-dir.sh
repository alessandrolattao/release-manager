# Sourced by every script and hook: where the team keeps its state. One place serves every Claude Code
# account, since session ids are unique across them.
#   $team_state/sessions/<id>/   one folder per session: role, cwd, config, alive, idle, status, color, name,
#                                asked, blocked, wake (what the hooks module and the scripts read and write)
#   $team_state/repos/<key>/     one folder per repository: the checkout lock, the dispatcher's lock and
#                                cursor, who follows each issue, QA and review records, the board
#   $team_data/                  what is kept: the user's own rules, the tech leads' notes, spike reports
# The status of a session is one JSON object, written by the scripts and the hooks, never by the model:
#   {"role", "repo", "name", "issue", "title", "topic", "place", "state", "detail", "since", "pr"}
# state: working (cyan), others (purple: waits on another agent or the checkout), you (yellow: waits on
# the user), stuck (red: dead, failing or silent), done (no color, then the session goes away).
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
	{ cat "$file" 2>/dev/null || echo '{}'; } | jq -c "$@" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" || rm -f "$file.tmp"
}

# state_set <session-id> <state> <detail>: the session's state and what it means in a few words; `since`
# moves only when one of the two changes.
state_set() {
	status_set "$1" --arg s "$2" --arg d "$3" --argjson now "$(date +%s)" \
		'(if .state == $s and .detail == $d then . else .since = $now end) | .state = $s | .detail = $d'
}

# waiting_in_chat <session-id>: true when an agent's last turn ended asking something in its own chat
# (hooks/asks.sh) and no turn has started since (hooks/sessions.tsx empties `idle` when one does).
waiting_in_chat() { [ -f "$sessions_dir/$1/asked" ] && [ -s "$sessions_dir/$1/idle" ]; }
