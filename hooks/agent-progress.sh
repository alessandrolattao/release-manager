#!/bin/sh
# Moves an agent to [review] without the model, after a Bash call in its own session:
# - `gh pr create` that printed a pull request URL, from [dev] or [fix];
# - a successful `git push` from [fix] (the fixes are up, CI and reviews run again).
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
case "$payload" in
*"gh pr create"* | *"git push"*) ;;
*) exit 0 ;;
esac

name=$(session_name)
case "$name" in
"[dev]"* | "[fix]"*) ;;
*) exit 0 ;;
esac

if printf '%s' "$payload" | grep -q 'gh pr create'; then
	printf '%s' "$payload" | grep -q 'github.com/[^"]*/pull/[0-9]' || exit 0
else
	case "$name" in "[fix]"*) ;; *) exit 0 ;; esac
	# A rejected or failed push leaves the agent where it is.
	printf '%s' "$payload" | grep -q -E 'rejected|error:|fatal:' && exit 0
fi
cd "$cwd"
sh "$scripts/set-state.sh" "${name#* }" review >/dev/null 2>&1
