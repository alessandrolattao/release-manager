#!/bin/sh
# Asks the user on an issue: posts the comment from stdin, adds the question label, moves the
# issue's agent (if any) to [ask], and calls the user out loud through TitTieS with the sentence.
#   ask.sh <issue-number> <release-manager-session-id> "<one spoken sentence: who and what for>" <<'EOF'
#   the comment: what is missing or what to decide, with the options
#   EOF
set -eu

issue=${1:?issue number}
manager=${2:?release-manager session id}
sentence=${3:?one spoken sentence}
here=$(cd "$(dirname "$0")" && pwd)
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
printf '%s\n' "$sentence" | sh "$here/titties.sh" call "$manager"
