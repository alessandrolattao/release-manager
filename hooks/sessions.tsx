import { atom, read, update } from 'claude-code'
import type { ApiContentBlock, EngineInterface, Register } from 'claude-code'

import type { Board, BoardRow } from '../types'

// Every team session's look, and a tech lead's board.
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
//   - in a tech lead it draws the board (/team-board opens it): the agents of the repository by state, and a
//     summary with the dispatcher, a process of its own (scripts/dispatcher.sh) started by hand, which a
//     click on its row starts when it is stopped.

const TICK_MS = 2000
const ALIVE_EVERY_TICKS = 30
const BOARD_EVERY_TICKS = 2
const DISPATCHER_START_MS = 30000
const DISPATCHER_ALIVE_S = 660
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

const board = atom({ plugin: 'team', key: 'board' } as const, { repo: '', rows: [], summary: null, dispatcher: { running: false, version: '' }, updated: 0 }, {
  shape: 'board-4',
})

let stateRoot: string | undefined
let isBusy = false
let isSyncing = false
let isStartingDispatcher = false
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
  stage?: string
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

// Starts this repository's dispatcher on this machine, when the user clicks its stopped row on the board: a
// process of its own (scripts/dispatcher.sh), which goes on after this session ends.
async function startDispatcher($: EngineInterface): Promise<void> {
  if (isStartingDispatcher) {
    return
  }
  isStartingDispatcher = true
  try {
    const folder = await folderOf($)
    const cwd = (await readText($, `${folder}/cwd`)) || (await $.session.cwd())
    const ran = await $.process.run(['sh', `${$.plugin.root}/scripts/dispatcher.sh`, 'start'], { cwd, timeoutMs: DISPATCHER_START_MS })
    $.ui.toast((ran.exitCode === 0 ? ran.stdout : ran.stderr || ran.stdout).trim() || 'dispatcher: no answer')
    const status = await readStatus($, folder)
    if (status.repo) {
      await refreshBoard($, status.repo)
    }
  } catch (err) {
    $.ui.log(`dispatcher: ${String(err)}`)
    $.ui.toast('the dispatcher did not start: see the log in its state folder')
  } finally {
    isStartingDispatcher = false
  }
}

// The board's windows: dialogs of the DOS programs of the 80s and 90s (dialogRows), one for the title and
// one for the summary, 2 columns in from each side of the pane. A row is a list of segments, each drawn
// with its own look.
// A segment with a press is a control: a click on it runs that action.
type Look = 'frame' | 'shadow' | 'label' | 'text' | 'strong' | 'ok' | 'alert'
type Press = 'start-dispatcher'
type Segment = { text: string; look: Look; press?: Press }
type Row = Segment[]

const LOOKS: Record<Look, { color?: string; dimColor?: boolean; bold?: boolean }> = {
  frame: { bold: true },
  shadow: { color: 'gray' },
  label: { dimColor: true },
  text: {},
  strong: { bold: true },
  ok: { color: 'green' },
  alert: { color: 'red', bold: true },
}
const SIDE = 2

const width = (row: Row) => row.reduce((n, segment) => n + [...segment.text].length, 0)

// The title: a dialog titled TEAM with the project's name centered in a thin inner frame. Null when the
// pane is too narrow.
function titleRows(name: string, columns: number): Row[] | null {
  const inside = columns - 5 - 2 * SIDE
  const box = inside - 2
  if (box < name.length) {
    return null
  }
  const pad = Math.floor((box - name.length) / 2)
  return dialogRows(
    inside,
    SIDE,
    [
      [{ text: `┌${'─'.repeat(box)}┐`, look: 'frame' }],
      [
        { text: '│', look: 'frame' },
        { text: ' '.repeat(pad), look: 'text' },
        { text: name, look: 'strong' },
        { text: ' '.repeat(box - pad - name.length), look: 'text' },
        { text: '│', look: 'frame' },
      ],
      [{ text: `└${'─'.repeat(box)}┘`, look: 'frame' }],
    ],
    'TEAM',
  )
}

// wrap <text> <width>: the text in lines of at most that many characters, at spaces when it can.
function wrap(text: string, max: number): string[] {
  const lines: string[] = []
  let line = ''
  for (const word of text.split(/\s+/).filter(Boolean)) {
    let rest = word
    while ([...rest].length > max) {
      if (line !== '') {
        lines.push(line)
        line = ''
      }
      lines.push(rest.slice(0, max))
      rest = rest.slice(max)
    }
    if (line === '') {
      line = rest
    } else if ([...line].length + 1 + [...rest].length <= max) {
      line = `${line} ${rest}`
    } else {
      lines.push(line)
      line = rest
    }
  }
  lines.push(line)
  return lines
}

