#!/bin/sh
# SessionStart after a compaction: the summary may lose the user's standing rules, so they go back into the
# context of a release manager, a planner or a developer agent. At start they come with the skill or the
# agent's brief.
#   rules-context.sh   (hook payload on stdin)
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
[ "$(field source)" = compact ] || exit 0
# shellcheck source=skills/run/scripts/session-dir.sh
. "$scripts/session-dir.sh"
if [ -z "$(cat "$sessions_dir/$sid/role" 2>/dev/null || true)" ]; then
	[ -n "$(agent_issue)" ] || exit 0
fi
cd "$cwd"
text=$(sh "$scripts/rules.sh" show --context 2>/dev/null || true)
[ -n "$text" ] || exit 0
jq -n --arg t "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $t}}'
