#!/bin/sh
# One cycle of the team's dispatcher. dispatcher.sh, a process of its own, runs it every minute; one
# run at a time per repository and machine (a lock). No model: it only does what follows from the state.
#   1. hands each new GitHub comment of the repository (not an edit of an older one) to the session it is
#      written to;
#   2. turns a question an agent left in its own chat, unanswered for 5 minutes, into a comment to the
#      repository's tech lead;
#   3. marks dead sessions stuck (red, in the agent list too), or done when they are developers or QA agents
#      whose issue is closed, and removes finished ones with their worktree;
#   4. resumes dead developer and QA agents, and starts the QA agents asked for;
#   5. starts a developer for the next workable issue (no cap: the user decides what is ready);
#   6. writes the board's summary: checkout, queue, main CI, how long the plan usage lasts.
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
trap 'exit 1' INT TERM
# The team's GitHub account, asked once a day.
login_file="$team_state/login"
login=$( [ -z "$(find "$login_file" -mmin -1440 2>/dev/null)" ] || cat "$login_file")
if [ -z "$login" ]; then
	login=$(gh api user --jq .login 2>/dev/null) || exit 0
	echo "$login" >"$login_file"
fi
now=$(date +%s)
tab=$(printf '\t')
listing=$(claude agents --json --all --cwd "$root" 2>/dev/null || echo '[]')
jobs_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs"

