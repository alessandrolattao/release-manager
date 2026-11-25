# team

A development team of Claude Code sessions for one repository, as a [Claude Code](https://code.claude.com) plugin. You are the product owner: you decide what to build and take the technical decisions. The team does the rest.

```sh
claude --bg --name "tech lead" "/team:tech-lead"   # the one you talk to, one per repository
```

## Who is in the team

- **The tech lead**, the session you talk to, one per repository: every question about the repository's issues reaches it. It designs with you, prepares its issues, smooths its developers' work, and starts **spikes** (`<repo> · spike · <topic>`), read-only background sessions, for the technical analyses you ask for. It never develops, and a hook makes sure of it. New issues and the first technical decision of an issue are always taken with you; on an issue that already has decisions it takes the next ones when they follow from those and it has no doubt.
- **Developers** (`<repo> · dev #<n> · <title>`), one per issue, in their own worktree. A developer reads the issue and its `## Technical decisions`, builds and tests the change, opens the pull request, follows its reviews, merges it and watches the default branch's CI. Whatever needs the running stack (sst dev, a server) runs in the main checkout, one agent at a time, through a lock with a queue. Before merging, a reviewer with a clean context checks the change against the decisions.
- **QA agents** (`<repo> · qa #<n> · <title>`) for the delicate issues, the ones with the label `qa`: a second agent tests the pull request before its merge.

Developers start by themselves. Every minute a dispatcher (a process of its own, not a model) starts one on the next workable issue: assigned to you, labelled `ready for development`, nothing blocking it, no `question`, best priority first. There is no cap: what is ready is what you want built, so you decide the pace by what you mark ready. The board's summary shows how long the plan usage lasts at this pace, as [clessidra](https://github.com/alessandrolattao/clessidra) estimates it. The same dispatcher wakes the sessions with the comments written to them and keeps the board's summary.

There is one dispatcher per repository on each machine that works on it. The tech lead keeps its machine's running: when it finds it stopped (a restart of the machine, a crash) it starts it again. `/team:dispatcher stop` in a Claude Code session in the repository's checkout stops it until you start it again yourself: click its red `stopped` row in the board's summary, or run `/team:dispatcher` (`status` tells). It goes on after that session ends. After a plugin update, `/team:update` restarts it on the new version; the summary shows the version it runs.

Developers, QA agents and spikes start on the account's default model (`--model default`), whatever model the settings pick. A spike runs on Fable only when you choose it with the tech lead for that analysis. The tech lead's own model is yours to pick with `/model`, and the board's summary shows it with its effort (`Opus 5.5 (xhigh)`).

## GitHub is where the team talks

Every exchange about an issue is a comment on it or on its pull request. Its first line says who writes to whom (`**dev #42 → tech lead**`), and the plugin wakes the session it is written to. No agent takes another's word for it: what one claims is checked against the code, the logs or GitHub before anyone acts on it or repeats it. You talk only with the tech leads, in their chat: the agents write to each other and to the tech lead, never to you. A tech lead answers what it already knows and brings you the rest; when it waits on you, Claude Code notifies you. The one exception is a permission prompt inside an agent's session, which needs your click there. Messages between repositories, which no session may touch on GitHub, go through a small inbox.

## Colors and the board

Every session has the color of its state, in `claude agents` too:

- **cyan**: working;
- **purple**: waiting on another agent or on the main checkout;
- **yellow**: the tech lead waits on you (only the tech lead: the agents never do);
- **red**: stuck (its session died, a turn failed, it waits for a permission prompt, or a developer, QA agent or spike has been silent for 20 minutes with nothing to wait for);
- **green**: idle, a tech lead with nothing in progress, waiting for work;
- **no color**: done. It goes away soon after, with its worktree; its conversation stays (`claude --resume`).

A color changes between turns: during a long turn the list shows the state of the turn before. The **board** beside a tech lead, a pane that opens by itself on a wide terminal or with `/team`, is always live: the project's name in a TEAM dialog, as in the DOS programs of the 80s and 90s, then the agents grouped by state (waiting on you, working, waiting on others, stuck, idle), each name on the color of its state with where it works (its worktree or the main checkout) and for how long, what it does under it, and at the bottom a SUMMARY dialog in the same style with the dispatcher, the checkout lock, the developers at work, the queue, the default branch's CI and how long the plan usage lasts (green when it lasts until the reset; red when it runs out first, with when, or once it ran out, with when it resets; above 90% the line alternates with when the window resets, a few seconds each). When it does not fit, it scrolls (the wheel, or the keys while it has the focus). To open an agent, pick it in the agent view (← on an empty prompt): the names are the same.

## Rules

A rule holds for everyone, on every machine. A general one lives in this plugin, in what each role is told; one about a project lives in that repository's own instructions (its `CLAUDE.md` and skills), which the developers read before they work. When you give the tech lead a rule that holds from now on, it opens an issue for it in the right place.

## Several machines

The team can work on one repository from several machines at once: keep the tech lead on the machine you talk to it from, and start a dispatcher on each of the others (`/team:dispatcher` in the repository's checkout; with no tech lead there, after a restart of the machine you start it again). GitHub is all they share.

- **One machine per issue.** A workable issue is `ready for development` and not started (its own GitHub status is not In progress, In review or Done). Before it starts a developer, a machine takes the issue with a comment, `**dispatcher · <machine>** takes #<n>`, and waits 30 seconds: the oldest take still standing wins, sets the issue's status to In progress (the project's Status follows, when the issue is on a board), and starts; any other deletes its take. The developer sets In review when it opens its pull request; the merge closes the issue.
- **Takeover.** An issue stays In progress while a machine works on it. When one stays there too long (a machine switched off), tell the tech lead to take it over: it releases the issue (`**tech lead** releases #<n>`), which is Todo again, and the first free machine takes it, from its pushed branch.
- **The board** shows the other machines' developers too, with a color read from GitHub: purple while their last message waits for an answer, red after an hour with nothing on the issue, cyan otherwise.
- **One GitHub account.** Every machine uses yours, and its hourly API allowance: the dispatcher reads little (new comments and the queue each minute, the default branch's CI every 5 minutes).
- **The main checkout** is per machine, so tests that need the running stack run on several machines at once. When the repository's tests share cloud resources (an `sst dev` stage), give each machine its own, in the repository's setup.

### Compatibility

Machines may run different versions of the plugin for a while: the lines they exchange are a contract, which only ever grows. A reader ignores what it does not know, and nothing changes meaning.

- `**<from> → <to>**`, the first line of a team message, with ` · fyi` after it when no answer is owed;
- `**dispatcher · <machine>** takes #<n>` and `**<who>** releases #<n>`, the takes;
- `<!-- team · <from> -->`, the hidden last line of a comment a session writes for the record, to nobody in particular (an issue's technical decisions, findings): not the user's;
- the issue's own status: Todo, In progress, In review, Done.

## When something goes wrong

After a restart of the machine, the first Claude Code session that starts resumes the tech leads that were running, they start their dispatcher again (unless you had stopped it), and it resumes the developers and QA agents. When a session meets a problem of the plugin itself, it reports it as an issue on this repository, describing the plugin only.

## Install

```
/plugin install team --marketplace alessandrolattao/team
```

Needs:

- Claude Code with background sessions (`claude --bg`, `claude agents`) and plugin hooks modules (`modules` in `hooks/hooks.json`, an early-access API).
- [`gh`](https://cli.github.com), logged in, `jq` and `python3`.
- [clessidra](https://github.com/alessandrolattao/clessidra) to read the plan usage (without it, one developer at a time).

How a repository is developed and tested comes from the repository itself: its CLAUDE.md files and skills. Priority and Effort are GitHub organization issue fields; repositories of a personal account have none.

## Updating

After a new version is published, run `/team:update` in any Claude Code session on each machine; a tech lead's board looks for one every 30 minutes and offers it at its foot, where a click on `update` does the same. It updates the plugin on every account the team uses there, restarts every live team session on the new version once it is quiet (no turn is cut, the conversation goes on), and restarts the dispatchers that were running. Its log is `~/.local/state/team/update.log`.

## License

GPL-3.0-or-later.
