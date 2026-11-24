#!/bin/sh
# After a developer merges: follows the CI and deploy runs of its merge commit until they finish, so it knows
# whether its change is deployed. It opens nothing and stops nobody: the default branch goes red for many
# reasons, most of them someone else's. When it is red the developer reads the failed runs: its own failure
# it fixes, and tells the tech lead; anyone else's it tells the tech lead, and its work is over.
#   main-ci.sh <pr> [--wait]   the runs of the pull request's merge commit; --wait: until they all end (45 min)
# Every workflow that runs on the commit counts; a cancelled one (superseded by a newer commit) does not, and
# when all of them were, the newest commit of the default branch, which holds the change, is followed instead.
set -eu

pr=${1:?pull request number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
base=$(base_branch)
sha=$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // empty')
[ -n "$sha" ] || {
	echo "#$pr is not merged"
	exit 1
}

runs() { gh run list --commit "$sha" --limit 50 --json status,conclusion,workflowName,url 2>/dev/null || echo '[]'; }
superseded() {
	[ "$(printf '%s' "$1" | jq '[.[] | select(.conclusion != "cancelled")] | length')" -eq 0 ] &&
		[ "$(printf '%s' "$1" | jq length)" -gt 0 ]
}

if [ "${2:-}" = --wait ]; then
	end=$(($(date +%s) + 45 * 60))
	while [ "$(date +%s)" -lt "$end" ]; do
		list=$(runs)
		if superseded "$list"; then
			sha=$(git ls-remote origin "refs/heads/$base" | cut -f1)
			sleep 60
			continue
		fi
		total=$(printf '%s' "$list" | jq length)
		pending=$(printf '%s' "$list" | jq '[.[] | select(.status != "completed")] | length')
		# Runs may take a moment to appear after a merge; once a minute, to spare the API.
		[ "$total" -gt 0 ] && [ "$pending" -eq 0 ] && break
		sleep 60
	done
fi

list=$(runs)
short=${sha%"${sha#???????}"}
failed=$(printf '%s' "$list" | jq -r '[.[] | select(.status == "completed" and (.conclusion | IN("failure", "timed_out", "startup_failure", "action_required")))]')
if [ "$(printf '%s' "$failed" | jq length)" -gt 0 ]; then
	echo "RED $base $short (the merge of #$pr, or a newer commit holding it)"
	printf '%s' "$failed" | jq -r '.[] | "  \(.workflowName): \(.conclusion) \(.url)"'
	echo "Read the failed runs: when the failure is your change's, fix it on a new branch and tell the tech lead;"
	echo "when it is not, tell the tech lead what fails (comment.sh <issue> \"tech lead\"), and your work is over."
	exit 0
fi
pending=$(printf '%s' "$list" | jq '[.[] | select(.status != "completed")] | length')
if [ "$pending" -gt 0 ] || [ "$(printf '%s' "$list" | jq length)" -eq 0 ]; then
	echo "PENDING $base $short: $pending run(s) still going"
	exit 0
fi
echo "GREEN $base $short: the CI and deploy runs of #$pr passed, your change is deployed"
