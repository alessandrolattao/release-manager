import { atom, read, update } from 'claude-code'
import type { ApiContentBlock, EngineInterface, Register } from 'claude-code'

import type { Board, BoardRow } from '../types'

// Every team session's look, and a tech lead's dispatcher and board.
//
// The scripts and hooks write each session's status in its own folder,
// <state>/team/sessions/<session id>/status (scripts/session-dir.sh). This module runs inside every session:
//   - between turns it gives the session the color of its state, with /color through the engine, so nothing
//     reaches the prompt box: cyan working, purple waiting on another agent, yellow waiting on the user,
//     red stuck, none when done; and the name role.sh asked for, with /rename. Their rows are hidden.
//   - a turn that starts means working; one that ends on an error, or a session silent for 20 minutes
//     while it should be working, means stuck.
//   - it writes `alive` every minute (the heartbeat the scripts and hooks/revive.sh read) and `idle`, when
//     the last turn ended, empty during a turn (hooks/session-events.sh wakes a session only between turns).
//   - in a tech lead it runs scripts/dispatch.sh every minute and draws the board, one row per agent of the
//     repository with the color of its state (/team-board opens it).

const TICK_MS = 2000
const ALIVE_EVERY_TICKS = 30
const DISPATCH_EVERY_TICKS = 30
const BOARD_EVERY_TICKS = 2
const DISPATCH_TIMEOUT_MS = 600000
const STUCK_AFTER_S = 20 * 60
const EXPECT_MS = 15000
const PANE = 'team-board'
const COLORS: Record<string, string> = { working: 'cyan', others: 'purple', you: 'yellow', stuck: 'red', done: 'default' }
const DOTS: Record<string, string> = { working: 'cyan', others: 'magenta', you: 'yellow', stuck: 'red', done: 'gray' }
const ORDER: Record<string, number> = { 'tech-lead': 0, dev: 1, qa: 2, spike: 3 }

const board = atom({ plugin: 'team', key: 'board' } as const, { repo: '', rows: [], footer: '', waitingOnUser: 0, updated: 0 }, {
  shape: 'board-1',
})

let stateRoot: string | undefined
let isBusy = false
let isSyncing = false
let isDispatching = false
let isPaneOpened = false
let ticks = 0
const applied = new Map<string, string>()
let expected: { command: string; args: string; until: number }[] = []
const hidden: string[] = []

type Status = {
  role?: string
  repo?: string
  name?: string
  issue?: number
  title?: string
  topic?: string
  place?: string
  state?: string
  detail?: string
  since?: number
  busy_until?: number
}

async function rootOf($: EngineInterface): Promise<string> {
  if (stateRoot === undefined) {
    const state = (await $.env.get('XDG_STATE_HOME')) || `${(await $.env.get('HOME')) ?? ''}/.local/state`
    stateRoot = `${state}/team`
  }
  return stateRoot
}

async function folderOf($: EngineInterface): Promise<string> {
  return `${await rootOf($)}/sessions/${await $.session.id()}`
}

async function readText($: EngineInterface, path: string): Promise<string> {
  try {
    return (await $.fs.read(path)).trim()
  } catch {
    return ''
  }
}

async function readStatus($: EngineInterface, folder: string): Promise<Status> {
  try {
    return JSON.parse(await $.fs.read(`${folder}/status`)) as Status
  } catch {
    return {}
  }
}

// Changes the session's own state the way scripts/session-dir.sh state_set does.
async function setState($: EngineInterface, folder: string, state: string, detail: string): Promise<void> {
  const status = await readStatus($, folder)
  const now = Math.floor((await $.clock.now()) / 1000)
  if (status.state !== state || status.detail !== detail) {
    status.since = now
  }
  status.state = state
  status.detail = detail
  await $.fs.write(`${folder}/status`, `${JSON.stringify(status)}\n`)
}

async function runCommand($: EngineInterface, command: string, args: string): Promise<void> {
  try {
    await $.command.run({ command, args })
  } catch (err) {
    $.ui.log(`/${command} ${args}: ${String(err)}`)
  }
}

// Applies a /color or /rename once, hiding its rows.
async function apply($: EngineInterface, key: string, command: string, value: string, now: number): Promise<void> {
  if (value === '' || applied.get(key) === value) {
    return
  }
  applied.set(key, value)
  expected.push({ command, args: value, until: now + EXPECT_MS })
  hidden.push(`${command} ${value}`)
  hidden.splice(0, Math.max(0, hidden.length - 50))
  await runCommand($, command, value)
}

