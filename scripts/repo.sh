# Sourced by the scripts: the repository they run in (its main checkout or a worktree), the names of its
# sessions, and a few counts.
# shellcheck shell=sh disable=SC2034 # the variables are used by the scripts that source this file

_here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/session-dir.sh
. "${scripts:-$_here}/session-dir.sh"

repo_full=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
repo_short=${repo_full#*/}
repo_key=$(printf '%s' "$repo_full" | tr '/' '_')
repo_dir="$team_state/repos/$repo_key"
# The main checkout, from any worktree of it.
root=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
mkdir -p "$repo_dir"

# base_branch: the default branch, asked once.
base_branch() {
	[ -s "$repo_dir/base" ] || gh repo view --json defaultBranchRef --jq .defaultBranchRef.name >"$repo_dir/base"
	cat "$repo_dir/base"
}


# The names of the sessions, without counters, so an address never goes stale.
tech_lead_name() { printf 'tech lead · %s%s' "$repo_short" "${1:+ · $1}"; }
dev_name() { printf 'dev #%s · %s · %s' "$1" "$repo_short" "$(printf '%s' "${2#*-}" | cut -c1-40)"; }
qa_name() { printf 'qa #%s · %s' "$1" "$repo_short"; }
spike_name() { printf 'spike · %s · %s' "$repo_short" "$1"; }

# address_of <session-id>: how comments name the session: "tech lead", "tech lead <topic>", "dev #<n>",
# "qa #<n>", "spike <topic>".
address_of() {
	jq -r 'if .role == "tech-lead" then "tech lead" + (if (.topic // "") != "" then " " + .topic else "" end)
		elif .role == "dev" or .role == "qa" then .role + " #" + (.issue | tostring)
		elif .role == "spike" then "spike " + (.topic // "")
		else "team" end' "$sessions_dir/$1/status" 2>/dev/null || echo team
}

# follower_of <issue>: the address of the tech lead who follows the issue (follow.sh), or "tech lead".
follower_of() { cat "$repo_dir/issues/$1/tech-lead" 2>/dev/null || echo "tech lead"; }

# sessions_of <role> [issue]: the ids of this repository's sessions with that role (and issue), from
# their status files, alive or not.
sessions_of() {
	for f in "$sessions_dir"/*/status; do
		[ -f "$f" ] || continue
		jq -e --arg r "$1" --arg repo "$repo_full" --arg i "${2:-}" \
			'.role == $r and .repo == $repo and ($i == "" or (.issue | tostring) == $i)' "$f" >/dev/null 2>&1 || continue
		basename "$(dirname "$f")"
	done
}

# alive <session-id>: its heartbeat (hooks/sessions.tsx, every minute) is at most 3 minutes old.
alive() {
	at=$(cat "$sessions_dir/$1/alive" 2>/dev/null || true)
	case "$at" in "" | *[!0-9]*) return 1 ;; esac
	[ $(($(date +%s) - at)) -le 180 ]
}

# inbox_dir <owner/name>: the inbox of another repository's tech leads, for what cannot go on an issue.
inbox_dir() { printf '%s/inbox/%s' "$team_data" "$(printf '%s' "${1:-$repo_full}" | tr '/' '_')"; }

# backlog_open: open issues assigned to the user without "ready for development".
backlog_open() {
	gh issue list --assignee @me --state open --limit 500 --search '-label:"ready for development"' --json number --jq length 2>/dev/null || echo 0
}

# questions_list: the user's open issues that wait on an answer (label question), one number per line.
# Through the REST list: a search with a label and an assignee lags behind a label just removed.
questions_list() {
	login=$(gh api user --jq .login 2>/dev/null) || return 0
	gh api --paginate "repos/$repo_full/issues?labels=question&assignee=$login&state=open&per_page=100" \
		--jq '.[] | select(.pull_request == null) | .number' 2>/dev/null || true
}
