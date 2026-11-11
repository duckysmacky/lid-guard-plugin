# Lid guard

![version](https://img.shields.io/badge/version-1.0.0-blue)
![platform](https://img.shields.io/badge/platform-Linux-informational?logo=linux&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-D97757)
![Codex](https://img.shields.io/badge/Codex-plugin-000000)
![Agent Skills](https://img.shields.io/badge/Agent%20Skills-npx%20skills%20add-success)

Keeps a Linux laptop awake with the lid closed while an AI coding agent works. Plugin with hooks for Claude Code and Codex, skill + script for any other agent.

## Modes

Set with `/lid-guard <mode>` (`$lid-guard <mode>` on Codex), `/lid-guard` alone shows the status.

| Mode      | Behaviour                                                                                 |
|-----------|-------------------------------------------------------------------------------------------|
| `off`     | Does nothing.                                                                             |
| `task`    | Lock held while a prompt is being worked on, released when the agent stops.               |
| `session` | Lock taken on the first prompt and held until the agent exits. **Default.** You can prompt again with the lid closed. Battery drains while the lid stays closed. |

The mode is a one-word file that survives restarts:

| Agent             | File                               |
|-------------------|------------------------------------|
| Claude Code       | `~/.claude/lid-guard-mode`         |
| Codex             | `~/.codex/lid-guard-mode`          |
| other (default)   | `~/.agents/lid-guard-mode`         |
| `--agent <name>`  | `~/.<name>/lid-guard-mode`         |

`LID_GUARD_MODE=off|task|session` overrides the file.

## Requirements

- `systemd-inhibit` (without systemd the hooks are silent no-ops)
- `jq`

## Install

### Claude Code

Plugin: hooks plus the `/lid-guard` command.

```
claude plugin marketplace add duckysmacky/duckysmacky-plugin-marketplace
claude plugin install lid-guard@duckysmacky
```

The plugin also ships a dashboard mod (Claude Code only): one line above the prompt with the lock status (`● held` / `● idle` / `● off`) and clickable `off` `task` `session` toggles. Collapse it with the `[-]` at the right or ctrl+x ctrl+a. Codex ignores it.

### Codex

Plugin: hooks plus the `$lid-guard` skill

```
codex plugin marketplace add duckysmacky/duckysmacky-plugin-marketplace
codex plugin add lid-guard@duckysmacky
```

### Other agents

Skill plus script, installed with [`skills`](https://github.com/vercel-labs/skills):

```sh
npx skills add duckysmacky/lid-guard-plugin              # project install
npx skills add duckysmacky/lid-guard-plugin -g           # user-wide (~/.agents/skills/lid-guard for most agents)
npx skills add duckysmacky/lid-guard-plugin -a <agent>   # pick the agent
```

The script is installed inside the skill folder. Without hooks the agent cannot be trusted to call it at the right time, so the reliable way is a wrapper that holds the lock for the whole agent process:

```sh
~/.agents/skills/lid-guard/scripts/lid-guard.sh run -- <agent command>
```

- Add `--agent <name>` before `run` to keep the mode file in `~/.<name>/` instead of `~/.agents/`.
- Skill only (no hooks): use the `/lid-guard <mode>` skill. It will run `acquire` before long work and `release` after, on a best-effort basis.

## How it works (Claude Code and Codex)

| Hook               | Action                                                                      |
|--------------------|-----------------------------------------------------------------------------|
| `UserPromptSubmit` | acquire a logind inhibitor (`sleep` + `handle-lid-switch`)                  |
| `PostToolUse`      | acquire again (no-op if the lock is fresh), so a mode switch mid-turn heals |
| `Stop`, `Interrupt`| release the lock in `task` mode, keep it in `session` mode                  |
| `SessionEnd`       | release the lock in every mode (exit, `/clear`, resume)                     |

- `task` locks are bounded leases (`LID_GUARD_LEASE_SECONDS`, default 1800), renewed on activity, so a missed `Stop` (Esc, crash) expires instead of leaking.
- `session` locks are tied to the agent process (`tail --pid`), so exiting or killing the agent releases them.
- One lock per session id, so parallel agents are independent.
- Switching to `off` or `task` releases existing locks right away.

Verify: `systemd-inhibit --list` shows `lid-guard`, or run `scripts/lid-guard.sh --agent claude status`.

## Script

```
skills/lid-guard/scripts/lid-guard.sh [--agent NAME] acquire | release [--on-stop] | set MODE | status [--json] | run -- CMD...
```

`acquire` and `release` print nothing on purpose: hook stdout can end up in the model context. `LID_GUARD_AGENT_PID` overrides which process a session lock follows.

## Notes

- Inhibitors only stop the *lid switch* and idle suspend. Turning the panel off on lid close is a compositor job
- In `task` mode, background subagents or long `run_in_background` jobs may outlive the turn's `Stop`, and the lock is released then. Use `session` mode for those.
- The dashboard mod is `hooks/register.tsx`, loaded through `modules` in `hooks/hooks.json` next to the command hooks.

