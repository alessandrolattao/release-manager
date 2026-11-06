#!/bin/sh
# Asks the user on an issue: posts the comment from stdin, adds the question label, moves the
# issue's agent (if any) to [ask], updates the planner's 🙋 counter and has the planner say it out loud.
#   ask.sh <issue-number> "<one spoken sentence: who and what for>" <<'EOF'
#   the comment: what is missing or what to decide, with the options
#   EOF
set -eu

issue=${1:?issue number}
sentence=${2:?one spoken sentence}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
body=$(cat)
[ -n "$body" ] || {
	echo "nothing to ask: the comment comes on stdin" >&2
	exit 2
}
gh label list --limit 200 --json name --jq '.[].name' | grep -qx question ||
	gh label create question --description "Waiting for an answer from the assignee" >/dev/null
printf '%s\n' "$body" | gh issue comment "$issue" --body-file - >/dev/null
gh issue edit "$issue" --add-label question >/dev/null
echo "issue $issue: question asked"

branch=$(claude agents --json 2>/dev/null | jq -r --arg n "$issue" \
	'[.[] | (.name // "") | select(test("^\\[[a-z]+\\][^ ]* " + $n + "-")) | sub("^\\[[a-z]+\\][^ ]* "; "")][0] // empty')
if [ -n "$branch" ]; then
	sh "$here/set-state.sh" "$branch" ask
fi

# The planner is the one who talks to the user: its counter goes up and it says the sentence.
# The details go to the planner's inbox, to read when its current topic is over.
{
	printf 'Issue #%s needs the user: %s\n\n' "$issue" "$sentence"
	printf '%s\n' "$body"
} | sh "$here/tell.sh" planner question >/dev/null 2>&1 || true
planner=$(session_of "$planner_prefix")
if [ -z "$planner" ]; then
	echo "no planner running for $repo_short: the question waits on GitHub"
	exit 0
fi
sh "$here/sync-names.sh" planner "$(printf '%s' "$planner" | cut -f1)" >/dev/null 2>&1 || true
printf '%s\n' "$sentence" | sh "$here/titties.sh" call "$(printf '%s' "$planner" | cut -f1)"
