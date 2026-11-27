#!/bin/sh
# After a developer merges: follows the CI and deploy runs of its merge commit until they finish, so it knows
# whether its change is deployed. It opens nothing and stops nobody: the default branch goes red for many
# reasons, most of them someone else's. When it is red the developer reads the failed runs: its own failure
# it fixes, and tells the tech lead; anyone else's it tells the tech lead, and its work is over.
#   main-ci.sh <pr> [--wait]   the runs of the pull request's merge commit; --wait: until they all end (45 min)
# Its answer: GREEN or NO CI (exit 0), RED (exit 1); without --wait, PENDING while runs still go (exit 0).
# With --wait, exit 0 comes only with an answer that ends the developer's wait. When it stops before the runs
# end it says so, and the developer runs it again: PENDING at its time limit (exit 3), INTERRUPTED when a
# signal stops it, as a restart of the session or a kill (exit 4).
# The branch is the one the merge landed on, the pull request's base branch (the default branch when it cannot
# be read): every answer names it, and everything below is about it.
# Every workflow that runs on the commit counts; a cancelled one (superseded by a newer commit) does not, and
# when all of them were, the newest commit of the branch, which holds the change, is followed instead.
# A repository with no workflow that runs on a push gets NO CI at once, without waiting: the work ends with the
# merge, as with GREEN. With --wait, so does a merge commit with no run 5 minutes after the merge, whatever the
# workflow files say (a push trigger whose filters leave this push out): none will start. The same holds for the
# newest commit it follows once every run of the merge commit was cancelled, 5 minutes after it started
# following it, even when that is near or past the end of the wait: each switch moves the end to 5 minutes after
# it when that is later.
# While GitHub has not marked a merge that landed (merge.sh says so), the merge commit is the branch's commit
# whose second parent is the pull request's head. A squash or a rebase leaves none: not merged, until GitHub
# marks it.
set -eu

pr=${1:?pull request number}
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
base=$(gh pr view "$pr" --json baseRefName --jq '.baseRefName // empty' 2>/dev/null || true)
[ -n "$base" ] || base=$(base_branch)
sha=$(gh pr view "$pr" --json mergeCommit --jq '.mergeCommit.oid // empty')
if [ -z "$sha" ]; then
	head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null || true)
	if [ -n "$head" ] && in_base "$head" "$base"; then
		sha=$(git rev-list --merges --parents "$head..origin/$base" | awk -v h="$head" '$3 == h { print $1 }' | tail -n 1)
	fi
fi
[ -n "$sha" ] || {
	echo "#$pr is not merged"
	exit 1
}

short=${sha%"${sha#???????}"}
merge=$sha
# merged: when the merge landed, in seconds: GitHub's mergedAt, or, for a merge it has not marked, the merge
# commit's own date; now when neither can be read, so the 5 minutes never start before the merge.
merged=$(gh pr view "$pr" --json mergedAt --jq '.mergedAt // empty | fromdate' 2>/dev/null || true)
[ -n "$merged" ] || merged=$(git log -1 --format=%ct "$sha" 2>/dev/null || true)
case "$merged" in "" | *[!0-9]*) merged=$(date +%s) ;; esac

