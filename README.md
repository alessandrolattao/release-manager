# release-manager

A release manager and a planner for one repository, as a [Claude Code](https://code.claude.com) plugin: two background sessions, started from the main checkout.

```sh
claude --bg --name "release manager" "/release-manager:run"   # builds, tests, merges
claude --bg --name planner "/release-manager:planner"          # the one you talk to
```

They rename themselves after the repository, with a counter: `release manager · my-app 🚀3` (merged today) and `planner · my-app 🙋2` (questions waiting for you). Open either from `claude agents`. The release manager's color tells you its state when its turn ends: green when all is well (its agents or CI at work, or nothing to do), orange when it needs you. Its agents are named after their state and branch, so `claude agents` reads like a board: `[dev]`, `[review]`, `[test]`, `[fix]`, `[ask]`, with 🔥 for urgent and 🐛 ✨ 🔧 for bugs, features and tasks; agents are cyan while they work and go away, session and worktree, when their pull request is merged; the planner is purple. Names and colors change between turns, through the plugin's hooks module: nothing is typed into a session, so a message you are writing there is never touched, and no row is left in its conversation.

Each one gets a goal (`/goal`) at every start: the release manager triages and tests every issue the planner assigns to it, coordinating with the planner and the developers; the planner does the technical analyses and sets up the work so the release manager can coordinate development. The goals never come true while the project lives: they keep both awake, waiting for work. After a restart of the machine, the first Claude Code session that starts resumes the release managers and planners that were running when it went down, and each release manager resumes its developer agents.

The release manager works through your GitHub issues on its own:

1. Takes the next open issue assigned to you that is ready: it carries the label `ready for development`, nothing blocks it (GitHub "blocked by" relationships) and it is not waiting on you (`question` label). Priority, when the repository has it, decides the order; otherwise the oldest first. Issues without the label are the backlog: it leaves them alone.
2. Checks that the technical decisions are in the issue's comments. If they are not, it does not start: it asks you.
3. Creates the linked branch and a worktree, and starts a background developer agent named `[dev] <n>-<slug>`, at most 2 at once, fewer when [clessidra](https://github.com/alessandrolattao/clessidra) says the plan usage would run out before it resets.
4. Answers the agent's questions only with what is written (issue comments, repository rules, product docs).
5. When the agent opens its pull request, tests it in the main checkout (the browser for what a person sees, the right tool otherwise), merges it when it passes, or sends the bugs back. After 3 failed rounds it asks you.
6. Watches the CI of the default branch after every merge. When it turns red it opens an urgent bug issue and merges nothing else until it is green again, except the fix.
7. Starts over. With nothing left to do it has the planner tell you once, and looks again every 15 minutes.

It also opens issues, for you or for whoever the repository's `.md` files name; they wait in the backlog until you and the planner mark them ready.

## Preparing the work

The planner works by `/release-manager:plan`, which you can also use in any session: you talk with Claude (a backlog review, a new project, the technical analysis of an issue) and it turns what you decide into issues the release manager can take: written with the repository's conventions, assigned, with Priority, Effort, "blocked by" relationships and the technical decisions in a comment. It reads the release manager's own rules and the repository's skills first, goes on alone with what is mechanical or already discussed with you (labels, fields, writing down your decisions, `ready for development` when every decision of the issue was discussed), stops and asks for anything else, and ends by telling you which issues are ready and which are not.

When something has waited for you for 30 minutes (a question of the planner or of the release manager, a permission prompt that stops the release manager), the planner says it out loud through [TitTieS](https://github.com/alessandrolattao/titties), once, in one short sentence.

A technical analysis or an opinion you ask the planner for is its own work: it starts consultants, read-only background sessions named `[plan] <topic>`, waits for their reports and brings you the options with a recommendation. The release manager only develops.

## The model chooses, the plugin does

Claude only makes the choices: which issue, what to answer, whether a test passed. Everything that follows from a choice is a script or a hook, so it cannot be forgotten: the release manager's color comes from hooks on its own turns, an agent moves to `[review]` when a hook sees it open its pull request or push its fixes, and every other step (start an agent, test, fail, merge, ask) is one script that also renames the agent and moves the board.

## One thread at a time

The release manager and the planner never interrupt each other, or another repository's planner: they leave messages in an inbox (one file per message, Maildir style, under `~/.local/share/release-manager/inbox/`), typed `question`, `unblocked` or `info`, and the receiver's name shows `📨<n>`. The release manager reads its inbox each time it wakes; the planner only when you ask or when a topic is over, so a message never pulls a discussion off course. Only the developer agents talk to the release manager directly.

## It never decides how

Engineering manager, delivery manager, QA and release manager, yes; tech lead and product owner, no. Every technical doubt stops the work on that point and becomes a question for you: a comment on the issue and the `question` label. The planner raises its 🙋 counter; you go through the question with the planner, which writes your decisions on the issue, removes `question` and tells the release manager, which picks the issue up again.

## Install

```
/plugin install release-manager --marketplace alessandrolattao/release-manager
```

Needs:

- Claude Code with background sessions (`claude --bg`, `claude agents`), `/goal` and plugin hooks modules (`modules` in `hooks/hooks.json`, an early-access API).
- [`gh`](https://cli.github.com), logged in, and `jq`.
- [clessidra](https://github.com/alessandrolattao/clessidra) to read the plan usage (without it, one agent at a time).
- TitTieS, optional, for the planner's voice (without it, nothing is said out loud).
- `python3`, for the planner's guard on other repositories.

How a repository is developed and tested comes from the repository itself: its CLAUDE.md files and skills. Priority and Effort are GitHub organization issue fields; repositories of a personal account have none.

## License

GPL-3.0-or-later.