# job_of <session-id>: the short id the agent list knows the session by, if it lists it.
job_of() { printf '%s' "$listing" | jq -r --arg s "$1" '[.[] | select(.sessionId == $s) | .id][0] // empty'; }
# running <session-id>: the agent list shows a process behind the session.
running() { [ "$(printf '%s' "$listing" | jq -r --arg s "$1" '[.[] | select(.sessionId == $s and .status != null)] | length')" != 0 ]; }
# wake <session-id> <time> <from> <text> <link>: the hooks module of that session wakes it between turns.
# The time is the comment's (epoch seconds): a session that answered on its thread after it is not woken.
wake() { printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$(printf '%s' "$4" | tr '\t\n' '  ' | cut -c1-200)" "$5" >>"$sessions_dir/$1/wake"; }
# note <issue> <jq filter> [jq args]: what last happened on an issue, from the comments read here (which
# machine took it, the last team message and when), for the board's agents of other machines.
note() {
	f="$repo_dir/activity/$1.json"
	shift
	mkdir -p "$repo_dir/activity"
	{ cat "$f" 2>/dev/null || echo '{}'; } | jq -c --argjson now "$now" "$@" >"$f.$$" && mv "$f.$$" "$f"
}
# live_of <role> [issue]: the sessions of that role (and issue) alive and not done.
live_of() {
	for id in $(sessions_of "$1" "${2:-}"); do
		{ alive "$id" || running "$id"; } && [ "$(jq -r .state "$sessions_dir/$id/status")" != done ] && echo "$id"
	done
}
# open_of <role> [issue]: the sessions of that role (and issue) not done, alive or not: a comment for one
# that is dead waits in its `wake` file and is delivered when it is resumed.
open_of() {
	for id in $(sessions_of "$1" "${2:-}"); do
		[ "$(jq -r .state "$sessions_dir/$id/status")" != done ] && echo "$id"
	done
}

# 1. GitHub comments to sessions.
cursor="$repo_dir/comments.since"
seen="$repo_dir/comments.seen"
touch "$seen"
since=$(cat "$cursor" 2>/dev/null || date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
date -u +%Y-%m-%dT%H:%M:%SZ >"$cursor.next"
# Each comment: id, when it was written (epoch seconds), author, issue, link, who signed it (note.sh's hidden
# last line, "-" when none), its first two non-empty lines. The listing also returns the comments edited since the cursor: one written before it
# is an edit, and wakes nobody, whoever wrote it.
if comments=$(since=$since gh api --paginate "repos/$repo_full/issues/comments?since=$since&per_page=100" --jq '.[]
	| select(.created_at >= env.since) | [
		(.id | tostring), (.created_at | fromdateiso8601 | tostring), .user.login, (.issue_url | split("/") | last), .html_url,
		([.body | capture("<!-- team · (?<f>[^<>]+) -->") | .f][0] // "-"),
		((.body | gsub("\r"; "") | split("\n") | map(select(length > 0))) as $l | ($l[0] // ""), ($l[1] // ""))
	] | map(gsub("\t"; " ")) | @tsv' 2>/dev/null); then
	mv "$cursor.next" "$cursor"
	printf '%s\n' "$comments" | while IFS="$tab" read -r cid created author issue link signed first second; do
		[ -n "$cid" ] || continue
		grep -qx "$cid" "$seen" && continue
		echo "$cid" >>"$seen"
		from="" to="" text=$first
		# "**from → to**", with " · fyi" after it when no answer is owed.
		header=$(printf '%s' "$first" | sed -n 's/^\*\*\(.*\) → \(.*\)\*\*\( · fyi\)\{0,1\}$/\1\t\2/p')
		# The team writes and reads with the user's own account: only its comments are listened to, so nobody
		# else can pass for a session or the user. Anyone else's comment wakes nobody.
		[ "$author" = "$login" ] || continue
		issue=$(issue_of "$issue" "$link")
		# A machine taking or releasing the issue (claim.sh): no message for anyone, a note for the board.
		case "$first" in
		"**dispatcher · "*"** takes #"*)
			h=$(printf '%s' "$first" | sed -n 's/^\*\*dispatcher · \([a-z0-9-]*\)\*\* takes #[0-9]*$/\1/p')
			[ -z "$h" ] || note "$issue" --arg h "$h" '.host = $h | .at = $now'
			continue
			;;
		"**"*"** releases #"*)
			note "$issue" '.host = null | .at = $now'
			continue
			;;
		esac
		if [ -n "$header" ]; then
			from=${header%%"$tab"*}
			to=${header#*"$tab"}
			text=$second
			case "$first" in *"** · fyi") fyi=true ;; *) fyi=false ;; esac
			note "$issue" --arg f "$from" --arg t "$to" --argjson fyi "$fyi" '.from = $f | .to = $t | .fyi = $fyi | .at = $now'
		elif [ "$signed" != - ]; then
			# A session's comment for the record (note.sh): not the user's, and to nobody in particular.
			from=$signed
			to="(record)"
		else
			from="the user"
		fi
		targets=""
		case "$to" in
		"@$login") ;;
		"tech lead"*)
			# The repository's tech lead: the live one, else the last known.
			targets=$(live_of tech-lead | head -1)
			[ -n "$targets" ] || targets=$(open_of tech-lead | head -1)
			;;
		"dev #"* | "qa #"*) targets=$(open_of "${to%% *}" "${to#*#}") ;;
		"(record)") targets="$(open_of dev "$issue") $(open_of qa "$issue")" ;;
		"")
			# Written on GitHub by the user, without a header: to whoever waits on the user for that issue
			# (asked there, or in its own chat about it), else to its developer, else to the tech lead.
			for id in $(open_of dev "$issue") $(open_of qa "$issue") $(open_of tech-lead); do
				jq -e --argjson n "$issue" '.state == "you" and (.asked_on == $n or (.asked_on == null and .issue == $n))' \
					"$sessions_dir/$id/status" >/dev/null 2>&1 && targets="$targets $id"
			done
			[ -n "$targets" ] || targets=$(open_of dev "$issue")
			[ -n "$targets" ] || targets=$(live_of tech-lead | head -1)
			;;
		esac
		for id in $targets; do
			[ "$(address_of "$id")" != "$from" ] || continue
			wake "$id" "$created" "$from on #$issue" "$text" "$link"
		done
	done
	tail -n 2000 "$seen" >"$seen.tmp" && mv "$seen.tmp" "$seen"
else
	rm -f "$cursor.next"
fi

