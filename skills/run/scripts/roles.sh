# Sourced by the scripts: the repository, the names of its release manager and planner, and their counters.
# Run from inside the repository (its main checkout or a worktree).
# shellcheck shell=sh disable=SC2034 # the variables are used by the scripts that source this file

repo_full=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
repo_short=${repo_full#*/}
manager_prefix="release manager · $repo_short"
planner_prefix="planner · $repo_short"
counters_dir="${XDG_STATE_HOME:-$HOME/.local/state}/release-manager/$(printf '%s' "$repo_full" | tr '/' '_')"

# session_of <prefix>: "<session id><TAB><name>" of the background session named <prefix> or "<prefix> …".
session_of() {
	claude agents --json 2>/dev/null | jq -r --arg p "$1" \
		'[.[] | select((.name // "") as $n | $n == $p or ($n | startswith($p + " ")))][0] // empty | "\(.sessionId)\t\(.name)"'
}

# merged_today: pull requests the release manager merged today.
merged_today() { cat "$counters_dir/merged-$(date +%F)" 2>/dev/null || echo 0; }

# questions_open: open issues assigned to the user that wait on an answer (label question).
questions_open() { gh issue list --label question --assignee @me --state open --limit 200 --json number --jq length 2>/dev/null || echo 0; }
