import type { On } from 'claude-code'
import { expect, mock, test, type Engine } from 'claude-code/testing'

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
  on('fs.exists', (_$, e) => ({ value: files.has(name(e.path)) }))
  on('fs.list', (_$, e) => ({
    value: e.path.endsWith('/inbox/acme_shop/new') ? inbox.map(n => ({ name: n, kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false })) : [],
  }))
  return files
}

// How a process the module runs ends: its exit status and what it wrote to standard error.
type Ran = { exitCode: number; stderr: string }

// What the engine answers beneath the plugins at the start of a session. The processes the module runs (a
// tech lead starting its dispatcher, a lookup of a comment on GitHub) are recorded, their command lines
// joined by spaces, and succeed unless `ran` says otherwise for that command line.
function engine(on: On, logs: string[] = [], published = '9.9.9', toasts: string[] = [], ran: (run: string) => Ran | undefined = () => undefined): string[] {
  const runs: string[] = []
  on('session.start', () => ({ cwd: '/repo' }))
  on('ui.log', (_$, e) => {
    logs.push(JSON.stringify(e))
    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('command.register', () => ({ value: { command: 'team' } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.cwd', () => ({ value: '/repo' }))
  // /color and /rename, which the module runs between turns.
  on('command.run', () => ({ text: '' }))
  // The version published on the plugin's repository: the one running.
  on('http.fetch', () => ({ value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ name: 'team', version: published }) } }))
  on('process.run', (_$, e) => {
    const run = e.argv.join(' ')
    runs.push(run)
    const { exitCode, stderr } = ran(run) ?? { exitCode: 0, stderr: '' }
    return { value: { exitCode, stdout: exitCode === 0 ? 'the dispatcher runs' : '', stderr, isStdoutTruncated: false, isStderrTruncated: false } }
  })
  return runs
}

// GitHub as gh answers a lookup of a comment (`gh api repos/acme/shop/issues/comments/<id> --silent`): 404 for
// the ids deleted, the error given for the ids failing otherwise, nothing for the rest, which exist.
function github(deleted: string[], failing: Record<string, string> = {}): (run: string) => Ran | undefined {
  return run => {
    const id = /^gh api repos\/acme\/shop\/issues\/comments\/(\d+) --silent$/.exec(run)?.[1]
    if (id === undefined) {
      return undefined
    }
    if (deleted.includes(id)) {
      return { exitCode: 1, stderr: 'gh: Not Found (HTTP 404)\n' }
    }
    return failing[id] === undefined ? undefined : { exitCode: 1, stderr: failing[id] }
  }
}

// A comment's link as dispatch.sh writes it, on an issue or on a pull request of acme/shop.
const link = (id: number, on = 'issues/42') => `https://github.com/acme/shop/${on}#issuecomment-${id}`

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
  // A developer opens its pane by itself: no surface in a test.
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
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

// The plugin's manifest, which a tech lead's update check reads: the version published is the one running.
const MANIFEST = '{"name":"team","version":"9.9.9","repository":"https://github.com/acme/team"}'

// The engine beneath the turns the module hears, and one turn the wake started: it starts and ends on an
// answer, with no script changing the state in between.
function turns(on: On): void {
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
}

async function wokenTurn($: Engine): Promise<void> {
  await $.turn.start({ text: '', turnId: 't1' })
  await $.turn.complete({ answer: 'fatto', durationMs: 1000, isAborted: false, turnId: 't1', reason: 'answer' })
}

type Waiting = { state?: string; detail?: string; waits_on?: string; resume_to?: unknown }

function statusOf(files: Map<string, string>): Waiting {
  return JSON.parse(files.get('status') ?? '{}') as Waiting
}

test('a developer waiting on the tech lead, woken by the tech lead, is answered and stays working after the turn', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const files = folder(on, {
    role: 'dev',
    status: JSON.stringify({ role: 'dev', issue: 42, state: 'others', detail: 'waits for tech lead: which table?', waits_on: 'tech lead' }),
    wake: `${NOW / 1000}\ttech lead on #42\tUsa la tabella users\thttps://x/42#c101\n`,
  })
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs)
  turns(on)

  await $.session.start(START)
  await clock.advance(6000)
  expect(seen.length).toBe(1)
  let status = statusOf(files)
  expect(`${status.state} · ${status.detail}`).toBe('working · answered by tech lead')
  expect(status.waits_on).toBe(undefined)
  expect(status.resume_to).toBe(undefined)

  await wokenTurn($)
  expect(logs).toEqual([])
  status = statusOf(files)
  expect(`${status.state} · ${status.detail}`).toBe('working · answered by tech lead')
})

