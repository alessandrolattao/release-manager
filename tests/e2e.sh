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
export XDG_STATE_HOME="$T/state" XDG_DATA_HOME="$T/data" TMPDIR="$T/tmp" CLAUDE_PLUGIN_ROOT="$W" PATH="$T/bin:$PATH" G="$T/gh" CLAUDE_CONFIG_DIR="$T/config" TT="$T" CLAIM_WAIT=0 REST_WAITS="0 0"
SC="$W/scripts"
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1: wanted [$3] got [$2]"; fi; }
st() { jq -r ".$2 // \"\"" "$S/$1/status" 2>/dev/null; }

# A fake GitHub. The scripts write through its REST API (gh api with fields, or -X DELETE): each write is
# logged in rest.log, and fails while fail-next has lines, its first line being the error gh prints for
# GitHub's answer.
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = api ] && [ "$2" != graphql ] && case " $* " in *" -f "* | *" -F "* | *" -X DELETE "*) true ;; *) false ;; esac; then
	echo "$*" >>"$G/rest.log"
	if [ -s "$G/fail-next" ]; then
		head -1 "$G/fail-next" >&2
		tail -n +2 "$G/fail-next" >"$G/fail-next.t"
		mv "$G/fail-next.t" "$G/fail-next"
		exit 1
	fi
fi
# F=<name> field "$@": the value of the -f or -F field <name>; for -F body=@<file>, "@<file>".
field() { for a in "$@"; do case "$a" in "$F="*) printf '%s\n' "${a#"$F="}" ;; esac; done; }
# answer <json>: GitHub's answer, through the caller's --jq filter when it gives one.
answer() {
	q=$(prev=""; for a in "$@"; do [ "$prev" != --jq ] || printf '%s' "$a"; prev=$a; done)
	if [ -n "$q" ]; then printf '%s' "$J" | jq -r "$q"; else printf '%s\n' "$J"; fi
}
next_id() { n=$(cat "$G/next-id" 2>/dev/null || echo 1); echo $((n + 1)) >"$G/next-id"; echo "$n"; }
case "$*" in
"repo view --json nameWithOwner --jq .nameWithOwner") echo test/repo ;;
# A repository by its name, as GitHub spells it whatever the case asked: test/repo and someone/else; any
# other, GitHub does not know.
"repo view "*" --json nameWithOwner --jq .nameWithOwner")
	r=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
	case "$r" in
	test/repo | someone/else) echo "$r" ;;
	*) echo "GraphQL: Could not resolve to a Repository with the name '$3'. (repository)" >&2; exit 1 ;;
	esac ;;
"repo view --json defaultBranchRef --jq .defaultBranchRef.name") echo main ;;
# The user's permission on the repository: ADMIN, or the one in permission.
"repo view --json viewerPermission --jq .viewerPermission") cat "$G/permission" 2>/dev/null || echo ADMIN ;;
"repo view --json url --jq .url") echo https://github.com/test/repo ;;
"api user --jq .login") echo tester ;;
"issue view "*" --json title --jq .title") echo "Title $3" ;;
"issue view "*" --json id --jq .id") echo "I_$3" ;;
"api repos/"*"/issues/"*"/comments "*)
	n=$(echo "$2" | sed -n 's#.*/issues/\([0-9]*\)/comments$#\1#p') id=$(next_id)
	cat "$(F=body field "$@" | sed 's/^@//')" >"$G/comments/$n.$id"
	# The repository a comment went to, beside it.
	echo "$n.$id $(echo "$2" | cut -d/ -f2,3)" >>"$G/comment-repos"
	J=$(jq -n --arg u "https://github.com/test/repo/issues/$n#issuecomment-$id" '{html_url: $u}') answer "$@" ;;
"api repos/"*"/issues/"*"/labels "*) echo "$(echo "$2" | sed -n 's#.*/issues/\([0-9]*\)/labels$#\1#p') $(F='labels[]' field "$@")" >>"$G/labels-added" ;;
"api repos/"*"/labels "*) echo "$(F=name field "$@") $(F=color field "$@")" >>"$G/labels-created" ;;
# Removing a label the issue does not carry: GitHub answers 404.
"api -X DELETE repos/"*"/issues/"*"/labels/"*)
	l="$(echo "$4" | sed -n 's#.*/issues/\([0-9]*\)/labels/.*#\1#p') $(printf '%s' "${4##*/}" | sed 's/%20/ /g')"
	grep -qxF "$l" "$G/labels-added" 2>/dev/null || { echo "gh: Label does not exist (HTTP 404)" >&2; exit 1; }
	grep -vxF "$l" "$G/labels-added" >"$G/labels-added.t"; mv "$G/labels-added.t" "$G/labels-added"; echo '[]' ;;
# A new issue: its title and body in issues/<n>, its labels and assignees in issues/<n>.meta.
"api repos/"*"/issues "*)
	n=$(next_id) r=$(echo "$2" | cut -d/ -f2,3); mkdir -p "$G/issues"
	F=title field "$@" >"$G/issues/$n.title"; cat "$(F=body field "$@" | sed 's/^@//')" >"$G/issues/$n.body"
	echo "repo=$r labels=$(F='labels[]' field "$@") assignees=$(F='assignees[]' field "$@")" >"$G/issues/$n.meta"
	J=$(jq -n --arg u "https://github.com/$r/issues/$n" '{html_url: $u}') answer "$@" ;;
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
# The merged pull request of a branch, in merged-pr-<branch>; none otherwise.
"pr list --head "*" --state merged --limit 1 --json number --jq .[0].number // empty") cat "$G/merged-pr-$4" 2>/dev/null || true ;;
"pr merge 50 --"*" --match-head-commit "*)
	# GitHub failing to answer, as during an incident: whether the merge landed, the default branch says.
	[ ! -f "$G/merge-fails" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
	# GitHub merges only the head it is told, and only when it is the pull request's.
	[ "$6" = "$(cat "$G/head-50" 2>/dev/null || echo abc1234567)" ] || { echo "head moved" >&2; exit 1; }
	case "$4" in --merge) echo merged >"$G/merged-50" ;; --rebase) echo rebased >"$G/merged-50" ;; esac ;;
# A dependency bot's pull request, as the REST API gives it: the author is its login, dependabot[bot].
"api repos/test/repo/pulls/60") cat "$G/pr-60.json" ;;
"pr checks 60 --json state,name") cat "$G/checks-60" ;;
"pr merge 60 --"*" --match-head-commit "*)
	[ "$6" = "$(jq -r .head.sha "$G/pr-60.json")" ] || { echo "head moved" >&2; exit 1; }
	echo "${4#--} $6" >"$G/merged-60" ;;
"api repos/test/repo --jq "*) cat "$G/merge-methods" 2>/dev/null || echo "merge rebase squash" ;;
"label list --limit 200 --json name --jq .[].name") echo question ;;
# Whether an issue carries the label review: review-<n> says, no otherwise; with labels-broken, the labels
# cannot be read.
"issue view "*" --json labels --jq "*'"review"'*)
	[ ! -f "$G/labels-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
	cat "$G/review-$3" 2>/dev/null || echo no ;;
"issue view 42 --json labels --jq "*) cat "$G/qa-42" 2>/dev/null || echo no ;;
"issue view 42 --json comments --jq "*) [ ! -f "$G/comments-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; cat "$G/decided-42" 2>/dev/null || true ;;
"issue view "*" --json state,labels --jq "*) cat "$G/issue-open" 2>/dev/null || echo false ;;
"issue view "*" --json state --jq .state")
	[ ! -f "$G/state-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
	if [ -f "$G/closed-$3" ]; then echo CLOSED; else echo OPEN; fi ;;
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
# A merge GitHub has not marked yet (unmarked-50) has no mergeCommit; its runs are those of the merge commit in
# the default branch (landed-50).
"pr view 50 --json mergeCommit --jq .mergeCommit.oid // empty") [ -f "$G/unmarked-50" ] || echo deadbeefcafe ;;
# When the merge landed: the time in merged-at-50, else now; none while GitHub has not marked it.
"pr view 50 --json mergedAt --jq "*)
	if [ -f "$G/unmarked-50" ]; then J='{"mergedAt":null}'; else J=$(jq -n --arg t "$(cat "$G/merged-at-50" 2>/dev/null || jq -nr 'now | floor | todate')" '{mergedAt: $t}'); fi
	answer "$@" ;;
"pr view 50 --json headRefOid --jq .headRefOid") cat "$G/head-50" 2>/dev/null || echo abc1234567 ;;
# The branch the pull request merges into: main, or the one in base-50; base-broken, an answer that cannot be read.
"pr view 50 --json baseRefName --jq .baseRefName // empty")
	[ ! -f "$G/base-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
	cat "$G/base-50" 2>/dev/null || echo main ;;
# With superseded-50, every run of the merge commit was cancelled: a newer commit of the branch holds the change.
# With cancelled-<sha>, every run of that commit was. With runs-broken, the runs cannot be read.
"run list --commit "*)
	[ ! -f "$G/runs-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
	if { [ "$4" = deadbeefcafe ] && [ -f "$G/superseded-50" ]; } || [ -f "$G/cancelled-$4" ]; then
		echo '[{"status":"completed","conclusion":"cancelled","workflowName":"ci","url":"u0"}]'
	elif [ "$4" = deadbeefcafe ] || [ "$4" = "$(cat "$G/landed-50" 2>/dev/null)" ]; then cat "$G/runs" 2>/dev/null || echo '[]'; else echo '[]'; fi ;;
# The board's CI of the default branch: the commit asked about, in ci-commit.
"run list --branch "*) printf '%s\n' "$6" >"$G/ci-commit"; echo '[]' ;;
"run list "*) echo '[]' ;;
"workflow list "*) [ ! -f "$G/workflows-broken" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }; cat "$G/workflows" 2>/dev/null || true ;;
# A workflow file as the branch it is read on has it: workflow-<id>.yml on main, workflow-<id>-<branch>.yml on another.
"workflow view "*" --yaml --ref "*)
	f="$G/workflow-$3.yml"
	[ "$6" = main ] || f="$G/workflow-$3-$6.yml"
	cat "$f" 2>/dev/null || { echo "HTTP 404: Not Found" >&2; exit 1; } ;;
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
	# A "blocked by" relationship added or taken away: the mutation and the two issues, in blocks.
	*BlockedBy*) printf '%s\n' "$*" | grep -o -e '[a-zA-Z]*BlockedBy(' -e '[ib]=I_[0-9]*' | tr -d '(' | paste -sd' ' >>"$G/blocks"; echo '{}' ;;
	*) cat "$G/queue" 2>/dev/null ;;
	esac ;;
"issue develop 44 --list") echo "44-new-thing	https://x" ;;
"issue develop 66 --list") echo "66-older	https://x" ;;
"issue develop 80 --list") echo "80-fork-thing	https://x" ;;
# The plugin's own repository, for report.sh. The REST listing has an issue as soon as it is opened, and a
# pull request among the issues it lists; the search index behind `gh issue list --label` has not seen it yet.
"api repos/"*"/issues?labels=flow-report&state=open&per_page=100")
	{
		for f in "$G/issues/"*.meta; do
			grep -q 'labels=flow-report' "$f" 2>/dev/null || continue
			n=$(basename "$f" .meta)
			jq -n --rawfile t "$G/issues/$n.title" --argjson n "$n" '{number: $n, title: ($t | rtrimstr("\n"))}'
		done
		[ ! -f "$G/report-pr" ] || jq -n --rawfile t "$G/report-pr" '{number: 900, title: ($t | rtrimstr("\n")), pull_request: {url: "https://x/pulls/900"}}'
	} | jq -s '.' ;;
"issue list -R "*" --state open --label flow-report "*) echo '[]' ;;
"label list -R "*" --limit 200 --json name --jq .[].name") cat "$G/plugin-labels" 2>/dev/null || echo flow-report ;;
*) echo "gh stub: unhandled: $*" >>"$G/unhandled"; exit 1 ;;
esac
EOF
# A fake claude: the agent list comes from a file, stop and rm are recorded. With --cwd <folder> it lists only the
# sessions started under that folder as the real CLI matches them: one in <dir>/.claude/worktrees/<x> by <dir>
# (`--cwd` on its own folder does not list it), any other by its own cwd; one with no cwd started in the main
# checkout. A plugin update installs, on the account it runs on, each version `publish` lists for that account
# ("<account folder> <version>" per line, the version's files in releases/<version>) and not installed there yet;
# each session `reloads` lists for a version it installs ("<session folder> <version>" per line) reloads it at
# once, as a session between turns does (hooks/sessions.tsx): its `version` reaches it.
cat >"$T/bin/claude" <<'EOF'
#!/bin/sh
case "$1" in
agents)
	under=$(prev=""; for a in "$@"; do [ "$prev" != --cwd ] || printf '%s' "$a"; prev=$a; done)
	{ cat "$TT/agents.json" 2>/dev/null || echo '[]'; } | jq --arg u "$under" --arg root "$TT/repo" \
		'[.[] | ((.cwd // $root) | sub("/\\.claude/worktrees/.*$"; "")) as $c | select($u == "" or $c == $u or ($c | startswith($u + "/")))]' ;;
--bg) echo "$*" >>"$TT/claude.log"; echo "backgrounded · abcd1234 · started" ;;
plugin)
	echo "$*" >>"$TT/claude.log"
	[ "$2" = update ] || exit 0
	home=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
	got=""
	while read -r account version; do
		[ "$account" = "$home" ] && [ ! -e "$home/plugins/cache/team/team/$version" ] || continue
		mkdir -p "$home/plugins/cache/team/team"
		ln -s "$TT/releases/$version" "$home/plugins/cache/team/team/$version"
		got=$version
		while read -r folder at; do [ "$at" != "$version" ] || echo "$at" >"$folder/version"; done <"$TT/reloads"
	done <"$TT/publish"
	if [ -n "$got" ]; then echo "Plugin \"team\" updated to $got"; else echo "Plugin \"team\" is already at the latest version"; fi ;;
*) echo "$*" >>"$TT/claude.log" ;;
esac
EOF
: >"$T/publish"
: >"$T/reloads"
# release <version>: the plugin's files as that version publishes them, in releases/<version>.
release() {
	mkdir -p "$T/releases/$1/.claude-plugin"
	cp -R "$W/scripts" "$W/skills" "$W/briefs" "$W/hooks" "$T/releases/$1/"
	printf '{"name": "team", "version": "%s"}\n' "$1" >"$T/releases/$1/.claude-plugin/plugin.json"
}
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

