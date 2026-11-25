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
    POST on repos/<other>/issues (a new one), issues/<n>/comments, labels or assignees and issues/comments/<id>,
    PATCH on repos/<other>/issues/comments/<id>;
  - a repository reached by its id (repositories/<id>), whose it is the guard cannot tell;
  - a GraphQL mutation typed by hand (gh api graphql, curl), or a query the guard cannot read (a file, stdin, a
    variable); the plugin's scripts run theirs;
  - any gh repo subcommand but view, clone, gitignore and license, on any repository (view and clone pass
    with a link to another one too);
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
SPIKE_FORBIDDEN_SCRIPTS = {"spike.sh", "start-dev.sh", "start-qa.sh", "merge.sh", "merge-bot.sh", "checkout.sh"}
# What a tech lead may do on another repository: read its issues and pull requests, write issues and comments.
GH_ELSEWHERE = {("issue", "view"), ("issue", "list"), ("issue", "create"), ("issue", "edit"), ("issue", "comment"),
                ("pr", "view"), ("pr", "list"), ("pr", "diff"), ("pr", "comment")}
# gh api's options that take a value: the rest of their word (after = for a long one), or the next word.
GH_API_SHORT_VALUES = set("FHXfpqt")
GH_API_LONG_VALUES = {"--cache", "--field", "--header", "--hostname", "--input", "--jq", "--method", "--preview",
                      "--raw-field", "--template"}
# The gh repo subcommands a tech lead or a spike may run, on any repository: they only read, or copy one to read it.
GH_REPO_READS = {"view", "clone", "gitignore", "license"}
API_REF = re.compile(r"repos/([\w.-]+/[\w.-]+)")
LINK_REF = re.compile(r"github\.com[:/]([\w.-]+/[\w.-]+)")
# A repository reached by its numeric id: whose it is the guard cannot tell.
BY_ID = re.compile(r"(?:^|/)repositories/\d+", re.IGNORECASE)
# What a tech lead may POST or PATCH on another repository, past repos/<owner>/<name>: a new issue, an issue's
# comments, labels and assignees, and a comment. GitHub takes a POST on what it patches as that PATCH, so a POST
# on an issue itself (which can close it, or a pull request) is no more allowed than a PATCH there.
POST_ELSEWHERE = re.compile(r"^/issues(/\d+/(comments|labels|assignees))?/?$|^/issues/comments/\d+/?$")
PATCH_ELSEWHERE = re.compile(r"^/issues/comments/\d+/?$")
# GitHub's GraphQL endpoint as gh api names it, and a mutation in what is sent there.
GRAPHQL = re.compile(r"(?:^|/)graphql(?:/|$|[?#])", re.IGNORECASE)
MUTATION = re.compile(r"\bmutation\b")
# A gh api endpoint: a path or a URL of the API, the repository, then the rest of the path.
ENDPOINT = re.compile(r"^(?:https://api\.github\.com)?/?repos/([\w.-]+/[\w.-]+)(/[^?#]*)?(?:[?#].*)?$", re.IGNORECASE)
# A gh api field (key=value): data, not an endpoint.
FIELD = re.compile(r"^[\w\[\]]+=")


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
    """The HTTP method of a gh api call: -X / --method, else POST with fields or an input, else GET.

    Short options stack as gh reads them: in `-iXPUT` or `-if title=x`, -i takes no value and the next letter
    takes the rest of the word, or the next word. A value in the next word is that option's, whatever it looks
    like: in `-q -XGET` it is a jq filter, not a method.
    """
    method, fields, value_of = None, False, None
    for i, w in enumerate(words):
        nxt = words[i + 1] if i + 1 < len(words) else ""
        if value_of == i:
            continue
        if w.startswith("--"):
            name, eq, value = w.partition("=")
            if name in GH_API_LONG_VALUES and not eq:
                value, value_of = nxt, i + 1
            if name == "--method":
                method = value
            elif name in ("--field", "--raw-field", "--input"):
                fields = True
        elif w.startswith("-") and len(w) > 1:
            for k, letter in enumerate(w[1:], 2):
                if letter in GH_API_SHORT_VALUES:
                    value = w[k:]
                    if not value:
                        value, value_of = nxt, i + 1
                    if letter == "X":
                        method = value
                    elif letter in "fF":
                        fields = True
                    break
    return (method or ("POST" if fields else "GET")).upper()


def elsewhere_named(words, assigns):
    """The other repositories a command reaches by its words: GH_REPO, which points gh at one before the
    command or for the next ones (export, declare -x, env); its API paths; its links; any repository by id."""
    text = assigns + words
    pointed = [w.split("=", 1)[1] for w in text if w.startswith("GH_REPO=")]
    pointed = [n for n in pointed if repo_of(n) not in (None, own)]
    called = [m.group(1) for w in text for m in API_REF.finditer(w) if m.group(1).lower() != own]
    linked = [m.group(1) for w in text for m in LINK_REF.finditer(w) if repo_of(m.group(1)) not in (None, own)]
    by_id = [m.group(0).lstrip("/") for w in text for m in BY_ID.finditer(w)]
    return pointed, called, linked, by_id