test('a developer waiting on the tech lead, woken by someone else, is back to waiting after the turn', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const files = folder(on, {
    role: 'dev',
    status: JSON.stringify({ role: 'dev', issue: 42, state: 'others', detail: 'waits for tech lead: which table?', waits_on: 'tech lead' }),
    wake: `${NOW / 1000}\tqa #42 on #42\tLa pagina non carica\thttps://x/50#c102\n`,
  })
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs)
  turns(on)

  await $.session.start(START)
  await clock.advance(6000)
  expect(seen.length).toBe(1)
  expect(statusOf(files).state).toBe('others')

  await wokenTurn($)
  expect(logs).toEqual([])
  const status = statusOf(files)
  expect(`${status.state} · ${status.detail}`).toBe('others · waits for tech lead: which table?')
  expect(status.waits_on).toBe('tech lead')
})

test('a tech lead that asked the user on GitHub, woken by the user\'s answer, no longer waits on the user', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'you', detail: 'Come lo chiamiamo?', asked_on: 44, waits_on: 'the user' }),
    wake: `${NOW / 1000}\tthe user on #44\tchiamalo pippo\thttps://x/44#c201\n`,
  })
  const seen = prompts(on)
  engine(on)
  turns(on)

  await $.session.start(START)
  await clock.advance(6000)
  expect(seen.length).toBe(1)
  let status = statusOf(files)
  expect(`${status.state} · ${status.detail}`).toBe('working · answered by the user')
  expect(status.waits_on).toBe(undefined)

  await wokenTurn($)
  status = statusOf(files)
  expect(status.state).not.toBe('you')
  expect(status.resume_to).toBe(undefined)
})

test('a tech lead waiting on the user in its chat is woken by the user\'s GitHub comment, with every fresh line, and no longer waits', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'you', detail: 'Come lo chiamiamo?' }),
    wake: `${at}\tdev #42 on #42\tQuale tabella?\thttps://x/42#c301\n${at + 30}\tthe user on #44\tchiamalo pippo\thttps://x/44#c302\n`,
    'plugin.json': MANIFEST,
  }, ['m1'])
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs)
  turns(on)

  await $.session.start(START)
  await clock.advance(6000)
  expect(logs).toEqual([])
  expect(seen.length).toBe(1)
  expect(seen[0]).toMatch(
    /^for you on GitHub: dev #42 on #42: Quale tabella\? \(https:\/\/x\/42#c301\); the user on #44: chiamalo pippo \(https:\/\/x\/44#c302\); 1 message\(s\) from other repositories: sh ".*\/scripts\/inbox\.sh" read$/,
  )
  expect(files.get('wake-read')).toBe('2\n')
  let status = statusOf(files)
  expect(`${status.state} · ${status.detail}`).toBe('working · answered by the user')
  expect(status.resume_to).toBe(undefined)

  await wokenTurn($)
  status = statusOf(files)
  expect(status.state).toBe('idle')
})

test('a wake for a comment the session already answered on GitHub starts no turn', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }),
    wake: `${at}\tthe user on #44\tchiamalo pippo\thttps://x/44#c302\n`,
    // A note on the thread after the comment: the user's comment is answered.
    commented: `${at + 60}\t44\t\n`,
    'plugin.json': MANIFEST,
  })
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs)

  await $.session.start(START)
  await clock.advance(10000)
  expect(logs).toEqual([])
  expect(seen).toEqual([])
  expect(files.get('wake-read')).toBe('1\n')
})

test('an agent\'s comment is answered only by a later comment to that agent; the user\'s only on its thread', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }),
    wake: [
      `${at}\tdev #42 on #42\tQuale tabella?\thttps://x/42#c301`,
      `${at}\tqa #42 on #42\tLa pagina non carica\thttps://x/50#c302`,
      `${at}\tthe user on #45\taltro tema\thttps://x/45#c303`,
      `${at}\tcheckout\tthe main checkout is free: take it now with checkout.sh take\t`,
      '',
    ].join('\n'),
    // Both agents' comments had reached the tech lead (mentions.sh listed them) before its comments below.
    seen: `${at + 5}\thttps://x/42#c301\n${at + 5}\thttps://x/50#c302\n`,
    commented: [
      // Before the comments: nothing is answered by it.
      `${at - 30}\t42\tdev #42`,
      // A note on the thread, and a comment to someone else: not an answer to the developer.
      `${at + 30}\t42\t`,
      `${at + 40}\t42\tqa #42`,
      // The user's comment on #45 is not answered on #44.
      `${at + 50}\t44\t`,
      '',
    ].join('\n'),
    'plugin.json': MANIFEST,
  })
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs)

  await $.session.start(START)
  await clock.advance(6000)
  expect(logs).toEqual([])
  expect(seen).toEqual([
    'for you on GitHub: dev #42 on #42: Quale tabella? (https://x/42#c301); the user on #45: altro tema (https://x/45#c303); checkout: the main checkout is free: take it now with checkout.sh take',
  ])
  expect(files.get('wake-read')).toBe('4\n')
})

