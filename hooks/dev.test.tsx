import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const NOW = 1_800_000_000_000
const START = { cwd: '/repo', surface: null, isInteractive: false } as const
const STATE = '/home/u/.local/state/team'
const WORKTREE = '/repo/.claude/worktrees/42-checkout-page'

const PANE = {
  plugin: 'team',
  component: 'Pane',
  requestId: 'team-dev',
  props: {
    title: 'Team',
    isFocused: false,
    bodyColumns: 72,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const PR = {
  number: 50,
  title: 'Checkout page with saved cards',
  url: 'https://github.com/acme/shop/pull/50',
  state: 'OPEN',
  checks: { total: 3, failed: 0, pending: 0 },
}

// The team's state as the scripts leave it, by path under its folder: this developer's session (abc-123),
// another one holding the checkout, and the repository's records. What the module writes lands in it too.
function seeded(on: On, extra: Record<string, string> = {}): Map<string, string> {
  const files = new Map<string, string>(
    Object.entries({
      'sessions/abc-123/role': 'dev',
      'sessions/abc-123/cwd': WORKTREE,
      'sessions/abc-123/status': JSON.stringify({
        role: 'dev',
        repo: 'acme/shop',
        issue: 42,
        title: 'Checkout page with saved cards, and the old one removed for good',
        branch: '42-checkout-page',
        state: 'others',
        detail: 'waits for QA on #42',
        since: NOW / 1000 - 540,
      }),
      'sessions/other-1/status': JSON.stringify({ role: 'dev', repo: 'acme/shop', issue: 7, state: 'working' }),
      'repos/acme_shop/base': 'main',
      'repos/acme_shop/ci': 'green',
      'repos/acme_shop/checkout': `other-1\n${NOW / 1000 - 600}\n7-search\n`,
      'repos/acme_shop/checkout.queue': 'qa-9\nabc-123\n',
      ...extra,
    }),
  )
  on('session.id', () => ({ value: 'abc-123' }))
  on('fs.read', (_$, e) => {
    if (e.path.endsWith('/.claude-plugin/plugin.json')) {
      return { value: '{"name":"team","version":"9.9.9"}' }
    }
    const text = files.get(e.path.slice(STATE.length + 1))
    if (!e.path.startsWith(`${STATE}/`) || text === undefined) {
      throw new Error(`ENOENT: ${e.path}`)
    }
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    files.set(e.path.slice(STATE.length + 1), e.text)
    return { value: undefined }
  })
  on('fs.list', () => ({ value: [] }))
  return files
}

// The engine beneath the plugin: the worktree's git answers, GitHub's (`gh`, recorded with where it ran,
// answered by `github`), the panes opened, the logs.
function engine(on: On, github: (argv: readonly string[]) => string = () => '', logs: string[] = []) {
  const asked: string[] = []
  const opened: string[] = []
  on('session.start', () => ({ cwd: '/repo' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.model', () => ({ value: 'claude-opus-5-5' }))
  on('command.register', () => ({ value: { command: 'team' } }))
  on('command.run', () => ({ text: '' }))
  on('ui.log', (_$, e) => {
    logs.push(JSON.stringify(e))
    return { value: undefined }
  })
  on('ui.open', (_$, e) => {
    opened.push(e.id)
    return { value: { isPlaced: false, reason: 'no surface in a test' } }
  })
  on('process.run', (_$, e) => {
    const line = e.argv.join(' ')
    const answer = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
    if (e.argv[0] === 'gh') {
      asked.push(`${e.init?.cwd ?? ''}: ${line}`)
      return answer(github(e.argv))
    }
    if (e.init?.cwd !== WORKTREE) {
      return { value: { exitCode: 128, stdout: '', stderr: 'not a git repository', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    if (line === 'git rev-list --count origin/main..HEAD') {
      return answer('3\n')
    }
    if (line === 'git diff --shortstat origin/main...HEAD') {
      return answer(' 4 files changed, 120 insertions(+), 15 deletions(-)\n')
    }
    if (line === 'git rev-parse HEAD') {
      return answer('abc123def\n')
    }
    return answer('')
  })
  return { asked, opened }
}

test("a developer's pane shows its issue, status, branch, pull request, work and state, and its summary", async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  // GitHub read a minute ago: not asked again.
  seeded(on, {
    'sessions/abc-123/github': JSON.stringify({ at: NOW / 1000 - 60, status: 'In review', qa: true, pr: PR }),
    'repos/acme_shop/review/42': 'abc123def\tthe decisions hold',
    'repos/acme_shop/qa/42': 'requested\tabc123def\t42\tabc-123\t42-checkout-page',
  })
  const logs: string[] = []
  const { asked, opened } = engine(on, () => '', logs)

  await $.session.start(START)
  await clock.advance(2000)
  expect(logs).toEqual([])
  expect(asked).toEqual([])
  // It opens by itself once the session runs, as the board does.
  expect(opened).toEqual(['team-dev'])

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  // The title: a dialog titled DEV #42, the repository's name centered in its thin inner frame.
  expect((await ui.find({ type: 'Text', text: /DEV #42/ }))?.text).toMatch(/^  ╔═+ DEV #42 ═+╗$/)
  expect((await ui.find({ type: 'Text', text: /│ +shop +│/ }))?.text).toMatch(/^  ║ │ +shop +│ ║▓$/)
  // ISSUE and PR: links, each labelled with its number and title, the title cut to the pane's width (72 less
  // the 2 sides and the label column).
  const [issue, pr] = await ui.findAll({ type: 'Link' })
  expect(issue?.props.href).toBe('https://github.com/acme/shop/issues/42')
  const issueLabel = String(issue?.children[0] ?? '')
  expect([...issueLabel].length).toBe(62)
  expect(issueLabel).toMatch(/^#42 Checkout page with saved cards, and the old one removed.*…$/)
  expect((await ui.find({ type: 'Text', text: /^STATUS / }))?.text).toBe('STATUS  In review')
  expect((await ui.find({ type: 'Text', text: /^BRANCH / }))?.text).toBe('BRANCH  42-checkout-page')
  // PR: a link to the pull request, then its state and its checks.
  expect(pr?.props.href).toBe('https://github.com/acme/shop/pull/50')
  expect(pr?.children).toEqual(['#50 Checkout page with saved cards'])
  expect((await ui.find({ type: 'Text', text: /open · checks green/ }))?.text).toBe('        open · checks green')
  expect((await ui.find({ type: 'Text', text: /^checks green$/ }))?.props.color).toBe('green')
  // WORK: from git in the worktree.
  expect((await ui.find({ type: 'Text', text: /^WORK / }))?.text).toBe('WORK    3 commits · 4 files · +120 -15')
  // STATE: the board's verb and age, on the color of the state, then what it waits on.
  const state = await ui.find({ type: 'Text', text: /^ waiting 9m $/ })
  expect(state?.props.backgroundColor).toBe('#827dbd')
  expect((await ui.find({ type: 'Text', text: /waits for QA/ }))?.text).toBe('        waits for QA on #42')
  // The summary.
  expect((await ui.find({ type: 'Text', text: /SUMMARY/ }))?.text).toMatch(/^  ╔═+ SUMMARY ═+╗$/)
  expect((await ui.find({ type: 'Text', text: /║ checkout/ }))?.text).toMatch(/║ checkout +held by dev #7 · you are 2 of 2 in the queue +║▓$/)
  expect((await ui.find({ type: 'Text', text: /║ review/ }))?.text).toMatch(/║ review +decision review passed · QA asked +║▓$/)
  expect((await ui.find({ type: 'Text', text: /║ main CI/ }))?.text).toMatch(/║ main CI +green +║▓$/)
  expect((await ui.find({ type: 'Text', text: /║ model/ }))?.text).toMatch(/║ model +Opus 5\.5 +║▓$/)
  expect((await ui.find({ type: 'Text', text: /team 9\.9\.9/ }))?.text.trim()).toBe('team 9.9.9')
  await ui.unmount()
})

test('GitHub is read at most every 5 minutes, and a pull request opened since shows', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const files = seeded(on)
  let listed = '[]'
  const { asked } = engine(on, argv => (argv[1] === 'api' ? '{"status":"In progress","qa":false}' : listed))

  await $.session.start(START)
  await clock.advance(2000)
  // One issue query and one list of the branch's pull requests, in any state, from the worktree.
  expect(asked.length).toBe(2)
  expect(asked[0]).toMatch(new RegExp(`^${WORKTREE}: gh api graphql .*status \\{ name \\} labels.* -F o=acme -F n=shop -F i=42 `))
  expect(asked[1]).toBe(`${WORKTREE}: gh pr list --repo acme/shop --head 42-checkout-page --state all --limit 1 --json number,title,url,state,statusCheckRollup`)
  expect(JSON.parse(files.get('sessions/abc-123/github') ?? '{}')).toEqual({ at: NOW / 1000 + 2, status: 'In progress', qa: false, pr: null })
  await clock.advance(4000)

  let ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /^STATUS / }))?.text).toBe('STATUS  In progress')
  expect((await ui.find({ type: 'Text', text: /^PR / }))?.text).toBe('PR      none yet')
  expect((await ui.find({ type: 'Text', text: /║ review/ }))?.text).toMatch(/║ review +decision review not passed · no QA +║▓$/)
  expect((await ui.find({ type: 'Text', text: /║ checkout/ }))?.text).toMatch(/║ checkout +held by dev #7 · you are 2 of 2 in the queue +║▓$/)
  await ui.unmount()

  // The developer opens its pull request: not asked again before 5 minutes, then it shows.
  listed = JSON.stringify([
    {
      number: 50,
      title: 'Checkout page',
      url: 'https://github.com/acme/shop/pull/50',
      state: 'OPEN',
      statusCheckRollup: [
        { __typename: 'CheckRun', status: 'COMPLETED', conclusion: 'FAILURE' },
        { __typename: 'CheckRun', status: 'IN_PROGRESS', conclusion: '' },
        { __typename: 'StatusContext', state: 'SUCCESS' },
      ],
    },
  ])
  await clock.advance(60000)
  expect(asked.length).toBe(2)
  await clock.advance(5 * 60000)
  expect(asked.length).toBe(4)
  await clock.advance(4000)
  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Link', text: /\/pull\/50/ }))?.children).toEqual(['#50 Checkout page'])
  const checks = await ui.find({ type: 'Text', text: /^checks failed/ })
  expect(checks?.text).toBe('checks failed: 1 of 3')
  expect(checks?.props.color).toBe('red')
  await ui.unmount()
})

test('a checkout taken as it is shows as-is after its holder', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const files = seeded(on, {
    'sessions/abc-123/github': JSON.stringify({ at: NOW / 1000, status: 'In progress', qa: false, pr: null }),
    'repos/acme_shop/checkout': `other-1\n${NOW / 1000 - 600}\nmain\nas-is\n`,
  })
  engine(on)

  await $.session.start(START)
  await clock.advance(2000)
  let ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /║ checkout/ }))?.text).toMatch(/║ checkout +held by dev #7 as-is · you are 2 of 2 in the queue +║▓$/)
  await ui.unmount()

  // This session holds it as it is.
  files.set('repos/acme_shop/checkout', `abc-123\n${NOW / 1000}\nmain\nas-is\n`)
  files.set('repos/acme_shop/checkout.queue', '')
  await clock.advance(4000)
  ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /║ checkout/ }))?.text).toMatch(/║ checkout +held by you as-is +║▓$/)
  await ui.unmount()
})

test('a review or a QA outcome counts for the worktree HEAD only', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  seeded(on, {
    'sessions/abc-123/github': JSON.stringify({ at: NOW / 1000, status: 'In review', qa: true, pr: PR }),
    // Both for the head before the last commit.
    'repos/acme_shop/review/42': 'old456\tthe decisions hold',
    'repos/acme_shop/qa/42': 'pass\told456',
  })
  engine(on)

  await $.session.start(START)
  await clock.advance(2000)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /║ review/ }))?.text).toMatch(/║ review +decision review not passed · QA needed +║▓$/)
  await ui.unmount()
})

