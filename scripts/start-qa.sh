#!/bin/sh
# Starts the QA agent of a pull request whose issue carries the label qa, once its developer asked for it
# (qa.sh request): a background session "qa #<issue> · <repo>" in the main checkout, with briefs/qa.md.
# The dispatcher runs it.
#   start-qa.sh <issue> <pr>    (from the main checkout)
set -eu

issue=${1:?issue number}
pr=${2:?pull request number}
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
branch=$(gh pr view "$pr" --json headRefName --jq .headRefName)
brief=$(sed -e "s|{{ISSUE}}|$issue|g" -e "s|{{PR}}|$pr|g" -e "s|{{REPO}}|$repo_full|g" -e "s|{{ROOT}}|$root|g" \
	-e "s|{{BASE}}|$(base_branch)|g" -e "s|{{SCRIPTS}}|$here|g" "$here/../briefs/qa.md")

cd "$root"
name=$(qa_name "$issue")
id=$(launch "$name" "$brief")
sh "$here/role.sh" "$id" qa "$issue" "$branch" >/dev/null
status_set "$id" --argjson p "$pr" '.pr = $p'
# Taken: the dispatcher starts no other QA agent for this request.
record="$repo_dir/qa/$pr"
[ ! -f "$record" ] || sed -i '1s/^requested\t/testing\t/' "$record"
echo "started $name ($id)"
