import { atom, read, update } from 'claude-code'
import type { ApiContentBlock, ElementTable, EngineInterface, Register } from 'claude-code'

import type { Board, BoardRow, Dev, DevPr, DevWork } from '../types'

// Every team session's look, a tech lead's board and a developer's pane.
//
// The scripts and hooks write each session's status in its own folder,
// <state>/team/sessions/<session id>/status (scripts/session-dir.sh). This module runs inside every session:
//   - between turns it gives the session the color of its state, with /color through the engine, so nothing
//     reaches the prompt box: cyan working, purple waiting on another agent, yellow waiting on the user,
//     red stuck, none when done; and the name role.sh asked for, with /rename. Their rows are hidden.
//   - a turn that starts means working; one that ends on an error, or a session silent for 20 minutes
//     while it should be working, means stuck.
//   - it writes `alive` every minute (the heartbeat the scripts and hooks/revive.sh read) and `idle`, when
//     the last turn ended, empty during a turn.
//   - it writes `version`, the plugin version it loaded at session start, once the session's folder has a
//     `role`: at session start, or at the first tick that finds the one role.sh wrote. scripts/update.sh
//     restarts only the sessions behind the newest version installed.
//   - between turns it wakes the session, with a prompt of its own, for what was written to it: a GitHub
//     comment (the dispatcher appends it to `wake`) it has not answered yet on GitHub and GitHub still has,
//     the main checkout freed for it, and in a tech lead the messages other repositories left in its inbox
//     (tell.sh). A session outside the team runs nothing. In a tech lead it records each comment it delivered
//     in the repository's `seen`, as scripts/mentions.sh does for each one it lists: a write to the asker
//     answers a question only once the question has reached the tech lead.
//   - a session whose turn ended on the usage limit is alive and waits: it wakes it once the limit has reset,
//     at the reset time the dispatcher reads for the board's usage line, once per stop, in every role.
//   - a prompt the user writes to a team session means working with them, whatever it waited on.
//   - in a tech lead it draws the board (/team opens it): the agents of the repository by state, and a
//     summary with the dispatcher, a process of its own (scripts/dispatcher.sh), which a click on its row
//     starts when it is stopped.
//   - in a developer it draws the developer's pane (/team opens it), in the board's look: its issue and the
//     issue's own GitHub status, its branch, its pull request with its checks, its work (git in its worktree,
//     at every refresh), its state, and a summary with the checkout, the reviews, the default branch's CI and
//     its model. The status and the pull request come from GitHub at most every 5 minutes, cached in the
//     session's folder (`github`). A QA agent or a spike has none.
//   - a tech lead looks every 30 minutes for a newer version of the plugin, published on its repository's
//     default branch; the board's foot offers it, and a click runs /team:update (scripts/update.sh).
//   - a tech lead keeps that dispatcher running: stopped (a restart of the machine, a crash), it starts it
//     again; one the user stopped by hand stays stopped until the user starts it.

const TICK_MS = 2000
const ALIVE_EVERY_TICKS = 30
const BOARD_EVERY_TICKS = 2
const ALTERNATE_S = 4
const DISPATCHER_START_MS = 30000
const DISPATCHER_ALIVE_S = 660
// A dispatcher the tech lead could not start is tried again after this long.
const DISPATCHER_RETRY_S = 300
const UPDATE_CHECK_MS = 30 * 60 * 1000
const UPDATE_START_MS = 30000
const STUCK_AFTER_S = 20 * 60
// A wake waits until the model has been stopped for this long.
const WAKE_QUIET_S = 5
// What a session stopped on the usage limit is woken with, once the limit has reset.
const LIMIT_WAKE = 'The usage limit has reset: go on where you stopped.'
// A tech lead the user comes back to after this long hears that its inbox holds messages.
const INBOX_PAUSE_S = 15 * 60
const EXPECT_MS = 15000
const PANE = 'team-board'
const DEV_PANE = 'team-dev'
// A developer reads the issue's status and its pull request from GitHub at most this often: every machine
// shares one account and its hourly API allowance.
const GITHUB_EVERY_S = 5 * 60
const GITHUB_TIMEOUT_MS = 30000
const GIT_TIMEOUT_MS = 10000
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
  // The purple Claude Code gives an agent in the agent list (dark theme), not the terminal's magenta, which draws pink.
  others: { bg: '#827dbd', fg: 'white' },
  stuck: { bg: 'red', fg: 'white' },
  idle: { bg: 'green', fg: 'black' },
}
const ORDER: Record<string, number> = { 'tech-lead': 0, dev: 1, qa: 2, spike: 3 }
// What the board writes before how long an agent has been in its state: "waiting 9m", "idle 1h20m".
const VERBS: Record<string, string> = { you: 'waiting', others: 'waiting', working: 'working', stuck: 'stuck', idle: 'idle' }

const board = atom({ plugin: 'team', key: 'board' } as const, { repo: '', rows: [], summary: null, dispatcher: { running: false, version: '' }, updated: 0 }, {
  shape: 'board-4',
})

// A developer's pane, refreshed with the board's rhythm.
const dev = atom(
  { plugin: 'team', key: 'dev' } as const,
  { repo: '', issue: 0, title: '', branch: '', status: '', pr: null, read: 0, work: null, state: '', detail: '', since: 0, checkout: '', review: '', ci: '', updated: 0 },
  { shape: 'dev-1' },
)

// The plugin's newest published version, when newer than the one running: the board's foot offers it.
const latest = atom({ plugin: 'team', key: 'latest' } as const, '')
// This session's model, as /model shows it: the tech lead's, which the user picks, in the board's summary.
const model = atom({ plugin: 'team', key: 'model' } as const, '')
// The effort its last request to the model carried ('' before the first, or on a model without effort).
const effort = atom({ plugin: 'team', key: 'effort' } as const, '')
let lastEffort: string | undefined
let updateCheckedAt = 0
let isStartingUpdate = false

let stateRoot: string | undefined
let dataRoot: string | undefined
// The inbox messages already told to this tech lead.
let toldInbox = new Set<string>()
let isBusy = false
let isSyncing = false
let isStartingDispatcher = false
let dispatcherTriedAt = 0
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
  branch?: string
  resume_to?: { state: string; detail: string; since: number }
  asked_on?: string | null
  waits_on?: string
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

