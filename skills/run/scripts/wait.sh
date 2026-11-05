#!/bin/sh
# Waits until one of this repository's agents changes state (finishes, blocks, fails) or the
# minutes run out, then prints the agents and exits. Run it in the background: its exit wakes you.
#   wait.sh [minutes]   default 15
set -eu

minutes=${1:-15}
root=$(git rev-parse --show-toplevel)

agents() {
	claude agents --json --cwd "$root/.claude/worktrees" 2>/dev/null |
		jq -c 'sort_by(.name) | map({name, state, status, id})' 2>/dev/null || echo '[]'
}

before=$(agents)
end=$(($(date +%s) + minutes * 60))
while [ "$(date +%s)" -lt "$end" ]; do
	sleep 30
	now=$(agents)
	if [ "$now" != "$before" ]; then
		echo "agents changed"
		echo "$now" | jq '.'
		exit 0
	fi
done
echo "no change in $minutes minutes"
echo "$before" | jq '.'
