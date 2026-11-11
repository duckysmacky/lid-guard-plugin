import { expect, test } from 'claude-code/testing'

const BAND = {
  plugin: 'lid-guard',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isCollapsed: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 80,
    scroll: { offset: 0, bodyRows: 10 },
  },
} as const

const STATUS = {
  mode: 'task',
  locks: [{ session: 's1', kind: 'task', age_seconds: 3 }],
}

test('the band is one line: held dot and the mode selector', async ($, on) => {
  on('process.run', () => ({
    value: { exitCode: 0, stdout: JSON.stringify(STATUS), stderr: '' },
  }))
  on('ui.status', () => ({ value: {} }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })

    expect(await ui.find({ type: 'Text', text: /● held/ })).toBeTruthy()
    expect(await ui.find({ type: 'Text', text: /Lid guard/ })).toBeTruthy()
    for (const mode of ['off', 'task', 'session']) {
      expect(await ui.find({ type: 'Button', key: mode })).toBeTruthy()
    }
    await ui.unmount()
  }
})

test('pressing a mode runs set, and without the script the mode file is read', async ($, on) => {
  const calls: string[][] = []
  on('process.run', (_, e) => {
    calls.push([...e.argv])
    return { value: { exitCode: 127, stdout: '', stderr: '' } }
  })
  on('env.get', () => ({ value: '/h' }))
  on('fs.exists', () => ({ value: true }))
  on('fs.read', () => ({ value: 'task\n' }))
  on('fs.write', () => ({ value: undefined }))
  on('ui.status', () => ({ value: {} }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /● idle/ })).toBeTruthy()
  await ui.press({ plugin: 'lid-guard', key: 'off' })
  expect(calls.some(c => c.includes('set') && c.includes('off'))).toBe(true)
  await ui.unmount()
})

test('keeps what another mod draws in the band, and hides the status line while shown', async ($, on) => {
  const lines: (string | undefined)[] = []
  on('process.run', () => ({
    value: { exitCode: 0, stdout: JSON.stringify(STATUS), stderr: '' },
  }))
  on('ui.status', (_, e) => {
    lines.push(e.text)
    return { value: {} }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>other mod</Text>
  })

  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const shown = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(await shown.find({ type: 'Text', text: /other mod/ })).toBeTruthy()
  expect(await shown.find({ type: 'Text', text: /● held/ })).toBeTruthy()
  expect(lines.at(-1)).toBeUndefined()
  await shown.unmount()

  const collapsed = await $.ui.mount({
    ...BAND,
    props: { ...BAND.props, isCollapsed: true },
    surface: 'desktop',
  })
  expect(lines.at(-1)).toBe('task')
  await collapsed.unmount()
})
