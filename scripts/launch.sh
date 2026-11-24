# Sourced by the scripts that start an agent: launch <name> <prompt> starts a background session in the
# current folder, on the same Claude Code account as the caller, and prints its full session id.
# shellcheck shell=sh

launch() {
	# Keep CLAUDE_CONFIG_DIR, drop every other CLAUDE* variable, so the new session and its supervisor do
	# not inherit the caller's identity.
	unset_args=$(env | grep -o -E '^CLAUDE[A-Z_]*' | grep -v '^CLAUDE_CONFIG_DIR$' | sed 's/^/-u /' | tr '\n' ' ')
	# shellcheck disable=SC2086 # unset_args is a list of -u flags
	out=$(env $unset_args claude --bg --name "$1" "$2" 2>&1) || {
		echo "$out" >&2
		return 1
	}
	short=$(printf '%s\n' "$out" | sed -n 's/^backgrounded · \([0-9a-f]\{8\}\).*/\1/p' | head -1)
	full=""
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		# By the job id it printed; by name only when it printed none, and then the newest one, since an
		# older session of the same name may still be listed.
		full=$(claude agents --json 2>/dev/null | jq -r --arg s "$short" --arg n "$1" \
			'if $s != "" then [.[] | select(.id == $s) | .sessionId][0] // empty
			else [.[] | select(.name == $n)] | sort_by(.startedAt // .createdAt // 0) | last | .sessionId // empty end')
		[ -n "$full" ] && break
		sleep 1
	done
	[ -n "$full" ] || {
		echo "could not find the session $1 just started" >&2
		echo "$out" >&2
		return 1
	}
	printf '%s\n' "$full"
}
