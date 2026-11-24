#!/bin/sh
# Updates the team plugin on this machine and moves the team onto the new version:
#   1. updates the plugin on every Claude Code account the team's sessions here use;
#   2. restarts every live team session on the new version, each once it is quiet (its conversation
#      unchanged for 90 seconds, so no turn is cut), resuming it with no flags (a flag would start a copy)
#      and a message with the new version and where its scripts are;
#   3. restarts on the new version every dispatcher that was running here (a stopped one stays stopped).
# A process of its own, so it goes on after the session that started it is restarted too.
#   update.sh [start]   starts it in the background; its log: <state>/team/update.log
#   update.sh run       the update itself
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/session-dir.sh
. "$here/session-dir.sh"
log="$team_state/update.log"
QUIET=${UPDATE_QUIET:-90}
GONE=${UPDATE_GONE:-60}

if [ "${1:-start}" = start ]; then
	mkdir -p "$team_state"
	setsid nohup sh "$here/update.sh" run >"$log" 2>&1 </dev/null &
	echo "the team is updating on this machine: sessions restart one by one as they go quiet (log: $log)"
	exit 0
fi

# Not one of the sessions: no session's own variables.
caller=${CLAUDE_CODE_SESSION_ID:-}
for v in $(env | grep -o -E '^CLAUDE[A-Z_]*'); do unset "$v"; done

# as <config dir> <command...>: on that account; an empty one is the default account (~/.claude).
as() {
	cfg=$1
	shift
	if [ -n "$cfg" ]; then CLAUDE_CONFIG_DIR=$cfg "$@"; else "$@"; fi
}
home_of() { if [ -n "$1" ]; then echo "$1"; else echo "$HOME/.claude"; fi; }
# alive <session id>: its heartbeat is from the last 3 minutes.
alive() {
	at=$(cat "$sessions_dir/$1/alive" 2>/dev/null || true)
	case "$at" in "" | *[!0-9]*) return 1 ;; esac
	[ $(($(date +%s) - at)) -le 180 ]
}
# newest <config dir>: the newest installed version's folder of the plugin on that account.
newest() { ls -d "$(home_of "$1")/plugins/cache/team/team/"*/ 2>/dev/null | sort -V | tail -1 | sed 's#/$##'; }
running() { [ "$(as "$1" claude agents --json </dev/null 2>/dev/null | jq --arg s "$2" '[.[] | select(.sessionId == $s and .status != null)] | length')" != 0 ]; }
gone() {
	roster=$(jq --arg s "$2" '[.workers[]? | select(.sessionId == $s)] | length' "$(home_of "$1")/daemon/roster.json" 2>/dev/null || echo 0)
	[ "$roster" = 0 ] && ! running "$1" "$2"
}

echo "$(date '+%F %T') update starts"

# 1. The plugin, on every account the team uses here.
accounts=$( { cat "$sessions_dir"/*/config 2>/dev/null; echo; } | sort -u)
printf '%s\n' "$accounts" | while IFS= read -r cfg; do
	as "$cfg" claude plugin marketplace update team </dev/null >/dev/null 2>&1
	echo "account $(home_of "$cfg"): $(as "$cfg" claude plugin update team@team </dev/null 2>&1 | tail -1)"
done

# 2. The live sessions, the one that started the update last.
list=$(for folder in "$sessions_dir"/*/; do
	id=$(basename "$folder")
	[ -s "$folder/role" ] && [ -f "$folder/status" ] || continue
	[ "$(jq -r '.state // ""' "$folder/status")" != done ] || continue
	cfg=$(cat "$folder/config" 2>/dev/null || true)
	alive "$id" || running "$cfg" "$id" || continue
	[ "$id" = "$caller" ] || echo "$id"
done
[ -z "$caller" ] || [ ! -s "$sessions_dir/$caller/role" ] || echo "$caller")
for id in $list; do
	folder="$sessions_dir/$id"
	role=$(cat "$folder/role")
	cfg=$(cat "$folder/config" 2>/dev/null || true)
	dir=$(cat "$folder/cwd" 2>/dev/null || true)
	name=$(jq -r '.name // ""' "$folder/status")
	plugin=$(newest "$cfg")
	[ -n "$plugin" ] && [ -d "$dir" ] || {
		echo "$name: left as it is (no plugin or folder)"
		continue
	}
	# Quiet: its conversation unchanged for $QUIET seconds, so no turn is cut (at most 30 minutes of waiting).
	transcript=$(find "$(home_of "$cfg")/projects" -name "$id.jsonl" 2>/dev/null | head -1)
	n=0
	while [ -n "$transcript" ] && [ $(($(date +%s) - $(stat -c %Y "$transcript"))) -lt "$QUIET" ] && [ "$n" -lt 180 ]; do
		sleep 10
		n=$((n + 1))
	done
	[ "$n" -lt 180 ] || {
		echo "$name: still busy after 30 minutes, left on its version"
		continue
	}
	as "$cfg" claude stop "${id%%-*}" </dev/null >/dev/null 2>&1
	n=0
	until gone "$cfg" "$id" || [ "$n" -ge "$GONE" ]; do
		sleep 1
		n=$((n + 1))
	done
	case "$role" in
	tech-lead) waiting="If you were waiting for the user's answer, end your turn with that question again in its last line." ;;
	spike) waiting="Go on with your analysis." ;;
	*) waiting="If you are waiting for something (another agent, the checkout, CI), declare it with sh \"$plugin/scripts/status.sh\" <others|working> \"<what you wait for>\" [--for <minutes>] and end your turn." ;;
	esac
	prompt="The team plugin was updated to $(basename "$plugin") and this session was restarted to load it. Its scripts are now in $plugin/scripts: use this path from now on, and read again what your role is told ($plugin/briefs or $plugin/skills) when its rules matter. Go on from where you were. $waiting"
	out=$( (cd "$dir" && as "$cfg" claude --bg --resume "$id" "$prompt") </dev/null 2>&1 | head -1)
	echo "$name: $out"
done

# 3. The dispatchers that were running here.
for repo in "$team_state"/repos/*/; do
	pid=$(cat "$repo/dispatcher.pid" 2>/dev/null || true)
	case "$pid" in "" | *[!0-9]*) continue ;; esac
	kill -0 "$pid" 2>/dev/null || continue
	root=$(cat "$repo/dispatcher.root" 2>/dev/null || true)
	cfg=$(cat "$repo/dispatcher.config" 2>/dev/null || true)
	# A dispatcher started by an older version did not record where and on which account it runs: the
	# repository's tech lead knows.
	if [ -z "$root" ]; then
		key=$(basename "$repo")
		for f in "$sessions_dir"/*/status; do
			[ "$(jq -r '(.role // "") + " " + ((.repo // "") | gsub("/"; "_"))' "$f" 2>/dev/null)" = "tech-lead $key" ] || continue
			root=$(cat "$(dirname "$f")/cwd" 2>/dev/null || true)
			cfg=$(cat "$(dirname "$f")/config" 2>/dev/null || true)
			break
		done
	fi
	plugin=$(newest "$cfg")
	[ -d "$root" ] && [ -n "$plugin" ] || {
		echo "dispatcher $(basename "$repo"): left as it is (no folder or plugin)"
		continue
	}
	(cd "$root" && as "$cfg" sh "$plugin/scripts/dispatcher.sh" stop >/dev/null 2>&1)
	echo "dispatcher $(basename "$repo"): $( (cd "$root" && as "$cfg" sh "$plugin/scripts/dispatcher.sh" start) 2>&1 | tail -1)"
done
echo "$(date '+%F %T') update done"
