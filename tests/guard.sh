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
# The session's scratch folder, outside the repository; UNKNOWN_DIR is a variable the session does not know.
export CLAUDE_JOB_DIR="$T/jobs/x"
unset UNKNOWN_DIR
R="$T/repo"
git init -q -b main "$R" || exit 1
mkdir -p "$R/sub"
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
check deny tech-lead 'gh issue view 3 -R someone/else'
check deny tech-lead 'gh api repos/someone/else/issues'
check deny tech-lead 'gh search issues foo'
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
# The API rule: repos/<owner>/<name> counts only in the words of gh api and in a curl or wget URL to
# api.github.com, whatever the method; a local path or a quoted string that holds it calls nothing.
check allow tech-lead 'tail -1 ~/.local/state/team/repos/test_repo/dispatcher.log'
check allow tech-lead 'tail -5 ~/.local/state/team/repos/someone_else/dispatcher.log'
check allow spike 'cat ~/.local/state/team/repos/test_repo/review/42'
check allow tech-lead 'gh issue comment 3 --body "see repos/a/b"'
check allow tech-lead 'gh issue comment 3 --body "it ran gh api repos/a/b by hand"'
check allow tech-lead 'gh issue comment 3 --body "it ran \`gh api repos/a/b\` by hand"'
check allow tech-lead 'gh api repos/test/repo/issues/3 --jq .title'
check allow tech-lead 'gh api -X POST repos/test/repo/issues -f title=x -f body="see repos/a/b"'
check allow tech-lead "gh api graphql -f query='mutation { addComment(input: {subjectId: \"x\", body: \"y\"}) { clientMutationId } }'"
check allow tech-lead 'gh api "repos/{owner}/{repo}/pulls?state=open"'
check deny tech-lead 'gh api -X POST repos/someone/else/issues'
check deny tech-lead 'gh api /repos/someone/else/issues'
check deny tech-lead 'gh api --paginate "repos/someone/else/issues?per_page=100"'
check deny tech-lead 'gh api https://api.github.com/repos/someone/else/issues'
check deny tech-lead 'env GH_TOKEN=x gh api repos/Someone/Else/issues'
check deny spike 'gh api repos/someone/else/contents/README.md'
check deny tech-lead 'body=$(gh api repos/someone/else/issues/1 --jq .body)'
check deny tech-lead 'echo "$(gh api repos/someone/else/issues/1 --jq ".labels[] | select(.name)")"'
check deny tech-lead 'echo `gh api repos/someone/else/issues`'
check deny tech-lead "sh -c 'gh api repos/someone/else/issues'"
# A substitution the shell runs counts, quoted or not; one inside single quotes is text.
check allow tech-lead "gh issue comment 3 --body 'it ran \`gh api repos/a/b\` by hand'"
check allow tech-lead "gh issue comment 3 --body 'see \$(gh api repos/a/b) here'"
check deny tech-lead "body=\$(gh api 'repos/someone/else/issues/1')"
check deny tech-lead "echo \"\$(gh api 'repos/someone/else/issues')\""
# gh api, curl or wget after another command that runs it.
check deny tech-lead 'timeout 10 gh api repos/someone/else/issues'
check deny tech-lead 'command gh api repos/someone/else/issues'
check deny tech-lead 'nice -n 5 gh api repos/someone/else/issues'
check deny tech-lead 'echo 1 | xargs -I{} gh api repos/someone/else/issues/{}'
check deny tech-lead 'timeout 5 curl -s https://api.github.com/repos/someone/else/issues'
check allow tech-lead 'curl -s https://api.github.com/repos/test/repo/issues'
check deny tech-lead 'curl -s -X POST https://api.github.com/repos/someone/else/issues -d "{}"'
check deny tech-lead 'wget -qO- api.github.com/repos/someone/else/issues'
check allow tech-lead 'curl -s https://example.com/repos/a/b'
check deny tech-lead 'curl -s https://API.github.com/repos/someone/else/issues'
check allow tech-lead 'curl -s https://API.github.com/repos/test/repo/issues'
# The link check: a URL or an ssh remote to GitHub, never a folder of a local path.
check allow tech-lead 'ls ~/go/pkg/mod/github.com/foo/bar@v1'
check allow tech-lead 'cat /home/x/src/github.com/foo/bar/README.md'
check allow tech-lead 'echo https://github.com/test/repo/pull/3'
check deny tech-lead 'git clone https://github.com/someone/else'
check deny tech-lead 'curl -sL https://www.github.com/someone/else/archive/main.zip'
check deny tech-lead 'git remote add x git@github.com:someone/else.git'
check deny tech-lead 'open github.com/someone/else'
# Every other subdomain of github.com stays the link check's.
check deny tech-lead 'curl -sL https://codeload.github.com/someone/else/tar.gz/main'
check deny tech-lead 'curl -s https://gist.github.com/someone/abc123'
check deny tech-lead 'curl -s https://uploads.github.com/repos/someone/else/releases/1/assets'
check allow tech-lead 'ls ~/src/gist.github.com/foo/bar'
# The edit check judges the path: sed -i or perl -i only on a file of the repository. The script and the values
# of -e/-f are no files, a relative path is resolved after the cds, a variable from the session's environment.
J="$T/jobs/x/tmp"
check allow spike "sed -i -e 's/a/b/' $J/x.txt"
check allow spike "sed -i --expression='s/a/b/' $J/x.txt"
check allow spike "sed -n -i -f $T/s.sed $J/x.txt"
check allow spike "perl -i -pe 's/a/b/' $J/x.txt"
check allow spike "perl -pi -e 's/a/b/' $J/x.txt"
check allow spike "cd $J && sed -i 's/a/b/' x.txt"
check allow spike "sed -i 's/a/b/' \"\$CLAUDE_JOB_DIR/tmp/x.txt\""
check allow spike "sed -i 's/a/b/' \${CLAUDE_JOB_DIR}/tmp/x.txt"
check allow spike "cd \$CLAUDE_JOB_DIR/tmp && sed -i 's/a/b/' x.txt"
check allow spike "sed -i 's/a/b/' \$HOME/x.txt"
check allow spike "sed -n 's/a/b/p' README.md"
check allow spike "perl -ne 'print if /a/' README.md"
check deny spike "sed -i -e 's/a/b/' README.md"
check deny spike "cd sub && sed -i 's/a/b/' ../README.md"
check deny spike "sed -i 's/a/b/' \$HOME/../repo/README.md"
check deny spike "cd $J && sed -i 's/a/b/' $R/README.md"
# A variable the session does not know, or a substitution, may be the repository.
check deny spike "sed -i 's/a/b/' \"\$UNKNOWN_DIR/x.txt\""
check deny spike "sed -i 's/a/b/' \"\$(git rev-parse --show-toplevel)/README.md\""
check deny spike "cd \$UNKNOWN_DIR && sed -i 's/a/b/' x.txt"
# The in-place forms the check missed before.
check deny spike "perl -pi -e 's/a/b/' README.md"
check deny tech-lead "perl -pi.bak -e 's/a/b/' $R/README.md"
check deny spike "perl -0777 -pi -e 's/a/b/' README.md"
check deny spike "sed -ni 's/a/b/p' README.md"
check deny spike "sed -Ei 's/a/b/' README.md"
check deny spike "sed -i --expression='s/a/b/' README.md"
check deny spike "sed 's/a/b/' -i README.md"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
