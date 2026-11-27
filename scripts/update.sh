#!/bin/sh
# Updates the team plugin on this machine and moves the team onto the new version:
#   1. updates the plugin on every Claude Code account the team's sessions here use; when none of them got
#      a new version, it restarts nothing and ends ("nothing to update");
#   2. restarts on the new version every dispatcher that was running here (a stopped one stays stopped);
#   3. waits for every live team session to run the new version. One on a version that reloads it by itself
#      ($RELOADS or newer) reloads the plugin in place, between turns, and reads its role's rules again
#      (hooks/sessions.tsx): the update waits for its `version` to reach the new one. One on an older version,
#      or with none recorded, cannot: it is restarted on the new version once it is quiet (between turns for
#      5 seconds, so no turn is cut; one started by a version that does not record its turns, its conversation
#      unchanged for 90 seconds) and not holding its repository's main checkout (scripts/checkout.sh: testing
#      there, a restart would lose what it built, a browser's signed-in sessions): the quiet ones at once, the
#      busy ones as soon as they go quiet, the ones holding the checkout as soon as they give it back, the one
#      that started the update last; resumed with no flags (a flag would start a copy) and a message with the
#      new version and where its scripts are. One holding the checkout that reloads by itself waits for it too
#      (hooks/sessions.tsx).
# In steps 2 and 3 a dispatcher or a session already on the newest version installed for its account is left
# alone ("already on <version>"): the version it runs is in dispatcher.version, a session's in its folder's
# `version` (hooks/sessions.tsx).
# After step 1 the newest installed version's own update.sh does the rest, so the restart prompt and every
# later step are the new version's, whatever version started the update.
# A process of its own, so it goes on after the session that started it is restarted too.
#   update.sh [start]                starts it in the background; its log: <state>/team/update.log
#   update.sh run                    the update itself
#   update.sh run --plugin-updated   steps 2 and 3 only: an older version's update.sh hands over to this one
#   update.sh restart <session id>   restarts that session on the newest version installed, in the background,
#                                    as step 3 restarts one (once it is quiet and holds no checkout), its lines
#                                    in the same log: its hooks module runs it when its reload failed
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/session-dir.sh
. "$here/session-dir.sh"
log="$team_state/update.log"
QUIET=${UPDATE_QUIET:-5}
TRANSCRIPT_QUIET=${UPDATE_TRANSCRIPT_QUIET:-90}
GONE=${UPDATE_GONE:-60}
# How long step 3 waits for the sessions, in seconds: one still behind then is reported and left on its version.
WAIT=${UPDATE_WAIT:-1800}
# The first version whose sessions reload a new version by themselves (hooks/sessions.tsx).
RELOADS=0.5.8

# The log is written in append mode, so the lines of a restart running beside the update are kept.
case "${1:-start}" in
start)
	mkdir -p "$team_state"
	: >"$log"
	setsid nohup sh "$here/update.sh" run >>"$log" 2>&1 </dev/null &
	echo "the team is updating on this machine: the sessions behind the new version reload it as they go quiet (log: $log)"
	exit 0
	;;
restart)
	if [ "${3:-}" != --now ]; then
		mkdir -p "$team_state"
		setsid nohup sh "$here/update.sh" restart "${2:?usage: update.sh restart <session id>}" --now >>"$log" 2>&1 </dev/null &
		exit 0
	fi
	;;
esac

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
# installed <accounts>: each account and the newest version of the plugin installed on it, one per line.
installed() {
	printf '%s\n' "$1" | while IFS= read -r cfg; do
		p=$(newest "$cfg")
		printf '%s\t%s\n' "$cfg" "${p##*/}"
	done
}
# behind <version> <newest>: the version is older than the newest one; an empty version (none recorded) is.
behind() { [ -z "$1" ] || { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }; }
# reloads <session id>: the version it recorded reloads a new one by itself.
reloads() { ! behind "$(cat "$sessions_dir/$1/version" 2>/dev/null || true)" "$RELOADS"; }
# holding <session id>: it holds its repository's main checkout, the lock's first line (scripts/checkout.sh).
holding() {
	lock="$team_state/repos/$(jq -r '.repo // ""' "$sessions_dir/$1/status" 2>/dev/null | tr '/' '_')/checkout"
	[ "$(sed -n 1p "$lock" 2>/dev/null)" = "$1" ]
}
running() { [ "$(as "$1" claude agents --json </dev/null 2>/dev/null | jq --arg s "$2" '[.[] | select(.sessionId == $s and .status != null)] | length')" != 0 ]; }
gone() {
	roster=$(jq --arg s "$2" '[.workers[]? | select(.sessionId == $s)] | length' "$(home_of "$1")/daemon/roster.json" 2>/dev/null || echo 0)
	[ "$roster" = 0 ] && ! running "$1" "$2"
}

