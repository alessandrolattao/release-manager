#!/bin/sh
# Resumes this repository's developers, reviewers and QA agents whose session died (a restart of the machine, a crash),
# each in its own folder, with the conversation it had. The dispatcher runs it; safe to run at any time.
# It leaves alone a live session, one stopped on purpose (`claude stop`), one that is done, and one whose
# issue the user parked (closed, or back in the backlog).
#   resume-agents.sh      (from the main checkout)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
prompt="Your session was cut off by a restart of the machine or a crash, and it is now resumed: go on with your work from where you stopped."
unset_args=$(env | grep -o -E '^CLAUDE[A-Z_]*' | grep -v '^CLAUDE_CONFIG_DIR$' | sed 's/^/-u /' | tr '\n' ' ')
listing=$(claude agents --json --all --cwd "$root" 2>/dev/null || echo '[]')

for id in $(sessions_of dev) $(sessions_of review) $(sessions_of qa); do
	status="$sessions_dir/$id/status"
	[ "$(jq -r .state "$status")" != done ] || continue
	alive "$id" && continue
	# Dead means no process behind it, whatever its last turn left: failed, cut off while working, or between
	# turns waiting on someone (blocked, done) when the machine went down. Left alone: one stopped on purpose
	# (`claude stop`), one removed (`claude rm`), one running.
	state=$(printf '%s' "$listing" | jq -r --arg s "$id" '[.[] | select(.sessionId == $s)][0] | if . == null then "gone" elif .status != null then "running" else .state end')
	case "$state" in stopped | gone | running) continue ;; esac
	issue=$(jq -r .issue "$status")
	open=$(gh issue view "$issue" --json state,labels --jq '.state == "OPEN" and any(.labels[]; .name == "ready for development")' 2>/dev/null || echo unknown)
	[ "$open" = true ] || continue
	dir=$(cat "$sessions_dir/$id/cwd" 2>/dev/null || true)
	[ -d "$dir" ] || continue
	name=$(jq -r .name "$status")
	# No flags: a background session keeps its own saved options, and any flag passed here (even --name)
	# would start a copy of it under a new id instead of continuing it. The module renames it anyway.
	# shellcheck disable=SC2086 # unset_args is a list of -u flags
	if (cd "$dir" && env $unset_args claude --bg --resume "$id" "$prompt") </dev/null >/dev/null 2>&1; then
		state_set "$id" working "resumed after an interruption"
		echo "resumed $name"
	else
		echo "could not resume $name: resume it from claude agents" >&2
	fi
done
