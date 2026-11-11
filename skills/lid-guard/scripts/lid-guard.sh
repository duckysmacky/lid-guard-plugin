#!/usr/bin/env bash
#
# lid-guard.sh [--agent NAME] acquire
#              [--agent NAME] release [--on-stop]
#              [--agent NAME] set off|task|session
#              [--agent NAME] status [--json]
#              [--agent NAME] run -- CMD...
#
# Keeps the machine awake with the lid closed by holding a systemd-logind
# inhibitor (sleep + handle-lid-switch) while an agent works.
#
# Modes (stored in <agent config dir>/lid-guard-mode, default "session"):
#   off      do nothing
#   task     lock held while a prompt is being worked on, released on Stop
#            (a lease, renewed on activity, so a missed Stop cannot leak it)
#   session  lock acquired on the first prompt and held until the agent
#            process exits (or SessionEnd)
#
# Mode file location: --agent claude -> ~/.claude, codex -> ~/.codex,
# no --agent -> ~/.agents, any other NAME -> ~/.NAME. $LID_GUARD_MODE overrides.
#
# $LID_GUARD_AGENT_PID overrides which process a session lock is tied to.
#
# One lock per session id, so several concurrent agents do not interfere.
#
# IMPORTANT: hook stdout can be injected into the model context, so
# acquire/release never print anything. Only set/status/run do.

set -u

agent=""
if [[ ${1:-} == --agent ]]; then
    agent="${2:-}"
    shift 2 || exit 2
fi
action="${1:-}"
shift || true

[[ $agent =~ ^[A-Za-z0-9_-]*$ ]] || exit 2
case "$action" in acquire|release) exec >/dev/null 2>&1 ;; esac

lease_seconds="${LID_GUARD_LEASE_SECONDS:-1800}"
case "$agent" in
    claude) config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    codex)  config_dir="${CODEX_HOME:-$HOME/.codex}" ;;
    "")     config_dir="$HOME/.agents" ;;
    *)      config_dir="$HOME/.$agent" ;;
esac
mode_file="$config_dir/lid-guard-mode"
state_dir="${XDG_RUNTIME_DIR:-/tmp}/lid-guard/${agent:-generic}"

get_mode()
{
    local mode="${LID_GUARD_MODE:-}"
    [[ -z $mode && -r $mode_file ]] && mode="$(<"$mode_file")"
    mode="${mode//[[:space:]]/}"
    case "$mode" in off|task|session) echo "$mode" ;; *) echo session ;; esac
}

# The agent process the session lock is tied to: nearest claude/codex ancestor.
agent_pid()
{
    [[ ${LID_GUARD_AGENT_PID:-} =~ ^[0-9]+$ ]] && { echo "$LID_GUARD_AGENT_PID"; return; }
    local pid=$PPID comm
    while (( pid > 1 )); do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || break
        case "$comm" in claude|codex|"${agent:-?}") echo "$pid"; return ;; esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    done
    echo "$PPID"
}

get_session_id()
{
    local id=""
    if [[ ! -t 0 ]]; then
        id="$(timeout 1 cat 2>/dev/null | jq -r '.session_id // empty' 2>/dev/null)"
    fi
    id="${id:-generic-$(agent_pid)}"
    echo "${id//[^A-Za-z0-9_-]/_}"
}

# A lock is a systemd-inhibit process (or, on systemd versions that exec the
# command, its sleep/tail) that is its own session leader (we started it with
# setsid). That guards against a recycled pid. Prints "session" or "task".
lock_kind()
{
    local lock_pid="$1" comm cmdline session_of_lock_pid
    [[ -n $lock_pid && -r /proc/$lock_pid/stat ]] || return 1
    comm="$(cat "/proc/$lock_pid/comm" 2>/dev/null)"
    [[ $comm == systemd-inhibit || $comm == sleep || $comm == tail ]] || return 1
    cmdline="$(tr '\0' ' ' <"/proc/$lock_pid/cmdline" 2>/dev/null)"
    [[ $comm != systemd-inhibit || $cmdline == *"--who=lid-guard"* ]] || return 1
    read -r _ _ _ _ _ session_of_lock_pid _ <"/proc/$lock_pid/stat" || return 1
    [[ $session_of_lock_pid == "$lock_pid" ]] || return 1
    [[ $cmdline == *"tail --pid="* ]] && echo session || echo task
}

lock_is_alive() { lock_kind "$1" >/dev/null; }

release_pid_file()
{
    local file="$1" lock_pid
    lock_pid="$(cat "$file" 2>/dev/null)"
    # Kill the whole group: systemd-inhibit and the command it runs.
    lock_is_alive "$lock_pid" && kill -- "-$lock_pid"
    rm -f "$file"
}

