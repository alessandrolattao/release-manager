import type { ApiContentBlock, EngineInterface, Register } from 'claude-code'

// A session's look, set without typing into it.
//
// color.sh, rename.sh and role.sh write what a session should be in its own folder,
// <state>/release-manager/sessions/<session id>/ (see skills/run/scripts/session-dir.sh). This module
// runs inside every session: while its session is between turns it applies what changed with /color
// and /rename through the engine, so nothing reaches the prompt box where the user may be
// writing. A command run mid-turn would wait in the queue until the turn ends, so the module waits
// itself. The rows /color and /rename leave in the conversation are emptied and hidden.
//
// A session with a role (the release manager or the planner) also writes `alive`, the time in seconds,
// every minute: hooks/revive.sh resumes after a restart the ones that were alive when the machine went down.
// It writes `idle` too, the time its last turn ended, empty during a turn: hooks/session-events.sh wakes
// the session only between turns.
// In the planner, every 5 minutes, hooks/remind.sh says out loud what has waited 30 minutes for the user.

const WANTS = [
  { file: 'color', command: 'color' },
  { file: 'name', command: 'rename' },
] as const

const TICK_MS = 2000
const ALIVE_EVERY_TICKS = 30
const REMIND_EVERY_TICKS = 150
const REMIND_TIMEOUT_MS = 120000
const EXPECT_MS = 15000

let sessionsDir: string | undefined
let isBusy = false
let isSyncing = false
let isReminding = false
let ticks = 0
// What this process applied, by file: a value applied once is not applied again until it changes.
const applied = new Map<string, string>()
// The /color and /rename runs of the last seconds, whose rows are emptied and hidden.
let expected: { command: string; args: string; until: number }[] = []
const hidden: string[] = []

async function folderOf($: EngineInterface): Promise<string> {
  if (sessionsDir === undefined) {
    const state = (await $.env.get('XDG_STATE_HOME')) || `${(await $.env.get('HOME')) ?? ''}/.local/state`
    sessionsDir = `${state}/release-manager/sessions`
  }
  return `${sessionsDir}/${await $.session.id()}`
}

async function readWant($: EngineInterface, path: string): Promise<string> {
  try {
    return (await $.fs.read(path)).trim()
  } catch {
    return ''
  }
}

async function runWant($: EngineInterface, command: string, args: string): Promise<void> {
  try {
    await $.command.run({ command, args })
  } catch (err) {
    $.ui.log(`/${command} ${args}: ${String(err)}`)
  }
}

async function remind($: EngineInterface, folder: string): Promise<void> {
  if (isReminding) {
    return
  }
  isReminding = true
  try {
    const cwd = (await readWant($, `${folder}/cwd`)) || (await $.session.cwd())
    const script = `${$.plugin.root}/hooks/remind.sh`
    await $.process.run(['sh', script, await $.session.id()], { cwd, timeoutMs: REMIND_TIMEOUT_MS })
  } catch (err) {
    $.ui.log(`remind: ${String(err)}`)
  } finally {
    isReminding = false
  }
}

// Records whether the model of a session with a role, or of a developer agent, is stopped, and since when.
async function markTurn($: EngineInterface, isRunning: boolean): Promise<void> {
  try {
    const folder = await folderOf($)
    const isAgent = (await $.session.cwd()).includes('/.claude/worktrees/')
    if (!isAgent && (await readWant($, `${folder}/role`)) === '') {
      return
    }
    await $.fs.write(`${folder}/idle`, isRunning ? '' : `${Math.floor((await $.clock.now()) / 1000)}\n`)
  } catch (err) {
    $.ui.log(`idle: ${String(err)}`)
  }
}

async function tick($: EngineInterface): Promise<void> {
  if (isSyncing) {
    return
  }
  isSyncing = true
  try {
    const folder = await folderOf($)
    const now = await $.clock.now()
    expected = expected.filter(x => x.until > now)
    const tickNumber = ticks++
    if (tickNumber % ALIVE_EVERY_TICKS === 0) {
      const role = await readWant($, `${folder}/role`)
      if (role !== '') {
        await $.fs.write(`${folder}/alive`, `${Math.floor(now / 1000)}\n`)
      }
      if (role === 'planner' && tickNumber % REMIND_EVERY_TICKS === 0) {
        void remind($, folder)
      }
    }
    for (const want of WANTS) {
      if (isBusy) {
        break
      }
      const value = await readWant($, `${folder}/${want.file}`)
      if (value === '' || applied.get(want.file) === value) {
        continue
      }
      applied.set(want.file, value)
      expected.push({ command: want.command, args: value, until: now + EXPECT_MS })
      hidden.push(`${want.command} ${value}`)
      hidden.splice(0, Math.max(0, hidden.length - 50))
      await runWant($, want.command, value)
    }
    // A session started when the roles still had a goal loses it, once.
    if (!isBusy && (await readWant($, `${folder}/goal`)) !== '') {
      await $.fs.write(`${folder}/goal`, '')
      await runWant($, 'goal', 'clear')
    }
  } catch (err) {
    $.ui.log(`sessions: ${String(err)}`)
  } finally {
    isSyncing = false
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
      (text.includes(`<command-name>/${x.command}</command-name>`) &&
        text.includes(`<command-args>${x.args}</command-args>`)) ||
      (text.includes('<local-command-stdout>') && text.includes(x.args)),
  )
}

function emptied(content: readonly ApiContentBlock[]): ApiContentBlock[] {
  return content.map(block => (block.type === 'text' ? { ...block, text: '' } : block))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    if (!isBusy) {
      await markTurn($, false)
    }
    $.clock.every(TICK_MS, () => {
      void tick($)
    })
    return result
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
}
