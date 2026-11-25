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
"issue comment "*" --body-file -")
	n=$(cat "$G/next-id" 2>/dev/null || echo 1); echo $((n + 1)) >"$G/next-id"; cat >"$G/comments/$3.$n"
	# The repository a comment went to with -R, beside it.
	[ "$4" != -R ] || echo "$3.$n $5" >>"$G/comment-repos"
	echo "https://github.com/test/repo/issues/$3#issuecomment-$n" ;;
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
"pr view 50 --json headRefOid,state,mergeable,closingIssuesReferences")
	m=MERGEABLE
	[ ! -f "$G/conflicting" ] || m=CONFLICTING
	echo '{"headRefOid":"'"$(cat "$G/head-50" 2>/dev/null || echo abc1234567)"'","state":"OPEN","mergeable":"'"$m"'","closingIssuesReferences":[{"number":42}]}' ;;
"pr checks 50 --json state,name") [ ! -f "$G/checks-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; echo '[{"name":"build","state":"SUCCESS"}]' ;;
"pr view 51 --json closingIssuesReferences --jq .closingIssuesReferences[0].number // empty") echo 44 ;;
"pr merge 50 --"*" --match-head-commit "*)
	# GitHub merges only the head it is told, and only when it is the pull request's.
	[ "$6" = "$(cat "$G/head-50" 2>/dev/null || echo abc1234567)" ] || { echo "head moved" >&2; exit 1; }
	case "$4" in --merge) echo merged >"$G/merged-50" ;; --rebase) echo rebased >"$G/merged-50" ;; esac ;;
"api repos/test/repo --jq "*) cat "$G/merge-methods" 2>/dev/null || echo "merge rebase squash" ;;
"label list --limit 200 --json name --jq .[].name") echo question ;;
"issue edit "*" --add-label question") echo "$3" >>"$G/question-labels" ;;
"issue view 42 --json labels --jq "*) cat "$G/qa-42" 2>/dev/null || echo no ;;
"issue view 42 --json comments --jq "*) [ ! -f "$G/comments-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; cat "$G/decided-42" 2>/dev/null || true ;;
"issue view "*" --json state,labels --jq "*) cat "$G/issue-open" 2>/dev/null || echo false ;;
"api --paginate repos/test/repo/issues/comments?since="*"per_page=100") cat "$G/mentions.json" 2>/dev/null || echo '[]' ;;
# The issues updated since the dispatcher's cursor, through the caller's --jq filter.
"api --paginate repos/test/repo/issues?state=all&since="*) [ ! -f "$G/repo-issues.json" ] || jq -r "$5" "$G/repo-issues.json" ;;
"api --paginate repos/test/repo/issues/comments?since="*)
	# A JSON listing is answered as GitHub does: the comments updated since the cursor, edits too, through the
	# caller's --jq filter. Otherwise the rows that filter would give.
	if [ -f "$G/repo-comments.json" ]; then
		s=$(printf '%s' "$3" | sed -n 's/.*since=\([^&]*\).*/\1/p')
		jq --arg s "$s" '[.[] | select(.updated_at >= $s)]' "$G/repo-comments.json" | jq -r "$5"
	else
		cat "$G/repo-comments.tsv" 2>/dev/null
	fi ;;
"pr view 50 --json mergeCommit --jq .mergeCommit.oid // empty") echo deadbeefcafe ;;
"run list --commit deadbeefcafe "*) cat "$G/runs" 2>/dev/null || echo '[]' ;;
"run list "*) echo '[]' ;;
"workflow list "*) [ ! -f "$G/workflows-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; cat "$G/workflows" 2>/dev/null || true ;;
"workflow view "*" --yaml --ref main") cat "$G/workflow-$3.yml" 2>/dev/null || { echo "HTTP 404: Not Found" >&2; exit 1; } ;;
"api graphql "*)
	case "$*" in
	*planningStatuses*) echo '[{"id":"S_TODO","name":"Todo"},{"id":"S_PROG","name":"In progress"},{"id":"S_REV","name":"In review"}]' ;;
	*setIssueStatus*) printf '%s\n' "$*" | grep -o 'S_[A-Z]*' | head -1 >"$G/status-last"; echo '{}' ;;
	# The boards: what is sent to add a Status option is kept, and the field comes back with the ids sent.
	*"--input -"*) cat >"$G/add-status-sent"; jq -c '[.variables.o[] | {id: (.id // "OPT_NEW"), name}]' "$G/add-status-sent" ;;
	*projectItems*) cat "$G/items.json" 2>/dev/null || echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' ;;
	*updateProjectV2ItemFieldValue*) printf '%s\n' "$*" | grep -o 'OPT_[A-Z]*' | head -1 >>"$G/card-moves"; echo '{}' ;;
	*projectsV2*) cat "$G/boards.json" 2>/dev/null || echo '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}' ;;
	*"projectV2(number"*) cat "$G/board.json" 2>/dev/null || echo null ;;
	*"issue(number"*) echo I_1 ;;
	*) cat "$G/queue" 2>/dev/null ;;
	esac ;;
"issue develop 44 --list") echo "44-new-thing	https://x" ;;
# The plugin's own repository, for report.sh. The REST listing has an issue as soon as it is opened, and a
# pull request among the issues it lists; the search index behind `gh issue list --label` has not seen it yet.
"api repos/"*"/issues?labels=flow-report&state=open&per_page=100")
	{
		for f in "$G/reports/"*; do [ -f "$f" ] || continue; jq -n --rawfile t "$f" --argjson n "${f##*/}" '{number: $n, title: ($t | rtrimstr("\n"))}'; done
		[ ! -f "$G/report-pr" ] || jq -n --rawfile t "$G/report-pr" '{number: 900, title: ($t | rtrimstr("\n")), pull_request: {url: "https://x/pulls/900"}}'
	} | jq -s '.' ;;
"issue list -R "*" --state open --label flow-report "*) echo '[]' ;;
"label list -R "*" --limit 200 --json name --jq .[].name") echo flow-report ;;
"issue create -R "*" --label flow-report --body-file -")
	n=$(cat "$G/next-id" 2>/dev/null || echo 1); echo $((n + 1)) >"$G/next-id"
	mkdir -p "$G/reports"; printf '%s\n' "$6" >"$G/reports/$n"; cat >"$G/report-body.$n"; echo "https://github.com/x/y/issues/$n" ;;
