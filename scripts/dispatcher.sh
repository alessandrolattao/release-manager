#!/bin/sh
# The team's dispatcher for one repository on this machine: a process of its own that runs dispatch.sh
# every minute (it starts developers on ready issues, wakes the sessions with the comments written to them,
# keeps the board's summary). A tech lead of the repository on this machine keeps it running: stopped (a
# restart of the machine, a crash), its hooks module starts it again. A stop by hand (this script,
# /team:dispatcher stop) holds until a start by hand (a click on its row in the board's summary,
# /team:dispatcher, this script): the tech lead leaves it stopped.
#   dispatcher.sh [start]   starts it, in the background, unless it already runs
#   dispatcher.sh stop      stops it
#   dispatcher.sh status    running, stopped, or stopped (by hand)
#   dispatcher.sh run       the loop itself (start runs it)
# At each cycle it looks for a newer version of the plugin installed on its account: with one, it starts that
# version's loop for the same repository and leaves ("now on team <version>" in its log), so one started by a
# session still on an older version, also during an update, ends up on the newest.
# Its files, in the repository's state folder: dispatcher.pid, dispatcher.alive (the last cycle, epoch),
# dispatcher.version (the plugin's), dispatcher.log (cut to its last 1000 lines at each start),
# dispatcher.stopped (when it was stopped by hand, until it is started again).
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
stopped_file="$repo_dir/dispatcher.stopped"

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
# newer <version> <than>: the version is newer than the other one; any version is newer than none.
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -1)" = "$1" ]; }

case "$action" in
start)
	rm -f "$stopped_file"
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
	case "$pid" in
	"" | *[!0-9]*) ;;
	*)
		# Gone before this returns, so a start right after never meets it.
		kill "$pid" 2>/dev/null || true
		n=0
		while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 20 ]; do
			sleep 0.5
			n=$((n + 1))
		done
		;;
	esac
	rm -f "$pid_file" "$alive_file"
	date +%s >"$stopped_file"
	echo "the dispatcher of $repo_full is stopped on this machine, until you start it again"
	;;
status)
	if running; then
		echo "running (pid $(cat "$pid_file"), team $(cat "$version_file" 2>/dev/null), last cycle $(date -d "@$(cat "$alive_file")" +%H:%M:%S))"
	elif [ -f "$stopped_file" ]; then
		echo "stopped (by hand)"
	else
		echo "stopped"
	fi
	;;
run)
	# Not one of the sessions: no session's own variables, only the account.
	for v in $(env | grep -o -E '^CLAUDE[A-Z_]*' | grep -v '^CLAUDE_CONFIG_DIR$'); do unset "$v"; done
	echo $$ >"$pid_file"
	mine=$(jq -r '.version // ""' "$here/../.claude-plugin/plugin.json" 2>/dev/null || true)
	printf '%s\n' "$mine" >"$version_file"
	# On its way out it removes the pid file only while it is still its own: a dispatcher started meanwhile
	# keeps its own.
	trap '[ "$(cat "$pid_file" 2>/dev/null)" != "$$" ] || rm -f "$pid_file"' EXIT
	trap 'exit 0' INT TERM
	while :; do
		# Another dispatcher took this repository over (its pid in the file), or it was stopped by hand meanwhile
		# (a stop while an older one handed over to this one): this one leaves.
		[ "$(cat "$pid_file" 2>/dev/null)" = "$$" ] && [ ! -f "$stopped_file" ] || exit 0
		# A newer version installed on its account (the update reads the same folder): its loop goes on for this
		# repository, detached as a start runs it, and this one leaves. Its pid file goes first, so its way out
		# never removes the new one's.
		newest=$(ls -d "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/team/team/"*/ 2>/dev/null | sort -V | tail -1 | sed 's#/$##')
		if [ -f "$newest/scripts/dispatcher.sh" ] && newer "${newest##*/}" "$mine"; then
			echo "$(date '+%F %T') now on team ${newest##*/}"
			cd "$root"
			rm -f "$pid_file"
			setsid nohup sh "$newest/scripts/dispatcher.sh" run >>"$log" 2>&1 </dev/null &
			exit 0
		fi
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
