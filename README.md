# team

A development team of Claude Code sessions for one repository, as a [Claude Code](https://code.claude.com) plugin. You are the product owner: you decide what to build and take the technical decisions. The team does the rest.

```sh
claude --bg --name "tech lead" "/team:tech-lead"            # the one you talk to
claude --bg --name "tech lead" "/team:tech-lead admin-app"  # another one, on its own topic
```

## Who is in the team

- **Tech leads**, the sessions you talk to, one per topic when several work in parallel. Each follows the issues you give it ("let's work on #3": from then on #3 is its own, and its developer's questions reach it). A tech lead designs with you, prepares its issues, smooths its developers' work, and starts **spikes** (`spike · …`), read-only background sessions, for the technical analyses you ask for. It never develops, and a hook makes sure of it. New issues and the first technical decision of an issue are always taken with you; on an issue that already has decisions it takes the next ones when they follow from those and it has no doubt.
- **Developers** (`dev #<n> · …`), one per issue, in their own worktree. A developer reads the issue and its `## Technical decisions`, builds and tests the change, opens the pull request, follows its reviews, merges it and watches the default branch's CI. Whatever needs the running stack (sst dev, a server) runs in the main checkout, one agent at a time, through a lock with a queue. Before merging, a reviewer with a clean context checks the change against the decisions.
- **QA agents** (`qa #<n> · …`) for the delicate issues, the ones with the label `qa`: a second agent tests the pull request before its merge.

Developers start by themselves. Every minute a dispatcher (a process of its own, not a model) starts one on the next workable issue: assigned to you, labelled `ready for development`, nothing blocking it, no `question`, best priority first. There is no cap: what is ready is what you want built, so you decide the pace by what you mark ready. The board's summary shows how long the plan usage lasts at this pace, as [clessidra](https://github.com/alessandrolattao/clessidra) estimates it. The same dispatcher wakes the sessions with the comments written to them and keeps the board's summary.

The dispatcher runs only when you start it, one per repository on each machine that works on it: click its red `stopped` row in the board's summary, or run `/team:dispatcher` in a Claude Code session in the repository's checkout (`/team:dispatcher stop` stops it, `status` tells). It goes on after that session ends; after a restart of the machine it stays stopped until you start it again. After a plugin update, restart it to run the new version: the summary shows the version it runs.

## GitHub is where the team talks

Every exchange about an issue is a comment on it or on its pull request. Its first line says who writes to whom (`**dev #42 → tech lead admin-app**`), and the plugin wakes the session it is written to. You talk only with the tech leads, in their chat: the agents write to each other and to the tech lead, never to you. A tech lead answers what it already knows and brings you the rest; when it waits on you, Claude Code notifies you. The one exception is a permission prompt inside an agent's session, which needs your click there. Messages between repositories, which no session may touch on GitHub, go through a small inbox.

## Colors and the board

Every session has the color of its state, in `claude agents` too:

- **cyan**: working;
- **purple**: waiting on another agent or on the main checkout;
- **yellow**: waiting on you;
- **red**: stuck (its session died, a turn failed, or a developer, QA agent or spike has been silent for 20 minutes with nothing to wait for);
- **green**: idle, a tech lead with nothing in progress, waiting for work;
- **no color**: done. It goes away soon after, with its worktree; its conversation stays (`claude --resume`).

A color changes between turns: during a long turn the list shows the state of the turn before. The **board** beside a tech lead, a pane that opens by itself on a wide terminal or with `/team-board`, is always live: the project's name in a TEAM dialog, as in the DOS programs of the 80s and 90s, then the agents grouped by state (waiting on you, working, waiting on others, stuck, idle), each name on the color of its state with where it works (its worktree or the main checkout) and for how long, what it does under it, and at the bottom a SUMMARY dialog in the same style with the dispatcher, the checkout lock, the developers at work, the queue, the default branch's CI and how long the plan usage lasts (green when it lasts until the reset, red when it runs out first). When it does not fit, it scrolls (the wheel, or the keys while it has the focus). To open an agent, pick it in the agent view (← on an empty prompt): the names are the same.

## Rules

A rule holds for everyone, on every machine. A general one lives in this plugin, in what each role is told; one about a project lives in that repository's own instructions (its `CLAUDE.md` and skills), which the developers read before they work. When you give the tech lead a rule that holds from now on, it opens an issue for it in the right place.

## When something goes wrong

After a restart of the machine, the first Claude Code session that starts resumes the tech leads that were running, and their dispatcher resumes the developers and QA agents. When a session meets a problem of the plugin itself, it reports it as an issue on this repository, describing the plugin only.

## Install

```
/plugin install team --marketplace alessandrolattao/team
```

Needs:

- Claude Code with background sessions (`claude --bg`, `claude agents`) and plugin hooks modules (`modules` in `hooks/hooks.json`, an early-access API).
- [`gh`](https://cli.github.com), logged in, `jq` and `python3`.
- [clessidra](https://github.com/alessandrolattao/clessidra) to read the plan usage (without it, one developer at a time).

How a repository is developed and tested comes from the repository itself: its CLAUDE.md files and skills. Priority and Effort are GitHub organization issue fields; repositories of a personal account have none.

## License

GPL-3.0-or-later.
