"""Keeps a tech lead and its spikes from developing, judging the command alone, without the model.

Only the commands the shell would run count: the words of a quoted string or of a here-document never do,
so a comment or a rule that talks about "git push" passes. The plugin's own scripts always pass, except the
ones a spike may not run.
Refused:
  - a command that changes code, branches or pull requests (git commit, push, merge, rebase, ...; gh pr
    create, merge, ...; claude --bg or -p; sed -i or perl -i on a file of the repository);
  - anything aimed at another repository but reading it with git (gh -R, GH_REPO, gh api repos/<other>,
    gh search, links to it, writing or building inside it), except, for a tech lead, its issues and comments:
    gh issue view, list, create, edit, comment and gh pr view, list, diff, comment, whether the repository
    comes with -R, --repo, GH_REPO or a link; gh api GET on repos/<other>/issues... and repos/<other>/pulls...,
    POST and PATCH on repos/<other>/issues...;
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
# What a tech lead may do on another repository: read its issues and pull requests, write issues and comments.
GH_ELSEWHERE = {("issue", "view"), ("issue", "list"), ("issue", "create"), ("issue", "edit"), ("issue", "comment"),
                ("pr", "view"), ("pr", "list"), ("pr", "diff"), ("pr", "comment")}
API_REF = re.compile(r"repos/([\w.-]+/[\w.-]+)")
LINK_REF = re.compile(r"github\.com[:/]([\w.-]+/[\w.-]+)")
# A gh api endpoint: a path or a URL of the API, the repository, then the rest of the path.
ENDPOINT = re.compile(r"^(?:(?:https?://)?api\.github\.com)?/?repos/([\w.-]+/[\w.-]+)(/[^?#]*)?", re.IGNORECASE)


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


def gh_words(words):
    """A gh command's words without -R/--repo and their values, and the repositories those name."""
    rest, named, i = [], [], 0
    while i < len(words):
        w = words[i]
        if w in ("-R", "--repo") and i + 1 < len(words):
            named.append(words[i + 1])
            i += 2
            continue
        if w.startswith("--repo="):
            named.append(w.split("=", 1)[1])
        elif w.startswith("-R") and len(w) > 2:
            named.append(w[2:])
        else:
            rest.append(w)
        i += 1
    return rest, named


def api_method(words):
    """The HTTP method of a gh api call: -X / --method, else POST with fields or an input, else GET."""
    method, fields = None, False
    for i, w in enumerate(words):
        if w in ("-X", "--method") and i + 1 < len(words):
            method = words[i + 1]
        elif w.startswith("--method="):
            method = w.split("=", 1)[1]
        elif w.startswith("-X") and len(w) > 2:
            method = w[2:]
        elif (w in ("-f", "-F", "--field", "--raw-field", "--input")
              or w.startswith(("--field=", "--raw-field=", "--input=", "-f", "-F"))):
            fields = True
    return (method or ("POST" if fields else "GET")).upper()


def elsewhere_refused(head, words, assigns):
    """Why a command aimed at another repository is refused, or None when it is not aimed at one or may be run.

    A tech lead may read another repository's issues and pull requests and write issues and comments there;
    everything else stays refused, as for a spike.
    """
    named = [a.split("=", 1)[1] for a in assigns if a.startswith("GH_REPO=")]
    rest = words[1:]
    if head == "gh":
        rest, flags = gh_words(rest)
        named += flags
    elif any(w in ("-R", "--repo") or w.startswith("--repo=") for w in rest):
        named += gh_words(rest)[1]
    text = assigns + words
    pointed = [n for n in named if repo_of(n) not in (None, own)]
    called = [m.group(1) for w in text for m in API_REF.finditer(w) if m.group(1).lower() != own]
    linked = [m.group(1) for w in text for m in LINK_REF.finditer(w) if repo_of(m.group(1)) not in (None, own)]
    if not (pointed or called or linked):
        return None
    # A substitution inside a quoted word, or in backticks, stays in that word: what it runs would ride on the
    # allowed command unseen, so a command carrying one gets no exception.
    allowed = role == "tech-lead" and head == "gh" and not any(re.search(r"\$\(|`|<\(|>\(", w) for w in text)
    if allowed and tuple(rest[:2]) in GH_ELSEWHERE:
        return None
    if allowed and rest[:1] == ["api"] and not pointed:
        # Its endpoint decides; the repositories named in its fields are data. Every word that starts as an
        # endpoint of another repository counts as one, so an unknown option cannot hide the real endpoint.
        method = api_method(rest)
        for w in rest[1:]:
            m = ENDPOINT.match(w)
            if not m or m.group(1).lower() == own:
                continue
            path = m.group(2) or ""
            if method == "GET" and re.match(r"^/(issues|pulls)(/|$)", path):
                continue
            if method in ("POST", "PATCH") and re.match(r"^/issues(/|$)", path):
                continue
            return (f"{method} {w} is not for this repository: on {m.group(1)} it reads issues and pull requests "
                    "and writes issues and comments only")
        return None
    if pointed:
        return f"it points gh at {pointed[0]}"
    if called:
        return f"it calls the API of {called[0]}"
    return f"it links {linked[0]}"


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

where = cwd
for words in segments:
    assigns = []
    while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in ("sudo", "time", "env", "nohup", "exec")):
        if "=" in words[0]:
            assigns.append(words[0])
        words = words[1:]
    if not words:
        # Only assignments: what they hold may be used by the next command.
        why = elsewhere_refused("", [""], assigns)
        if why:
            refuse(why)
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

    why = elsewhere_refused(head, words, assigns)
    if why:
        refuse(why)

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
        sub = gh_words(words[1:])[0]
        if sub[:1] == ["pr"] and sub[1:2] and sub[1] in ("create", "merge", "edit", "close", "review", "checkout"):
            refuse(f"gh pr {sub[1]} is a developer's work")
        if sub[:2] == ["issue", "develop"]:
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
