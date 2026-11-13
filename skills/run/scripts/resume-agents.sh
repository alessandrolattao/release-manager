#!/bin/sh
# Resumes this repository's developer agents that are not running any more (a restart of the machine
# stops every session): each one in its own worktree, with the conversation it had, on this account.
#   resume-agents.sh      (from the main checkout)
# Prints one line per agent it resumed; nothing when every agent is running.
set -eu

root=$(git rev-parse --show-toplevel)
prompt="Your session was stopped, the machine restarted, and it is now resumed: go on with your work from where you stopped."

# Same account as this session: keep CLAUDE_CONFIG_DIR, drop every other CLAUDE* variable so the
# agent and its supervisor do not inherit this session's identity.
unset_args=$(env | grep -o -E '^CLAUDE[A-Z_]*' | grep -v '^CLAUDE_CONFIG_DIR$' | sed 's/^/-u /' | tr '\n' ' ')

# One session per worktree, the latest, and only when none of that worktree's sessions runs.
# `--cwd` takes the repository: given the worktrees folder it lists nothing.
claude agents --json --all --cwd "$root" 2>/dev/null | jq -r --arg w "$root/.claude/worktrees/" '
	map(select(.cwd | startswith($w)))
	| group_by(.cwd)[]
	| select(all(.status == null))
	| max_by(.startedAt)
	| select((.name // "") | test("^\\[(dev|review|test|fix|ask)\\]"))
	| "\(.sessionId)\t\(.cwd)\t\(.name)"' |
	while IFS="$(printf '\t')" read -r id dir name; do
		[ -d "$dir" ] || continue
		# shellcheck disable=SC2086 # unset_args is a list of -u flags
		if (cd "$dir" && env $unset_args claude --bg --resume "$id" "$prompt") >/dev/null 2>&1; then
			echo "resumed $name"
		else
			echo "could not resume $name: resume it from claude agents" >&2
		fi
	done