# 2. Questions an agent left in its own chat, which nobody reads, go to the tech lead on the issue.
for id in $(sessions_of dev) $(sessions_of qa); do
	asked="$sessions_dir/$id/asked"
	waiting_in_chat "$id" || continue
	[ ! -f "$asked.told" ] || continue
	at=$(sed -n 1p "$asked")
	case "$at" in "" | *[!0-9]*) continue ;; esac
	[ $((now - at)) -ge 30 ] || continue
	issue=$(jq -r .issue "$sessions_dir/$id/status")
	printf '**%s → tech lead**\n\nAsked in its own chat:\n\n%s\n' "$(address_of "$id")" "$(sed -n '4,$p' "$asked")" |
		gh issue comment "$issue" --body-file - >/dev/null 2>&1 && {
		touch "$asked.told"
		state_set "$id" others "waits for tech lead: $(sed -n 4p "$asked")"
		# The same wait as comment.sh's: the tech lead's answer ends it (hooks/sessions.tsx).
		status_set "$id" '.waits_on = "tech lead"'
	}
done

# 3. Dead sessions turn red, or are done when their issue is closed; finished ones go away, with a
# developer's worktree.
for f in "$sessions_dir"/*/status; do
	[ -f "$f" ] || continue
	[ "$(jq -r '.repo // ""' "$f")" = "$repo_full" ] || continue
	id=$(basename "$(dirname "$f")")
	state=$(jq -r '.state // ""' "$f")
	job=$(job_of "$id")
	dead=false
	alive "$id" || running "$id" || dead=true
	# A dead developer or QA agent whose issue is closed is done, even when it died before done.sh, and goes
	# at once: no turn of its own is left to end. A live one is left alone: it may still follow its merge's CI
	# and deploy. An issue whose state cannot be read is not closed.
	closed=false
	if [ "$state" != done ] && [ "$dead" = true ]; then
		case "$(jq -r '.role // ""' "$f")" in
		dev | qa)
			issue=$(jq -r '.issue // ""' "$f")
			[ -z "$issue" ] || [ "$(gh issue view "$issue" --json state --jq .state 2>/dev/null)" != CLOSED ] || closed=true
			;;
		esac
	fi
	if [ "$closed" = true ]; then
		state_set "$id" done "its issue is closed"
		state=done
	fi
	if [ "$state" = done ]; then
		since=$(jq -r '.since // 0' "$f")
		[ "$closed" = true ] || [ $((now - since)) -ge 120 ] || continue
		if [ -n "$job" ]; then
			claude stop "$job" >/dev/null 2>&1 || true
			claude rm "$job" >/dev/null 2>&1 || true
		fi
		dir=$(cat "$sessions_dir/$id/cwd" 2>/dev/null || true)
		case "$(jq -r .role "$f"):$dir" in
		dev:"$root/.claude/worktrees/"*)
			branch=$(jq -r '.branch // ""' "$f")
			# Neither goes with work that was not pushed: remove refuses a dirty worktree, -d a branch ahead
			# of what was pushed and merged.
			git -C "$root" worktree remove "$dir" >/dev/null 2>&1 || true
			[ -z "$branch" ] || git -C "$root" branch -d "$branch" >/dev/null 2>&1 || true
			;;
		esac
		rm -rf "${sessions_dir:?}/$id"
		continue
	fi
	if [ "$dead" = true ] && [ "$state" != stuck ]; then
		state_set "$id" stuck "session stopped"
		state_json="$jobs_dir/$job/state.json"
		if [ -n "$job" ] && [ -f "$state_json" ] && jq '.color = "red"' "$state_json" >"$state_json.team" 2>/dev/null; then
			chmod 600 "$state_json.team"
			mv "$state_json.team" "$state_json"
		else
			rm -f "$state_json.team"
		fi
	fi
done

# 4. Dead agents come back; QA agents asked for start. A QA record is keyed by its issue.
resumed=$(sh "$here/resume-agents.sh" 2>/dev/null | grep -c '^resumed dev ' || true)
for record in "$repo_dir"/qa/*; do
	[ -f "$record" ] || continue
	[ "$(cut -f1 "$record")" = requested ] || continue
	issue=$(basename "$record")
	[ -n "$(live_of qa "$issue")" ] || sh "$here/start-qa.sh" "$issue" >/dev/null 2>&1 || true
done

# 5. The next workable issue gets a developer: no cap, the user decides what is ready.
# The plan usage of this account, only shown on the board: read at most every 5 minutes for all its
# repositories (the usage API rate-limits frequent readers); when a read fails, the last good one holds for
# 30 minutes.
usage_file="$team_state/usage/$(printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" | tr '/' '_').json"
mkdir -p "$team_state/usage"
usage=""
if [ -n "$(find "$usage_file" -mmin -5 2>/dev/null)" ]; then
	usage=$(cat "$usage_file")
elif command -v clessidra >/dev/null 2>&1 && fresh=$(clessidra --json 2>/dev/null) &&
	printf '%s' "$fresh" | jq -e '.windows' >/dev/null 2>&1; then
	usage=$fresh
	printf '%s\n' "$usage" >"$usage_file.$$" && mv "$usage_file.$$" "$usage_file"
elif [ -n "$(find "$usage_file" -mmin -30 2>/dev/null)" ]; then
	usage=$(cat "$usage_file")
fi
# at <time> <5h|7d>: a time of clessidra's as the board shows it: the hour within the 5-hour window, the
# day of the week and the hour within the weekly one.
at() {
	if [ "$2" = 5h ]; then date -d "$1" +%H:%M; else date -d "$1" '+%a %H:%M'; fi
}
# window <5h|7d>: that window from clessidra --json, as {text, alt, tone}. text: "33% · lasts" (ok),
# "99% · runs out Wed 08:00" (alert), "100% · resets Tue 17:00" (alert), "2% · too early" (text). Above 90%
# the board alternates text with alt, "93% · resets 00:10": when the window starts again.
window() {
	row=$(printf '%s' "$usage" | jq -r --arg w "$1" '.windows[]? | select(.window == $w)
		| [.outcome, ((.used // 0) | floor | tostring), (.resets_at // "-"), (.runs_out_at // "-")] | @tsv' 2>/dev/null | head -1)
	[ -n "$row" ] || { jq -n '{text: "unreadable", alt: "", tone: "text"}'; return; }
	outcome=$(printf '%s' "$row" | cut -f1) used=$(printf '%s' "$row" | cut -f2)
	resets=$(printf '%s' "$row" | cut -f3) out=$(printf '%s' "$row" | cut -f4)
	alt=""
	case "$outcome" in
	lasts) text="$used% · lasts" tone=ok ;;
	runs_out) text="$used% · runs out $(at "$out" "$1")" tone=alert ;;
	limit_reached) text="$used% · resets $(at "$resets" "$1")" tone=alert ;;
	too_early) text="$used% · too early" tone=text ;;
	not_started) text="not started" tone=text ;;
	*) text="no data" tone=text ;;
	esac
	if [ "$used" -ge 90 ] 2>/dev/null && [ "$outcome" != limit_reached ] && [ "$resets" != - ]; then
		alt="$used% · resets $(at "$resets" "$1")"
	fi
	jq -n --arg text "$text" --arg alt "$alt" --arg tone "$tone" '{text: $text, alt: $alt, tone: $tone}'
}
# Busy: the live developers, and the ones resumed in this run, which have no heartbeat yet.
busy=$(($(live_of dev | wc -l | tr -d ' ') + ${resumed:-0}))
queue=$(sh "$here/queue.sh" 2>/dev/null || true)
workable=$(printf '%s\n' "$queue" | jq -r 'select(.workable) | .number' 2>/dev/null || true)
next=""
for issue in $workable; do
	# Any session of the issue holds it, a done one too until it is removed with its worktree, and so does
	# a developer being started (start-dev.sh).
	[ -z "$(sessions_of dev "$issue")" ] || continue
	[ -z "$(find "$repo_dir/starting.$issue" -maxdepth 0 -mmin -5 2>/dev/null)" ] || continue
	next=$issue
	break
done
if [ -n "$next" ]; then
	sh "$here/start-dev.sh" "$next" >/dev/null 2>&1 && busy=$((busy + 1)) && next=""
fi

# 6. A free checkout with someone waiting wakes the first of them; then the board's summary.
sh "$here/checkout.sh" next >/dev/null 2>&1 || true
holder=$(sed -n 1p "$repo_dir/checkout" 2>/dev/null || true)
# One that took it as it is (checkout.sh take --as-is) shows with as-is after its name.
held_as=""
[ "$(sed -n 4p "$repo_dir/checkout" 2>/dev/null)" != as-is ] || held_as=" as-is"
base=$(base_branch)
# The default branch's CI, asked at most every 5 minutes: every machine shares one GitHub account and its
# hourly API allowance.
ci_file="$repo_dir/ci"
if [ -n "$(find "$ci_file" -mmin -5 2>/dev/null)" ]; then
	ci=$(cat "$ci_file")
else
	sha=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
	ci=$(gh run list --branch "$base" --commit "$sha" --limit 50 --json status,conclusion 2>/dev/null |
		jq -r 'if length == 0 then "no runs" elif any(.[]; .status == "completed" and (.conclusion | IN("failure", "timed_out", "startup_failure"))) then "red"
			elif any(.[]; .status != "completed") then "running" else "green" end' 2>/dev/null || echo "?")
	[ "$ci" = "?" ] || echo "$ci" >"$ci_file"
fi
# The agents of other machines: the started issues another machine took, their state guessed from the notes
# of the comments read here: stuck when nothing happened on the issue for an hour, waiting when the agent's
# last message is still unanswered, working otherwise.
myhost=$(sh "$here/claim.sh" host 2>/dev/null || true)
elsewhere=$(printf '%s\n' "$queue" | jq -c 'select(.status == "started") | {number, title, statusName}' 2>/dev/null |
	while read -r row; do
		f="$repo_dir/activity/$(printf '%s' "$row" | jq -r .number).json"
		h=$(jq -r '.host // ""' "$f" 2>/dev/null || true)
		[ -n "$h" ] && [ "$h" != "$myhost" ] || continue
		jq -c --argjson row "$row" --argjson now "$now" '
			($now - (.at // $now)) as $quiet
			| (((.from // "") | test("^(dev|qa) #")) and (.fyi != true)) as $asks
			| {issue: $row.number, title: $row.title, host: .host, since: (.at // $now),
				stage: (($row.statusName // "in progress") | ascii_downcase),
				state: (if $quiet > 3600 then "stuck" elif $asks then "others" else "working" end),
				detail: (if $quiet > 3600 then "quiet \($quiet / 3600 | floor)h, on \(.host)"
					elif $asks then "waits for \(.to), on \(.host)" else "on \(.host)" end)}' "$f"
	done | jq -s -c '.')
jq -n --argjson now "$now" --arg holder "$( [ -n "$holder" ] && echo "$(address_of "$holder")$held_as")" \
	--arg held_since "$(sed -n 2p "$repo_dir/checkout" 2>/dev/null)" \
	--arg waiting "$(while read -r w; do [ -n "$w" ] && address_of "$w"; done <"$repo_dir/checkout.queue" 2>/dev/null | paste -sd, -)" \
	--argjson ready "$(printf '%s\n' "$workable" | grep -c . || true)" --arg next "${next:+#$next}" \
	--argjson backlog "$(printf '%s\n' "$queue" | jq -s '[.[] | select(.backlog)] | length' 2>/dev/null || echo 0)" \
	--argjson questions "$(printf '%s\n' "$queue" | jq -s '[.[] | select(.question)] | length' 2>/dev/null || echo 0)" \
	--arg ci "$ci" --argjson busy "$busy" --argjson h5 "$(window 5h)" --argjson d7 "$(window 7d)" \
	--argjson elsewhere "${elsewhere:-[]}" \
	'{updated: $now, checkout: {holder: $holder, since: $held_since, waiting: $waiting}, queue: {ready: $ready, next: $next,
	backlog: $backlog, questions: $questions}, ci: $ci, developers: {busy: $busy}, usage: {h5: $h5, d7: $d7},
	elsewhere: $elsewhere}' \
	>"$repo_dir/board.json.tmp" && mv "$repo_dir/board.json.tmp" "$repo_dir/board.json"