release_all()
{
    local file
    for file in "$state_dir"/*.pid; do
        [[ -e $file ]] && release_pid_file "$file"
    done
}

acquire_lock()
{
    local mode="$1" pid_file="$2" session_id="$3"
    local old_pid old_kind age
    old_pid="$(cat "$pid_file" 2>/dev/null)"

    # Existing lock of the right kind: session locks never need renewing,
    # task leases only when older than half a lease.
    if old_kind="$(lock_kind "$old_pid")" && [[ $old_kind == "$mode" ]]; then
        [[ $mode == session ]] && return 0
        age=$(( $(date +%s) - $(stat -c %Y "$pid_file") ))
        (( age < lease_seconds / 2 )) && return 0
    fi

    local holder=(sleep "$lease_seconds")
    [[ $mode == session ]] && holder=(tail "--pid=$(agent_pid)" -f /dev/null)

    # Start the new lock first, then drop the old one, so there is no gap.
    # bash records its own pid, then exec()s into systemd-inhibit, which
    # runs the holder; the pid we record is the group leader of that whole tree.
    mkdir -p "$state_dir"
    setsid bash -c '
        echo "$$" > "$1"
        why="$2"
        shift 2
        exec systemd-inhibit \
            --what=sleep:handle-lid-switch \
            --mode=block \
            --who=lid-guard \
            --why="$why" \
            "$@"
    ' lid-guard "$pid_file" "lid-guard ($mode): session $session_id is active" "${holder[@]}" </dev/null &

    # Give the child a moment to write its pid before we kill the old one.
    local wait_attempts=20
    while (( wait_attempts-- > 0 )) && [[ "$(cat "$pid_file" 2>/dev/null)" == "$old_pid" ]]; do
        sleep 0.05
    done
    [[ -n $old_pid ]] && lock_is_alive "$old_pid" && kill -- "-$old_pid"
    return 0
}

print_status()
{
    local json="${1:-}" mode file lock_pid session_id kind age rows=""
    mode="$(get_mode)"
    for file in "$state_dir"/*.pid; do
        [[ -e $file ]] || continue
        lock_pid="$(cat "$file" 2>/dev/null)"
        kind="$(lock_kind "$lock_pid")" || continue
        session_id="$(basename "$file" .pid)"
        age=$(( $(date +%s) - $(stat -c %Y "$file") ))
        rows+="$session_id"$'\t'"$kind"$'\t'"$age"$'\n'
    done

    if [[ $json == --json ]]; then
        jq -n --arg mode "$mode" --arg file "$mode_file" --arg rows "$rows" \
            --argjson inhibit "$(command -v systemd-inhibit >/dev/null && echo true || echo false)" '
            {mode: $mode, mode_file: $file, systemd_inhibit: $inhibit,
             locks: [$rows | split("\n")[] | select(. != "") | split("\t")
                     | {session: .[0], kind: .[1], age_seconds: (.[2] | tonumber)}]}'
        return
    fi
    echo "lid-guard mode: $mode ($mode_file)"
    command -v systemd-inhibit >/dev/null || echo "systemd-inhibit not found: lid-guard is a no-op here"
    if [[ -z $rows ]]; then
        echo "active locks: none"
    else
        echo "active locks:"
        while IFS=$'\t' read -r session_id kind age; do
            [[ -n $session_id ]] && echo "  $session_id  $kind  ${age}s"
        done <<<"$rows"
    fi
}

case "$action" in
    acquire)
        command -v systemd-inhibit >/dev/null || exit 0   # not a systemd box: no-op
        mode="$(get_mode)"
        session_id="$(get_session_id)"
        pid_file="$state_dir/$session_id.pid"
        if [[ $mode == off ]]; then
            release_pid_file "$pid_file"
        else
            acquire_lock "$mode" "$pid_file" "$session_id"
        fi
        ;;
    release)
        # Stop/interrupt: a session lock stays, everything else goes.
        if [[ ${1:-} == --on-stop && "$(get_mode)" == session ]]; then exit 0; fi
        release_pid_file "$state_dir/$(get_session_id).pid"
        ;;
    set)
        new_mode="${1:-}"
        case "$new_mode" in
            off|task|session) ;;
            *) echo "usage: lid-guard.sh [--agent NAME] set off|task|session" >&2; exit 2 ;;
        esac
        mkdir -p "$config_dir"
        printf '%s\n' "$new_mode" >"$mode_file.tmp" && mv "$mode_file.tmp" "$mode_file"
        # A mid-turn lock comes back on the next PostToolUse.
        [[ $new_mode == session ]] || release_all
        print_status
        ;;
    status)
        print_status "${1:-}"
        ;;
    run)
        [[ ${1:-} == -- ]] && shift
        [[ $# -gt 0 ]] || { echo "usage: lid-guard.sh [--agent NAME] run -- CMD..." >&2; exit 2; }
        if [[ "$(get_mode)" == off ]] || ! command -v systemd-inhibit >/dev/null; then
            exec "$@"
        fi
        exec systemd-inhibit --what=sleep:handle-lid-switch --mode=block \
            --who=lid-guard --why="lid-guard: running $1" "$@"
        ;;
    *)
        echo "usage: lid-guard.sh [--agent NAME] acquire|release [--on-stop]|set MODE|status [--json]|run -- CMD..." >&2
        exit 2
        ;;
esac

exit 0
