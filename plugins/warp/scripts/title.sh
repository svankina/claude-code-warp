#!/bin/bash
# Terminal-title helpers (OSC 0) for the dynamic-title spinner.
#
# Working: ⠋ project   (animated braille spinner, driven by title-spinner.sh)
# Blocked: ● project   (static attention marker — Claude needs the user)
# Idle:    project     (static)
#
# Source this file from a hook script, then call one title_on_* wrapper
# (added with the spinner lifecycle). The wrappers gate on title_enabled, so
# they are silent no-ops outside Warp or when the user opts out with
# WARP_CLAUDE_DYNAMIC_TITLE=0; low-level helpers like title_set write
# unconditionally but never fail the caller (no tty → silent no-op).
# Titles are plain OSC 0 (not the cli-agent protocol), so they deliberately
# do NOT gate on should_use_structured — they work on older Warp builds too.

_TITLE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TITLE_STATE_DIR="${TMPDIR:-/tmp}/.warp-claude-title"

# Where title writes go. Overridable so tests can use a temp file.
_title_tty() {
    printf '%s' "${WARP_TITLE_TTY:-/dev/tty}"
}

title_enabled() {
    [ "${WARP_CLAUDE_DYNAMIC_TITLE:-1}" = "0" ] && return 1
    [ "${TERM_PROGRAM:-}" = "WarpTerminal" ] && return 0
    [ -n "${WARP_CLI_AGENT_PROTOCOL_VERSION:-}" ] && return 0
    return 1
}

# basename of .cwd from the hook input JSON; falls back to $PWD.
title_base() {
    local cwd=""
    if command -v jq >/dev/null 2>&1; then
        cwd=$(printf '%s' "${1:-}" | jq -r '.cwd // empty' 2>/dev/null)
        if [ -z "$cwd" ]; then
            cwd=$(printf '%s' "${1:-}" | tr -d '[\000-\037]' | jq -r '.cwd // empty' 2>/dev/null)
        fi
    fi
    [ -z "$cwd" ] && cwd="$PWD"
    # Strip C0 control chars: BEL/ESC in a dir name would break the OSC 0
    # sequence and could inject terminal control sequences.
    basename "$cwd" | tr -d '[\000-\037]'
}

_title_session_id() {
    local sid=""
    if command -v jq >/dev/null 2>&1; then
        sid=$(printf '%s' "${1:-}" | jq -r '.session_id // empty' 2>/dev/null)
    fi
    printf '%s' "${sid:-nosession}"
}

title_format_osc0() {
    printf '\033]0;%s\007' "${1:-}"
}

# Write an OSC 0 title sequence; silently no-op if the tty is unavailable.
# Appends (>>) so a regular file standing in for the tty isn't truncated.
title_set() {
    ( title_format_osc0 "${1:-}" >> "$(_title_tty)" ) 2>/dev/null || true
}

# Per-session PID file, session id sanitized like warp-notify.sh's cache.
_title_pid_file() {
    local safe
    safe=$(printf '%s' "${1:-nosession}" | tr -c 'A-Za-z0-9_.-' '_')
    printf '%s/%s.pid' "$TITLE_STATE_DIR" "$safe"
}

# Print the live spinner pid recorded in $1, if it is really our spinner.
# Guards against recycled pids: the process must still be title-spinner.sh.
_title_spinner_pid() {
    local pidfile="${1:-}" pid args
    [ -f "$pidfile" ] || return 1
    pid=$(cat "$pidfile" 2>/dev/null)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    case "$args" in
        *title-spinner.sh*) printf '%s' "$pid"; return 0 ;;
    esac
    return 1
}

# Find the Claude process for the spinner to watch: the nearest ancestor whose
# command line mentions "claude". Hooks may run under a short-lived
# intermediate shell, so bare $PPID could die the moment the hook exits and
# take the spinner with it. Falls back to $PPID when nothing matches.
_title_claude_pid() {
    local pid=$$ args _i
    for _i in 1 2 3 4 5 6 7 8; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        case "$pid" in '' | 0 | 1) break ;; esac
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
            *claude*) printf '%s' "$pid"; return 0 ;;
        esac
    done
    printf '%s' "$PPID"
}

title_spinner_start() {
    local session_id="${1:-}" base="${2:-}"
    local pidfile oldpid
    pidfile=$(_title_pid_file "$session_id")
    mkdir -p "$TITLE_STATE_DIR" 2>/dev/null || return 0
    if oldpid=$(_title_spinner_pid "$pidfile"); then
        kill "$oldpid" 2>/dev/null
    fi
    rm -f "$pidfile" 2>/dev/null
    # Double-fork so the daemon is orphaned immediately and survives this
    # hook's exit (setsid is not portable to macOS). The tty is opened here,
    # pre-detach; if there is no controlling terminal the redirection fails
    # inside the subshell and no daemon is spawned — exactly the desired no-op.
    ( "$_TITLE_SCRIPT_DIR/title-spinner.sh" "$base" "$(_title_claude_pid)" "$pidfile" \
        >> "$(_title_tty)" < /dev/null 2>/dev/null & ) 2>/dev/null
    return 0
}

title_spinner_ensure() {
    local session_id="${1:-}" base="${2:-}"
    _title_spinner_pid "$(_title_pid_file "$session_id")" >/dev/null && return 0
    title_spinner_start "$session_id" "$base"
}

title_spinner_stop() {
    local session_id="${1:-}" static_title="${2:-}"
    local pid pidfile
    pidfile=$(_title_pid_file "$session_id")
    if pid=$(_title_spinner_pid "$pidfile"); then
        kill "$pid" 2>/dev/null
    fi
    rm -f "$pidfile" 2>/dev/null
    [ -n "$static_title" ] && title_set "$static_title"
    return 0
}

# --- Event wrappers: one call per hook script ---

title_on_working() {   # UserPromptSubmit — Claude started working
    title_enabled || return 0
    title_spinner_start "$(_title_session_id "${1:-}")" "$(title_base "${1:-}")"
}

title_on_tool_done() { # PostToolUse — still working; restarts after a permission grant
    title_enabled || return 0
    title_spinner_ensure "$(_title_session_id "${1:-}")" "$(title_base "${1:-}")"
}

title_on_blocked() {   # PermissionRequest / idle Notification — needs the user
    title_enabled || return 0
    title_spinner_stop "$(_title_session_id "${1:-}")" "● $(title_base "${1:-}")"
}

title_on_idle() {      # Stop / SessionStart — not working, nothing pending
    title_enabled || return 0
    title_spinner_stop "$(_title_session_id "${1:-}")" "$(title_base "${1:-}")"
}