test('a question to the tech lead it wrote to the asker about before the question reached it is still delivered, and then seen', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }),
    wake: `${at}\tdev #42 on #42\tQuale tabella?\t${link(301)}\n`,
    // Written to the developer mid-turn, after the question was asked but before any wake or list showed it.
    commented: `${at + 30}\t42\tdev #42\n`,
    seen: `${at - 600}\t${link(200)}\n`,
    'plugin.json': MANIFEST,
  })
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs, '9.9.9', [], github([]))

  await $.session.start(START)
  await clock.advance(6000)
  expect(logs).toEqual([])
  expect(seen).toEqual([`for you on GitHub: dev #42 on #42: Quale tabella? (${link(301)})`])
  // Delivered: it has reached the tech lead now, after what was there already.
  const [before, added, ...rest] = (files.get('seen') ?? '').split('\n')
  expect(before).toBe(`${at - 600}\t${link(200)}`)
  const [time, delivered] = (added ?? '').split('\t')
  expect(delivered).toBe(link(301))
  expect(Number(time)).toBeGreaterThanOrEqual(NOW / 1000)
  expect(rest).toEqual([''])
})

test('a question to the tech lead mentions.sh listed, then written to, is not delivered', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }),
    wake: `${at}\tdev #42 on #42\tQuale tabella?\t${link(301)}\n`,
    // Listed by mentions.sh, listed again later: the first time it reached the tech lead counts.
    seen: `${at + 10}\t${link(301)}\n${at + 60}\t${link(301)}\n`,
    commented: `${at + 30}\t42\tdev #42\n`,
    'plugin.json': MANIFEST,
  })
  const seen = prompts(on)
  const logs: string[] = []
  const runs = engine(on, logs, '9.9.9', [], github([]))

  await $.session.start(START)
  await clock.advance(10000)
  expect(logs).toEqual([])
  expect(seen).toEqual([])
  expect(files.get('wake-read')).toBe('1\n')
  expect(lookups(runs)).toEqual([])
  expect(files.get('seen')).toBe(`${at + 10}\t${link(301)}\n${at + 60}\t${link(301)}\n`)
})

test('a tech lead waiting in its chat is left alone for the user\'s comment it already answered', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'you', detail: 'Come lo chiamiamo?' }),
    wake: `${at}\tthe user on #44\tchiamalo pippo\thttps://x/44#c302\n`,
    commented: `${at + 60}\t44\tdev #44\n`,
  })
  const seen = prompts(on)
  engine(on)

  await $.session.start(START)
  await clock.advance(10000)
  expect(seen).toEqual([])
  expect(statusOf(files).state).toBe('you')
})

// The lookups of comments on GitHub among the processes the module ran, in order.
const lookups = (runs: string[]) => runs.filter(run => run.startsWith('gh api repos/acme/shop/issues/comments/'))

test('a queued wake whose comment was deleted is not delivered', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'dev',
    status: JSON.stringify({ role: 'dev', issue: 42, state: 'others', detail: 'waits for tech lead: which table?', waits_on: 'tech lead' }),
    wake: `${at}\ttech lead on #42\tUsa la tabella users\t${link(101)}\n`,
  })
  const seen = prompts(on)
  const logs: string[] = []
  const runs = engine(on, logs, '9.9.9', [], github(['101']))

  await $.session.start(START)
  await clock.advance(10000)
  expect(logs).toEqual([])
  expect(seen).toEqual([])
  expect(files.get('wake-read')).toBe('1\n')
  expect(lookups(runs)).toEqual(['gh api repos/acme/shop/issues/comments/101 --silent'])
  // Nothing reached it: it still waits.
  expect(statusOf(files).waits_on).toBe('tech lead')
})

test('a queued wake a developer already answered on its thread is not delivered, and GitHub is not asked', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'dev',
    status: JSON.stringify({ role: 'dev', issue: 42, state: 'working', detail: 'at work' }),
    wake: [
      `${at}\treview #42 on #42\tFAIL: manca il test\t${link(101)}`,
      `${at + 40}\tqa #42 on #42\tLa pagina non carica\t${link(102, 'pull/50')}`,
      '',
    ].join('\n'),
    commented: [
      // A note on the thread answers the reviewer's comment before it.
      `${at + 30}\t42\t`,
      // A comment to the tech lead answers the QA agent's too: a developer's answer is anything it wrote after.
      `${at + 50}\t42\ttech lead`,
      '',
    ].join('\n'),
  })
  const seen = prompts(on)
  const logs: string[] = []
  const runs = engine(on, logs, '9.9.9', [], github([]))

  await $.session.start(START)
  await clock.advance(10000)
  expect(logs).toEqual([])
  expect(seen).toEqual([])
  expect(files.get('wake-read')).toBe('2\n')
  expect(lookups(runs)).toEqual([])
})

