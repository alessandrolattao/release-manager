#!/bin/sh
# The comments of this repository written to this tech lead in the last days that it has not answered yet:
# no comment of its own came after them on the same issue. The plugin wakes the tech lead with each one as
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

gh api --paginate "repos/$repo_full/issues/comments?since=$since&per_page=100" | jq -s 'add // []' |
	jq -r --arg me "$mine" --arg login "$login" '
		[.[] | select(.user.login == $login)
			| ((.body | gsub("\r"; "") | split("\n") | map(select(length > 0))) as $l
				| {created: .created_at, issue: (.issue_url | split("/") | last), link: .html_url, text: ($l[1] // "")}
				+ (($l[0] // "") | capture("^\\*\\*(?<from>.*) → (?<to>.*)\\*\\*$") // {from: null, to: null}))] as $all
		| [$all[] | select(.to == $me) | . as $c
			| select([$all[] | select(.issue == $c.issue and .from == $me and .created > $c.created)] | length == 0)]
		| if length == 0 then "nothing waits for \($me)"
			else .[] | "#\(.issue) · \(.from) · \(.created[0:16] | sub("T"; " ")) · \(.text) · \(.link)" end'
