#!/bin/sh
# Checks hooks/guard.py on the commands the old guard refused by mistake, and on ones it must refuse, for a
# tech lead and a spike of a fake repository in a temporary folder, removed when the run ends.
#   sh tests/guard.sh    (from anywhere; prints its failures, ends with passed=<n> failed=<n>, non-zero on a failure)
set -u
P=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$T/home/.config"
# Nothing of the machine's own: its home and git configuration stay out.
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1
R="$T/repo"
git init -q -b main "$R" || exit 1
# A sibling repository, outside the fake one: there a spike may only read.
S="$T/sibling"
git init -q -b main "$S" || exit 1
pass=0 fail=0
check() {
	want=$1 role=$2 cmd=$3
	if printf '%s' "$cmd" | python3 -I "$P/hooks/guard.py" "$role" test/repo "$R" "$R" "$P" >"$T/out" 2>&1; then got=allow; else got=deny; fi
	if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL ($want, got $got: $(cat "$T/out")): $cmd" | cut -c1-220; fi
}
# Refused by mistake before.
check allow tech-lead 'git merge-base --is-ancestor community/main origin/x && echo yes || echo no'
check allow tech-lead "grep -n -i \"gh pr merge\\|--merge\" $T/merge.sh"
check allow tech-lead "sh $P/scripts/rules.sh add \"linear history: rebase, no merge commit, push with force-with-lease\""
check allow tech-lead "gh issue comment 3 --body \"the run to follow; git push was cancelled\" && sh $P/scripts/comment.sh 3 dev --fyi <<'EOF'
git push --force and git merge are mentioned here only
EOF"
check allow tech-lead "sed -i \"s/a/b/\" $T/jobs/x/tmp/watch.sh"
check allow tech-lead "cat >> ~/.local/share/team/notes/x/a.md <<'EOF'
- merged #1, git push done
EOF"
# Must be refused.
check deny tech-lead 'git commit -am "x"'
check deny tech-lead 'cd sub && git push origin HEAD'
check deny tech-lead 'git checkout -b feature'
check deny tech-lead 'gh pr merge 12 --merge'
check deny tech-lead 'claude --bg --name x "do it"'
check deny tech-lead "sed -i 's/a/b/' $R/README.md"
check deny tech-lead 'gh search issues foo'
# Another repository: a tech lead reads its issues and pull requests and writes issues and comments there,
# whichever way the repository is named; never its code, pull requests, releases or settings.
check allow tech-lead 'gh issue view 3 -R someone/else'
check allow tech-lead 'gh issue view 3 --repo someone/else --comments'
check allow tech-lead 'gh issue list --repo=someone/else --state open'
check allow tech-lead 'gh issue -R someone/else view 3'
check allow tech-lead 'gh issue view https://github.com/someone/else/issues/3 --comments'
check allow tech-lead 'GH_REPO=someone/else gh issue view 3'
check allow tech-lead 'gh pr view 5 -R someone/else --json files'
check allow tech-lead 'gh pr list -R someone/else'
check allow tech-lead 'gh pr diff https://github.com/someone/else/pull/5'
check allow tech-lead "gh issue comment 3 -R someone/else --body-file - <<'EOF'
a question
EOF"
check allow tech-lead "gh issue create -R someone/else --title 'x' --body-file - <<'EOF'
what must become true
EOF"
check allow tech-lead 'gh issue edit 3 -R someone/else --add-label bug'
check allow tech-lead 'gh pr comment 5 -R someone/else --body "a note"'
check allow tech-lead 'gh issue comment 3 --body "see https://github.com/someone/else/issues/9"'
check allow tech-lead 'gh api repos/someone/else/issues'
check allow tech-lead 'gh api --paginate "repos/someone/else/issues/3/comments?per_page=100"'
check allow tech-lead 'gh api repos/someone/else/pulls/5/files'
check allow tech-lead 'gh api -X GET repos/someone/else/pulls -f state=open'
check allow tech-lead 'gh api repos/someone/else/issues -f title=x -f body=y'
check allow tech-lead 'gh api repos/someone/else/issues/3/comments -f body=x'
check allow tech-lead 'gh api -X PATCH repos/someone/else/issues/comments/9 -f body=x'
check allow tech-lead 'gh api repos/test/repo/issues/3/comments -f body="moved to https://github.com/someone/else/issues/9"'
check allow tech-lead "sh $P/scripts/comment.sh 3 'tech lead' --repo someone/else <<'EOF'
a question
EOF"
check allow tech-lead "sh $P/scripts/note.sh 3 --repo someone/else <<'EOF'
found
EOF"
check allow tech-lead "sh $P/scripts/open-issue.sh 'x' @me --repo someone/else <<'EOF'
what must become true
EOF"
check allow tech-lead "sh $P/scripts/tell.sh someone/else info <<'EOF'
news
EOF"
# The plugin's scripts never reach another repository by a link, an API path or GH_REPO: only by their --repo.
check deny tech-lead "sh $P/scripts/note.sh https://github.com/someone/else/issues/5 <<'EOF'
## Technical decisions
EOF"
check deny tech-lead "sh $P/scripts/comment.sh https://github.com/someone/else/issues/5 'tech lead' <<'EOF'
x
EOF"
check deny tech-lead "sh $P/scripts/ready.sh https://github.com/someone/else/issues/5"
check deny tech-lead "GH_REPO=someone/else sh $P/scripts/note.sh 5"
check deny tech-lead "sh $P/scripts/note.sh 5 repos/someone/else/issues/5"
check deny spike "sh $P/scripts/note.sh https://github.com/someone/else/issues/5"
check deny tech-lead 'gh pr create -R someone/else --title x --body y'
check deny tech-lead 'gh pr merge 5 -R someone/else --merge'
check deny tech-lead 'gh pr -R someone/else merge 5'
check deny tech-lead 'gh pr merge https://github.com/someone/else/pull/5'
check deny tech-lead 'gh pr review 5 -R someone/else --approve'
check deny tech-lead 'gh pr close 5 -R someone/else'
check deny tech-lead 'gh pr checkout 5 -R someone/else'
check deny tech-lead 'gh issue close 3 -R someone/else'
check deny tech-lead 'gh issue develop 3 -R someone/else'
check deny tech-lead 'gh release create v1 -R someone/else'
check deny tech-lead 'GH_REPO=someone/else gh release create v1'
check deny tech-lead 'gh label create x -R someone/else'
check deny tech-lead 'gh workflow run deploy -R someone/else'
check deny tech-lead 'gh run list -R someone/else'
check deny tech-lead 'gh api -X PUT repos/someone/else/pulls/5/merge'
check deny tech-lead 'gh api repos/someone/else/pulls -f title=x -f head=y -f base=main'
check deny tech-lead 'gh api repos/someone/else/pulls/5/reviews -f event=APPROVE'
check deny tech-lead 'gh api -X PATCH repos/someone/else/pulls/5 -f state=closed'
check deny tech-lead 'gh api repos/someone/else/git/refs -f ref=refs/heads/x -f sha=abc'
check deny tech-lead 'gh api repos/someone/else/contents/README.md'
check deny tech-lead 'gh api repos/someone/else'
check deny tech-lead 'gh api -X DELETE repos/someone/else/issues/comments/1'
# PATCH on an issue can close it, or a pull request: there it edits a comment only.
check deny tech-lead 'gh api -X PATCH repos/someone/else/issues/3 -f title=x'
check deny tech-lead 'gh api -X PATCH repos/someone/else/issues/5 -f state=closed'
# GitHub takes a POST on an issue as a PATCH.
check deny tech-lead 'gh api repos/someone/else/issues/5 -f state=closed'
check deny tech-lead 'gh api -X POST repos/someone/else/issues/5 -f state=closed'
check deny tech-lead 'gh api -iXPOST repos/someone/else/issues/5/ -f state=closed'
check allow tech-lead 'gh api repos/someone/else/issues/5/labels -f "labels[]=bug"'
check deny tech-lead 'gh api -X PATCH repos/someone/else/issues/comments/9/reactions -f content=x'
check deny tech-lead 'gh api https://api.github.com/repos/someone/else/pulls -f title=x'
check deny tech-lead 'GH_REPO=someone/else gh api repos/{owner}/{repo}/issues'
check deny tech-lead 'export GH_REPO=someone/else; gh release create v1'
check deny tech-lead 'declare -x GH_REPO=someone/else && gh repo view'
check allow tech-lead 'export GH_REPO=test/repo; gh issue view 3'
# gh api's short options stack: -iXPUT is -i and -X PUT, -if is -i and -f.
check deny tech-lead 'gh api -iXPUT repos/someone/else/pulls/5/merge'
check deny tech-lead 'gh api -iX PUT repos/someone/else/pulls/5/merge'
check deny tech-lead 'gh api -XPUT repos/someone/else/pulls/5/merge'
check deny tech-lead 'gh api --method=PUT repos/someone/else/pulls/5/merge'
check deny tech-lead 'gh api repos/someone/else/pulls -if title=x -if head=y -if base=main'
check deny tech-lead 'gh api repos/someone/else/pulls/5/reviews -iF event=APPROVE'
check deny tech-lead 'gh api --method PUT repos/someone/else/pulls/5/merge'
# An option's value in the next word is that option's, never read as one: -q -XGET is a jq filter.
check deny tech-lead 'gh api -X PUT repos/someone/else/pulls/5/merge -q -XGET'
check deny tech-lead 'gh api -X PUT repos/someone/else/pulls/5/merge --jq -XGET'
check deny tech-lead 'gh api -XPUT repos/someone/else/pulls/5/merge -t -XGET'
check deny tech-lead 'gh api --method PUT repos/someone/else/pulls/5/merge --preview -XGET'
check allow tech-lead 'gh api -H "Accept: application/vnd.github.diff" repos/someone/else/pulls/5'
check allow tech-lead 'gh api -i repos/someone/else/pulls/5'
check allow tech-lead 'gh api repos/someone/else/issues -if title=x'
check allow tech-lead 'gh api -iXPATCH repos/someone/else/issues/comments/9 -f body=x'
check deny tech-lead 'curl -s https://api.github.com/repos/someone/else/issues'
check deny tech-lead 'git clone https://github.com/someone/else'
check deny tech-lead 'git push https://github.com/someone/else HEAD:main'
check deny tech-lead "cd $S && git push origin HEAD"
check deny tech-lead "git -C $S commit -am x"
# What a substitution inside an allowed command runs gets no exception.
check deny tech-lead 'gh issue comment 3 -R someone/else --body "$(gh api -X PUT repos/someone/else/pulls/5/merge)"'
check deny tech-lead 'gh issue comment 3 --body "$(gh api -X PUT repos/someone/else/pulls/5/merge)"'
check deny tech-lead 'gh issue view 3 -R someone/else `gh pr merge 5 -R someone/else`'
check deny tech-lead 'gh issue create -R someone/else --title x --body-file <(gh api -X PUT repos/someone/else/pulls/5/merge)'
check deny tech-lead 'gh api repos/someone/else/issues -f body="$(gh api -X PUT repos/someone/else/pulls/5/merge)"'
check allow tech-lead 'echo $(gh api repos/someone/else/issues/3 --jq .title)'
# On another repository POST creates an issue, or adds to one its comments, labels and assignees, or edits a
# comment; nothing else, whatever form the path takes.
check deny tech-lead 'gh api repos/someone/else/issues/$N -f state=closed'
check deny tech-lead 'gh api repos/someone/else/issues/%35 -f state=closed'
check deny tech-lead 'gh api repos/someone/else/issues/5.json --input -'
check deny tech-lead 'gh api repos/someone/else/issues/5/lock -f lock_reason=resolved'
check deny tech-lead 'gh api repos/someone/else/issues/%35/comments -f body=x'
check allow tech-lead 'gh api repos/someone/else/issues/5/assignees -f "assignees[]=a"'
check allow tech-lead 'gh api -X POST repos/someone/else/issues/comments/9 -f body=x'
# Another repository's API only as the guard reads it plainly.
check deny tech-lead "gh api -X PUT 'https://api.github.com:443/repos/someone/else/pulls/5/merge'"
check deny tech-lead 'gh api -X PUT ./repos/someone/else/pulls/5/merge'
check deny tech-lead "gh api -X PUT 'repos/test/repo/../../repos/someone/else/pulls/5/merge'"
check deny tech-lead "gh api -X PUT 'repos/someone/else/issues/../pulls/5/merge'"
check deny tech-lead "gh api 'repos/someone/else/issues/./5' -f state=closed"
check allow tech-lead 'gh api https://api.github.com/repos/someone/else/issues/3'
check allow tech-lead 'gh api /repos/someone/else/issues/3'
check allow tech-lead 'gh api "repos/someone/else/issues?state=open&per_page=100"'
# A repository reached by its id: whose it is the guard cannot tell.
check deny tech-lead 'gh api -X PUT repositories/123/pulls/5/merge'
check deny tech-lead 'gh api repositories/123/issues/5'
check deny tech-lead 'curl -s https://api.github.com/repositories/123/issues'
check deny spike 'gh api repositories/123'
# GraphQL: queries typed by hand pass, mutations and what the guard cannot read do not; the scripts run theirs.
check allow tech-lead "gh api graphql -f query='{ viewer { login } }'"
check allow tech-lead "gh api graphql -F owner=a -f query='query(\$owner: String!) { repository(owner: \$owner, name: \"b\") { issue(number: 1) { title } } }'"
check allow spike "gh api graphql -f query='{ viewer { login } }'"
check deny tech-lead "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
check deny spike "gh api graphql -f query='mutation { closeIssue(input: {issueId: \"x\"}) { clientMutationId } }'"
check deny tech-lead "gh api https://api.github.com/graphql -f query='mutation { x }'"
check deny tech-lead 'gh api graphql -F query=@m.graphql'
check deny tech-lead "gh api graphql -F query=@- <<'EOF'
mutation { x }
EOF"
check deny tech-lead 'gh api graphql -f query="$Q"'
check deny tech-lead 'gh api graphql -f query="query Q { viewer { login } } $M" -f operationName=M'
check deny tech-lead 'gh api graphql -f query="$(cat m.graphql)"'
check deny tech-lead 'gh api graphql --input body.json'
check deny tech-lead "gh api 'graphql?x=1' -F query=@m.graphql"
check deny tech-lead "gh api 'graphql#x' -F query=@m.graphql"
check deny tech-lead "gh api /graphql/ -f query='mutation { x }'"
check allow tech-lead "gh api 'graphql?x=1' -f query='{ viewer { login } }'"
check deny tech-lead "curl -s -X POST https://api.github.com/graphql -d '{\"query\": \"mutation { x }\"}'"
check allow tech-lead "sh $P/scripts/block.sh 5 3"
# gh repo: a tech lead or a spike views or clones a repository, any one, and changes none, this one included.
check allow tech-lead 'gh repo view'
check allow tech-lead 'gh repo view someone/else --json description'
check allow tech-lead 'gh repo view https://github.com/someone/else'
check allow tech-lead "gh repo clone someone/else $T/clone"
check allow tech-lead 'gh repo clone https://github.com/someone/else'
check allow tech-lead 'gh repo gitignore view Go'
check allow tech-lead 'gh repo license view MIT'
check deny tech-lead 'gh repo edit someone/else --visibility private'
check deny tech-lead 'gh repo edit --description x'
check deny tech-lead 'gh repo delete someone/else --yes'
check deny tech-lead 'gh repo rename other-name --yes'
check deny tech-lead 'gh repo archive someone/else --yes'
check deny tech-lead 'gh repo unarchive someone/else --yes'
check deny tech-lead 'gh repo create x --public'
check deny tech-lead 'gh repo fork someone/else'
check deny tech-lead 'gh repo sync'
check deny tech-lead 'gh repo set-default someone/else'
check deny tech-lead 'gh repo deploy-key add key.pub'
check deny tech-lead 'gh repo autolink create JIRA- https://x/'
check allow spike 'gh repo view'
check allow spike 'gh repo view https://github.com/someone/else'
check allow spike 'gh repo clone someone/else'
check allow spike 'gh repo license view MIT'
check deny spike 'gh repo delete someone/else --yes'
check deny spike 'gh repo edit --description x'
check deny spike 'gh repo create x --public'
check deny spike 'gh repo fork someone/else'
check deny tech-lead "gh repo view \"\$(gh api -X PUT repos/someone/else/pulls/5/merge)\""
# In another repository's checkout gh takes the repository from the folder: judged as if it came with -R.
check allow tech-lead "cd $S && gh issue view 3"
check allow tech-lead "cd $S && gh pr diff 5"
check allow tech-lead "cd $S && gh repo view"
check allow tech-lead "cd $S && gh api repos/someone/else/issues/3"
check allow tech-lead "cd $S && git log --oneline -3"
check deny tech-lead "cd $S && gh issue close 3"
check deny tech-lead "cd $S && gh release create v1"
check deny tech-lead "cd $S && gh pr merge 5"
check deny tech-lead "cd $S && gh api -X PUT 'repos/{owner}/{repo}/pulls/5/merge'"
check deny tech-lead "cd $S && gh api 'repos/{owner}/{repo}/issues/3'"
check deny tech-lead "cd $S && sh $P/scripts/ready.sh 5"
check deny spike "cd $S && gh issue view 3"
check allow spike "cd $S && gh repo view"
check allow tech-lead "gh api 'repos/{owner}/{repo}/issues/3'"
check deny tech-lead "cd $S && gh api -X PUT repos/:owner/:repo/pulls/5/merge"
check deny spike "cd $S && gh api repos/:owner/:repo/issues/3 -f state=closed"
# The folder gh and git run in, however it is reached: cd, pushd, env -C, GIT_DIR or GIT_WORK_TREE.
check deny tech-lead "pushd $S && gh issue close 3"
check deny tech-lead "pushd $S && sh $P/scripts/ready.sh 5"
check allow tech-lead "pushd $S && popd && gh issue close 3"
check deny tech-lead "env -C $S gh issue close 3"
check deny tech-lead "env --chdir=$S gh release create v1"
check allow tech-lead "env -C $S gh issue view 3"
check allow tech-lead "env -C $S git log --oneline -1"
check deny tech-lead "GIT_DIR=$S/.git gh issue close 3"
check deny tech-lead "GIT_DIR=$S/.git git checkout main"
check deny tech-lead "GIT_WORK_TREE=$S git checkout main"
check allow tech-lead "git checkout main"
check deny tech-lead "env -i -C $S gh issue close 3"
check deny tech-lead "export GIT_DIR=$S/.git; gh issue close 3"
check allow tech-lead "GIT_DIR=$R/.git git log --oneline -1"
# A repository held in a shell variable counts as another one: only what passes there passes.
check deny tech-lead 'R=someone/else; gh release create v1 -R "$R"'
check deny tech-lead 'gh issue close 3 -R $R'
check deny tech-lead 'GH_REPO=$R gh release create v1'
check deny tech-lead "GH_REPO=\$R sh $P/scripts/note.sh 5"
check deny tech-lead 'gh api -X PUT "repos/$R/pulls/5/merge"'
check deny tech-lead 'gh api "repos/$R/issues/3"'
check deny tech-lead 'curl -s "https://api.github.com/repos/$R/issues"'
check deny tech-lead 'gh api "repos/test/repo/actions/runs/$ID"'
check deny tech-lead 'gh api "repos/test/repo/issues/$N" -f state=closed'
check allow tech-lead 'gh issue comment 3 -R "$R" --body x'
check allow tech-lead 'gh api "repos/test/repo/issues/$N"'
check deny spike 'gh issue comment 3 -R $R --body x'
# An alias hides the command the guard would judge.
check deny tech-lead "gh alias set m 'pr merge 5 -R someone/else'"
check deny spike "gh alias import aliases.yml"
check allow tech-lead 'gh alias list'
# A spike only reads, and still not another repository through GitHub.
check deny spike 'gh issue view 3 -R someone/else'
check deny spike 'gh api repos/someone/else/issues'
check deny spike 'gh issue comment 3 -R someone/else --body x'
check deny spike 'git switch main'
check deny spike "sh $P/scripts/start-dev.sh 12"
check allow spike 'git show origin/main:README.md | head'
check allow tech-lead "sh $P/scripts/start-dev.sh 12"
# A dependency bot's pull request: the tech lead merges it through merge-bot.sh, never with gh pr merge by hand;
# a spike does not merge.
check allow tech-lead "sh $P/scripts/merge-bot.sh 12"
check allow tech-lead "sh $P/scripts/merge-bot.sh 12 --squash"
check deny tech-lead 'gh pr merge 12 --squash --match-head-commit abc1234'
check deny spike "sh $P/scripts/merge-bot.sh 12"
check deny tech-lead "sh -c 'git push origin HEAD'"
check deny tech-lead 'eval git commit -m x'
check allow tech-lead "bash -c 'git log --oneline -3'"
check deny tech-lead 'cat <<< hello
git push'
# git symbolic-ref only reads with one argument; with two, or --delete, it changes the repository.
check allow spike "git -C $S symbolic-ref refs/remotes/origin/HEAD"
check allow spike "git -C $S symbolic-ref --short refs/remotes/origin/HEAD"
check allow spike "git -C $S symbolic-ref -q HEAD"
check allow spike "git -C $S symbolic-ref -q --short HEAD"
check allow spike "git -C $S symbolic-ref --quiet HEAD"
check allow spike "cd $S && git symbolic-ref HEAD"
check deny spike "git -C $S symbolic-ref HEAD refs/heads/x"
check deny spike "cd $S && git symbolic-ref HEAD refs/heads/x"
check deny spike "git -C $S symbolic-ref --delete refs/remotes/origin/HEAD"
check deny spike "git -C $S symbolic-ref -d refs/remotes/origin/HEAD"
check deny spike "git -C $S symbolic-ref -m why HEAD refs/heads/x"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
