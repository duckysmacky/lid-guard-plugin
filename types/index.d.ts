export type Lock = { session: string; kind: string; age_seconds: number }
export type Status = {
  mode: string
  locks: Lock[]
  // false when the lid-guard script could not be found (file-only fallback)
  hasScript: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'lid-guard': { status: Status }
  }
}
