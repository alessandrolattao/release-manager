import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import type { Board } from '../types'

const PANE = {
  plugin: 'team',
  component: 'Pane',
  requestId: 'team-board',
  props: {
    title: 'Team',
    isFocused: false,
    bodyColumns: 48,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const BOARD: Board = {
  repo: 'equokar/equokar.com',
  rows: [
    { id: 'a', label: 'tech lead', role: 'tech-lead', state: 'you', place: '', stage: '', detail: 'Registro come tua regola fissa che le domande per te passano tutte da me?', since: 0 },
    { id: 'b', label: 'dev #318', role: 'dev', state: 'you', place: 'checkout', stage: 'in progress', detail: 'giro vero di #318 sul bucket e su Google Drive, comandi in issue', since: 0 },
    { id: 'd', label: 'tech lead api', role: 'tech-lead', state: 'idle', place: '', stage: '', detail: 'waiting for work', since: 0 },
    { id: 'c', label: 'dev #8', role: 'dev', state: 'working', place: 'worktree 8', stage: 'in review', detail: 'removal of preview pr-317 with SST .38', since: 0 },
  ],
  summary: { checkout: 'dev #318', developers: '2 at work', queue: '0 ready · 5 backlog', ci: 'green', usage5h: { text: '93% · runs out 12:45', alt: '93% · resets 14:00', tone: 'alert' }, usage7d: { text: '11% · lasts', alt: '', tone: 'ok' } },
  dispatcher: { running: false, version: '' },
  updated: 0,
}

// The values the module keeps, as the atoms store them: the board with its shape tag, and the newest version
// published ('' when the running one is the newest).
function stored(on: On, newer = ''): void {
  on('state.get', (_$, e) => ({
    value:
      e.key === 'board'
        ? { value: { shape: 'board-4', value: BOARD }, version: 1 }
        : { value: e.key === 'model' ? 'claude-fable-5-2' : newer, version: 1 },
  }))
}

test('the board groups the agents by state, names on the color of their state', async ($, on) => {
  // As the atom keeps it: a value with its shape tag.
  stored(on)
  on('clock.now', () => ({ value: 120000 }))
  on('fs.read', () => ({ value: '{"name":"team","version":"9.9.9"}' }))

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /WAITING ON YOU/ }))?.text).toBe('WAITING ON YOU (2)')
  expect((await ui.find({ type: 'Text', text: /^WORKING/ }))?.text).toBe('WORKING (1)')
  const name = await ui.find({ type: 'Text', text: /dev #318/ })
  expect(name?.text).toBe(' dev #318 ')
  expect(name?.props.backgroundColor).toBe('yellow')
  expect((await ui.find({ type: 'Text', text: /removal of preview/ }))?.text).toBe('removal of preview pr-317 with SST .38')
  expect((await ui.find({ type: 'Text', text: /^IDLE/ }))?.text).toBe('IDLE (1)')
  expect((await ui.find({ type: 'Text', text: /tech lead api/ }))?.props.backgroundColor).toBe('green')
  expect((await ui.find({ type: 'Text', text: /checkout · in progress · waiting/ }))?.text).toContain('checkout · in progress · waiting 2m')
  expect((await ui.find({ type: 'Text', text: /idle 2m/ }))?.text).toContain('idle 2m')
  // The title: a dialog titled TEAM, the name centered in its thin inner frame, 2 columns in from each side.
  expect((await ui.find({ type: 'Text', text: /TEAM/ }))?.text).toMatch(/^  ╔═+ TEAM ═+╗$/)
  const titleLine = (await ui.find({ type: 'Text', text: /│ +equokar\.com +│/ }))?.text ?? ''
  expect(titleLine).toMatch(/^  ║ │ +equokar\.com +│ ║▓$/)
  const [, before = '', after = ''] = titleLine.match(/│( +)equokar\.com( +)│/) ?? []
  expect(Math.abs(before.length - after.length)).toBeLessThanOrEqual(1)
  // The summary: SUMMARY in the top border of a window as wide as the pane, a row per item.
  expect((await ui.find({ type: 'Text', text: /SUMMARY/ }))?.text).toMatch(/^  ╔═+ SUMMARY ═+╗$/)
  const usage = (await ui.find({ type: 'Text', text: /usage 7d/ }))?.text ?? ''
  expect(usage).toMatch(/^  ║ usage 7d +11% · lasts +║▓$/)
  // 2 columns of room on each side: 48 less the 2 on the right, which are not drawn.
  expect([...usage].length).toBe(46)
  // The usage tones: red when the window runs out first, green when it lasts.
  expect((await ui.find({ type: 'Text', text: /^93% · runs out 12:45$/ }))?.props.color).toBe('red')
  expect((await ui.find({ type: 'Text', text: /^11% · lasts$/ }))?.props.color).toBe('green')
  // The dispatcher, stopped: in red, inside a control that starts it.
  const stopped = await ui.find({ type: 'Text', text: /^stopped · click to start$/ })
  expect(stopped?.props.color).toBe('red')
  expect(await ui.find({ type: 'Button' })).toBeTruthy()
  // The tech lead's model, by its name.
  expect((await ui.find({ type: 'Text', text: /model +Fable 5\.2/ }))?.text).toMatch(/model +Fable 5\.2/)
  // At the foot, the plugin's version centered in the 48 columns.
  const foot = (await ui.find({ type: 'Text', text: /team 9\.9\.9/ }))?.text ?? ''
  expect(foot.trim()).toBe('team 9.9.9')
  expect(foot.length - foot.trimStart().length).toBe(Math.floor((48 - 'team 9.9.9'.length) / 2))
  await ui.unmount()
})

test('above 90% a usage line alternates with when the window resets', async ($, on) => {
  stored(on)
  on('fs.read', () => ({ value: '{"name":"team","version":"9.9.9"}' }))
  // 124 seconds: the second half of a 4-second step shows the reset instead.
  on('clock.now', () => ({ value: 124000 }))

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /^93% · resets 14:00$/ }))?.props.color).toBe('red')
  expect(await ui.find({ type: 'Text', text: /runs out/ })).toBeFalsy()
  expect((await ui.find({ type: 'Text', text: /^11% · lasts$/ }))?.props.color).toBe('green')
  await ui.unmount()
})

test('a newer version at the foot, and update runs /team:update', async ($, on) => {
  stored(on, '9.9.10')
  on('clock.now', () => ({ value: 120000 }))
  on('fs.read', () => ({ value: '{"name":"team","version":"9.9.9"}' }))
  on('session.id', () => ({ value: 'abc-123' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', () => ({ value: undefined }))
  on('ui.toast', () => ({ value: undefined }))
  const runs: string[] = []
  on('process.run', (_$, e) => {
    runs.push(e.argv.join(' '))
    return { value: { exitCode: 0, stdout: 'update started', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: / · 9\.9\.10 available · $/ }))?.props.color).toBe('yellow')
  await ui.press({ key: 'update' })
  expect(runs.filter(run => run.endsWith('/scripts/update.sh start')).length).toBe(1)
  await ui.unmount()
})
