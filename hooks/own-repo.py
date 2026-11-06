"""Tells whether a shell command reaches outside the session's own repository.

Used by planner-guard.sh: prints a reason and exits 1 when the command points gh at another
repository (-R/--repo, gh api repos/..., github.com/... links), searches across repositories
(gh search), or does anything but read in another repository (cd, git -C). Reading another
repository with git (log, show, diff, grep, branch listing, fetch...) is allowed, for ports;
switching its branches is not, since that moves its main checkout under its own sessions.
Exits 0 when the command is fine.
    python3 -I own-repo.py <owner/name> <repo root> <cwd>   (command on stdin)
"""

import os
import re
import shlex
import subprocess
import sys

own, root, cwd = sys.argv[1].lower(), os.path.realpath(sys.argv[2]), sys.argv[3]
command = sys.stdin.read()


def repo_of(ref):
    ref = ref.strip().lower().removesuffix(".git").rstrip("/")
    ref = re.sub(r"^(https?://|git@)?github\.com[:/]", "", ref)
    parts = [p for p in ref.split("/") if p]
    return "/".join(parts[:2]) if len(parts) >= 2 else None


def outside(reason):
    print(reason)
    sys.exit(1)


try:
    words = shlex.split(command, posix=True)
except ValueError:
    words = command.split()

if re.search(r"\bgh\s+search\b", command):
    outside("gh search looks across repositories")

for i, w in enumerate(words):
    value = None
    if w in ("-R", "--repo") and i + 1 < len(words):
        value = words[i + 1]
    elif w.startswith("--repo="):
        value = w.split("=", 1)[1]
    if value is not None and repo_of(value) not in (None, own):
        outside(f"it points gh at {value}")

for match in re.finditer(r"repos/([\w.-]+/[\w.-]+)", command):
    if match.group(1).lower() != own:
        outside(f"it calls the API of {match.group(1)}")
for match in re.finditer(r"github\.com[:/]([\w.-]+/[\w.-]+)", command):
    if repo_of(match.group(1)) != own:
        outside(f"it links {match.group(1)}")


def toplevel(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return os.path.realpath(out.stdout.strip()) if out.returncode == 0 else None


READ_GIT = {"log", "show", "diff", "grep", "ls-files", "ls-tree", "blame", "branch", "fetch", "status",
            "rev-parse", "rev-list", "cat-file", "describe", "shortlog", "remote", "config", "worktree", "tag"}
WRITE_TOOLS = {"rm", "mv", "cp", "touch", "mkdir", "rmdir", "tee", "chmod", "chown", "ln", "install", "truncate",
               "npm", "npx", "bun", "bunx", "yarn", "pnpm", "go", "make", "cargo", "pip", "uv", "docker", "sst",
               "terraform", "cdk", "patch"}


def elsewhere():
    """The other repository the command enters, if any."""
    for i, w in enumerate(words):
        target = None
        if w == "cd" and i + 1 < len(words):
            target = words[i + 1]
        elif w == "-C" and i > 0 and words[i - 1] == "git" and i + 1 < len(words):
            target = words[i + 1]
        if not target or target.startswith("-"):
            continue
        path = os.path.realpath(os.path.join(cwd, os.path.expanduser(target)))
        top = toplevel(path)
        if top and top != root and not top.startswith(root + os.sep):
            return top
    return None


other = elsewhere()
if other:
    # Only reading: every git subcommand must be a reading one, no file is written, nothing is built.
    for i, w in enumerate(words):
        if w != "git":
            continue
        j = i + 1
        while j < len(words) and words[j].startswith("-"):
            j += 2 if words[j] in ("-C", "-c") else 1
        sub = words[j] if j < len(words) else ""
        rest = words[j + 1:j + 4]
        if sub in ("switch", "checkout", "restore"):
            outside(f"it switches branches in another repository ({other}); read another branch with "
                    f"git -C <repo> show <branch>:<file>, git log <branch> or git diff main..<branch>")
        if sub not in READ_GIT:
            outside(f"git {sub} changes another repository ({other}); there you may only read")
        if sub == "branch" and any(not a.startswith("-") or a in ("-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy") for a in rest if a not in ("-a", "-r", "-v", "-vv", "--list", "--all", "--remotes", "--contains", "--merged", "--no-merged")):
            outside(f"git branch would change another repository ({other}); listing is fine")
        if sub == "worktree" and (not rest or rest[0] != "list"):
            outside(f"git worktree changes another repository ({other}); git worktree list is fine")
        if sub in ("remote", "config", "tag") and rest and rest[0] not in ("-v", "--get", "--list", "-l", "show", "get-url"):
            outside(f"git {sub} {rest[0]} changes another repository ({other}); there you may only read")
    for w in words:
        if os.path.basename(w) in WRITE_TOOLS:
            outside(f"{w} could change another repository ({other}); there you may only read")
        if w in ("-i", "--in-place") or w.startswith("-i."):
            outside(f"an in-place edit in another repository ({other})")
    if re.search(r"(^|[^0-9&>])>{1,2}\s*(?!/dev/null)[^&\s]", command):
        outside(f"it writes a file while in another repository ({other})")
sys.exit(0)