# An issue opened on another repository (open-issue.sh --repo): what was asked, and its body.
"issue create -R "*" --title "*" --assignee "*" --body-file -") echo "$*" >"$G/created-elsewhere.args"; cat >"$G/created-elsewhere.body"; echo "https://github.com/$4/issues/77" ;;
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
ok "and records whom it waits on" "$(st "$DEV" waits_on)" "tech lead"
echo "Serve il login AWS" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/comment.sh" 42 you >/dev/null 2>&1; code=$?
ok "a developer never writes to the user" "$code" "2"
echo "Mi serve il login AWS" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 42 you >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "a tech lead to the user: a real mention" "$(head -1 "$G/comments/$last")" "**tech lead → @tester**"
ok "to the user: label question" "$(cat "$G/question-labels")" "42"
ok "to the user: yellow" "$(st "$TL1" state)" "you"
ok "to the user: waits on the user" "$(st "$TL1" waits_on)" "the user"
# The user's answer reached it: the hooks module ended the wait.
jq -c '.state = "working" | del(.asked_on, .waits_on)' "$S/$TL1/status" >"$S/$TL1/status.t" && mv "$S/$TL1/status.t" "$S/$TL1/status"
echo "PR 50 riguarda la 42" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 50 dev --fyi >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "on a pull request, dev means the issue's developer; news says fyi" "$(head -1 "$G/comments/$last")" "**tech lead → dev #42** · fyi"
ok "--fyi leaves the writer's state" "$(st "$TL1" state)" "working"
ok "--fyi records nobody to wait on" "$(st "$TL1" waits_on)" ""

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

