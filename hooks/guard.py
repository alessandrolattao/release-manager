"""Keeps a tech lead and its spikes from developing, judging the command alone, without the model.

Only the commands the shell would run count: the words of a quoted string or of a here-document never do,
so a comment or a rule that talks about "git push" passes. The plugin's own scripts always pass, except the
ones a spike may not run.
Refused:
  - a command that changes code, branches or pull requests (git commit, push, merge, rebase, ...; gh pr
    create, merge, ...; claude --bg or -p; sed -i or perl -i on a file of the repository);
  - anything aimed at another repository but reading it with git (gh -R, gh api repos/<other>, gh search,
    links to it, writing or building inside it);
  - for a spike: moving the main checkout (git checkout, switch, pull) and starting agents.
Prints the reason and exits 1 when refused, exits 0 otherwise.
    python3 -I guard.py <role> <owner/name> <repo root> <cwd> <plugin root>   (command on stdin)
"""

import os
import re
import shlex
import subprocess
import sys

role, own, root, cwd, plugin = sys.argv[1], sys.argv[2].lower(), os.path.realpath(sys.argv[3]), sys.argv[4], os.path.realpath(sys.argv[5])
command = sys.stdin.read()

WRITE_GIT = {"commit", "push", "merge", "rebase", "cherry-pick", "revert", "am", "apply", "stash", "restore", "reset"}
READ_GIT = {"log", "show", "diff", "grep", "ls-files", "ls-tree", "blame", "branch", "fetch", "status", "rev-parse",
            "rev-list", "cat-file", "describe", "shortlog", "remote", "config", "worktree", "tag", "merge-base"}
BUILD = {"rm", "mv", "cp", "touch", "mkdir", "rmdir", "tee", "chmod", "chown", "ln", "install", "truncate", "npm", "npx",
         "bun", "bunx", "yarn", "pnpm", "go", "make", "cargo", "pip", "uv", "docker", "sst", "terraform", "cdk", "patch"}
SPIKE_FORBIDDEN_SCRIPTS = {"spike.sh", "start-dev.sh", "start-qa.sh", "merge.sh", "checkout.sh"}


def refuse(reason):
    print(reason)
    sys.exit(1)


def repo_of(ref):
    ref = ref.strip().lower().removesuffix(".git").rstrip("/")
    ref = re.sub(r"^(https?://|git@)?github\.com[:/]", "", ref)
    parts = [p for p in ref.split("/") if p]
    return "/".join(parts[:2]) if len(parts) >= 2 else None


