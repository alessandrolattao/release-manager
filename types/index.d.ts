// The values the hooks module keeps in $.state, drawn by the board pane of a tech lead and by the pane of a
// developer.

export type BoardRow = {
  id: string
  // What the board shows: "tech lead", "tech lead admin-app", "dev #318", "review #42", "qa #42", "spike flaky ci".
  label: string
  role: string
  state: string
  place: string
  // Where the issue stands, for a developer, a reviewer or a QA agent: in progress, in review.
  stage: string
  detail: string
  since: number
}

export type BoardSummary = {
  checkout: string
  developers: string
  queue: string
  ci: string
  // How long the plan usage lasts at this pace, as clessidra estimates it, per window: the text, and its
  // tone (ok: it lasts, alert: it runs out first, text: too early to say).
  usage5h: BoardUsage
  usage7d: BoardUsage
}

// alt, when set (above 90% used), alternates with text on the board: when the window resets.
export type BoardUsage = { text: string; alt: string; tone: string }

// This repository's dispatcher on this machine: running when its last cycle is recent.
export type BoardDispatcher = {
  running: boolean
  version: string
}

export type Board = {
  dispatcher: BoardDispatcher
  repo: string
  rows: BoardRow[]
  summary: BoardSummary | null
  updated: number
}

// A developer's pull request, as GitHub listed it for its branch.
export type DevPr = {
  number: number
  title: string
  url: string
  // As GitHub writes it: OPEN, MERGED, CLOSED.
  state: string
  // The checks of its head: how many, how many failed, how many still running.
  checks: { total: number; failed: number; pending: number }
}

// The developer's branch against the default branch, from git in its worktree.
export type DevWork = { commits: number; files: number; added: number; removed: number }

// What a developer's pane shows: its issue, branch, pull request, work and state, and its summary.
export type Dev = {
  repo: string
  issue: number
  title: string
  branch: string
  // The issue's own GitHub status (Todo, In progress, In review, Done), '' when unknown.
  status: string
  // null when the branch has no pull request yet.
  pr: DevPr | null
  // When GitHub was last read for the status and the pull request, 0 before the first read.
  read: number
  // null when git could not tell.
  work: DevWork | null
  state: string
  detail: string
  since: number
  checkout: string
  review: string
  ci: string
  updated: number
}

declare module 'claude-code' {
  interface PluginState {
    // latest: the plugin's newest published version, when it is newer than the one running, else ''.
    // model: this session's model, as /model shows it, and effort: the level its last request to the model
    // carried ('' before the first), for the board's summary and the developer's.
    // dev: a developer session's pane.
    // loaded: true once the module started in this process; a reload keeps it, a new process starts without it.
    team: { board: Shaped<Board>; dev: Shaped<Dev>; latest: string; model: string; effort: string; loaded: boolean }
  }
}