# The sessions step 3 waits on to reload by themselves, one id per word; and, when set, a session to restart
# whatever its version (update.sh restart).
waited=""
forced=""
# look <session id>: done with it (0), or to look at again at the next pass (1): one that reloads by itself
# until its `version` reaches the newest installed, one to restart while it is busy.
look() {
	id=$1
	folder="$sessions_dir/$id"
	# Ended while the update waited (done, or its folder gone): the plugin removes it, nothing to restart.
	[ -s "$folder/role" ] && [ -f "$folder/status" ] && [ "$(jq -r '.state // ""' "$folder/status")" != done ] || return 0
	role=$(cat "$folder/role")
	cfg=$(cat "$folder/config" 2>/dev/null || true)
	dir=$(cat "$folder/cwd" 2>/dev/null || true)
	name=$(jq -r '.name // ""' "$folder/status")
	plugin=$(newest "$cfg")
	[ -n "$plugin" ] || {
		echo "$name: left as it is (no plugin or folder)"
		return 0
	}
	have=$(cat "$folder/version" 2>/dev/null || true)
	behind "$have" "${plugin##*/}" || {
		case " $waited " in
		*" $id "*) echo "$name: now on $have" ;;
		*) echo "$name: already on $have" ;;
		esac
		return 0
	}
	# One that reloads by itself: waited for, unless its own reload failed (update.sh restart).
	if [ "$id" != "$forced" ] && reloads "$id"; then
		case " $waited " in *" $id "*) ;; *) waited="$waited $id" ;; esac
		return 1
	fi
	[ -d "$dir" ] || {
		echo "$name: left as it is (no plugin or folder)"
		return 0
	}
	# Holding the main checkout: it may be testing there, it restarts once it has given it back.
	! holding "$id" || return 1
	# Quiet: between turns for $QUIET seconds, so no turn is cut. Its `idle` holds the time its last turn
	# ended, empty while one runs (hooks/sessions.tsx); its conversation file is no measure, it changes while
	# the session waits.
	if [ -f "$folder/idle" ]; then
		ended=$(cat "$folder/idle" 2>/dev/null || true)
		case "$ended" in "" | *[!0-9]*) return 1 ;; esac
		[ $(($(date +%s) - ended)) -ge "$QUIET" ] || return 1
	else
		# Started by a version with no `idle` file: its conversation unchanged for $TRANSCRIPT_QUIET seconds,
		# long enough not to cut a turn running a long command.
		transcript=$(find "$(home_of "$cfg")/projects" -name "$id.jsonl" 2>/dev/null | head -1)
		[ -z "$transcript" ] || [ $(($(date +%s) - $(stat -c %Y "$transcript"))) -ge "$TRANSCRIPT_QUIET" ] || return 1
	fi
	as "$cfg" claude stop "${id%%-*}" </dev/null >/dev/null 2>&1
	n=0
	until gone "$cfg" "$id" || [ "$n" -ge "$GONE" ]; do
		sleep 1
		n=$((n + 1))
	done
	case "$role" in
	tech-lead)
		told="$plugin/skills/tech-lead/SKILL.md"
		# Only a tech lead starts subagents (the others are started with the Agent tool denied).
		waiting="Subagents you started with the Agent tool before the restart may have been stopped: if a hand-back you wait for does not come, start that subagent again. If you were waiting for the user's answer, end your turn with that question again, whole, with its options, in its last line."
		;;
	spike)
		told="$plugin/briefs/spike.md"
		waiting="Go on with your analysis."
		;;
	*)
		told="$plugin/briefs/$role.md"
		[ "$role" != review ] || told="$plugin/briefs/reviewer.md"
		waiting="If you are waiting for something (another agent, the checkout, CI), declare it with sh \"$plugin/scripts/status.sh\" <others|working> \"<what you wait for>\" [--for <minutes>] and end your turn."
		;;
	esac
	prompt="The team plugin was updated to $(basename "$plugin") and this session was restarted to load it. Its scripts are now in $plugin/scripts: use this path from now on. Your role's rules may have changed: read $told again now, whole, and follow it from here on (its {{...}} placeholders stand for what you already know: your issue, branch, worktree, repository). Then go on from where you were. Commands you started in the background before the restart (a \`main-ci.sh --wait\`, a spike's wait) keep running and their end still reaches you: do not start them again. $waiting"
	out=$( (cd "$dir" && as "$cfg" claude --bg --resume "$id" "$prompt") </dev/null 2>&1 | head -1)
	echo "$name: $out"
}
# passes <session id...>: looks at them pass after pass, every 10 seconds, until none is left or $WAIT seconds
# have passed since $since; reports the ones left then.
passes() {
	pending=$*
	while :; do
		left=""
		for p in $pending; do look "$p" || left="$left $p"; done
		pending=$left
		[ -n "$pending" ] && [ $(($(date +%s) - since)) -lt "$WAIT" ] || break
		sleep 10
	done
	for p in $pending; do
		name=$(jq -r '.name // ""' "$sessions_dir/$p/status")
		case " $waited " in
		*" $p "*) echo "$name: still behind after $((WAIT / 60)) minutes, on $(cat "$sessions_dir/$p/version" 2>/dev/null || true)" ;;
		*) if holding "$p"; then
			echo "$name: still holds the checkout after $((WAIT / 60)) minutes, left on its version"
		else
			echo "$name: still busy after $((WAIT / 60)) minutes, left on its version"
		fi ;;
		esac
	done
}