test('a tech lead line is delivered to a developer that commented after it', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'dev',
    status: JSON.stringify({ role: 'dev', issue: 42, state: 'working', detail: 'at work' }),
    wake: `${at}\ttech lead on #42\tUsa la tabella users\t${link(101)}\n`,
    // A note and a comment to the tech lead after it: neither drops the tech lead's line.
    commented: `${at + 30}\t42\t\n${at + 50}\t42\ttech lead\n`,
  })
  const seen = prompts(on)
  const logs: string[] = []
  const runs = engine(on, logs, '9.9.9', [], github([]))

  await $.session.start(START)
  await clock.advance(10000)
  expect(logs).toEqual([])
  expect(seen).toEqual([`for you on GitHub: tech lead on #42: Usa la tabella users (${link(101)})`])
  expect(files.get('wake-read')).toBe('1\n')
  // Only a deleted comment is dropped: GitHub is asked about it.
  expect(lookups(runs)).toEqual(['gh api repos/acme/shop/issues/comments/101 --silent'])
})

test('a queued wake with another comment left is delivered with that one only', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'dev',
    status: JSON.stringify({ role: 'dev', issue: 42, state: 'working', detail: 'at work' }),
    wake: [
      `${at + 20}\ttech lead on #42\tcopia cancellata\t${link(101)}`,
      `${at}\tqa #42 on #42\tgià risposto\t${link(102)}`,
      `${at + 20}\ttech lead on #42\tUsa la tabella users\t${link(103)}`,
      // GitHub failing otherwise tells nothing: the comment stays.
      `${at + 20}\tqa #42 on #42\tLa pagina non carica\t${link(104, 'pull/50')}`,
      `${at + 30}\tcheckout\tthe main checkout is free: take it now with checkout.sh take\t`,
      '',
    ].join('\n'),
    commented: `${at + 10}\t42\t\n`,
  })
  const seen = prompts(on)
  const logs: string[] = []
  const runs = engine(on, logs, '9.9.9', [], github(['101'], { '104': 'gh: Bad Gateway (HTTP 502)\n' }))

  await $.session.start(START)
  await clock.advance(10000)
  expect(logs).toEqual([])
  expect(seen).toEqual([
    `for you on GitHub: tech lead on #42: Usa la tabella users (${link(103)}); qa #42 on #42: La pagina non carica (${link(104, 'pull/50')}); checkout: the main checkout is free: take it now with checkout.sh take`,
  ])
  expect(files.get('wake-read')).toBe('5\n')
  // The answered comment is never looked up; each other comment once.
  expect([...lookups(runs)].sort()).toEqual([101, 103, 104].map(id => `gh api repos/acme/shop/issues/comments/${id} --silent`))
})

test('a tech lead waiting in its chat is left alone for the user\'s deleted comment, asked about once', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'you', detail: 'Come lo chiamiamo?' }),
    wake: [`${at}\tdev #42 on #42\tQuale tabella?\t${link(201)}`, `${at + 30}\tthe user on #44\tchiamalo pippo\t${link(202, 'issues/44')}`, ''].join('\n'),
    'dispatcher.alive': String(NOW / 1000),
    'plugin.json': MANIFEST,
  })
  const seen = prompts(on)
  const logs: string[] = []
  const runs = engine(on, logs, '9.9.9', [], github(['202']))

  await $.session.start(START)
  await clock.advance(20000)
  expect(logs).toEqual([])
  expect(seen).toEqual([])
  expect(statusOf(files).state).toBe('you')
  expect(files.has('wake-read')).toBe(false)
  expect([...lookups(runs)].sort()).toEqual([201, 202].map(id => `gh api repos/acme/shop/issues/comments/${id} --silent`))
})

// A request of the main loop to the model, in the turn given, answered beneath the plugins.
function requests(on: On): void {
  on('turn.step', async function* (_$, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
  })
}

async function request($: Engine, turnId = 't1', index = 0): Promise<void> {
  for await (const _ of $.turn.step({ turnId, index, model: 'claude-opus-5-5', messageCount: 1 })) {
    // The response's pieces: none here.
  }
}

