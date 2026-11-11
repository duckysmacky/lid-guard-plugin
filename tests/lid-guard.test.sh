#!/usr/bin/env bash
# Smoke test against the real systemd-inhibit. Uses a throwaway runtime dir and HOME.
set -u

script="$(cd "$(dirname "$0")/.." && pwd)/skills/lid-guard/scripts/lid-guard.sh"
tmp="$(mktemp -d)"
export XDG_RUNTIME_DIR="$tmp/run" HOME="$tmp/home"
mkdir -p "$XDG_RUNTIME_DIR" "$HOME"
sleep 300 & fake_agent=$!
export LID_GUARD_AGENT_PID=$fake_agent
trap 'kill $fake_agent 2>/dev/null; pkill -f "lid-guard.*$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

fails=0
hook() { echo "{\"session_id\":\"t1\"}" | "$script" --agent testagent "$@"; sleep 0.3; }
locks() { "$script" --agent testagent status --json | jq -r '.locks | length'; }
mode_of() { "$script" --agent testagent status --json | jq -r '.mode'; }
check() { # name expected actual
    if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1 (want $2, got $3)"; fails=$((fails + 1)); fi
}

check "default mode is session" session "$(mode_of)"

"$script" --agent testagent set task >/dev/null
check "set task writes ~/.testagent/lid-guard-mode" task "$(cat "$HOME/.testagent/lid-guard-mode")"
hook acquire;               check "task: acquire takes lock"       1 "$(locks)"
systemd-inhibit --list 2>/dev/null | grep -q 'lid-guard'
check "task: lock visible in systemd-inhibit --list" 0 $?
hook release --on-stop;     check "task: stop releases"            0 "$(locks)"

"$script" --agent testagent set session >/dev/null
hook acquire;               check "session: acquire takes lock"    1 "$(locks)"
hook acquire;               check "session: acquire is idempotent" 1 "$(locks)"
hook release --on-stop;     check "session: stop keeps lock"       1 "$(locks)"
hook release;               check "session: SessionEnd releases"   0 "$(locks)"

hook acquire;               check "session: reacquire"             1 "$(locks)"
kill $fake_agent; wait $fake_agent 2>/dev/null; sleep 2.5  # tail --pid polls every 1s
check "session: lock dies with agent" 0 "$(locks)"

sleep 300 & fake_agent=$!; export LID_GUARD_AGENT_PID=$fake_agent
"$script" --agent testagent set off >/dev/null
hook acquire;               check "off: acquire does nothing"      0 "$(locks)"

"$script" --agent testagent set session >/dev/null
hook acquire
"$script" --agent testagent set off >/dev/null
check "set off clears locks" 0 "$(locks)"

echo "bad" >"$HOME/.testagent/lid-guard-mode"
check "bad mode file falls back to session" session "$(mode_of)"

(( fails == 0 )) && echo "all passed" || { echo "$fails failed"; exit 1; }
