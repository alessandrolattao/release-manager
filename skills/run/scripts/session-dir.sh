# Sourced by the scripts and the hooks: where each session's look and role are kept, one folder per
# session id (`color`, `name`, `role`, `cwd`, `config`, `alive`, `idle`). The plugin's hooks module
# (hooks/sessions.tsx), running inside every session, reads its own folder and applies what it finds.
# Session ids are unique across Claude Code accounts, so one place serves them all.
# shellcheck shell=sh disable=SC2034 # the variable is used by the files that source this one

sessions_dir="${XDG_STATE_HOME:-$HOME/.local/state}/release-manager/sessions"

# waiting_in_chat <session-id>: true when a developer agent's last turn ended asking something
# (hooks/agent-asks.sh) and no turn has started since (hooks/sessions.tsx empties `idle` when one does).
waiting_in_chat() { [ -f "$sessions_dir/$1/asked" ] && [ -s "$sessions_dir/$1/idle" ]; }

# want <session-id> <file> <value>: writes one file of a session's folder in one step, so the module
# never reads half of it.
want() {
	mkdir -p "$sessions_dir/$1"
	printf '%s\n' "$3" >"$sessions_dir/$1/$2.tmp"
	mv "$sessions_dir/$1/$2.tmp" "$sessions_dir/$1/$2"
}
