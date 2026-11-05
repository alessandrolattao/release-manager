# release-manager

A release manager for one repository, as a [Claude Code](https://code.claude.com) plugin. Start it in a session in the main checkout:

```
/release-manager:run
```

and it works through your GitHub issues on its own:

1. Takes the open issue assigned to you with the highest Priority (Urgent, High, Medium, Low) that nothing blocks (GitHub "blocked by" relationships) and that is not waiting on you (`question` label).
2. Checks that the technical decisions are in the issue's comments. If they are not, it does not start: it asks you.
3. Creates the linked branch and a worktree, and starts a background developer agent named after the branch (`claude --bg --name <n>-<slug>`), at most 2 at once, fewer when [clessidra](https://github.com/alessandrolattao/clessidra) says the plan usage would run out before it resets.
4. Answers the agent's questions only with what is written (issue comments, repository rules, product docs).
5. When the agent opens its pull request, tests it in the main checkout (the browser for what a person sees, the right tool otherwise), merges it when it passes, or sends the bugs back. After 3 failed rounds it asks you.
6. Starts over. With nothing left to do it tells you once and looks again every 15 minutes.

It also opens issues, for you or for whoever the repository's `.md` files name, with Priority and Effort set.

## It never decides how

Engineering manager, delivery manager, QA and release manager, yes; tech lead and product owner, no. Every technical doubt stops the work on that point and becomes a question for you: a comment on the issue, the `question` label, and a call out loud through [TitTieS](https://github.com/alessandrolattao/titties) (only for decisions and blocks, never for progress). You answer in the issue and remove `question`; it picks the issue up again.

## Install

```
/plugin install release-manager --marketplace alessandrolattao/release-manager
```

Needs:

- Claude Code with background sessions (`claude --bg`, `claude agents`).
- [`gh`](https://cli.github.com), logged in, and `jq`.
- [clessidra](https://github.com/alessandrolattao/clessidra) to read the plan usage (without it, one agent at a time).
- [TitTieS](https://github.com/alessandrolattao/titties) for the voice (optional).

How a repository is developed and tested comes from the repository itself: its CLAUDE.md files and skills. Priority and Effort are GitHub organization issue fields; repositories of a personal account have none.

## License

GPL-3.0-or-later.