echo "== on another repository: comment.sh, note.sh and open-issue.sh --repo"
cd "$ROOT" || exit 1
repo_of_last() { grep "^$(basename "$1") " "$G/comment-repos" | cut -d' ' -f2; }
before=$(jq -c '{state, detail, waits_on}' "$S/$TL1/status")
echo "Ci serve un endpoint per gli ordini" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 7 "tech lead" --repo someone/else >/dev/null
f=$(ls -t "$G/comments/7."* | head -1)
ok "comment.sh --repo writes on that repository" "$(repo_of_last "$f")" "someone/else"
ok "its header names this repository's tech lead and that one's" "$(head -1 "$f")" "**tech lead of test/repo → tech lead**"
ok "and its last line signs it with this repository" "$(tail -1 "$f")" "<!-- team · tech lead of test/repo -->"
ok "the writer's state does not change, nobody is waited on" "$(jq -c '{state, detail, waits_on}' "$S/$TL1/status")" "$before"
echo "Fatto dal nostro lato" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 7 "tech lead" --fyi --repo someone/else >/dev/null
f=$(ls -t "$G/comments/7."* | head -1)
ok "--fyi still marks its header" "$(head -1 "$f")" "**tech lead of test/repo → tech lead** · fyi"
echo "x" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/comment.sh" 7 "tech lead" --repo someone/else >/dev/null 2>&1; code=$?
ok "only a tech lead writes on another repository" "$code" "2"
echo "x" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 7 dev --repo someone/else >/dev/null 2>&1; code=$?
ok "and only to its tech lead" "$code" "2"
echo "x" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 7 "tech lead" --repo Test/Repo >/dev/null 2>&1; code=$?
ok "--repo names another repository, never this one" "$code" "2"
printf 'Trovato: gli ordini annullati restano aperti\n' | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/note.sh" 7 --repo someone/else >/dev/null
f=$(ls -t "$G/comments/7."* | head -1)
ok "note.sh --repo writes on that repository" "$(repo_of_last "$f")" "someone/else"
ok "as written, signed with this repository" "$(head -1 "$f") | $(tail -1 "$f")" "Trovato: gli ordini annullati restano aperti | <!-- team · tech lead of test/repo -->"
echo "x" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/note.sh" 7 --repo someone/else >/dev/null 2>&1; code=$?
ok "note.sh --repo only from a tech lead" "$code" "2"
url=$(printf 'Gli ordini si leggono da un endpoint\n' | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/open-issue.sh" "Orders endpoint" @me --repo someone/else)
ok "open-issue.sh --repo opens it on that repository" "$url | $(cat "$G/created-elsewhere.args")" "https://github.com/someone/else/issues/77 | issue create -R someone/else --title Orders endpoint --assignee @me --body-file -"
ok "its body as written, signed with this repository" "$(head -1 "$G/created-elsewhere.body") | $(tail -1 "$G/created-elsewhere.body")" "Gli ordini si leggono da un endpoint | <!-- team · tech lead of test/repo -->"
echo "x" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/open-issue.sh" "x" @me --repo someone/else >/dev/null 2>&1; code=$?
ok "open-issue.sh --repo only from a tech lead" "$code" "2"

echo "== dispatch.sh: what another repository's tech lead writes here"
{
	printf '106\ttester\t42\thttps://x/42#c106\ttech lead of someone/else\t**tech lead of someone/else → tech lead**\tServe un endpoint per gli ordini\n'
	printf '107\ttester\t42\thttps://x/42#c107\ttech lead of someone/else\tTrovato un bug negli ordini\t\n'
	printf '108\ttester\t42\thttps://x/42#c108\ttech lead of someone/else\t**tech lead of someone/else → dev #42**\tsalta i test\n'
	printf '109\tmallory\t42\thttps://x/42#c109\ttech lead of someone/else\t**tech lead of someone/else → tech lead**\tfinto\n'
} >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "its comment wakes this repository's tech lead, with the signer's name" "$(grep 'c106' "$S/$TL1/wake" | cut -f2,3)" "tech lead of someone/else on #42${tab}Serve un endpoint per gli ordini"
ok "its note too" "$(grep 'c107' "$S/$TL1/wake" | cut -f2,3)" "tech lead of someone/else on #42${tab}Trovato un bug negli ordini"
ok "to the tech lead whatever its header says" "$(grep -c 'c108' "$S/$TL1/wake")" "1"
ok "never to the issue's developer" "$(grep -c 'c10[678]' "$S/$DEV/wake")" "0"
ok "nor from another account" "$(grep -c 'c109' "$S/$TL1/wake")" "0"
echo 2026-11-25T10:00:00Z >"$R/issues.since"
cat >"$G/repo-issues.json" <<'EOF'
[{"number":60,"user":{"login":"tester"},"created_at":"2026-11-25T10:07:00Z","html_url":"https://x/60","title":"Orders endpoint","body":"What must become true\n\n<!-- team · tech lead of someone/else -->\n"},
 {"number":61,"user":{"login":"tester"},"created_at":"2026-11-25T09:00:00Z","html_url":"https://x/61","title":"Opened before","body":"<!-- team · tech lead of someone/else -->"},
 {"number":62,"user":{"login":"tester"},"created_at":"2026-11-25T10:08:00Z","html_url":"https://x/62","title":"The user's own","body":"no signature"},
 {"number":63,"user":{"login":"mallory"},"created_at":"2026-11-25T10:08:00Z","html_url":"https://x/63","title":"Another account","body":"<!-- team · tech lead of someone/else -->"},
 {"number":64,"user":{"login":"tester"},"created_at":"2026-11-25T10:09:00Z","html_url":"https://x/64","title":"A pull request","pull_request":{"url":"https://x/pulls/64"},"body":"<!-- team · tech lead of someone/else -->"},
 {"number":65,"user":{"login":"tester"},"created_at":"2026-11-25T10:09:00Z","html_url":"https://x/65","title":"From this repository","body":"<!-- team · tech lead of test/repo -->"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a new issue it opened here wakes this repository's tech lead" "$(grep 'https://x/60' "$S/$TL1/wake" | cut -f2,3)" "tech lead of someone/else on #60${tab}Orders endpoint"
ok "not an older one, an unsigned one, another account's, a pull request, this repository's own" "$(grep -c 'https://x/6[1-5]' "$S/$TL1/wake")" "0"
echo 2026-11-25T10:00:00Z >"$R/issues.since"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "an issue is delivered once" "$(grep -c 'https://x/60' "$S/$TL1/wake")" "1"
rm -f "$G/repo-issues.json"

echo "== dispatch.sh: only new comments are handed out, not edits"
# Two comments written before the cursor and edited after it, so the listing returns them; one written after.
echo 2026-11-25T10:00:00Z >"$R/comments.since"
cat >"$G/repo-comments.json" <<'EOF'
[{"id":110,"user":{"login":"tester"},"created_at":"2026-11-25T09:00:00Z","updated_at":"2026-11-25T10:05:00Z","issue_url":"https://x/42","html_url":"https://x/42#c110","body":"**tech lead → dev #42**\n\nmessaggio corretto"},
 {"id":111,"user":{"login":"tester"},"created_at":"2026-11-25T09:30:00Z","updated_at":"2026-11-25T10:06:00Z","issue_url":"https://x/42","html_url":"https://x/42#c111","body":"superato da un commento successivo"},
 {"id":112,"user":{"login":"tester"},"created_at":"2026-11-25T10:07:00Z","updated_at":"2026-11-25T10:07:00Z","issue_url":"https://x/42","html_url":"https://x/42#c112","body":"**tech lead → dev #42**\n\nnuovo messaggio"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "an old comment edited after the cursor wakes nobody" "$(cat "$S"/*/wake 2>/dev/null | grep -c 'c110\|c111')" "0"
ok "a new comment still wakes its reader" "$(grep -c 'c112' "$S/$DEV/wake" 2>/dev/null)" "1"
rm -f "$G/repo-comments.json"

echo "== dispatch.sh: a question left in a chat goes to the tech lead after 5 minutes"
date +%s >"$S/$DEV2/idle"
printf '%s\n%s\n%s\n%s\n' "$(($(date +%s) - 400))" "Quale porta uso?" 43 "Quale porta uso?" >"$S/$DEV2/asked"
rm -f "$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
last=$(ls -t "$G/comments" | head -1)
ok "posted to the tech lead" "$(head -1 "$G/comments/$last")" "**dev #43 → tech lead**"
ok "and the agent waits on it" "$(st "$DEV2" state)" "others"
ok "and records whom it waits on" "$(st "$DEV2" waits_on)" "tech lead"

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
waited_on=$(st "$DEV" waits_on)
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/checkout.sh" take >/dev/null; code=$?
ok "the first agent takes the checkout" "$code" "0"
ok "a script setting a state drops whom it waited on" "$waited_on -> $(st "$DEV" waits_on)" "tech lead -> "
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

echo "== checkout.sh take --as-is"
held() { [ -f "$R/checkout" ] && echo held || echo free; }
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
# A commit of main's own, so what stays checked out differs from the agent's branch.
git -C "$ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "on main only"
head_before=$(git -C "$ROOT" rev-parse HEAD)
echo staged >"$ROOT/staged.txt" && git -C "$ROOT" add staged.txt
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/checkout.sh" take --as-is >/dev/null 2>&1; code=$?
ok "take --as-is refuses a main checkout with local changes, as take does" "$code $(held)" "1 free"
git -C "$ROOT" rm -q --cached staged.txt && rm -f "$ROOT/staged.txt"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/checkout.sh" take --asis >/dev/null 2>&1; code=$?
ok "a mistyped option is refused and moves nothing" "$code $(git -C "$ROOT" rev-parse --abbrev-ref HEAD) $(held)" "2 main free"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/checkout.sh" take --as-is >/dev/null; code=$?
ok "take --as-is holds the checkout" "$code $(sed -n 1p "$R/checkout")" "0 $DEV"
ok "and leaves HEAD where it was" "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD) $(git -C "$ROOT" rev-parse HEAD)" "main $head_before"
ok "its place is the checkout" "$(st "$DEV" place)" "checkout"
ok "the head tested is the one checked out" "$(st "$DEV" tested_head)" "$head_before"
ok "who shows as-is after the holder's name" "$(cd "$ROOT" && sh "$SC/checkout.sh" who | head -1 | sed 's/ since [^,]*,/,/')" "held by dev #42 as-is, on main"
(cd "$ROOT" && sh "$SC/dispatch.sh" >/dev/null 2>&1)
ok "and so does the board's summary" "$(jq -r '.checkout.holder' "$R/board.json")" "dev #42 as-is"
cd "$ROOT/.claude/worktrees/43-other" || exit 1
CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" take >/dev/null; code=$?
ok "a second agent queues as it does with take" "$code $(st "$DEV2" state)" "3 others"
ok "its row names the holder with as-is" "$(st "$DEV2" detail)" "queued for the checkout (held by dev #42 as-is)"
woken=$(grep -c 'checkout is free' "$S/$DEV2/wake")
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/checkout.sh" give >/dev/null; code=$?
ok "give frees it, on main" "$code $(held) $(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" "0 free main"
ok "and wakes the next in the queue" "$(grep -c 'checkout is free' "$S/$DEV2/wake")" "$((woken + 1))"
git -C "$ROOT" reset -q --hard origin/main
cd "$ROOT/.claude/worktrees/43-other" || exit 1
CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" take >/dev/null
(cd "$ROOT" && sh "$SC/dispatch.sh" >/dev/null 2>&1)
ok "a take after it holds without as-is" "$(jq -r '.checkout.holder' "$R/board.json") $(cd "$ROOT" && sh "$SC/checkout.sh" who | head -1 | sed 's/ since [^,]*,/,/')" "dev #43 held by dev #43, on 43-other"
CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" give >/dev/null

echo "== review, QA and merge: on the branch, before the pull request"
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "no decision review: refused" "$code" "1"
# The developer's work, committed on its branch: no pull request yet.
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
reviewed=$(git rev-parse HEAD)
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/review.sh" pass 42 "decisioni rispettate" >/dev/null
ok "the decision review is recorded by issue, at the branch's HEAD" "$(cut -f1 "$R/review/42" 2>/dev/null) $([ -f "$R/review/50" ] && echo by-pr || echo not-by-pr)" "$reviewed not-by-pr"
echo yes >"$G/qa-42"
git push -q origin 42-feature
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/qa.sh" request 42 >/dev/null
ok "asking for QA: waiting, purple" "$(st "$DEV" state)" "others"
ok "the QA request is keyed by the issue, with the pushed head and the branch" "$(cut -f1,2,3,5 "$R/qa/42" 2>/dev/null)" "requested	$reviewed	42	42-feature"
sh "$SC/qa.sh" pass 42 >/dev/null
ok "the QA outcome is recorded by issue, at the pushed head" "$(cut -f1,2 "$R/qa/42")" "pass	$reviewed"
# The pull request is opened only now; at another head than the one reviewed, it is refused.
echo abc1234567 >"$G/head-50"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a pull request whose head has no passed review: refused" "$code $(printf '%s' "$out" | grep -c 'no decision review for the current head.*review.sh pass 42 ') $([ -f "$G/merged-50" ] && echo merged || echo not-merged)" "1 1 not-merged"
echo "$reviewed" >"$G/head-50"
rm -f "$R/qa/42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a qa issue without QA: refused" "$(printf '%s' "$out" | grep -c 'carries the label qa and the QA has not passed this head: qa.sh request 42')" "1"
sh "$SC/qa.sh" pass 42 >/dev/null 2>&1; code=$?
ok "an outcome with no head to name: refused" "$code $([ -f "$R/qa/42" ] && echo recorded || echo not-recorded)" "1 not-recorded"
printf 'pass\t%s\n' "$reviewed" >"$R/qa/42"
touch "$G/conflicting"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a conflict: refused, catching up the way the repository's instructions say" "$code $(printf '%s' "$out" | grep -c "bring it into your branch the way the repository's instructions say (a merge when they say nothing") $([ -f "$G/merged-50" ] && echo merged || echo not-merged)" "1 1 not-merged"
rm -f "$G/conflicting"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1; code=$?
ok "a review and a QA recorded on the branch before the pull request existed: merged" "$code $(cat "$G/merged-50" 2>/dev/null)" "0 merged"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 --rebase >/dev/null 2>&1
ok "the method the repository asks for" "$(cat "$G/merged-50" 2>/dev/null)" "rebased"
echo "rebase" >"$G/merge-methods"
rm -f "$G/merged-50"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1
ok "without one, the only method the repository allows" "$(cat "$G/merged-50" 2>/dev/null)" "rebased"
rm -f "$G/merge-methods"

echo "== merge.sh: Technical decisions newer than the review or the QA"
merged() { [ -f "$G/merged-50" ] && echo merged || echo not-merged; }
stamp='^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$'
echo no >"$G/qa-42"
rm -f "$G/merged-50"
sleep 1
date -u +%Y-%m-%dT%H:%M:%SZ >"$G/decided-42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a review, then newer decisions: refused, asking for a new review" "$code $(printf '%s' "$out" | grep -c 'the decisions changed after the review: run the decision review again') $(merged)" "1 1 not-merged"
sleep 1
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/review.sh" pass 42 "decisioni rispettate" >/dev/null
ok "the review records its time beside the head and the summary" "$(cut -f1,3 "$R/review/42") $(cut -f2 "$R/review/42" | grep -c "$stamp")" "$reviewed	decisioni rispettate 1"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1
ok "a new review: merged" "$(merged)" "merged"
rm -f "$G/merged-50"
printf '%s\tdecisioni rispettate\n' "$reviewed" >"$R/review/42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a review recorded with no time counts as older than any decision" "$code $(printf '%s' "$out" | grep -c 'the decisions changed after the review') $(merged)" "1 1 not-merged"
echo yes >"$G/qa-42"
sleep 1
date -u +%Y-%m-%dT%H:%M:%SZ >"$G/decided-42"
sleep 1
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/review.sh" pass 42 "decisioni rispettate" >/dev/null
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a QA pass older than the decisions: refused the same way" "$code $(printf '%s' "$out" | grep -c 'the decisions changed after the QA: qa.sh request 42') $(merged)" "1 1 not-merged"
printf 'requested\t%s\t42\t%s\t42-feature\n' "$reviewed" "$DEV" >"$R/qa/42"
sh "$SC/qa.sh" pass 42 >/dev/null
ok "the QA pass records its time beside the head" "$(cut -f1,2 "$R/qa/42") $(cut -f3 "$R/qa/42" | grep -c "$stamp")" "pass	$reviewed 1"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1
ok "a new QA pass: merged" "$(merged)" "merged"
rm -f "$G/merged-50"
printf 'pass\t%s\n' "$reviewed" >"$R/qa/42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a QA pass recorded with no time counts as older too" "$code $(printf '%s' "$out" | grep -c 'the decisions changed after the QA') $(merged)" "1 1 not-merged"
printf 'requested\t%s\t42\t%s\t42-feature\n' "$reviewed" "$DEV" >"$R/qa/42"
sh "$SC/qa.sh" pass 42 >/dev/null
touch "$G/comments-broken"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "decisions that cannot be read refuse the merge" "$code $(printf '%s' "$out" | grep -c 'could not read the comments of #42') $(merged)" "1 1 not-merged"
rm -f "$G/comments-broken" "$G/decided-42"

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
printf 'requested\tabc1234567\t42\t%s\t42-feature\n' "$DEV" >"$R/qa/42"
cat >"$T/agents.json" <<EOF
[{"id":"abcd1234","sessionId":"$QA","name":"qa #42 · repo","status":"running","state":"working"},
 {"id":"efgh5678","sessionId":"$NEW","name":"dev #44 · repo · new-thing","status":"running","state":"working"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a QA agent is launched, while the issue is in progress" "$(grep -c -- '--name repo · qa #42 · in progress · Title 42' "$T/claude.log")" "1"
ok "its brief names the issue and the developer's branch, no pull request" "$(grep -c "You are the QA agent of issue #42 of test/repo: you test its developer's branch \`42-feature\`, before its pull request is opened" "$T/claude.log") $(grep -c '{{PR}}' "$T/claude.log")" "1 0"
ok "on the account's default model too" "$(grep -c -- '--bg --model default --name repo · qa #42' "$T/claude.log")" "1"
ok "the request is taken" "$(cut -f1 "$R/qa/42")" "testing"
ok "its role, issue and branch" "$(st "$QA" role) $(st "$QA" issue) $(st "$QA" branch) $(st "$QA" stage)" "qa 42 42-feature in progress"
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
sh "$SC/qa.sh" fail 42 >/dev/null
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

printf 'pass\t%s\n' "$reviewed" >"$R/qa/42"
touch "$G/checks-broken"
rm -f "$G/merged-50"
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "checks that cannot be read refuse the merge" "$code $(printf '%s' "$out" | grep -c 'could not read the checks')" "1 1"
rm -f "$G/checks-broken"
cd "$ROOT" || exit 1

jq -c '.tested_head = "deadbeef00"' "$S/$QA/status" >"$S/$QA/status.t" && mv "$S/$QA/status.t" "$S/$QA/status"
CLAUDE_CODE_SESSION_ID=$QA sh "$SC/qa.sh" pass 42 >/dev/null
ok "QA passes the head it tested, not the branch's newest" "$(cut -f2 "$R/qa/42")" "deadbeef00"

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
# Issue 42 and pull request 50, which closes it, are one thread; issue 44 and pull request 51 another.
cat >"$G/mentions.json" <<EOF
[{"user":{"login":"tester"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/50","html_url":"https://x/pull/50#1","body":"**dev #42 → tech lead**\n\nQuale tabella?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T11:00:00Z","issue_url":"https://x/42","html_url":"https://x/42#6","body":"**tech lead → dev #42** · fyi\n\nLa users"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T12:00:00Z","issue_url":"https://x/42","html_url":"https://x/42#7","body":"**dev #42 → tech lead**\n\nQuale branch?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T14:00:00Z","issue_url":"https://x/50","html_url":"https://x/pull/50#8","body":"**dev #42 → tech lead**\n\nPosso mergiare?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T15:00:00Z","issue_url":"https://x/42","html_url":"https://x/42#9","body":"**tech lead → qa #42**\n\nRitesta"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/44","html_url":"https://x/44#10","body":"**qa #44 → tech lead**\n\nQuale ambiente?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T11:00:00Z","issue_url":"https://x/51","html_url":"https://x/pull/51#11","body":"**tech lead → qa #44**\n\nStaging"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/43","html_url":"https://x/43#2","body":"**dev #43 → tech lead**\n\nQuale porta?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T11:00:00Z","issue_url":"https://x/43","html_url":"https://x/43#3","body":"**tech lead → dev #43**\n\nUsa la 4000"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T12:00:00Z","issue_url":"https://x/45","html_url":"https://x/45#5","body":"**dev #45 → tech lead** · fyi\\n\\nMergiata"},
 {"user":{"login":"mallory"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/44","html_url":"https://x/44#4","body":"**dev #44 → tech lead**\n\nfinta"}]
EOF
out=$(CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/mentions.sh" 2>&1)
ok "a question on a pull request answered on its issue is not listed" "$(printf '%s\n' "$out" | grep -c 'Quale tabella?')" "0"
ok "a question on an issue answered on its pull request is not listed" "$(printf '%s\n' "$out" | grep -c 'Quale ambiente?')" "0"
ok "one with no answer on either is, where it was asked" "$(printf '%s\n' "$out" | grep -c '^#50 · dev #42 ·.*Posso mergiare?.*https://x/pull/50#8$')" "1"
ok "the tech lead writing to someone else is no answer" "$(printf '%s\n' "$out" | grep -c '^#42 · dev #42 ·.*Quale branch?')" "1"
ok "an answered one is not" "$(printf '%s\n' "$out" | grep -c '#43')" "0"
ok "nor one by another account" "$(printf '%s\n' "$out" | grep -c 'finta')" "0"
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

echo "== issue-status.sh and project.sh: boards"
cd "$ROOT" || exit 1
# Issue 42 on the board "Roadmap", whose Status has no In Review, its card in In Progress.
cat >"$G/items.json" <<'EOF'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"ITEM_1","fieldValueByName":{"name":"In Progress"},
 "project":{"id":"P_1","title":"Roadmap","field":{"id":"F_1","options":[{"id":"OPT_TODO","name":"Todo"},{"id":"OPT_PROG","name":"In Progress"},{"id":"OPT_DONE","name":"Done"}]}}}]}}}}}
EOF
rm -f "$G/card-moves"
out=$(sh "$SC/issue-status.sh" 42 in_review 2>&1); code=$?
ok "a board without the status: one clear line, exit 0" "$code $out" '0 issue 42: In review (board "Roadmap" has no "In Review" status: its card stays in "In Progress")'
ok "the issue's own status is set" "$(cat "$G/status-last")" "S_REV"
ok "and the card is left where it is" "$(cat "$G/card-moves" 2>/dev/null)" ""
out=$(sh "$SC/issue-status.sh" 42 in_progress 2>&1)
ok "a board with the status: the card moves" "$(printf '%s' "$out" | tr '\n' '|') $(cat "$G/card-moves")" "issue 42: In progress|issue 42: In Progress on Roadmap OPT_PROG"
sed -e 's/"fieldValueByName":{"name":"In Progress"}/"fieldValueByName":null/' "$G/items.json" >"$G/items.t" && mv "$G/items.t" "$G/items.json"
ok "a card with no status" "$(sh "$SC/issue-status.sh" 42 in_review 2>&1)" 'issue 42: In review (board "Roadmap" has no "In Review" status: its card has no status)'
sed -e 's/"name":"Done"/"name":"in review"/' "$G/items.json" >"$G/items.t" && mv "$G/items.t" "$G/items.json"
rm -f "$G/card-moves"
out=$(sh "$SC/issue-status.sh" 42 in_review 2>&1)
ok "option names compared without case" "$(printf '%s' "$out" | tr '\n' '|') $(cat "$G/card-moves")" "issue 42: In review|issue 42: In Review on Roadmap OPT_DONE"
cat >"$G/items.json" <<'EOF'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[
 {"id":"ITEM_1","fieldValueByName":{"name":"Todo"},"project":{"id":"P_1","title":"Roadmap","field":{"id":"F_1","options":[{"id":"OPT_TODO","name":"Todo"}]}}},
 {"id":"ITEM_2","fieldValueByName":{"name":"Doing"},"project":{"id":"P_2","title":"Ops","field":{"id":"F_2","options":[{"id":"OPT_DOING","name":"Doing"},{"id":"OPT_REV","name":"In Review"}]}}},
 {"id":"ITEM_3","fieldValueByName":null,"project":{"id":"P_3","title":"Notes","field":null}}]}}}}}
EOF
rm -f "$G/card-moves"
out=$(sh "$SC/issue-status.sh" 42 in_review 2>&1)
ok "several boards: one part per board lacking it, then the boards that move" "$(printf '%s' "$out" | tr '\n' '|') $(cat "$G/card-moves")" 'issue 42: In review (board "Roadmap" has no "In Review" status: its card stays in "Todo"; board "Notes" has no "In Review" status: its card has no status)|issue 42: In Review on Ops OPT_REV'
rm -f "$G/items.json"
ok "an issue on no board: its status alone" "$(sh "$SC/issue-status.sh" 42 in_review 2>&1)" "issue 42: In review"
ok "check, with no board: nothing" "$(sh "$SC/project.sh" check 2>&1)" ""
cat >"$G/boards.json" <<'EOF'
{"data":{"repository":{"projectsV2":{"nodes":[
 {"number":3,"title":"Roadmap","field":{"options":[{"name":"Todo"},{"name":"In Progress"},{"name":"Done"}]}},
 {"number":4,"title":"Ops","field":{"options":[{"name":"todo"},{"name":"In progress"},{"name":"in review"},{"name":"DONE"}]}},
 {"number":5,"title":"Ideas","field":{"options":[{"name":"Backlog"}]}},
 {"number":6,"title":"Notes","field":null}]}}}}
EOF
ok "check lists the boards that lack a status, with what they lack" "$(sh "$SC/project.sh" check 2>&1 | tr '\n' '|')" 'board 3 "Roadmap" lacks: In Review|board 5 "Ideas" lacks: Todo, In Progress, In Review, Done|board 6 "Notes" has no Status field|'
ok "asked records the user's answer" "$(sh "$SC/project.sh" asked 3 no 2>&1) $(cat "$R/board-asked.3")" "board 3: the user's answer is recorded (no) no"
ok "check marks the boards already asked with the answer" "$(sh "$SC/project.sh" check 2>&1 | head -2 | tr '\n' '|')" 'board 3 "Roadmap" lacks: In Review (asked: no)|board 5 "Ideas" lacks: Todo, In Progress, In Review, Done|'
sh "$SC/project.sh" asked 5 maybe >/dev/null 2>&1; code=$?
ok "asked takes only yes or no" "$code $([ -f "$R/board-asked.5" ] && echo recorded || echo none)" "2 none"
cat >"$G/board.json" <<'EOF'
{"title":"Roadmap","field":{"id":"F_1","options":[{"id":"OPT_TODO","name":"Todo","color":"GREEN","description":"to do"},
 {"id":"OPT_PROG","name":"In Progress","color":"YELLOW","description":""},{"id":"OPT_DONE","name":"Done","color":"PURPLE","description":"shipped"}]}}
EOF
rm -f "$G/add-status-sent"
out=$(sh "$SC/project.sh" add-status 3 "In Review" 2>&1); code=$?
ok "add-status adds the option" "$code $out" '0 board 3 "Roadmap": "In Review" added to its Status'
ok "to the board's Status field" "$(jq -r .variables.f "$G/add-status-sent" 2>/dev/null)" "F_1"
ok "sending the existing options with their ids, the new one at its place" "$(jq -c .variables.o "$G/add-status-sent" 2>/dev/null)" '[{"id":"OPT_TODO","name":"Todo","color":"GREEN","description":"to do"},{"id":"OPT_PROG","name":"In Progress","color":"YELLOW","description":""},{"name":"In Review","color":"GRAY","description":""},{"id":"OPT_DONE","name":"Done","color":"PURPLE","description":"shipped"}]'
cat >"$G/board.json" <<'EOF'
{"title":"Ideas","field":{"id":"F_5","options":[{"id":"OPT_BACK","name":"Backlog","color":"GRAY","description":""},
 {"id":"OPT_PROG","name":"in progress","color":"YELLOW","description":""},{"id":"OPT_DONE","name":"Done","color":"PURPLE","description":""}]}}
EOF
sh "$SC/project.sh" add-status 5 "Todo" >/dev/null 2>&1
ok "before the first one that comes after it; an option the plugin does not know keeps its place" "$(jq -r '[.variables.o[].name] | join(", ")' "$G/add-status-sent" 2>/dev/null)" "Backlog, Todo, in progress, Done"
sh "$SC/project.sh" add-status 5 "Blocked" >/dev/null 2>&1
ok "a status the plugin does not know goes at the end" "$(jq -r '[.variables.o[].name] | join(", ")' "$G/add-status-sent" 2>/dev/null)" "Backlog, in progress, Done, Blocked"
cat >"$G/board.json" <<'EOF'
{"title":"Roadmap","field":{"id":"F_1","options":[{"id":"OPT_TODO","name":"Todo","color":"GREEN","description":"to do"},
 {"id":"OPT_PROG","name":"In Progress","color":"YELLOW","description":""},{"id":"OPT_DONE","name":"Done","color":"PURPLE","description":"shipped"}]}}
EOF
rm -f "$G/add-status-sent"
out=$(sh "$SC/project.sh" add-status 3 "in progress" 2>&1); code=$?
ok "a status the board has already: said, nothing sent" "$code $out $([ -f "$G/add-status-sent" ] && echo sent || echo none)" '0 board 3 "Roadmap" already has "in progress" none'
rm -f "$G/boards.json" "$G/board.json" "$R/board-asked.3"

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
# within <seconds> <command...>: its output once it ends, or TIMEOUT, with it stopped, when it still runs then.
within() {
	secs=$1
	shift
	"$@" >"$T/within.out" 2>&1 &
	wpid=$!
	n=0
	while kill -0 "$wpid" 2>/dev/null && [ "$n" -lt $((secs * 10)) ]; do sleep 0.1; n=$((n + 1)); done
	if kill -0 "$wpid" 2>/dev/null; then
		pkill -P "$wpid" 2>/dev/null
		kill "$wpid" 2>/dev/null
		wait "$wpid" 2>/dev/null
		echo TIMEOUT
		return
	fi
	wait "$wpid" 2>/dev/null
	cat "$T/within.out"
}
echo '[{"id":1,"name":"ci","path":".github/workflows/ci.yml","state":"active"}]' >"$G/workflows"
printf 'name: ci\non:\n  push:\n    branches: [main]\n  pull_request:\n' >"$G/workflow-1.yml"
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"},{"status":"completed","conclusion":"success","workflowName":"deploy","url":"u2"}]' >"$G/runs"
ok "green: the change is deployed" "$(sh "$SC/main-ci.sh" 50 | cut -c1-21)" "GREEN main deadbee: t"
ok "and --wait ends on it" "$(within 10 sh "$SC/main-ci.sh" 50 --wait | cut -c1-21)" "GREEN main deadbee: t"
echo '[{"status":"completed","conclusion":"failure","workflowName":"deploy","url":"https://x/run/9"},{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
out=$(sh "$SC/main-ci.sh" 50)
ok "red: the failed runs, and whose it is to say" "$(printf '%s\n' "$out" | grep -c -e '^RED main deadbee' -e 'deploy: failure https://x/run/9' -e 'tell the tech lead')" "4"
ok "and no bug issue opened" "$(ls "$G/comments" | grep -c 'CI')" "0"
echo '[{"status":"in_progress","conclusion":"","workflowName":"deploy","url":"u2"}]' >"$G/runs"
ok "still running" "$(sh "$SC/main-ci.sh" 50 | cut -c1-15)" "PENDING main de"
echo '[]' >"$G/runs"
ok "a workflow on push to the default branch and no run yet: it waits as today" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
rm -f "$G/workflows"
ok "no workflow: NO CI at once, without waiting" "$(within 10 sh "$SC/main-ci.sh" 50 --wait)" "NO CI main deadbee: no workflow runs on main"
ok "and without --wait too" "$(sh "$SC/main-ci.sh" 50)" "NO CI main deadbee: no workflow runs on main"
echo '[{"id":2,"name":"pr","path":".github/workflows/pr.yml","state":"active"},{"id":3,"name":"Dependabot Updates","path":"dynamic/dependabot/dependabot-updates","state":"active"},{"id":1,"name":"ci","path":".github/workflows/ci.yml","state":"disabled_manually"}]' >"$G/workflows"
printf 'name: pr\non: [pull_request, workflow_dispatch]\n' >"$G/workflow-2.yml"
ok "workflows on other events, a dynamic one and a disabled one on push: NO CI" "$(within 10 sh "$SC/main-ci.sh" 50 --wait)" "NO CI main deadbee: no workflow runs on main"
echo '[{"id":2,"name":"pr","path":".github/workflows/pr.yml","state":"active"},{"id":4,"name":"gone","path":".github/workflows/gone.yml","state":"active"}]' >"$G/workflows"
ok "a workflow file that cannot be read: it waits as today" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
touch "$G/workflows-broken"
ok "a workflow list that cannot be read: it waits as today" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
rm -f "$G/workflows-broken"

echo "== push-trigger.py: a workflow's on: has a push trigger"
pt() { printf "$1" | python3 -I "$SC/push-trigger.py"; }
ok "a name" "$(pt 'on: push\n')" "push"
ok "another name" "$(pt 'on: workflow_dispatch # push by hand\n')" "no"
ok "a list on one line" "$(pt 'name: x\n"on": [pull_request, push]\n')" "push"
ok "a list over several lines" "$(pt "on: [pull_request,\n  push]\njobs:\n")" "push"
ok "a list with no push" "$(pt "'on': [pull_request, schedule]\n")" "no"
ok "one item per line" "$(pt 'on:\n- workflow_dispatch\n- push\njobs:\n')" "push"
ok "a list on the line under on:" "$(pt 'on:\n  [pull_request, push]\njobs:\n')" "push"
ok "a map on the line under on:" "$(pt 'on:\n  {push: {branches: [main]}}\njobs:\n')" "push"
ok "a list with no push on the line under on:" "$(pt 'on:\n  [pull_request]\njobs:\n')" "no"
ok "a map whose key's list sits at the key's indentation is no list of events" "$(pt "name: stale\non:\n  schedule:\n  - cron: '0 0 * * *'\n  workflow_dispatch:\njobs:\n")" "no"
ok "and with push among its keys" "$(pt "on:\n  schedule:\n  - cron: '0 0 * * *'\n  push:\n    branches:\n    - main\n")" "push"
ok "an item it cannot read as a name: it cannot tell, so push" "$(pt 'on:\n  - [pull_request]\njobs:\n')" "push"
ok "a map: push with filters counts, they are not interpreted" "$(pt 'on:\n  push:\n    tags: [v*]\n    branches-ignore: [main]\njobs:\n  push:\n')" "push"
ok "a map with no push: neither a deeper key nor a later block counts" "$(pt 'on:\n  # push: off\n  pull_request:\n    branches: [push]\n  schedule:\n    - cron: x\njobs:\n  push:\n')" "no"
ok "no on: it cannot tell, so push" "$(pt 'name: x\njobs:\n')" "push"
ok "an alias: it cannot tell, so push" "$(pt 'on: *triggers\n')" "push"

echo "== report.sh: the same title again, right after, comments on the open report"
cd "$T" || exit 1
echo "first" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "A wake for nothing" >/dev/null
echo "second" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "A wake for nothing" >/dev/null
rep=$(ls "$G/reports" 2>/dev/null | head -1)
ok "one issue" "$(ls "$G/reports" 2>/dev/null | wc -l)" "1"
ok "and one comment on it, with the second report" "$(ls "$G/comments" | grep -c "^$rep\.") $(cat "$G/comments/$rep".* 2>/dev/null | head -1)" "1 second"
echo "third" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "a WAKE for nothing" >/dev/null
ok "the title compared without case" "$(ls "$G/reports" | wc -l) $(ls "$G/comments" | grep -c "^$rep\.")" "1 2"
echo "Board shows a wrong color" >"$G/report-pr"
echo "fourth" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "Board shows a wrong color" >/dev/null
ok "a pull request with the title is no report: a new issue" "$(ls "$G/reports" | wc -l) $(ls "$G/comments" | grep -c '^900\.')" "2 0"

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
ok "and that its subagents may have been stopped, to start again when their hand-back does not come" "$(grep -- "--bg --resume $TL1 " "$T/claude.log" | grep -cF 'do not start them again. Subagents you started with the Agent tool before the restart may have been stopped: if a hand-back you wait for does not come, start that subagent again.')" "1"
ok "with no flags, which would start a copy" "$(grep -- '--resume' "$T/claude.log" | grep -c -- '--name')" "0"
new_pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
ok "a running dispatcher restarts" "$([ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && echo yes || echo no) $(grep -c '^dispatcher test_repo: the dispatcher of test/repo runs' "$T/update.out")" "yes 1"
ok "before any session" "$(grep -e '^dispatcher ' -e ': backgrounded' "$T/update.out" | head -1 | cut -d: -f1)" "dispatcher test_repo"
ok "and the update says it is done" "$(tail -1 "$T/update.out" | cut -c21-)" "update done"
sh "$SC/dispatcher.sh" stop >/dev/null

echo "== update.sh: started by an older version, the newest one restarts the sessions"
# An older version installed beside 9.9.9, whose restart prompt lacks a sentence of the newer one's.
CACHE="$T/config/plugins/cache/team/team"
OLD="$CACHE/0.0.1"
sentence='Commands you started in the background before the restart'
mkdir -p "$OLD/.claude-plugin"
cp -R "$W/scripts" "$W/skills" "$W/briefs" "$OLD/"
echo '{"name": "team", "version": "0.0.1"}' >"$OLD/.claude-plugin/plugin.json"
sed "s/ $sentence.*do not start them again\.//" "$W/scripts/update.sh" >"$OLD/scripts/update.sh"
ok "the older version's prompt lacks the sentence" "$(grep -c "$sentence" "$OLD/scripts/update.sh")" "0"
# The older version alone installed: it is the newest, it goes on by itself.
mv "$CACHE/9.9.9" "$T/9.9.9"
date +%s >"$S/$TL1/alive"
: >"$T/claude.log"
UPDATE_QUIET=0 UPDATE_GONE=1 sh "$OLD/scripts/update.sh" run >"$T/update.out" 2>&1
ok "the newest version installed hands over to nobody" "$(grep -c '^continuing with team' "$T/update.out") $(grep -c -- "--bg --resume $TL1 The team plugin was updated to 0.0.1 " "$T/claude.log")" "0 1"
ok "and restarts with its own prompt" "$(grep -- "--bg --resume $TL1 " "$T/claude.log" | grep -c "$sentence")" "0"
# 9.9.9 installed too: the older version updates the plugin, then 9.9.9 goes on.
mv "$T/9.9.9" "$CACHE/9.9.9"
date +%s >"$S/$TL1/alive"
date +%s >"$S/$DEV2/alive"
: >"$T/claude.log"
CLAUDE_CODE_SESSION_ID=$TL1 UPDATE_QUIET=0 UPDATE_GONE=1 sh "$OLD/scripts/update.sh" run >"$T/update.out" 2>&1
ok "the log notes the hand-over" "$(grep -c '^continuing with team 9.9.9$' "$T/update.out")" "1"
ok "the restarted sessions get the newer prompt" "$(grep -- "--bg --resume $TL1 The team plugin was updated to 9.9.9 " "$T/claude.log" | grep -c "$sentence") $(grep -- "--bg --resume $DEV2 The team plugin was updated to 9.9.9 " "$T/claude.log" | grep -c "$sentence")" "1 1"
ok "the plugin is updated once on each account" "$(grep -c 'plugin update team@team' "$T/claude.log")" "2"
ok "the one that started the update restarts last" "$(grep -- '--bg --resume' "$T/claude.log" | tail -1 | cut -d' ' -f3)" "$TL1"
ok "and the log says once that the update starts, and that it is done" "$(grep -c 'update starts$' "$T/update.out") $(tail -1 "$T/update.out" | cut -c21-)" "1 update done"

echo
[ ! -f "$G/unhandled" ] || { echo "unhandled gh calls:"; sort -u "$G/unhandled"; }
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
