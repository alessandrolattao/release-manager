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
const COLORS: Record<string, string> = { working: 'cyan', others: 'purple', you: 'yellow', stuck: 'red', idle: 'green', done: 'default' }
const IDLE_DETAIL = 'waiting for work'
// The board: the agents grouped by state, in this order, each name on the background of its state.
const GROUPS: { state: string; title: string }[] = [
  { state: 'you', title: 'WAITING ON YOU' },
  { state: 'working', title: 'WORKING' },
  { state: 'others', title: 'WAITING ON OTHERS' },
  { state: 'stuck', title: 'STUCK' },
  { state: 'idle', title: 'IDLE' },
]
const BACKGROUNDS: Record<string, { bg: string; fg: string }> = {
  you: { bg: 'yellow', fg: 'black' },
  working: { bg: 'cyan', fg: 'black' },
  others: { bg: 'magenta', fg: 'white' },
  stuck: { bg: 'red', fg: 'white' },
  idle: { bg: 'green', fg: 'black' },
}
const ORDER: Record<string, number> = { 'tech-lead': 0, dev: 1, qa: 2, spike: 3 }
// What the board writes before how long an agent has been in its state: "waiting 9m", "idle 1h20m".
const VERBS: Record<string, string> = { you: 'waiting', others: 'waiting', working: 'working', stuck: 'stuck', idle: 'idle' }

