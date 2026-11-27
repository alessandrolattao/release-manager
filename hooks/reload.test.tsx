import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const NOW = 1_800_000_000_000
const START = { cwd: '/repo', surface: null, isInteractive: false } as const
const FOLDER = '/home/u/.local/state/team/sessions/abc-123'
const CACHE = '/home/u/.claude/plugins/cache/team/team'
const RELOADED = 'Reloaded: 17 plugins · 209 skills · 12 agents · 23 hooks · 2 plugin MCP servers · 2 plugin LSP servers'

// The session's folder as the scripts leave it and the plugin's manifest, by file name; the versions of the
// plugin installed on an account, by the account's cache folder, as `claude plugin update` leaves them.
function files(on: On, seed: Record<string, string>, installed: Record<string, string[]> = { [CACHE]: [] }): { files: Map<string, string>; listed: string[] } {
  const all = new Map(Object.entries(seed))
  const listed: string[] = []
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
    return { value: undefined }
  })
  on('fs.list', (_$, e) => {
    listed.push(e.path)
    const versions = installed[e.path]
    if (versions === undefined) {
      return { value: [] }
    }
    return { value: versions.map(v => ({ name: v, kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: false })) }
  })
  return { files: all, listed }
}

// The engine beneath the plugin. Each slash command the module runs is recorded as `/<command> <args>`;
// /reload-plugins answers as `reload` says (its output, or a rejection when it throws), the others as /color
// and /rename do. Each process is recorded, its command line joined by spaces, and succeeds. The prompts the
// module submits are recorded.
function engine(on: On, reload: () => string = () => RELOADED): { commands: string[]; runs: string[]; prompts: string[] } {
  const commands: string[] = []
  const runs: string[] = []
  const prompts: string[] = []
  on('session.start', () => ({ cwd: '/repo' }))
  on('ui.log', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'team' } }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('ui.open', () => ({ value: { isPlaced: false, reason: 'no surface in a test' } }))
  on('http.fetch', () => ({ value: { status: 200, ok: true, headers: {}, text: '{"name":"team","version":"1.2.3"}' } }))
  on('command.run', (_$, e) => {
    commands.push(`/${e.command} ${e.args}`)
    return { text: e.command === 'reload-plugins' ? reload() : '' }
  })
  on('process.run', (_$, e) => {
    runs.push(e.argv.join(' '))
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('prompt.submit', (_$, e) => {
    prompts.push(e.text)
    return { text: e.text }
  })
  return { commands, runs, prompts }
}

const manifest = (version: string) => JSON.stringify({ name: 'team', version })
const reviewer = { role: 'review', status: JSON.stringify({ role: 'review', state: 'working', detail: 'reads #42' }) }
const reloads = (commands: string[]) => commands.filter(c => c.startsWith('/reload-plugins'))
const restarts = (runs: string[]) => runs.filter(r => r.includes('/scripts/update.sh restart'))

test('a session behind the newest version installed on its account reloads the plugin once, between turns', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  // Its account is the one its `config` names; the newest version there is 1.2.10, numbers compared as numbers.
  const account = '/home/u/.claude-work/plugins/cache/team/team'
  const { files: all, listed } = files(on, { 'plugin.json': manifest('1.2.3'), config: '/home/u/.claude-work', ...reviewer }, { [account]: ['1.2.3', '1.2.9', '1.2.10'], [CACHE]: ['9.9.9'] })
  const { commands, runs, prompts } = engine(on)

  await $.session.start(START)
  expect(reloads(commands)).toEqual([])
  await clock.advance(2000)
  expect(listed).toContain(account)
  expect(listed).not.toContain(CACHE)
  expect(reloads(commands)).toEqual(['/reload-plugins --force'])
  // The new version's module reads it at its start: this one never hears back from a reload that works.
  expect(all.get('reloading')).toBe('1.2.10\n')
  await clock.advance(10000)
  expect(reloads(commands)).toEqual(['/reload-plugins --force'])
  expect(restarts(runs)).toEqual([])
  expect(prompts).toEqual([])
})

test('the tick that starts a reload delivers no wake, marks none read and leaves the name and the color to the new module', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  // A wake due at the third tick, when 1.2.4 has just been installed; nothing newer before.
  const installed: Record<string, string[]> = { [CACHE]: ['1.2.3'] }
  const { files: all } = files(
    on,
    { 'plugin.json': manifest('1.2.3'), name: 'shop · review #42', wake: `${NOW / 1000}\ttech lead on #42\tRileggi la issue\thttps://x/42#c101\n`, ...reviewer },
    installed,
  )
  const { commands, prompts } = engine(on)

  await $.session.start(START)
  await clock.advance(4000)
  expect(commands).toEqual(['/rename shop · review #42', '/color cyan'])
  expect(prompts).toEqual([])
  // A new name and a new state for the next tick, as role.sh and status.sh write them.
  all.set('name', 'shop · review #42 · round 2')
  all.set('status', JSON.stringify({ role: 'review', state: 'others', detail: 'waits for the developer' }))
  installed[CACHE] = ['1.2.3', '1.2.4']
  await clock.advance(2000)
  expect(commands).toEqual(['/rename shop · review #42', '/color cyan', '/reload-plugins --force'])
  expect(prompts).toEqual([])
  expect(all.has('wake-read')).toBe(false)
})

