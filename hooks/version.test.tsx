import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const NOW = 1_800_000_000_000
const START = { cwd: '/repo', surface: null, isInteractive: false } as const
const FOLDER = '/home/u/.local/state/team/sessions/abc-123'

// The session's folder as the scripts leave it and the plugin's manifest, by file name; every write is
// recorded with its path, in order.
function files(on: On, seed: Record<string, string>): { files: Map<string, string>; writes: string[] } {
  const all = new Map(Object.entries(seed))
  const writes: string[] = []
  on('session.id', () => ({ value: 'abc-123' }))
  const name = (path: string) => path.slice(path.lastIndexOf('/') + 1)
  on('fs.read', (_$, e) => {
    const text = all.get(name(e.path))
    if (text === undefined) {
      throw new Error(`ENOENT: ${e.path}`)
    }
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    all.set(name(e.path), e.text)
    writes.push(e.path)
    return { value: undefined }
  })
  on('fs.list', () => ({ value: [] }))
  return { files: all, writes }
}

// What the engine answers beneath the plugins; a developer opens its pane by itself, with no surface here.
function engine(on: On): void {
  on('session.start', () => ({ cwd: '/repo' }))
  on('ui.log', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'team' } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('command.run', () => ({ text: '' }))
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  on('process.run', () => ({ value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
}

const manifest = (version: string) => JSON.stringify({ name: 'team', version })

test('a team session writes the version it loaded in its folder at session start, once', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const { files: all, writes } = files(on, {
    'plugin.json': manifest('1.2.3'),
    role: 'dev',
    status: JSON.stringify({ role: 'dev', state: 'working', detail: 'starting' }),
  })
  engine(on)

  await $.session.start(START)
  expect(all.get('version')).toBe('1.2.3\n')
  expect(writes.filter(path => path === `${FOLDER}/version`).length).toBe(1)
  await clock.advance(10000)
  expect(writes.filter(path => path.endsWith('/version')).length).toBe(1)
})

test('a session outside the team writes nothing, and no folder is made for it', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const { writes } = files(on, { 'plugin.json': manifest('1.2.3') })
  engine(on)

  await $.session.start(START)
  await clock.advance(10000)
  expect(writes).toEqual([])
})

test('a new session gets its version at the first tick that finds the role role.sh wrote, the one loaded at start', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const { files: all, writes } = files(on, { 'plugin.json': manifest('1.2.3') })
  engine(on)

  await $.session.start(START)
  await clock.advance(2000)
  expect(all.has('version')).toBe(false)
  // role.sh records the session after it started; the plugin on disk has moved on since.
  all.set('role', 'dev')
  all.set('status', JSON.stringify({ role: 'dev', state: 'working', detail: 'starting' }))
  all.set('plugin.json', manifest('9.9.9'))
  await clock.advance(2000)
  expect(all.get('version')).toBe('1.2.3\n')
  expect(writes.filter(path => path === `${FOLDER}/version`).length).toBe(1)
  await clock.advance(10000)
  expect(writes.filter(path => path.endsWith('/version')).length).toBe(1)
})
