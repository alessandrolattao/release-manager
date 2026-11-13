#!/bin/sh
# Uses TitTieS, when it is installed on this Claude Code account, without going through the model.
#   titties.sh on <session-id>              turns voice notifications on for the session
#   titties.sh call <session-id> <<'EOF'    says the sentence on stdin (only if the session is on)
#   EOF
# Without TitTieS it says so and exits 0: the release manager works without voice.
set -eu

action=${1:?on or call}
id=${2:?session id}
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
root=$(jq -r '.plugins["titties@titties"][0].installPath // empty' "$config/plugins/installed_plugins.json" 2>/dev/null || true)
data="$config/plugins/data/titties-titties"
if [ -z "$root" ] || [ ! -d "$root/hooks" ]; then
	echo "TitTieS is not installed on this account: no voice"
	exit 0
fi
case "$action" in
on) exec sh "$root/hooks/session.sh" on "$id" "$data" ;;
call) exec sh "$root/hooks/call.sh" "$root" "$data" "$id" ;;
*)
	echo "usage: titties.sh on|call <session-id>" >&2
	exit 2
	;;
esac