// The text of each note a plugin appended to the conversation, in order.
const notes = (session: { appended: () => readonly { door: string; message: { content: readonly { type: string; [field: string]: unknown }[] } }[] }) =>
  session.appended().filter(row => row.door === 'note').map(row => row.message.content.map(block => String(block.text ?? '')).join(''))

// The links of the repository's `seen`, in order.
const seenLinks = (files: Map<string, string>) => (files.get('seen') ?? '').split('\n').filter(line => line !== '').map(line => line.split('\t')[1])

type Submit = Parameters<Engine['prompt']['submit']>[0]

test('a question to a tech lead holding for the user goes into its conversation once, is seen once a request carries it, and wakes nobody', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'you', detail: 'Come lo chiamiamo?' }),
    wake: [`${at}\tdev #42 on #42\tQuale tabella?\t${link(301)}`, `${at + 10}\tcheckout\tthe main checkout is free: take it now with checkout.sh take\t`, ''].join('\n'),
    'dispatcher.alive': String(NOW / 1000),
    'plugin.json': MANIFEST,
  }, ['m1'])
  const session = mock.session(on)
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs, '9.9.9', [], github([]))
  turns(on)
  requests(on)

  await $.session.start(START)
  await clock.advance(6000)
  expect(logs).toEqual([])
  expect(notes(session)).toEqual([`for you on GitHub: dev #42 on #42: Quale tabella? (${link(301)})`])
  // No turn: the rest waits for the user, the checkout and the inbox included.
  expect(seen).toEqual([])
  expect(files.has('wake-read')).toBe(false)
  // The append resolved, and no request carried it yet: not seen.
  expect(files.has('seen')).toBe(false)
  await clock.advance(20000)
  expect(notes(session).length).toBe(1)

  // The user writes in the chat: the first request of that turn carries the note.
  await $.prompt.submit({ text: 'chiamalo pippo', origin: { kind: 'composer' } } as Submit)
  await $.turn.start({ text: 'chiamalo pippo', turnId: 't1' })
  expect(files.has('seen')).toBe(false)
  await request($)
  await clock.settle()
  expect(seenLinks(files)).toEqual([link(301)])
  await request($, 't1', 1)
  await clock.settle()
  expect(seenLinks(files)).toEqual([link(301)])
  await $.turn.complete({ answer: 'fatto', durationMs: 1000, isAborted: false, turnId: 't1', reason: 'answer' })

  // At rest after the turn: the question is not delivered again, what waited is.
  await clock.advance(6000)
  expect(logs).toEqual([])
  expect(seen.length).toBe(2)
  expect(seen[1]).toMatch(/^for you on GitHub: checkout: the main checkout is free: take it now with checkout\.sh take; 1 message\(s\) from other repositories: sh ".*\/scripts\/inbox\.sh" read$/)
  expect(files.get('wake-read')).toBe('2\n')
  expect(files.get('carried')).toBe('')
  expect(notes(session).length).toBe(1)
})

test('a question whose note is refused waits for the end of the hold, as before notes, asked about once', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'you', detail: 'Come lo chiamiamo?' }),
    wake: `${at}\tdev #42 on #42\tQuale tabella?\t${link(301)}\n`,
    'dispatcher.alive': String(NOW / 1000),
    'plugin.json': MANIFEST,
  })
  const refusals: string[] = []
  on('session.append', (_$, e) => {
    refusals.push(e.door)
    return { deny: 'no notes here' }
  })
  const seen = prompts(on)
  const logs: string[] = []
  const runs = engine(on, logs, '9.9.9', [], github([]))

  await $.session.start(START)
  await clock.advance(20000)
  expect(refusals).toEqual(['note'])
  expect(logs.length).toBe(1)
  expect(logs[0]).toContain('no notes here')
  expect(seen).toEqual([])
  expect(lookups(runs)).toEqual(['gh api repos/acme/shop/issues/comments/301 --silent'])

  files.set('status', JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }))
  await clock.advance(2000)
  expect(seen).toEqual([`for you on GitHub: dev #42 on #42: Quale tabella? (${link(301)})`])
  expect(refusals.length).toBe(1)
})

test('a question to a tech lead at rest wakes it as before, with no note', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const at = NOW / 1000 - 120
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }),
    wake: `${at}\tdev #42 on #42\tQuale tabella?\t${link(301)}\n`,
    'dispatcher.alive': String(NOW / 1000),
    'plugin.json': MANIFEST,
  })
  const session = mock.session(on)
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs, '9.9.9', [], github([]))

  await $.session.start(START)
  await clock.advance(6000)
  expect(logs).toEqual([])
  expect(seen).toEqual([`for you on GitHub: dev #42 on #42: Quale tabella? (${link(301)})`])
  expect(notes(session)).toEqual([])
  expect(seenLinks(files)).toEqual([link(301)])
})

