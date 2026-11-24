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

Developers start by themselves. Every minute a dispatcher (a script, not a model) starts one on the next workable issue: assigned to you, labelled `ready for development`, nothing blocking it, no `question`, best priority first, within capacity (2 at once by default, fewer when [clessidra](https://github.com/alessandrolattao/clessidra) says the plan usage would run out before it resets).

## GitHub is where the team talks

Every exchange about an issue is a comment on it or on its pull request. Its first line says who writes to whom (`**dev #42 → tech lead admin-app**`), and the plugin wakes the session it is written to. When a session needs you, it mentions you, so GitHub notifies you, adds `question` to the issue, and stops, so Claude Code notifies you too. Messages between repositories, which no session may touch on GitHub, go through a small inbox.

## Colors and the board

Every session has the color of its state, in `claude agents` too:

- **cyan**: working;
- **purple**: waiting on another agent or on the main checkout;
- **yellow**: waiting on you;
- **red**: stuck (its session died, a turn failed, or a developer, QA agent or spike has been silent for 20 minutes with nothing to wait for);
- **green**: idle, a tech lead with nothing in progress, waiting for work;
- **no color**: done. It goes away soon after, with its worktree; its conversation stays (`claude --resume`).

A color changes between turns: during a long turn the list shows the state of the turn before. The **board** beside a tech lead, a pane that opens by itself on a wide terminal or with `/team-board`, is always live: the agents grouped by state (waiting on you, working, waiting on others, stuck, idle), each name on the color of its state with where it works (its worktree or the main checkout) and for how long, what it does under it, and at the bottom the checkout lock, the developers, the queue, the default branch's CI and the capacity. Clicking a name opens that session in the same terminal (`/resume`); ← on an empty prompt goes back to the agent view.

## Your rules

Your own rules for a repository ("up to 3 agents at once", "this repository keeps a linear history") are yours: they live on this machine, in `~/.local/share/team/rules/`, never in the repository or on GitHub. The tech lead writes them when you state them, and every session reads them at start and after a compaction. A few are read by the scripts: `agents: <n>`, `merge: merge|rebase|squash|user`, `capacity: 5h`.

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