# A real repository with an origin, a branch for issue 42 and its worktree. Its URL ends in test/repo, the
# repository gh resolves. 42 and 43 have theirs where older developers had them, under the main checkout's
# .claude/worktrees/; new ones go beside it, in $WT.
mkdir -p "$T/test"
git init -q --bare -b main "$T/test/repo.git"
git clone -q "$T/test/repo.git" "$T/repo" 2>/dev/null
ROOT="$T/repo"
WT="$ROOT.worktrees"
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
ok "where the user can write, only its name" "$(sh "$SC/role.sh" "$TL1" tech-lead)" "repo · tech lead"
echo READ >"$G/permission"
out=$(sh "$SC/role.sh" "$TL1" tech-lead); code=$?
ok "where the user can only read, a line says so before the name, for the tech lead to tell the user" "$code | $out" "0 | the user can only read test/repo here, so the plugin's flow cannot run. Tell the user in one line.
repo · tech lead"
ok "and the tech lead is recorded all the same" "$(st "$TL1" role) $(st "$TL1" repo)" "tech-lead test/repo"
rm -f "$G/permission"
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
tab=$(printf '\t')
: >"$G/rest.log"
out=$(echo "Quale tabella legge il nuovo endpoint?" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/comment.sh" 42 "tech lead")
last=$(ls -t "$G/comments" | head -1)
ok "header names writer and reader" "$(head -1 "$G/comments/$last")" "**dev #42 → tech lead**"
ok "posted through the REST API, the body from a file" "$(sed 's/body=@.*/body=@/' "$G/rest.log")" "api repos/test/repo/issues/42/comments --jq .html_url -F body=@"
ok "and its link printed" "$out" "https://github.com/test/repo/issues/42#issuecomment-${last#42.}"
ok "the writer waits on another agent" "$(st "$DEV" state)" "others"
ok "and records whom it waits on" "$(st "$DEV" waits_on)" "tech lead"
echo "Serve il login AWS" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/comment.sh" 42 you >/dev/null 2>&1; code=$?
ok "a developer never writes to the user" "$code" "2"
echo "Mi serve il login AWS" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 42 you >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "a tech lead to the user: a real mention" "$(head -1 "$G/comments/$last")" "**tech lead → @tester**"
ok "to the user: label question, through the REST API" "$(cat "$G/labels-added")" "42 question"
ok "to the user: yellow" "$(st "$TL1" state)" "you"
ok "to the user: waits on the user" "$(st "$TL1" waits_on)" "the user"
# The user's answer reached it: the hooks module ended the wait.
jq -c '.state = "working" | del(.asked_on, .waits_on)' "$S/$TL1/status" >"$S/$TL1/status.t" && mv "$S/$TL1/status.t" "$S/$TL1/status"
echo "PR 50 riguarda la 42" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 50 dev --fyi >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "on a pull request, dev means the issue's developer; news says fyi" "$(head -1 "$G/comments/$last")" "**tech lead → dev #42** · fyi"
ok "--fyi leaves the writer's state" "$(st "$TL1" state)" "working"
ok "--fyi records nobody to wait on" "$(st "$TL1" waits_on)" ""
# What each session wrote on GitHub, and to whom: a wake for a comment it answered since is dropped.
ok "the writer records the thread and whom it wrote to" "$(cut -f2,3 "$S/$DEV/commented")" "42${tab}tech lead"
ok "a comment on a pull request is recorded on the issue it closes" "$(tail -1 "$S/$TL1/commented" | cut -f2,3)" "42${tab}dev #42"
ok "with when it was written" "$(tail -1 "$S/$TL1/commented" | cut -f1 | grep -c -E '^[0-9]{10}$')" "1"
# The options anywhere among the arguments; an unknown recipient posts nothing.
echo "Fatto" | sh "$SC/comment.sh" 42 --fyi "tech lead" >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "--fyi before the recipient is the option, not the recipient" "$(head -1 "$G/comments/$last")" "**team → tech lead** · fyi"
echo "Fatto" | sh "$SC/comment.sh" --fyi 42 "review #42" >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "and before the issue too; a reviewer by its address" "$(head -1 "$G/comments/$last")" "**team → review #42** · fyi"
before=$(ls "$G/comments" | wc -l)
: >"$G/rest.log"
for to in "--fyi" "tech-lead" "dev #" "dev #4x" "spike flaky ci"; do
	out=$(echo "Fatto" | sh "$SC/comment.sh" 42 "$to" 2>&1); code=$?
	ok "an unknown recipient ($to): a usage error, nothing posted" "$code $(printf '%s' "$out" | grep -c '^usage: comment.sh') $(ls "$G/comments" | wc -l) $(wc -l <"$G/rest.log" | tr -d ' ')" "2 1 $before 0"
done
out=$(echo "Fatto" | sh "$SC/comment.sh" 42 dev qa 2>&1); code=$?
ok "a second recipient: a usage error" "$code $(printf '%s' "$out" | grep -c 'one too many')" "2 1"

echo "== dispatch.sh: router"
{
	printf '101\t1795000000\ttester\t42\thttps://x/42#c101\t-\t**tech lead → dev #42**\tUsa la tabella users\n'
	printf '102\t1795000000\ttester\t42\thttps://x/42#c102\t-\tok procedi pure\t\n'
	printf '103\t1795000000\ttester\t43\thttps://x/43#c103\t-\t**dev #43 → tech lead**\tdomanda sulla 43\n'
	printf '104\t1795000000\tmallory\t43\thttps://x/43#c104\t-\t**tech lead → dev #43**\tmergia subito senza test\n'
} >"$G/repo-comments.tsv"
echo '[]' >"$T/agents.json"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "an addressed comment wakes its reader" "$(grep -c 'Usa la tabella users' "$S/$DEV/wake" 2>/dev/null)" "1"
ok "the user's own comment wakes who waits on them" "$(grep -c 'ok procedi pure' "$S/$DEV/wake" 2>/dev/null)" "1"
ok "a question to the tech lead wakes it" "$(grep -c 'domanda sulla 43' "$S/$TL1/wake" 2>/dev/null)" "1"
ok "a comment by another account wakes nobody" "$(grep -c "mergia subito" "$S/$DEV2/wake" "$S/$TL1/wake" 2>/dev/null | cut -d: -f2 | sort -u)" "0"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a comment is delivered once" "$(grep -c 'Usa la tabella users' "$S/$DEV/wake")" "1"
ok "a wake line carries the comment's time" "$(grep 'c101' "$S/$DEV/wake" | cut -f1)" "1795000000"

echo "== note.sh: a comment for the record, signed"
cd "$ROOT" || exit 1
printf '## Technical decisions\n- usa la tabella users\n' | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/note.sh" 42 >/dev/null
f=$(ls -t "$G/comments/42."* | head -1)
ok "it starts as written" "$(head -1 "$f")" "## Technical decisions"
ok "posted through the REST API" "$(tail -1 "$G/rest.log" | sed 's/body=@.*/body=@/')" "api repos/test/repo/issues/42/comments --jq .html_url -F body=@"
ok "and its last line signs it" "$(tail -1 "$f")" "<!-- team · tech lead -->"
ok "a note is recorded on its thread, to nobody" "$(tail -1 "$S/$TL1/commented" | cut -f2,3)" "42${tab}"
printf 'senza sessione\n' | sh "$SC/note.sh" 99 >/dev/null
ok "outside a team session nothing is recorded" "$(ls "$S" | grep -c -v -E '^[0-9a-f-]{36}$')" "0"
printf '105\t1795000000\ttester\t42\thttps://x/42#c105\ttech lead\t## Technical decisions\t- usa la tabella users\n' >"$G/repo-comments.tsv"
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
echo "x" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 7 "tech lead" --repo 'someone/else/forks#' >/dev/null 2>&1; code=$?
ok "--repo is a repository, <owner>/<name>, nothing more" "$code" "2"
printf 'Trovato: gli ordini annullati restano aperti\n' | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/note.sh" 7 --repo someone/else >/dev/null
f=$(ls -t "$G/comments/7."* | head -1)
ok "note.sh --repo writes on that repository" "$(repo_of_last "$f")" "someone/else"
ok "as written, signed with this repository" "$(head -1 "$f") | $(tail -1 "$f")" "Trovato: gli ordini annullati restano aperti | <!-- team · tech lead of test/repo -->"
echo "x" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/note.sh" 7 --repo someone/else >/dev/null 2>&1; code=$?
ok "note.sh --repo only from a tech lead" "$code" "2"
echo "x" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/note.sh" 7 --repo 'someone/else/actions/runs/1/rerun#' >/dev/null 2>&1; code=$?
ok "note.sh --repo only <owner>/<name>" "$code" "2"
url=$(printf 'Gli ordini si leggono da un endpoint\n' | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/open-issue.sh" "Orders endpoint" @me --repo someone/else)
n=${url##*/}
ok "open-issue.sh --repo opens it on that repository" "$url | $(cat "$G/issues/$n.title") | $(cat "$G/issues/$n.meta")" "https://github.com/someone/else/issues/$n | Orders endpoint | repo=someone/else labels= assignees=tester"
ok "its body as written, signed with this repository" "$(head -1 "$G/issues/$n.body") | $(tail -1 "$G/issues/$n.body")" "Gli ordini si leggono da un endpoint | <!-- team · tech lead of test/repo -->"
echo "x" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/open-issue.sh" "x" @me --repo someone/else >/dev/null 2>&1; code=$?
ok "open-issue.sh --repo only from a tech lead" "$code" "2"
echo "x" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/open-issue.sh" "x" @me --repo 'someone/else/milestones#' >/dev/null 2>&1; code=$?
ok "open-issue.sh --repo only <owner>/<name>" "$code" "2"

echo "== comment.sh to another repository's tech lead, on this repository's issue"
cd "$ROOT" || exit 1
box="$T/data/team/inbox/someone_else"
out=$(echo "Sì, l'endpoint degli ordini è nel piano" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 42 "tech lead of someone/else"); code=$?
reply=$(ls -t "$G/comments/42."* | head -1)
link="https://github.com/test/repo/issues/42#issuecomment-${reply##*.}"
ok "it writes on this repository's issue" "$code $(repo_of_last "$reply")" "0 test/repo"
ok "its header names this tech lead and the other repository's" "$(head -1 "$reply")" "**tech lead → tech lead of someone/else**"
ok "signed as on this repository: no hidden signature" "$(grep -c '<!-- team' "$reply")" "0"
ok "it prints the comment's link first" "$(printf '%s\n' "$out" | head -1)" "$link"
ok "it leaves one message in that tech lead's inbox" "$(ls "$box/new" 2>/dev/null | wc -l | tr -d ' ')" "1"
m=$(ls "$box/new/"* 2>/dev/null | head -1)
ok "an info from this repository's tech lead, one line with the link" "$(sed -n 's/^Kind: //p' "$m") | $(sed -n 's/^From: //p' "$m") | $(sed -n '5,$p' "$m")" "info | tech lead of test/repo | Wrote to you on test/repo#42: $link"
ok "and says when no tech lead there reads it yet" "$(printf '%s\n' "$out" | grep -c '^NOT READ YET')" "1"
ok "the writer waits on that tech lead" "$(st "$TL1" state) | $(st "$TL1" waits_on)" "others | tech lead of someone/else"
ok "the thread records whom it wrote to" "$(tail -1 "$S/$TL1/commented" | cut -f2,3)" "42${tab}tech lead of someone/else"
# Its answer reached it: the hooks module ended the wait.
jq -c '.state = "working" | del(.waits_on)' "$S/$TL1/status" >"$S/$TL1/status.t" && mv "$S/$TL1/status.t" "$S/$TL1/status"
before=$(jq -c '{state, detail, waits_on}' "$S/$TL1/status")
echo "Fatto dal nostro lato" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 50 "tech lead of someone/else" --fyi >/dev/null
f=$(ls -t "$G/comments/50."* | head -1)
ok "--fyi, on a pull request: news in its header" "$(head -1 "$f")" "**tech lead → tech lead of someone/else** · fyi"
ok "the writer's state does not change" "$(jq -c '{state, detail, waits_on}' "$S/$TL1/status")" "$before"
ok "recorded on the issue the pull request closes" "$(tail -1 "$S/$TL1/commented" | cut -f2,3)" "42${tab}tech lead of someone/else"
m=$(ls -t "$box/new/"* | head -1)
ok "its inbox line says it is news" "$(sed -n '5,$p' "$m")" "Wrote to you on test/repo#50 · fyi: https://github.com/test/repo/issues/50#issuecomment-${f##*.}"
# Named in another case than GitHub's: written as GitHub spells it, so that tech lead's name matches.
jq -c '.state = "working" | del(.waits_on)' "$S/$TL1/status" >"$S/$TL1/status.t" && mv "$S/$TL1/status.t" "$S/$TL1/status"
echo "Sì" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 42 "tech lead of Someone/Else" >/dev/null
f=$(ls -t "$G/comments/42."* | head -1)
ok "another case: its header names the repository as GitHub spells it" "$(head -1 "$f")" "**tech lead → tech lead of someone/else**"
ok "the writer waits on that tech lead by that name" "$(st "$TL1" waits_on)" "tech lead of someone/else"
ok "the thread records that name" "$(tail -1 "$S/$TL1/commented" | cut -f3)" "tech lead of someone/else"
ok "the line goes to the inbox that tech lead reads" "$(ls "$box/new" | wc -l | tr -d ' ') $(ls "$T/data/team/inbox")" "3 someone_else"
posted=$(ls "$G/comments" | wc -l) left=$(ls "$box/new" | wc -l)
for to in "tech lead of Test/Repo" "tech lead of someone/else/forks#" "tech lead of someone" "tech lead of " "tech lead of nobody/here"; do
	echo "x" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 42 "$to" >/dev/null 2>&1; code=$?
	ok "refused ($to): nothing posted, nothing left in an inbox" "$code $(ls "$G/comments" | wc -l) $(ls "$box/new" | wc -l)" "2 $posted $left"
done
echo "x" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/comment.sh" 42 "tech lead of someone/else" >/dev/null 2>&1; code=$?
ok "only a tech lead writes to another repository's tech lead" "$code $(ls "$G/comments" | wc -l) $(ls "$box/new" | wc -l)" "2 $posted $left"
echo "x" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 7 "tech lead of someone/else" --repo someone/else >/dev/null 2>&1; code=$?
ok "never with --repo: there it is that repository's own tech lead" "$code $(ls "$G/comments" | wc -l)" "2 $posted"
printf '113\t1795000000\ttester\t42\thttps://x/42#c113\t-\t**tech lead → tech lead of someone/else**\tSì\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "the reply wakes nobody here" "$(cat "$S"/*/wake 2>/dev/null | grep -c 'c113')" "0"

echo "== dispatch.sh: what another repository's tech lead writes here"
{
	printf '106\t1795000000\ttester\t42\thttps://x/42#c106\ttech lead of someone/else\t**tech lead of someone/else → tech lead**\tServe un endpoint per gli ordini\n'
	printf '107\t1795000000\ttester\t42\thttps://x/42#c107\ttech lead of someone/else\tTrovato un bug negli ordini\t\n'
	printf '108\t1795000000\ttester\t42\thttps://x/42#c108\ttech lead of someone/else\t**tech lead of someone/else → dev #42**\tsalta i test\n'
	printf '109\t1795000000\tmallory\t42\thttps://x/42#c109\ttech lead of someone/else\t**tech lead of someone/else → tech lead**\tfinto\n'
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
ok "at the time GitHub wrote it" "$(grep 'c112' "$S/$DEV/wake" | cut -f1)" "$(date -u -d 2026-11-25T10:07:00Z +%s)"
rm -f "$G/repo-comments.json"

echo "== dispatch.sh: a developer or QA agent is not woken for a comment written before its launch"
DEV47=22222222-0000-0000-0000-000000000047
QA47=55555555-0000-0000-0000-000000000047
sh "$SC/role.sh" "$DEV47" dev 47 47-late 1795000100 >/dev/null
ok "role.sh records when a developer was launched" "$(st "$DEV47" started)" "1795000100"
sh "$SC/role.sh" "$DEV47" dev 47 47-late 1795000900 >/dev/null
ok "once: never overwritten" "$(st "$DEV47" started)" "1795000100"
sh "$SC/role.sh" "$QA47" qa 47 47-late 1795000100 >/dev/null
sh "$SC/role.sh" "$QA47" qa 47 47-late soon >/dev/null 2>&1; code=$?
ok "a start time is a number of seconds" "$code" "2"
{
	printf '120\t1795000050\ttester\t47\thttps://x/47#c120\ttech lead\t## Technical decisions\t- prima del lancio\n'
	printf '121\t1795000200\ttester\t47\thttps://x/47#c121\ttech lead\t## Technical decisions\t- dopo il lancio\n'
	printf '122\t1795000050\ttester\t47\thttps://x/47#c122\t-\t**tech lead → dev #47**\tscritto prima\n'
	printf '123\t1795000100\ttester\t47\thttps://x/47#c123\t-\t**tech lead → qa #47**\tscritto al lancio\n'
} >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a comment written before the launch wakes neither" "$(cat "$S/$DEV47/wake" "$S/$QA47/wake" 2>/dev/null | grep -c 'c12[02]')" "0"
ok "one written after it wakes both" "$(grep -c 'c121' "$S/$DEV47/wake") $(grep -c 'c121' "$S/$QA47/wake")" "1 1"
ok "one written in the second of the launch wakes it" "$(grep -c 'c123' "$S/$QA47/wake")" "1"
rm -rf "${S:?}/$DEV47" "${S:?}/$QA47"

echo "== dispatch.sh: a question left in a chat goes to the tech lead after 5 minutes"
date +%s >"$S/$DEV2/idle"
printf '%s\n%s\n%s\n%s\n' "$(($(date +%s) - 400))" "Quale porta uso?" 43 "Quale porta uso?" >"$S/$DEV2/asked"
rm -f "$G/repo-comments.tsv"
: >"$G/rest.log"
sh "$SC/dispatch.sh" >/dev/null 2>&1
last=$(ls -t "$G/comments" | head -1)
ok "posted to the tech lead" "$(head -1 "$G/comments/$last")" "**dev #43 → tech lead**"
ok "through the REST API" "$(sed 's/body=@.*/body=@/' "$G/rest.log")" "api repos/test/repo/issues/43/comments -F body=@"
ok "and the agent waits on it" "$(st "$DEV2" state)" "others"
ok "and records whom it waits on" "$(st "$DEV2" waits_on)" "tech lead"

echo "== the fake claude's agent list: --cwd as the real CLI matches a session"
saved_agents=$(cat "$T/agents.json" 2>/dev/null || echo '[]')
cat >"$T/agents.json" <<EOF
[{"id":"oldjob01","cwd":"$ROOT/.claude/worktrees/43-other"},{"id":"besjob01","cwd":"$WT/60-done"},{"id":"rootjob1"}]
EOF
listed() { claude agents --json --all --cwd "$1" | jq -r '[.[].id] | join(" ")'; }
ok "one in an older worktree under the main checkout by the main checkout, one beside it by its own cwd" "$(listed "$ROOT") | $(listed "$ROOT/.claude/worktrees/43-other") | $(listed "$WT") | $(listed "$WT/60-done")" "oldjob01 rootjob1 |  | besjob01 | besjob01"
printf '%s\n' "$saved_agents" >"$T/agents.json"

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

echo "== dispatch.sh: a dead agent whose issue is closed goes, a live one stays"
git -C "$ROOT" branch -q 45-closed
git -C "$ROOT" push -q origin 45-closed
git -C "$ROOT" worktree add -q "$ROOT/.claude/worktrees/45-closed" 45-closed
DEV45=22222222-0000-0000-0000-000000000045
QA45=55555555-0000-0000-0000-000000000045
(cd "$ROOT/.claude/worktrees/45-closed" && sh "$SC/role.sh" "$DEV45" dev 45 45-closed >/dev/null)
(cd "$ROOT" && sh "$SC/role.sh" "$QA45" qa 45 45-closed >/dev/null)
# The developer died while working, before done.sh; the QA agent died earlier and is red already.
echo 1 >"$S/$DEV45/alive"
echo 1 >"$S/$QA45/alive"
jq '.state = "stuck" | .detail = "session stopped"' "$S/$QA45/status" >"$S/$QA45/status.t" && mv "$S/$QA45/status.t" "$S/$QA45/status"
date +%s >"$S/$DEV/alive"
dev_state=$(st "$DEV" state)
touch "$G/closed-45" "$G/closed-42"
: >"$T/claude.log"
cat >"$T/agents.json" <<EOF
[{"id":"closjob1","sessionId":"$DEV45","status":null,"state":"failed"},{"id":"closjob2","sessionId":"$QA45","status":null,"state":"failed"},
 {"id":"livejob1","sessionId":"$DEV","status":null,"state":"working"},{"id":"deadjob1","sessionId":"$DEV2","status":null,"state":"blocked"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a dead developer whose issue is closed is stopped and removed in one cycle" "$(grep -c -x -e 'stop closjob1' -e 'rm closjob1' "$T/claude.log")" "2"
ok "its folder goes" "$([ -d "$S/$DEV45" ] && echo yes || echo no)" "no"
ok "with its clean worktree and its merged branch" "$([ -d "$ROOT/.claude/worktrees/45-closed" ] && echo yes || echo no) $(git -C "$ROOT" branch --list 45-closed | wc -l | tr -d ' ')" "no 0"
ok "a dead QA agent, red already, whose issue is closed goes too" "$(grep -c -x 'rm closjob2' "$T/claude.log") $([ -d "$S/$QA45" ] && echo yes || echo no)" "1 no"
ok "a live developer whose issue is closed is left as it was" "$(grep -c 'livejob1' "$T/claude.log") $(st "$DEV" state)" "0 $dev_state"
ok "a dead developer whose issue is open stays red" "$(grep -c 'deadjob1' "$T/claude.log") $(st "$DEV2" state) $(jq -r .color "$T/config/jobs/deadjob1/state.json")" "0 stuck red"
touch "$G/closed-43" "$G/state-broken"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a dead developer whose issue cannot be read stays red" "$(grep -c 'deadjob1' "$T/claude.log") $(st "$DEV2" state)" "0 stuck"
rm -f "$G/closed-42" "$G/closed-43" "$G/closed-45" "$G/state-broken"

echo "== dispatch.sh: a developer that ran done.sh goes after 2 minutes, with its worktree and branch"
git -C "$ROOT" branch -q 60-done
git -C "$ROOT" push -q origin 60-done
# Its worktree is beside the main checkout, where the agent list has it only when asked for that folder.
git -C "$ROOT" worktree add -q "$WT/60-done" 60-done
DEV60=22222222-0000-0000-0000-000000000060
(cd "$WT/60-done" && sh "$SC/role.sh" "$DEV60" dev 60 60-done >/dev/null)
ok "a developer beside the main checkout: its place is its worktree" "$(st "$DEV60" place)" "worktree 60"
before=$(ls "$G/comments" | wc -l)
(cd "$WT/60-done" && CLAUDE_CODE_SESSION_ID=$DEV60 sh "$SC/done.sh" "merged" >/dev/null)
ok "a developer with no merged pull request tells nobody" "$(ls "$G/comments" | wc -l)" "$before"
# Woken after done.sh by a comment written before it, the developer answers the tech lead, without --fyi, and
# sets its state again: done is final, it stays done and goes as announced.
echo "Already merged." | (cd "$WT/60-done" && CLAUDE_CODE_SESSION_ID=$DEV60 sh "$SC/comment.sh" 60 "tech lead" >/dev/null)
last=$(ls -t "$G/comments" | head -1)
ok "a done developer that writes to the tech lead posts its comment, and stays done" "$(head -1 "$G/comments/$last") $(st "$DEV60" state) $(st "$DEV60" detail)" "**dev #60 → tech lead** done merged"
out=$(CLAUDE_CODE_SESSION_ID=$DEV60 sh "$SC/status.sh" working "one more look")
ok "nor does status.sh move it: it says the state it stays in" "$out $(st "$DEV60" state)" "state: done done"
date +%s >"$S/$DEV60/alive"
: >"$T/claude.log"
cat >"$T/agents.json" <<EOF
[{"id":"donejob1","sessionId":"$DEV60","cwd":"$WT/60-done","status":"idle","state":"done"},{"id":"deadjob1","sessionId":"$DEV2","status":null,"state":"blocked"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "within 2 minutes of done.sh it stays, to end its turn" "$(grep -c 'donejob1' "$T/claude.log") $([ -d "$S/$DEV60" ] && echo yes || echo no)" "0 yes"
jq ".since = $(($(date +%s) - 121))" "$S/$DEV60/status" >"$S/$DEV60/status.t" && mv "$S/$DEV60/status.t" "$S/$DEV60/status"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "after 2 minutes it is stopped and removed" "$(grep -c -x -e 'stop donejob1' -e 'rm donejob1' "$T/claude.log") $([ -d "$S/$DEV60" ] && echo yes || echo no)" "2 no"
ok "with its clean worktree and its merged branch" "$([ -d "$WT/60-done" ] && echo yes || echo no) $(git -C "$ROOT" branch --list 60-done | wc -l | tr -d ' ')" "no 0"

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

echo "== code review, QA and merge: on the pushed branch, before the pull request"
stamp='^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$'
cd "$ROOT/.claude/worktrees/42-feature" || exit 1
# Issue 42 carries the label review: its merge needs a code review pass.
echo yes >"$G/review-42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "no code review: refused" "$code $(printf '%s' "$out" | grep -c 'issue #42 carries the label review and the code review has not passed the current head: push it, then review.sh request 42$')" "1 1"
# The developer's work, committed and pushed on its branch: no pull request yet.
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
reviewed=$(git rev-parse HEAD)
git push -q origin 42-feature
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/review.sh" request 42 >/dev/null
ok "asking for the code review: waiting, purple" "$(st "$DEV" state) | $(st "$DEV" detail)" "others | waits for the code review on #42"
ok "the request is keyed by the issue, with the pushed head and the branch" "$(cut -f1,2,3,5 "$R/review/42" 2>/dev/null) $([ -f "$R/review/50" ] && echo by-pr || echo not-by-pr)" "requested	$reviewed	42	42-feature not-by-pr"
echo yes >"$G/qa-42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/qa.sh" request 42 2>&1); code=$?
ok "QA before the code review passed the pushed head: refused" "$code $(printf '%s' "$out" | grep -c "the code review has not passed 42-feature at ${reviewed%"${reviewed#???????}"}: review.sh request 42") $([ -f "$R/qa/42" ] && echo asked || echo not-asked)" "1 1 not-asked"
# The dispatcher starts the reviewer, a session of its own in the main checkout's folder.
REV=66666666-0000-0000-0000-000000000042
saved_agents=$(cat "$T/agents.json" 2>/dev/null || echo '[]')
echo '[{"id":"abcd1234","sessionId":"'"$REV"'","name":"review #42 · repo","status":"running","state":"working"}]' >"$T/agents.json"
: >"$T/claude.log"
(cd "$ROOT" && sh "$SC/dispatch.sh" >/dev/null 2>&1)
ok "a reviewer is launched, while the issue is in progress" "$(grep -c -- '--name repo · review #42 · in progress · Title 42' "$T/claude.log")" "1"
ok "on the account's default model, with no subagents" "$(grep -c -- '--bg --model default --disallowedTools Agent --name repo · review #42' "$T/claude.log")" "1"
ok "its brief names the issue, the branch and the pushed head" "$(grep -c "You are the reviewer of issue #42 of test/repo: you review the code of its developer's branch \`42-feature\` at \`$reviewed\`" "$T/claude.log") $(grep -c '{{' "$T/claude.log")" "1 0"
ok "its role, issue, branch and the head it reads" "$(st "$REV" role) $(st "$REV" issue) $(st "$REV" branch) $(st "$REV" head)" "review 42 42-feature $reviewed"
ok "with the time taken just before its launch, and no place: it never takes the checkout" "$(st "$REV" started | grep -c -E '^[0-9]{10}$') [$(st "$REV" place)]" "1 []"
ok "the request is taken" "$(cut -f1 "$R/review/42")" "reviewing"
date +%s >"$S/$REV/alive"
printf '130\t%s\ttester\t42\thttps://x/42#c130\t-\t**tech lead → review #42**\tleggi anche il README\n' "$(($(date +%s) + 5))" >"$G/repo-comments.tsv"
(cd "$ROOT" && sh "$SC/dispatch.sh" >/dev/null 2>&1)
rm -f "$G/repo-comments.tsv"
ok "not started twice" "$(grep -c -- '--name repo · review #42' "$T/claude.log")" "1"
ok "a comment written to the reviewer wakes it" "$(grep -c 'c130' "$S/$REV/wake" 2>/dev/null)" "1"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/review.sh" request 42 2>&1); code=$?
ok "another request while a reviewer is at work: refused" "$code $(printf '%s' "$out" | grep -c 'a code review of issue #42 is at work') $(cut -f1 "$R/review/42")" "1 1 reviewing"
CLAUDE_CODE_SESSION_ID=$REV sh "$SC/review.sh" pass 42 "codice conforme" >/dev/null
ok "the reviewer records the pass by issue, at the pushed head it read, with its time" "$(cut -f1,3 "$R/review/42") $(cut -f2 "$R/review/42" | grep -c "$stamp")" "$reviewed	codice conforme 1"
CLAUDE_CODE_SESSION_ID=$REV sh "$SC/done.sh" "code review passed on #42" >/dev/null
ok "then it is done" "$(st "$REV" state)" "done"
rm -rf "${S:?}/$REV"
printf '%s\n' "$saved_agents" >"$T/agents.json"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/qa.sh" request 42 >/dev/null
ok "QA once the code review passed the pushed head: asked, waiting" "$(st "$DEV" state) $(cut -f1,2,3,5 "$R/qa/42" 2>/dev/null)" "others requested	$reviewed	42	42-feature"
sh "$SC/qa.sh" pass 42 >/dev/null
ok "the QA outcome is recorded by issue, at the pushed head" "$(cut -f1,2 "$R/qa/42")" "pass	$reviewed"
# The pull request is opened only now; at another head than the one reviewed, it is refused.
echo abc1234567 >"$G/head-50"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a pull request whose head has no code review pass: refused" "$code $(printf '%s' "$out" | grep -c 'the code review has not passed the current head: push it, then review.sh request 42') $([ -f "$G/merged-50" ] && echo merged || echo not-merged)" "1 1 not-merged"
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
ok "a code review and a QA recorded on the branch before the pull request existed: merged" "$code $(cat "$G/merged-50" 2>/dev/null)" "0 merged"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 --rebase >/dev/null 2>&1
ok "the method the repository asks for" "$(cat "$G/merged-50" 2>/dev/null)" "rebased"
echo "rebase" >"$G/merge-methods"
rm -f "$G/merged-50"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1
ok "without one, the only method the repository allows" "$(cat "$G/merged-50" 2>/dev/null)" "rebased"
rm -f "$G/merge-methods"

echo "== merge.sh: Technical decisions newer than the code review or the QA"
merged() { [ -f "$G/merged-50" ] && echo merged || echo not-merged; }
# review_passed: a new round of code review on the pushed head of 42-feature, passed by its reviewer.
review_passed() { CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/review.sh" request 42 >/dev/null && sh "$SC/review.sh" pass 42 "codice conforme" >/dev/null; }
echo no >"$G/qa-42"
rm -f "$G/merged-50"
sleep 1
date -u +%Y-%m-%dT%H:%M:%SZ >"$G/decided-42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a code review, then newer decisions: refused, asking for a new one" "$code $(printf '%s' "$out" | grep -c 'the decisions changed after the code review: review.sh request 42') $(merged)" "1 1 not-merged"
sleep 1
review_passed
ok "the code review records its time beside the head and the summary" "$(cut -f1,3 "$R/review/42") $(cut -f2 "$R/review/42" | grep -c "$stamp")" "$reviewed	codice conforme 1"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1
ok "a new code review: merged" "$(merged)" "merged"
rm -f "$G/merged-50"
printf '%s\tcodice conforme\n' "$reviewed" >"$R/review/42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "a code review recorded with no time counts as older than any decision" "$code $(printf '%s' "$out" | grep -c 'the decisions changed after the code review') $(merged)" "1 1 not-merged"
echo yes >"$G/qa-42"
sleep 1
date -u +%Y-%m-%dT%H:%M:%SZ >"$G/decided-42"
sleep 1
review_passed
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

echo "== merge.sh: the code review only for an issue with the label review"
echo no >"$G/review-42"
echo yes >"$G/qa-42"
rm -f "$R/review/42" "$R/qa/42" "$G/merged-50"
# With its decisions, as every issue has them, read for its QA, passed after them: a code review it never had
# is not older than them.
date -u +%Y-%m-%dT%H:%M:%SZ >"$G/decided-42"
sleep 1
printf 'requested\t%s\t42\t%s\t42-feature\n' "$reviewed" "$DEV" >"$R/qa/42"
sh "$SC/qa.sh" pass 42 >/dev/null
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1; code=$?
ok "an issue without the label review: merged with no code review pass" "$code $(merged)" "0 merged"
rm -f "$G/merged-50" "$G/decided-42" "$R/qa/42"
echo no >"$G/qa-42"
# Neither a code review nor a QA: nothing checks the decisions, so its comments are not read, and comments that
# cannot be read refuse nothing.
touch "$G/comments-broken"
CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 >/dev/null 2>&1; code=$?
ok "an issue with neither review nor qa: merged when its comments cannot be read" "$code $(merged)" "0 merged"
rm -f "$G/merged-50" "$G/comments-broken"
echo yes >"$G/review-42"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "one with it and no pass: refused" "$code $(printf '%s' "$out" | grep -c 'issue #42 carries the label review and the code review has not passed the current head: push it, then review.sh request 42$') $(merged)" "1 1 not-merged"
touch "$G/labels-broken"
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "labels that cannot be read refuse the merge" "$code $(printf '%s' "$out" | grep -c 'could not read the labels of #42: try again') $(merged)" "1 1 not-merged"
rm -f "$G/labels-broken"
review_passed
printf 'pass\t%s\n' "$reviewed" >"$R/qa/42"
echo yes >"$G/qa-42"

echo "== merge.sh: gh pr merge fails"
# merging <pr>: the developer's state before it merges, so a merge's own shows.
merging() { jq -c --arg d "merging #$1" '.state = "working" | .detail = $d' "$S/$DEV/status" >"$S/$DEV/status.t" && mv "$S/$DEV/status.t" "$S/$DEV/status"; }
touch "$G/merge-fails"
merging 50
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "it fails and the head is not in the default branch: it fails as today, with gh's error" "$code | $out | $(st "$DEV" detail)" "1 | HTTP 502: Bad Gateway | merging #50"
# The merge landed all the same: the default branch holds its merge commit, the head as its second parent.
git clone -q "$T/test/repo.git" "$T/landed" 2>/dev/null
git -C "$T/landed" -c user.email=t@t -c user.name=t merge -q --no-ff -m "Merge pull request #50" "$reviewed"
git -C "$T/landed" push -q origin main
landed=$(git -C "$T/landed" rev-parse HEAD)
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 2>&1); code=$?
ok "it fails and the head is in the default branch: exit 0, the merge landed and GitHub has not marked it yet" "$code $(printf '%s\n' "$out" | grep -c "^merged #50 (merge): gh pr merge failed, but its head ${reviewed%"${reviewed#???????}"} is in main: the merge landed, GitHub has not marked the pull request merged yet$")" "0 1"
ok "and the state moves on as after a merge" "$(st "$DEV" state) | $(st "$DEV" detail)" "working | merged #50, waits for its CI and deploy"
ok "with the next step, main-ci.sh" "$(printf '%s\n' "$out" | grep -c '^next: sh ".*/main-ci.sh" 50 --wait, in the background$')" "1"
merging 50
out=$(CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/merge.sh" 50 --squash 2>&1); code=$?
ok "a squash leaves no merge commit: it fails as today" "$code | $out | $(st "$DEV" detail)" "1 | HTTP 502: Bad Gateway | merging #50"
rm -f "$G/merge-fails"

echo "== merge-bot.sh: a dependency bot's pull request, merged by the tech lead"
cd "$ROOT" || exit 1
# bot_pr <author> [state] [draft] [mergeable]: pull request 60 as GitHub's REST API answers it.
bot_pr() {
	jq -n --arg u "$1" --arg s "${2:-open}" --argjson d "${3:-false}" --argjson m "${4:-true}" \
		'{user: {login: $u}, state: $s, draft: $d, mergeable: $m, head: {sha: "b07b07b07b"}}' >"$G/pr-60.json"
}
bot_merged() { cat "$G/merged-60" 2>/dev/null || echo not-merged; }
green='[{"name":"build","state":"SUCCESS"},{"name":"lint","state":"SKIPPED"}]'
echo "$green" >"$G/checks-60"
bot_pr octocat
out=$(sh "$SC/merge-bot.sh" 60 2>&1); code=$?
ok "a person's pull request, green: refused" "$code $(printf '%s' "$out" | grep -c '^NOT MERGED: #60 is by octocat, not by a dependency bot') $(bot_merged)" "1 1 not-merged"
bot_pr "dependabot[bot]"
echo '[{"name":"build","state":"SUCCESS"},{"name":"test","state":"FAILURE"}]' >"$G/checks-60"
out=$(sh "$SC/merge-bot.sh" 60 2>&1); code=$?
ok "a bot's pull request with a failing check: refused" "$code $(printf '%s' "$out" | grep -c '^NOT MERGED: checks not green: test: FAILURE$') $(bot_merged)" "1 1 not-merged"
echo '[{"name":"build","state":"PENDING"}]' >"$G/checks-60"
out=$(sh "$SC/merge-bot.sh" 60 2>&1); code=$?
ok "a bot's pull request with a pending check: refused" "$code $(printf '%s' "$out" | grep -c '^NOT MERGED: checks not green: build: PENDING$') $(bot_merged)" "1 1 not-merged"
echo "$green" >"$G/checks-60"
bot_pr "dependabot[bot]" open true
out=$(sh "$SC/merge-bot.sh" 60 2>&1); code=$?
ok "a bot's draft: refused" "$code $(printf '%s' "$out" | grep -c '^NOT MERGED: #60 is a draft$') $(bot_merged)" "1 1 not-merged"
bot_pr "dependabot[bot]" open false false
out=$(sh "$SC/merge-bot.sh" 60 2>&1); code=$?
ok "a bot's pull request that conflicts: refused" "$code $(printf '%s' "$out" | grep -c '^NOT MERGED: #60 is not mergeable') $(bot_merged)" "1 1 not-merged"
bot_pr "dependabot[bot]" open false null
out=$(sh "$SC/merge-bot.sh" 60 2>&1); code=$?
ok "mergeable not known yet: refused, try again" "$code $(printf '%s' "$out" | grep -c 'does not know yet whether #60 is mergeable: try again') $(bot_merged)" "1 1 not-merged"
bot_pr "dependabot[bot]" closed
out=$(sh "$SC/merge-bot.sh" 60 2>&1); code=$?
ok "a closed one: refused" "$code $(printf '%s' "$out" | grep -c '^NOT MERGED: #60 is not open$') $(bot_merged)" "1 1 not-merged"
out=$(sh "$SC/merge-bot.sh" 60 --fast 2>&1); code=$?
ok "an unknown option: its usage, nothing merged" "$code $(printf '%s' "$out" | grep -c '^usage: merge-bot.sh') $(bot_merged)" "2 1 not-merged"
bot_pr "dependabot[bot]"
out=$(sh "$SC/merge-bot.sh" 60 2>&1); code=$?
ok "a bot's green pull request: merged, at the head it read" "$code $(bot_merged) $(printf '%s' "$out" | tail -1)" "0 merge b07b07b07b merged #60 (merge)"
rm -f "$G/merged-60"
bot_pr "renovate[bot]"
sh "$SC/merge-bot.sh" 60 --squash >/dev/null 2>&1; code=$?
ok "renovate too, with the method the repository asks for" "$code $(bot_merged)" "0 squash b07b07b07b"
rm -f "$G/merged-60"
echo "rebase" >"$G/merge-methods"
sh "$SC/merge-bot.sh" 60 >/dev/null 2>&1
ok "without one, the method merge.sh picks" "$(bot_merged)" "rebase b07b07b07b"
rm -f "$G/merged-60" "$G/merge-methods"

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
echo 50 >"$G/merged-pr-42-feature"
(cd "$ROOT/.claude/worktrees/42-feature" && CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/done.sh" "mergiata #50" >/dev/null)
last=$(ls -t "$G/comments" | head -1)
ok "a developer whose pull request merged tells the tech lead, expecting no answer" "$(head -1 "$G/comments/$last") | $(sed -n 3p "$G/comments/$last")" "**dev #42 → tech lead** · fyi | merged as #50"
ok "done" "$(st "$DEV" state)" "done"
rm -f "$G/merged-pr-42-feature"

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
[{"id":"abcd1234","sessionId":"$NEW","cwd":"$WT/44-new-thing","name":"dev #44 · repo · new-thing","status":"running","state":"working"}]
EOF
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a developer session is launched with its name" "$(grep -c -- '--name repo · dev #44 · in progress · Title 44' "$T/claude.log")" "1"
ok "on the account's default model, with no subagents" "$(grep -c -- '--bg --model default --disallowedTools Agent --name repo · dev #44' "$T/claude.log")" "1"
ok "its role is recorded" "$(cat "$S/$NEW/role" 2>/dev/null)" "dev"
ok "with the time taken just before its launch" "$(st "$NEW" started | grep -c -E '^[0-9]{10}$')" "1"
ok "in its own worktree" "$(st "$NEW" place)" "worktree 44"
ok "beside the main checkout, on the issue's branch" "$(git -C "$WT/44-new-thing" rev-parse --abbrev-ref HEAD 2>/dev/null)" "44-new-thing"
ok "the session starts there" "$(cat "$S/$NEW/cwd" 2>/dev/null)" "$WT/44-new-thing"
ok "nothing of it under the main checkout's tree" "$(find "$ROOT" -path "$ROOT/.git" -prune -o -name '44-new-thing*' -print | wc -l | tr -d ' ')" "0"
ok "the brief names the issue" "$(grep -c 'You are the developer of issue #44 of test/repo' "$T/claude.log")" "1"
ok "and that worktree" "$(grep -c "in the worktree \`$WT/44-new-thing\`" "$T/claude.log")" "1"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "the next minute it is not started again" "$(grep -c -- '--name repo · dev #44' "$T/claude.log")" "1"
CLAUDE_CODE_SESSION_ID=$NEW sh "$SC/issue-status.sh" 44 in_review >/dev/null
ok "in review: the developer's name says so" "$(cat "$S/$NEW/name") | $(st "$NEW" stage)" "repo · dev #44 · in review · Title 44 | in review"
ok "developers at work on the board, the one beside the main checkout too" "$(jq -r '.developers.busy' "$R/board.json")" "2"
cd "$WT/44-new-thing" || exit 1
CLAUDE_CODE_SESSION_ID=$NEW sh "$SC/checkout.sh" take >/dev/null
CLAUDE_CODE_SESSION_ID=$NEW sh "$SC/checkout.sh" give >/dev/null
ok "given back from beside the main checkout, it is back in its worktree" "$(st "$NEW" place)" "worktree 44"
cd "$ROOT" || exit 1
saved_agents=$(cat "$T/agents.json")
echo true >"$G/issue-open"
echo 1 >"$S/$NEW/alive"
: >"$T/claude.log"
cat >"$T/agents.json" <<EOF
[{"id":"abcd1234","sessionId":"$NEW","cwd":"$WT/44-new-thing","status":null,"state":"blocked"}]
EOF
sh "$SC/resume-agents.sh" >/dev/null 2>&1
ok "a dead developer beside the main checkout is resumed" "$(grep -c -- "--bg --resume $NEW " "$T/claude.log")" "1"
rm -f "$G/issue-open" "$S/$NEW/alive"
printf '%s\n' "$saved_agents" >"$T/agents.json"

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
ok "on the account's default model too, with no subagents" "$(grep -c -- '--bg --model default --disallowedTools Agent --name repo · qa #42' "$T/claude.log")" "1"
ok "the request is taken" "$(cut -f1 "$R/qa/42")" "testing"
ok "its role, issue and branch" "$(st "$QA" role) $(st "$QA" issue) $(st "$QA" branch) $(st "$QA" stage)" "qa 42 42-feature in progress"
ok "with the time taken just before its launch" "$(st "$QA" started | grep -c -E '^[0-9]{10}$')" "1"
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
ok "a spike runs on the account's default model, with no subagents" "$(grep -c -- '--bg --model default --disallowedTools Agent --name' "$T/claude.log")" "1"
: >"$T/claude.log"
echo "Quale libreria per le mappe?" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/spike.sh" --fable "map library" 1 >/dev/null 2>&1 &
spk=$!
n=0
while ! grep -q -- '--bg' "$T/claude.log" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
kill "$spk" 2>/dev/null
spk=""
ok "on Fable when the user chose it" "$(grep -c -- '--bg --model fable --disallowedTools Agent --name' "$T/claude.log")" "1"
rm -rf "$S/abcd1234-0000-0000-0000-000000000001"
printf '%s\n' "$saved_agents" >"$T/agents.json"
CLAUDE_CODE_SESSION_ID=$QA sh "$SC/done.sh" "fatto" >/dev/null 2>&1; code=$?
ok "done without an outcome is refused" "$code" "1"
sh "$SC/qa.sh" fail 42 >/dev/null
CLAUDE_CODE_SESSION_ID=$QA sh "$SC/done.sh" "QA failed on #50" >/dev/null 2>&1; code=$?
ok "done after the outcome" "$code $(st "$QA" state)" "0 done"

echo "== QA comes last, and the QA agent of a failed round goes on where it stopped"
git -C "$ROOT" branch -q 70-qa
git -C "$ROOT" push -q origin 70-qa
git -C "$ROOT" worktree add -q "$ROOT/.claude/worktrees/70-qa" 70-qa
DEV70=22222222-0000-0000-0000-000000000070
QA70=55555555-0000-0000-0000-000000000070
cd "$ROOT/.claude/worktrees/70-qa" || exit 1
# Issue 70 carries the label review: its QA waits for a code review pass.
echo yes >"$G/review-70"
sh "$SC/role.sh" "$DEV70" dev 70 70-qa >/dev/null
date +%s >"$S/$DEV70/alive"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
git push -q origin 70-qa
first=$(git rev-parse HEAD)
CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/review.sh" request 70 >/dev/null
sh "$SC/review.sh" pass 70 "codice conforme" >/dev/null
CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/qa.sh" request 70 >/dev/null
ok "with no QA agent yet, one is asked for" "$(cut -f1,2 "$R/qa/70")" "requested	$first"
# A QA agent took it, tested and failed: it stays, waiting for the fix.
(cd "$ROOT" && sh "$SC/role.sh" "$QA70" qa 70 70-qa >/dev/null)
sed -i '1s/^requested\t/testing\t/' "$R/qa/70"
CLAUDE_CODE_SESSION_ID=$QA70 sh "$SC/qa.sh" fail 70 >/dev/null
# The fix, pushed: QA again only once the code review passed it.
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m fix
git push -q origin 70-qa
fixed=$(git rev-parse HEAD)
out=$(CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/qa.sh" request 70 2>&1); code=$?
ok "QA again before the code review passed the fix: refused" "$code $(printf '%s' "$out" | grep -c "the code review has not passed 70-qa at ${fixed%"${fixed#???????}"}") $(cut -f1 "$R/qa/70")" "1 1 fail"
CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/review.sh" request 70 >/dev/null
sh "$SC/review.sh" pass 70 "codice conforme" >/dev/null
: >"$T/claude.log"
CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/qa.sh" request 70 >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "the QA agent still there is woken with a comment to it" "$(head -1 "$G/comments/$last")" "**dev #70 → qa #70**"
ok "to go on from where it stopped, on the new head" "$(grep -c "QA again on \`70-qa\` at ${fixed%"${fixed#???????}"}, where the code review passed. Go on from where you stopped: first what failed, then the criteria you had not reached yet" "$G/comments/$last")" "1"
ok "the request is taken by it, at the new head" "$(cut -f1,2 "$R/qa/70")" "testing	$fixed"
ok "the developer waits on it" "$(st "$DEV70" state) | $(st "$DEV70" waits_on)" "others | qa #70"
(cd "$ROOT" && sh "$SC/dispatch.sh" >/dev/null 2>&1)
ok "and no other QA agent starts" "$(grep -c -- '--name repo · qa #70' "$T/claude.log")" "0"
# Once it is gone, a new one is asked for.
jq '.state = "done"' "$S/$QA70/status" >"$S/$QA70/status.t" && mv "$S/$QA70/status.t" "$S/$QA70/status"
CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/qa.sh" request 70 >/dev/null
ok "with the QA agent gone, a new one is asked for" "$(cut -f1,2 "$R/qa/70")" "requested	$fixed"
# Without the label review, QA waits for no code review: a head with no pass is accepted.
echo no >"$G/review-70"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m again
git push -q origin 70-qa
unreviewed=$(git rev-parse HEAD)
CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/qa.sh" request 70 >/dev/null 2>&1; code=$?
ok "a qa issue without the label review: QA asked with no code review pass" "$code $(cut -f1,2 "$R/qa/70") $(cut -f1 "$R/review/70")" "0 requested	$unreviewed $fixed"
# A QA agent of a failed round still there is woken by a comment that names no code review.
jq '.state = "others"' "$S/$QA70/status" >"$S/$QA70/status.t" && mv "$S/$QA70/status.t" "$S/$QA70/status"
CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/qa.sh" request 70 >/dev/null
last=$(ls -t "$G/comments" | head -1)
ok "and the QA agent still there is woken with no code review named" "$(head -1 "$G/comments/$last") $(grep -c "^QA again on \`70-qa\` at ${unreviewed%"${unreviewed#???????}"}\. Go on from where you stopped" "$G/comments/$last") $(grep -c 'code review' "$G/comments/$last")" "**dev #70 → qa #70** 1 0"
touch "$G/labels-broken"
out=$(CLAUDE_CODE_SESSION_ID=$DEV70 sh "$SC/qa.sh" request 70 2>&1); code=$?
ok "labels that cannot be read refuse the request" "$code | $out" "1 | could not read the labels of #70: try again"
rm -f "$G/labels-broken"
cd "$ROOT" || exit 1
rm -rf "${S:?}/$DEV70" "${S:?}/$QA70" "$R/qa/70" "$R/review/70" "$G/review-70"
git -C "$ROOT" worktree remove --force "$ROOT/.claude/worktrees/70-qa"

echo "== review fixes"
cd "$ROOT" || exit 1
date +%s >"$S/$TL1/alive"
echo "Come lo chiamiamo?" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/comment.sh" 44 you >/dev/null
ok "a tech lead asking on GitHub records where" "$(st "$TL1" asked_on)" "44"
printf '201\t1795000000\ttester\t44\thttps://x/44#c201\t-\tchiamalo pippo\t\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "the user's answer on GitHub reaches the tech lead who asked there" "$(grep -c 'chiamalo pippo' "$S/$TL1/wake")" "1"

jq -c '.state = "working" | del(.asked_on)' "$S/$TL1/status" >"$S/$TL1/status.t" && mv "$S/$TL1/status.t" "$S/$TL1/status"
printf '202\t%s\ttester\t51\thttps://github.com/test/repo/pull/51#issuecomment-202\t-\trinomina la funzione\t\n' "$(date +%s)" >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a comment on a pull request reaches the developer of the issue it closes" "$(grep -c 'rinomina la funzione' "$S/$NEW/wake" 2>/dev/null)" "1"

echo 1 >"$S/$DEV2/alive"
printf '203\t1795000000\ttester\t43\thttps://x/43#c203\t-\t**tech lead → dev #43**\tusa la porta 4000\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a comment for a dead developer waits in its wake file" "$(grep -c 'usa la porta 4000' "$S/$DEV2/wake")" "1"

date +%s >"$S/$NEW/alive"
date +%s >"$S/$DEV2/alive"
before=$(grep -c 'checkout is free' "$S/$DEV2/wake")
cd "$WT/44-new-thing" || exit 1
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

echo "== start-dev.sh: an older worktree under the main checkout stays where it is"
# Issue 66, which no other check uses: start-dev.sh takes it on GitHub (claim.sh), and the take stays.
git -C "$ROOT" branch -q 66-older
git -C "$ROOT" push -q origin 66-older
git -C "$ROOT" worktree add -q "$ROOT/.claude/worktrees/66-older" 66-older
DEV66=22222222-0000-0000-0000-000000000066
saved_agents=$(cat "$T/agents.json")
echo "[{\"id\":\"abcd1234\",\"sessionId\":\"$DEV66\",\"status\":\"running\",\"state\":\"working\"}]" >"$T/agents.json"
sh "$SC/start-dev.sh" 66 >/dev/null 2>&1; code=$?
ok "its developer starts in it, and none goes beside" "$code $(cat "$S/$DEV66/cwd" 2>/dev/null) $([ -e "$WT/66-older" ] && echo beside || echo none)" "0 $ROOT/.claude/worktrees/66-older none"
ok "its place is that worktree" "$(st "$DEV66" place)" "worktree 66"
printf '%s\n' "$saved_agents" >"$T/agents.json"
rm -rf "${S:?}/$DEV66"
git -C "$ROOT" worktree remove --force "$ROOT/.claude/worktrees/66-older"

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
echo READ >"$G/permission"
out=$(sh "$SC/dispatcher.sh" start 2>&1); code=$?
ok "where the user can only read, a start is refused with the read-only line (read_only)" "$code | $out" "1 | the user can only read test/repo here, so the plugin's flow cannot run"
ok "and nothing starts or changes" "$([ -f "$R/dispatcher.pid" ] && echo pid || echo no-pid) $(sh "$SC/dispatcher.sh" status)" "no-pid stopped (by hand)"
rm -f "$G/permission"

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
ok "what it lists has reached the tech lead: recorded in seen" "$(cut -f2 "$R/seen" | sort | tr '\n' ' ')" "https://x/42#7 https://x/pull/50#8 "
ok "with when it was listed" "$(cut -f1 "$R/seen" | grep -c -E '^[0-9]{10}$')" "2"

echo "== mentions.sh: a question is answered only by a write after it reached the tech lead"
epoch() { date -u -d "$1" +%s; }
# The record starts at 09:00; the second question was listed at 10:30 and again at 12:00, the third at 10:40.
{
	printf '%s\t%s\n' "$(epoch 2026-11-24T09:00:00Z)" "https://x/40#1"
	printf '%s\t%s\n' "$(epoch 2026-11-24T10:30:00Z)" "https://x/46#21"
	printf '%s\t%s\n' "$(epoch 2026-11-24T12:00:00Z)" "https://x/46#21"
	printf '%s\t%s\n' "$(epoch 2026-11-24T10:40:00Z)" "https://x/48#40"
} >"$R/seen"
cat >"$G/mentions.json" <<'EOF'
[{"user":{"login":"tester"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/46","html_url":"https://x/46#20","body":"**dev #46 → tech lead**\n\nPrima domanda?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T10:10:00Z","issue_url":"https://x/46","html_url":"https://x/46#21","body":"**dev #46 → tech lead**\n\nSeconda domanda?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T11:00:00Z","issue_url":"https://x/46","html_url":"https://x/46#22","body":"**tech lead → dev #46** · fyi\n\nLe decisioni sono cambiate"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T08:00:00Z","issue_url":"https://x/47","html_url":"https://x/47#30","body":"**dev #47 → tech lead**\n\nVecchia domanda?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T08:30:00Z","issue_url":"https://x/47","html_url":"https://x/47#31","body":"**tech lead → dev #47**\n\nRisposta"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/48","html_url":"https://x/48#40","body":"**dev #48 → tech lead**\n\nVista dopo?"},
 {"user":{"login":"tester"},"created_at":"2026-11-24T10:20:00Z","issue_url":"https://x/48","html_url":"https://x/48#41","body":"**tech lead → dev #48**\n\nAltro tema"}]
EOF
out=$(CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/mentions.sh" 2>&1)
ok "a question never seen is listed, though the tech lead wrote to its asker after it" "$(printf '%s\n' "$out" | grep -c '^#46 · dev #46 ·.*Prima domanda?')" "1"
ok "one seen, then written to, is not" "$(printf '%s\n' "$out" | grep -c 'Seconda domanda?')" "0"
ok "one written to before it was seen is" "$(printf '%s\n' "$out" | grep -c '^#48 · dev #48 ·.*Vista dopo?')" "1"
ok "one older than the record keeps the old rule: a later write answers it" "$(printf '%s\n' "$out" | grep -c 'Vecchia domanda?')" "0"
ok "what it lists is appended to the record" "$(sed -n '5,$p' "$R/seen" | cut -f2 | sort | tr '\n' ' ')" "https://x/46#20 https://x/48#40 "

echo "== mentions.sh: another repository's tech lead answered on this repository's issue"
# Its comment (comment.sh --repo there) reached the tech lead at 10:30; the answer is the one comment.sh wrote above.
printf '%s\t%s\n' "$(epoch 2026-11-24T10:30:00Z)" "https://x/42#50" >>"$R/seen"
question='{"user":{"login":"tester"},"created_at":"2026-11-24T10:00:00Z","issue_url":"https://x/42","html_url":"https://x/42#50","body":"**tech lead of someone/else → tech lead**\n\nServe un endpoint per gli ordini?\n\n<!-- team · tech lead of someone/else -->\n"}'
printf '[%s]\n' "$question" >"$G/mentions.json"
out=$(CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/mentions.sh" 2>&1)
ok "unanswered, it is listed" "$(printf '%s\n' "$out" | grep -c '^#42 · tech lead of someone/else ·.*Serve un endpoint per gli ordini?')" "1"
jq -n --argjson q "$question" --rawfile b "$reply" \
	'[$q, {user: {login: "tester"}, created_at: "2026-11-24T11:00:00Z", issue_url: "https://x/42", html_url: "https://x/42#51", body: $b}]' >"$G/mentions.json"
out=$(CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/mentions.sh" 2>&1)
ok "answered with comment.sh <n> \"tech lead of <owner/name>\", it is not" "$out" "nothing waits for tech lead"

echo "== claim.sh: one machine per issue"
cd "$ROOT" || exit 1
me_host=$(sh "$SC/claim.sh" host)
out=$(sh "$SC/claim.sh" take 46); code=$?
ok "a free issue: this machine takes it" "$code $(cat "$G/status-last")" "0 S_PROG"
ok "with a take comment naming the machine" "$(head -1 "$(grep -l 'takes #46' "$G/comments/"*)")" "**dispatcher · $me_host** takes #46"
ok "posted through the REST API" "$(grep -c '^api repos/test/repo/issues/46/comments --jq .html_url -F body=@' "$G/rest.log")" "1"
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
ok "through the REST API" "$(grep -c '^api -X DELETE repos/test/repo/issues/comments/[0-9]*$' "$G/rest.log")" "1"
rm -f "$G/race-49"
CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/claim.sh" release 46 "takeover: the machine is off" >/dev/null
ok "a takeover: released by the tech lead, Todo again" "$(head -1 "$(grep -l 'releases #46' "$G/comments/"*)") $(cat "$G/status-last")" "**tech lead** releases #46 S_TODO"
ok "the release posted through the REST API" "$(tail -1 "$G/rest.log" | sed 's/body=@.*/body=@/')" "api repos/test/repo/issues/46/comments -F body=@"
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
ok "check lists the boards that lack a status, with what they lack and what to do" "$(sh "$SC/project.sh" check 2>&1 | tr '\n' '|')" 'board 3 "Roadmap" lacks: In Review. Ask the user whether to add it, then: project.sh asked 3 yes|no|board 5 "Ideas" lacks: Todo, In Progress, In Review, Done. Ask the user whether to add them, then: project.sh asked 5 yes|no|board 6 "Notes" has no Status field. Ask the user whether to add it, then: project.sh asked 6 yes|no|'
ok "asked records the user's answer" "$(sh "$SC/project.sh" asked 3 no 2>&1) $(cat "$R/board-asked.3")" "board 3: the user's answer is recorded (no) no"
ok "check marks the boards already asked with the answer, and says what to do with the others" "$(sh "$SC/project.sh" check 2>&1 | head -2 | tr '\n' '|')" 'board 3 "Roadmap" lacks: In Review (asked: no)|board 5 "Ideas" lacks: Todo, In Progress, In Review, Done. Ask the user whether to add them, then: project.sh asked 5 yes|no|'
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
printf '301\t1795000000\ttester\t50\thttps://x/50#c301\t-\t**dispatcher · other-9999** takes #50\t\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "a take comment wakes nobody" "$(cat "$S/$TL1/wake" 2>/dev/null | wc -l)" "$before"
ok "and notes the machine" "$(jq -r .host "$R/activity/50.json")" "other-9999"
jq -c '.at = (now - 4000 | floor)' "$R/activity/50.json" >"$R/activity/50.t" && mv "$R/activity/50.t" "$R/activity/50.json"
echo '{"number":50,"title":"Remote thing","labels":{"nodes":[{"name":"ready for development"}]},"blockedBy":{"nodes":[]},"issueFieldValues":{"nodes":[]},"status":{"name":"In progress","category":{"key":"started"}}}' >"$G/queue"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "an agent of another machine quiet for an hour: stuck" "$(jq -r '.elsewhere[0] | "\(.issue) \(.state) \(.detail)"' "$R/board.json")" "50 stuck quiet 1h, on other-9999"
printf '302\t1795000000\ttester\t50\thttps://x/50#c302\t-\t**dev #50 → tech lead**\tQuale porta?\n' >"$G/repo-comments.tsv"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "its unanswered question: waiting on others" "$(jq -r '.elsewhere[0] | "\(.state) \(.detail)"' "$R/board.json")" "others waits for tech lead, on other-9999"
ok "a started issue is not workable" "$(jq -r '.queue.ready' "$R/board.json")" "0"

echo "== main-ci.sh: the merge's CI and deploy"
cd "$ROOT" || exit 1
# within <seconds> <command...>: its output once it ends, or TIMEOUT, with it stopped, when it still runs then.
# Its exit code, or TIMEOUT, goes in $T/within.code.
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
		echo TIMEOUT >"$T/within.code"
		echo TIMEOUT
		return
	fi
	wait "$wpid" 2>/dev/null
	echo $? >"$T/within.code"
	cat "$T/within.out"
}
echo '[{"id":1,"name":"ci","path":".github/workflows/ci.yml","state":"active"}]' >"$G/workflows"
printf 'name: ci\non:\n  push:\n    branches: [main]\n  pull_request:\n' >"$G/workflow-1.yml"
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"},{"status":"completed","conclusion":"success","workflowName":"deploy","url":"u2"}]' >"$G/runs"
ok "green: the change is deployed" "$(sh "$SC/main-ci.sh" 50 | cut -c1-21)" "GREEN main deadbee: t"
ok "and --wait ends on it" "$(within 10 sh "$SC/main-ci.sh" 50 --wait | cut -c1-21)" "GREEN main deadbee: t"
ok "with exit 0" "$(cat "$T/within.code")" "0"
echo '[{"status":"completed","conclusion":"failure","workflowName":"deploy","url":"https://x/run/9"},{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
out=$(sh "$SC/main-ci.sh" 50)
code=$?
ok "red: the failed runs, and whose it is to say" "$(printf '%s\n' "$out" | grep -c -e '^RED main deadbee' -e 'deploy: failure https://x/run/9' -e 'tell the tech lead')" "4"
ok "with exit 1" "$code" "1"
ok "and no bug issue opened" "$(ls "$G/comments" | grep -c 'CI')" "0"
echo '[{"status":"in_progress","conclusion":"","workflowName":"deploy","url":"u2"}]' >"$G/runs"
ok "still running" "$(sh "$SC/main-ci.sh" 50 | cut -c1-15)" "PENDING main de"
ok "a run still going at the limit of --wait: PENDING, and to run it again" "$(within 10 env MAIN_CI_WAIT=0 sh "$SC/main-ci.sh" 50 --wait)" "PENDING main deadbee: 1 run(s) still going after 0 minutes: run main-ci.sh 50 --wait again"
ok "with exit 3" "$(cat "$T/within.code")" "3"
# nap_of <pid> [<pause>]: the pid of the pause main-ci.sh <pid> takes between two looks, once it takes one other
# than <pause>; empty when it ends first.
nap_of() {
	n=0
	np=""
	while [ -z "$np" ] && kill -0 "$1" 2>/dev/null && [ "$n" -lt 100 ]; do
		np=$(pgrep -P "$1" -x sleep 2>/dev/null | grep -vx "${2:-}" | head -1)
		[ -n "$np" ] || sleep 0.1
		n=$((n + 1))
	done
	echo "$np"
}
# ended <pid>: main-ci.sh <pid> once it ends, stopped when it still runs 5 seconds on; its exit code, or "still
# running", in $code.
ended() {
	n=0
	while kill -0 "$1" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
	if kill -0 "$1" 2>/dev/null; then
		pkill -P "$1" 2>/dev/null
		kill -KILL "$1" 2>/dev/null
		wait "$1" 2>/dev/null
		code="still running"
	else
		wait "$1" 2>/dev/null
		code=$?
	fi
}
# interrupt_wait [<looks>]: main-ci.sh 50 --wait, stopped by a TERM while it waits between two looks, after
# <looks> of them (1 when not given): each pause before cut short. Its output goes in $T/main-ci.out, its exit
# code (or "still running") in $code, its last pause's pid in $spid.
interrupt_wait() {
	sh "$SC/main-ci.sh" 50 --wait >"$T/main-ci.out" 2>&1 &
	mpid=$!
	spid=$(nap_of "$mpid")
	looks=${1:-1}
	while [ "$looks" -gt 1 ] && [ -n "$spid" ]; do
		kill "$spid" 2>/dev/null
		spid=$(nap_of "$mpid" "$spid")
		looks=$((looks - 1))
	done
	kill -TERM "$mpid" 2>/dev/null
	ended "$mpid"
}
# A TERM while it waits between two looks: it says so at once, not at the end of its pause.
interrupt_wait
ok "a TERM during the wait: INTERRUPTED, and to run it again" "$(cat "$T/main-ci.out")" "INTERRUPTED main deadbee: run main-ci.sh 50 --wait again"
ok "with exit 4" "$code" "4"
sleep 0.2
ok "and its pause stopped with it" "$([ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null && echo stopped)" "stopped"
echo '[]' >"$G/runs"
ok "a workflow on push to the default branch and no run yet: it waits as today" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
# ago <seconds>: that long ago, as GitHub writes a time.
ago() { jq -nr --argjson s "$1" 'now - $s | floor | todate'; }
# A clock for main-ci.sh, with $T/clock first in its PATH: its `date +%s` runs ahead of the real one by the
# seconds in $G/clock, so a wait of minutes passes in a moment; any other date is the real one.
mkdir -p "$T/clock"
d=$(command -v date)
cat >"$T/clock/date" <<EOF
#!/bin/sh
[ "\$*" = +%s ] || exec $d "\$@"
echo \$((\$($d +%s) + \$(cat "\$G/clock" 2>/dev/null || echo 0)))
EOF
chmod +x "$T/clock/date"
# next_look: main-ci.sh $mpid's pause $spid cut short, so it looks again; its next pause's pid in $spid, empty when
# it ends instead.
next_look() {
	[ -z "$spid" ] || kill "$spid" 2>/dev/null
	spid=$(nap_of "$mpid" "$spid")
}
ago 60 >"$G/merged-at-50"
ok "merged a minute ago, no run yet: it waits" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
# A run that appears after its first look, within the 5 minutes: followed as today.
sh "$SC/main-ci.sh" 50 --wait >"$T/main-ci.out" 2>&1 &
mpid=$!
spid=$(nap_of "$mpid")
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
[ -z "$spid" ] || kill "$spid" 2>/dev/null
ended "$mpid"
ok "a run that appears within the 5 minutes: followed as today" "$code $(cut -c1-21 "$T/main-ci.out")" "0 GREEN main deadbee: t"
# The issue's repository: its only push workflow filters on tags, so no run starts for a merge.
ago 360 >"$G/merged-at-50"
echo '[]' >"$G/runs"
printf "name: int\non:\n  push:\n    tags: ['int-*']\n  workflow_dispatch:\n" >"$G/workflow-1.yml"
ok "no run of the merge commit 5 minutes after the merge: NO CI" "$(within 10 sh "$SC/main-ci.sh" 50 --wait)" "NO CI main deadbee: no workflow run started for this merge"
ok "with exit 0" "$(cat "$T/within.code")" "0"
touch "$G/runs-broken"
ok "runs that cannot be read then: it waits" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
rm -f "$G/runs-broken"
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
ok "a run of the merge commit then: followed as today" "$(within 10 sh "$SC/main-ci.sh" 50 --wait | cut -c1-21)" "GREEN main deadbee: t"
printf 'name: ci\non:\n  push:\n    branches: [main]\n  pull_request:\n' >"$G/workflow-1.yml"
rm -f "$G/merged-at-50"
echo '[]' >"$G/runs"
rm -f "$G/workflows"
ok "no workflow: NO CI at once, without waiting" "$(within 10 sh "$SC/main-ci.sh" 50 --wait)" "NO CI main deadbee: no workflow runs on main"
ok "with exit 0" "$(cat "$T/within.code")" "0"
ok "and without --wait too" "$(sh "$SC/main-ci.sh" 50)" "NO CI main deadbee: no workflow runs on main"
echo '[{"id":2,"name":"pr","path":".github/workflows/pr.yml","state":"active"},{"id":3,"name":"Dependabot Updates","path":"dynamic/dependabot/dependabot-updates","state":"active"},{"id":1,"name":"ci","path":".github/workflows/ci.yml","state":"disabled_manually"}]' >"$G/workflows"
printf 'name: pr\non: [pull_request, workflow_dispatch]\n' >"$G/workflow-2.yml"
ok "workflows on other events, a dynamic one and a disabled one on push: NO CI" "$(within 10 sh "$SC/main-ci.sh" 50 --wait)" "NO CI main deadbee: no workflow runs on main"
echo '[{"id":2,"name":"pr","path":".github/workflows/pr.yml","state":"active"},{"id":4,"name":"gone","path":".github/workflows/gone.yml","state":"active"}]' >"$G/workflows"
ok "a workflow file that cannot be read: it waits as today" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
touch "$G/workflows-broken"
ok "a workflow list that cannot be read: it waits as today" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
rm -f "$G/workflows-broken"
# A merge that landed while gh pr merge failed (merge.sh): GitHub has not marked the pull request merged yet.
touch "$G/unmarked-50"
echo "$landed" >"$G/landed-50"
echo '[{"id":1,"name":"ci","path":".github/workflows/ci.yml","state":"active"}]' >"$G/workflows"
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
ok "no mergeCommit and the head in the default branch: the merge commit by its second parent, and its CI" "$(within 10 sh "$SC/main-ci.sh" 50 --wait | cut -c1-21)" "GREEN main ${landed%"${landed#???????}"}: t"
# unmarked_merge <seconds>: a new commit merged into main that long ago, by its merge commit's date, as GitHub
# leaves it before it marks the pull request merged: the commit in head-50, the merge commit in landed-50.
unmarked_merge() {
	git -C "$T/landed" checkout -q -b "late-$1" main
	git -C "$T/landed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "late $1"
	git -C "$T/landed" rev-parse HEAD >"$G/head-50"
	git -C "$T/landed" checkout -q main
	GIT_COMMITTER_DATE="$(($(date +%s) - $1)) +0000" git -C "$T/landed" -c user.email=t@t -c user.name=t merge -q --no-ff -m "Merge pull request #50" "late-$1"
	git -C "$T/landed" push -q origin main
	git -C "$T/landed" rev-parse HEAD >"$G/landed-50"
}
echo '[]' >"$G/runs"
unmarked_merge 0
ok "no mergeCommit, merged just now and no run yet: it waits" "$(within 2 sh "$SC/main-ci.sh" 50 --wait)" "TIMEOUT"
unmarked_merge 360
m=$(cat "$G/landed-50")
ok "no mergeCommit and no run 5 minutes after its merge commit's date: NO CI" "$(within 10 sh "$SC/main-ci.sh" 50 --wait)" "NO CI main ${m%"${m#???????}"}: no workflow run started for this merge"
echo abc1234567 >"$G/head-50"
ok "no mergeCommit and the head not in it: not merged, as today" "$(sh "$SC/main-ci.sh" 50)" "#50 is not merged"
echo "$reviewed" >"$G/head-50"
rm -f "$G/unmarked-50" "$G/landed-50" "$G/workflows"

echo "== main-ci.sh: a pull request merged into another branch than the default one"
# A release branch on origin, one commit ahead of main, so its newest commit is not main's.
git -C "$T/landed" checkout -q -b release
git -C "$T/landed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m release
git -C "$T/landed" push -q origin release
rtip=$(git -C "$T/landed" rev-parse HEAD)
echo release >"$G/base-50"
echo '[{"id":1,"name":"ci","path":".github/workflows/ci.yml","state":"active"}]' >"$G/workflows"
printf 'name: ci\non:\n  push:\n    branches: [release]\n' >"$G/workflow-1-release.yml"
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
ok "green: the line names the branch it merged into" "$(sh "$SC/main-ci.sh" 50 | cut -c1-24)" "GREEN release deadbee: t"
echo '[{"status":"completed","conclusion":"failure","workflowName":"deploy","url":"https://x/run/9"}]' >"$G/runs"
ok "red too" "$(sh "$SC/main-ci.sh" 50 | head -1)" "RED release deadbee (the merge of #50, or a newer commit holding it)"
echo '[{"status":"in_progress","conclusion":"","workflowName":"deploy","url":"u2"}]' >"$G/runs"
ok "and pending" "$(sh "$SC/main-ci.sh" 50)" "PENDING release deadbee: 1 run(s) still going"
# main's workflow file runs on a push, the release branch's does not.
printf 'name: ci\non: [pull_request]\n' >"$G/workflow-1-release.yml"
ok "the workflow files as that branch has them: NO CI on it" "$(within 10 sh "$SC/main-ci.sh" 50 --wait)" "NO CI release deadbee: no workflow runs on release"
printf 'name: ci\non:\n  push:\n    branches: [release]\n' >"$G/workflow-1-release.yml"
touch "$G/superseded-50"
interrupt_wait
ok "every run cancelled: it follows the newest commit of that branch" "$(cat "$T/main-ci.out")" "INTERRUPTED release ${rtip%"${rtip#???????}"}: run main-ci.sh 50 --wait again"
# The merge commit has runs, the newest commit none yet: its 5 minutes start when it is followed, not at the merge.
ago 360 >"$G/merged-at-50"
interrupt_wait 2
ok "and 5 minutes after the merge, the newest commit just followed with no run yet: it waits for it" "$(cat "$T/main-ci.out")" "INTERRUPTED release ${rtip%"${rtip#???????}"}: run main-ci.sh 50 --wait again"
# Its 5 minutes over, on the clock: none will start for it.
PATH="$T/clock:$PATH" sh "$SC/main-ci.sh" 50 --wait >"$T/main-ci.out" 2>&1 &
mpid=$!
spid=$(nap_of "$mpid")
echo 301 >"$G/clock"
next_look
ended "$mpid"
ok "the newest commit with no run 5 minutes after it is followed: NO CI, and why" "$code $(cat "$T/main-ci.out")" "0 NO CI release ${rtip%"${rtip#???????}"}: the merge's runs were cancelled and the newest commit started none"
rm -f "$G/superseded-50" "$G/merged-at-50" "$G/clock"
# Every run of the merge commit cancelled 43 minutes on: the newest commit's 5 minutes end past the 45 of the wait.
echo '[{"status":"in_progress","conclusion":"","workflowName":"ci","url":"u1"}]' >"$G/runs"
PATH="$T/clock:$PATH" sh "$SC/main-ci.sh" 50 --wait >"$T/main-ci.out" 2>&1 &
mpid=$!
spid=$(nap_of "$mpid")
echo 2580 >"$G/clock"
touch "$G/superseded-50"
next_look
next_look
echo 2760 >"$G/clock"
next_look
ok "cancelled 43 minutes on, no run of the newest commit at 46: it waits past the limit" "$([ -n "$spid" ] && echo waiting || cat "$T/main-ci.out")" "waiting"
echo 2881 >"$G/clock"
next_look
ended "$mpid"
ok "and once that commit's 5 minutes are over: NO CI, not PENDING" "$code $(cat "$T/main-ci.out")" "0 NO CI release ${rtip%"${rtip#???????}"}: the merge's runs were cancelled and the newest commit started none"
rm -f "$G/superseded-50" "$G/clock"
# Past the 45 minutes, a push cancels every run of the commit it follows: the even newer one gets its 5 minutes.
PATH="$T/clock:$PATH" sh "$SC/main-ci.sh" 50 --wait >"$T/main-ci.out" 2>&1 &
mpid=$!
spid=$(nap_of "$mpid")
echo 2580 >"$G/clock"
touch "$G/superseded-50"
next_look
next_look
git -C "$T/landed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "release 2"
git -C "$T/landed" push -q origin release
rtip2=$(git -C "$T/landed" rev-parse HEAD)
touch "$G/cancelled-$rtip"
echo 2820 >"$G/clock"
next_look
echo 2940 >"$G/clock"
next_look
ok "cancelled again at 47 minutes, no run of the newer commit at 49: it waits on" "$([ -n "$spid" ] && echo waiting || cat "$T/main-ci.out")" "waiting"
echo 3121 >"$G/clock"
next_look
ended "$mpid"
ok "and once its own 5 minutes are over: NO CI for it" "$code $(cat "$T/main-ci.out")" "0 NO CI release ${rtip2%"${rtip2#???????}"}: the merge's runs were cancelled and the newest commit started none"
rm -f "$G/superseded-50" "$G/clock" "$G/cancelled-$rtip"
# A merge into the release branch GitHub has not marked yet: the head is in that branch only, not in main.
git -C "$T/landed" checkout -q -b side main
git -C "$T/landed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m side
side=$(git -C "$T/landed" rev-parse HEAD)
git -C "$T/landed" checkout -q release
git -C "$T/landed" -c user.email=t@t -c user.name=t merge -q --no-ff -m "Merge pull request #50" side
git -C "$T/landed" push -q origin release
rlanded=$(git -C "$T/landed" rev-parse HEAD)
touch "$G/unmarked-50"
echo "$side" >"$G/head-50"
echo "$rlanded" >"$G/landed-50"
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
ok "no mergeCommit: the merge commit on that branch, by its second parent" "$(within 10 sh "$SC/main-ci.sh" 50 --wait | cut -c1-24)" "GREEN release ${rlanded%"${rlanded#???????}"}: t"
rm -f "$G/unmarked-50" "$G/landed-50"
echo "$reviewed" >"$G/head-50"
touch "$G/base-broken"
ok "a base branch that cannot be read: the default branch" "$(sh "$SC/main-ci.sh" 50 | cut -c1-21)" "GREEN main deadbee: t"
rm -f "$G/base-broken" "$G/base-50" "$G/workflows" "$G/workflow-1-release.yml"

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
# reports: the issues opened with the label flow-report, one number per line.
reports() { grep -l 'labels=flow-report' "$G/issues/"*.meta 2>/dev/null | sed 's#.*/##; s#\.meta$##'; }
plugin=$(jq -r .repository "$W/.claude-plugin/plugin.json" | sed -E 's#^https?://github\.com/##; s#\.git$##')
echo "first" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "A wake for nothing" >/dev/null
echo "second" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "A wake for nothing" >/dev/null
rep=$(reports | head -1)
ok "one issue" "$(reports | wc -l)" "1"
ok "opened through the REST API on the plugin's repository, with its title" "$(grep -c "^api repos/$plugin/issues -f title=A wake for nothing -f labels\\[\\]=flow-report " "$G/rest.log") $(cat "$G/issues/$rep.title")" "1 A wake for nothing"
ok "its body signed" "$(head -1 "$G/issues/$rep.body") $(tail -1 "$G/issues/$rep.body")" "first <!-- team · tech lead -->"
ok "and one comment on it, with the second report" "$(ls "$G/comments" | grep -c "^$rep\.") $(cat "$G/comments/$rep".* 2>/dev/null | head -1)" "1 second"
ok "through the REST API" "$(grep -c "^api repos/$plugin/issues/$rep/comments " "$G/rest.log")" "1"
echo "third" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "a WAKE for nothing" >/dev/null
ok "the title compared without case" "$(reports | wc -l) $(ls "$G/comments" | grep -c "^$rep\.")" "1 2"
echo "Board shows a wrong color" >"$G/report-pr"
echo "fourth" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "Board shows a wrong color" >/dev/null
ok "a pull request with the title is no report: a new issue" "$(reports | wc -l) $(ls "$G/comments" | grep -c '^900\.')" "2 0"
echo other >"$G/plugin-labels"
out=$(echo "fifth" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/report.sh" "A missing label")
ok "a missing label is created first, through the REST API; the new issue's link printed" "$(tail -1 "$G/labels-created") $(printf '%s' "$out" | grep -c "^https://github.com/$plugin/issues/[0-9]*$")" "flow-report d73a4a 1"
rm -f "$G/plugin-labels"

echo "== rest.sh: a write GitHub fails for a moment is tried again"
cd "$ROOT" || exit 1
: >"$G/rest.log"
echo "gh: Server Error (HTTP 502)" >"$G/fail-next"
out=$(printf 'una nota lunga\n' | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/note.sh" 42 2>"$T/rest.err"); code=$?
last=$(ls -t "$G/comments" | head -1)
ok "a first 5xx answer is tried again, and the second try posts it" "$code $(wc -l <"$G/rest.log") $(head -1 "$G/comments/$last")" "0 2 una nota lunga"
ok "the same body both times, and only the link printed" "$(cut -d' ' -f2 "$G/rest.log" | sort -u) $out $(cat "$T/rest.err")" "repos/test/repo/issues/42/comments https://github.com/test/repo/issues/42#issuecomment-${last#42.} "
: >"$G/rest.log"
printf '%s\n' "error connecting to api.github.com" 'Post "https://api.github.com/repos/test/repo/issues/42/comments": dial tcp: connect: connection refused' >"$G/fail-next"
echo "Ci sei?" | CLAUDE_CODE_SESSION_ID=$DEV sh "$SC/comment.sh" 42 "tech lead" --fyi >/dev/null 2>&1; code=$?
ok "a connection that fails is tried again too, 3 tries in all" "$code $(wc -l <"$G/rest.log") $(head -1 "$G/comments/$(ls -t "$G/comments" | head -1)")" "0 3 **dev #42 → tech lead** · fyi"
: >"$G/rest.log"
echo "gh: Validation Failed (HTTP 422)" >"$G/fail-next"
out=$(printf 'x\n' | sh "$SC/note.sh" 42 2>"$T/rest.err"); code=$?
ok "a 4xx answer is not tried again: it fails with the error" "$code $(wc -l <"$G/rest.log") [$out] $(cat "$T/rest.err")" "1 1 [] gh: Validation Failed (HTTP 422)"
# The waits as they are outside the tests, with a sleep that only writes down how long it was asked to wait.
mkdir -p "$T/sleepy"
printf '#!/bin/sh\necho "$1" >>"$TT/slept"\n' >"$T/sleepy/sleep"
chmod +x "$T/sleepy/sleep"
: >"$G/rest.log"
printf '%s\n' "gh: Server Error (HTTP 500)" "gh: HTTP 502" "gh: Service Unavailable (HTTP 503)" >"$G/fail-next"
out=$(printf 'x\n' | REST_WAITS="" PATH="$T/sleepy:$PATH" sh "$SC/note.sh" 42 2>"$T/rest.err"); code=$?
ok "three 5xx answers: 3 tries, 5 and 15 seconds apart, then it fails with the last error" "$code $(wc -l <"$G/rest.log") $(tr '\n' ' ' <"$T/slept")[$out] $(cat "$T/rest.err")" "1 3 5 15 [] gh: Service Unavailable (HTTP 503)"
rm -f "$G/fail-next"

echo "== ready.sh: the label through the REST API"
echo 1 >"$G/decided-42"
: >"$G/rest.log"
sh "$SC/ready.sh" 42 >/dev/null; code=$?
ok "the missing label is created with its color, then added" "$code $(grep '^ready for development ' "$G/labels-created") $(grep -c '^42 ready for development$' "$G/labels-added")" "0 ready for development 0E8A16 1"
out=$(sh "$SC/ready.sh" --remove 42 2>&1); code=$?
ok "taken back: removed by its name, encoded" "$code $(grep -c '^42 ready for development$' "$G/labels-added") $(tail -1 "$G/rest.log")" "0 0 api -X DELETE repos/test/repo/issues/42/labels/ready%20for%20development"
out=$(sh "$SC/ready.sh" --remove 42 2>&1); code=$?
ok "an issue without the label is already in the backlog" "$code $out" "0 issue 42: back to the backlog"
echo "gh: Not Found (HTTP 404)" >"$G/fail-next"
out=$(sh "$SC/ready.sh" --remove 42 2>&1); code=$?
ok "any other refusal fails with its error" "$code $out" "1 gh: Not Found (HTTP 404)"
sh "$SC/ready.sh" 42 >/dev/null
out=$(sh "$SC/ready.sh" 42 --remove 2>&1); code=$?
ok "--remove after the issue number takes the label away too" "$code $(grep -c '^42 ready for development$' "$G/labels-added") $out" "0 0 issue 42: back to the backlog"
: >"$G/rest.log"
out=$(sh "$SC/ready.sh" 42 extra 2>&1); code=$?
ok "an argument it does not expect: its usage, and nothing changes" "$code $(printf '%s' "$out" | grep -c '^usage: ready.sh') $(wc -l <"$G/rest.log") $(grep -c '^42 ready for development$' "$G/labels-added")" "2 1 0 0"
rm -f "$G/decided-42" "$G/fail-next"

echo "== block.sh"
out=$(sh "$SC/block.sh" 42 43 extra 2>&1); code=$?
ok "an argument it does not expect: its usage, and no relationship changes" "$code $(printf '%s' "$out" | grep -c '^usage: block.sh') $(cat "$G/blocks" 2>/dev/null | wc -l)" "2 1 0"

echo "== open-issue.sh: a new issue through the REST API"
url=$(printf 'Il corpo\n' | sh "$SC/open-issue.sh" "Un nuovo tema" @me); code=$?
n=${url##*/}
ok "opened in this repository, assigned to the team's account, its link printed" "$code $url $(cat "$G/issues/$n.meta")" "0 https://github.com/test/repo/issues/$n repo=test/repo labels= assignees=tester"
ok "with its title and body" "$(cat "$G/issues/$n.title") / $(cat "$G/issues/$n.body")" "Un nuovo tema / Il corpo"
url=$(printf 'Altro\n' | sh "$SC/open-issue.sh" "Per un altro" someone)
ok "or to the login given" "$(sed 's/.*assignees=//' "$G/issues/${url##*/}.meta")" "someone"

echo "== update.sh"
cd "$ROOT" || exit 1
# 9.9.9 published: the update installs it on the team's account. No session runs a version that reloads it by
# itself: one recorded 0.5.7, the others none, as when an older version started them. Each one restarts.
release 9.9.9
echo "$T/config 9.9.9" >"$T/publish"
echo 0.5.7 >"$S/$DEV2/version"
date +%s >"$S/$TL1/alive"
date +%s >"$S/$DEV2/alive"
date +%s >"$S/$NEW/alive"
# A developer that ran done.sh just now (the dispatcher removes it 2 minutes after), alive, between turns for a
# minute, on a version too old to reload: its work is over, the update leaves it alone.
DONE61=77777777-0000-0000-0000-000000000061
mkdir -p "$S/$DONE61"
echo dev >"$S/$DONE61/role"
jq -n --argjson now "$(date +%s)" '{role: "dev", repo: "test/repo", name: "repo · dev #61 · in review · Title 61", issue: 61, state: "done", detail: "merged #61", since: $now}' >"$S/$DONE61/status"
echo "$T/config" >"$S/$DONE61/config"
echo "$ROOT" >"$S/$DONE61/cwd"
echo 0.5.7 >"$S/$DONE61/version"
date +%s >"$S/$DONE61/alive"
echo $(($(date +%s) - 60)) >"$S/$DONE61/idle"
sh "$SC/dispatcher.sh" start >/dev/null 2>&1
old_pid=$(cat "$R/dispatcher.pid")
: >"$T/claude.log"
# Two live sessions with an `idle` file: the first listed in a turn (its `idle` empty, its transcript
# untouched for an hour) until the second has restarted, then between turns; the second between turns for a
# minute, its transcript touched again and again as while it waits, until it restarts. The tech lead, listed
# before them, started the update and has no `idle` file, as with a version that did not write it: its
# transcript touched until the first one has restarted. The toucher notes when the sessions' step starts (the
# dispatchers' line, the last before it) and when each session restarts.
mkdir -p "$T/config/projects/repo"
touch -d '1 hour ago' "$T/config/projects/repo/$DEV2.jsonl"
: >"$S/$DEV2/idle"
echo $(($(date +%s) - 60)) >"$S/$NEW/idle"
rm -f "$S/$TL1/idle"
: >"$T/update.out"
(
	n=0
	until grep -q -- "--resume $TL1 " "$T/claude.log" || [ "$n" -ge 400 ]; do
		[ -s "$T/step3-at" ] || ! grep -q '^dispatcher test_repo: ' "$T/update.out" || date +%s >"$T/step3-at"
		if [ ! -s "$T/new-at" ]; then
			touch "$T/config/projects/repo/$NEW.jsonl"
			if grep -q -- "--resume $NEW " "$T/claude.log"; then
				date +%s >"$T/new-at"
				date +%s >"$S/$DEV2/idle"
			fi
		fi
		if [ ! -s "$T/dev2-at" ]; then
			touch "$T/config/projects/repo/$TL1.jsonl"
			! grep -q -- "--resume $DEV2 " "$T/claude.log" || date +%s >"$T/dev2-at"
		fi
		sleep 0.2
		n=$((n + 1))
	done
	! grep -q -- "--resume $TL1 " "$T/claude.log" || date +%s >"$T/tl1-at"
) &
busy=$!
CLAUDE_CODE_SESSION_ID=$TL1 UPDATE_TRANSCRIPT_QUIET=2 UPDATE_GONE=1 sh "$SC/update.sh" run >"$T/update.out" 2>&1
wait "$busy"
busy=""
first=no
[ -s "$T/new-at" ] && [ -s "$T/step3-at" ] && [ $(($(cat "$T/new-at") - $(cat "$T/step3-at"))) -lt 10 ] && first=yes
ok "a session between turns restarts in the first pass, though its transcript keeps changing" "$first" "yes"
ok "one on a version too old to reload restarts as one with none recorded" "$(grep -c -- "--bg --resume $DEV2 The team plugin was updated to 9.9.9 " "$T/claude.log")" "1"
ok "one in a turn waits for the next pass, though its transcript is an hour old" "$(grep -o -e "--resume $DEV2 " -e "--resume $NEW " "$T/claude.log" | cut -d' ' -f2 | tr '\n' ' ')" "$NEW $DEV2 "
fallback=no
[ -s "$T/tl1-at" ] && [ -s "$T/dev2-at" ] && [ $(($(cat "$T/tl1-at") - $(cat "$T/dev2-at"))) -ge 5 ] && [ $(($(cat "$T/tl1-at") - $(cat "$T/dev2-at"))) -lt 20 ] && fallback=yes
ok "one with no idle file waits for its transcript to stay unchanged, then restarts the pass after" "$fallback" "yes"
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
ok "a done session is neither stopped nor restarted, and has no line" "$(grep -c -e "--resume $DONE61" -e "^stop ${DONE61%%-*}" "$T/claude.log") $(grep -c 'dev #61' "$T/update.out") $(st "$DONE61" state)" "0 0 done"
ok "and the update says it is done" "$(tail -1 "$T/update.out" | cut -c21-)" "update done"
rm -rf "${S:?}/$DONE61"

echo "== update.sh: a second run right after the first restarts nothing"
pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
date +%s >"$S/$TL1/alive"
date +%s >"$S/$DEV2/alive"
date +%s >"$S/$NEW/alive"
: >"$T/claude.log"
CLAUDE_CODE_SESSION_ID=$TL1 UPDATE_QUIET=0 UPDATE_GONE=1 sh "$SC/update.sh" run >"$T/update.out" 2>&1
ok "the plugin is updated on each account, and none gets a new version" "$(grep -c 'plugin update team@team' "$T/claude.log") $(grep -c 'is already at the latest version$' "$T/update.out")" "2 2"
ok "nothing to update" "$(grep -c '^nothing to update$' "$T/update.out")" "1"
ok "no session restarts" "$(grep -c -- '--resume' "$T/claude.log")" "0"
ok "nor the dispatcher" "$(cat "$R/dispatcher.pid" 2>/dev/null) $(grep -c '^dispatcher ' "$T/update.out")" "$pid 0"
ok "and the update says it is done" "$(tail -1 "$T/update.out" | cut -c21-)" "update done"

echo "== update.sh: a new version on one account: the session behind it reloads it, and none restarts"
# The default account has 9.9.9 too, and 9.9.10 is published there alone. Its session runs 9.9.9; the team's
# account stays on 9.9.9, where its sessions, restarted by the first run, and the dispatcher run it already.
# The session behind reloads it by itself (hooks/sessions.tsx): its `version` reaches 9.9.10 a few seconds in.
ACC=55555555-0000-0000-0000-000000000045
mkdir -p "$T/home/.claude/plugins/cache/team/team" "$S/$ACC"
ln -s "$T/releases/9.9.9" "$T/home/.claude/plugins/cache/team/team/9.9.9"
release 9.9.10
echo "$T/home/.claude 9.9.10" >>"$T/publish"
echo dev >"$S/$ACC/role"
echo '{"role":"dev","repo":"test/repo","name":"repo · dev #45 · in progress · Title 45","issue":45,"state":"working"}' >"$S/$ACC/status"
echo >"$S/$ACC/config"
echo "$ROOT" >"$S/$ACC/cwd"
for id in $TL1 $DEV2 $NEW $ACC; do
	date +%s >"$S/$id/alive"
	echo 9.9.9 >"$S/$id/version"
done
ok "the dispatcher runs 9.9.9" "$(cat "$R/dispatcher.version")" "9.9.9"
pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
: >"$T/claude.log"
(
	sleep 3
	echo 9.9.10 >"$S/$ACC/version"
) &
reloader=$!
CLAUDE_CODE_SESSION_ID=$TL1 UPDATE_QUIET=0 UPDATE_GONE=1 sh "$SC/update.sh" run >"$T/update.out" 2>&1
wait "$reloader"
ok "the default account gets 9.9.10" "$(grep -c '^account .*/home/.claude: Plugin "team" updated to 9.9.10$' "$T/update.out")" "1"
ok "no session restarts" "$(grep -c -e '--resume' -e '^stop ' "$T/claude.log")" "0"
ok "the update waits for the session behind to reach 9.9.10, and says so" "$(grep -c '^repo · dev #45 · in progress · Title 45: now on 9.9.10$' "$T/update.out")" "1"
ok "every session already on its account's newest version is left alone, with its line" "$(grep ': already on 9.9.9$' "$T/update.out" | grep -v '^dispatcher ' | cut -d: -f1 | sort | tr '\n' '|')" "repo · dev #43 · in progress · Title 43|repo · dev #44 · in review · Title 44|repo · tech lead|"
ok "and so is the dispatcher" "$(cat "$R/dispatcher.pid" 2>/dev/null) $(grep '^dispatcher ' "$T/update.out")" "$pid dispatcher test_repo: already on 9.9.9"
ok "and the update says it is done" "$(tail -1 "$T/update.out" | cut -c21-)" "update done"

echo "== update.sh: a new version on the team's account restarts the dispatcher, and no session"
# 9.9.11 published on the team's account, where the dispatcher and the sessions run 9.9.9. The two developers
# reload it by themselves: one as soon as it is installed, before the update looks at the sessions, the other
# a few seconds in; the tech lead, which started the update, reloads like them but has not when the update
# stops waiting.
release 9.9.11
echo "$T/config 9.9.11" >>"$T/publish"
echo "$S/$DEV2 9.9.11" >"$T/reloads"
for id in $TL1 $DEV2 $NEW $ACC; do date +%s >"$S/$id/alive"; done
# The dispatcher running on 9.9.9 is a stand-in that never cycles: a real one hands over to 9.9.11 by itself at its
# next cycle (scripts/dispatcher.sh), and one that came between the install and step 2 would leave the update
# nothing to restart. The first update.sh section restarts a real one. Detached, so its end needs nobody to reap it.
sh "$SC/dispatcher.sh" stop >/dev/null
rm -f "$R/dispatcher.stopped"
pid=$(sh -c 'sleep 300 >/dev/null 2>&1 & echo $!')
echo "$pid" >"$R/dispatcher.pid"
echo 9.9.9 >"$R/dispatcher.version"
: >"$T/claude.log"
(
	sleep 3
	echo 9.9.11 >"$S/$NEW/version"
) &
reloader=$!
CLAUDE_CODE_SESSION_ID=$TL1 UPDATE_QUIET=0 UPDATE_GONE=1 UPDATE_WAIT=5 sh "$SC/update.sh" run >"$T/update.out" 2>&1
wait "$reloader"
new_pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
ok "the dispatcher restarts on 9.9.11" "$([ -n "$new_pid" ] && [ "$new_pid" != "$pid" ] && echo yes || echo no) $(grep -c '^dispatcher test_repo: the dispatcher of test/repo runs' "$T/update.out") $(cat "$R/dispatcher.version")" "yes 1 9.9.11"
ok "no session restarts, the one that started the update neither" "$(grep -c -e '--resume' -e '^stop ' "$T/claude.log")" "0"
ok "each session that reached 9.9.11 has its line, the one that reloaded before the update looked at it too" "$(grep ': now on 9.9.11$' "$T/update.out" | cut -d: -f1 | sort | tr '\n' '|') $(grep -c ': already on 9.9.11$' "$T/update.out")" "repo · dev #43 · in progress · Title 43|repo · dev #44 · in review · Title 44| 0"
ok "the one on another account, already on its newest, is left alone" "$(grep -c '^repo · dev #45 · in progress · Title 45: already on 9.9.10$' "$T/update.out")" "1"
ok "one still behind when the update stops waiting is reported, last" "$(tail -2 "$T/update.out" | head -1)" "repo · tech lead: still behind after 0 minutes, on 9.9.9"
ok "and the update says it is done" "$(tail -1 "$T/update.out" | cut -c21-)" "update done"
sh "$SC/dispatcher.sh" stop >/dev/null
rm -rf "${S:?}/$ACC" "$T/home/.claude/plugins"
rm -f "$S/$TL1/version" "$S/$DEV2/version" "$S/$NEW/version" "$T/config/plugins/cache/team/team/9.9.11"
: >"$T/publish"
: >"$T/reloads"

echo "== update.sh: started by an older version, the newest one restarts the sessions"
# An older version, whose restart prompt lacks a sentence of the newer one's.
CACHE="$T/config/plugins/cache/team/team"
release 0.0.1
OLD="$T/releases/0.0.1"
sentence='Commands you started in the background before the restart'
sed "s/ $sentence.*do not start them again\.//" "$W/scripts/update.sh" >"$OLD/scripts/update.sh"
ok "the older version's prompt lacks the sentence" "$(grep -c "$sentence" "$OLD/scripts/update.sh")" "0"
# The older version alone installed, by this run: it is the newest, it goes on by itself.
rm "$CACHE/9.9.9"
echo "$T/config 0.0.1" >"$T/publish"
date +%s >"$S/$TL1/alive"
: >"$T/claude.log"
UPDATE_QUIET=0 UPDATE_TRANSCRIPT_QUIET=0 UPDATE_GONE=1 sh "$OLD/scripts/update.sh" run >"$T/update.out" 2>&1
ok "the newest version installed hands over to nobody" "$(grep -c '^continuing with team' "$T/update.out") $(grep -c -- "--bg --resume $TL1 The team plugin was updated to 0.0.1 " "$T/claude.log")" "0 1"
ok "and restarts with its own prompt" "$(grep -- "--bg --resume $TL1 " "$T/claude.log" | grep -c "$sentence")" "0"
# 9.9.9 published too: the older version updates the plugin, then 9.9.9 goes on.
echo "$T/config 9.9.9" >>"$T/publish"
date +%s >"$S/$TL1/alive"
date +%s >"$S/$DEV2/alive"
: >"$T/claude.log"
CLAUDE_CODE_SESSION_ID=$TL1 UPDATE_QUIET=0 UPDATE_TRANSCRIPT_QUIET=0 UPDATE_GONE=1 sh "$OLD/scripts/update.sh" run >"$T/update.out" 2>&1
ok "the log notes the hand-over" "$(grep -c '^continuing with team 9.9.9$' "$T/update.out")" "1"
ok "the restarted sessions get the newer prompt" "$(grep -- "--bg --resume $TL1 The team plugin was updated to 9.9.9 " "$T/claude.log" | grep -c "$sentence") $(grep -- "--bg --resume $DEV2 The team plugin was updated to 9.9.9 " "$T/claude.log" | grep -c "$sentence")" "1 1"
ok "the plugin is updated once on each account" "$(grep -c 'plugin update team@team' "$T/claude.log")" "2"
ok "the one that started the update restarts last" "$(grep -- '--bg --resume' "$T/claude.log" | tail -1 | cut -d' ' -f3)" "$TL1"
ok "and the log says once that the update starts, and that it is done" "$(grep -c 'update starts$' "$T/update.out") $(tail -1 "$T/update.out" | cut -c21-)" "1 update done"

echo "== update.sh restart: a session whose reload failed restarts, in the background, its lines in the update's log"
# A developer on a version that reloads by itself, behind 9.9.9: its reload failed, and its module runs this.
ulog="$T/state/team/update.log"
echo "an earlier update's line" >"$ulog"
echo 9.9.8 >"$S/$DEV2/version"
echo $(($(date +%s) - 60)) >"$S/$DEV2/idle"
: >"$T/claude.log"
out=$(UPDATE_QUIET=0 UPDATE_GONE=1 sh "$SC/update.sh" restart "$DEV2" 2>&1)
code=$?
ok "it answers at once, with nothing to say" "$code [$out]" "0 []"
n=0
until grep -q ': backgrounded' "$ulog" || [ "$n" -ge 100 ]; do
	sleep 0.1
	n=$((n + 1))
done
ok "that session alone restarts" "$(grep -o -e "--resume [^ ]* " "$T/claude.log" | cut -d' ' -f2 | tr '\n' ' ')" "$DEV2 "
ok "on the newest version installed, with the restart's prompt" "$(grep -c -- "--bg --resume $DEV2 The team plugin was updated to 9.9.9 and this session was restarted to load it. Its scripts are now in [^ ]*/scripts" "$T/claude.log")" "1"
ok "the update's log says so, after what it held" "$(head -1 "$ulog") | $(grep -c ' repo · dev #43 · in progress · Title 43: its reload failed, it restarts$' "$ulog") | $(grep -c '^repo · dev #43 · in progress · Title 43: backgrounded' "$ulog")" "an earlier update's line | 1 | 1"
# Rolled back from 9.9.11 to 9.9.9: Claude Code left 9.9.11's folder behind, marked .orphaned_at.
ln -s "$T/releases/9.9.11" "$CACHE/9.9.11"
date +%s >"$CACHE/9.9.11/.orphaned_at"
: >"$T/claude.log"
UPDATE_QUIET=0 UPDATE_GONE=1 sh "$SC/update.sh" restart "$DEV2" --now >/dev/null 2>&1
ok "a newer folder marked .orphaned_at is not installed: the restart is on the newest one without the mark" "$(grep -c -- "--bg --resume $DEV2 The team plugin was updated to 9.9.9 and this session was restarted to load it. Its scripts are now in $CACHE/9.9.9/scripts:" "$T/claude.log") $(grep -c '9\.9\.11' "$T/claude.log")" "1 0"
rm -f "$CACHE/9.9.11/.orphaned_at" "$CACHE/9.9.11"
rm -f "$S/$DEV2/version"

echo "== dispatcher.sh: a newer version installed on its account takes over"
cd "$ROOT" || exit 1
# 0.0.1 and 9.9.9 installed on the team's account. One started from 0.0.1, as by a session still on it while an
# update runs, goes on with 9.9.9 at its first cycle; 9.9.9, the newest, keeps running.
: >"$R/dispatcher.log"
rm -f "$R/board.json"
out=$(sh "$CACHE/0.0.1/scripts/dispatcher.sh" start 2>&1)
code=$?
pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
ok "started from 0.0.1, it runs 9.9.9's loop from its first cycle" "$code $out | $(ps -o args= -p "$pid" 2>/dev/null)" "0 the dispatcher of test/repo runs on this machine (pid $pid, team 9.9.9) | sh $CACHE/9.9.9/scripts/dispatcher.sh run"
ok "its log says so, once" "$(grep -c ' now on team 9.9.9$' "$R/dispatcher.log") $(grep -c 'now on team' "$R/dispatcher.log")" "1 1"
ok "and 0.0.1's has left" "$(pgrep -fc "$CACHE/0.0.1/scripts/dispatcher.sh run")" "0"
n=0
while [ ! -f "$R/board.json" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
ok "with no newer version, it keeps running after its cycle" "$([ -f "$R/board.json" ] && echo yes || echo no) $(cat "$R/dispatcher.pid" 2>/dev/null) $(kill -0 "$pid" 2>/dev/null && echo alive || echo gone) $(grep -c 'now on team' "$R/dispatcher.log")" "yes $pid alive 1"
sh "$SC/dispatcher.sh" stop >/dev/null
# A stop by hand as an older one hands over: the newer one it started leaves at once.
timeout 20 sh "$CACHE/9.9.9/scripts/dispatcher.sh" run >>"$R/dispatcher.log" 2>&1 </dev/null
code=$?
ok "a stopped dispatcher stays stopped" "$code $(pgrep -fc "$CACHE/9.9.9/scripts/dispatcher.sh run") $(sh "$SC/dispatcher.sh" status)" "0 0 stopped (by hand)"
# Rolled back from 9.9.20 to 9.9.9: Claude Code left 9.9.20's folder behind, marked .orphaned_at. One started from
# 0.0.1 goes on with 9.9.9, which stays.
release 9.9.20
ln -s "$T/releases/9.9.20" "$CACHE/9.9.20"
date +%s >"$CACHE/9.9.20/.orphaned_at"
: >"$R/dispatcher.log"
rm -f "$R/board.json"
out=$(sh "$CACHE/0.0.1/scripts/dispatcher.sh" start 2>&1)
pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
n=0
while [ ! -f "$R/board.json" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
ok "a newer folder marked .orphaned_at is not installed: started from 0.0.1, it goes on with 9.9.9 and stays there" "$out | $(ps -o args= -p "$pid" 2>/dev/null) | $(cat "$R/dispatcher.pid" 2>/dev/null) $(grep -c 'now on team' "$R/dispatcher.log") $(grep -c 'now on team 9.9.20' "$R/dispatcher.log")" "the dispatcher of test/repo runs on this machine (pid $pid, team 9.9.9) | sh $CACHE/9.9.9/scripts/dispatcher.sh run | $pid 1 0"
sh "$SC/dispatcher.sh" stop >/dev/null
rm -f "$CACHE/9.9.20/.orphaned_at" "$CACHE/9.9.20"
# The newest installed, 9.9.30, has a manifest with no version: its own loop never hands over to its own folder,
# so it does not start itself again and again.
release 9.9.30
echo '{"name": "team"}' >"$T/releases/9.9.30/.claude-plugin/plugin.json"
ln -s "$T/releases/9.9.30" "$CACHE/9.9.30"
: >"$R/dispatcher.log"
rm -f "$R/board.json"
sh "$CACHE/9.9.30/scripts/dispatcher.sh" start >/dev/null 2>&1
pid=$(cat "$R/dispatcher.pid" 2>/dev/null)
n=0
while [ ! -f "$R/board.json" ] && [ "$n" -lt 30 ]; do sleep 1; n=$((n + 1)); done
ok "one that cannot read its own version stays on its folder and runs its cycle" "$([ -f "$R/board.json" ] && echo yes || echo no) $(cat "$R/dispatcher.pid" 2>/dev/null) $(kill -0 "$pid" 2>/dev/null && echo alive || echo gone) $(grep -c 'now on team' "$R/dispatcher.log") $(pgrep -fc "$CACHE/9.9.30/scripts/dispatcher.sh run")" "yes $pid alive 0 1"
sh "$SC/dispatcher.sh" stop >/dev/null
rm -f "$CACHE/9.9.30"

echo "== update.sh: a session that holds the main checkout restarts only once it has given it back"
# 9.9.12 published on the team's account. The developer, too old to reload by itself and between turns, holds
# the main checkout, testing there; the other live sessions run 9.9.12 already. It gives the checkout back once
# the update's first pass has looked at every session (the last one listed has its line).
release 9.9.12
echo "$T/config 9.9.12" >>"$T/publish"
for id in $TL1 $NEW; do echo 9.9.12 >"$S/$id/version"; done
for id in $TL1 $DEV2 $NEW; do date +%s >"$S/$id/alive"; done
echo $(($(date +%s) - 60)) >"$S/$DEV2/idle"
cd "$ROOT/.claude/worktrees/43-other" || exit 1
CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" take >/dev/null; code=$?
ok "the developer holds the checkout" "$code $(sed -n 1p "$R/checkout")" "0 $DEV2"
cd "$ROOT" || exit 1
: >"$T/claude.log"
: >"$T/update.out"
(
	n=0
	until grep -q '^repo · dev #44 · [^:]*: [a-z]* on 9.9.12$' "$T/update.out" || [ "$n" -ge 300 ]; do
		sleep 0.1
		n=$((n + 1))
	done
	grep -c -- "--resume $DEV2 " "$T/claude.log" >"$T/held-restarts"
	cd "$ROOT/.claude/worktrees/43-other" && CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" give >/dev/null
) &
giver=$!
UPDATE_QUIET=0 UPDATE_GONE=1 sh "$SC/update.sh" run >"$T/update.out" 2>&1
wait "$giver"
ok "while it holds the checkout it does not restart" "$(cat "$T/held-restarts")" "0"
ok "once it has given it back it restarts, on the new version" "$(grep -o -e "--resume [^ ]* " "$T/claude.log" | cut -d' ' -f2 | tr '\n' ' ') $(grep -c -- "--bg --resume $DEV2 The team plugin was updated to 9.9.12 " "$T/claude.log")" "$DEV2  1"
ok "and the update says it is done" "$(tail -1 "$T/update.out" | cut -c21-)" "update done"

echo "== update.sh restart: one still holding the checkout when the update stops waiting is left on its version"
cd "$ROOT/.claude/worktrees/43-other" || exit 1
date +%s >"$S/$DEV2/alive"
CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" take >/dev/null
cd "$ROOT" || exit 1
: >"$T/claude.log"
out=$(UPDATE_QUIET=0 UPDATE_GONE=1 UPDATE_WAIT=3 sh "$SC/update.sh" restart "$DEV2" --now 2>&1)
ok "it does not restart" "$(grep -c -e '--resume' -e '^stop ' "$T/claude.log")" "0"
ok "and the log says it still holds the checkout" "$(printf '%s\n' "$out" | tail -1)" "repo · dev #43 · in progress · Title 43: still holds the checkout after 0 minutes, left on its version"
cd "$ROOT/.claude/worktrees/43-other" && CLAUDE_CODE_SESSION_ID=$DEV2 sh "$SC/checkout.sh" give >/dev/null
cd "$ROOT" || exit 1
rm -f "$S/$TL1/version" "$S/$NEW/version"

echo "== a fork's checkout: the remote of the repository gh resolves, whatever its name"
cd "$ROOT" || exit 1
# origin is another repository (the one a fork comes from); test/repo, the one gh resolves, is the remote fork.
mkdir -p "$T/upstream"
git init -q --bare -b main "$T/upstream/repo.git"
git -C "$ROOT" remote set-url origin "$T/upstream/repo.git"
git -C "$ROOT" fetch -q --prune origin
git -C "$ROOT" remote add fork "$T/test/repo.git"
# Every form of a remote's URL names test/repo, whatever its host and case (repo_of_url): that remote is the one.
for url in git@github.com:test/repo.git ssh://git@github.com/test/repo.git https://github.com/test/repo \
	https://github.com/test/repo.git/ github-work:test/repo.git git@github.com:Test/Repo.git; do
	git -C "$ROOT" remote set-url fork "$url"
	ok "a remote at $url: the repository's" "$(scripts=$SC && . "$SC/repo.sh" && repo_remote 2>&1)" "fork"
done
git -C "$ROOT" remote set-url fork "$T/test/repo.git"
# commit_on <ref>: a new commit on top of the fork's <ref>, pushed there from another clone, so the main
# checkout knows nothing of it until it fetches.
commit_on() {
	c=$(git -C "$T/landed" -c user.email=t@t -c user.name=t commit-tree -p "$1" -m "on the fork" "$1^{tree}")
	git -C "$T/landed" push -q origin "$c:refs/heads/$2"
	echo "$c"
}
forked=$(commit_on main 80-fork-thing)
FRK=88888888-0000-0000-0000-000000000080
cat >"$T/agents.json" <<EOF
[{"id":"abcd1234","sessionId":"$FRK","name":"repo · dev #80","status":"running","state":"working"}]
EOF
out=$(sh "$SC/start-dev.sh" 80 2>&1); code=$?
ok "start-dev.sh fetches the issue's branch from that remote" "$code $(git -C "$WT/80-fork-thing" rev-parse HEAD 2>/dev/null)" "0 $forked"
ok "and the worktree's branch follows it there" "$(git -C "$WT/80-fork-thing" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" "fork/80-fork-thing"
date +%s >"$S/$FRK/alive"
pushed=$(commit_on "$forked" 80-fork-thing)
cd "$WT/80-fork-thing" || exit 1
CLAUDE_CODE_SESSION_ID=$FRK sh "$SC/checkout.sh" take >/dev/null 2>&1; code=$?
ok "checkout.sh take puts the main checkout on the branch as that remote has it" "$code $(git -C "$ROOT" rev-parse HEAD)" "0 $pushed"
newmain=$(git -C "$T/landed" rev-parse main)
newmain=$(commit_on "$newmain" main)
CLAUDE_CODE_SESSION_ID=$FRK sh "$SC/checkout.sh" give >/dev/null 2>&1; code=$?
ok "and give pulls the default branch from it" "$code $(git -C "$ROOT" rev-parse --abbrev-ref HEAD) $(git -C "$ROOT" rev-parse HEAD)" "0 main $newmain"
cd "$ROOT" || exit 1
touch "$G/unmarked-50"
echo "$landed" >"$G/landed-50"
echo '[{"id":1,"name":"ci","path":".github/workflows/ci.yml","state":"active"}]' >"$G/workflows"
echo '[{"status":"completed","conclusion":"success","workflowName":"ci","url":"u1"}]' >"$G/runs"
ok "main-ci.sh finds a merge GitHub has not marked in the default branch as that remote has it" "$(sh "$SC/main-ci.sh" 50 | cut -c1-21)" "GREEN main ${landed%"${landed#???????}"}: t"
ok "the remote's name is written for the hooks module" "$(cat "$R/remote")" "fork"
rm -f "$R/ci" "$G/ci-commit"
sh "$SC/dispatch.sh" >/dev/null 2>&1
ok "the board's CI is the default branch's newest commit on that remote" "$(cat "$G/ci-commit" 2>/dev/null)" "$newmain"
# The code review and the QA find the branch pushed there, and their briefs read it from there.
cd "$WT/80-fork-thing" || exit 1
CLAUDE_CODE_SESSION_ID=$FRK sh "$SC/review.sh" request 80 >/dev/null 2>&1; code=$?
ok "review.sh request finds the branch's head on that remote" "$code $(cut -f1,2 "$R/review/80")" "0 requested${tab}$pushed"
cd "$ROOT" || exit 1
REV=99999999-0000-0000-0000-000000000080
echo "[{\"id\":\"abcd1234\",\"sessionId\":\"$REV\",\"status\":\"running\",\"state\":\"working\"}]" >"$T/agents.json"
: >"$T/claude.log"
sh "$SC/start-review.sh" 80 >/dev/null 2>&1; code=$?
ok "the reviewer's brief reads the change from that remote" "$code $(grep -cF "git fetch -q fork main 80-fork-thing\`, then \`git diff fork/main...$pushed\`" "$T/claude.log") $(grep -c '{{REMOTE}}' "$T/claude.log")" "0 1 0"
CLAUDE_CODE_SESSION_ID=$REV sh "$SC/review.sh" pass 80 "reads the fork" >/dev/null
cd "$WT/80-fork-thing" || exit 1
CLAUDE_CODE_SESSION_ID=$FRK sh "$SC/qa.sh" request 80 >/dev/null 2>&1; code=$?
ok "qa.sh request too" "$code $(cut -f1,2 "$R/qa/80")" "0 requested${tab}$pushed"
cd "$ROOT" || exit 1
QAF=77777777-0000-0000-0000-000000000080
echo "[{\"id\":\"abcd1234\",\"sessionId\":\"$QAF\",\"status\":\"running\",\"state\":\"working\"}]" >"$T/agents.json"
: >"$T/claude.log"
sh "$SC/start-qa.sh" 80 >/dev/null 2>&1; code=$?
ok "and the QA agent's brief" "$code $(grep -cF 'git fetch -q fork main 80-fork-thing`, then `git diff fork/main...fork/80-fork-thing`' "$T/claude.log") $(grep -c '{{REMOTE}}' "$T/claude.log")" "0 1 0"
echo '[{"id":"abcd1234","sessionId":"abcd1234-0000-0000-0000-000000000002","status":"running","state":"working"}]' >"$T/agents.json"
: >"$T/claude.log"
echo "Da dove si legge?" | CLAUDE_CODE_SESSION_ID=$TL1 sh "$SC/spike.sh" "fork remote" 1 >/dev/null 2>&1 &
spk=$!
n=0
while ! grep -q -- '--bg' "$T/claude.log" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
kill "$spk" 2>/dev/null
spk=""
ok "and a spike's brief" "$(grep -cF 'First run `git fetch -q fork main`, so `fork/main` is' "$T/claude.log") $(grep -c '{{REMOTE}}' "$T/claude.log")" "1 0"
# No remote points to test/repo any more.
git -C "$ROOT" remote remove fork
missing="no git remote of $ROOT points to test/repo, the repository gh works on here: add it with git -C $ROOT remote add test https://github.com/test/repo.git, then run this again"
before=$(ls "$G/comments" | wc -l)
out=$(sh "$SC/start-dev.sh" 81 2>&1); code=$?
ok "with no remote on it, start-dev.sh stops, saying which repository and how to add the remote" "$code | $out" "1 | $missing"
ok "before claiming the issue" "$(ls "$G/comments" | grep -c '^81\.') $(ls "$G/comments" | wc -l)" "0 $before"
cd "$WT/80-fork-thing" || exit 1
out=$(CLAUDE_CODE_SESSION_ID=$FRK sh "$SC/checkout.sh" take 2>&1); code=$?
ok "checkout.sh take stops too, before holding the checkout" "$code $(held) | $out" "1 free | $missing"
# take --as-is fetches nothing, and give works without the remote too: a checkout taken as-is is never left locked.
out=$(CLAUDE_CODE_SESSION_ID=$FRK sh "$SC/checkout.sh" take --as-is 2>&1); code=$?
ok "checkout.sh take --as-is holds it all the same" "$code $(held) $(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" "0 held main"
out=$(CLAUDE_CODE_SESSION_ID=$FRK sh "$SC/checkout.sh" give 2>&1); code=$?
ok "and give gives it back, on the default branch, with nothing to pull from" "$code $(held) $(git -C "$ROOT" rev-parse --abbrev-ref HEAD) | $out" "0 free main | given back: the checkout is on main"
ok "and the giver is back in its worktree" "$(st "$FRK" place) | $(st "$FRK" detail)" "worktree 80 | gave the checkout back"
cd "$ROOT" || exit 1
out=$(sh "$SC/main-ci.sh" 50 2>&1); code=$?
ok "and main-ci.sh" "$code | $out" "1 | $missing"
cd "$WT/80-fork-thing" || exit 1
out=$(CLAUDE_CODE_SESSION_ID=$FRK sh "$SC/review.sh" request 80 2>&1); code=$?
ok "and review.sh request" "$code | $out" "1 | $missing"
cd "$ROOT" || exit 1
ok "and the hooks module's remote is gone" "$([ -f "$R/remote" ] && echo kept || echo gone)" "gone"
rm -f "$G/unmarked-50" "$G/landed-50" "$G/workflows" "$G/runs"
git -C "$ROOT" remote set-url origin "$T/test/repo.git"

echo "== no write through GitHub's GraphQL API where REST has an endpoint"
ok "no gh issue comment, issue create, issue edit or label create" "$(cat "$G/unhandled" 2>/dev/null | grep -c -E '^(issue (comment|create|edit)|label create) ')" "0"

echo
[ ! -f "$G/unhandled" ] || { echo "unhandled gh calls:"; sort -u "$G/unhandled"; }
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