def toplevel(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return os.path.realpath(out.stdout.strip()) if out.returncode == 0 else None


def inside_repo(path):
    real = os.path.realpath(os.path.join(cwd, os.path.expanduser(path)))
    return real == root or real.startswith(root + os.sep)


# Here-documents are data: their bodies go before anything is parsed.
lines, skipping = [], None
for line in command.split("\n"):
    if skipping is not None:
        if line.strip() == skipping:
            skipping = None
        continue
    lines.append(line)
    # `<<<word` is a here-string, on its own line: nothing after it is skipped.
    match = re.search(r"(?<!<)<<(?!<)-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
    if match:
        skipping = match.group(1)
script = ";\n".join(lines)

try:
    lexer = shlex.shlex(script, posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    tokens = script.split()

segments, current = [], []
for token in tokens:
    if token and set(token) <= set(";&|()"):
        if current:
            segments.append(current)
        current = []
    else:
        current.append(token)
if current:
    segments.append(current)

if any(s[:2] == ["gh", "search"] for s in segments):
    refuse("gh search looks across repositories")
for match in re.finditer(r"repos/([\w.-]+/[\w.-]+)", script):
    if match.group(1).lower() != own:
        refuse(f"it calls the API of {match.group(1)}")
for match in re.finditer(r"github\.com[:/]([\w.-]+/[\w.-]+)", script):
    if repo_of(match.group(1)) not in (None, own):
        refuse(f"it links {match.group(1)}")

where = cwd
for words in segments:
    while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in ("sudo", "time", "env", "nohup", "exec")):
        words = words[1:]
    if not words:
        continue
    head = os.path.basename(words[0])

    # The plugin's own scripts: they hold their own rules.
    target = words[1] if head in ("sh", "bash") and len(words) > 1 else words[0]
    real = os.path.realpath(os.path.join(where, os.path.expanduser(target)))
    if real.startswith(plugin + os.sep) and real.endswith(".sh"):
        if role == "spike" and os.path.basename(real) in SPIKE_FORBIDDEN_SCRIPTS:
            refuse(f"a spike only reads: it does not run {os.path.basename(real)}")
        continue

    # A command inside a command (sh -c '...', eval ...) is checked as one of its own.
    inner = None
    if head in ("sh", "bash", "zsh", "dash") and "-c" in words[1:]:
        k = words.index("-c")
        inner = words[k + 1] if k + 1 < len(words) else ""
    elif head == "eval":
        inner = " ".join(words[1:])
    if inner is not None:
        nested = subprocess.run([sys.executable, "-I", os.path.abspath(__file__), *sys.argv[1:]],
                                input=f"cd {shlex.quote(where)}\n{inner}", capture_output=True, text=True)
        if nested.returncode != 0:
            sys.stdout.write(nested.stdout)
            sys.stderr.write(nested.stderr)
            sys.exit(nested.returncode)
        continue

    if head == "cd" and len(words) > 1:
        where = os.path.realpath(os.path.join(where, os.path.expanduser(words[1])))
        continue

    for i, w in enumerate(words):
        value = None
        if w in ("-R", "--repo") and i + 1 < len(words):
            value = words[i + 1]
        elif w.startswith("--repo="):
            value = w.split("=", 1)[1]
        if value is not None and repo_of(value) not in (None, own):
            refuse(f"it points gh at {value}")

    top = toplevel(where)
    other = top if top and top != root and not top.startswith(root + os.sep) else None

    if head == "git":
        j, gitdir = 1, where
        while j < len(words) and words[j].startswith("-"):
            if words[j] == "-C" and j + 1 < len(words):
                gitdir = os.path.realpath(os.path.join(where, os.path.expanduser(words[j + 1])))
                j += 2
            elif words[j] == "-c":
                j += 2
            else:
                j += 1
        sub = words[j] if j < len(words) else ""
        rest = words[j + 1:]
        gtop = toplevel(gitdir)
        elsewhere = gtop if gtop and gtop != root and not gtop.startswith(root + os.sep) else None
        if elsewhere:
            if sub in ("switch", "checkout", "restore", "pull"):
                refuse(f"it moves another repository ({elsewhere}); read another branch with git -C <repo> show <branch>:<file>")
            # git symbolic-ref <ref> only prints where the ref points; with a target or --delete it changes it.
            options = [a for a in rest if a.startswith("-")]
            reads_ref = sub == "symbolic-ref" and set(options) <= {"--short", "-q", "--quiet"} and len(rest) - len(options) == 1
            if sub not in READ_GIT and not reads_ref:
                refuse(f"git {sub} changes another repository ({elsewhere}); there you may only read")
            continue
        creates_branch = sub == "branch" and any(not a.startswith("-") for a in rest) and not any(
            a in ("-a", "-r", "--list", "--all", "--remotes", "--contains", "--merged", "--no-merged", "-v", "-vv") for a in rest)
        if (sub in WRITE_GIT or creates_branch
                or (sub == "checkout" and "-b" in rest) or (sub == "switch" and ("-c" in rest or "--create" in rest))
                or (sub == "worktree" and rest[:1] == ["add"])):
            refuse(f"git {sub} changes code or branches")
        if role == "spike" and sub in ("checkout", "switch", "pull"):
            refuse("the main checkout stays where it is (read another branch with git show <branch>:<path>)")
        continue

    if head == "gh" and len(words) > 2:
        if words[1] == "pr" and words[2] in ("create", "merge", "edit", "close", "review", "checkout"):
            refuse(f"gh pr {words[2]} is a developer's work")
        if words[1:3] == ["issue", "develop"]:
            refuse("gh issue develop is a developer's work")
        continue

    if head == "claude" and any(w in ("--bg", "--background", "-p", "--print") for w in words[1:]):
        refuse("agents start through the plugin's scripts (start-dev.sh, spike.sh), never by hand")

    if head in ("sed", "perl") and any(w in ("-i", "--in-place") or w.startswith("-i") for w in words[1:]):
        files = [w for w in words[1:] if not w.startswith("-")]
        # Without -e or -f the first word is the script, the rest are files.
        if not any(w in ("-e", "--expression", "-f", "--file") or w in ("-pe", "-ne", "-pi", "-npe") for w in words[1:]):
            files = files[1:]
        if any(inside_repo(f) for f in files):
            refuse(f"{head} -i edits a file of the repository")

    if other:
        if head in BUILD:
            refuse(f"{head} could change another repository ({other}); there you may only read")
        if any(re.match(r"^\d*>>?$", w) for w in words):
            refuse(f"it writes a file while in another repository ({other})")
sys.exit(0)