// dialogRows <inside width> <left margin> <rows> <title>: a dialog of the DOS programs of the 80s and 90s,
// one double frame with its title centered in the top border, a clean inside with a space of margin, and a
// drop shadow; 5 columns wider than its inside, after the margin.
function dialogRows(inside: number, left: number, content: Row[], title: string): Row[] {
  const margin: Segment = { text: ' '.repeat(left), look: 'text' }
  const across = inside + 2
  const before = Math.max(1, Math.floor((across - title.length - 2) / 2))
  const after = Math.max(1, across - title.length - 2 - before)
  return [
    [
      margin,
      { text: `╔${'═'.repeat(before)} `, look: 'frame' },
      { text: title, look: 'strong' },
      { text: ` ${'═'.repeat(after)}╗`, look: 'frame' },
    ],
    ...content.map((row): Row => [
      margin,
      { text: '║ ', look: 'frame' },
      ...row,
      { text: ' '.repeat(Math.max(0, inside - width(row))), look: 'text' },
      { text: ' ║', look: 'frame' },
      { text: '▓', look: 'shadow' },
    ]),
    [margin, { text: `╚${'═'.repeat(across)}╝`, look: 'frame' }, { text: '▓', look: 'shadow' }],
    [margin, { text: ' ', look: 'text' }, { text: '▓'.repeat(across + 2), look: 'shadow' }],
  ]
}

// The summary: a dialog across the pane with 2 columns of room on each side, one
// row per item, long values wrapped inside it, never cut. Null when the pane is too narrow.
type Item = { label: string; value: string; look?: Look; press?: Press }

// toneLook: the look of a usage window's tone, green when it lasts, red when it runs out first.
const toneLook = (tone: string): Look => (tone === 'ok' ? 'ok' : tone === 'alert' ? 'alert' : 'text')

function summaryRows(items: Item[], columns: number): Row[] | null {
  const inside = columns - 5 - 2 * SIDE
  const room = inside - 12
  if (room < 8) {
    return null
  }
  const content: Row[] = []
  for (const item of items) {
    wrap(item.value, room).forEach((part, i) => {
      content.push([
        { text: (i === 0 ? item.label : '').padEnd(11), look: 'label' },
        { text: ' ', look: 'text' },
        { text: part, look: item.look ?? 'text', press: item.press },
      ])
    })
  }
  return dialogRows(inside, SIDE, content, 'SUMMARY')
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
      stage: status.stage ?? '',
      detail: status.detail ?? '',
      since: status.since ?? 0,
    })
  }
  rows.sort((a, b) => (ORDER[a.role] ?? 9) - (ORDER[b.role] ?? 9) || a.label.localeCompare(b.label, undefined, { numeric: true }))
  let summary: Board['summary'] = null
  const key = repo.replace('/', '_')
  try {
    const written = JSON.parse(await $.fs.read(`${root}/repos/${key}/board.json`)) as {
      checkout?: { holder?: string; waiting?: string }
      queue?: { ready?: number; next?: string; backlog?: number; questions?: number }
      ci?: string
      developers?: { busy?: number }
      usage?: { h5?: { text?: string; tone?: string }; d7?: { text?: string; tone?: string } }
      elsewhere?: { issue: number; host: string; stage?: string; state: string; detail: string; since: number }[]
    }
    // The developers of other machines, as the dispatcher guesses them from GitHub (scripts/dispatch.sh).
    for (const remote of written.elsewhere ?? []) {
      rows.push({
        id: `remote-${remote.issue}`,
        label: `dev #${remote.issue}`,
        role: 'dev',
        state: remote.state,
        place: `other PC ${remote.host}`,
        stage: remote.stage ?? '',
        detail: remote.detail,
        since: remote.since,
      })
    }
    rows.sort((a, b) => (ORDER[a.role] ?? 9) - (ORDER[b.role] ?? 9) || a.label.localeCompare(b.label, undefined, { numeric: true }))
    const waiting = written.checkout?.waiting ? ` · queued: ${written.checkout.waiting}` : ''
    summary = {
      checkout: `${written.checkout?.holder || 'free'}${waiting}`,
      developers: `${written.developers?.busy ?? 0} at work`,
      queue: `${written.queue?.ready ?? 0} ready · ${written.queue?.backlog ?? 0} backlog${written.queue?.next ? ` · next ${written.queue.next}` : ''}`,
      ci: written.ci ?? '?',
      usage5h: { text: written.usage?.h5?.text || 'unreadable', tone: written.usage?.h5?.tone ?? 'text' },
      usage7d: { text: written.usage?.d7?.text || 'unreadable', tone: written.usage?.d7?.tone ?? 'text' },
    }
  } catch {
    summary = null
  }
  const now = Math.floor((await $.clock.now()) / 1000)
  // The dispatcher runs when its last cycle is recent (scripts/dispatcher.sh writes it at each one).
  const lastCycle = Number(await readText($, `${root}/repos/${key}/dispatcher.alive`)) || 0
  const dispatcher = {
    running: now - lastCycle <= DISPATCHER_ALIVE_S,
    version: await readText($, `${root}/repos/${key}/dispatcher.version`),
  }
  await update($, board, () => ({ repo, rows, summary, dispatcher, updated: now }))
}

