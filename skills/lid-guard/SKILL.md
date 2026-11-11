---
name: lid-guard
description: Keep the laptop awake with the lid closed while the agent works. Show or set the lid-guard mode (off, task, session). Use for /lid-guard, "lid guard", or keeping a Linux laptop from sleeping on lid close.
disable-model-invocation: true
argument-hint: "[off|task|session]"
allowed-tools: Bash(*lid-guard.sh*)
---

Run `scripts/lid-guard.sh` (it sits next to this file) and show its output verbatim. Do nothing else.

- No argument: `scripts/lid-guard.sh status`
- `off`, `task` or `session`: `scripts/lid-guard.sh set <mode>`
- Anything else: tell the user the valid modes.

Add `--agent claude` or `--agent codex` before the subcommand if you are Claude Code or Codex. Otherwise add `--agent <your name>` if you keep config in `~/.<your name>/`, or omit it (mode file is then `~/.agents/lid-guard-mode`).

| Mode | Effect |
|------|--------|
| `off` | Disabled |
| `task` | Lid guard only while a prompt is being worked on |
| `session` | Lid guard from the first prompt until the agent exits (default) |

No hooks installed (agent without a hook system)? Run `scripts/lid-guard.sh [--agent NAME] acquire` before long work and `release` when done. Best effort. The reliable way is starting the agent as `scripts/lid-guard.sh [--agent NAME] run -- <agent command>`.
