// The values the hooks module keeps in $.state, drawn by the board pane of a tech lead.

export type BoardRow = {
  id: string
  name: string
  role: string
  state: string
  place: string
  detail: string
  since: number
}

export type Board = {
  repo: string
  rows: BoardRow[]
  footer: string
  waitingOnUser: number
  updated: number
}

declare module 'claude-code' {
  interface PluginState {
    team: { board: Shaped<Board> }
  }
}
