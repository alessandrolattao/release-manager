#!/bin/sh
# Starts the QA agent of an issue that carries the label qa, once its developer asked for it (qa.sh request):
# a background session "<repo> · qa #<issue> · <title>" in the main checkout, with briefs/qa.md, on the
# developer's branch the request names. There is no pull request yet: it opens once QA passed.
# The dispatcher runs it.
#   start-qa.sh <issue>    (from the main checkout)
set -eu

issue=${1:?issue number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# shellcheck source=scripts/launch.sh
. "$here/launch.sh"

for other in $(sessions_of qa "$issue"); do
	if alive "$other" && [ "$(jq -r .state "$sessions_dir/$other/status")" != done ]; then
		echo "issue $issue already has a QA agent" >&2
		exit 1
	fi
done
record="$repo_dir/qa/$issue"
branch=$(cut -f5 "$record" 2>/dev/null || true)
[ -n "$branch" ] || {
	echo "the QA request of issue $issue names no branch" >&2
	exit 1
}
brief=$(sed -e "s|{{ISSUE}}|$issue|g" -e "s|{{BRANCH}}|$branch|g" -e "s|{{REPO}}|$repo_full|g" -e "s|{{ROOT}}|$root|g" \
	-e "s|{{BASE}}|$(base_branch)|g" -e "s|{{SCRIPTS}}|$here|g" "$here/../briefs/qa.md")

cd "$root"
name=$(qa_name "$issue" "$(gh issue view "$issue" --json title --jq .title 2>/dev/null || true)" "in progress")
# Taken just before the launch: the QA agent reads the issue with all its comments after it, so none written
# before wakes it (role.sh, dispatch.sh).
started=$(date +%s)
id=$(launch "$name" "$brief")
sh "$here/role.sh" "$id" qa "$issue" "$branch" "$started" >/dev/null
# Taken: the dispatcher starts no other QA agent for this request.
sed -i '1s/^requested\t/testing\t/' "$record"
echo "started $name ($id)"
