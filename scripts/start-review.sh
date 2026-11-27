#!/bin/sh
# Starts the reviewer of an issue, once its developer asked for the code review (review.sh request): a
# background session "<repo> · review #<issue> · <title>" in the main checkout's folder, which it never takes,
# with briefs/reviewer.md, on the pushed head the request names. Each request gets a reviewer of its own.
# The dispatcher runs it.
#   start-review.sh <issue>    (from the main checkout)
set -eu

issue=${1:?issue number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# shellcheck source=scripts/launch.sh
. "$here/launch.sh"
# The reviewer reads the branch from the repository's remote: with none, nobody is started.
remote=$(repo_remote) || exit 1

for other in $(sessions_of review "$issue"); do
	if alive "$other" && [ "$(jq -r .state "$sessions_dir/$other/status")" != done ]; then
		echo "issue $issue already has a reviewer" >&2
		exit 1
	fi
done
record="$repo_dir/review/$issue"
[ "$(cut -f1 "$record" 2>/dev/null || true)" = requested ] || {
	echo "no code review of issue $issue is asked for" >&2
	exit 1
}
head=$(cut -f2 "$record")
branch=$(cut -f5 "$record")
[ -n "$head" ] && [ -n "$branch" ] || {
	echo "the code review request of issue $issue names no head or branch" >&2
	exit 1
}
brief=$(sed -e "s|{{ISSUE}}|$issue|g" -e "s|{{BRANCH}}|$branch|g" -e "s|{{HEAD}}|$head|g" -e "s|{{REPO}}|$repo_full|g" \
	-e "s|{{ROOT}}|$root|g" -e "s|{{BASE}}|$(base_branch)|g" -e "s|{{REMOTE}}|$remote|g" -e "s|{{SCRIPTS}}|$here|g" \
	"$here/../briefs/reviewer.md")

cd "$root"
name=$(review_name "$issue" "$(gh issue view "$issue" --json title --jq .title 2>/dev/null || true)" "in progress")
# Taken just before the launch: the reviewer reads the issue with all its comments after it, so none written
# before wakes it (role.sh, dispatch.sh).
started=$(date +%s)
id=$(launch "$name" "$brief")
sh "$here/role.sh" "$id" review "$issue" "$branch" "$started" >/dev/null
# The head it reads, which review.sh pass records: a newer request does not move it.
status_set "$id" --arg h "$head" '.head = $h'
# Taken: the dispatcher starts no other reviewer for this request.
sed -i '1s/^requested\t/reviewing\t/' "$record"
echo "started $name ($id)"