test('a question to a tech lead busy in a turn goes into its conversation, and the turn\'s end wakes nobody for it', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }),
    'dispatcher.alive': String(NOW / 1000),
    'plugin.json': MANIFEST,
  })
  const session = mock.session(on)
  const seen = prompts(on)
  const logs: string[] = []
  const runs = engine(on, logs, '9.9.9', [], github([]))
  turns(on)
  requests(on)

  await $.session.start(START)
  await $.turn.start({ text: 'parliamo della 44', turnId: 't1' })
  await request($)
  // The dispatcher writes the question while the turn runs.
  files.set('wake', `${NOW / 1000}\tdev #42 on #42\tQuale tabella?\t${link(301)}\n`)
  await clock.advance(2000)
  expect(notes(session)).toEqual([`for you on GitHub: dev #42 on #42: Quale tabella? (${link(301)})`])
  expect(lookups(runs)).toEqual([`gh api repos/acme/shop/issues/comments/301 --silent`])
  await clock.advance(4000)
  expect(notes(session).length).toBe(1)
  expect(files.has('seen')).toBe(false)
  // The turn's next request carries it.
  await request($, 't1', 1)
  await clock.settle()
  expect(seenLinks(files)).toEqual([link(301)])
  await $.turn.complete({ answer: 'fatto', durationMs: 1000, isAborted: false, turnId: 't1', reason: 'answer' })

  await clock.advance(10000)
  expect(logs).toEqual([])
  expect(seen).toEqual([])
  expect(files.get('wake-read')).toBe('1\n')
  expect(statusOf(files).state).toBe('idle')
})

test('a question appended in a turn that ends with no request after it wakes the tech lead as before', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const files = folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }),
    'dispatcher.alive': String(NOW / 1000),
    'plugin.json': MANIFEST,
  })
  const session = mock.session(on)
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs, '9.9.9', [], github([]))
  turns(on)
  requests(on)

  await $.session.start(START)
  await $.turn.start({ text: 'parliamo della 44', turnId: 't1' })
  await request($)
  // It arrives while the turn's last answer is written.
  files.set('wake', `${NOW / 1000}\tdev #42 on #42\tQuale tabella?\t${link(301)}\n`)
  await clock.advance(2000)
  expect(notes(session).length).toBe(1)
  await $.turn.complete({ answer: 'fatto', durationMs: 1000, isAborted: false, turnId: 't1', reason: 'answer' })

  await clock.advance(6000)
  expect(logs).toEqual([])
  expect(seen).toEqual([`for you on GitHub: dev #42 on #42: Quale tabella? (${link(301)})`])
  expect(seenLinks(files)).toEqual([link(301)])
  expect(files.get('carried')).toBe('')
  // The turn it woke carries the note too: seen once.
  await $.turn.start({ text: '', turnId: 't2' })
  await request($, 't2')
  await clock.settle()
  expect(seenLinks(files)).toEqual([link(301)])
})

for (const [from, isAnswer] of [['dev #42', true], ['qa #42', false]] as const) {
  test(`a tech lead waiting on dev #42, busy in a turn, ${isAnswer ? 'stops waiting once dev #42\'s answer is carried' : 'still waits after a note from someone else'}`, async ($, on) => {
    const clock = mock.clock(on, { now: NOW })
    mock.env(on, { HOME: '/home/u' })
    on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
    const files = folder(on, {
      role: 'tech-lead',
      status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'others', detail: 'waits for dev #42: quale tabella?', waits_on: 'dev #42' }),
      'dispatcher.alive': String(NOW / 1000),
      'plugin.json': MANIFEST,
    })
    const session = mock.session(on)
    const logs: string[] = []
    engine(on, logs, '9.9.9', [], github([]))
    turns(on)
    requests(on)

    await $.session.start(START)
    await $.turn.start({ text: 'parliamo della 44', turnId: 't1' })
    files.set('wake', `${NOW / 1000}\t${from} on #42\tla tabella users\t${link(301)}\n`)
    await clock.advance(2000)
    expect(notes(session).length).toBe(1)
    await request($)
    await clock.settle()
    let status = statusOf(files)
    expect(`${status.state} · ${status.detail}`).toBe(isAnswer ? 'working · answered by dev #42' : 'working · at work')
    expect(status.waits_on).toBe(isAnswer ? undefined : 'dev #42')
    await $.turn.complete({ answer: 'fatto', durationMs: 1000, isAborted: false, turnId: 't1', reason: 'answer' })
    expect(logs).toEqual([])
    status = statusOf(files)
    expect(status.resume_to).toBe(undefined)
    expect(`${status.state} · ${status.waits_on}`).toBe(isAnswer ? 'idle · undefined' : 'others · dev #42')
  })
}

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

