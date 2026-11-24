#!/bin/sh
# The team's dispatcher. A tech lead's hooks module runs it every minute; one run at a time per repository,
# whichever tech lead takes the lock. No model: it only does what follows from the state.
#   1. hands each new GitHub comment of the repository to the session it is written to;
#   2. turns a question an agent left in its own chat, unanswered for 5 minutes, into a comment to the
#      tech lead who follows the issue;
#   3. marks dead sessions stuck (red, in the agent list too) and removes finished ones with their worktree;
#   4. resumes dead developer and QA agents, and starts the QA agents asked for;
#   5. starts a developer for the next workable issue, within capacity;
#   6. writes the board's summary: checkout, queue, main CI, capacity.
#   dispatch.sh      (from the main checkout)
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/repo.sh
. "$here/repo.sh"
lock="$repo_dir/dispatch.lock"
if ! mkdir "$lock" 2>/dev/null; then
	# A run that died leaves its lock behind: it expires after 10 minutes.
	[ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || exit 0
	rm -rf "$lock"
	mkdir "$lock" 2>/dev/null || exit 0
fi
trap 'rm -rf "$lock"' EXIT
login=$(gh api user --jq .login 2>/dev/null) || exit 0
now=$(date +%s)
tab=$(printf '\t')
listing=$(claude agents --json --all --cwd "$root" 2>/dev/null || echo '[]')
jobs_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs"

# job_of <session-id>: the short id the agent list knows the session by, if it lists it.
job_of() { printf '%s' "$listing" | jq -r --arg s "$1" '[.[] | select(.sessionId == $s) | .id][0] // empty'; }
# running <session-id>: the agent list shows a process behind the session.
running() { [ "$(printf '%s' "$listing" | jq -r --arg s "$1" '[.[] | select(.sessionId == $s and .status != null)] | length')" != 0 ]; }
# wake <session-id> <from> <text> <link>: the monitor of that session wakes it between turns.
wake() { printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$2" "$(printf '%s' "$3" | tr '\t\n' '  ' | cut -c1-200)" "$4" >>"$sessions_dir/$1/wake"; }
# live_of <role> [issue]: the sessions of that role (and issue) alive and not done.
live_of() {
	for id in $(sessions_of "$1" "${2:-}"); do
		{ alive "$id" || running "$id"; } && [ "$(jq -r .state "$sessions_dir/$id/status")" != done ] && echo "$id"
	done
}

# 1. GitHub comments to sessions.
cursor="$repo_dir/comments.since"
seen="$repo_dir/comments.seen"
touch "$seen"
since=$(cat "$cursor" 2>/dev/null || date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
date -u +%Y-%m-%dT%H:%M:%SZ >"$cursor.next"
if comments=$(gh api --paginate "repos/$repo_full/issues/comments?since=$since&per_page=100" --jq '.[] | [
		(.id | tostring), .user.login, (.issue_url | split("/") | last), .html_url,
		((.body | gsub("\r"; "") | split("\n") | map(select(length > 0))) as $l | ($l[0] // ""), ($l[1] // ""))
	] | map(gsub("\t"; " ")) | @tsv' 2>/dev/null); then
	mv "$cursor.next" "$cursor"
	printf '%s\n' "$comments" | while IFS="$tab" read -r cid author issue link first second; do
		[ -n "$cid" ] || continue
		grep -qx "$cid" "$seen" && continue
		echo "$cid" >>"$seen"
		from="" to="" text=$first
		header=$(printf '%s' "$first" | sed -n 's/^\*\*\(.*\) → \(.*\)\*\*$/\1\t\2/p')
		if [ -n "$header" ]; then
			from=${header%%"$tab"*}
			to=${header#*"$tab"}
			text=$second
		elif [ "$author" = "$login" ]; then
			from="the user"
		else
			from=$author
		fi
		targets=""
		case "$to" in
		"@$login") ;;
		"tech lead"*)
			for id in $(live_of tech-lead); do [ "$(address_of "$id")" = "$to" ] && targets="$targets $id"; done
			[ -n "$targets" ] || targets=$(live_of tech-lead | head -1)
			;;
		"dev #"* | "qa #"*) targets=$(live_of "${to%% *}" "${to#*#}") ;;
		"")
			# Written on GitHub by the user or someone else: to whoever waits on the user for that issue,
			# else to its developer, else to the tech lead who follows it.
			for id in $(live_of dev "$issue") $(live_of qa "$issue") $(live_of tech-lead); do
				[ "$(jq -r '.state + " " + ((.issue // "") | tostring)' "$sessions_dir/$id/status")" = "you $issue" ] && targets="$targets $id"
			done
			[ -n "$targets" ] || targets=$(live_of dev "$issue")
			[ -n "$targets" ] || for id in $(live_of tech-lead); do [ "$(address_of "$id")" = "$(follower_of "$issue")" ] && targets=$id; done
			;;
		esac
		for id in $targets; do
			[ "$(address_of "$id")" != "$from" ] || continue
			wake "$id" "$from on #$issue" "$text" "$link"
		done
	done
	tail -n 2000 "$seen" >"$seen.tmp" && mv "$seen.tmp" "$seen"
else
	rm -f "$cursor.next"
fi

# 2. Questions left in an agent's own chat, unanswered for 5 minutes, go to the tech lead on the issue.
for id in $(sessions_of dev) $(sessions_of qa); do
	asked="$sessions_dir/$id/asked"
	waiting_in_chat "$id" || continue
	[ ! -f "$asked.told" ] || continue
	at=$(sed -n 1p "$asked")
	case "$at" in "" | *[!0-9]*) continue ;; esac
	[ $((now - at)) -ge 300 ] || continue
	issue=$(jq -r .issue "$sessions_dir/$id/status")
	follower=$(follower_of "$issue")
	printf '**%s → %s**\n\nAsked in its own chat, where nobody answered:\n\n%s\n' "$(address_of "$id")" "$follower" "$(sed -n '4,$p' "$asked")" |
		gh issue comment "$issue" --body-file - >/dev/null 2>&1 && {
		touch "$asked.told"
		state_set "$id" others "aspetta $follower: $(sed -n 4p "$asked" | cut -c1-80)"
	}
done

# 3. Dead sessions turn red; finished ones go away, with a developer's worktree.
for f in "$sessions_dir"/*/status; do
	[ -f "$f" ] || continue
	[ "$(jq -r '.repo // ""' "$f")" = "$repo_full" ] || continue
	id=$(basename "$(dirname "$f")")
	state=$(jq -r '.state // ""' "$f")
	job=$(job_of "$id")
	if [ "$state" = done ]; then
		since=$(jq -r '.since // 0' "$f")
		[ $((now - since)) -ge 120 ] || continue
		if [ -n "$job" ]; then
			claude stop "$job" >/dev/null 2>&1 || true
			claude rm "$job" >/dev/null 2>&1 || true
		fi
		dir=$(cat "$sessions_dir/$id/cwd" 2>/dev/null || true)
		case "$(jq -r .role "$f"):$dir" in
		dev:"$root/.claude/worktrees/"*)
			branch=$(jq -r '.branch // ""' "$f")
			git -C "$root" worktree remove "$dir" >/dev/null 2>&1 || true
			[ -z "$branch" ] || git -C "$root" branch -D "$branch" >/dev/null 2>&1 || true
			;;
		esac
		rm -rf "${sessions_dir:?}/$id"
		continue
	fi
	if ! alive "$id" && ! running "$id" && [ "$state" != stuck ]; then
		state_set "$id" stuck "sessione ferma"
		state_json="$jobs_dir/$job/state.json"
		if [ -n "$job" ] && [ -f "$state_json" ] && jq '.color = "red"' "$state_json" >"$state_json.team" 2>/dev/null; then
			chmod 600 "$state_json.team"
			mv "$state_json.team" "$state_json"
		else
			rm -f "$state_json.team"
		fi
	fi
done

# 4. Dead agents come back; QA agents asked for start.
sh "$here/resume-agents.sh" >/dev/null 2>&1 || true
for record in "$repo_dir"/qa/*; do
	[ -f "$record" ] || continue
	[ "$(cut -f1 "$record")" = requested ] || continue
	pr=$(basename "$record")
	issue=$(cut -f3 "$record")
	[ -n "$(live_of qa "$issue")" ] || sh "$here/start-qa.sh" "$issue" "$pr" >/dev/null 2>&1 || true
done

# 5. The next workable issue gets a developer, within capacity.
max=$(rule agents)
case "$max" in "" | *[!0-9]*) max=2 ;; esac
capacity="ok"
if command -v clessidra >/dev/null 2>&1 && usage=$(clessidra 2>/dev/null); then
	lines=$usage
	[ "$(rule capacity)" != 5h ] || lines=$(printf '%s\n' "$usage" | grep -i '5h' || true)
	if printf '%s\n' "$lines" | grep -q 'runs out in'; then
		capacity="esaurita prima del reset"
		max=0
	fi
else
	capacity="non leggibile, al massimo 1 agente"
	[ "$max" -le 1 ] || max=1
fi
busy=$(live_of dev | wc -l | tr -d ' ')
queue=$(sh "$here/queue.sh" 2>/dev/null || true)
workable=$(printf '%s\n' "$queue" | jq -r 'select(.workable) | .number' 2>/dev/null || true)
next=""
for issue in $workable; do
	taken=no
	for id in $(sessions_of dev "$issue"); do
		[ "$(jq -r .state "$sessions_dir/$id/status")" = done ] || taken=yes
	done
	[ "$taken" = no ] || continue
	next=$issue
	break
done
if [ -n "$next" ] && [ "$busy" -lt "$max" ]; then
	sh "$here/start-dev.sh" "$next" >/dev/null 2>&1 && busy=$((busy + 1)) && next=""
fi

# 6. The board's summary.
holder=$(sed -n 1p "$repo_dir/checkout" 2>/dev/null || true)
base=$(base_branch)
sha=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
ci=$(gh run list --branch "$base" --commit "$sha" --limit 50 --json status,conclusion 2>/dev/null |
	jq -r 'if length == 0 then "nessuna run" elif any(.[]; .status == "completed" and (.conclusion | IN("failure", "timed_out", "startup_failure"))) then "rossa"
		elif any(.[]; .status != "completed") then "in corso" else "verde" end' 2>/dev/null || echo "?")
jq -n --argjson now "$now" --arg holder "$( [ -n "$holder" ] && address_of "$holder")" \
	--arg held_since "$(sed -n 2p "$repo_dir/checkout" 2>/dev/null)" \
	--arg waiting "$(while read -r w; do [ -n "$w" ] && address_of "$w"; done <"$repo_dir/checkout.queue" 2>/dev/null | paste -sd, -)" \
	--argjson ready "$(printf '%s\n' "$workable" | grep -c . || true)" --arg next "${next:+#$next}" \
	--argjson backlog "$(printf '%s\n' "$queue" | jq -s '[.[] | select(.backlog)] | length' 2>/dev/null || echo 0)" \
	--argjson questions "$(printf '%s\n' "$queue" | jq -s '[.[] | select(.question)] | length' 2>/dev/null || echo 0)" \
	--arg ci "$ci" --arg capacity "$capacity" --argjson busy "$busy" --argjson max "$max" \
	'{updated: $now, checkout: {holder: $holder, since: $held_since, waiting: $waiting}, queue: {ready: $ready, next: $next,
	backlog: $backlog, questions: $questions}, ci: $ci, capacity: $capacity, developers: {busy: $busy, max: $max}}' \
	>"$repo_dir/board.json.tmp" && mv "$repo_dir/board.json.tmp" "$repo_dir/board.json"
