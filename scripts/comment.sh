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
#   dev | review | qa
#                the developer, the reviewer or the QA agent of that issue
#   "<address>"  a session by its address, as "dev #42", "review #42" or "qa #42"
#   "tech lead of <owner/name>"
#                from a tech lead only: ANOTHER repository's tech lead, who wrote on this repository's issue
#                (comment.sh --repo there), answered here: the header says "**tech lead → tech lead of
#                <owner/name>**", and a line with the comment's link goes to that tech lead's inbox (tell.sh
#                <owner/name> info), since its dispatcher does not read this repository
# Any other recipient is refused, and nothing is posted. The options may come anywhere among the arguments.
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
# The session's `commented` records it (session-dir.sh commented_on): a wake for a comment written to it
# before on that thread is not delivered; in a tech lead, only one by the user, or one by the one it writes to
# that had reached it already (delivered in a wake or listed by mentions.sh).
# Prints the comment's link; to another repository's tech lead, then what tell.sh prints.
set -eu

usage() {
	echo "usage: comment.sh <issue-or-pr> <you|\"tech lead\"|dev|review|qa|\"dev #<n>\"|\"review #<n>\"|\"qa #<n>\"|\"tech lead of <owner/name>\"> [--fyi] [--repo <owner/name>] <<'EOF' ... EOF" >&2
	exit 2
}
target="" to="" fyi="" elsewhere=""
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
	-*)
		echo "unknown option '$1'" >&2
		usage
		;;
	*)
		if [ -z "$target" ]; then
			target=$1
		elif [ -z "$to" ]; then
			to=$1
		else
			echo "one issue or pull request and one recipient: '$1' is one too many" >&2
			usage
		fi
		shift
		;;
	esac
done
[ -n "$target" ] && [ -n "$to" ] || usage
# Only a known address: anything else would post a header that wakes nobody.
case "$to" in
you | "tech lead" | dev | review | qa | "tech lead of "*) ;;
"dev #"[0-9]* | "review #"[0-9]* | "qa #"[0-9]*)
	case "${to#*#}" in *[!0-9]*)
		echo "unknown recipient '$to'" >&2
		usage
		;;
	esac
	;;
*)
	echo "unknown recipient '$to'" >&2
	usage
	;;
esac
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
role=$(jq -r '.role // ""' "$sessions_dir/$me/status" 2>/dev/null || true)
# The user talks only with the tech leads: no other session writes to them.
if [ "$to" = you ] && [ "$role" != tech-lead ]; then
	echo "the user talks only with the tech leads: write to the tech lead (comment.sh $target \"tech lead\"), who answers or brings it to the user" >&2
	exit 2
fi
# Another repository's tech lead, answered on this repository's issue: only by a tech lead, and only another
# repository's, named <owner>/<name>.
other=""
case "$to" in "tech lead of "*)
	other=${to#tech lead of }
	is_repo_name "$other" || {
		echo "unknown recipient '$to': another repository's tech lead is \"tech lead of <owner>/<name>\"" >&2
		usage
	}
	[ "$role" = tech-lead ] || {
		echo "only a tech lead writes to another repository's tech lead: write to your tech lead (comment.sh $target \"tech lead\")" >&2
		exit 2
	}
	[ "$(lower "$other")" != "$(lower "$repo_full")" ] || {
		echo "$repo_full is this repository: write to its tech lead with comment.sh $target \"tech lead\"" >&2
		exit 2
	}
	;;
esac

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
		rest_body "repos/$elsewhere/issues/$target/comments" --jq .html_url
	exit 0
fi

# The issue the target belongs to: the number itself, or the issue a pull request closes.
issue=$(thread_of "$target")

login=$(gh api user --jq .login)
case "$to" in
you) address="@$login" ;;
"tech lead") address="tech lead" ;;
dev | review | qa) address="$to #$issue" ;;
*) address=$to ;;
esac

marker=""
[ "$fyi" != --fyi ] || marker=" · fyi"
link=$(printf '**%s → %s**%s\n\n%s\n' "$from" "$address" "$marker" "$body" |
	rest_body "repos/$repo_full/issues/$target/comments" --jq .html_url)
echo "$link"
# Written on the thread, to them: a wake for what was written to the session there before it is not delivered
# (in a tech lead, for what the user wrote, or what they wrote that had reached it already).
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
# Another repository's dispatcher does not read this one: its tech lead hears of the answer in its inbox.
[ -z "$other" ] || printf 'Wrote to you on %s#%s%s: %s\n' "$repo_full" "$target" "$marker" "$link" | sh "$here/tell.sh" "$other" info
