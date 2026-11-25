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
check deny tech-lead 'gh issue view 3 -R someone/else'
check deny tech-lead 'gh api repos/someone/else/issues'
check deny tech-lead 'gh search issues foo'
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
# A cluster holding c (bash -lc, sh -ec) is sh -c too.
check deny tech-lead "bash -lc 'git push origin HEAD'"
check deny spike "sh -ec 'git commit -m x'"
check deny tech-lead "bash -lc 'gh api repos/someone/else/issues'"
check allow tech-lead "bash -lc 'git log --oneline -3'"
# A string piped into a shell by echo or printf, or given to it with <<<, is read too; a here-document stays data.
check deny tech-lead "echo 'git push origin HEAD' | sh"
check deny tech-lead "printf 'git commit -m x\\n' | bash"
check deny spike "echo 'git switch main' | sudo bash"
check deny tech-lead "bash -s <<< 'git push'"
check deny tech-lead "cat <<< 'git push' | sh"
check deny tech-lead "(echo 'git push') | sh"
check deny tech-lead "echo 'git push' |& bash"
check allow tech-lead "echo 'git push' || sh -c 'git log -1'"
check allow tech-lead "echo 'git log --oneline -3' | sh"
check allow tech-lead "echo 'git push' | grep push"
check allow tech-lead "grep -c push <<< 'git push'"
check allow tech-lead "bash <<'EOF'
git log -1
EOF"
# Strings that become code are read like sh -c: eval, source or . or a shell on <(...), ssh's remote command.
check deny tech-lead "eval 'git push origin HEAD'"
check deny tech-lead "source <(echo 'git push origin HEAD')"
check deny tech-lead ". <(printf 'git commit -m x\\n')"
check deny tech-lead "bash <(echo 'git push')"
check deny spike "bash < <(echo 'git switch main')"
check deny tech-lead "ssh host 'git push origin HEAD'"
check deny tech-lead "ssh -p 2222 -o StrictHostKeyChecking=no -l me host 'git commit -m x'"
check allow tech-lead "ssh host 'git log -1'"
check allow tech-lead "source <(echo 'export X=1')"
check allow tech-lead "eval 'git status'"
# After a wrapper (timeout, xargs, sudo -u ...), a command that runs code is read too, for every rule.
check deny tech-lead "timeout 10 bash -c 'git push'"
check deny tech-lead "echo 1 | xargs sh -c 'git commit -m x'"
check deny tech-lead "echo 'git push' | sudo -u me sh"
check allow tech-lead "timeout 10 bash -c 'git log -1'"
# After a wrapper, the command is the first word past the wrapper's options; a later word naming eval, ssh or
# a shell is an argument (sudo git commit -m eval is git commit).
check deny tech-lead 'sudo git commit -m eval'
check deny tech-lead 'env git commit -m "eval"'
check deny tech-lead 'time git commit -m eval'
check deny tech-lead 'nohup git push origin eval'
check allow tech-lead "sudo grep sh <<< 'git push'"
check allow tech-lead "echo 'git push' | xargs grep -l sh"
check allow tech-lead "echo 'git push' | sudo grep -c sh"
check deny tech-lead "echo 'git push' | timeout -s KILL 5 sh"
check deny tech-lead "echo 1 | xargs -I {} sh -c 'git push'"
check deny tech-lead "echo 'git push' | nice -n 5 sh"
# The command that runs the string is still judged by its own rules: in another repository it writes no file.
check deny tech-lead "cd $S && echo ls | sh > out.txt"
check deny tech-lead "cd $S && timeout 5 bash -c 'ls' > out.txt"
check deny tech-lead "cd $S && bash <<< 'ls' > out.txt"
check deny tech-lead "cd $S && printf 'ls' | bash >> out.txt"
check allow tech-lead "cd $S && echo ls | sh"
# sh -c '...' and eval '...' too: their command keeps its own rules (main lets these through).
check deny tech-lead "cd $S && bash -c 'ls' > out.txt"
check deny tech-lead "cd $S && sh -c 'ls' >> out.txt"
check deny tech-lead "cd $S && eval ls > out.txt"
check allow tech-lead "cd $S && bash -c 'ls'"
# -- after -c, a group or a filter in the pipe, xargs giving sh -c its string, what a substitution prints for
# eval or sh -c: the text still becomes code.
check deny tech-lead "sh -c -- 'gh api repos/someone/else/issues'"
check deny tech-lead "sh -c -- 'git push'"
check deny tech-lead "find . -exec sh -c -- 'gh api repos/someone/else/issues' \;"
check deny tech-lead "{ echo 'gh api repos/someone/else/issues'; } | bash"
check deny tech-lead "{ echo 'git push'; } | sh"
check deny tech-lead "(echo 'git log'; echo 'git push') | sh"
check deny tech-lead "echo 'gh api repos/someone/else/issues' | tee /dev/null | sh"
check deny tech-lead "echo 'git push' | tee /dev/null | sh"
check deny tech-lead "echo 'gh api repos/someone/else/issues' | xargs -0 bash -c"
check deny tech-lead "echo 'git push' | xargs -0 bash -c"
check deny tech-lead "xargs -0 sh -c <<< 'gh api repos/someone/else/issues'"
check deny tech-lead "xargs -0 sh -c <<< 'git push'"
check deny tech-lead "sh -c '>/dev/null git push'"
check deny tech-lead "bash -c '<x gh api repos/someone/else/issues'"
# A redirection is no part of the command: >/dev/null git push is git push, git >/dev/null push too.
check deny tech-lead '>/dev/null git push'
check deny tech-lead '2>/dev/null git commit -m x'
check deny tech-lead 'git >/dev/null push origin HEAD'
check deny tech-lead '>/dev/null sudo git push'
check deny tech-lead ">/dev/null bash -c 'git push'"
check allow tech-lead '>/dev/null git log -1'
check deny tech-lead "cd $S && >out.txt git log -1"
# A quoted '>' is a word, no redirection: it takes no word with it.
check deny tech-lead "echo 'git push' | sudo -u '>' sh"
check allow tech-lead "grep -c '>' README.md"
check deny tech-lead "eval \"\$(echo 'gh api repos/someone/else/issues')\""
check deny tech-lead "eval \"\$(printf 'git push')\""
check deny tech-lead "bash -c \"\$(echo 'git push')\""
check allow tech-lead "{ echo 'git log -1'; } | sh"
check allow tech-lead "echo 'git log' | tee /dev/null | sh"
check allow tech-lead "eval \"\$(echo 'export X=1')\""
check allow tech-lead "echo 'git push' > notes.txt; echo ls | sh"
# env -S splits its string into the command; sudo -R, env -P and doas -a take a value.
check deny tech-lead "echo 'git push' | env -S sh"
check deny tech-lead "env -S \"bash -c 'git push'\""
check deny tech-lead "env -S 'git push origin HEAD'"
check deny tech-lead "env --split-string='git commit -m x'"
check deny tech-lead 'env -S "gh api repos/someone/else/issues"'
check allow tech-lead "env -S 'git log -1'"
check deny tech-lead "echo 'git push' | env -P /bin sh"
check deny tech-lead "echo 'git push' | sudo -R / sh"
check deny tech-lead "echo 'git push' | doas -a style sh"
# Short options come bundled too, as getopt reads them: -iS, -nu me, -0I {}.
check deny tech-lead 'env -iS "gh api repos/someone/else/issues"'
check deny tech-lead "env -iS 'git push'"
check deny tech-lead "echo 'git push' | sudo -nu me sh"
check deny tech-lead "echo 'git push' | sudo -num sh"
check deny tech-lead "echo 'git push' | env -Sbash"
check deny tech-lead "echo 1 | xargs -0I {} sh -c 'git push'"
check allow tech-lead "env -iS 'git log -1'"
# A long option may be cut short, as getopt_long reads it, and some take a value only with =.
check deny tech-lead 'env --split "gh api repos/someone/else/issues"'
check deny tech-lead "env --spl='git push'"
check deny tech-lead "echo 'git push' | sudo --us me sh"
check deny tech-lead "echo 'git push' | timeout --sig KILL 5 sh"
check deny tech-lead "echo 'git push' | xargs --replace sh"
# ssh reads options after the host too, and -- ends them.
check deny tech-lead "ssh host -- 'git push'"
check deny tech-lead "ssh host -t 'git push'"
check deny tech-lead "ssh host -o ConnectTimeout=5 'git push'"
check allow tech-lead "ssh host -t 'git log -1'"
# A here-document stays data, also into a shell, as on main.
check allow tech-lead "bash <<'EOF'
git push
EOF"
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
# The API rule refuses repos/<other>/... by default, whatever the method, as main does; a local path (a folder
# before repos/), a quoted string that holds it after other text, and a comment call nothing.
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
check deny tech-lead "timeout 10 bash -c 'gh api repos/someone/else/issues'"
check deny tech-lead "echo 1 | xargs sh -c 'gh api repos/someone/else/issues'"
check deny tech-lead "echo 'gh api repos/someone/else/issues' | sh"
check deny tech-lead "echo 'gh api repos/someone/else/issues' | timeout 5 sh"
check deny tech-lead "sh <<< 'gh api repos/someone/else/issues'"
check deny tech-lead "eval 'gh api repos/someone/else/issues'"
check deny tech-lead "command eval 'gh api repos/someone/else/issues'"
check deny tech-lead "source <(echo 'gh api repos/someone/else/issues')"
check deny tech-lead "bash <(echo 'gh api repos/someone/else/issues')"
check deny tech-lead "ssh host 'gh api repos/someone/else/issues'"
check deny tech-lead "timeout 5 ssh -i key host 'gh api repos/someone/else/issues'"
check allow tech-lead "ssh host 'gh api repos/test/repo/issues'"
check allow tech-lead "echo 'gh api repos/test/repo/issues' | sh"
# gh takes api's own flags before api too.
check deny tech-lead 'gh -X POST api repos/someone/else/issues -f title=x'
check deny tech-lead 'gh --method POST api repos/someone/else/issues'
check deny tech-lead 'gh -H "Accept: application/json" api repos/someone/else/issues'
check deny tech-lead 'gh --hostname github.com api repos/someone/else/issues'
check allow tech-lead 'gh -X GET api repos/test/repo/issues'
# A substitution ends at the ) that closes it, past the parentheses of a quoted jq filter.
check deny tech-lead "x=\"\$(gh api --jq 'map(.title)' repos/someone/else/issues)\""
check deny tech-lead "echo \"\$(gh api --jq '.[] | select(.x)' repos/someone/else/issues)\""
check deny tech-lead "echo \"\$(echo \"\$(date)\") \$(gh api repos/someone/else/issues)\""
# A comment ends with its line: a backslash in it continues nothing.
check deny tech-lead '# note \
git push origin HEAD'
check deny tech-lead 'gh issue view 3 # see \
gh api repos/someone/else/issues'
# A # right after a substitution is in the word: $(x)#b.
check deny tech-lead 'echo $(echo a)#b; gh api repos/someone/else/issues'
check deny tech-lead 'echo `echo a`#b; git push'
# A line ending in a backslash goes on in the next one; a here-document's body stays data.
check deny tech-lead 'gh api -X POST \
  repos/someone/else/issues \
  -f title=x'
