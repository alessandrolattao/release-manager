#!/bin/sh
# Stop: a team session ended its turn asking something in its own chat (a "needs input:" line, a last line
# that asks, or a request for a go-ahead written without a question mark).
#   - a tech lead asks the user, who talks to it: its state becomes "waits on you" (yellow);
#   - a developer or QA agent asks in a chat nobody reads (the user talks only with the tech leads): the
#     question is recorded, its state becomes "waits on others", and the dispatcher turns it into a comment
#     to the repository's tech lead.
# A turn that asked on GitHub (comment.sh) or that asks nothing changes nothing here.
#   asks.sh   (hook payload on stdin)
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
case "$role" in tech-lead | dev | qa) ;; *) exit 0 ;; esac
record="$sessions_dir/$sid/asked"
rm -f "$record" "$record.told"

text=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)
[ -n "$text" ] || exit 0
question=$(printf '%s\n' "$text" | sed -n 's/^needs input:[[:space:]]*//p' | tail -1)
if [ -z "$question" ]; then
	last=$(printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | tail -1)
	if printf '%s\n' "$last" | grep -q -i -E "\?([[:space:]]|$)|se mi dai l.ok|dammi l.ok|dimmi |fammi sapere|(aspetto|attendo) (te|il tuo|la tua|una risposta|conferma|istruzioni)|vuoi che|posso procedere|confermi|let me know|tell me |should i |do you want|waiting for (you|your)|your call|(^|[^a-z])ok to "; then
		question=$last
	fi
fi
[ -n "$question" ] || exit 0
short=$(printf '%s' "$question" | tr '\n' ' ' | sed -E 's/[`*_#>]//g; s/\[([^]]*)\]\([^)]*\)/\1/g')

# Asked on GitHub in this very turn: the comment already says it, and comment.sh set the state.
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
	asked_on_github=$(tail -n 300 "$transcript" | jq -s '
		[.[] | select(.type == "user" or .type == "assistant")] as $rows
		| ([$rows | to_entries[]
			| select(.value.type == "user" and (.value.isMeta | not)
				and ((.value.message.content | type) == "string" or any(.value.message.content[]?; .type == "text")))
			| .key] | last // -1) as $start
		| [$rows[($start + 1):][] | select(.type == "assistant") | .message.content[]?
			| select(.type == "tool_use" and .name == "Bash" and ((.input.command // "") | test("comment\\.sh")))] | length' 2>/dev/null || echo 0)
	[ "${asked_on_github:-0}" -eq 0 ] || exit 0
fi

if [ "$role" = tech-lead ]; then
	state_set "$sid" you "$short"
	# Asked in its own chat: the user answers it there, not on GitHub.
	status_set "$sid" 'del(.asked_on)'
else
	# An agent never waits on the user: the dispatcher hands the question to the tech lead at once.
	state_set "$sid" others "asks the tech lead: $short"
	rm -f "$sessions_dir/$sid/asked.told"
	want "$sid" asked "$(printf '%s\n%s\n%s\n%s' "$(date +%s)" "$short" "$(jq -r '.issue // ""' "$sessions_dir/$sid/status")" "$short")"
fi