test('the review and the QA, taken on the branch, show before the pull request exists', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  seeded(on, {
    'sessions/abc-123/github': JSON.stringify({ at: NOW / 1000, status: 'In progress', qa: true, pr: null }),
    // Keyed by the issue, for the worktree's HEAD.
    'repos/acme_shop/review/42': 'abc123def\tthe decisions hold',
    'repos/acme_shop/qa/42': 'pass\tabc123def',
  })
  engine(on)

  await $.session.start(START)
  await clock.advance(2000)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /^PR / }))?.text).toBe('PR      none yet')
  expect((await ui.find({ type: 'Text', text: /║ review/ }))?.text).toMatch(/║ review +decision review passed · QA passed +║▓$/)
  await ui.unmount()
})

test('/team opens the pane in a developer session; a QA agent or a spike has none', async ($, on) => {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, { HOME: '/home/u' })
  const files = seeded(on, {
    'sessions/abc-123/role': 'qa',
    'sessions/abc-123/status': JSON.stringify({ role: 'qa', repo: 'acme/shop', issue: 42, state: 'working' }),
  })
  const { asked, opened } = engine(on)

  await $.session.start(START)
  await clock.advance(4000)
  expect(opened).toEqual([])
  expect(asked).toEqual([])

  files.set('sessions/abc-123/role', 'spike')
  files.set('sessions/abc-123/status', JSON.stringify({ role: 'spike', repo: 'acme/shop', topic: 'flaky ci', state: 'working' }))
  await clock.advance(4000)
  expect(opened).toEqual([])

  files.set('sessions/abc-123/role', 'dev')
  type Run = Parameters<typeof $.command.run>[0]
  await $.command.run({ command: 'team', args: '', origin: { kind: 'composer' } } as Run)
  expect(opened).toEqual(['team-dev'])
})
