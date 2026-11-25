#!/bin/sh
# The comments of this repository written to this tech lead in the last days that it has not answered yet:
# it has not written to their asker since ("**tech lead → <asker>**", news or not) on the same thread. An
# issue and the pull requests that close it are one thread: a question asked on either is answered on either.
# News (" · fyi") owes no answer and is left out. The plugin wakes the tech lead with each one as
# it arrives; this is the list to look at again (at the start, after a restart, before saying all is done).
# Only the team's own account counts, as for the dispatcher.
#   mentions.sh [days]    (default 7; from a tech lead session)
set -eu

days=${1:-7}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
me=${CLAUDE_CODE_SESSION_ID:?run it from the tech lead session}
mine=$(address_of "$me")
login=$(gh api user --jq .login)
since=$(date -u -d "-$days days" +%Y-%m-%dT%H:%M:%SZ)

comments=$(gh api --paginate "repos/$repo_full/issues/comments?since=$since&per_page=100" | jq -s 'add // []' |
	jq -c --arg login "$login" '
		[.[] | select(.user.login == $login)
			| ((.body | gsub("\r"; "") | split("\n") | map(select(length > 0))) as $l
				| {created: .created_at, issue: (.issue_url | split("/") | last), link: .html_url, text: ($l[1] // "")}
				+ (($l[0] // "") | capture("^\\*\\*(?<from>.*) → (?<to>.*)\\*\\*(?<fyi> · fyi)?$") // {from: null, to: null, fyi: null}))]')

# The thread of each issue or pull request the tech lead was written to or wrote on: the issue a pull request
# closes, or the number itself.
threads=$(printf '%s\n' "$comments" | jq -r --arg me "$mine" '.[] | select(.to == $me or .from == $me) | "\(.issue) \(.link)"' |
	sort -u -k1,1 | while read -r n link; do printf '%s %s\n' "$n" "$(issue_of "$n" "$link")"; done |
	jq -Rn '[inputs | split(" ") | {(.[0]): .[1]}] | add // {}')

printf '%s\n' "$comments" | jq -r --arg me "$mine" --argjson thread "$threads" '
	map(. + {thread: ($thread[.issue] // .issue)}) as $all
	| [$all[] | select(.to == $me and .fyi == null) | . as $c
		| select([$all[] | select(.thread == $c.thread and .from == $me and .to == $c.from and .created > $c.created)] | length == 0)]
	| if length == 0 then "nothing waits for \($me)"
		else .[] | "#\(.issue) · \(.from) · \(.created[0:16] | sub("T"; " ")) · \(.text) · \(.link)" end'
