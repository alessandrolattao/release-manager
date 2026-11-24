#!/bin/sh
# Reports a problem of the team plugin itself, as an issue on the plugin's own repository: a script that
# failed in a way it should not, a step that left a session stuck, a rule of the flow that did not fit.
# The plugin's repository is public and the projects are not, so the report describes the plugin only:
# no project or company name, no code, path, issue text, secret or link of the project, nothing the user
# said in their words. Say what was expected, what happened, which script or step, and how to see it again.
# An open report with the same title gets a comment instead of a second issue.
#   report.sh "<title: what went wrong, in English>" <<'EOF'
#   <what was expected, what happened, which script or step, how to see it again>
#   EOF
set -eu

title=${1:?title}
here=$(cd "$(dirname "$0")" && pwd)
body=$(cat)
[ -n "$body" ] || {
	echo "the report comes on stdin" >&2
	exit 2
}
plugin=$(jq -r '.repository // empty' "$here/../.claude-plugin/plugin.json" | sed -E 's#^https?://github\.com/##; s#\.git$##')
[ -n "$plugin" ] || {
	echo "the plugin's repository is not in plugin.json" >&2
	exit 1
}
version=$(jq -r '.version // "?"' "$here/../.claude-plugin/plugin.json")
role=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/team/sessions/${CLAUDE_CODE_SESSION_ID:-none}/role" 2>/dev/null || echo "?")

same=$(gh issue list -R "$plugin" --state open --label flow-report --limit 100 --json number,title 2>/dev/null |
	jq -r --arg t "$title" '.[] | select((.title | ascii_downcase) == ($t | ascii_downcase)) | .number' 2>/dev/null | head -1 || true)
note=$(printf '%s\n\n_Reported by a %s session, plugin %s._\n' "$body" "$role" "$version")
if [ -n "$same" ]; then
	printf '%s\n' "$note" | gh issue comment "$same" -R "$plugin" --body-file -
	exit 0
fi
gh label list -R "$plugin" --limit 200 --json name --jq '.[].name' | grep -qx flow-report ||
	gh label create flow-report -R "$plugin" --description "A problem a session met in the plugin's flow" >/dev/null
printf '%s\n' "$note" | gh issue create -R "$plugin" --title "$title" --label flow-report --body-file -
