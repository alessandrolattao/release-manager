#!/bin/sh
# Checks the CI of the default branch, so a merge never leaves it broken unnoticed.
#   main-ci.sh            the latest commit of the default branch, as it stands now
#   main-ci.sh --wait     waits (up to 45 minutes) for every workflow run of the latest commit to finish
# Every workflow that runs on the default branch counts; a cancelled run (superseded) does not.
# Red: records the broken commit, opens a bug issue once (Urgent when the repository has the field),
# and prints RED with the failed runs. Green: clears the record and prints GREEN.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
base=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
sha=$(git ls-remote origin "refs/heads/$base" | cut -f1)
red_file="$counters_dir/main-red"
mkdir -p "$counters_dir"

runs() { gh run list --branch "$base" --commit "$sha" --limit 50 --json databaseId,status,conclusion,workflowName,url 2>/dev/null || echo '[]'; }

if [ "${1:-}" = --wait ]; then
	end=$(($(date +%s) + 45 * 60))
	while [ "$(date +%s)" -lt "$end" ]; do
		list=$(runs)
		total=$(printf '%s' "$list" | jq length)
		pending=$(printf '%s' "$list" | jq '[.[] | select(.status != "completed")] | length')
		# Runs may take a moment to appear after a merge.
		[ "$total" -gt 0 ] && [ "$pending" -eq 0 ] && break
		sleep 30
	done
fi

list=$(runs)
failed=$(printf '%s' "$list" | jq -r '[.[] | select(.status == "completed" and (.conclusion | IN("failure", "timed_out", "startup_failure", "action_required")))]')
if [ "$(printf '%s' "$failed" | jq length)" -eq 0 ]; then
	pending=$(printf '%s' "$list" | jq '[.[] | select(.status != "completed")] | length')
	if [ "$pending" -gt 0 ]; then
		echo "PENDING $base ${sha%"${sha#???????}"}: $pending run(s) still going"
		exit 0
	fi
	if [ -f "$red_file" ]; then
		rm -f "$red_file"
		sh "$here/sync-names.sh" manager >/dev/null 2>&1 || true
	fi
	echo "GREEN $base ${sha%"${sha#???????}"}"
	exit 0
fi

short=${sha%"${sha#???????}"}
echo "RED $base $short"
printf '%s' "$failed" | jq -r '.[] | "  \(.workflowName): \(.conclusion) \(.url)"'

# Open the bug once per broken commit.
if [ "$(sed -n 1p "$red_file" 2>/dev/null)" = "$sha" ]; then
	echo "  bug issue: #$(sed -n 2p "$red_file")"
	exit 0
fi
pr=$(gh pr list --state merged --base "$base" --limit 20 --json number,mergeCommit 2>/dev/null |
	jq -r --arg s "$sha" '.[] | select(.mergeCommit.oid == $s) | .number' 2>/dev/null | head -1 || true)
title="La CI di $base fallisce${pr:+ dopo il merge di #$pr} ($short)"
issue_url=$({
	# shellcheck disable=SC2016 # the backticks are Markdown
	printf 'La CI di `%s` è rossa sul commit `%s`%s.\n\n' "$base" "$short" "${pr:+, il merge di #$pr}"
	printf '%s' "$failed" | jq -r '.[] | "- \(.workflowName): \(.conclusion), \(.url)"'
	printf '\nFinché non torna verde il release manager non mergia altro, tranne la PR che chiude questa issue.\n'
} | sh "$here/open-issue.sh" "$title" @me)
issue=${issue_url##*/}
printf '%s\n%s\n' "$sha" "$issue" >"$red_file"
sh "$here/set-fields.sh" "$issue" Urgent Low >/dev/null 2>&1 || true
sh "$here/sync-names.sh" manager >/dev/null 2>&1 || true
echo "  bug issue: #$issue"