const board = atom({ plugin: 'team', key: 'board' } as const, { repo: '', rows: [], summary: null, updated: 0 }, {
  shape: 'board-2',
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
  resume_to?: { state: string; detail: string; since: number }
}

// The detail a turn that starts gives; a turn that ends with it untouched changed nothing.
const TURN_DETAIL = 'at work'

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
    const role = await readText($, `${folder}/role`)
    if (role === '') {
      return
    }
    const now = Math.floor((await $.clock.now()) / 1000)
    await $.fs.write(`${folder}/idle`, isRunning ? '' : `${now}\n`)
    const status = await readStatus($, folder)
    if (isRunning) {
      if (status.state === 'you' || status.state === 'others') {
        // Woken while it waits: working for this turn, and back to the wait when the turn ends with no
        // script having changed the state (an answer that is not there yet, a look at the issue).
        status.resume_to = { state: status.state, detail: status.detail ?? '', since: status.since ?? now }
        status.state = 'working'
        status.detail = TURN_DETAIL
        status.since = now
        await $.fs.write(`${folder}/status`, `${JSON.stringify(status)}\n`)
      } else if (status.state !== 'working' && status.state !== 'done') {
        await setState($, folder, 'working', TURN_DETAIL)
      }
    } else {
      const before = JSON.stringify(status)
      if (status.resume_to !== undefined) {
        const back = status.resume_to
        delete status.resume_to
        if (status.state === 'working' && status.detail === TURN_DETAIL) {
          status.state = back.state
          status.detail = back.detail
          status.since = back.since
        }
      }
      // A tech lead whose turn ends with nothing in progress, no question for the user and nobody to wait
      // on, waits for work: idle (green). A question asks.sh finds afterwards turns it yellow anyway.
      if (role === 'tech-lead' && status.state === 'working' && (status.busy_until ?? 0) < now) {
        status.state = 'idle'
        status.detail = IDLE_DETAIL
        status.since = now
      }
      if (JSON.stringify(status) !== before) {
        await $.fs.write(`${folder}/status`, `${JSON.stringify(status)}\n`)
      }
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

// The board's title: the project's name in a window with a double frame and a drop shadow, on a dithered
// background as wide as the pane, the way an Atari ST dialog sat on its desktop. Each line is split in its
// parts so each gets its own look: background, frame and name, shadow.
type TitleLine = { left: string; frame: string; shadow: string; right: string }

function titleLines(name: string, columns: number): TitleLine[] | null {
  const inner = Math.min(columns - 6, Math.max(name.length + 12, 24))
  if (inner < name.length + 2) {
    return null
  }
  const left = Math.max(1, Math.floor((columns - inner - 3) / 2))
  const right = Math.max(0, columns - left - inner - 3)
  const pad = Math.floor((inner - name.length) / 2)
  const bg = (n: number) => '░'.repeat(n)
  const empty = { left: bg(left), frame: `║${' '.repeat(inner)}║`, shadow: '▓', right: bg(right) }
  return [
    { left: bg(columns), frame: '', shadow: '', right: '' },
    { left: bg(left), frame: `╔${'═'.repeat(inner)}╗`, shadow: '', right: bg(right + 1) },
    empty,
    { left: bg(left), frame: `║${' '.repeat(pad)}${name}${' '.repeat(inner - pad - name.length)}║`, shadow: '▓', right: bg(right) },
    empty,
    { left: bg(left), frame: `╚${'═'.repeat(inner)}╝`, shadow: '▓', right: bg(right) },
    { left: bg(left + 1), frame: '', shadow: '▓'.repeat(inner + 2), right: bg(right) },
    { left: bg(columns), frame: '', shadow: '', right: '' },
  ]
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
    const label =
      status.role === 'tech-lead'
        ? `tech lead${status.topic ? ` ${status.topic}` : ''}`
        : status.role === 'spike'
          ? `spike ${status.topic ?? ''}`.trim()
          : `${status.role} #${status.issue ?? '?'}`
    rows.push({
      id: entry.name,
      label,
      role: status.role,
      state: status.state ?? 'working',
      place: status.place ?? '',
      detail: status.detail ?? '',
      since: status.since ?? 0,
    })
  }
  rows.sort((a, b) => (ORDER[a.role] ?? 9) - (ORDER[b.role] ?? 9) || a.label.localeCompare(b.label, undefined, { numeric: true }))
  let summary: Board['summary'] = null
  try {
    const key = repo.replace('/', '_')
    const written = JSON.parse(await $.fs.read(`${root}/repos/${key}/board.json`)) as {
      checkout?: { holder?: string; waiting?: string }
      queue?: { ready?: number; next?: string; backlog?: number; questions?: number }
      ci?: string
      capacity?: string
      developers?: { busy?: number; max?: number }
    }
    const waiting = written.checkout?.waiting ? ` · queued: ${written.checkout.waiting}` : ''
    summary = {
      checkout: `${written.checkout?.holder || 'free'}${waiting}`,
      developers: `${written.developers?.busy ?? 0}/${written.developers?.max ?? 0}`,
      queue: `${written.queue?.ready ?? 0} ready · ${written.queue?.backlog ?? 0} backlog${written.queue?.next ? ` · next ${written.queue.next}` : ''}`,
      ci: written.ci ?? '?',
      capacity: written.capacity ?? '?',
    }
  } catch {
    summary = null
  }
  const now = Math.floor((await $.clock.now()) / 1000)
  await update($, board, () => ({ repo, rows, summary, updated: now }))
}

async function openBoard($: EngineInterface): Promise<void> {
  await $.ui.open({ id: PANE, title: 'Team' })
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
      // An agent silent for 20 minutes while it should be working: stuck. Not a tech lead: waiting for the
      // user or the team is its normal state, and a dead one turns red through the dispatcher.
      const idleSince = Number(await readText($, `${folder}/idle`))
      if (role !== 'tech-lead' && !isBusy && status.state === 'working' && idleSince > 0 && now - idleSince > STUCK_AFTER_S && (status.busy_until ?? 0) < now) {
        await setState($, folder, 'stuck', `silent for ${age(idleSince, now)} with nothing to wait for`)
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
    await setState($, folder, 'stuck', reason === 'refusal' ? 'the model refused' : 'API error or usage limit')
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
    const { Box, Text } = $.ui.resolve(e)
    const data: Board = await read($, board)
    const now = Math.floor((await $.clock.now()) / 1000)
    // Every agent is drawn: the pane's body scrolls (the wheel, or the keys while the pane has the focus).
    const groups = GROUPS.map(group => {
      const shown = data.rows.filter(row => row.state === group.state)
      return { ...group, count: shown.length, shown }
    }).filter(group => group.shown.length > 0)
    const summary = data.summary
    const line = (label: string, value: string) => (
      <Text>
        <Text dimColor>{label.padEnd(11)}</Text>
        {value}
      </Text>
    )
    const project = data.repo.split('/')[1] ?? '...'
    const title = titleLines(project, Math.max(24, e.viewport?.columns ?? 60))
    return (
      <Box flexDirection="column">
        {title === null ? (
          <Text bold>{project}</Text>
        ) : (
          title.map((part, i) => (
            <Text key={`title-${i}`}>
              <Text color="gray" dimColor>
                {part.left}
              </Text>
              <Text bold>{part.frame}</Text>
              <Text color="gray">{part.shadow}</Text>
              <Text color="gray" dimColor>
                {part.right}
              </Text>
            </Text>
          ))
        )}
        {data.rows.length === 0 && <Text dimColor>No agents at work.</Text>}
        {groups.map(group => (
          <Box key={group.state} flexDirection="column" marginTop={1}>
            <Text bold>
              {group.title} ({group.count})
            </Text>
            {group.shown.map(row => {
              const look = BACKGROUNDS[row.state] ?? { bg: 'gray', fg: 'white' }
              return (
                <Box key={row.id} flexDirection="column">
                  <Box flexDirection="row">
                    <Text backgroundColor={look.bg} color={look.fg}> {row.label} </Text>
                    <Text dimColor>
                      {'  '}
                      {row.place ? `${row.place} · ` : ''}
                      {`${VERBS[row.state] ?? row.state} ${age(row.since, now)}`}
                    </Text>
                  </Box>
                  {row.detail !== '' && (
                    <Box paddingLeft={2}>
                      <Text wrap="wrap">
                        {row.detail}
                      </Text>
                    </Box>
                  )}
                </Box>
              )
            })}
          </Box>
        ))}
        <Box flexDirection="column" marginTop={1}>
          <Text bold>SUMMARY</Text>
          {summary === null ? (
            <Text dimColor>the dispatcher has not written its summary yet</Text>
          ) : (
            <>
              {line('checkout', summary.checkout)}
              {line('developers', summary.developers)}
              {line('queue', summary.queue)}
              {line('main CI', summary.ci)}
              {line('capacity', summary.capacity)}
            </>
          )}
        </Box>
      </Box>
    )
  })
}