// A tech lead whose dispatcher had its last cycle an hour ago: stopped by a restart of the machine.
function stoppedDispatcher(on: On, extra: Record<string, string> = {}): void {
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  folder(on, {
    role: 'tech-lead',
    status: JSON.stringify({ role: 'tech-lead', repo: 'acme/shop', state: 'idle', detail: 'waiting for work' }),
    'dispatcher.alive': String(NOW / 1000 - 3600),
    cwd: '/repo',
    'plugin.json': '{"name":"team","version":"9.9.9","repository":"https://github.com/acme/team"}',
    ...extra,
  })
}

test('a tech lead starts its stopped dispatcher, and does not try again at once', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  stoppedDispatcher(on)
  const logs: string[] = []
  const runs = engine(on, logs)

  await $.session.start(START)
  await clock.advance(4000)
  expect(logs).toEqual([])
  expect(runs.filter(run => run.endsWith('/scripts/dispatcher.sh start')).length).toBe(1)
  await clock.advance(20000)
  expect(runs.length).toBe(1)
})

test('a dispatcher the user stopped stays stopped', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  stoppedDispatcher(on, { 'dispatcher.stopped': String(NOW / 1000 - 60) })
  const runs = engine(on)

  await $.session.start(START)
  await clock.advance(8000)
  expect(runs).toEqual([])
})

test('a tech lead finds a newer version of the plugin and says so, once', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  stoppedDispatcher(on, { 'dispatcher.alive': String(NOW / 1000) })
  const toasts: string[] = []
  const runs = engine(on, [], '9.10.0', toasts)

  await $.session.start(START)
  await clock.advance(4000)
  expect(toasts).toEqual(['team 9.10.0 is out: click update at the foot of the board'])
  expect(runs).toEqual([])
  await clock.advance(20000)
  expect(toasts.length).toBe(1)
})

test("the effort of the session's requests to the model is kept for the summary", async ($, on) => {
  mock.clock(on, { now: NOW })
  on('turn.step', async function* (_$, e) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  const written: string[] = []
  on('state.set', (_$, e, next) => {
    if (e.key === 'effort') {
      written.push(String(e.value))
    }
    return next(e)
  })

  for await (const _ of $.turn.step({ turnId: 't1', index: 0, model: 'claude-opus-5-5', effort: 'xhigh', messageCount: 1 })) {
    // The response's pieces: none here.
  }
  expect(written).toEqual(['xhigh'])
})

const LIMIT_WAKE = 'The usage limit has reset: go on where you stopped.'

type Window = { window: string; outcome: string; used: number; resets_at: string }

// The plan usage the dispatcher keeps for the board (clessidra --json) for the config folder /home/u/.claude,
// with these windows, each reset written as clessidra writes a time.
function plan(windows: Window[]): Record<string, string> {
  return {
    '_home_u_.claude.json': JSON.stringify({
      account: '/home/u/.claude',
      windows: windows.map(w => ({ ...w, runs_out_at: null, short_by_minutes: null })),
    }),
  }
}

// Times around NOW (2027-01-15T08:00:00Z).
const IN_A_MINUTE = '2027-01-15T09:01:00.873694+01:00'
const IN_THREE_MINUTES = '2027-01-15T09:03:00.000000+01:00'
const A_MINUTE_AGO = '2027-01-15T08:59:00.873694+01:00'
const NEXT_WEEK = '2027-01-20T09:00:00.000000+01:00'

// The 5-hour window at its limit, resetting at `reset`, the weekly one far from it.
function usage(reset: string): Record<string, string> {
  return plan([
    { window: '5h', outcome: 'limit_reached', used: 100, resets_at: reset },
    { window: '7d', outcome: 'lasts', used: 40, resets_at: NEXT_WEEK },
  ])
}

// A turn of the main loop that ends on an API error, as Claude Code ends it: its StopFailure, then its end.
async function failingTurn($: Engine, error: 'rate_limit' | 'server_error' = 'rate_limit', agentId?: string): Promise<void> {
  await $.turn.start({ text: '', turnId: 't0' })
  await $.classic.StopFailure({ error, last_assistant_message: 'API Error: Rate limit reached', ...(agentId === undefined ? {} : { agent_id: agentId }) })
  await $.turn.complete({ answer: '', durationMs: 1000, isAborted: false, turnId: 't0', reason: 'error' })
}

// A session of that role, idle at its last turn's end, the plan usage given beside its folder.
function limited(on: On, role: string, plan: Record<string, string>): { seen: string[]; logs: string[]; files: Map<string, string> } {
  mock.env(on, { HOME: '/home/u' })
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  const files = folder(on, { role, status: JSON.stringify({ role, issue: 42, state: 'working', detail: 'at work' }), ...plan })
  const seen = prompts(on)
  const logs: string[] = []
  engine(on, logs)
  turns(on)
  // No settings hook beneath: the StopFailure has nothing to answer.
  on('classic.StopFailure', () => ({}))
  return { seen, logs, files }
}

for (const [role, who] of [['dev', 'developer'], ['tech-lead', 'tech lead'], ['qa', 'QA agent']] as const) {
  test(`a ${who} stopped on the usage limit is woken once the limit has reset: never before, never twice`, async ($, on) => {
    const clock = mock.clock(on, { now: NOW })
    const { seen, logs } = limited(on, role, usage(IN_A_MINUTE))

    await $.session.start(START)
    await failingTurn($)
    await clock.advance(58000)
    expect(seen).toEqual([])
    await clock.advance(4000)
    expect(seen).toEqual([LIMIT_WAKE])
    await clock.advance(10000)
    expect(seen.length).toBe(1)
    // The turn the wake started, and what follows it: no wake again for the same stop.
    await wokenTurn($)
    await clock.advance(60000)
    expect(seen.length).toBe(1)
    expect(logs).toEqual([])
  })
}

test('a session woken before the limit resets that goes on is not woken at the reset', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const { seen } = limited(on, 'dev', usage(IN_A_MINUTE))

  await $.session.start(START)
  await failingTurn($)
  await clock.advance(10000)
  await wokenTurn($)
  await clock.advance(120000)
  expect(seen).toEqual([])
})

