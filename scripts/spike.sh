#!/bin/sh
# Starts a spike for a tech lead: a read-only background session "spike · <repo> · <topic>", for a
# technical analysis or an opinion the user asked for. It writes its report to a file; this script
# waits for the session to end and prints the report. Run it with the Bash tool in the background:
# its end wakes you with the report.
#   spike.sh [--fable] "<topic>" [minutes] <<'EOF'
#   <the question: what to find out, what is already known or decided, what the user wants back>
#   EOF
# It runs on the account's default model; --fable runs it on Fable, only when the user chose that for this
# analysis.
#   spike.sh --wait <id> <report> [minutes]    wait again for a spike still at work
# Run it from the main checkout. <minutes> (default 60) bounds the wait, not the spike.
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
		echo "spike $id still at work after $minutes minutes; wait again with:"
		echo "  sh \"$here/spike.sh\" --wait $id \"$report\""
		exit 0
		;;
	esac
	echo "spike $id: $state"
	# Its work is over: the board drops it and the dispatcher removes the session.
	full_id=$(claude agents --json --all 2>/dev/null | jq -r --arg i "$id" '[.[] | select(.id == $i or .sessionId == $i) | .sessionId][0] // empty' 2>/dev/null || true)
	[ -z "$full_id" ] || state_set "$full_id" done "report ready"
	if [ -s "$report" ]; then
		echo "report $report"
		echo
		cat "$report"
	else
		echo "it wrote no report; its last output:"
		claude logs "$id" 2>/dev/null | tail -40
	fi
}

# shellcheck source=scripts/session-dir.sh
. "$here/session-dir.sh"
if [ "${1:-}" = "--wait" ]; then
	wait_for "${2:?spike id}" "${3:?report file}" "${4:-60}"
	exit 0
fi

model=default
if [ "${1:-}" = --fable ]; then
	model=fable
	shift
fi
topic=${1:?topic}
minutes=${2:-60}
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
# shellcheck source=scripts/launch.sh
. "$here/launch.sh"
base=$(base_branch)

question=$(cat)
[ -n "$question" ] || {
	echo "the question comes on stdin" >&2
	exit 2
}

name=$(spike_name "$topic")

dir="$team_data/spikes/$repo_key"
mkdir -p "$dir"
slug=$(printf '%s' "$topic" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-40)
report="$dir/$(date +%Y%m%dT%H%M%S)-${slug:-spike}.md"

brief=$(sed -e "s|{{REPO}}|$repo_full|g" -e "s|{{TECH_LEAD}}|$(address_of "${CLAUDE_CODE_SESSION_ID:-}")|g" \
	-e "s|{{REPORT}}|$report|g" -e "s|{{BASE}}|$base|g" -e "s|{{SCRIPTS}}|$here|g" "$here/../briefs/spike.md")
brief="$brief

$question"

cd "$root"
full=$(launch "$name" "$brief" "$model")
sh "$here/role.sh" "$full" spike "$topic" >/dev/null
id=${full%%-*}
echo "spike $id started as $name; report in $report"
wait_for "$id" "$report" "$minutes"