# A session whose reload failed (hooks/sessions.tsx): restarted as step 3 restarts one too old to reload.
if [ "${1:-}" = restart ]; then
	forced=$2
	echo "$(date '+%F %T') $(jq -r '.name // ""' "$sessions_dir/$forced/status" 2>/dev/null || true): its reload failed, it restarts"
	since=$(date +%s)
	passes "$forced"
	exit 0
fi

# 1. The plugin, on every account the team uses here; skipped when an older version handed over, whose
# log already says the update started.
if [ "${2:-}" != --plugin-updated ]; then
	echo "$(date '+%F %T') update starts"
	accounts=$( { cat "$sessions_dir"/*/config 2>/dev/null; echo; } | sort -u)
	before=$(installed "$accounts")
	printf '%s\n' "$accounts" | while IFS= read -r cfg; do
		as "$cfg" claude plugin marketplace update team </dev/null >/dev/null 2>&1
		echo "account $(home_of "$cfg"): $(as "$cfg" claude plugin update team@team </dev/null 2>&1 | tail -1)"
	done
	# No account got a new version: every session and dispatcher already runs what it can.
	if [ "$(installed "$accounts")" = "$before" ]; then
		echo "nothing to update"
		echo "$(date '+%F %T') update done"
		exit 0
	fi
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

# 2. The dispatchers that were running here, before the sessions: they do not depend on them, and the sessions
# may take a while.
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
	have=$(cat "$repo/dispatcher.version" 2>/dev/null || true)
	behind "$have" "${plugin##*/}" || {
		echo "dispatcher $(basename "$repo"): already on $have"
		continue
	}
	(cd "$root" && as "$cfg" sh "$plugin/scripts/dispatcher.sh" stop >/dev/null 2>&1)
	echo "dispatcher $(basename "$repo"): $( (cd "$root" && as "$cfg" sh "$plugin/scripts/dispatcher.sh" start) 2>&1 | tail -1)"
done

# 3. The live sessions. In passes, every 10 seconds: each pass notes the sessions that reached the new version
# and restarts the quiet ones among those too old to reload it by themselves, keeping the others for the next,
# until none is left or $WAIT seconds have passed since the step started. One too old to reload that started the
# update goes last, waited on alone, with $WAIT seconds of its own; one that reloads goes with the others.
others=$(for folder in "$sessions_dir"/*/; do
	id=$(basename "$folder")
	[ -s "$folder/role" ] && [ -f "$folder/status" ] || continue
	[ "$(jq -r '.state // ""' "$folder/status")" != done ] || continue
	cfg=$(cat "$folder/config" 2>/dev/null || true)
	[ "$id" != "$caller" ] || reloads "$id" || continue
	alive "$id" || running "$cfg" "$id" || continue
	echo "$id"
done)
since=$(date +%s)
# shellcheck disable=SC2086 # one word per session id
passes $others
# The one that started the update, too old to reload, once every other session is on the new version, ended or
# given up.
if [ -n "$caller" ] && [ -s "$sessions_dir/$caller/role" ] && ! reloads "$caller"; then
	since=$(date +%s)
	passes "$caller"
fi
echo "$(date '+%F %T') update done"
