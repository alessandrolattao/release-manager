#!/bin/sh
# Waits until one of this repository's agents changes state (finishes, blocks, fails), or a question
# is answered (fewer issues with the question label), or the minutes run out; then prints the agents
# and exits. Run it in the background: its exit wakes you.
#   wait.sh [minutes]   default 15
set -eu

minutes=${1:-15}
root=$(git rev-parse --show-toplevel)

agents() {
	claude agents --json --cwd "$root/.claude/worktrees" 2>/dev/null |
		jq -c 'sort_by(.name) | map({name, state, status, id})' 2>/dev/null || echo '[]'
}

questions() { gh issue list --label question --assignee @me --state open --limit 200 --json number --jq length 2>/dev/null || echo 0; }

before=$(agents)
asked=$(questions)
checks=0
end=$(($(date +%s) + minutes * 60))
while [ "$(date +%s)" -lt "$end" ]; do
	sleep 30
	now=$(agents)
	if [ "$now" != "$before" ]; then
		echo "agents changed"
		echo "$now" | jq '.'
		exit 0
	fi
	# Every 2 minutes, see whether the user answered a question.
	checks=$((checks + 1))
	if [ $((checks % 4)) -eq 0 ] && [ "$(questions)" -lt "$asked" ]; then
		echo "a question was answered: look at the queue again"
		exit 0
	fi
done
echo "no change in $minutes minutes"
echo "$before" | jq '.'
