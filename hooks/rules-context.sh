#!/bin/sh
# SessionStart after a compaction: the summary may lose the user's own rules, so they go back into the
# context of a tech lead, a developer or a QA agent. At start they come with the skill or the agent's brief.
#   rules-context.sh   (hook payload on stdin)
set -eu

# shellcheck source=hooks/common.sh
. "${CLAUDE_PLUGIN_ROOT:?}/hooks/common.sh"
[ "$(field source)" = compact ] || exit 0
case "$role" in tech-lead | dev | qa) ;; *) exit 0 ;; esac
cd "$cwd"
text=$(sh "$scripts/rules.sh" show --context 2>/dev/null || true)
[ -n "$text" ] || exit 0
jq -n --arg t "$text" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $t}}'