# runs: the runs of the commit followed; [] and a failure when they cannot be read.
runs() {
	gh run list --commit "$sha" --limit 50 --json status,conclusion,workflowName,url 2>/dev/null && return 0
	echo '[]'
	return 1
}
# push_workflow: whether an active workflow file of the repository (.github/workflows/*) runs on a push: its
# on: on the branch has a push trigger, whatever its filters (push-trigger.py). GitHub's dynamic
# workflows (Pages build, CodeQL default setup, Dependabot, Copilot) have no file and do not count. A read
# that fails counts as such a workflow: NO CI comes only from knowing there is none.
push_workflow() {
	workflows=$(gh workflow list --limit 1000 --json id,path,state 2>/dev/null) || return 0
	ids=$(printf '%s' "$workflows" | jq -r '.[] | select(.state == "active" and (.path | startswith(".github/workflows/"))) | .id' 2>/dev/null) || return 0
	for id in $ids; do
		yaml=$(gh workflow view "$id" --yaml --ref "$base" 2>/dev/null) || return 0
		[ "$(printf '%s\n' "$yaml" | python3 -I "$here/push-trigger.py" 2>/dev/null)" = no ] || return 0
	done
	return 1
}
superseded() {
	[ "$(printf '%s' "$1" | jq '[.[] | select(.conclusion != "cancelled")] | length')" -eq 0 ] &&
		[ "$(printf '%s' "$1" | jq length)" -gt 0 ]
}
# no_run, with --wait: NO CI, and the end, when the runs of the commit followed were read ($seen, $list) and
# there are none 5 minutes after $since: none will start. Runs that cannot be read are not known to be none.
no_run() {
	[ -n "$seen" ] && [ "$(printf '%s' "$list" | jq length)" -eq 0 ] && [ "$(date +%s)" -ge $((since + 300)) ] || return 0
	if [ "$sha" = "$merge" ]; then
		echo "NO CI $base ${sha%"${sha#???????}"}: no workflow run started for this merge"
	else
		echo "NO CI $base ${sha%"${sha#???????}"}: the merge's runs were cancelled and the newest commit started none"
	fi
	exit 0
}

# The wait's own pause, a sleep in the background so that a signal stops it at once; stopped with the wait.
nap=""
pause() {
	sleep 60 &
	nap=$!
	wait "$nap" || true
	nap=""
}
interrupted() {
	[ -z "$nap" ] || kill "$nap" 2>/dev/null || true
	echo "INTERRUPTED $base ${sha%"${sha#???????}"}: run main-ci.sh $pr --wait again"
	exit 4
}
[ "${2:-}" != --wait ] || trap interrupted HUP INT TERM

if ! push_workflow; then
	echo "NO CI $base $short: no workflow runs on $base"
	exit 0
fi

if [ "${2:-}" = --wait ]; then
	minutes=${MAIN_CI_WAIT:-45}
	end=$(($(date +%s) + minutes * 60))
	# since: when the 5 minutes for a first run of the commit followed start: the merge for the merge commit,
	# the moment it starts following it for a newer one.
	since=$merged
	while [ "$(date +%s)" -lt "$end" ]; do
		seen=yes
		list=$(runs) || seen=""
		if superseded "$list"; then
			newest=$(git ls-remote origin "refs/heads/$base" | cut -f1)
			if [ "$newest" != "$sha" ]; then
				since=$(date +%s)
				# Its 5 minutes may end past the limit: the wait goes on until they do.
				[ $((since + 300)) -le "$end" ] || end=$((since + 300))
			fi
			sha=$newest
			pause
			continue
		fi
		total=$(printf '%s' "$list" | jq length)
		pending=$(printf '%s' "$list" | jq '[.[] | select(.status != "completed")] | length')
		# Runs may take a moment to appear after a merge; once a minute, to spare the API.
		[ "$total" -gt 0 ] && [ "$pending" -eq 0 ] && break
		no_run
		pause
	done
fi

seen=yes
list=$(runs) || seen=""
[ "${2:-}" != --wait ] || no_run
short=${sha%"${sha#???????}"}
failed=$(printf '%s' "$list" | jq -r '[.[] | select(.status == "completed" and (.conclusion | IN("failure", "timed_out", "startup_failure", "action_required")))]')
if [ "$(printf '%s' "$failed" | jq length)" -gt 0 ]; then
	echo "RED $base $short (the merge of #$pr, or a newer commit holding it)"
	printf '%s' "$failed" | jq -r '.[] | "  \(.workflowName): \(.conclusion) \(.url)"'
	echo "Read the failed runs: when the failure is your change's, fix it on a new branch and tell the tech lead;"
	echo "when it is not, tell the tech lead what fails (comment.sh <issue> \"tech lead\"), and your work is over."
	exit 1
fi
pending=$(printf '%s' "$list" | jq '[.[] | select(.status != "completed")] | length')
if [ "$pending" -gt 0 ] || [ "$(printf '%s' "$list" | jq length)" -eq 0 ]; then
	if [ "${2:-}" = --wait ]; then
		echo "PENDING $base $short: $pending run(s) still going after $minutes minutes: run main-ci.sh $pr --wait again"
		exit 3
	fi
	echo "PENDING $base $short: $pending run(s) still going"
	exit 0
fi
echo "GREEN $base $short: the CI and deploy runs of #$pr passed, your change is deployed"