def elsewhere_reason(pointed, called, linked, by_id):
    if by_id:
        return f"it calls the API of a repository by its id ({by_id[0]}): whose it is the guard cannot tell"
    if pointed:
        return f"it points gh at {pointed[0]}"
    if called:
        return f"it calls the API of {called[0]}"
    return f"it links {linked[0]}"


def elsewhere_refused(head, words, assigns):
    """Why a command aimed at another repository is refused, or None when it is not aimed at one or may be run.

    A tech lead may read another repository's issues and pull requests and write issues and comments there;
    everything else stays refused, as for a spike.
    """
    pointed, called, linked, by_id = elsewhere_named(words, assigns)
    if by_id:
        return elsewhere_reason(pointed, called, linked, by_id)
    rest, named = words[1:], []
    if head == "gh":
        rest, named = gh_words(rest)
    elif any(w in ("-R", "--repo") or w.startswith("--repo=") for w in rest):
        named = gh_words(rest)[1]
    pointed += [n for n in named if repo_of(n) not in (None, own)]
    text = assigns + words
    if not (pointed or called or linked):
        return None
    # A substitution inside a quoted word, or in backticks, stays in that word: what it runs would ride on the
    # allowed command unseen, so a command carrying one gets no exception.
    plain = head == "gh" and not any(re.search(r"\$\(|`|<\(|>\(", w) for w in text)
    if plain and rest[:1] == ["repo"] and rest[1:2] in (["view"], ["clone"]):
        return None
    allowed = role == "tech-lead" and plain
    if allowed and tuple(rest[:2]) in GH_ELSEWHERE:
        return None
    if allowed and rest[:1] == ["api"] and not pointed:
        # Its endpoint decides; the repositories named in its fields (key=value) are data. Any other word that
        # names another repository's API counts as an endpoint, so an unknown option cannot hide the real one,
        # and has to be one the guard reads plainly: no port, no ./ before it, no . or .. in its path.
        method = api_method(rest)
        for w in rest[1:]:
            if FIELD.match(w) or not any(r.lower() != own for r in API_REF.findall(w)):
                continue
            m = ENDPOINT.match(w)
            path = (m.group(2) or "") if m else ""
            if not m or re.search(r"(^|/)\.\.?(/|$)", path) or m.group(1).lower() == own:
                return f"{w} reaches another repository's API in a form the guard does not read: write repos/<owner>/<name>/..."

            if method == "GET" and re.match(r"^/(issues|pulls)(/|$)", path):
                continue
            if method == "POST" and POST_ELSEWHERE.match(path):
                continue
            if method == "PATCH" and PATCH_ELSEWHERE.match(path):
                continue
            return (f"{method} {w} is not for this repository: on {m.group(1)} it reads issues and pull requests "
                    "and writes issues and comments only")
        return None
    return elsewhere_reason(pointed, called, linked, by_id)


def unreadable_query(query):
    """A GraphQL query the guard cannot read: from a file or stdin (@), or holding what the shell fills in.

    A query's own variables are `$name` too, but the query declares each one (`$name:`): any other `$` is the
    shell's, as are a substitution and backticks.
    """
    if query[:1] == "@" or "`" in query or re.search(r"\$(?![A-Za-z_])", query):
        return True
    return bool(set(re.findall(r"\$(\w+)", query)) - set(re.findall(r"\$(\w+)\s*:", query)))


def graphql_refused(head, words):
    """Why a command sends GitHub's GraphQL API a mutation typed by hand, or a query the guard cannot read."""
    rest = gh_words(words[1:])[0] if head == "gh" else []
    if rest[:1] == ["api"] and any(GRAPHQL.search(w) for w in rest[1:] if not FIELD.match(w)):
        if any(MUTATION.search(w) for w in rest):
            return "a GraphQL mutation changes GitHub: here only queries are typed by hand"
        unread = [w for w in rest if w == "--input" or w.startswith("--input=")]
        unread += [w for w in rest if "query=" in w and unreadable_query(w.split("query=", 1)[1])]
        if unread:
            return f"the GraphQL query comes from where the guard cannot read it ({unread[0]}): type it in the command"
        return None
    if any("graphql" in w.lower() for w in words) and any(MUTATION.search(w) for w in words):
        return "a GraphQL mutation changes GitHub: here only queries are typed by hand"
    return None


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
        # Never another repository through them, by a link, an API path or GH_REPO: they would write there as
        # this repository's session. Their own --repo signs what they write there.
        named = elsewhere_named(words, assigns)
        if any(named):
            refuse(elsewhere_reason(*named))
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

    why = elsewhere_refused(head, words, assigns) or graphql_refused(head, words)
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
        if sub[:1] == ["repo"] and sub[1:2] and sub[1] not in GH_REPO_READS:
            refuse(f"gh repo {sub[1]} changes a repository; here a repository is only viewed or cloned")
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
