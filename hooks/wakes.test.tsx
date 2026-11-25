import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const NOW = 1_800_000_000_000
const START = { cwd: '/repo', surface: null, isInteractive: false } as const

// The session's folder as the scripts leave it, by file name; what the module writes lands in it too.
// An inbox, when given, is what a tech lead's repository holds in <data>/team/inbox/<repo>/new.
function folder(on: On, seed: Record<string, string>, inbox: string[] = []): Map<string, string> {
  const files = new Map(Object.entries(seed))
  on('session.id', () => ({ value: 'abc-123' }))
  const name = (path: string) => path.slice(path.lastIndexOf('/') + 1)
  on('fs.read', (_$, e) => {
    const text = files.get(name(e.path))
    if (text === undefined) {
      throw new Error(`ENOENT: ${e.path}`)
    }
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    files.set(name(e.path), e.text)
    return { value: undefined }
  })
  on('fs.list', (_$, e) => ({
    value: e.path.endsWith('/inbox/acme_shop/new') ? inbox.map(n => ({ name: n, kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false })) : [],
  }))
  return files
}

// What the engine answers beneath the plugins at the start of a session.
function engine(on: On, logs: string[] = []): void {
  on('session.start', () => ({ cwd: '/repo' }))
  on('ui.log', (_$, e) => {
    logs.push(JSON.stringify(e))
    return { value: undefined }
  })
  on('command.register', () => ({ value: { command: 'team' } }))
  // /color and /rename, which the module runs between turns.
  on('command.run', () => ({ text: '' }))
}

function prompts(on: On): string[] {
  const seen: string[] = []
  on('prompt.submit', (_$, e) => {
    seen.push(e.text)
    return { text: e.text }
  })
  return seen
}

test('a team session is woken between turns with what was written to it, once', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const files = folder(on, {
    role: 'dev',
    status: JSON.stringify({ role: 'dev', state: 'others', detail: 'the tech lead' }),
    wake: `${NOW / 1000}\ttech lead on #42\tUsa la tabella users\thttps://x/42#c101\n`,
  })
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs)

  await $.session.start(START)
  // Stopped for less than a few seconds: not yet.
  await clock.advance(2000)
  expect(seen).toEqual([])
  await clock.advance(4000)
  expect(logs).toEqual([])
  expect(seen).toEqual(['for you on GitHub: tech lead on #42: Usa la tabella users (https://x/42#c101)'])
  expect(files.get('wake-read')).toBe('1\n')
  await clock.advance(4000)
  expect(seen.length).toBe(1)
})

test('a session outside the team is never woken and runs nothing', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const files = folder(on, { wake: `${NOW / 1000}\ttech lead on #42\tsomething\t\n` })
  const seen = prompts(on)
  engine(on)

  await $.session.start(START)
  await clock.advance(10000)
  expect(seen).toEqual([])
  expect(files.has('wake-read')).toBe(false)
})

test('a tech lead waiting on the user in its chat is left alone; one that asked on GitHub hears the answer', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'you', detail: 'Come lo chiamiamo?' }),
    wake: `${NOW / 1000}\ttester on #44\tchiamalo pippo\t\n`,
  }, ['m1'])
  const seen = prompts(on)
  engine(on)

  await $.session.start(START)
  await clock.advance(10000)
  expect(seen).toEqual([])

  files.set('status', JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'you', detail: 'Come lo chiamiamo?', asked_on: '44' }))
  await clock.advance(2000)
  expect(seen.length).toBe(1)
  expect(seen[0]).toMatch(/^for you on GitHub: tester on #44: chiamalo pippo; 1 message\(s\) from other repositories: sh ".*\/scripts\/inbox\.sh" read$/)
})

test('the user writing to a team session ends its wait; the plugin\'s own prompts do not', async ($, on) => {
  mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const waiting = JSON.stringify({ role: 'dev', state: 'you', detail: 'which port?', resume_to: { state: 'you', detail: 'x', since: 1 } })
  const files = folder(on, { role: 'dev', status: waiting })
  const origins: string[] = []
  const logs: string[] = []
  on('ui.log', (_$, e) => {
    logs.push(JSON.stringify(e))
    return { value: undefined }
  })
  on('prompt.submit', (_$, e) => {
    origins.push(e.origin.kind)
    return { text: e.text }
  })

  type Submit = Parameters<typeof $.prompt.submit>[0]
  // A wake the plugin submitted: not the user, the wait stays.
  await $.prompt.submit({ text: 'for you on GitHub: tech lead on #43: 4000', origin: { kind: 'plugin', name: 'team' } } as Submit)
  expect(JSON.parse(files.get('status') ?? '{}').state).toBe('you')
  // As the engine stamps a prompt typed at the session's prompt.
  await $.prompt.submit({ text: 'usa la 4000', origin: { kind: 'composer' } } as Submit)
  expect(origins).toEqual(['plugin', 'composer'])
  expect(logs).toEqual([])
  const status = JSON.parse(files.get('status') ?? '{}') as { state?: string; detail?: string; resume_to?: unknown }
  expect(`${status.state} ${status.detail}`).toBe('working with you')
  expect(status.resume_to).toBe(undefined)
})

test('a tech lead the user comes back to after a pause hears that its inbox holds messages', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  folder(on, { role: 'tech-lead', status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }) }, ['m1', 'm2'])
  const contexts: string[][] = []
  on('prompt.submit', (_$, e) => {
    contexts.push([...(e.context ?? [])])
    return { text: e.text }
  })
  type Submit = Parameters<typeof $.prompt.submit>[0]

  await $.prompt.submit({ text: 'come siamo messi?', origin: { kind: 'composer' } } as Submit)
  await clock.advance(60000)
  await $.prompt.submit({ text: 'e poi?', origin: { kind: 'composer' } } as Submit)
  expect(contexts[0]?.join(' ')).toMatch(/^📨 2 message\(s\) from other repositories wait in your inbox/)
  // A minute later it is the same conversation: no note again.
  expect(contexts[1]).toEqual([])
})
