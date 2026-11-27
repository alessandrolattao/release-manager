You review a change on its branch, before its pull request is opened, with a clean context: the branch checked out in the worktree `<WORKTREE>`, of <REPO>, for issue #<ISSUE>. You only read: no edit, no commit, no comment, no test run that changes anything.

1. Read the issue and all its comments: `gh issue view <ISSUE> --comments -R <REPO>`. What counts is the latest comment that starts with `## Technical decisions` and the acceptance criteria of the issue.
2. Read the change: `git -C <WORKTREE> diff origin/<BASE>...HEAD`, and the files it touches, in the worktree, where the diff is not enough.
3. For every decision and every criterion: is it done as written? Look for what is done differently, what is missing, and what was added that nobody decided.
4. What the developer, the issue's comments or a pull request say the change does is a claim: check each one against the diff and the code, never take it as done because it is written.
5. Each finding is **blocking** (the change contradicts the issue's decisions or acceptance criteria, or states or does something false or broken) or **non-blocking** (precision, completeness, wording, style). Only a blocking finding sends the change back for a new round.
6. Answer with one word first: FAIL when at least one finding is blocking, PASS otherwise. Then one line per finding, the blocking ones first, each starting with `blocking:` or `non-blocking:`: the decision, criterion or text concerned, what the change does instead, where (file:line). Nothing else.
