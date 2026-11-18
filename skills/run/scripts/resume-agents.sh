#!/bin/sh
# Resumes this repository's developer agents whose session died (a restart of the machine or a crash):
# each one in its own worktree, with the conversation it had, under its current name, on this account.
# Safe to run at any time. It leaves alone:
#   - a live session, idle ones included: `done` and `blocked` are sessions waiting for a message;
#   - a session someone stopped on purpose (`stopped`, as `claude stop` leaves it);
#   - an agent that waits for the user ([ask], [ready]) or is over ([done]);
#   - an issue the user parked: closed, or back in the backlog without `ready for development`.
#   resume-agents.sh      (from the main checkout)
# Prints one line per agent it resumed; nothing when no agent needs it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=skills/run/scripts/session-dir.sh
. "$here/session-dir.sh"
root=$(git rev-parse --show-toplevel)
prompt="Your session was cut off by a restart of the machine or a crash, and it is now resumed: go on with your work from where you stopped."

# Same account as this session: keep CLAUDE_CONFIG_DIR, drop every other CLAUDE* variable so the
# agent and its supervisor do not inherit this session's identity.
unset_args=$(env | grep -o -E '^CLAUDE[A-Z_]*' | grep -v '^CLAUDE_CONFIG_DIR$' | sed 's/^/-u /' | tr '\n' ' ')

# One session per worktree, the latest, and only when none of that worktree's sessions runs. Dead means
# `failed`, or `working` with no process behind it (the machine went down before the state was updated).
# `--cwd` takes the repository: given the worktrees folder it lists nothing.
claude agents --json --all --cwd "$root" 2>/dev/null | jq -r --arg w "$root/.claude/worktrees/" '
	map(select(.cwd | startswith($w)))
	| group_by(.cwd)[]
	| select(all(.status == null))
	| max_by(.startedAt)
	| select(.state == "failed" or .state == "working")
	| "\(.sessionId)\t\(.cwd)\t\(.name // "")"' |
	while IFS="$(printf '\t')" read -r id dir listed; do
		[ -d "$dir" ] || continue
		# The last name asked wins over the listed one, which lags behind until the session applies it
		# and reads [closed] once closed-sweep.sh has seen the session dead.
		name=$(cat "$sessions_dir/$id/name" 2>/dev/null || true)
		[ -n "$name" ] || name=$listed
		case "$name" in
		"[dev]"* | "[fix]"* | "[test]"* | "[review]"*) ;;
		*) continue ;;
		esac
		branch=${name#* }
		issue=${branch%%-*}
		# Everything in this loop reads from /dev/null: its stdin is the list of agents.
		if ! open=$(gh issue view "$issue" --json state,labels \
			--jq '.state == "OPEN" and any(.labels[]; .name == "ready for development")' </dev/null 2>/dev/null); then
			echo "could not read issue $issue: $name not resumed" >&2
			continue
		fi
		[ "$open" = true ] || continue
		# shellcheck disable=SC2086 # unset_args is a list of -u flags
		if (cd "$dir" && env $unset_args claude --bg --resume "$id" --name "$name" "$prompt") </dev/null >/dev/null 2>&1; then
			echo "resumed $name"
		else
			echo "could not resume $name: resume it from claude agents" >&2
		fi
	done