test('a session stopped on the usage limit again after its wake is woken again at the next reset', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const { seen, files } = limited(on, 'dev', usage(IN_A_MINUTE))

  await $.session.start(START)
  await failingTurn($)
  await clock.advance(62000)
  expect(seen).toEqual([LIMIT_WAKE])
  // The woken turn stops on the limit again: the file still says the reset that passed, so nothing yet.
  await failingTurn($)
  await clock.advance(60000)
  expect(seen.length).toBe(1)
  // The dispatcher reads the plan usage again: the window's next reset, five minutes after NOW.
  files.set('_home_u_.claude.json', usage('2027-01-15T09:05:00.000000+01:00')['_home_u_.claude.json'] ?? '')
  await clock.advance(120000)
  expect(seen.length).toBe(1)
  await clock.advance(60000)
  expect(seen).toEqual([LIMIT_WAKE, LIMIT_WAKE])
})

test('no wake for a turn that ended on another API error', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const { seen } = limited(on, 'dev', usage(IN_A_MINUTE))

  await $.session.start(START)
  await failingTurn($, 'server_error')
  await clock.advance(120000)
  expect(seen).toEqual([])
})

test("no wake for a subagent's turn that ended on the usage limit", async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const { seen } = limited(on, 'dev', usage(IN_A_MINUTE))

  await $.session.start(START)
  await failingTurn($, 'rate_limit', 'a1')
  await clock.advance(120000)
  expect(seen).toEqual([])
})

test('no wake from a plan usage read before the window started', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const { seen } = limited(on, 'dev', usage(A_MINUTE_AGO))

  await $.session.start(START)
  await failingTurn($)
  await clock.advance(120000)
  expect(seen).toEqual([])
})

test('with no window at its limit yet, a session stopped on the usage limit is woken at the reset of the most used one', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const { seen } = limited(on, 'dev', plan([
    { window: '5h', outcome: 'runs_out', used: 60, resets_at: IN_A_MINUTE },
    { window: '7d', outcome: 'runs_out', used: 97, resets_at: IN_THREE_MINUTES },
  ]))

  await $.session.start(START)
  await failingTurn($)
  await clock.advance(120000)
  expect(seen).toEqual([])
  await clock.advance(70000)
  expect(seen).toEqual([LIMIT_WAKE])
  await clock.advance(60000)
  expect(seen.length).toBe(1)
})

test('with no window at its limit, no wake when the most used one reset before the stop', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const { seen } = limited(on, 'dev', plan([
    { window: '5h', outcome: 'runs_out', used: 97, resets_at: A_MINUTE_AGO },
    { window: '7d', outcome: 'lasts', used: 40, resets_at: IN_A_MINUTE },
  ]))

  await $.session.start(START)
  await failingTurn($)
  await clock.advance(120000)
  expect(seen).toEqual([])
})

test('no wake with no plan usage to read', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  const { seen, logs } = limited(on, 'dev', {})

  await $.session.start(START)
  await failingTurn($)
  await clock.advance(120000)
  expect(seen).toEqual([])
  expect(logs).toEqual([])
})
