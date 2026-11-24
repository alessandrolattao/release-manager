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
    { id: 'a', label: 'tech lead', role: 'tech-lead', state: 'you', place: '', detail: 'Registro come tua regola fissa che le domande per te passano tutte da me?', since: 0 },
    { id: 'b', label: 'dev #318', role: 'dev', state: 'you', place: 'checkout', detail: 'giro vero di #318 sul bucket e su Google Drive, comandi in issue', since: 0 },
    { id: 'd', label: 'tech lead api', role: 'tech-lead', state: 'idle', place: '', detail: 'waiting for work', since: 0 },
    { id: 'c', label: 'dev #8', role: 'dev', state: 'working', place: 'worktree 8', detail: 'removal of preview pr-317 with SST .38', since: 0 },
  ],
  summary: { checkout: 'dev #318', developers: '2/2', queue: '0 ready · 5 backlog', ci: 'verde', capacity: 'ok' },
  updated: 0,
}

test('the board groups the agents by state, names on the color of their state', async ($, on) => {
  // As the atom keeps it: a value with its shape tag.
  on('state.get', () => ({ value: { value: { shape: 'board-2', value: BOARD }, version: 1 } }))
  on('clock.now', () => ({ value: 120000 }))

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /WAITING ON YOU/ }))?.text).toBe('WAITING ON YOU (2)')
  expect((await ui.find({ type: 'Text', text: /^WORKING/ }))?.text).toBe('WORKING (1)')
  const name = await ui.find({ type: 'Text', text: /dev #318/ })
  expect(name?.text).toBe(' dev #318 ')
  expect(name?.props.backgroundColor).toBe('yellow')
  expect((await ui.find({ type: 'Text', text: /removal of preview/ }))?.text).toBe('removal of preview pr-317 with SST .38')
  expect((await ui.find({ type: 'Text', text: /^IDLE/ }))?.text).toBe('IDLE (1)')
  expect((await ui.find({ type: 'Text', text: /tech lead api/ }))?.props.backgroundColor).toBe('green')
  expect((await ui.find({ type: 'Text', text: /checkout · waiting/ }))?.text).toContain('checkout · waiting 2m')
  expect((await ui.find({ type: 'Text', text: /idle 2m/ }))?.text).toContain('idle 2m')
  // The title: the name inside the inner frame, the dotted band around it, centered in the 48 columns.
  const titleLine = (await ui.find({ type: 'Text', text: /│ +equokar\.com +│/ }))?.text ?? ''
  expect(titleLine).toMatch(/^ *║░│ +equokar\.com +│░║▓$/)
  const before = titleLine.length - titleLine.trimStart().length
  const after = 48 - [...titleLine].length
  expect(Math.abs(before - after)).toBeLessThanOrEqual(1)
  // The summary: SUMMARY in the top border of a window as wide as the pane, a row per item.
  expect((await ui.find({ type: 'Text', text: /SUMMARY/ }))?.text).toMatch(/^  ╔═+ SUMMARY ═+╗$/)
  const capacity = (await ui.find({ type: 'Text', text: /capacity/ }))?.text ?? ''
  expect(capacity).toMatch(/^  ║ capacity +ok +║▓$/)
  // 2 columns of room on each side: 48 less the 2 on the right, which are not drawn.
  expect([...capacity].length).toBe(46)
  await ui.unmount()
})
