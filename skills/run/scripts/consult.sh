#!/bin/sh
# Starts a consultant of the planner: a read-only background session named "[plan] <topic>", for a
# technical analysis or an opinion the user asked for. It writes its report to a file; this script
# waits for the session to end and prints the report. Run it with the Bash tool in the background:
# its end wakes you with the report.
#   consult.sh "<topic>" [minutes] <<'EOF'
#   <the question: what to find out, what is already known or decided, what the user wants back>
#   EOF
#   consult.sh --wait <id> <report> [minutes]    wait again for a consultant still at work
# Run it from the main checkout. <minutes> (default 60) bounds the wait, not the consultant.
set -eu

here=$(cd "$(dirname "$0")" && pwd)

# wait_for <id> <report> <minutes>: waits until the session ends, then prints its report.
wait_for() {
	id=$1 report=$2 minutes=$3
	end=$(($(date +%s) + minutes * 60))
	state=""
	while [ "$(date +%s)" -lt "$end" ]; do
		sleep 20
		state=$(claude agents --json --all 2>/dev/null |
			jq -r --arg i "$id" '[.[] | select(.id == $i or .sessionId == $i) | .state][0] // empty' 2>/dev/null || true)
		case "$state" in done | blocked | failed | stopped) break ;; esac
	done
	case "$state" in
	done | blocked | failed | stopped) ;;
	*)
		echo "consultant $id still at work after $minutes minutes; wait again with:"
		echo "  sh \"$here/consult.sh\" --wait $id \"$report\""
		exit 0
		;;
	esac
	echo "consultant $id: $state"
	if [ -s "$report" ]; then
		echo "report $report"
		echo
		cat "$report"
	else
		echo "it wrote no report; its last output:"
		claude logs "$id" 2>/dev/null | tail -40
	fi
}

if [ "${1:-}" = "--wait" ]; then
	wait_for "${2:?consultant id}" "${3:?report file}" "${4:-60}"
	exit 0
fi

topic=${1:?topic}
minutes=${2:-60}
# shellcheck source=skills/run/scripts/roles.sh
. "$here/roles.sh"
root=$(git rev-parse --show-toplevel)
base=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)

question=$(cat)
[ -n "$question" ] || {
	echo "the question comes on stdin" >&2
	exit 2
}

# "[<state>]<icons> <n>-" is how the release manager's scripts find a developer agent: a topic that
# starts with a number would be taken for one, so it gets a "#".
case "$topic" in [0-9]*) topic="#$topic" ;; esac
name="[plan] $topic"

dir="${XDG_DATA_HOME:-$HOME/.local/share}/release-manager/consults/$(printf '%s' "$repo_full" | tr '/' '_')"
mkdir -p "$dir"
slug=$(printf '%s' "$topic" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-40)
report="$dir/$(date +%Y%m%dT%H%M%S)-${slug:-consult}.md"

brief=$(sed -e "s|{{REPO}}|$repo_full|g" -e "s|{{PLANNER}}|$planner_prefix|g" \
	-e "s|{{REPORT}}|$report|g" -e "s|{{BASE}}|$base|g" "$here/../../planner/consult-brief.md")
brief="$brief

$question"

# Same account as this session: keep CLAUDE_CONFIG_DIR, drop every other CLAUDE* variable so the
# consultant and its supervisor do not inherit this session's identity.
unset_args=$(env | grep -o -E '^CLAUDE[A-Z_]*' | grep -v '^CLAUDE_CONFIG_DIR$' | sed 's/^/-u /' | tr '\n' ' ')
cd "$root"
# shellcheck disable=SC2086 # unset_args is a list of -u flags
out=$(env $unset_args claude --bg --name "$name" "$brief" 2>&1) || {
	echo "$out" >&2
	exit 1
}

id=$(printf '%s\n' "$out" | sed -n 's/.*claude logs \([0-9a-f]\{8\}\).*/\1/p' | head -1)
if [ -z "$id" ]; then
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		id=$(claude agents --json 2>/dev/null | jq -r --arg n "$name" '[.[] | select(.name == $n) | .id][0] // empty')
		[ -n "$id" ] && break
		sleep 1
	done
fi
[ -n "$id" ] || {
	echo "could not find the consultant session $name" >&2
	echo "$out" >&2
	exit 1
}
echo "consultant $id started as $name; report in $report"
wait_for "$id" "$report" "$minutes"