async function dataOf($: EngineInterface): Promise<string> {
  if (dataRoot === undefined) {
    const data = (await $.env.get('XDG_DATA_HOME')) || `${(await $.env.get('HOME')) ?? ''}/.local/share`
    dataRoot = `${data}/team`
  }
  return dataRoot
}

// The messages other repositories left for this repository's tech leads (tell.sh), unread.
async function inboxOf($: EngineInterface, repo: string): Promise<string[]> {
  try {
    const entries = await $.fs.list(`${await dataOf($)}/inbox/${repo.replace('/', '_')}/new`)
    return entries.filter(entry => entry.kind === 'file').map(entry => entry.name)
  } catch {
    return []
  }
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
  delete status.waits_on
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
      // A turn that starts ends a stop on the usage limit: a turn that stops on it again records a new one.
      if ((await readText($, `${folder}/limited`)) !== '') {
        await $.fs.write(`${folder}/limited`, '')
      }
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

// Starts this repository's dispatcher on this machine, when the user clicks its stopped row on the board or
// the tech lead finds it stopped: a process of its own (scripts/dispatcher.sh), which goes on after this
// session ends.
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

// A tech lead keeps its repository's dispatcher running on this machine: stopped by a restart of the
// machine or a crash, it starts it again, at most once every few minutes. One the user stopped by hand
// (dispatcher.stopped, which a start by hand removes) stays stopped: the user starts it again.
async function keepDispatcher($: EngineInterface, repo: string, nowMs: number): Promise<void> {
  const dir = `${await rootOf($)}/repos/${repo.replace('/', '_')}`
  const lastCycle = Number(await readText($, `${dir}/dispatcher.alive`)) || 0
  if (Math.floor(nowMs / 1000) - lastCycle <= DISPATCHER_ALIVE_S) {
    return
  }
  if ((await readText($, `${dir}/dispatcher.stopped`)) !== '' || nowMs - dispatcherTriedAt < DISPATCHER_RETRY_S * 1000) {
    return
  }
  dispatcherTriedAt = nowMs
  void startDispatcher($)
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
// A developer's pane: the width of its label column ("BRANCH" and a space or two).
const LABEL_WIDTH = 8

const width = (row: Row) => row.reduce((n, segment) => n + [...segment.text].length, 0)

// The title: a dialog titled TEAM (a developer's: DEV #<n>) with the project's name centered in a thin inner
// frame. Null when the pane is too narrow.
function titleRows(name: string, columns: number, title = 'TEAM'): Row[] | null {
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
    title,
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

// cut <text> <width>: the text on one line of at most that many characters, an ellipsis at its end when cut.
function cut(text: string, max: number): string {
  const chars = [...text]
  return chars.length <= max ? text : `${chars.slice(0, Math.max(0, max - 1)).join('')}…`
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

// The elements a pane draws with, on any surface.
type Ui = Pick<ElementTable, 'Box' | 'Text' | 'Button' | 'Link'>

function segmentOf(ui: Ui, segment: Segment, key: string) {
  const { Text } = ui
  return (
    <Text key={key} {...LOOKS[segment.look]}>
      {segment.text}
    </Text>
  )
}

// A row holding a control is laid out in a row of its parts, the control a Button around its text.
function drawRows($: EngineInterface, ui: Ui, rows: Row[], key: string) {
  const { Box, Text, Button } = ui
  return rows.map((row, i) =>
    row.some(segment => segment.press !== undefined) ? (
      <Box key={`${key}-${i}`} flexDirection="row">
        {row.map((segment, j) =>
          segment.press === 'start-dispatcher' ? (
            <Button key={`${key}-${i}-${j}`} plain onPress={() => startDispatcher($)}>
              {segmentOf(ui, segment, `${key}-${i}-${j}-text`)}
            </Button>
          ) : (
            segmentOf(ui, segment, `${key}-${i}-${j}`)
          ),
        )}
      </Box>
    ) : (
      <Text key={`${key}-${i}`}>{row.map((segment, j) => segmentOf(ui, segment, `${key}-${i}-${j}`))}</Text>
    ),
  )
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
      usage?: { h5?: { text?: string; alt?: string; tone?: string }; d7?: { text?: string; alt?: string; tone?: string } }
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
      usage5h: { text: written.usage?.h5?.text || 'unreadable', alt: written.usage?.h5?.alt ?? '', tone: written.usage?.h5?.tone ?? 'text' },
      usage7d: { text: written.usage?.d7?.text || 'unreadable', alt: written.usage?.d7?.alt ?? '', tone: written.usage?.d7?.tone ?? 'text' },
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

// How comments name a session, as scripts/repo.sh address_of does: "tech lead", "dev #<n>", "qa #<n>",
// "spike <topic>".
async function addressOf($: EngineInterface, id: string): Promise<string> {
  const status = await readStatus($, `${await rootOf($)}/sessions/${id}`)
  if (status.role === 'tech-lead') {
    return 'tech lead'
  }
  if (status.role === 'dev' || status.role === 'qa') {
    return `${status.role} #${status.issue ?? '?'}`
  }
  return status.role === 'spike' ? `spike ${status.topic ?? ''}`.trim() : 'team'
}

// The main checkout's lock (scripts/checkout.sh): who holds it, with as-is after its name when it took it
// as it is (its fourth line), and this session's place in its queue.
async function checkoutOf($: EngineInterface, dir: string, me: string): Promise<string> {
  const lock = (await readText($, `${dir}/checkout`)).split('\n')
  const holder = lock[0] ?? ''
  const how = lock[3] === 'as-is' ? ' as-is' : ''
  const queue = (await readText($, `${dir}/checkout.queue`)).split('\n').filter(line => line !== '')
  const held = holder === '' ? 'free' : `held by ${holder === me ? 'you' : await addressOf($, holder)}${how}`
  const place = queue.indexOf(me)
  return place < 0 ? held : `${held} · you are ${place + 1} of ${queue.length} in the queue`
}

// git <args> in the developer's worktree: what it printed, null when it failed.
async function gitOf($: EngineInterface, cwd: string, args: string[]): Promise<string | null> {
  try {
    const ran = await $.process.run(['git', ...args], { cwd, timeoutMs: GIT_TIMEOUT_MS })
    return ran.exitCode === 0 ? ran.stdout.trim() : null
  } catch {
    return null
  }
}

// The branch's work, local and read at every refresh: the commits ahead of the default branch, and the
// files and lines changed since the two parted. Null when git cannot tell.
async function workOf($: EngineInterface, cwd: string, base: string): Promise<DevWork | null> {
  if (base === '') {
    return null
  }
  const commits = await gitOf($, cwd, ['rev-list', '--count', `origin/${base}..HEAD`])
  const stat = await gitOf($, cwd, ['diff', '--shortstat', `origin/${base}...HEAD`])
  if (commits === null || stat === null) {
    return null
  }
  // " 4 files changed, 120 insertions(+), 15 deletions(-)", a part left out when it is 0, all of it when
  // nothing changed.
  const count = (pattern: RegExp) => Number(pattern.exec(stat)?.[1] ?? 0)
  return {
    commits: Number(commits) || 0,
    files: count(/(\d+) files? changed/),
    added: count(/(\d+) insertions?\(\+\)/),
    removed: count(/(\d+) deletions?\(-\)/),
  }
}

// What a developer last read from GitHub, kept in its session's folder (`github`): when, the issue's own
// status, whether the issue carries the label qa (null before the first read), and the branch's newest pull
// request.
type GithubRead = { at: number; status: string; qa: boolean | null; pr: DevPr | null }

async function githubOf($: EngineInterface, folder: string): Promise<GithubRead> {
  try {
    const known = JSON.parse(await $.fs.read(`${folder}/github`)) as Partial<GithubRead>
    return { at: Number(known.at) || 0, status: known.status ?? '', qa: known.qa ?? null, pr: known.pr ?? null }
  } catch {
    return { at: 0, status: '', qa: null, pr: null }
  }
}

const ISSUE_QUERY =
  'query($o: String!, $n: String!, $i: Int!) { repository(owner: $o, name: $n) { issue(number: $i) { status { name } labels(first: 30) { nodes { name } } } } }'

// One check of a pull request's head: a check run (status, conclusion) or a commit status (state).
type Check = { __typename?: string; status?: string; conclusion?: string; state?: string }

// The checks of a pull request's head, judged as merge.sh does: a check run passes when it completed with
// success, skipped or neutral, a commit status when it is a success; one not finished yet is running.
function checksOf(rollup: readonly Check[]): DevPr['checks'] {
  let failed = 0
  let pending = 0
  for (const check of rollup) {
    if (check.__typename === 'StatusContext') {
      if (check.state === 'PENDING' || check.state === 'EXPECTED') {
        pending++
      } else if (check.state !== 'SUCCESS') {
        failed++
      }
    } else if (check.status !== 'COMPLETED') {
      pending++
    } else if (!['SUCCESS', 'SKIPPED', 'NEUTRAL'].includes(check.conclusion ?? '')) {
      failed++
    }
  }
  return { total: rollup.length, failed, pending }
}

let isReadingGithub = false

// Reads from GitHub, in two calls, the issue's own status with its labels and the branch's newest pull
// request in any state, and keeps them in the session's folder with when. Whatever the outcome GitHub is not
// asked again for 5 minutes; a call that fails keeps what the last read found.
async function readGithub($: EngineInterface, folder: string, cwd: string, repo: string, issue: number, branch: string, now: number): Promise<void> {
  if (isReadingGithub) {
    return
  }
  isReadingGithub = true
  const known = await githubOf($, folder)
  let { status, qa, pr } = known
  try {
    const [owner = '', name = ''] = repo.split('/')
    const asked = await $.process.run(
      ['gh', 'api', 'graphql', '-f', `query=${ISSUE_QUERY}`, '-F', `o=${owner}`, '-F', `n=${name}`, '-F', `i=${issue}`,
        '--jq', '.data.repository.issue | {status: (.status.name // ""), qa: ([.labels.nodes[].name] | index("qa") != null)}'],
      { cwd, timeoutMs: GITHUB_TIMEOUT_MS },
    )
    if (asked.exitCode === 0) {
      const answer = JSON.parse(asked.stdout) as { status?: string; qa?: boolean }
      status = answer.status ?? ''
      qa = answer.qa ?? null
    }
    if (branch !== '') {
      const listed = await $.process.run(
        ['gh', 'pr', 'list', '--repo', repo, '--head', branch, '--state', 'all', '--limit', '1', '--json', 'number,title,url,state,statusCheckRollup'],
        { cwd, timeoutMs: GITHUB_TIMEOUT_MS },
      )
      if (listed.exitCode === 0) {
        const [newest] = JSON.parse(listed.stdout) as { number: number; title: string; url: string; state: string; statusCheckRollup?: Check[] }[]
        pr =
          newest === undefined
            ? null
            : { number: newest.number, title: newest.title, url: newest.url, state: newest.state, checks: checksOf(newest.statusCheckRollup ?? []) }
      }
    }
  } catch (err) {
    $.ui.log(`team: github: ${String(err)}`)
  } finally {
    try {
      await $.fs.write(`${folder}/github`, `${JSON.stringify({ at: now, status, qa, pr })}\n`)
    } catch (err) {
      $.ui.log(`team: github: ${String(err)}`)
    }
    isReadingGithub = false
  }
}

// The reviews of the branch (review.sh, qa.sh), keyed by the issue since they come before the pull request:
// each counts only for the worktree's HEAD, as merge.sh wants it for the head it merges. "decision review
// passed · QA needed".
async function reviewOf($: EngineInterface, dir: string, cwd: string, issue: number, qa: boolean | null): Promise<string> {
  const head = (await gitOf($, cwd, ['rev-parse', 'HEAD'])) ?? ''
  const reviewed = issue === 0 ? '' : ((await readText($, `${dir}/review/${issue}`)).split('\t')[0] ?? '')
  const decision = head !== '' && reviewed === head ? 'decision review passed' : 'decision review not passed'
  // qa/<issue>: "requested <head> <issue> <session> <branch>" once asked, then "pass <head>" or "fail <head>".
  const [outcome = '', tested = ''] = issue === 0 ? [] : (await readText($, `${dir}/qa/${issue}`)).split('\t')
  let quality = qa === null ? '' : qa ? 'QA needed' : 'no QA'
  if (outcome === 'requested') {
    quality = 'QA asked'
  } else if ((outcome === 'pass' || outcome === 'fail') && head !== '' && tested === head) {
    quality = outcome === 'pass' ? 'QA passed' : 'QA failed'
  }
  return quality === '' ? decision : `${decision} · ${quality}`
}

// A developer's pane: its own status file, git in its worktree, what it last read from GitHub (asked again
// in the background once 5 minutes have passed), the checkout lock, the review and QA records and the
// default branch's CI as the dispatcher wrote it.
async function refreshDev($: EngineInterface, folder: string, status: Status, now: number): Promise<void> {
  const repo = status.repo ?? ''
  const dir = `${await rootOf($)}/repos/${repo.replace('/', '_')}`
  const cwd = (await readText($, `${folder}/cwd`)) || (await $.session.cwd())
  const branch = status.branch ?? ''
  const github = await githubOf($, folder)
  if (repo !== '' && status.issue !== undefined && now - github.at >= GITHUB_EVERY_S) {
    void readGithub($, folder, cwd, repo, status.issue, branch, now)
  }
  const work = await workOf($, cwd, await readText($, `${dir}/base`))
  const checkout = await checkoutOf($, dir, await $.session.id())
  const review = await reviewOf($, dir, cwd, status.issue ?? 0, github.qa)
  const ci = await readText($, `${dir}/ci`)
  const next: Dev = {
    repo,
    issue: status.issue ?? 0,
    title: status.title ?? '',
    branch,
    status: github.status,
    pr: github.pr,
    read: github.at,
    work,
    state: status.state ?? 'working',
    detail: status.detail ?? '',
    since: status.since ?? 0,
    checkout,
    review,
    ci,
    updated: now,
  }
  await update($, dev, () => next)
}

// "claude-fable-5-2" as "Fable 5.2"; anything else as it is.
function modelName(id: string): string {
  const m = /^claude-([a-z]+)-(\d+)-(\d+)/.exec(id)
  return m === null ? id : `${(m[1] ?? '').charAt(0).toUpperCase()}${(m[1] ?? '').slice(1)} ${m[2]}.${m[3]}`
}

// "Opus 5.5" and "xhigh" as "Opus 5.5 (xhigh)"; with no effort known, the model alone.
function withEffort(name: string, level: string): string {
  return level === '' ? name : `${name} (${level})`
}

// The effort of the main loop's requests to the model, as the engine sends it: written when it changes.
async function noteEffort($: EngineInterface, level: string | number | undefined): Promise<void> {
  const now = level === undefined ? '' : String(level)
  if (now === lastEffort) {
    return
  }
  lastEffort = now
  try {
    await update($, effort, () => now)
  } catch (err) {
    $.ui.log(`team: effort: ${String(err)}`)
  }
}

// The tech lead's model for the summary, read at each refresh: the user may switch it with /model.
async function noteModel($: EngineInterface): Promise<void> {
  try {
    const now = await $.session.model()
    if (now !== (await read($, model))) {
      await update($, model, () => now)
    }
  } catch (err) {
    $.ui.log(`team: model: ${String(err)}`)
  }
}

// a newer than b, both "x.y.z".
function isNewer(a: string, b: string): boolean {
  const x = a.split('.').map(Number)
  const y = b.split('.').map(Number)
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0)
    if (d !== 0) {
      return d > 0
    }
  }
  return false
}

// A tech lead looks, every 30 minutes, at the version published on the plugin's repository (its manifest on
// the default branch, read from raw.githubusercontent.com: no GitHub API call, nothing from the account's
// allowance). Newer than the one running, it goes on the board's foot, with a toast the first time.
async function checkLatest($: EngineInterface, nowMs: number): Promise<void> {
  if (updateCheckedAt !== 0 && nowMs - updateCheckedAt < UPDATE_CHECK_MS) {
    return
  }
  updateCheckedAt = nowMs
  try {
    const manifest = JSON.parse(await $.fs.read(`${$.plugin.root}/.claude-plugin/plugin.json`)) as { repository?: string }
    const repo = (manifest.repository ?? '').replace(/^https?:\/\/github\.com\//, '').replace(/\.git$/, '')
    if (repo === '') {
      return
    }
    const answer = await $.http.fetch(`https://raw.githubusercontent.com/${repo}/HEAD/.claude-plugin/plugin.json`)
    if (!answer.ok) {
      return
    }
    const published = (JSON.parse(answer.text) as { version?: string }).version ?? ''
    const running = await versionOf($)
    const newer = published !== '' && running !== '' && isNewer(published, running) ? published : ''
    if (newer !== '' && newer !== (await read($, latest))) {
      $.ui.toast(`team ${newer} is out: click update at the foot of the board`)
    }
    await update($, latest, () => newer)
  } catch (err) {
    $.ui.log(`team: update check: ${String(err)}`)
  }
}

// A click on update at the board's foot: /team:update, detached (scripts/update.sh start). It updates the
// plugin on every account of this machine and restarts on the new version every running dispatcher, then
// every live team session, each once it is quiet, this session last.
async function startUpdate($: EngineInterface): Promise<void> {
  if (isStartingUpdate) {
    return
  }
  isStartingUpdate = true
  try {
    const cwd = (await readText($, `${await folderOf($)}/cwd`)) || (await $.session.cwd())
    const ran = await $.process.run(['sh', `${$.plugin.root}/scripts/update.sh`, 'start'], { cwd, timeoutMs: UPDATE_START_MS })
    $.ui.toast((ran.exitCode === 0 ? ran.stdout : ran.stderr || ran.stdout).trim() || 'update: no answer')
  } catch (err) {
    $.ui.log(`team: update: ${String(err)}`)
    $.ui.toast('the update did not start: run /team:update')
  } finally {
    isStartingUpdate = false
  }
}

// The plugin's version, read once from its manifest (at session start), for the foot of the board and the
// session's `version`.
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

// The folder this module wrote its `version` in; another one (none yet) gets it at the next chance.
let versionFolder = ''
// Writes the version the session loaded in a team session's folder, once: scripts/update.sh reads it.
async function noteVersion($: EngineInterface, folder: string): Promise<void> {
  if (versionFolder === folder) {
    return
  }
  try {
    const version = await versionOf($)
    if (version !== '') {
      await $.fs.write(`${folder}/version`, `${version}\n`)
    }
    versionFolder = folder
  } catch (err) {
    $.ui.log(`team: version: ${String(err)}`)
  }
}

async function openBoard($: EngineInterface): Promise<void> {
  await $.ui.open({ id: PANE, title: 'Team' })
}

async function openDev($: EngineInterface): Promise<void> {
  await $.ui.open({ id: DEV_PANE, title: 'Team' })
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
    await noteVersion($, folder)
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
        await keepDispatcher($, status.repo, nowMs)
        await checkLatest($, nowMs)
        await noteModel($)
        if (!isPaneOpened) {
          isPaneOpened = true
          void openBoard($)
        }
      }
    }
    if (role === 'dev' && tickNumber % BOARD_EVERY_TICKS === 0) {
      // What the pane cannot read never keeps the session from its wakes and its color.
      try {
        await refreshDev($, folder, status, now)
        await noteModel($)
      } catch (err) {
        $.ui.log(`team: dev pane: ${String(err)}`)
      }
      if (!isPaneOpened) {
        isPaneOpened = true
        void openDev($)
      }
    }
    if (!isBusy) {
      // The usage limit's wake goes alone: what else waits reaches the turn it starts at its end.
      if (!(await limitWake($, folder, now))) {
        await wakeUp($, folder, role, status, now)
      }
      await apply($, 'name', 'rename', await readText($, `${folder}/name`), nowMs)
      await apply($, 'color', 'color', COLORS[status.state ?? ''] ?? '', nowMs)
    }
  } catch (err) {
    $.ui.log(`team: ${String(err)}`)
  } finally {
    isSyncing = false
  }
}

// A wake line as dispatch.sh and checkout.sh write it: time, from, what, link. A GitHub comment's from is
// "<author> on #<issue>", the issue being its thread (an issue and the pull requests that close it), its
// time is the comment's and its link the comment's own.
type WakeLine = { time: number; from: string; link: string; text: string }

// What the session wrote on GitHub (comment.sh, note.sh), one line of `commented` each: when, on which
// thread, to whom (an address; empty for a note).
type Said = { time: number; issue: string; to: string }

// The author of the comments written on GitHub without a header (dispatch.sh): the user.
const USER = 'the user'

// "<author> on #<issue>" as its author and its issue; null for a line that is not a GitHub comment.
function commentOf(from: string): { author: string; issue: string } | null {
  const match = /^(.+) on #(\d+)$/.exec(from)
  return match === null ? null : { author: match[1] ?? '', issue: match[2] ?? '' }
}

async function saidOf($: EngineInterface, folder: string): Promise<Said[]> {
  return (await readText($, `${folder}/commented`))
    .split('\n')
    .filter(line => line !== '')
    .map(line => {
      const [time = '', issue = '', to = ''] = line.split('\t')
      return { time: Number(time), issue, to }
    })
}

// When each comment first reached this repository's tech lead, by link: delivered in a wake (wakeUp) or listed
// by scripts/mentions.sh, one line of the repository's `seen` each, <time> <link>. Shared by the successive
// tech lead sessions of the repository on this machine; only ever appended to.
type Seen = Map<string, number>

async function seenFile($: EngineInterface, repo: string): Promise<string> {
  return `${await rootOf($)}/repos/${repo.replace('/', '_')}/seen`
}

async function seenOf($: EngineInterface, repo: string): Promise<Seen> {
  const seen: Seen = new Map()
  for (const line of (await readText($, await seenFile($, repo))).split('\n')) {
    const [time = '', link = ''] = line.split('\t')
    if (link !== '' && Number(time) > 0 && !seen.has(link)) {
      seen.set(link, Number(time))
    }
  }
  return seen
}

// Appends the links that reached the tech lead now to the repository's `seen`. A file that exists but cannot
// be read is left as it is: written whole, it would lose what it held.
async function noteSeen($: EngineInterface, repo: string, links: string[]): Promise<void> {
  const file = await seenFile($, repo)
  const now = Math.floor((await $.clock.now()) / 1000)
  let before = (await $.fs.exists(file)) ? await $.fs.read(file) : ''
  if (before !== '' && !before.endsWith('\n')) {
    before += '\n'
  }
  await $.fs.write(file, `${before}${links.map(link => `${now}\t${link}\n`).join('')}`)
}

// A comment the session already answered. In a tech lead: one of the user's by any later comment of the
// session on its thread; an agent's only by a comment of the session written to that agent on its thread
// after the comment reached the tech lead (`seen`), so one never seen is never answered. In any other
// session: by any later comment of the session on its thread, a note included, whoever it was to.
function isAnswered(line: WakeLine, said: Said[], role: string, seen: Seen): boolean {
  const comment = commentOf(line.from)
  if (comment === null || !(line.time > 0)) {
    return false
  }
  if (role === 'tech-lead' && comment.author !== USER) {
    const at = seen.get(line.link)
    return at !== undefined && said.some(s => s.issue === comment.issue && s.to === comment.author && s.time > at)
  }
  return said.some(s => s.issue === comment.issue && s.time > line.time)
}

// A GitHub comment's link as dispatch.sh writes it (the comment's html_url) as its repository and its id;
// null for any other link (a new issue) or none (the checkout).
function commentLink(link: string): { repo: string; id: string } | null {
  const match = /^https:\/\/[^/]+\/([^/]+)\/([^/]+)\/(?:issues|pull)\/\d+#issuecomment-(\d+)$/.exec(link)
  return match === null ? null : { repo: `${match[1] ?? ''}/${match[2] ?? ''}`, id: match[3] ?? '' }
}

// The comments GitHub no longer has, by link: never asked about again in this session.
const gone = new Set<string>()

// A comment deleted since it was written: GitHub answers 404 for it. Any other failure (no network, the
// hourly allowance) tells nothing, and keeps it.
async function isGone($: EngineInterface, cwd: string, link: string): Promise<boolean> {
  const comment = commentLink(link)
  if (comment === null) {
    return false
  }
  try {
    const ran = await $.process.run(['gh', 'api', `repos/${comment.repo}/issues/comments/${comment.id}`, '--silent'], { cwd, timeoutMs: GITHUB_TIMEOUT_MS })
    if (ran.exitCode !== 0 && /HTTP 404/.test(ran.stderr)) {
      gone.add(link)
      return true
    }
  } catch (err) {
    $.ui.log(`team: comment lookup: ${String(err)}`)
  }
  return false
}

// Wakes the session, between turns, with what was written to it since: a GitHub comment the dispatcher
// appended to `wake` (one line each: time, from, what, link), the main checkout freed for it, and for a tech
// lead the messages other repositories left in its inbox. Once the model has been stopped a few seconds; a
// tech lead whose last message asked the user something in its chat is left alone, the user is talking to
// it, until the user writes to it on GitHub: that is the user talking too, and every fresh line goes with it.
// Each comment is checked again as it is delivered: one the session already answered on GitHub (isAnswered),
// then, asking GitHub, one deleted since (isGone), is delivered without a turn; with nothing left, no wake.
// `wake-read`, beside it, counts the lines delivered, so a restart does not deliver them again. A line from
// the one the session waits on ends that wait before the turn starts (answered). In a tech lead, the links
// delivered go to the repository's `seen` once the prompt entered (noteSeen).
async function wakeUp($: EngineInterface, folder: string, role: string, status: Status, now: number): Promise<void> {
  const idleSince = Number(await readText($, `${folder}/idle`))
  if (!(idleSince > 0) || now - idleSince < WAKE_QUIET_S) {
    return
  }
  const isInChat = role === 'tech-lead' && status.state === 'you' && (status.asked_on ?? null) === null
  const parts: string[] = []
  let wake = ''
  try {
    wake = await $.fs.read(`${folder}/wake`)
  } catch {
    wake = ''
  }
  const lines = wake.split('\n').filter(line => line !== '')
  let delivered = Number(await readText($, `${folder}/wake-read`)) || 0
  if (delivered > lines.length) {
    delivered = 0
  }
  const fresh: WakeLine[] = lines.slice(delivered).map(line => {
    const [time = '', from = '', what = '', link = ''] = line.split('\t')
    return { time: Number(time), from, link, text: `${from}: ${what}${link !== '' ? ` (${link})` : ''}` }
  })
  const said = fresh.length > 0 ? await saidOf($, folder) : []
  const repo = role === 'tech-lead' ? (status.repo ?? '') : ''
  const seen = fresh.length > 0 && repo !== '' ? await seenOf($, repo) : new Map<string, number>()
  // First what needs no call to GitHub: the comments answered, and those already found deleted.
  let kept = fresh.filter(line => !isAnswered(line, said, role, seen) && !gone.has(line.link))
  const hasUser = () => kept.some(line => commentOf(line.from)?.author === USER)
  if (isInChat && !hasUser()) {
    return
  }
  if (kept.some(line => commentLink(line.link) !== null)) {
    const cwd = (await readText($, `${folder}/cwd`)) || (await $.session.cwd())
    const deleted = await Promise.all(kept.map(line => isGone($, cwd, line.link)))
    kept = kept.filter((_, i) => !deleted[i])
    // A turn that started while GitHub answered (the user wrote) has the wake wait for its end, checked again.
    if (isBusy || (isInChat && !hasUser())) {
      return
    }
  }
  if (fresh.length > 0) {
    await $.fs.write(`${folder}/wake-read`, `${lines.length}\n`)
  }
  if (kept.length > 0) {
    parts.push(`for you on GitHub: ${kept.map(line => line.text).join('; ')}`)
    await answered($, folder, role, kept.map(line => line.from), now)
  }
  if (role === 'tech-lead' && status.repo) {
    const inbox = await inboxOf($, status.repo)
    const unread = inbox.filter(name => !toldInbox.has(name))
    if (unread.length > 0) {
      parts.push(`${unread.length} message(s) from other repositories: sh "${$.plugin.root}/scripts/inbox.sh" read`)
    }
    toldInbox = new Set(inbox)
  }
  if (parts.length > 0) {
    // In a tech lead, what the prompt carried has reached it once the prompt entered: `seen`.
    const links = repo !== '' ? kept.map(line => line.link).filter(link => link !== '') : []
    void $.prompt
      .submit({ text: parts.join('; ') })
      .then(async result => {
        if (result.drop === undefined && links.length > 0) {
          await noteSeen($, repo, links)
        }
      })
      .catch(err => $.ui.log(`team: ${String(err)}`))
  }
}

// A comment from the one the session waits on (`waits_on`, recorded by comment.sh) ends the wait: working,
// answered by them, with nothing to put back, so markTurn does not restore the wait when the turn it wakes
// ends. A tech lead that asked the user in its own chat waits on the user, who may answer on GitHub too: as a
// prompt the user types, the user's comment ends that wait. A comment from anyone else leaves the wait: worked
// for the turn, back to waiting after it. Each `from` is a wake line's as dispatch.sh writes it, "<author> on
// #<issue>".
async function answered($: EngineInterface, folder: string, role: string, froms: string[], now: number): Promise<void> {
  const status = await readStatus($, folder)
  const isTechLeadAsking = status.state === 'you' && role === 'tech-lead'
  const isInChat = isTechLeadAsking && (status.asked_on ?? null) === null
  const isWaiting = status.state === 'others' || (isTechLeadAsking && !isInChat)
  const waitsOn = isInChat ? USER : isWaiting ? status.waits_on : undefined
  if (waitsOn === undefined) {
    return
  }
  const author = froms.map(from => commentOf(from)?.author).find(from => from === waitsOn)
  if (author === undefined) {
    return
  }
  status.state = 'working'
  status.detail = `answered by ${author}`
  status.since = now
  delete status.waits_on
  delete status.resume_to
  await $.fs.write(`${folder}/status`, `${JSON.stringify(status)}\n`)
}

// The user writing to a team session (at its prompt, through Remote Control or Slack): it works with them,
// and whatever it waited on is over (markTurn would otherwise put the wait back when the turn ends). A tech
// lead the user comes back to after a pause hears, in one line of context, that other repositories left
// messages in its inbox; the messages never enter the conversation here. The plugin's own wakes, the
// engine's notifications and the scripts' prompts are not the user.
async function heardUser($: EngineInterface): Promise<string | undefined> {
  const folder = await folderOf($)
  const role = await readText($, `${folder}/role`)
  if (role === '') {
    return undefined
  }
  const now = Math.floor((await $.clock.now()) / 1000)
  const status = await readStatus($, folder)
  if (status.state !== 'working' || status.detail !== 'with you') {
    status.since = now
  }
  status.state = 'working'
  status.detail = 'with you'
  delete status.resume_to
  await $.fs.write(`${folder}/status`, `${JSON.stringify(status)}\n`)
  if (role !== 'tech-lead' || !status.repo) {
    return undefined
  }
  const before = Number(await readText($, `${folder}/last-prompt`)) || 0
  await $.fs.write(`${folder}/last-prompt`, `${now}\n`)
  if (now - before < INBOX_PAUSE_S) {
    return undefined
  }
  const waiting = (await inboxOf($, status.repo)).length
  return waiting === 0 ? undefined : `📨 ${waiting} message(s) from other repositories wait in your inbox (inbox.sh). Mention it in one line before answering, do not read them unless the user wants to; answer what the user asked.`
}

// A turn of the main loop that ended on the usage limit (Claude Code's StopFailure with `rate_limit`): the
// session is alive and waits for the limit to reset. `limited`, in its folder, holds when it stopped, until the
// wake or the next turn that starts.
async function stoppedOnLimit($: EngineInterface): Promise<void> {
  const folder = await folderOf($)
  if ((await readText($, `${folder}/role`)) === '') {
    return
  }
  await $.fs.write(`${folder}/limited`, `${Math.floor((await $.clock.now()) / 1000)}\n`)
}

// "2026-11-26T19:09:59.873694+01:00", as clessidra writes a time, in seconds: its fraction cut to milliseconds,
// as every JavaScript engine reads it. NaN when it is no time.
function secondsOf(time: string): number {
  return Math.floor(Date.parse(time.replace(/(\.\d{3})\d+/, '$1')) / 1000)
}

// When the usage limit a session stopped on (at `stop`) resets: the plan usage the dispatcher reads for the
// board (scripts/dispatch.sh, `clessidra --json`, one file per Claude Code config folder), the reset of the
// window at its limit, the later one when both are. With no window at its limit (read before the stop, or
// after a reset that came between the stop and the read), the reset of the most used window, the later one
// when two are as used. Null when none is known yet: no file, or a reset not after the stop (a file read
// before the window started).
async function resetOf($: EngineInterface, stop: number): Promise<number | null> {
  const config = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${(await $.env.get('HOME')) ?? ''}/.claude`
  let windows: { outcome?: string; used?: number; resets_at?: string | null }[] = []
  try {
    const usage = JSON.parse(await $.fs.read(`${await rootOf($)}/usage/${config.replace(/\//g, '_')}.json`)) as { windows?: typeof windows }
    windows = usage.windows ?? []
  } catch {
    return null
  }
  const known = windows
    .map(w => ({ isAtLimit: w.outcome === 'limit_reached', used: Number(w.used) || 0, reset: secondsOf(w.resets_at ?? '') }))
    .filter(w => Number.isFinite(w.reset))
  const atLimit = known.filter(w => w.isAtLimit)
  const [chosen] = atLimit.length > 0 ? [...atLimit].sort((a, b) => b.reset - a.reset) : [...known].sort((a, b) => b.used - a.used || b.reset - a.reset)
  return chosen !== undefined && chosen.reset > stop ? chosen.reset : null
}

// Wakes a session stopped on the usage limit once the limit has reset, once per stop: true when it did.
async function limitWake($: EngineInterface, folder: string, now: number): Promise<boolean> {
  const stop = Number(await readText($, `${folder}/limited`))
  const idleSince = Number(await readText($, `${folder}/idle`))
  if (!(stop > 0) || !(idleSince > 0)) {
    return false
  }
  const reset = await resetOf($, stop)
  if (reset === null || now < reset) {
    return false
  }
  await $.fs.write(`${folder}/limited`, '')
  void $.prompt.submit({ text: LIMIT_WAKE }).catch(err => $.ui.log(`team: ${String(err)}`))
  return true
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
    // The version loaded now, kept for the session's `version`: in a team session's folder alone.
    await versionOf($)
    const folder = await folderOf($)
    if ((await readText($, `${folder}/role`)) !== '') {
      await noteVersion($, folder)
    }
    await $.command.register({ name: 'team', description: 'Open the team pane: the project, its agents by state, the summary' })
    if (!isBusy) {
      await markTurn($, false)
    }
    $.clock.every(TICK_MS, () => {
      void tick($)
    })
    return result
  })

  // A developer's pane in a developer session, the board anywhere else.
  on('command.run', { command: 'team' }, async $ => {
    if ((await readText($, `${await folderOf($)}/role`)) === 'dev') {
      await openDev($)
    } else {
      await openBoard($)
    }
    return { text: 'Team pane opened.' }
  })

  on('prompt.submit', async ($, e, next) => {
    const kind = e.origin?.kind
    const isUser = kind === 'composer' || kind === 'bridge' || kind === 'slack-ping' || (kind === 'unclassified' && e.isMeta !== true)
    if (!isUser) {
      return next(e)
    }
    try {
      const note = await heardUser($)
      if (note !== undefined) {
        return next({ ...e, context: [...(e.context ?? []), note] })
      }
    } catch (err) {
      $.ui.log(`team: ${String(err)}`)
    }
    return next(e)
  })

  // Each request of the main loop to the model carries its effort: the summary shows it after the model.
  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined) {
      void noteEffort($, e.effort)
    }
    return yield* next(e)
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

  // A turn of the main loop that ended on the usage limit, never a subagent's: woken when the limit resets.
  on('classic.StopFailure', async ($, e, next) => {
    if (e.error === 'rate_limit' && e.agent_id === undefined) {
      try {
        await stoppedOnLimit($)
      } catch (err) {
        $.ui.log(`team: usage limit: ${String(err)}`)
      }
    }
    return next(e)
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
    const ui = $.ui.resolve(e)
    const { Box, Text, Button } = ui
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
    // Above 90%, a usage window's line alternates with when it resets, a few seconds each.
    const usageText = (u: { text: string; alt: string }) => (u.alt !== '' && Math.floor(now / ALTERNATE_S) % 2 === 1 ? u.alt : u.text)
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
            // The tech lead's own model, which the user picks with /model; the agents run on the default.
            { label: 'model', value: withEffort(modelName(await read($, model)) || '?', await read($, effort)) },
            { label: 'usage 5h', value: usageText(summary.usage5h), look: toneLook(summary.usage5h.tone) },
            { label: 'usage 7d', value: usageText(summary.usage7d), look: toneLook(summary.usage7d.tone) },
          ]
    const bottom = summaryRows(items, columns)
    const version = await versionOf($)
    const newer = await read($, latest)
    const footer = version === '' ? 'team' : `team ${version}`
    // A newer version published: the foot offers it, and a click on update runs /team:update.
    const offer = newer === '' ? '' : ` · ${newer} available · `
    const offerAction = newer === '' ? '' : 'update'
    const draw = (rows: Row[], key: string) => drawRows($, ui, rows, key)
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
        {newer === '' ? (
          <Text dimColor>
            {' '.repeat(Math.max(0, Math.floor((columns - footer.length) / 2)))}
            {footer}
          </Text>
        ) : (
          <Box flexDirection="row">
            <Text dimColor>
              {' '.repeat(Math.max(0, Math.floor((columns - footer.length - offer.length - offerAction.length) / 2)))}
              {footer}
            </Text>
            <Text color="yellow">{offer}</Text>
            <Button key="update" plain onPress={() => startUpdate($)}>
              <Text color="yellow" bold underline>
                {offerAction}
              </Text>
            </Button>
          </Box>
        )}
      </Box>
    )
  })

  // A developer's pane, in the board's look: the title dialog, the rows behind a dim label column, the
  // summary dialog, the plugin's version at the foot.
  on('ui.render', { component: 'Pane', requestId: DEV_PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Text, Link } = ui
    const data: Dev = await read($, dev)
    const now = Math.floor((await $.clock.now()) / 1000)
    const columns = Math.max(24, e.props.bodyColumns)
    const project = data.repo.split('/')[1] ?? '...'
    const title = titleRows(project, columns, `DEV #${data.issue || '?'}`)
    // The rows, one column in from each side of the pane: what follows the label has the rest.
    const room = Math.max(8, columns - 2 - LABEL_WIDTH)
    const label = (text: string) => <Text dimColor>{text.padEnd(LABEL_WIDTH)}</Text>
    const lines = (name: string, text: string, look: Look = 'text') =>
      wrap(text, room).map((part, i) => (
        <Text key={`${name}-${i}`}>
          {label(i === 0 ? name : '')}
          <Text {...LOOKS[look]}>{part}</Text>
        </Text>
      ))
    // Before GitHub was read once: three dots; a read that found nothing: a question mark.
    const unread = data.read === 0
    const issueUrl = data.repo === '' || data.issue === 0 ? '' : `https://github.com/${data.repo}/issues/${data.issue}`
    const pr = data.pr
    const checks =
      pr === null
        ? { text: '', look: 'text' as Look }
        : pr.checks.total === 0
          ? { text: 'no checks', look: 'text' as Look }
          : pr.checks.failed > 0
            ? { text: `checks failed: ${pr.checks.failed} of ${pr.checks.total}`, look: 'alert' as Look }
            : pr.checks.pending > 0
              ? { text: `checks running: ${pr.checks.pending} of ${pr.checks.total}`, look: 'text' as Look }
              : { text: 'checks green', look: 'ok' as Look }
    const many = (n: number, one: string) => `${n} ${one}${n === 1 ? '' : 's'}`
    const work = data.work === null ? '?' : `${many(data.work.commits, 'commit')} · ${many(data.work.files, 'file')} · +${data.work.added} -${data.work.removed}`
    const look = BACKGROUNDS[data.state] ?? { bg: 'gray', fg: 'white' }
    const items: Item[] = [
      { label: 'checkout', value: data.checkout || '?' },
      { label: 'review', value: data.review || '?' },
      { label: 'main CI', value: data.ci || '?' },
      { label: 'model', value: withEffort(modelName(await read($, model)) || '?', await read($, effort)) },
    ]
    const bottom = summaryRows(items, columns)
    const version = await versionOf($)
    const footer = version === '' ? 'team' : `team ${version}`
    return (
      <Box flexDirection="column">
        {title === null ? <Text bold>{project}</Text> : drawRows($, ui, title, 'title')}
        <Box flexDirection="column" paddingLeft={1} paddingRight={1} marginTop={1}>
          <Text>
            {label('ISSUE')}
            {issueUrl === '' ? '...' : <Link href={issueUrl}>{cut(`#${data.issue} ${data.title}`, room)}</Link>}
          </Text>
          {lines('STATUS', data.status || (unread ? '...' : '?'))}
          {lines('BRANCH', data.branch || '?')}
          {pr === null ? (
            lines('PR', unread ? '...' : 'none yet')
          ) : (
            <Box flexDirection="column">
              <Text>
                {label('PR')}
                <Link href={pr.url}>{cut(`#${pr.number} ${pr.title}`, room)}</Link>
              </Text>
              <Text>
                {label('')}
                {pr.state.toLowerCase()} · <Text {...LOOKS[checks.look]}>{checks.text}</Text>
              </Text>
            </Box>
          )}
          {lines('WORK', work)}
          <Text>
            {label('STATE')}
            <Text backgroundColor={look.bg} color={look.fg}>
              {' '}
              {`${VERBS[data.state] ?? (data.state || '?')} ${age(data.since, now)}`}{' '}
            </Text>
          </Text>
          {data.detail !== '' && lines('', data.detail)}
        </Box>
        <Box flexDirection="column" marginTop={1}>
          {bottom === null
            ? items.map(item => (
                <Text key={`summary-${item.label}`}>
                  <Text dimColor>{item.label.padEnd(11)}</Text> <Text>{item.value}</Text>
                </Text>
              ))
            : drawRows($, ui, bottom, 'summary')}
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
