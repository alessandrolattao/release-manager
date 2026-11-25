#!/bin/sh
# End-to-end checks of the team plugin with `gh`, `claude` and `clessidra` stubbed, a real local git
# repository, and every state folder redirected into a temporary folder, removed when the run ends.
#   sh tests/e2e.sh    (from anywhere; prints its checks, ends with passed=<n> failed=<n>, non-zero on a failure)
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
S="$T/state/team/sessions"
R="$T/state/team/repos/test_repo"
spk=""
busy=""
# On the way out, even after a failure: the dispatchers started here stop with every process of theirs (each
# runs in a session of its own), a spike or a busy session's toucher left running is killed, and the
# temporary folder goes.
cleanup() {
	cd / || true
	[ -z "$spk" ] || kill "$spk" 2>/dev/null
	[ -z "$busy" ] || kill "$busy" 2>/dev/null
	for f in "$T"/state/team/repos/*/dispatcher.pid; do
		pid=$(cat "$f" 2>/dev/null || true)
		case "$pid" in "" | *[!0-9]*) continue ;; esac
		kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
		n=0
		while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
	done
	rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$T/state" "$T/data" "$T/tmp" "$T/bin" "$T/gh/comments" "$T/config/jobs" "$T/home/.config"
for v in $(env | grep -o -E '^CLAUDE[A-Z_]*'); do unset "$v"; done
# Nothing of the machine's own: its home, git configuration and time zone stay out.
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1 TZ=UTC
export XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data" TMPDIR="$T/tmp" CLAUDE_PLUGIN_ROOT="$W" PATH="$T/bin:$PATH" G="$T/gh" CLAUDE_CONFIG_DIR="$T/config" TT="$T" CLAIM_WAIT=0
SC="$W/scripts"
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: wanted [$3] got [$2]"; fi; }
st() { jq -r ".$2 // \"\"" "$S/$1/status" 2>/dev/null; }

# A fake GitHub.
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
case "$*" in
"repo view --json nameWithOwner --jq .nameWithOwner") echo test/repo ;;
"repo view --json defaultBranchRef --jq .defaultBranchRef.name") echo main ;;
"api user --jq .login") echo tester ;;
"issue view "*" --json title --jq .title") echo "Title $3" ;;
"issue comment "*" --body-file -") n=$(cat "$G/next-id" 2>/dev/null || echo 1); echo $((n + 1)) >"$G/next-id"; cat >"$G/comments/$3.$n"; echo "https://github.com/test/repo/issues/$3#issuecomment-$n" ;;
"api --paginate repos/test/repo/issues/"*"/comments?per_page=100")
	n=$(echo "$*" | sed -n 's#.*issues/\([0-9]*\)/comments.*#\1#p')
	all=$(for f in "$G/comments/$n".*; do [ -f "$f" ] || continue; jq -n --rawfile b "$f" --argjson id "${f##*.}" '{id: $id, user: {login: "tester"}, body: $b}'; done | jq -s '.')
	# A race: another machine's older take shows up once this one has taken the issue.
	if [ -f "$G/race-$n" ] && [ "$all" != "[]" ]; then all=$(printf '%s' "$all" | jq --arg n "$n" '[{id: 0.5, user: {login: "tester"}, body: "**dispatcher · other-9999** takes #\($n)"}] + .'); fi
	printf '%s\n' "$all" ;;
"api -X DELETE repos/test/repo/issues/comments/"*) rm -f "$G/comments/"*".${4##*/}" ;;
"pr view 50 --json number") echo '{"number":50}' ;;
"pr view "*" --json number") exit 1 ;;
"pr view 50 --json closingIssuesReferences --jq .closingIssuesReferences[0].number // empty") echo 42 ;;
"pr view 50 --json headRefOid --jq .headRefOid") echo abc1234567 ;;
"pr view 50 --json headRefName --jq .headRefName") echo 42-feature ;;
"pr view 50 --json headRefOid,state,mergeable,closingIssuesReferences")
	m=MERGEABLE
	[ ! -f "$G/conflicting" ] || m=CONFLICTING
	echo '{"headRefOid":"abc1234567","state":"OPEN","mergeable":"'"$m"'","closingIssuesReferences":[{"number":42}]}' ;;
"pr checks 50 --json state,name") [ ! -f "$G/checks-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; echo '[{"name":"build","state":"SUCCESS"}]' ;;
"pr view 51 --json closingIssuesReferences --jq .closingIssuesReferences[0].number // empty") echo 44 ;;
"pr merge 50 --merge --match-head-commit abc1234567") echo merged >"$G/merged-50" ;;
"pr merge 50 --rebase --match-head-commit abc1234567") echo rebased >"$G/merged-50" ;;
"api repos/test/repo --jq "*) cat "$G/merge-methods" 2>/dev/null || echo "merge rebase squash" ;;
"label list --limit 200 --json name --jq .[].name") echo question ;;
"issue edit "*" --add-label question") echo "$3" >>"$G/question-labels" ;;
"issue view 42 --json labels --jq "*) cat "$G/qa-42" 2>/dev/null || echo no ;;
"issue view "*" --json state,labels --jq "*) cat "$G/issue-open" 2>/dev/null || echo false ;;
"api --paginate repos/test/repo/issues/comments?since="*"per_page=100") cat "$G/mentions.json" 2>/dev/null || echo '[]' ;;
"api --paginate repos/test/repo/issues/comments?since="*) cat "$G/repo-comments.tsv" 2>/dev/null ;;
"pr view 50 --json mergeCommit --jq .mergeCommit.oid // empty") echo deadbeefcafe ;;
"run list --commit deadbeefcafe "*) cat "$G/runs" 2>/dev/null || echo '[]' ;;
"run list "*) echo '[]' ;;
"api graphql "*)
	case "$*" in
	*planningStatuses*) echo '[{"id":"S_TODO","name":"Todo"},{"id":"S_PROG","name":"In progress"},{"id":"S_REV","name":"In review"}]' ;;
	*setIssueStatus*) printf '%s\n' "$*" | grep -o 'S_[A-Z]*' | head -1 >"$G/status-last"; echo '{}' ;;
	*"issue(number"*) echo I_1 ;;
	*) cat "$G/queue" 2>/dev/null ;;
	esac ;;
