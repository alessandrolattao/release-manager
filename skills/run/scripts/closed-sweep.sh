#!/bin/sh
# Shows this repository's closed sessions as what they are: no color, and the tag [done] when the agent's
# pull request was merged, [closed] otherwise. It covers the developer agents and the sessions of a Pulse check.
# Closed means the agent list shows no process behind the session, however it ended (stopped, crashed,
# finished): a session that crashes runs no hook, so the list is the one signal that never misses an end.
# Safe to run at any time, and it changes nothing the second time. It leaves alone:
#   - a live session, idle ones included;
#   - a session that changed in the last 2 minutes: one still starting shows no process for a moment;
#   - the release manager, the planner and any other session.
# A closed session runs no hooks module, so its look is written where the list reads it, the session's
# state.json. Its folder keeps the live name and color: if the session is resumed, the module gives them
# back, and resume-agents.sh still knows what the agent was doing.
#   closed-sweep.sh      (from the main checkout)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/session-dir.sh
. "$here/session-dir.sh"
root=$(git rev-parse --show-toplevel)
jobs_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs"
tab=$(printf '\t')

# is_closed <session id>: true only when the list, read now, shows that session with no process.
is_closed() {
	[ "$(claude agents --json --all --cwd "$root" </dev/null 2>/dev/null | jq -r --arg s "$1" \
		'[.[] | select(.sessionId == $s)] | if length == 1 and .[0].status == null and .[0].pid == null then "yes" else "no" end' 2>/dev/null)" = yes ]
}

# pr_outcome <branch>: "done" when the branch's pull request was merged and none is open on it, else
# "closed". Fails when GitHub cannot be read.
pr_outcome() {
	gh pr list --head "$1" --state all --limit 20 --json state --jq \
		'if any(.[]; .state == "OPEN") then "closed" elif any(.[]; .state == "MERGED") then "done" else "closed" end' </dev/null 2>/dev/null
}

claude agents --json --all --cwd "$root" 2>/dev/null |
	jq -r '.[] | select(.status == null and .pid == null) | "\(.id)\t\(.sessionId)\t\(.cwd)"' 2>/dev/null |
	while IFS="$tab" read -r short id cwd; do
		state="$jobs_dir/$short/state.json"
		[ -f "$state" ] || continue
		[ ! -f "$sessions_dir/$id/role" ] || continue
		[ -n "$(find "$state" -mmin +2 2>/dev/null)" ] || continue
		[ "$(jq -r '.sessionId // empty' "$state" 2>/dev/null)" = "$id" ] || continue
		name=$(jq -r '.name // empty' "$state")
		color=$(jq -r '.color // empty' "$state")
		template=$(jq -r '.template // empty' "$state")

		case "$cwd:$name" in
		"$root/.claude/worktrees/"*:"[done]"*) new=$name ;;
		"$root/.claude/worktrees/"*:"[dev]"* | "$root/.claude/worktrees/"*:"[review]"* | \
			"$root/.claude/worktrees/"*:"[test]"* | "$root/.claude/worktrees/"*:"[fix]"* | \
			"$root/.claude/worktrees/"*:"[ask]"* | "$root/.claude/worktrees/"*:"[ready]"* | \
			"$root/.claude/worktrees/"*:"[closed]"*)
			outcome=$(pr_outcome "${name#* }") || continue
			[ -n "$outcome" ] || continue
			new="[$outcome]${name#*]}"
			;;
		*)
			case "$template:$name" in
			pulse:*:"[closed] "*) new=$name ;;
			pulse:*:?*) new="[closed] $name" ;;
			*) continue ;;
			esac
			;;
		esac
		[ "$new" != "$name" ] || [ -n "$color" ] || continue

		# A second look a moment later: a session coming back shows no process for a second or two.
		sleep 3
		is_closed "$id" || continue

		# What the session looks like alive, for when it is resumed.
		case "$name" in
		"[closed]"*) ;;
		*) [ -s "$sessions_dir/$id/name" ] || want "$id" name "$name" ;;
		esac
		[ -z "$color" ] || [ -s "$sessions_dir/$id/color" ] || want "$id" color "$color"

		# The color key goes away: a session whose color is null drops out of the list.
		if jq --arg n "$new" '.name = $n | del(.color)' "$state" >"$state.sweep" && [ -s "$state.sweep" ]; then
			chmod 600 "$state.sweep"
			mv "$state.sweep" "$state"
			echo "$new"
		else
			rm -f "$state.sweep"
		fi
	done
