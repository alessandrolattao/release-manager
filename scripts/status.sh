#!/bin/sh
# Sets this session's state, which its color and the board show. Most of the time the other scripts set it
# (comment.sh, checkout.sh, qa.sh, merge.sh, done.sh); call it yourself only for what they do not cover.
#   status.sh working "<what you are doing>" [--for <minutes>]
#       --for: a wait of yours in the background (CI, a long build) that may last that long; until then a
#       silent session is not taken for a stuck one
#   status.sh others "<who or what you wait for>"
#   status.sh you "<what the user has to do>"
#   status.sh done "<how it ended>"
set -eu

state=${1:?working, others, you or done}
detail=${2:?a few words}
id=${CLAUDE_CODE_SESSION_ID:?run it from a session}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/session-dir.sh
. "$here/session-dir.sh"
case "$state" in
working | others | you | done) ;;
*)
	echo "unknown state '$state': working, others, you or done" >&2
	exit 2
	;;
esac
state_set "$id" "$state" "$(printf '%s' "$detail" | tr '\n' ' ' | cut -c1-120)"
if [ "${3:-}" = --for ]; then
	minutes=${4:?minutes}
	status_set "$id" --argjson u "$(($(date +%s) + minutes * 60))" '.busy_until = $u'
fi
echo "state: $state"
