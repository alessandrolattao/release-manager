// The values the hooks module keeps in $.state, drawn by the board pane of a tech lead.

export type BoardRow = {
  id: string
  // What the board shows: "tech lead", "tech lead admin-app", "dev #318", "qa #42", "spike flaky ci".
  label: string
  // The session's own name, for `claude attach`.
  session: string
  role: string
  state: string
  place: string
  detail: string
  since: number
}

export type BoardSummary = {
  checkout: string
  developers: string
  queue: string
  ci: string
  capacity: string
}

export type Board = {
  repo: string
  rows: BoardRow[]
  summary: BoardSummary | null
  updated: number
}

declare module 'claude-code' {
  interface PluginState {
    team: { board: Shaped<Board> }
  }
}
