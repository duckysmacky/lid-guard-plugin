import { atom, read, update } from 'claude-code'
import type { Hook, Register } from 'claude-code'

import type { Status } from '../types'

const MODES = ['off', 'task', 'session'] as const
const REFRESH_MS = 5000

const status = atom(
  { plugin: 'lid-guard', key: 'status' } as const,
  { mode: 'session', locks: [], hasScript: false } as Status,
)

// Whether the band is on screen (the status line shows the mode only when it is not).
let isBandShown = false

type Api = Parameters<Hook<'session.start'>>[0]

// The script ships in this plugin. A failed start counts as "not found" (127).
async function lidGuard($: Api, ...args: string[]) {
  const script = `${$.plugin.root}/skills/lid-guard/scripts/lid-guard.sh`
  try {
    return await $.process.run([script, '--agent', 'claude', ...args])
  } catch {
    return { exitCode: 127, stdout: '', stderr: '' }
  }
}

async function refresh($: Api) {
  const ran = await lidGuard($, 'status', '--json')
  let next: Status
  if (ran.exitCode === 0) {
    const parsed = JSON.parse(ran.stdout)
    next = { mode: parsed.mode, locks: parsed.locks, hasScript: true }
  } else {
    // No script: the mode file is still the source of truth.
    const file = `${await $.env.get('HOME')}/.claude/lid-guard-mode`
    const text = (await $.fs.exists(file)) ? String(await $.fs.read(file)).trim() : ''
    next = {
      mode: (MODES as readonly string[]).includes(text) ? text : 'session',
      locks: [],
      hasScript: false,
    }
  }
  await update($, status, () => next)
  // The engine prefixes the plugin's name.
  $.ui.status(isBandShown ? undefined : next.mode)
}

async function setMode($: Api, mode: string) {
  const ran = await lidGuard($, 'set', mode)
  if (ran.exitCode !== 0) {
    await $.fs.write(`${await $.env.get('HOME')}/.claude/lid-guard-mode`, `${mode}\n`)
  }
  await refresh($)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await refresh($)
    $.clock.every(REFRESH_MS, () => void refresh($))

    return next(e)
  })

  // One line above the prompt: status dot, mode selector. The engine draws
  // its own [-] collapse button at the right end.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // Keep what the mods beneath draw (the band takes one tree): ours goes above it.
    const below = await next(e)
    if (e.props.hasSurvey) return below

    const { Box, Button, Text } = $.ui.resolve(e)
    const s = await read($, status)

    const isShown = !e.props.isCollapsed
    if (isShown !== isBandShown) {
      isBandShown = isShown
      $.ui.status(isShown ? undefined : s.mode)
    }
    const isHeld = s.mode !== 'off' && s.locks.length > 0
    const state = s.mode === 'off' ? 'off' : isHeld ? `held${s.locks.length > 1 ? ` x${s.locks.length}` : ''}` : 'idle'

    const line = (
      <Box justifyContent="space-between">
        <Box gap={2}>
          <Text dimColor={!isHeld} color={isHeld ? 'green' : undefined}>
            ● {state}
          </Text>
          <Box>
            {MODES.map(mode => (
              <Button key={mode} plain dimColor={mode !== s.mode} onPress={() => setMode($, mode)}>
                {mode === s.mode ? <Text inverse> {mode} </Text> : ` ${mode} `}
              </Button>
            ))}
          </Box>
        </Box>
        <Text dimColor>Lid guard</Text>
      </Box>
    )

    return below ? (
      <Box flexDirection="column">
        {line}
        {below}
      </Box>
    ) : (
      line
    )
  })
}
