#!/bin/sh
# Reports a problem of the team plugin itself, as an issue on the plugin's own repository: a script that
# failed in a way it should not, a step that left a session stuck, a rule of the flow that did not fit.
# The plugin's repository is public and the projects are not, so the report describes the plugin only:
# no project or company name, no code, path, issue text, secret or link of the project, nothing the user
# said in their words. Say what was expected, what happened, which script or step, and how to see it again.
# An open report with the same title gets a comment instead of a second issue. Both go out with the user's
# GitHub account, so both end with the hidden line note.sh signs with (`<!-- team · <address> -->`): the
# plugin repository's dispatcher then knows they are not the user's.
#   report.sh "<title: what went wrong, in English>" <<'EOF'
#   <what was expected, what happened, which script or step, how to see it again>
#   EOF
set -eu

title=${1:?title}
here=$(cd "$(dirname "$0")" && pwd)
# It runs from any folder, so the session comes from session-dir.sh, not repo.sh (which needs a repository).
# shellcheck source=scripts/session-dir.sh
. "$here/session-dir.sh"
# shellcheck source=scripts/rest.sh
. "$here/rest.sh"
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
me=${CLAUDE_CODE_SESSION_ID:-none}
role=$(cat "$sessions_dir/$me/role" 2>/dev/null || echo "?")
# The session's address, as repo.sh's address_of computes it.
from=$(jq -r 'if .role == "tech-lead" then "tech lead"
	elif .role == "dev" or .role == "qa" then .role + " #" + (.issue | tostring)
	elif .role == "spike" then "spike " + (.topic // "")
	else "team" end' "$sessions_dir/$me/status" 2>/dev/null || echo team)

# The REST listing, not `gh issue list --label`: that one goes through the search index, which misses an
# issue opened seconds earlier. The REST listing counts pull requests among the issues: they are no reports.
same=$(gh api "repos/$plugin/issues?labels=flow-report&state=open&per_page=100" 2>/dev/null |
	jq -r --arg t "$title" '.[] | select(.pull_request | not) | select((.title | ascii_downcase) == ($t | ascii_downcase)) | .number' 2>/dev/null | head -1 || true)
note=$(printf '%s\n\n_Reported by a %s session, plugin %s._\n\n<!-- team · %s -->\n' "$body" "$role" "$version" "$from")
if [ -n "$same" ]; then
	printf '%s\n' "$note" | rest_body "repos/$plugin/issues/$same/comments" --jq .html_url
	exit 0
fi
gh label list -R "$plugin" --limit 200 --json name --jq '.[].name' | grep -qx flow-report ||
	rest "repos/$plugin/labels" -f name=flow-report -f color=d73a4a -f description="A problem a session met in the plugin's flow" >/dev/null
printf '%s\n' "$note" | rest_body "repos/$plugin/issues" -f title="$title" -f "labels[]=flow-report" --jq .html_url
