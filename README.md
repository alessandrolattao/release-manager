# release-manager

A release manager for one repository, as a [Claude Code](https://code.claude.com) plugin. Start it as a background session, from the main checkout:

```sh
claude --bg --name "release manager" "/release-manager:run"
```

Open it with `claude attach "release manager"` or from `claude agents`. Its color tells you its state: green while it works, yellow while it waits on its agents or CI, red when it waits for you. Its agents are named after their state and branch, so `claude agents` reads like a board: `[dev]`, `[review]`, `[test]`, `[fix]`, `[ask]`, `[done]`; finished ones lose their color and stay out of the way.

and it works through your GitHub issues on its own:

1. Takes the open issue assigned to you with the highest Priority (Urgent, High, Medium, Low) that nothing blocks (GitHub "blocked by" relationships) and that is not waiting on you (`question` label). Issues without a Priority are the backlog: it leaves them alone.
2. Checks that the technical decisions are in the issue's comments. If they are not, it does not start: it asks you.
3. Creates the linked branch and a worktree, and starts a background developer agent named `[dev] <n>-<slug>`, at most 2 at once, fewer when [clessidra](https://github.com/alessandrolattao/clessidra) says the plan usage would run out before it resets.
4. Answers the agent's questions only with what is written (issue comments, repository rules, product docs).
5. When the agent opens its pull request, tests it in the main checkout (the browser for what a person sees, the right tool otherwise), merges it when it passes, or sends the bugs back. After 3 failed rounds it asks you.
6. Starts over. With nothing left to do it tells you once and looks again every 15 minutes.

It also opens issues, for you or for whoever the repository's `.md` files name, with Priority and Effort set.

## Preparing the work

```
/release-manager:plan
```

The other half: you talk with Claude (a backlog review, a new project, the technical analysis of an issue) and it turns what you decide into issues the release manager can take: written with the repository's conventions, assigned, with Priority, Effort, "blocked by" relationships and the technical decisions in a comment. It reads the release manager's own rules and the repository's skills first, shows you everything before publishing, writes only the decisions you took, and ends by telling you which issues are ready and which are not.

## The model chooses, the plugin does

Claude only makes the choices: which issue, what to answer, whether a test passed. Everything that follows from a choice is a script or a hook, so it cannot be forgotten: the release manager's color comes from hooks on its own turns, an agent moves to `[review]` when a hook sees it open its pull request or push its fixes, and every other step (start an agent, test, fail, merge, ask) is one script that also renames the agent, moves the board and calls you through TitTieS.

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
- `python3`, for the session colors.

How a repository is developed and tested comes from the repository itself: its CLAUDE.md files and skills. Priority and Effort are GitHub organization issue fields; repositories of a personal account have none.

## License

GPL-3.0-or-later.
