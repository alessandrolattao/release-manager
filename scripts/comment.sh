#!/bin/sh
# Writes where the team talks: a comment on an issue or a pull request of this repository. Its first line
# says who writes to whom, so the plugin wakes the right session; the same GitHub account writes for every
# session, so the line is the signature.
#   comment.sh <issue-or-pr> <to> [--fyi] [--repo <owner/name>] <<'EOF'
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
#   --repo <owner/name>
#                on ANOTHER repository, from a tech lead only, to that repository's tech lead only: the header
#                says "**tech lead of <this repository> → tech lead**" and a hidden last line signs it
#                (`<!-- team · tech lead of <this repository> -->`), so its dispatcher wakes its tech lead. Your
#                state does not change, as with --fyi: the answer comes on a repository this one's dispatcher
#                does not read.
# Prints the comment's link.
set -eu

target=${1:?issue or pull request number}
to=${2:?you, tech lead, dev, qa or an address}
shift 2
fyi="" elsewhere=""
while [ $# -gt 0 ]; do
	case "$1" in
	--fyi)
		fyi=--fyi
		shift
		;;
	--repo)
		elsewhere=${2:?owner/name of the other repository}
		shift 2
		;;
	*)
		echo "unknown option '$1'" >&2
		exit 2
		;;
	esac
done
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
role=$(jq -r '.role // ""' "$sessions_dir/$me/status" 2>/dev/null || true)
# The user talks only with the tech leads: no other session writes to them.
if [ "$to" = you ] && [ "$role" != tech-lead ]; then
	echo "the user talks only with the tech leads: write to the tech lead (comment.sh $target \"tech lead\"), who answers or brings it to the user" >&2
	exit 2
fi

# Another repository: only its tech lead is written to, only by a tech lead, signed with this repository.
if [ -n "$elsewhere" ]; then
	may_write_elsewhere "$me" "$elsewhere"
	[ "$to" = "tech lead" ] || {
		echo "on another repository you write to its tech lead only: comment.sh $target \"tech lead\" --repo $elsewhere" >&2
		exit 2
	}
	marker=""
	[ "$fyi" != --fyi ] || marker=" · fyi"
	printf '**%s → tech lead**%s\n\n%s\n\n<!-- team · %s -->\n' "$signer_elsewhere" "$marker" "$body" "$signer_elsewhere" |
		gh issue comment "$target" -R "$elsewhere" --body-file -
	exit 0
fi

# The issue the target belongs to: the number itself, or the issue a pull request closes.
issue=$target
if gh pr view "$target" --json number >/dev/null 2>&1; then
	issue=$(gh pr view "$target" --json closingIssuesReferences --jq '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)
	[ -n "$issue" ] || issue=$target
fi

login=$(gh api user --jq .login)
case "$to" in
you) address="@$login" ;;
"tech lead") address="tech lead" ;;
dev | qa) address="$to #$issue" ;;
*) address=$to ;;
esac

marker=""
[ "$fyi" != --fyi ] || marker=" · fyi"
link=$(printf '**%s → %s**%s\n\n%s\n' "$from" "$address" "$marker" "$body" | gh issue comment "$target" --body-file -)
echo "$link"

first=$(printf '%s\n' "$body" | sed '/^[[:space:]]*$/d' | head -1)
if [ "$to" = you ]; then
	gh label list --limit 200 --json name --jq '.[].name' | grep -qx question ||
		gh label create question --description "Waiting for an answer from the assignee" >/dev/null
	gh issue edit "$issue" --add-label question >/dev/null 2>&1 || true
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