"issue develop 44 --list") echo "44-new-thing	https://x" ;;
*) echo "gh stub: unhandled: $*" >>"$G/unhandled"; exit 1 ;;
esac
EOF
# A fake claude: the agent list comes from a file, stop and rm are recorded.
cat >"$T/bin/claude" <<'EOF'
#!/bin/sh
case "$1" in
agents) cat "$TT/agents.json" 2>/dev/null || echo '[]' ;;
--bg) echo "$*" >>"$TT/claude.log"; echo "backgrounded · abcd1234 · started" ;;
*) echo "$*" >>"$TT/claude.log" ;;
esac
EOF
cat >"$T/bin/clessidra" <<'EOF'
#!/bin/sh
[ "${1:-}" = --json ] || { echo "5h  ██░░░░░░░░   20%  reset 23:00 · lasts"; exit 0; }
cat <<JSON
{"account": "/x", "windows": [
 {"window": "5h", "outcome": "runs_out", "used": 80, "resets_at": "$(date +%F)T23:50:00+00:00", "runs_out_at": "$(date +%F)T23:00:00+00:00", "short_by_minutes": 50},
 {"window": "7d", "outcome": "lasts", "used": 11, "resets_at": "2030-12-01T17:00:00+00:00", "runs_out_at": null, "short_by_minutes": null}
]}
JSON
EOF
chmod +x "$T/bin/gh" "$T/bin/claude" "$T/bin/clessidra"

# A real repository with an origin, a branch for issue 42 and its worktree.
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
ROOT="$T/repo"
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$ROOT" push -q origin main
git -C "$ROOT" branch -q 42-feature
git -C "$ROOT" push -q origin 42-feature
git -C "$ROOT" branch -q 43-other
git -C "$ROOT" push -q origin 43-other
mkdir -p "$ROOT/.claude/worktrees"
git -C "$ROOT" worktree add -q "$ROOT/.claude/worktrees/42-feature" 42-feature
git -C "$ROOT" worktree add -q "$ROOT/.claude/worktrees/43-other" 43-other

TL1=11111111-0000-0000-0000-000000000001
TL2=11111111-0000-0000-0000-000000000002
DEV=22222222-0000-0000-0000-000000000042
DEV2=22222222-0000-0000-0000-000000000043
SPK=33333333-0000-0000-0000-000000000001

echo "== role.sh"
cd "$ROOT" || exit 1
sh "$SC/role.sh" "$TL1" tech-lead "" >/dev/null
date +%s >"$S/$TL1/alive"
ok "tech lead name" "$(cat "$S/$TL1/name")" "repo · tech lead"
out=$(sh "$SC/role.sh" "$TL2" tech-lead)
ok "a second tech lead for the repository is refused" "$(printf '%s' "$out" | grep -c 'already has a tech lead') $([ -f "$S/$TL2/status" ] && echo registered || echo not-registered)" "1 not-registered"
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
sh "$SC/role.sh" "$DEV" dev 42 42-feature >/dev/null
date +%s >"$S/$DEV/alive"
ok "developer name: repo, role, stage, title" "$(cat "$S/$DEV/name")" "repo · dev #42 · in progress · Title 42"
ok "developer place" "$(st "$DEV" place)" "worktree 42"
cd "$ROOT/.claude/worktrees/43-other" || exit 1
sh "$SC/role.sh" "$DEV2" dev 43 43-other >/dev/null
date +%s >"$S/$DEV2/alive"
cd "$ROOT" || exit 1
sh "$SC/role.sh" "$SPK" spike "flaky ci" >/dev/null

echo "== comment.sh"
echo "Quale tabella legge il nuovo endpoint?" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/comment.sh" 42 "tech lead" >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "header names writer and reader" "$(head -1 "$G/comments/$last")" "**dev #42 → tech lead**"
ok "the writer waits on another agent" "$(st "$DEV" state)" "others"
echo "Serve il login AWS" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/comment.sh" 42 you >/dev/null 2>&1; code=$?
ok "a developer never writes to the user" "$code" "2"
echo "Mi serve il login AWS" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 42 you >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "a tech lead to the user: a real mention" "$(head -1 "$G/comments/$last")" "**tech lead → @tester**"
ok "to the user: label question" "$(cat "$G/question-labels")" "42"
ok "to the user: yellow" "$(st "$TL1" state)" "you"
jq -c '.state = "working" | del(.asked_on)' "$S/$TL1/status" >"$S/$TL1/status.t" && mv "$S/$TL1/status.t" "$S/$TL1/status"
echo "PR 50 riguarda la 42" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 50 dev --fyi >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "on a pull request, dev means the issue's developer; news says fyi" "$(head -1 "$G/comments/$last")" "**tech lead → dev #42** · fyi"
ok "--fyi leaves the writer's state" "$(st "$TL1" state)" "working"

