#!/bin/sh
# Writes where the team talks: a comment on an issue or a pull request of this repository. Its first line
# says who writes to whom, so the plugin wakes the right session; the same GitHub account writes for every
# session, so the line is the signature.
#   comment.sh <issue-or-pr> <to> [--fyi] <<'EOF'
#   the message, in the issue's language
#   EOF
# <to>:
#   you          the user: a real @mention (GitHub notifies them), the label question on the issue
#   tech lead    the tech lead who follows the issue (follow.sh), or any tech lead
#   dev | qa     the developer or the QA agent of that issue
#   "<address>"  a session by its address, as "tech lead admin-app" or "dev #42"
# Your state follows: waiting on the user (yellow) or on another session (purple), until an answer wakes you.
#   --fyi        a reply or a piece of news: nobody owes you an answer, your state does not change
# Prints the comment's link.
set -eu

target=${1:?issue or pull request number}
to=${2:?you, tech lead, dev, qa or an address}
fyi=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
body=$(cat)
[ -n "$body" ] || {
	echo "the message comes on stdin" >&2
	exit 2
}
me=${CLAUDE_CODE_SESSION_ID:-}
from=$(address_of "$me")

# The issue the target belongs to: the number itself, or the issue a pull request closes.
issue=$target
if gh pr view "$target" --json number >/dev/null 2>&1; then
	issue=$(gh pr view "$target" --json closingIssuesReferences --jq '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)
	[ -n "$issue" ] || issue=$target
fi

login=$(gh api user --jq .login)
case "$to" in
you) address="@$login" ;;
"tech lead") address=$(follower_of "$issue") ;;
dev | qa) address="$to #$issue" ;;
*) address=$to ;;
esac

link=$(printf '**%s → %s**\n\n%s\n' "$from" "$address" "$body" | gh issue comment "$target" --body-file -)
echo "$link"

first=$(printf '%s\n' "$body" | sed '/^[[:space:]]*$/d' | head -1 | cut -c1-100)
if [ "$to" = you ]; then
	gh label list --limit 200 --json name --jq '.[].name' | grep -qx question ||
		gh label create question --description "Waiting for an answer from the assignee" >/dev/null
	gh issue edit "$issue" --add-label question >/dev/null 2>&1 || true
fi
[ -z "$me" ] || [ "$fyi" = --fyi ] || {
	if [ "$to" = you ]; then
		state_set "$me" you "$first"
		# Asked on GitHub, so the answer comes on GitHub: the plugin wakes the session with it.
		status_set "$me" --argjson n "$issue" '.asked_on = $n'
	else
		state_set "$me" others "waits for $address: $first"
	fi
}
