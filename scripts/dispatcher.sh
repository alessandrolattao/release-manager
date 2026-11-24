#!/bin/sh
# The team's dispatcher for one repository on this machine: a process of its own that runs dispatch.sh
# every minute (it starts developers on ready issues, wakes the sessions with the comments written to them,
# keeps the board's summary). It runs only when started by hand: from the board's summary, with
# /team:dispatcher, or with this script; after a restart of the machine it stays stopped until started again.
#   dispatcher.sh [start]   starts it, in the background, unless it already runs
#   dispatcher.sh stop      stops it
#   dispatcher.sh status    running or stopped
#   dispatcher.sh run       the loop itself (start runs it)
# Its files, in the repository's state folder: dispatcher.pid, dispatcher.alive (the last cycle, epoch),
# dispatcher.version (the plugin's), dispatcher.log (cut to its last 1000 lines at each start).
# Run it from the repository's main checkout or one of its worktrees; it works on the Claude Code account
# of CLAUDE_CONFIG_DIR, as the sessions it starts.
set -eu

action=${1:-start}
[ -n "$action" ] || action=start
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
mkdir -p "$repo_dir"
pid_file="$repo_dir/dispatcher.pid"
alive_file="$repo_dir/dispatcher.alive"
version_file="$repo_dir/dispatcher.version"
log="$repo_dir/dispatcher.log"

# running: its process exists and its last cycle is from the last 11 minutes (a cycle may take a few minutes;
# dispatch.sh gives up its own lock after 10).
running() {
	pid=$(cat "$pid_file" 2>/dev/null || true)
	case "$pid" in "" | *[!0-9]*) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null || return 1
	at=$(cat "$alive_file" 2>/dev/null || echo 0)
	case "$at" in "" | *[!0-9]*) at=0 ;; esac
	[ $(($(date +%s) - at)) -le 660 ]
}

case "$action" in
start)
	if running; then
		echo "the dispatcher of $repo_full already runs on this machine (pid $(cat "$pid_file"), team $(cat "$version_file" 2>/dev/null))"
		exit 0
	fi
	# A stale process (stopped cycling) goes first.
	old=$(cat "$pid_file" 2>/dev/null || true)
	case "$old" in "" | *[!0-9]*) ;; *) kill "$old" 2>/dev/null || true ;; esac
	cd "$root"
	# Where and on which account it runs, so update.sh can restart it on a new version of the plugin.
	printf '%s\n' "$root" >"$repo_dir/dispatcher.root"
	printf '%s\n' "${CLAUDE_CONFIG_DIR:-}" >"$repo_dir/dispatcher.config"
	[ ! -f "$log" ] || { tail -n 1000 "$log" >"$log.tmp" && mv "$log.tmp" "$log"; }
	setsid nohup sh "$here/dispatcher.sh" run >>"$log" 2>&1 </dev/null &
	n=0
	until running || [ "$n" -ge 20 ]; do
		sleep 1
		n=$((n + 1))
	done
	if running; then
		echo "the dispatcher of $repo_full runs on this machine (pid $(cat "$pid_file"), team $(cat "$version_file" 2>/dev/null))"
	else
		echo "the dispatcher of $repo_full did not start: see $log" >&2
		exit 1
	fi
	;;
stop)
	pid=$(cat "$pid_file" 2>/dev/null || true)
	case "$pid" in "" | *[!0-9]*) ;; *) kill "$pid" 2>/dev/null || true ;; esac
	rm -f "$pid_file" "$alive_file"
	echo "the dispatcher of $repo_full is stopped on this machine"
	;;
status)
	if running; then
		echo "running (pid $(cat "$pid_file"), team $(cat "$version_file" 2>/dev/null), last cycle $(date -d "@$(cat "$alive_file")" +%H:%M:%S))"
	else
		echo "stopped"
	fi
	;;
run)
	# Not one of the sessions: no session's own variables, only the account.
	for v in $(env | grep -o -E '^CLAUDE[A-Z_]*' | grep -v '^CLAUDE_CONFIG_DIR$'); do unset "$v"; done
	echo $$ >"$pid_file"
	jq -r '.version // ""' "$here/../.claude-plugin/plugin.json" >"$version_file" 2>/dev/null || true
	trap 'rm -f "$pid_file"' EXIT
	trap 'exit 0' INT TERM
	while :; do
		date +%s >"$alive_file"
		sh "$here/dispatch.sh" || echo "$(date '+%F %T') dispatch.sh exited $?"
		date +%s >"$alive_file"
		# In the background, so a stop does not wait for the minute to end.
		sleep 60 &
		wait $!
	done
	;;
*)
	echo "usage: dispatcher.sh [start|stop|status]" >&2
	exit 2
	;;
esac
