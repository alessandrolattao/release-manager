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

# in_base <commit>: whether the commit is in the default branch, as origin has it now: origin/<base>, fetched
# first. Fails when it is not, or when the fetch fails.
in_base() {
	git fetch -q origin "$(base_branch)" 2>/dev/null &&
		git merge-base --is-ancestor "$1" "origin/$(base_branch)" 2>/dev/null
}

# The names of the sessions, without counters, so an address never goes stale.
# Every name is "<repo> · <role> · <detail>", so the agent list keeps a project's sessions together; a
# developer's and a QA agent's also say where the issue stands (its stage: in progress, in review).
tech_lead_name() { printf '%s · tech lead' "$repo_short"; }
dev_name() { printf '%s · dev #%s · %s%s' "$repo_short" "$1" "${3:+$3 · }" "$(short_title "$2")"; }
qa_name() { printf '%s · qa #%s · %s%s' "$repo_short" "$1" "${3:+$3 · }" "$(short_title "$2")"; }
spike_name() { printf '%s · spike · %s' "$repo_short" "$1"; }
# short_title <title>: an issue title cut to about 40 characters at a word, without Markdown marks.
short_title() {
	printf '%s\n' "$1" | tr -d '`*_' | awk -v max=40 '{
		if (length($0) <= max) { print; exit }
		s = substr($0, 1, max); sub(/ [^ ]*$/, "", s); print s "…"; exit }'
}

# address_of <session-id>: how comments name the session: "tech lead", "dev #<n>", "qa #<n>", "spike <topic>".
address_of() {
	jq -r 'if .role == "tech-lead" then "tech lead"
		elif .role == "dev" or .role == "qa" then .role + " #" + (.issue | tostring)
		elif .role == "spike" then "spike " + (.topic // "")
		else "team" end' "$sessions_dir/$1/status" 2>/dev/null || echo team
}

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

# issue_of <number> <link>: the issue a comment belongs to. A comment on a pull request carries the pull
# request's number: the issue is the one it closes (remembered).
issue_of() {
	case "$2" in */pull/*) ;; *)
		echo "$1"
		return
		;;
	esac
	known="$repo_dir/pr-issue/$1"
	if [ ! -s "$known" ]; then
		mkdir -p "$repo_dir/pr-issue"
		n=$(gh pr view "$1" --json closingIssuesReferences --jq '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)
		case "$n" in "" | *[!0-9]*) n="" ;; esac
		[ -z "$n" ] || echo "$n" >"$known"
	fi
	cat "$known" 2>/dev/null || echo "$1"
}

# thread_of <issue-or-pr>: the issue a number belongs to: the number itself, or the issue a pull request
# closes.
thread_of() {
	if gh pr view "$1" --json number >/dev/null 2>&1; then
		_closes=$(gh pr view "$1" --json closingIssuesReferences --jq '.closingIssuesReferences[0].number // empty' 2>/dev/null || true)
		[ -z "$_closes" ] || {
			echo "$_closes"
			return
		}
	fi
	echo "$1"
}

# alive <session-id>: its heartbeat (hooks/sessions.tsx, every minute) is at most 3 minutes old.
alive() {
	at=$(cat "$sessions_dir/$1/alive" 2>/dev/null || true)
	case "$at" in "" | *[!0-9]*) return 1 ;; esac
	[ $(($(date +%s) - at)) -le 180 ]
}

# merge_method [--merge|--rebase|--squash]: the method a merge in this repository uses (merge.sh, merge-bot.sh).
# The one asked for, which the repository's own instructions name; without one, a merge commit when the
# repository allows it, else the method it allows. Fails on anything else.
merge_method() {
	case "${1:-}" in
	--merge | --rebase | --squash) echo "${1#--}" ;;
	"")
		allowed=$(gh api "repos/$repo_full" --jq '[if .allow_merge_commit then "merge" else empty end,
			if .allow_rebase_merge then "rebase" else empty end, if .allow_squash_merge then "squash" else empty end] | join(" ")' 2>/dev/null || true)
		case " $allowed " in
		*" merge "* | "  ") echo merge ;;
		*) echo "${allowed%% *}" ;;
		esac
		;;
	*) return 1 ;;
	esac
}

# checks_not_green <pr>: the pull request's checks that are not green, as "<name>: <state>, ...", nothing when every
# one is or it has none. When they cannot be read it prints why and fails.
checks_not_green() {
	# gh exits non-zero for pending or failing checks too: only an answer that is not a list, other than "no
	# checks reported", is a failure to read them.
	err=$(mktemp)
	checks=$(gh pr checks "$1" --json state,name 2>"$err") || true
	if ! printf '%s' "$checks" | jq -e 'type == "array"' >/dev/null 2>&1; then
		if grep -qi 'no checks reported' "$err"; then
			checks='[]'
		else
			head -1 "$err"
			rm -f "$err"
			return 1
		fi
	fi
	rm -f "$err"
	printf '%s' "$checks" | jq -r '[.[] | select(.state != "SUCCESS" and .state != "SKIPPED" and .state != "NEUTRAL") | "\(.name): \(.state)"] | join(", ")'
}

# inbox_dir <owner/name>: the inbox of another repository's tech leads, for what belongs on none of its issues.
inbox_dir() { printf '%s/inbox/%s' "$team_data" "$(printf '%s' "${1:-$repo_full}" | tr '/' '_')"; }

# lower <text>: the text in lower case (owner/name compares without case, as on GitHub).
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# On another repository a tech lead reads and writes issues and comments, never its code (hooks/guard.py).
# What it writes there is signed with this repository, `<!-- team · tech lead of <this repository> -->`, so
# that repository's dispatcher wakes its own tech lead with it.
signer_elsewhere="tech lead of $repo_full"
# may_write_elsewhere <session-id> <owner/name>: exits 2, saying why, unless the session is a tech lead and
# the repository is another one. Called as a command, never in $(...): it ends the script.
may_write_elsewhere() {
	[ "$(jq -r '.role // ""' "$sessions_dir/$1/status" 2>/dev/null || true)" = tech-lead ] || {
		echo "only a tech lead writes on another repository: write to your tech lead on the issue (comment.sh <n> \"tech lead\")" >&2
		exit 2
	}
	[ "$(lower "$2")" != "$(lower "$repo_full")" ] || {
		echo "--repo names another repository: inside $repo_full write without it" >&2
		exit 2
	}
}

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
