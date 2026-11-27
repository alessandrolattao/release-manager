#!/bin/sh
# The comments of this repository written to this tech lead in the last days that it has not answered yet:
# it has not written to their asker ("**tech lead → <asker>**", news or not; to another repository's tech lead,
# comment.sh <n> "tech lead of <owner/name>") on the same thread since the comment reached it. An issue and the pull requests that close it are one thread: a question asked on either
# is answered on either. News (" · fyi") owes no answer and is left out. The plugin brings the tech lead each
# one as it arrives, in a wake or in a note carried into its conversation; this is the list to look at again (at
# the start, after a restart, before saying all is done). Only the team's own account counts, as for the
# dispatcher.
# A comment reaches the tech lead when the plugin delivers it in a wake, when a request of its conversation
# carries the note that holds it (hooks/sessions.tsx), or when this list prints it: each one is then recorded,
# one line `<time> <link>` of the repository's `seen`, shared by the successive tech lead sessions on this
# machine. One never seen is always listed, whatever was written to its asker since; one older than the first
# line of `seen`, written before anything was recorded, is answered by any later write to its asker on its
# thread.
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
seen_file="$repo_dir/seen"

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

# When each comment first reached the tech lead, by link, and when the record starts (null with no record).
seen='{"first": null, "at": {}}'
[ ! -f "$seen_file" ] || seen=$(jq -Rn '[inputs | split("\t") | select(length >= 2 and (.[0] | test("^[0-9]+$"))) | {at: (.[0] | tonumber), link: .[1]}]
	| {first: (.[0].at // null), at: (reduce .[] as $s ({}; if has($s.link) then . else . + {($s.link): $s.at} end))}' "$seen_file")

waiting=$(printf '%s\n' "$comments" | jq -c --arg me "$mine" --argjson thread "$threads" --argjson seen "$seen" '
	map(. + {thread: ($thread[.issue] // .issue)}) as $all
	| [$all[] | select(.to == $me and .fyi == null) | . as $c
		| [$all[] | select(.thread == $c.thread and .from == $me and .to == $c.from)] as $writes
		| ($seen.at[$c.link]) as $at
		| select(
			if $at != null then [$writes[] | select((.created | fromdateiso8601) > $at)] | length == 0
			elif $seen.first != null and ($c.created | fromdateiso8601) >= $seen.first then true
			else [$writes[] | select(.created > $c.created)] | length == 0 end)]')

if [ "$(printf '%s\n' "$waiting" | jq length)" = 0 ]; then
	echo "nothing waits for $mine"
	exit 0
fi
printf '%s\n' "$waiting" | jq -r '.[] | "#\(.issue) · \(.from) · \(.created[0:16] | sub("T"; " ")) · \(.text) · \(.link)"'
# Printed in the tech lead's turn: it has reached the tech lead.
printf '%s\n' "$waiting" | jq -r --arg now "$(date +%s)" '.[] | "\($now)\t\(.link)"' >>"$seen_file"
