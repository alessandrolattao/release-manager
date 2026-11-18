#!/bin/sh
# Moves an agent's tag without the model, after a tool call in its own session:
# - from [ask] to [dev] as soon as it edits a file or commits, wherever the user answered it (its own
#   chat included), and reminds it to tell the planner what was decided;
# - `gh pr create` that printed a pull request URL, from [dev] or [fix], to [review];
# - a successful `git push` from [fix] to [review] (the fixes are up, CI and reviews run again).
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
# shellcheck source=skills/run/scripts/session-dir.sh
. "$scripts/session-dir.sh"

# working: this call changed the agent's work. Agents live under .claude/worktrees: any other session
# stops here, without reading its transcript at every edit.
working=no
case "$cwd" in
*/.claude/worktrees/*)
	case "$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)" in
	Edit | Write | MultiEdit | NotebookEdit) working=yes ;;
	Bash)
		if printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null |
			grep -q -E '(^|[[:space:];&|(])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+commit([[:space:]]|$)' &&
			! printf '%s' "$payload" | jq -r '.tool_response | tostring' 2>/dev/null |
				grep -q -E 'nothing to commit|nothing added to commit|no changes added to commit'; then
			working=yes
		fi
		;;
	esac
	;;
esac
if [ "$working" = no ]; then
	case "$payload" in
	*"gh pr create"* | *"git push"*) ;;
	*) exit 0 ;;
	esac
fi

# The last name asked first: a rename shows only when the turn ends, and until then the transcript
# still holds the old tag.
name=$(cat "$sessions_dir/$sid/name" 2>/dev/null || true)
[ -n "$name" ] || name=$(session_name)
case "$name" in
"[ask]"*)
	[ "$working" = yes ] || exit 0
	branch=${name#* }
	cd "$cwd"
	sh "$scripts/set-state.sh" "$branch" dev >/dev/null 2>&1
	issue=${branch%%-*}
	note="This agent is working again, so its tag moved from [ask] to [dev]. Issue #$issue keeps its question label until the planner knows the outcome. When the user answered in this chat, the planner is told on stdin of: sh \"$scripts/tell.sh\" planner info --from \"agent of #$issue\". The message starts with \"question closed on issue #$issue:\" and says what was decided."
	jq -n --arg note "$note" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $note}}'
	exit 0
	;;
"[dev]"* | "[fix]"*) ;;
*) exit 0 ;;
esac

case "$payload" in
*"gh pr create"* | *"git push"*) ;;
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
