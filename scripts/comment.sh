#!/bin/sh
# Writes where the team talks: a comment on an issue or a pull request of this repository. Its first line
# says who writes to whom, so the plugin wakes the right session; the same GitHub account writes for every
# session, so the line is the signature.
#   comment.sh <issue-or-pr> <to> [--fyi] <<'EOF'
#   the message, in the issue's language
#   EOF
# <to>:
#   you          the user, from a tech lead only: a real @mention (GitHub notifies them), the label
#                question on the issue. The user talks only with the tech leads: other sessions ask a tech lead.
#   tech lead    the repository's tech lead
#   dev | qa     the developer or the QA agent of that issue
#   "<address>"  a session by its address, as "dev #42" or "qa #42"
# Your state follows: waiting on the user (yellow) or on another session (purple), until an answer wakes you.
# The status records whom you wait on (waits_on: the address, or "the user"): their comment ends the wait.
#   --fyi        a reply or a piece of news: nobody owes you an answer, your state does not change, and the
#                header says so ("**dev #42 → tech lead** · fyi")
# The session's `commented` records it (session-dir.sh commented_on): a wake for a comment written to it
# before, by the one it writes to or by the user, is not delivered.
# Prints the comment's link.
set -eu

target=${1:?issue or pull request number}
to=${2:?you, tech lead, dev, qa or an address}
fyi=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# shellcheck source=scripts/rest.sh
. "$here/rest.sh"
body=$(cat)
[ -n "$body" ] || {
	echo "the message comes on stdin" >&2
	exit 2
}
me=${CLAUDE_CODE_SESSION_ID:-}
from=$(address_of "$me")
# The user talks only with the tech leads: no other session writes to them.
if [ "$to" = you ] && [ "$(jq -r '.role // ""' "$sessions_dir/$me/status" 2>/dev/null)" != tech-lead ]; then
	echo "the user talks only with the tech leads: write to the tech lead (comment.sh $target \"tech lead\"), who answers or brings it to the user" >&2
	exit 2
fi

# The issue the target belongs to: the number itself, or the issue a pull request closes.
issue=$(thread_of "$target")

login=$(gh api user --jq .login)
case "$to" in
you) address="@$login" ;;
"tech lead") address="tech lead" ;;
dev | qa) address="$to #$issue" ;;
*) address=$to ;;
esac

marker=""
[ "$fyi" != --fyi ] || marker=" · fyi"
link=$(printf '**%s → %s**%s\n\n%s\n' "$from" "$address" "$marker" "$body" |
	rest_body "repos/$repo_full/issues/$target/comments" --jq .html_url)
echo "$link"
# Written on the thread, to them: a wake for what they wrote before it is not delivered.
commented_on "$me" "$issue" "$address"

first=$(printf '%s\n' "$body" | sed '/^[[:space:]]*$/d' | head -1)
if [ "$to" = you ]; then
	gh label list --limit 200 --json name --jq '.[].name' | grep -qx question ||
		rest "repos/$repo_full/labels" -f name=question -f color=d876e3 -f description="Waiting for an answer from the assignee" >/dev/null
	rest "repos/$repo_full/issues/$issue/labels" -f "labels[]=question" >/dev/null 2>&1 || true
fi
[ -z "$me" ] || [ "$fyi" = --fyi ] || {
	if [ "$to" = you ]; then
		state_set "$me" you "$first"
		# Asked on GitHub, so the answer comes on GitHub: the plugin wakes the session with it.
		status_set "$me" --argjson n "$issue" '.asked_on = $n | .waits_on = "the user"'
	else
		state_set "$me" others "waits for $address: $first"
		status_set "$me" --arg w "$address" '.waits_on = $w'
	fi
}
