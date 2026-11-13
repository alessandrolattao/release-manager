#!/bin/sh
# After the machine restarts, resumes the release managers and planners that were running when it went
# down. A SessionStart hook: the first Claude Code session that starts after a boot does it, any other
# one exits at once. Each comes back with its own skill (/release-manager:run, /release-manager:planner),
# on its own account, as if started again; the release manager then resumes its developer agents.
# "Running when it went down": its heartbeat (hooks/sessions.tsx writes it every minute) is from before
# this boot and within 3 minutes of the last heartbeat of that boot. One stopped earlier stays stopped.
#   revive.sh   (hook payload on stdin, unused)
set -eu

# shellcheck source=skills/run/scripts/session-dir.sh
. "${CLAUDE_PLUGIN_ROOT:?}/skills/run/scripts/session-dir.sh"
[ -d "$sessions_dir" ] || exit 0
state=${sessions_dir%/*}

if [ -r /proc/stat ]; then
	boot=$(awk '/^btime/ {print $2}' /proc/stat)
else
	boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')
fi
[ -n "$boot" ] || exit 0
[ "$(cat "$state/revived" 2>/dev/null)" = "$boot" ] && exit 0
mkdir "$state/revive.lock" 2>/dev/null || exit 0
trap 'rmdir "$state/revive.lock"' EXIT
[ "$(cat "$state/revived" 2>/dev/null)" = "$boot" ] && exit 0
printf '%s\n' "$boot" >"$state/revived"

# heartbeat <folder>: the session's last heartbeat in seconds, 0 when it has none.
heartbeat() {
	t=$(cat "$1/alive" 2>/dev/null || true)
	case "$t" in "" | *[!0-9]*) t=0 ;; esac
	printf '%s' "$t"
}

last=0
for folder in "$sessions_dir"/*; do
	[ -f "$folder/role" ] || continue
	t=$(heartbeat "$folder")
	if [ "$t" -lt "$boot" ] && [ "$t" -gt "$last" ]; then
		last=$t
	fi
done
[ "$last" -gt 0 ] || exit 0

# A new session on the account the old one ran on, without this session's own variables.
unset_args=$(env | grep -o -E '^CLAUDE[A-Z_]*' | sed 's/^/-u /' | tr '\n' ' ')
as_account() {
	if [ -n "$config" ]; then
		# shellcheck disable=SC2086 # unset_args is a list of -u flags
		env $unset_args CLAUDE_CONFIG_DIR="$config" "$@"
	else
		# shellcheck disable=SC2086
		env $unset_args "$@"
	fi
}

for folder in "$sessions_dir"/*; do
	[ -f "$folder/role" ] || continue
	t=$(heartbeat "$folder")
	[ "$t" -lt "$boot" ] || continue
	if [ "$t" -lt $((last - 180)) ]; then
		# It was stopped before the machine went down: it stays stopped, and its folder goes.
		rm -rf "$folder"
		continue
	fi
	id=${folder##*/}
	cwd=$(cat "$folder/cwd" 2>/dev/null || true)
	config=$(cat "$folder/config" 2>/dev/null || true)
	case "$(cat "$folder/role")" in
	manager) skill=/release-manager:run ;;
	planner) skill=/release-manager:planner ;;
	*) continue ;;
	esac
	[ -d "$cwd" ] || continue
	running=$(as_account claude agents --json 2>/dev/null |
		jq -r --arg s "$id" '[.[] | select(.sessionId == $s and .status != null)] | length' 2>/dev/null || echo 0)
	[ "${running:-0}" -eq 0 ] || continue
	(cd "$cwd" && as_account claude --bg --resume "$id" "$skill") >/dev/null 2>&1 || true
done