test('a session in a turn reloads only once the turn has ended', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  files(on, { 'plugin.json': manifest('1.2.3'), ...reviewer }, { [CACHE]: ['1.2.3', '1.2.4'] })
  const { commands } = engine(on)
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))

  await $.session.start(START)
  await $.turn.start({ text: '', turnId: 't1' })
  await clock.advance(4000)
  expect(reloads(commands)).toEqual([])
  await $.turn.complete({ answer: 'fatto', durationMs: 1000, isAborted: false, turnId: 't1', reason: 'answer' })
  await clock.advance(2000)
  expect(reloads(commands)).toEqual(['/reload-plugins --force'])
})

test('loaded by a reload to its version, the session is told to read its role\'s rules again, once', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const { files: all } = files(
    on,
    { 'plugin.json': manifest('1.2.10'), reloading: '1.2.10\n', role: 'dev', status: JSON.stringify({ role: 'dev', state: 'others', detail: 'waits for QA' }) },
    { [CACHE]: ['1.2.3', '1.2.10'] },
  )
  const { commands, prompts } = engine(on)

  await $.session.start(START)
  expect(prompts.length).toBe(1)
  expect(prompts[0]).toMatch(
    /^The team plugin was updated to 1\.2\.10 and this session reloaded it in place\. Its scripts are now in \S+\/scripts: use this path from now on\. Your role's rules may have changed: read \S+\/briefs\/dev\.md again now, whole, and follow it from here on/,
  )
  expect(prompts[0]).toMatch(/Then go on from where you were\. If you are waiting for something \(another agent, the checkout, CI\), declare it with sh "\S+\/scripts\/status\.sh" <others\|working>/)
  // What only a restart needs: its background commands and subagents go on.
  expect(prompts[0]).not.toContain('background')
  expect(prompts[0]).not.toContain('Subagents')
  expect(all.get('reloading')).toBe('')
  expect(all.get('version')).toBe('1.2.10\n')
  await clock.advance(10000)
  expect(prompts.length).toBe(1)
  expect(reloads(commands)).toEqual([])
})

test('a tech lead reloaded is told to read its skill again and to ask the user its question again', async ($, on) => {
  mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  files(on, { 'plugin.json': manifest('1.2.10'), reloading: '1.2.10\n', role: 'tech-lead', status: JSON.stringify({ role: 'tech-lead', state: 'you', detail: 'asks' }) })
  const { prompts } = engine(on)

  await $.session.start(START)
  expect(prompts.length).toBe(1)
  expect(prompts[0]).toMatch(/read \S+\/skills\/tech-lead\/SKILL\.md again now, whole/)
  expect(prompts[0]).toMatch(/Then go on from where you were\. If you were waiting for the user's answer, end your turn with that question again, whole, with its options, in its last line\.$/)
})

test('a session started on a version `reloading` does not name is told nothing', async ($, on) => {
  mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const { files: all } = files(on, { 'plugin.json': manifest('1.2.3'), reloading: '1.2.10\n', ...reviewer })
  const { prompts } = engine(on)

  await $.session.start(START)
  expect(prompts).toEqual([])
  expect(all.get('reloading')).toBe('1.2.10\n')
})

for (const [how, reload] of [
  ['answers no Reloaded: line', () => 'Plugin reload failed: team: hooks module did not load'],
  [
    'rejects',
    () => {
      throw new Error('reload-plugins: refused')
    },
  ],
] as const) {
  test(`a reload that ${how} restarts the session instead, once, telling nobody to read the rules twice`, async ($, on) => {
    const clock = mock.clock(on, { now: NOW })
    mock.env(on, { HOME: '/home/u' })
    const { files: all } = files(on, { 'plugin.json': manifest('1.2.3'), cwd: '/repo/.claude/worktrees/42-x', ...reviewer }, { [CACHE]: ['1.2.3', '1.2.4'] })
    const { commands, runs, prompts } = engine(on, reload)

    await $.session.start(START)
    await clock.advance(2000)
    expect(reloads(commands)).toEqual(['/reload-plugins --force'])
    // The newest version's update.sh, detached: it restarts the session as the update restarts one too old to reload.
    expect(restarts(runs)).toEqual([`sh ${CACHE}/1.2.4/scripts/update.sh restart abc-123`])
    // The restart carries its own prompt: the new version's module finds nothing to tell.
    expect(all.get('reloading')).toBe('')
    await clock.advance(10000)
    expect(reloads(commands).length).toBe(1)
    expect(restarts(runs).length).toBe(1)
    expect(prompts).toEqual([])
  })
}

for (const [where, running] of [
  ['already on the newest version installed', '1.2.10'],
  ['on a version newer than any installed', '1.3.0'],
] as const) {
  test(`a session ${where} does nothing`, async ($, on) => {
    const clock = mock.clock(on, { now: NOW })
    mock.env(on, { HOME: '/home/u' })
    const { files: all } = files(on, { 'plugin.json': manifest(running), ...reviewer }, { [CACHE]: ['1.2.3', '1.2.10'] })
    const { commands, runs, prompts } = engine(on)

    await $.session.start(START)
    await clock.advance(10000)
    expect(reloads(commands)).toEqual([])
    expect(restarts(runs)).toEqual([])
    expect(prompts).toEqual([])
    expect(all.has('reloading')).toBe(false)
  })
}

test('a session outside the team never reloads', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const { files: all } = files(on, { 'plugin.json': manifest('1.2.3') }, { [CACHE]: ['1.2.3', '1.2.4'] })
  const { commands } = engine(on)

  await $.session.start(START)
  await clock.advance(10000)
  expect(reloads(commands)).toEqual([])
  expect(all.has('reloading')).toBe(false)
})