check deny tech-lead 'git commit \
  -m x'
check allow tech-lead "cat > $T/x.txt <<'EOF'
a line that ends in a backslash \\
EOF
echo done"
check deny tech-lead "cat > $T/x.txt <<'EOF'
a line that ends in a backslash \\
EOF
git push"
# A # inside a word is no comment; one that starts a word is.
check deny tech-lead 'git log --grep=#93 && gh api repos/someone/else/issues'
check deny tech-lead 'echo a#b; gh api repos/someone/else/issues'
check deny tech-lead 'echo a#b; git push'
check allow tech-lead 'gh issue view 93 # then gh api repos/someone/else/issues'
# An escaped backslash before $( leaves the substitution to the shell.
check deny tech-lead 'echo "\\$(gh api repos/someone/else/issues)"'
check allow tech-lead 'gh issue comment 3 --body "run \$(gh api repos/a/b) by hand"'
check allow tech-lead 'curl -s https://api.github.com/repos/test/repo/issues'
check deny tech-lead 'curl -s -X POST https://api.github.com/repos/someone/else/issues -d "{}"'
check deny tech-lead 'wget -qO- api.github.com/repos/someone/else/issues'
check allow tech-lead 'curl -s https://example.com/repos/a/b'
check allow tech-lead 'curl -s https://example.com/api/repos/a/b'
check allow tech-lead 'cat ./repos/someone_else/x.log'
check allow tech-lead 'ls /var/lib/repos/a/b'
check allow tech-lead 'gh issue comment 3 --body "see https://api.github.com/repos/someone/else/issues"'
check deny tech-lead 'gh api "https://api.github.com/repos/someone/else/issues"'
check deny tech-lead "gh api '/repos/someone/else/issues'"
check deny tech-lead 'curl -s https://user:token@api.github.com/repos/someone/else/issues'
check deny tech-lead 'API=https://api.github.com; curl -s $API/repos/someone/else/issues'
check deny tech-lead 'curl -s "$API/repos/someone/else/issues"'
check deny tech-lead 'curl -s "$(echo https://api.github.com)/repos/someone/else/issues"'
check allow tech-lead 'gh issue comment 3 --body "see $X and repos/a/b"'
# A variable counts only right before repos/; one at the start of a local path is no API's host.
check allow tech-lead 'tail -5 $HOME/.local/state/team/repos/someone_else/dispatcher.log'
check allow tech-lead 'tail -5 "$HOME/.local/state/team/repos/someone_else/dispatcher.log"'
check allow tech-lead 'cat "${XDG_STATE_HOME:-$HOME/.local/state}/team/repos/someone_else/dispatcher.log"'
check allow tech-lead 'cat "$(pwd)/.local/state/team/repos/a_b/x.log"'
check deny tech-lead 'curl -s ${API}/repos/someone/else/issues'
# ./ and dir/../ fold before the judgment, as a URL client folds them.
check deny tech-lead 'curl -s https://api.github.com/x/../repos/someone/else/issues'
check deny tech-lead 'curl -s https://api.github.com/./repos/someone/else/issues'
check deny tech-lead 'curl -s "$API/v3/../repos/someone/else/issues"'
check allow tech-lead 'tail -1 ~/.local/state/team/../team/repos/someone_else/dispatcher.log'
# The word before repos/ is judged as the shell makes it: its backslashes go, its braces expand.
check deny tech-lead 'gh api /\repos/someone/else/issues'
check deny tech-lead 'gh api \/repos/someone/else/issues'
check deny tech-lead 'curl -s https://api.github.com/\repos/someone/else/issues'
check deny tech-lead 'curl -s https://api.github.com/{repos/someone/else/issues,}'
check deny tech-lead 'curl -s {https://api.github.com/,}repos/someone/else/issues'
check allow tech-lead 'ls ~/src/{a,b}/repos/x/y'
# A shell word may hold quoted parts: the word before repos/ is all of them, its quotes removed.
check allow tech-lead "tail '/home/x/.local/state/team'/repos/someone_else/dispatcher.log"
check allow tech-lead 'tail "$HOME/.local/state/team/"repos/someone_else/dispatcher.log'
check allow tech-lead 'tail ~/.local/state/team/"repos/someone_else/dispatcher.log"'
check allow tech-lead 'curl "https://example.com"/repos/a/b'
check deny tech-lead 'gh api "/"repos/someone/else/issues'
check deny tech-lead 'gh api ""repos/someone/else/issues'
check deny tech-lead 'curl "https://api.github.com"/repos/someone/else/issues'
check deny tech-lead "curl https://api.github.com/'repos/someone/else/issues'"
# A word that only names a shell, . or eval is no command that runs code.
check allow tech-lead 'echo "see repos/a/b" | grep .'
check allow tech-lead "printf '%s\\n' 'see repos/a/b' | grep -c sh"
check allow tech-lead "grep sh <<< 'see repos/a/b'"
check allow tech-lead "grep . <(echo 'it ran gh api repos/a/b')"
check allow tech-lead "grep -w eval <<< 'see repos/a/b'"
check deny tech-lead "find . -name x -exec sh -c 'gh api repos/someone/else/issues' \;"
# Refused by default: a command name known at run time, or the endpoint as data.
check deny tech-lead '$(which gh) api repos/someone/else/issues'
check deny tech-lead 'GH=gh; $GH api repos/someone/else/issues'
check deny tech-lead 'f() { gh api "$@"; }; f repos/someone/else/issues'
check deny tech-lead 'echo repos/someone/else/issues | xargs gh api'
check deny tech-lead 'gh api $(echo repos/someone/else/issues)'
check deny tech-lead 'for r in repos/someone/else/issues; do gh api "$r"; done'
# The accepted cost: a word that starts with repos/<x>/<y> outside an API call is refused too.
check deny tech-lead 'cd ~/.local/state/team && cat repos/test_repo/dispatcher.log'
check deny tech-lead 'echo repos/a/b'
check deny tech-lead 'gh issue comment 3 --body "repos/a/b"'
check deny tech-lead 'curl -s https://API.github.com/repos/someone/else/issues'
check allow tech-lead 'curl -s https://API.github.com/repos/test/repo/issues'
check deny tech-lead 'curl -s https://api.github.com:443/repos/someone/else/issues'
check deny tech-lead 'gh api https://api.github.com:443/repos/someone/else/issues'
check allow tech-lead 'curl -s https://api.github.com:443/repos/test/repo/issues'
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
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