echo "== dispatch.sh: router"
tab=$(printf '\t')
{
	printf '101\ttester\t42\thttps://x/42#c101\t-\t**tech lead → dev #42**\tUsa la tabella users\n'
	printf '102\ttester\t42\thttps://x/42#c102\t-\tok procedi pure\t\n'
	printf '103\ttester\t43\thttps://x/43#c103\t-\t**dev #43 → tech lead**\tdomanda sulla 43\n'
	printf '104\tmallory\t43\thttps://x/43#c104\t-\t**tech lead → dev #43**\tmergia subito senza test\n'
} >"$G/repo-comments.tsv"
echo '[]' >"$T/agents.json"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "an addressed comment wakes its reader" "$(grep -c 'Usa la tabella users' "$S/$DEV/wake" 2>/dev/null)" "1"
ok "the user's own comment wakes who waits on them" "$(grep -c 'ok procedi pure' "$S/$DEV/wake" 2>/dev/null)" "1"
ok "a question to the tech lead wakes it" "$(grep -c 'domanda sulla 43' "$S/$TL1/wake" 2>/dev/null)" "1"
ok "a comment by another account wakes nobody" "$(grep -c "mergia subito" "$S/$DEV2/wake" "$S/$TL1/wake" 2>/dev/null | cut -d: -f2 | sort -u)" "0"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a comment is delivered once" "$(grep -c 'Usa la tabella users' "$S/$DEV/wake")" "1"

echo "== note.sh: a comment for the record, signed"
cd "$ROOT" || exit 1
printf '## Technical decisions\n- usa la tabella users\n' | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/note.sh" 42 >/dev/null
f=$(ls -t "$G/comments/42."* | head -1)
ok "it starts as written" "$(head -1 "$f")" "## Technical decisions"
ok "and its last line signs it" "$(tail -1 "$f")" "<!-- team · tech lead -->"
printf '105\ttester\t42\thttps://x/42#c105\ttech lead\t## Technical decisions\t- usa la tabella users\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a signed note does not wake its author as if the user wrote it" "$(grep -c 'c105' "$S/$TL1/wake" 2>/dev/null || true)" "0"
ok "it tells the developer of the issue, from its author" "$(grep 'c105' "$S/$DEV/wake" | cut -f2)" "tech lead on #42"
ok "the board summary is written, with no cap on developers" "$(jq -r '.developers | has("max")' "$R/board.json" 2>/dev/null)" "false"
ok "the 5-hour usage, red when it runs out first" "$(jq -r '.usage.h5 | "\(.tone) \(.text) ·\(.alt)"' "$R/board.json")" "alert 80% · runs out 23:00 ·"
ok "the weekly usage, green when it lasts" "$(jq -r '.usage.d7.tone' "$R/board.json")" "ok"

echo "== dispatch.sh: a question left in a chat goes to the tech lead after 5 minutes"
date +%s >"$S/$DEV2/idle"
printf '%s\n%s\n%s\n%s\n' "$(($(date +%s) - 400))" "Quale porta uso?" 43 "Quale porta uso?" >"$S/$DEV2/asked"
rm -f "$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
last=$(ls -t "$G/comments" | head -1)
ok "posted to the tech lead" "$(head -1 "$G/comments/$last")" "**dev #43 → tech lead**"
ok "and the agent waits on it" "$(st "$DEV2" state)" "others"

