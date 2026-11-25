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
check allow tech-lead 'gh api -X PATCH repos/someone/else/issues/3 -f title=x'
check allow tech-lead 'gh api repos/test/repo/issues/3/comments -f body="moved to https://github.com/someone/else/issues/9"'
check allow tech-lead "sh $P/scripts/comment.sh 3 'tech lead' --repo someone/else <<'EOF'
a question
EOF"
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
check deny tech-lead 'gh api https://api.github.com/repos/someone/else/pulls -f title=x'
check deny tech-lead 'GH_REPO=someone/else gh api repos/{owner}/{repo}/issues'
check deny tech-lead 'curl -s https://api.github.com/repos/someone/else/issues'
check deny tech-lead 'git clone https://github.com/someone/else'
check deny tech-lead 'git push https://github.com/someone/else HEAD:main'
check deny tech-lead "cd $S && git push origin HEAD"
check deny tech-lead "git -C $S commit -am x"
# A spike only reads, and still not another repository through GitHub.
check deny spike 'gh issue view 3 -R someone/else'
check deny spike 'gh api repos/someone/else/issues'
check deny spike 'gh issue comment 3 -R someone/else --body x'
check deny spike 'git switch main'
check deny spike "sh $P/scripts/start-dev.sh 12"
check allow spike 'git show origin/main:README.md | head'
check allow tech-lead "sh $P/scripts/start-dev.sh 12"
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