// The plugin's version, read once from its manifest, for the foot of the board.
let pluginVersion: string | undefined
async function versionOf($: EngineInterface): Promise<string> {
  if (pluginVersion === undefined) {
    try {
      const manifest = JSON.parse(await $.fs.read(`${$.plugin.root}/.claude-plugin/plugin.json`)) as { version?: string }
      pluginVersion = manifest.version ?? ''
    } catch {
      pluginVersion = ''
    }
  }
  return pluginVersion
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
    const { Box, Text, Button } = $.ui.resolve(e)
    const data: Board = await read($, board)
    const now = Math.floor((await $.clock.now()) / 1000)
    // Every agent is drawn: the pane's body scrolls (the wheel, or the keys while the pane has the focus).
    const groups = GROUPS.map(group => {
      const shown = data.rows.filter(row => row.state === group.state)
      return { ...group, count: shown.length, shown }
    }).filter(group => group.shown.length > 0)
    const columns = Math.max(24, e.props.bodyColumns)
    const project = data.repo.split('/')[1] ?? '...'
    const title = titleRows(project, columns)
    const summary = data.summary
    // The dispatcher first: stopped, in red, it is a control that starts it.
    const dispatcher: Item = data.dispatcher.running
      ? { label: 'dispatcher', value: `running${data.dispatcher.version ? ` · team ${data.dispatcher.version}` : ''}`, look: 'ok' }
      : { label: 'dispatcher', value: 'stopped · click to start', look: 'alert', press: 'start-dispatcher' }
    const items: Item[] =
      summary === null
        ? [dispatcher, { label: '', value: 'the dispatcher has not written its summary yet' }]
        : [
            dispatcher,
            { label: 'checkout', value: summary.checkout },
            { label: 'developers', value: summary.developers },
            { label: 'queue', value: summary.queue },
            { label: 'main CI', value: summary.ci },
            { label: 'usage 5h', value: summary.usage5h.text, look: toneLook(summary.usage5h.tone) },
            { label: 'usage 7d', value: summary.usage7d.text, look: toneLook(summary.usage7d.tone) },
          ]
    const bottom = summaryRows(items, columns)
    const version = await versionOf($)
    const footer = version === '' ? 'team' : `team ${version}`
    const segmentOf = (segment: Segment, key: string) => (
      <Text key={key} {...LOOKS[segment.look]}>
        {segment.text}
      </Text>
    )
    // A row holding a control is laid out in a row of its parts, the control a Button around its text.
    const draw = (rows: Row[], key: string) =>
      rows.map((row, i) =>
        row.some(segment => segment.press !== undefined) ? (
          <Box key={`${key}-${i}`} flexDirection="row">
            {row.map((segment, j) =>
              segment.press === 'start-dispatcher' ? (
                <Button key={`${key}-${i}-${j}`} plain onPress={() => startDispatcher($)}>
                  {segmentOf(segment, `${key}-${i}-${j}-text`)}
                </Button>
              ) : (
                segmentOf(segment, `${key}-${i}-${j}`)
              ),
            )}
          </Box>
        ) : (
          <Text key={`${key}-${i}`}>{row.map((segment, j) => segmentOf(segment, `${key}-${i}-${j}`))}</Text>
        ),
      )
    return (
      <Box flexDirection="column">
        {title === null ? <Text bold>{project}</Text> : draw(title, 'title')}
        {/* The agents, one column in from each side of the pane. */}
        <Box flexDirection="column" paddingLeft={1} paddingRight={1}>
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
                        {row.stage ? `${row.stage} · ` : ''}
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
        </Box>
        <Box flexDirection="column" marginTop={1}>
          {bottom === null
            ? items.map(item => (
                <Text key={`summary-${item.label}`}>
                  <Text dimColor>{item.label.padEnd(11)}</Text> <Text {...LOOKS[item.look ?? 'text']}>{item.value}</Text>
                </Text>
              ))
            : draw(bottom, 'summary')}
        </Box>
        {/* An empty row, then the version: a Text holding a space, since an empty one takes no height. */}
        <Text> </Text>
        <Text dimColor>
          {' '.repeat(Math.max(0, Math.floor((columns - footer.length) / 2)))}
          {footer}
        </Text>
      </Box>
    )
  })
}
