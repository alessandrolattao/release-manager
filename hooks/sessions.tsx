import type { ApiContentBlock, EngineInterface, Register } from 'claude-code'

// A session's look and goal, set without typing into it.
//
// color.sh, rename.sh and role.sh write what a session should be in its own folder,
// <state>/release-manager/sessions/<session id>/ (see skills/run/scripts/session-dir.sh). This module
// runs inside every session: while its session is between turns it applies what changed with /color,
// /rename and /goal through the engine, so nothing reaches the prompt box where the user may be
// writing. A command run mid-turn would wait in the queue until the turn ends, so the module waits
// itself. The rows /color and /rename leave in the conversation are emptied and hidden; /goal's stay.
//
// A session with a role (the release manager or the planner) also writes `alive`, the time in seconds,
// every minute: hooks/revive.sh resumes after a restart the ones that were alive when the machine went down.

const WANTS = [
  { file: 'color', command: 'color', isHidden: true },
  { file: 'name', command: 'rename', isHidden: true },
  { file: 'goal', command: 'goal', isHidden: false },
] as const

const TICK_MS = 2000
const ALIVE_EVERY_TICKS = 30
const EXPECT_MS = 15000

let sessionsDir: string | undefined
let isBusy = false
let isSyncing = false
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

async function tick($: EngineInterface): Promise<void> {
  if (isSyncing) {
    return
  }
  isSyncing = true
  try {
    const folder = await folderOf($)
    const now = await $.clock.now()
    expected = expected.filter(x => x.until > now)
    if (ticks++ % ALIVE_EVERY_TICKS === 0 && (await $.fs.exists(`${folder}/role`))) {
      await $.fs.write(`${folder}/alive`, `${Math.floor(now / 1000)}\n`)
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
      if (want.isHidden) {
        expected.push({ command: want.command, args: value, until: now + EXPECT_MS })
        hidden.push(`${want.command} ${value}`)
        hidden.splice(0, Math.max(0, hidden.length - 50))
      }
      await runWant($, want.command, value)
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
    $.clock.every(TICK_MS, () => {
      void tick($)
    })
    return result
  })

  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) {
      isBusy = true
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) {
      isBusy = false
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
