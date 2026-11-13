#!/bin/sh
# Gives the release manager or the planner of this repository its name with its counter:
#   release manager · <repo> 🚀<merged today>
#   planner · <repo> 🙋<questions waiting for the user> 🧠<issues to prepare, not ready for development>
#   📨<unread messages in its inbox> on either
# A counter is left out at zero. The name changes only when it differs.
#   sync-names.sh manager|planner [session-id]   (without an id, the session already named after the role)
set -eu

role=${1:?manager or planner}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"

case "$role" in
manager)
	prefix=$manager_prefix
	counters=""
	n=$(merged_today)
	[ "${n:-0}" -gt 0 ] && counters=" 🚀$n"
	k=$(inbox_new manager)
	[ "${k:-0}" -gt 0 ] && counters="$counters 📨$k"
	;;
planner)
	prefix=$planner_prefix
	counters=""
	n=$(questions_open)
	[ "${n:-0}" -gt 0 ] && counters=" 🙋$n"
	m=$(backlog_open)
	[ "${m:-0}" -gt 0 ] && counters="$counters 🧠$m"
	k=$(inbox_new planner)
	[ "${k:-0}" -gt 0 ] && counters="$counters 📨$k"
	;;
*)
	echo "usage: sync-names.sh manager|planner [session-id]" >&2
	exit 2
	;;
esac
want="$prefix$counters"

id=${2:-}
if [ -z "$id" ]; then
	found=$(session_of "$prefix")
	[ -n "$found" ] || {
		echo "no $role session running for $repo_short"
		exit 0
	}
	id=$(printf '%s' "$found" | cut -f1)
fi
# Compared with the last name asked for the session (rename.sh's file, which the hooks module applies),
# never with its transcript: a session resumed as a copy inherits the old one's title there while
# showing another name.
# shellcheck source=skills/run/scripts/session-dir.sh
. "$here/session-dir.sh"
[ "$(cat "$sessions_dir/$id/name" 2>/dev/null || true)" = "$want" ] && exit 0
sh "$here/rename.sh" "$id" "$want"
