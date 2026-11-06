#!/bin/sh
# Stop in a planner session: when the planner ends its turn asking the user something and the user
# does not write to it within a couple of minutes, TitTieS calls them. Answering in time keeps it quiet,
# so a live discussion is never interrupted by the voice.
set -eu

delay=${RELEASE_MANAGER_ASK_DELAY:-120}
# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
role_is "planner" is-planner || exit 0

text=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)
[ -n "$text" ] || exit 0
# A question for the user: a "needs input:" line, or a last line that asks.
question=$(printf '%s\n' "$text" | sed -n 's/^needs input:[[:space:]]*//p' | tail -1)
if [ -z "$question" ]; then
	last=$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | tail -1)
	case "$last" in
	*\?*) question=$last ;;
	*) exit 0 ;;
	esac
fi

stamp="$state_dir/$sid.asked"
asked_at=$(date +%s)
echo "$asked_at" >"$stamp"
sleep "$delay"

# Answered in the meantime (the inbox hook stamps every user prompt), or a newer turn took over.
[ "$(cat "$state_dir/$sid.last-prompt" 2>/dev/null || echo 0)" -ge "$asked_at" ] && exit 0
[ "$(cat "$stamp" 2>/dev/null || echo 0)" = "$asked_at" ] || exit 0

cd "$cwd"
# shellcheck source=skills/run/scripts/roles.sh
. "$scripts/roles.sh"
short=$(printf '%s' "$question" | sed -E 's/[`*_#>]//g; s/\[([^]]*)\]\([^)]*\)/\1/g' | cut -c1-140)
sentence="Il planner di $repo_short aspetta una tua risposta."
[ ${#short} -le 120 ] && sentence="$sentence $short"
printf '%s\n' "$sentence" | sh "$scripts/titties.sh" call "$sid"
