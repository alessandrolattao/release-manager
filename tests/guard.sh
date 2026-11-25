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
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