async function markTurn($: EngineInterface, isRunning: boolean): Promise<void> {
  try {
    const folder = await folderOf($)
    if ((await readText($, `${folder}/role`)) === '') {
      return
    }
    const now = Math.floor((await $.clock.now()) / 1000)
    await $.fs.write(`${folder}/idle`, isRunning ? '' : `${now}\n`)
    const status = await readStatus($, folder)
    if (isRunning && status.state !== 'done') {
      await setState($, folder, 'working', status.state === 'working' ? (status.detail ?? 'lavora') : 'lavora')
    }
  } catch (err) {
    $.ui.log(`turn: ${String(err)}`)
  }
}

async function dispatch($: EngineInterface, folder: string): Promise<void> {
  if (isDispatching) {
    return
  }
  isDispatching = true
  try {
    const cwd = (await readText($, `${folder}/cwd`)) || (await $.session.cwd())
    await $.process.run(['sh', `${$.plugin.root}/scripts/dispatch.sh`], { cwd, timeoutMs: DISPATCH_TIMEOUT_MS })
  } catch (err) {
    $.ui.log(`dispatch: ${String(err)}`)
  } finally {
    isDispatching = false
  }
}

function age(since: number, now: number): string {
  const minutes = Math.max(0, Math.floor((now - since) / 60))
  return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h${minutes % 60 === 0 ? '' : `${minutes % 60}m`}`
}

async function refreshBoard($: EngineInterface, repo: string): Promise<void> {
  const root = await rootOf($)
  const rows: BoardRow[] = []
  let entries: { name: string; kind: string }[] = []
  try {
    entries = (await $.fs.list(`${root}/sessions`)) as { name: string; kind: string }[]
  } catch {
    entries = []
  }
  for (const entry of entries) {
    const status = await readStatus($, `${root}/sessions/${entry.name}`)
    if (status.repo !== repo || !status.role || status.state === 'done') {
      continue
    }
    const what = status.role === 'dev' || status.role === 'qa' ? `${status.issue ?? ''} ${status.title ?? ''}`.trim() : (status.topic ?? '')
    rows.push({
      id: entry.name,
      name: status.role === 'tech-lead' ? `tech lead${what ? ` ${what}` : ''}` : `${status.role} #${what}`,
      role: status.role,
      state: status.state ?? 'working',
      place: status.place ?? '',
      detail: status.detail ?? '',
      since: status.since ?? 0,
    })
  }
  rows.sort((a, b) => (ORDER[a.role] ?? 9) - (ORDER[b.role] ?? 9) || a.name.localeCompare(b.name))
  let footer = ''
  try {
    const key = repo.replace('/', '_')
    const summary = JSON.parse(await $.fs.read(`${root}/repos/${key}/board.json`)) as {
      checkout?: { holder?: string; waiting?: string }
      queue?: { ready?: number; next?: string; backlog?: number; questions?: number }
      ci?: string
      capacity?: string
      developers?: { busy?: number; max?: number }
    }
    const checkout = summary.checkout?.holder ? `checkout: ${summary.checkout.holder}` : 'checkout libero'
    const waiting = summary.checkout?.waiting ? ` · in coda: ${summary.checkout.waiting}` : ''
    footer = `${checkout}${waiting} · developer ${summary.developers?.busy ?? 0}/${summary.developers?.max ?? 0} · pronte ${summary.queue?.ready ?? 0}${summary.queue?.next ? ` (${summary.queue.next})` : ''} · backlog ${summary.queue?.backlog ?? 0} · CI main ${summary.ci ?? '?'} · capacità ${summary.capacity ?? '?'}`
  } catch {
    footer = 'il dispatcher non ha ancora scritto il riepilogo'
  }
  const now = Math.floor((await $.clock.now()) / 1000)
  await update($, board, () => ({ repo, rows, footer, waitingOnUser: rows.filter(r => r.state === 'you').length, updated: now }))
}

async function openBoard($: EngineInterface): Promise<void> {
  await $.ui.open({ id: PANE, title: 'Team' })
}

async function copyAttach($: EngineInterface, name: string): Promise<void> {
  await $.ui.copy({ text: `claude attach "${name}"` })
  $.ui.toast(`copiato: claude attach "${name}"`)
}

