#!/bin/sh
# Which machine works on an issue, decided on GitHub, so two machines never start a developer on the same
# one. A machine takes an issue with a comment; 30 seconds later the oldest take still standing wins (a
# release ends every take before it). The winner sets the issue In progress; a loser deletes its own take.
# Every machine reads the same comments, so they all agree on the winner.
#   claim.sh take <issue>               exit 0 when this machine has it, 1 when another one does (said)
#   claim.sh release <issue> "<why>"    ends the takes: the issue is Todo and free again (a takeover)
#   claim.sh who <issue>                the machine that has it, or nothing
#   claim.sh host                       this machine's name in the takes
# The first lines of these comments are a contract between machines and versions: only ever extended.
#   **dispatcher · <host>** takes #<n>
#   **<who>** releases #<n>
set -eu

action=${1:?take, release, who or host}
issue=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# The machine: its host name, which several installs may share ("fedora"), and the start of its machine id,
# which they do not.
host=$( (hostname -s 2>/dev/null || hostname) | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-' | head -1)
machine=$(cut -c1-4 /etc/machine-id 2>/dev/null || true)
host="$host${machine:+-$machine}"
WAIT=${CLAIM_WAIT:-30}

# takes: the takes of the issue still standing, oldest first, as "<comment id> <host>". Only the team's own
# account counts, as for the dispatcher.
takes() {
	login=$(gh api user --jq .login)
	gh api --paginate "repos/$repo_full/issues/$issue/comments?per_page=100" | jq -s 'add // []' |
		jq -r --arg login "$login" --arg n "$issue" '
			[.[] | select(.user.login == $login) | {id, first: ((.body | gsub("\r"; "") | split("\n"))[0] // "")}]
			| sort_by(.id) as $all
			| ([$all[] | select(.first | test("^\\*\\*.*\\*\\* releases #" + $n + "$")) | .id] | max // 0) as $since
			| $all[] | select(.id > $since)
			| (.first | capture("^\\*\\*dispatcher · (?<host>[a-z0-9-]+)\\*\\* takes #" + $n + "$")? // null) as $c
			| select($c != null) | "\(.id) \($c.host)"'
}

case "$action" in
host)
	echo "$host"
	;;
who)
	takes | head -1 | cut -d' ' -f2
	;;
take)
	[ -n "$issue" ] || {
		echo "usage: claim.sh take <issue>" >&2
		exit 2
	}
	first=$(takes | head -1)
	if [ -n "$first" ]; then
		if [ "${first#* }" = "$host" ]; then
			echo "issue $issue: already taken by this machine ($host)"
			exit 0
		fi
		echo "issue $issue: taken by ${first#* }"
		exit 1
	fi
	link=$(printf '**dispatcher · %s** takes #%s\n\nA developer starts on %s, unless another machine took the issue first.\n' \
		"$host" "$issue" "$host" | gh issue comment "$issue" --body-file -)
	mine=${link##*-}
	sleep "$WAIT"
	first=$(takes | head -1)
	if [ "${first#* }" = "$host" ]; then
		sh "$here/issue-status.sh" "$issue" in_progress >/dev/null 2>&1 || true
		echo "issue $issue: taken by this machine ($host)"
		exit 0
	fi
	gh api -X DELETE "repos/$repo_full/issues/comments/$mine" >/dev/null 2>&1 || true
	echo "issue $issue: taken by ${first#* }"
	exit 1
	;;
release)
	why=${3:?why the issue is released}
	who=$(address_of "${CLAUDE_CODE_SESSION_ID:-}")
	[ "$who" != team ] || who="dispatcher · $host"
	printf '**%s** releases #%s\n\n%s\n' "$who" "$issue" "$why" | gh issue comment "$issue" --body-file - >/dev/null
	sh "$here/issue-status.sh" "$issue" todo >/dev/null 2>&1 || true
	echo "issue $issue: released, Todo again"
	;;
*)
	echo "usage: claim.sh take|release|who <issue> | host" >&2
	exit 2
	;;
esac
