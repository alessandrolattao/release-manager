#!/bin/sh
# Stop in a developer agent's session: what it writes in its own chat reaches nobody unless the user is
# there. When its turn ends asking something and it told nobody with SendMessage, the question is recorded
# in the session's folder: if it still waits 5 minutes later the plugin's monitor wakes the release manager
# (hooks/session-events.sh), and after 30 minutes the planner says it out loud (hooks/remind.sh).
#   agent-asks.sh   (hook payload on stdin)
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
# shellcheck source=skills/run/scripts/session-dir.sh
. "$scripts/session-dir.sh"

issue=$(agent_issue)
[ -n "$issue" ] || exit 0
record="$sessions_dir/$sid/asked"
# A turn that ended replaces what the one before it asked.
rm -f "$record" "$record.told" "$record.called"

text=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)
[ -n "$text" ] || exit 0
question=$(printf '%s\n' "$text" | sed -n 's/^needs input:[[:space:]]*//p' | tail -1)
if [ -z "$question" ]; then
	last=$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | tail -1)
	# A question, or a request for a go-ahead written without a question mark ("se mi dai l'ok lo lancio io").
	if printf '%s\n' "$last" | grep -q -i -E "\?([[:space:]]|$)|se mi dai l.ok|dammi l.ok|dimmi |fammi sapere|(aspetto|attendo) (te|il tuo|la tua|una risposta|conferma|istruzioni)|vuoi che|posso procedere|confermi|let me know|tell me |should i |do you want|waiting for (you|your)|your call|(^|[^a-z])ok to "; then
		question=$last
	fi
fi
[ -n "$question" ] || exit 0

# Asked with SendMessage in this same turn: the release manager already has it.
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
	sent=$(tail -n 300 "$transcript" | jq -s '
		[.[] | select(.type == "user" or .type == "assistant")] as $rows
		| ([$rows | to_entries[]
			| select(.value.type == "user" and (.value.isMeta | not)
				and ((.value.message.content | type) == "string" or any(.value.message.content[]?; .type == "text")))
			| .key] | last // -1) as $start
		| [$rows[($start + 1):][] | select(.type == "assistant") | .message.content[]?
			| select(.type == "tool_use" and .name == "SendMessage")] | length' 2>/dev/null || echo 0)
	[ "${sent:-0}" -eq 0 ] || exit 0
fi

short=$(printf '%s' "$question" | tr '\n' ' ' | sed -E 's/[`*_#>]//g; s/\[([^]]*)\]\([^)]*\)/\1/g' | cut -c1-140)
cd "$cwd"
# shellcheck source=skills/run/scripts/roles.sh
. "$scripts/roles.sh"
want "$sid" asked "$(printf '%s\n%s\n%s\n%s' "$(date +%s)" "L'agente della issue $issue di $repo_short aspetta una risposta: $short" "$issue" "$short")"
