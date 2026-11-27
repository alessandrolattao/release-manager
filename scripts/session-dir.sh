# Sourced by every script and hook: where the team keeps its state. One place serves every Claude Code
# account, since session ids are unique across them.
#   $team_state/sessions/<id>/   one folder per session: role, cwd, config, alive, idle, status, color, name,
#                                asked, blocked, wake, commented, version (what the hooks module and the
#                                scripts read and write)
#   $team_state/repos/<key>/     one folder per repository: the checkout lock, the dispatcher's lock and
#                                cursor, QA and review records, the board, `seen` (what reached its tech
#                                leads: hooks/sessions.tsx, mentions.sh), and `base` and `remote` (the default
#                                branch and the git remote of the repository, repo.sh)
#   $team_data/                  what is kept: the tech leads' notes, spike reports, other repositories' messages
# The status of a session is one JSON object, written by the scripts and the hooks, never by the model:
#   {"role", "repo", "name", "issue", "title", "topic", "place", "state", "detail", "since", "branch",
#    "busy_until", "tested_head", "head", "asked_on", "waits_on", "started"}
# head: the pushed head a reviewer reads, from its request (start-review.sh): review.sh pass records it.
# asked_on: the issue where the session asked the user on GitHub (comment.sh); absent when it asked in its
# own chat (hooks/asks.sh), where the user answers it directly.
# waits_on: whom the session waits on since it wrote to them on GitHub (comment.sh, or dispatch.sh posting a
# question it left in its chat): the address ("tech lead", "dev #42", "review #42", "qa #42"), or "the user" for a tech
# lead's question to the user. A comment from them ends the wait (hooks/sessions.tsx); a state_set removes
# it, except on a done session, which it leaves as it is; a new wait records its own.
# started: when a developer, a reviewer or a QA agent was launched (role.sh): the dispatcher wakes it for no comment
# written before.
# state: working (cyan), others (purple: waits on another agent or the checkout), you (yellow: waits on
# the user), stuck (red: dead, failing or silent), idle (green: a tech lead waiting for work), done (no
# color, then the session goes away; final: nothing moves a done session to another state).
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
# Done is final: a done session stays done whatever is set after it (a comment it still writes, a hook), so the
# dispatcher removes it as done.sh announces.
state_set() {
	status_set "$1" --arg s "$2" --arg d "$3" --argjson now "$(date +%s)" \
		'if .state == "done" and $s != "done" then .
		else (if .state == $s and .detail == $d then . else .since = $now end) | .state = $s | .detail = $d | del(.waits_on) end'
}

# commented_on <session-id> <issue> [to]: the session wrote on that issue's thread (an issue and the pull
# requests that close it), to that address (empty for a note): one line of `commented`, <time> <issue> <to>.
# A wake for a comment it answered since is dropped (hooks/sessions.tsx). Nothing outside a team session.
commented_on() {
	[ -n "$1" ] && [ -d "$sessions_dir/$1" ] || return 0
	printf '%s\t%s\t%s\n' "$(date +%s)" "$2" "${3:-}" >>"$sessions_dir/$1/commented"
}

# newest_plugin [config dir]: the folder of the newest version of the plugin installed on that Claude Code account
# (none named: ~/.claude), nothing when none is. A version folder marked `.orphaned_at` is not installed: Claude
# Code marks the previous version's folder so when it updates or uninstalls the plugin, and removes it 14 days
# later, so after a rollback the newer folder left behind would otherwise be the newest.
newest_plugin() {
	for _v in "${1:-$HOME/.claude}/plugins/cache/team/team/"*/; do
		[ -d "$_v" ] && [ ! -e "${_v}.orphaned_at" ] && printf '%s\n' "${_v%/}"
	done | sort -V | tail -1
}

# waiting_in_chat <session-id>: true when an agent's last turn ended asking something in its own chat
# (hooks/asks.sh) and no turn has started since (hooks/sessions.tsx empties `idle` when one does).
waiting_in_chat() { [ -f "$sessions_dir/$1/asked" ] && [ -s "$sessions_dir/$1/idle" ]; }