async function tick($: EngineInterface): Promise<void> {
  if (isSyncing) {
    return
  }
  isSyncing = true
  try {
    const folder = await folderOf($)
    const role = await readText($, `${folder}/role`)
    if (role === '') {
      return
    }
    const nowMs = await $.clock.now()
    const now = Math.floor(nowMs / 1000)
    expected = expected.filter(x => x.until > nowMs)
    const tickNumber = ticks++
    let status = await readStatus($, folder)
    if (tickNumber % ALIVE_EVERY_TICKS === 0) {
      await $.fs.write(`${folder}/alive`, `${now}\n`)
      // Silent for 20 minutes while it should be working: stuck.
      const idleSince = Number(await readText($, `${folder}/idle`))
      if (!isBusy && status.state === 'working' && idleSince > 0 && now - idleSince > STUCK_AFTER_S && (status.busy_until ?? 0) < now) {
        await setState($, folder, 'stuck', `ferma da ${age(idleSince, now)} senza aspettare niente`)
        status = await readStatus($, folder)
      }
    }
    if (role === 'tech-lead') {
      if (tickNumber % DISPATCH_EVERY_TICKS === 0) {
        void dispatch($, folder)
      }
      if (tickNumber % BOARD_EVERY_TICKS === 0 && status.repo) {
        await refreshBoard($, status.repo)
        if (!isPaneOpened) {
          isPaneOpened = true
          void openBoard($)
        }
      }
    }
    if (!isBusy) {
      await apply($, 'name', 'rename', await readText($, `${folder}/name`), nowMs)
      await apply($, 'color', 'color', COLORS[status.state ?? ''] ?? '', nowMs)
    }
  } catch (err) {
    $.ui.log(`team: ${String(err)}`)
  } finally {
    isSyncing = false
  }
}

async function failedTurn($: EngineInterface, reason: string): Promise<void> {
  const folder = await folderOf($)
  if ((await readText($, `${folder}/role`)) !== '') {
    await setState($, folder, 'stuck', reason === 'refusal' ? 'il modello ha rifiutato' : 'errore API o limite di utilizzo')
  }
}

// A row of one of the module's own /color or /rename runs: the command's echo or its output.
function isExpected(content: readonly ApiContentBlock[]): boolean {
  if (expected.length === 0) {
    return false
  }
  const text = content.map(block => (block.type === 'text' ? block.text : '')).join('')
  return expected.some(
    x =>
      (text.includes(`<command-name>/${x.command}</command-name>`) && text.includes(`<command-args>${x.args}</command-args>`)) ||
      (text.includes('<local-command-stdout>') && text.includes(x.args)),
  )
}

function emptied(content: readonly ApiContentBlock[]): ApiContentBlock[] {
  return content.map(block => (block.type === 'text' ? { ...block, text: '' } : block))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await $.command.register({ name: 'team-board', description: 'Open the team board: every agent of this repository, colored by its state' })
    if (!isBusy) {
      await markTurn($, false)
    }
    $.clock.every(TICK_MS, () => {
      void tick($)
    })
    return result
  })

  on('command.run', { command: 'team-board' }, async $ => {
    await openBoard($)
    return { text: 'Team board opened.' }
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      isBusy = true
      await markTurn($, true)
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) {
      isBusy = false
      await markTurn($, false)
      if (e.reason === 'error' || e.reason === 'refusal') {
        await failedTurn($, e.reason)
      }
      void tick($)
    }
    return result
  })

  on('session.append', { door: 'command' }, ($, e, next) => {
    if (!isExpected(e.message.content)) {
      return next(e)
    }
    return next({ ...e, message: { ...e.message, content: emptied(e.message.content) } })
  })

  on('ui.render', { component: 'CommandOutput' }, ($, e, next) => {
    if (!hidden.includes(`${e.props.command} ${e.props.args}`)) {
      return next(e)
    }
    const { Box } = $.ui.resolve(e)
    return <Box />
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const data: Board = await read($, board)
    const now = Math.floor((await $.clock.now()) / 1000)
    const room = Math.max(3, (e.viewport?.rows ?? 30) - 4)
    const waiting = data.waitingOnUser > 0 ? ` · ${data.waitingOnUser} ti aspett${data.waitingOnUser === 1 ? 'a' : 'ano'}` : ''
    return (
      <Box flexDirection="column">
        <Text bold>TEAM · {data.repo || '...'}{waiting}</Text>
        {data.rows.length === 0 && <Text dimColor>Nessun agente al lavoro.</Text>}
        {data.rows.slice(0, room).map(row => (
          <Button key={row.id} onPress={() => copyAttach($, row.name)}>
            <Text color={DOTS[row.state] ?? 'gray'}>● </Text>
            <Text>{row.name.slice(0, 40)}</Text>
            <Text dimColor>{row.place ? ` ${row.place}` : ''} · </Text>
            <Text>{row.detail.slice(0, 60)}</Text>
            <Text dimColor> {age(row.since, now)}</Text>
          </Button>
        ))}
        <Text dimColor>{data.footer}</Text>
      </Box>
    )
  })
}
