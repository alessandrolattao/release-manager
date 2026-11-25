#!/bin/sh
# Updates the team plugin on this machine and moves the team onto the new version:
#   1. updates the plugin on every Claude Code account the team's sessions here use;
#   2. restarts every live team session on the new version, each once it is quiet (its conversation
#      unchanged for 90 seconds, so no turn is cut), resuming it with no flags (a flag would start a copy)
#      and a message with the new version and where its scripts are;
#   3. restarts on the new version every dispatcher that was running here (a stopped one stays stopped).
# After step 1 the newest installed version's own update.sh does the rest, so the restart prompt and every
# later step are the new version's, whatever version started the update.
# A process of its own, so it goes on after the session that started it is restarted too.
#   update.sh [start]                starts it in the background; its log: <state>/team/update.log
#   update.sh run                    the update itself
#   update.sh run --plugin-updated   steps 2 and 3 only: an older version's update.sh hands over to this one
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

# 1. The plugin, on every account the team uses here; skipped when an older version handed over, whose
# log already says the update started.
if [ "${2:-}" != --plugin-updated ]; then
	echo "$(date '+%F %T') update starts"
	accounts=$( { cat "$sessions_dir"/*/config 2>/dev/null; echo; } | sort -u)
	printf '%s\n' "$accounts" | while IFS= read -r cfg; do
		as "$cfg" claude plugin marketplace update team </dev/null >/dev/null 2>&1
		echo "account $(home_of "$cfg"): $(as "$cfg" claude plugin update team@team </dev/null 2>&1 | tail -1)"
	done
	# The rest is the newest installed version's, on any of those accounts, unless this is that version.
	latest=$(printf '%s\n' "$accounts" | while IFS= read -r cfg; do
		p=$(newest "$cfg")
		[ -z "$p" ] || printf '%s\t%s\n' "$(basename "$p")" "$p"
	done | sort -V | tail -1 | cut -f2)
	mine=$(jq -r '.version // ""' "$here/../.claude-plugin/plugin.json" 2>/dev/null || true)
	if [ -f "$latest/scripts/update.sh" ] && [ "$(basename "$latest")" != "$mine" ]; then
		echo "continuing with team $(basename "$latest")"
		exec env CLAUDE_CODE_SESSION_ID="$caller" sh "$latest/scripts/update.sh" run --plugin-updated
	fi
fi

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
	# Ended while the update waited on another session: nothing to restart.
	[ -s "$folder/role" ] && [ -f "$folder/status" ] || continue
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
	# Done while it was waited on: the plugin removes it, nothing to restart.
	[ -f "$folder/status" ] && [ "$(jq -r '.state // ""' "$folder/status")" != done ] || continue
	as "$cfg" claude stop "${id%%-*}" </dev/null >/dev/null 2>&1
	n=0
	until gone "$cfg" "$id" || [ "$n" -ge "$GONE" ]; do
		sleep 1
		n=$((n + 1))
	done
	case "$role" in
	tech-lead)
		told="$plugin/skills/tech-lead/SKILL.md"
		waiting="If you were waiting for the user's answer, end your turn with that question again, whole, with its options, in its last line."
		;;
	spike)
		told="$plugin/briefs/spike.md"
		waiting="Go on with your analysis."
		;;
	*)
		told="$plugin/briefs/$role.md"
		waiting="If you are waiting for something (another agent, the checkout, CI), declare it with sh \"$plugin/scripts/status.sh\" <others|working> \"<what you wait for>\" [--for <minutes>] and end your turn."
		;;
	esac
	prompt="The team plugin was updated to $(basename "$plugin") and this session was restarted to load it. Its scripts are now in $plugin/scripts: use this path from now on. Your role's rules may have changed: read $told again now, whole, and follow it from here on (its {{...}} placeholders stand for what you already know: your issue, branch, worktree, repository). Then go on from where you were. Commands you started in the background before the restart (a \`main-ci.sh --wait\`, a spike's wait) keep running and their end still reaches you: do not start them again. $waiting"
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
