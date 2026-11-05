#!/bin/sh
# Gives the release manager or the planner of this repository its name with its counter:
#   release manager · <repo> 🚀<merged today>      planner · <repo> 🙋<questions waiting for the user>
# The counter is left out at zero. The name changes only when it differs.
#   sync-names.sh manager|planner [session-id]   (without an id, the session already named after the role)
set -eu

role=${1:?manager or planner}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"

case "$role" in
manager)
	prefix=$manager_prefix
	n=$(merged_today)
	icon="🚀"
	;;
planner)
	prefix=$planner_prefix
	n=$(questions_open)
	icon="🙋"
	;;
*)
	echo "usage: sync-names.sh manager|planner [session-id]" >&2
	exit 2
	;;
esac
want=$prefix
[ "${n:-0}" -gt 0 ] && want="$prefix $icon$n"

id=${2:-}
current=""
if [ -z "$id" ]; then
	found=$(session_of "$prefix")
	[ -n "$found" ] || {
		echo "no $role session running for $repo_short"
		exit 0
	}
	id=$(printf '%s' "$found" | cut -f1)
	current=$(printf '%s' "$found" | cut -f2)
else
	current=$(claude agents --json 2>/dev/null | jq -r --arg s "$id" '[.[] | select(.sessionId == $s) | .name][0] // empty')
fi
[ "$current" = "$want" ] && exit 0
sh "$here/rename.sh" "$id" "$want"