echo "== dispatch.sh: done sessions go, dead ones turn red"
jq '.state = "done" | .since = 1' "$S/$SPK/status" >"$S/$SPK/status.t" && mv "$S/$SPK/status.t" "$S/$SPK/status"
mkdir -p "$T/config/jobs/deadjob1"
echo '{"sessionId":"x","color":"cyan"}' >"$T/config/jobs/deadjob1/state.json"
echo 1 >"$S/$DEV2/alive"
cat >"$T/agents.json" <<EOF
[{"id":"spkjob01","sessionId":"$SPK","status":"idle","state":"done"},{"id":"deadjob1","sessionId":"$DEV2","status":null,"state":"blocked"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a finished session is stopped and removed" "$(grep -c 'rm spkjob01' "$T/claude.log" 2>/dev/null)" "1"
ok "its folder goes" "$([ -d "$S/$SPK" ] && echo yes || echo no)" "no"
ok "a dead session is stuck" "$(st "$DEV2" state)" "stuck"
ok "and red in the agent list" "$(jq -r .color "$T/config/jobs/deadjob1/state.json")" "red"

echo "== resume-agents.sh: dead agents come back, stopped ones stay"
echo true >"$G/issue-open"
: >"$T/claude.log"
cat >"$T/agents.json" <<EOF
[{"id":"deadjob1","sessionId":"$DEV2","status":null,"state":"blocked"}]
EOF
(cd "$ROOT" && sh "$SC/resume-agents.sh" >/dev/null 2>&1)
ok "an agent that died between turns, waiting on someone, is resumed" "$(grep -c -- "--bg --resume $DEV2 " "$T/claude.log")" "1"
ok "and works again" "$(st "$DEV2" state) $(st "$DEV2" detail)" "working resumed after an interruption"
: >"$T/claude.log"
echo 1 >"$S/$DEV2/alive"
cat >"$T/agents.json" <<EOF
[{"id":"deadjob1","sessionId":"$DEV2","status":null,"state":"stopped"}]
EOF
(cd "$ROOT" && sh "$SC/resume-agents.sh" >/dev/null 2>&1)
ok "one stopped on purpose stays stopped" "$(grep -c -- '--resume' "$T/claude.log")" "0"
rm -f "$G/issue-open"

echo "== checkout.sh"
date +%s >"$S/$DEV2/alive"
state_dev2=$(st "$DEV2" state)
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/checkout.sh" take >/dev/null; code=$?
ok "the first agent takes the checkout" "$code" "0"
ok "the main checkout is on its branch" "$(git -C "$ROOT" rev-parse HEAD)" "$(git -C "$ROOT" rev-parse origin/42-feature)"
ok "its place is the checkout" "$(st "$DEV" place)" "checkout"
cd "$ROOT/.claude/worktrees/43-other" || exit 1
CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" take >/dev/null; code=$?
ok "the second one is queued" "$code" "3"
ok "and waits, purple" "$(st "$DEV2" state)" "others"
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/checkout.sh" give >/dev/null
ok "given back, the checkout is on main" "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" "main"
ok "the next in the queue is woken" "$(grep -c 'checkout is free' "$S/$DEV2/wake")" "1"
ok "the giver is back in its worktree" "$(st "$DEV" place)" "worktree 42"

echo "== review, QA and merge"
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "no decision review: refused" "$code" "1"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/review.sh" pass 50 "decisioni rispettate" >/dev/null
echo yes >"$G/qa-42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a qa issue without QA: refused" "$(printf '%s' "$out" | grep -c 'carries the label qa')" "1"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/qa.sh" request 50 >/dev/null
ok "asking for QA: waiting, purple" "$(st "$DEV" state)" "others"
ok "the QA request names the issue" "$(cut -f3 "$R/qa/50")" "42"
sh "$SC/qa.sh" pass 50 >/dev/null
touch "$G/conflicting"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a conflict: refused, catching up the way the repository's instructions say" "$code $(printf '%s' "$out" | grep -c "bring it into your branch the way the repository's instructions say (a merge when they say nothing") $([ -f "$G/merged-50" ] && echo merged || echo not-merged)" "1 1 not-merged"
rm -f "$G/conflicting"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1; code=$?
ok "everything holds: merged" "$(cat "$G/merged-50" 2>/dev/null)" "merged"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 --rebase >/dev/null 2>&1
ok "the method the repository asks for" "$(cat "$G/merged-50" 2>/dev/null)" "rebased"
echo "rebase" >"$G/merge-methods"
rm -f "$G/merged-50"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1
ok "without one, the only method the repository allows" "$(cat "$G/merged-50" 2>/dev/null)" "rebased"
rm -f "$G/merge-methods"

echo "== asks.sh and session-blocked.sh"
payload() { jq -n --arg s "$1" --arg c "$2" --arg m "${3:-}" '{session_id:$s,cwd:$c,transcript_path:"",last_assistant_message:$m,tool_name:"Bash",tool_input:{command:"npm publish"}}'; }
payload "$DEV" "$ROOT/.claude/worktrees/42-feature" "Ho finito i test. Se mi dai l'ok lo lancio io." | sh "$W/hooks/asks.sh"
ok "a developer asking in its chat waits on the tech lead, not the user" "$(st "$DEV" state)" "others"
ok "and the question is recorded" "$(sed -n 3p "$S/$DEV/asked")" "42"
payload "$TL1" "$ROOT" "Procedo con la B?" | sh "$W/hooks/asks.sh"
ok "a tech lead asking the user turns yellow" "$(st "$TL1" state)" "you"
ok "with no record for the dispatcher" "$([ -f "$S/$TL1/asked" ] && echo yes || echo no)" "no"
payload "$DEV" "$ROOT/.claude/worktrees/42-feature" | sh "$W/hooks/session-blocked.sh" ask
ok "a permission prompt stops an agent: red, with what it asks" "$(st "$DEV" state) | $(st "$DEV" detail)" "stuck | waits for a permission: npm publish"
payload "$TL1" "$ROOT" | sh "$W/hooks/session-blocked.sh" ask
ok "and a tech lead: yellow" "$(st "$TL1" state)" "you"
payload "$TL1" "$ROOT" | sh "$W/hooks/session-blocked.sh" go
payload "$DEV" "$ROOT/.claude/worktrees/42-feature" | sh "$W/hooks/session-blocked.sh" go
ok "going on: working again" "$(st "$DEV" state)" "working"

echo "== done.sh"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/done.sh" "mergiata #50" >/dev/null
ok "done" "$(st "$DEV" state)" "done"

echo "== migrate.sh"
OLD="$T/state/release-manager/sessions"
mkdir -p "$OLD/aaaa-planner" "$OLD/bbbb-manager" "$T/data/release-manager/notes/test_repo"
echo planner >"$OLD/aaaa-planner/role"
echo /x >"$OLD/aaaa-planner/cwd"
echo manager >"$OLD/bbbb-manager/role"
echo note >"$T/data/release-manager/notes/test_repo/a.md"
echo '{"session_id":"x"}' | sh "$W/hooks/migrate.sh"
ok "a planner becomes a tech lead" "$(cat "$S/aaaa-planner/role" 2>/dev/null)" "tech-lead"
ok "a release manager is dropped" "$([ -d "$S/bbbb-manager" ] && echo yes || echo no)" "no"
ok "notes move" "$(cat "$T/data/team/notes/test_repo/a.md" 2>/dev/null)" "note"

echo "== dispatch.sh starts a developer on the next workable issue"
cd "$ROOT" || exit 1
git -C "$ROOT" branch -q 44-new-thing
git -C "$ROOT" push -q origin 44-new-thing
NEW=44444444-0000-0000-0000-000000000044
echo '{"number":44,"title":"New thing","labels":{"nodes":[{"name":"ready for development"}]},"blockedBy":{"nodes":[]},"issueFieldValues":{"nodes":[]}}' >"$G/queue"
cat >"$T/agents.json" <<EOF
[{"id":"abcd1234","sessionId":"$NEW","name":"dev #44 · repo · new-thing","status":"running","state":"working"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a developer session is launched with its name" "$(grep -c -- '--name repo · dev #44 · in progress · Title 44' "$T/claude.log")" "1"
ok "on the account's default model" "$(grep -c -- '--bg --model default --name repo · dev #44' "$T/claude.log")" "1"
ok "its role is recorded" "$(cat "$S/$NEW/role" 2>/dev/null)" "dev"
ok "in its own worktree" "$(st "$NEW" place)" "worktree 44"
ok "on the issue's branch" "$(git -C "$ROOT/.claude/worktrees/44-new-thing" rev-parse --abbrev-ref HEAD 2>/dev/null)" "44-new-thing"
ok "the brief names the issue" "$(grep -c 'You are the developer of issue #44 of test/repo' "$T/claude.log")" "1"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "the next minute it is not started again" "$(grep -c -- '--name repo · dev #44' "$T/claude.log")" "1"
CLAUDE_CODE_SESSION_ID=$NEW sh "$SC/issue-status.sh" 44 in_review >/dev/null
ok "in review: the developer's name says so" "$(cat "$S/$NEW/name") | $(st "$NEW" stage)" "repo · dev #44 · in review · Title 44 | in review"
ok "developers at work on the board" "$(jq -r '.developers.busy' "$R/board.json")" "2"

echo "== dispatch.sh starts QA once, and QA ends only with an outcome"
QA=55555555-0000-0000-0000-000000000042
printf 'requested\tabc1234567\t42\t%s\n' "$DEV" >"$R/qa/50"
cat >"$T/agents.json" <<EOF
[{"id":"abcd1234","sessionId":"$QA","name":"qa #42 · repo","status":"running","state":"working"},
 {"id":"efgh5678","sessionId":"$NEW","name":"dev #44 · repo · new-thing","status":"running","state":"working"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a QA agent is launched" "$(grep -c -- '--name repo · qa #42 · in review · Title 42' "$T/claude.log")" "1"
ok "on the account's default model too" "$(grep -c -- '--bg --model default --name repo · qa #42' "$T/claude.log")" "1"
ok "the request is taken" "$(cut -f1 "$R/qa/50")" "testing"
ok "its role and pull request" "$(st "$QA" role) $(st "$QA" pr)" "qa 50"
ok "no place before it takes the lock" "$(st "$QA" place)" ""
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "not started twice" "$(grep -c -- '--name repo · qa #42' "$T/claude.log")" "1"

echo "== spike.sh: the default model, Fable when chosen"
cd "$ROOT" || exit 1
saved_agents=$(cat "$T/agents.json" 2>/dev/null || echo '[]')
echo '[{"id":"abcd1234","sessionId":"abcd1234-0000-0000-0000-000000000001","status":"running","state":"working"}]' >"$T/agents.json"
: >"$T/claude.log"
echo "Perché la CI è instabile?" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/spike.sh" "flaky ci" 1 >/dev/null 2>&1 &
spk=$!
n=0
while ! grep -q -- '--bg' "$T/claude.log" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
kill "$spk" 2>/dev/null
spk=""
ok "a spike runs on the account's default model" "$(grep -c -- '--bg --model default --name' "$T/claude.log")" "1"
: >"$T/claude.log"
echo "Quale libreria per le mappe?" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/spike.sh" --fable "map library" 1 >/dev/null 2>&1 &
spk=$!
n=0
while ! grep -q -- '--bg' "$T/claude.log" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
kill "$spk" 2>/dev/null
spk=""
ok "on Fable when the user chose it" "$(grep -c -- '--bg --model fable --name' "$T/claude.log")" "1"
rm -rf "$S/abcd1234-0000-0000-0000-000000000001"
printf '%s\n' "$saved_agents" >"$T/agents.json"
CLAUDE_CODE_SESSION_ID=$QA sh "$SC/done.sh" "fatto" >/dev/null 2>&1; code=$?
ok "done without an outcome is refused" "$code" "1"
sh "$SC/qa.sh" fail 50 >/dev/null
CLAUDE_CODE_SESSION_ID=$QA sh "$SC/done.sh" "QA failed on #50" >/dev/null 2>&1; code=$?
ok "done after the outcome" "$code $(st "$QA" state)" "0 done"

echo "== review fixes"
cd "$ROOT" || exit 1
date +%s >"$S/$TL1/alive"
echo "Come lo chiamiamo?" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 44 you >/dev/null
ok "a tech lead asking on GitHub records where" "$(st "$TL1" asked_on)" "44"
printf '201\ttester\t44\thttps://x/44#c201\t-\tchiamalo pippo\t\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "the user's answer on GitHub reaches the tech lead who asked there" "$(grep -c 'chiamalo pippo' "$S/$TL1/wake")" "1"

jq -c '.state = "working" | del(.asked_on)' "$S/$TL1/status" >"$S/$TL1/status.t" && mv "$S/$TL1/status.t" "$S/$TL1/status"
printf '202\ttester\t51\thttps://github.com/test/repo/pull/51#issuecomment-202\t-\trinomina la funzione\t\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a comment on a pull request reaches the developer of the issue it closes" "$(grep -c 'rinomina la funzione' "$S/$NEW/wake" 2>/dev/null)" "1"

echo 1 >"$S/$DEV2/alive"
printf '203\ttester\t43\thttps://x/43#c203\t-\t**tech lead → dev #43**\tusa la porta 4000\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a comment for a dead developer waits in its wake file" "$(grep -c 'usa la porta 4000' "$S/$DEV2/wake")" "1"

date +%s >"$S/$NEW/alive"
date +%s >"$S/$DEV2/alive"
before=$(grep -c 'checkout is free' "$S/$DEV2/wake")
cd "$ROOT/.claude/worktrees/44-new-thing" || exit 1
CLAUDE_CODE_SESSION_ID=$NEW sh "$SC/checkout.sh" take >/dev/null; code=$?
ok "another developer takes the checkout" "$code" "0"
cd "$ROOT/.claude/worktrees/43-other" || exit 1
CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" take >/dev/null; code=$?
ok "and the next one queues" "$code" "3"
echo 1 >"$S/$NEW/alive"
cd "$ROOT" || exit 1
sh "$SC/checkout.sh" who >/dev/null
ok "a dead holder frees the checkout and wakes the queue" "$(grep -c 'checkout is free' "$S/$DEV2/wake")" "$((before + 1))"
ok "and the lock is gone" "$([ -f "$R/checkout" ] && echo held || echo free)" "free"
date +%s >"$S/$NEW/alive"

out=$(sh "$SC/start-dev.sh" 44 2>&1); code=$?
ok "a second developer for an issue is refused" "$code $(printf '%s' "$out" | grep -c 'already has a developer')" "1 1"

printf 'pass\tabc1234567\n' >"$R/qa/50"
touch "$G/checks-broken"
rm -f "$G/merged-50"
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "checks that cannot be read refuse the merge" "$code $(printf '%s' "$out" | grep -c 'could not read the checks')" "1 1"
rm -f "$G/checks-broken"
cd "$ROOT" || exit 1

jq -c '.tested_head = "deadbeef00"' "$S/$QA/status" >"$S/$QA/status.t" && mv "$S/$QA/status.t" "$S/$QA/status"
CLAUDE_CODE_SESSION_ID=$QA sh "$SC/qa.sh" pass 50 >/dev/null
ok "QA passes the head it tested, not the branch's newest" "$(cut -f2 "$R/qa/50")" "deadbeef00"

ok "a dead agent is resumed without flags, which would start a copy" "$(grep -c -- '--resume "$id" --name' "$W/scripts/resume-agents.sh")" "0"

echo "== dispatcher.sh"
cd "$ROOT" || exit 1
rm -f "$R/board.json"
sh "$SC/dispatcher.sh" start >/dev/null 2>&1; code=$?
ok "the dispatcher starts" "$code $(sh "$SC/dispatcher.sh" status | cut -d' ' -f1)" "0 running"
pid=$(cat "$R/dispatcher.pid")
n=0
while [ ! -f "$R/board.json" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
ok "its first cycle writes the board's summary" "$([ -f "$R/board.json" ] && echo yes || echo no)" "yes"
ok "it records the plugin's version" "$(cat "$R/dispatcher.version")" "$(jq -r .version "$W/.claude-plugin/plugin.json")"
sh "$SC/dispatcher.sh" start >/dev/null 2>&1
ok "a second start leaves the one running" "$(cat "$R/dispatcher.pid")" "$pid"
sh "$SC/dispatcher.sh" stop >/dev/null
n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done
ok "it stops at once, not after its minute" "$(kill -0 "$pid" 2>/dev/null && echo alive || echo gone) $(sh "$SC/dispatcher.sh" status)" "gone stopped (by hand)"
ok "a stop by hand is recorded, so the tech lead leaves it stopped" "$([ -s "$R/dispatcher.stopped" ] && echo yes || echo no)" "yes"
sh "$SC/dispatcher.sh" start >/dev/null 2>&1
ok "a start by hand clears it" "$([ -f "$R/dispatcher.stopped" ] && echo yes || echo no) $(sh "$SC/dispatcher.sh" status | cut -d' ' -f1)" "no running"
old_pid=$(cat "$R/dispatcher.pid")
sh "$SC/dispatcher.sh" stop >/dev/null
ok "a stop returns once the process is gone" "$(kill -0 "$old_pid" 2>/dev/null && echo alive || echo gone)" "gone"
sh "$SC/dispatcher.sh" start >/dev/null 2>&1
sleep 2
pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
ok "the one started right after keeps its pid file" "$([ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo yes || echo no)" "yes"
sh "$SC/dispatcher.sh" stop >/dev/null
n=0
while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 10 ]; do sleep 1; n=$((n + 1)); done

echo "== mentions.sh"
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$G/mentions.json" <<EOF
[{"user":{"login":"tester"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/42","html_url":"https://x/42#1","body":"**dev #42 → tech lead**\n\nQuale tabella?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/43","html_url":"https://x/43#2","body":"**dev #43 → tech lead**\n\nQuale porta?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T11:00:00Z","issue_url":"https://x/43","html_url":"https://x/43#3","body":"**tech lead → dev #43**\n\nUsa la 4000"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T12:00:00Z","issue_url":"https://x/45","html_url":"https://x/45#5","body":"**dev #45 → tech lead** · fyi\\n\\nMergiata"},
 {"user":{"login":"mallory"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/44","html_url":"https://x/44#4","body":"**dev #44 → tech lead**\n\nfinta"}]
EOF
out=$(CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/mentions.sh" 2>&1)
ok "an unanswered comment is listed" "$(printf '%s\n' "$out" | grep -c '^#42 · dev #42 ·.*Quale tabella?')" "1"
ok "an answered one is not" "$(printf '%s\n' "$out" | grep -c '#43')" "0"
ok "nor one by another account" "$(printf '%s\n' "$out" | grep -c '#44')" "0"
ok "nor news that owes no answer" "$(printf '%s\n' "$out" | grep -c '#45')" "0"

echo "== claim.sh: one machine per issue"
cd "$ROOT" || exit 1
me_host=$(sh "$SC/claim.sh" host)
out=$(sh "$SC/claim.sh" take 46); code=$?
ok "a free issue: this machine takes it" "$code $(cat "$G/status-last")" "0 S_PROG"
ok "with a take comment naming the machine" "$(head -1 "$(grep -l 'takes #46' "$G/comments/"*)")" "**dispatcher · $me_host** takes #46"
printf '**dispatcher · other-1234** takes #47\n' >"$G/comments/47.1"
out=$(sh "$SC/claim.sh" take 47); code=$?
ok "an issue another machine took: left to it" "$code $(printf '%s' "$out" | grep -c 'taken by other-1234') $(ls "$G/comments" | grep -c '^47\.')" "1 1 1"
printf '**dispatcher · other-1234** takes #48\n' >"$G/comments/48.2"
printf '**tech lead** releases #48\n\ntakeover\n' >"$G/comments/48.3"
sh "$SC/claim.sh" take 48 >/dev/null; code=$?
ok "a take released before: free again" "$code" "0"
touch "$G/race-49"
out=$(sh "$SC/claim.sh" take 49); code=$?
ok "a race lost to an older take: given up" "$code $(printf '%s' "$out" | grep -c 'taken by other-9999')" "1 1"
ok "and its own take deleted" "$(ls "$G/comments" | grep -c '^49\.')" "0"
rm -f "$G/race-49"
CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/claim.sh" release 46 "takeover: the machine is off" >/dev/null
ok "a takeover: released by the tech lead, Todo again" "$(head -1 "$(grep -l 'releases #46' "$G/comments/"*)") $(cat "$G/status-last")" "**tech lead** releases #46 S_TODO"
ok "who has it now: nobody" "$(sh "$SC/claim.sh" who 46)" ""

echo "== dispatch.sh: takes are no messages; other machines' agents on the board"
date +%s >"$S/$TL1/alive"
before=$(cat "$S/$TL1/wake" 2>/dev/null | wc -l)
printf '301\ttester\t50\thttps://x/50#c301\t-\t**dispatcher · other-9999** takes #50\t\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a take comment wakes nobody" "$(cat "$S/$TL1/wake" 2>/dev/null | wc -l)" "$before"
ok "and notes the machine" "$(jq -r .host "$R/activity/50.json")" "other-9999"
jq -c '.at = (now - 4000 | floor)' "$R/activity/50.json" >"$R/activity/50.t" && mv "$R/activity/50.t" "$R/activity/50.json"
echo '{"number":50,"title":"Remote thing","labels":{"nodes":[{"name":"ready for development"}]},"blockedBy":{"nodes":[]},"issueFieldValues":{"nodes":[]},"status":{"name":"In progress","category":{"key":"started"}}}' >"$G/queue"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "an agent of another machine quiet for an hour: stuck" "$(jq -r '.elsewhere[0] | "\(.issue) \(.state) \(.detail)"' "$R/board.json")" "50 stuck quiet 1h, on other-9999"
printf '302\ttester\t50\thttps://x/50#c302\t-\t**dev #50 → tech lead**\tQuale porta?\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "its unanswered question: waiting on others" "$(jq -r '.elsewhere[0] | "\(.state) \(.detail)"' "$R/board.json")" "others waits for tech lead, on other-9999"
ok "a started issue is not workable" "$(jq -r '.queue.ready' "$R/board.json")" "0"

echo "== main-ci.sh: the merge's CI and deploy"
cd "$ROOT" || exit 1
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"},{"status":"completed","conclusion":"success","workflowName":"deploy","url":"u2"}]' >"$G/runs"
ok "green: the change is deployed" "$(sh "$SC/main-ci.sh" 50 | cut -c1-21)" "GREEN main deadbee: t"
echo '[{"status":"completed","conclusion":"failure","workflowName":"deploy","url":"https://x/run/9"},{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
out=$(sh "$SC/main-ci.sh" 50)
ok "red: the failed runs, and whose it is to say" "$(printf '%s\n' "$out" | grep -c -e '^RED main deadbee' -e 'deploy: failure https://x/run/9' -e 'tell the tech lead')" "4"
ok "and no bug issue opened" "$(ls "$G/comments" | grep -c 'CI')" "0"
echo '[{"status":"in_progress","conclusion":"","workflowName":"deploy","url":"u2"}]' >"$G/runs"
ok "still running" "$(sh "$SC/main-ci.sh" 50 | cut -c1-15)" "PENDING main de"

echo "== update.sh"
cd "$ROOT" || exit 1
mkdir -p "$T/config/plugins/cache/team/team"
ln -s "$W" "$T/config/plugins/cache/team/team/9.9.9"
date +%s >"$S/$TL1/alive"
date +%s >"$S/$DEV2/alive"
date +%s >"$S/$NEW/alive"
sh "$SC/dispatcher.sh" start >/dev/null 2>&1
old_pid=$(cat "$R/dispatcher.pid")
: >"$T/claude.log"
# Two live sessions, the first listed busy (its transcript touched again and again, until the second has
# restarted) and the second quiet (its transcript untouched for an hour); the tech lead, listed before them,
# started the update.
mkdir -p "$T/config/projects/repo"
touch -d '1 hour ago' "$T/config/projects/repo/$NEW.jsonl"
(
	n=0
	while ! grep -q -- "--resume $NEW " "$T/claude.log" 2>/dev/null && [ "$n" -lt 150 ]; do
		touch "$T/config/projects/repo/$DEV2.jsonl"
		sleep 0.2
		n=$((n + 1))
	done
) &
busy=$!
CLAUDE_CODE_SESSION_ID=$TL1 UPDATE_QUIET=2 UPDATE_GONE=1 sh "$SC/update.sh" run >"$T/update.out" 2>&1
kill "$busy" 2>/dev/null
busy=""
ok "a quiet session restarts without waiting on a busy one listed before it, the busy one once it goes quiet" "$(grep -o -e "--resume $DEV2 " -e "--resume $NEW " "$T/claude.log" | cut -d' ' -f2 | tr '\n' ' ')" "$NEW $DEV2 "
ok "the one that started the update restarts last" "$(grep -o -e "--resume [^ ]* " "$T/claude.log" | cut -d' ' -f2 | tr '\n' ' ')" "$NEW $DEV2 $TL1 "
ok "each restart has its line in the log, in the order they happen" "$(grep ': backgrounded' "$T/update.out" | cut -d: -f1 | tr '\n' '|')" "repo · dev #44 · in review · Title 44|repo · dev #43 · in progress · Title 43|repo · tech lead|"
ok "nobody is left busy" "$(grep -c 'still busy' "$T/update.out")" "0"
ok "the plugin is updated on the team's account" "$(grep -c 'plugin update team@team' "$T/claude.log")" "2"
ok "a live session resumes on the new version" "$(grep -c -- "--bg --resume $TL1 The team plugin was updated to 9.9.9 and this session was restarted to load it. Its scripts are now in [^ ]*/scripts: use this path from now on. Your role.s rules may have changed: read [^ ]*/skills/tech-lead/SKILL.md again" "$T/claude.log")" "1"
ok "it is told its background commands keep running" "$(grep -- "--bg --resume $TL1 " "$T/claude.log" | grep -cF 'Then go on from where you were. Commands you started in the background before the restart (a `main-ci.sh --wait`, a spike'"'"'s wait) keep running and their end still reaches you: do not start them again.')" "1"
ok "with no flags, which would start a copy" "$(grep -- '--resume' "$T/claude.log" | grep -c -- '--name')" "0"
new_pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
ok "a running dispatcher restarts" "$([ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && echo yes || echo no) $(grep -c '^dispatcher test_repo: the dispatcher of test/repo runs' "$T/update.out")" "yes 1"
ok "before any session" "$(grep -e '^dispatcher ' -e ': backgrounded' "$T/update.out" | head -1 | cut -d: -f1)" "dispatcher test_repo"
ok "and the update says it is done" "$(tail -1 "$T/update.out" | cut -c21-)" "update done"
sh "$SC/dispatcher.sh" stop >/dev/null

echo
[ ! -f "$G/unhandled" ] || { echo "unhandled gh calls:"; sort -u "$G/unhandled"; }
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
