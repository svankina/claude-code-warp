#!/bin/bash
# Terminal-title helpers (OSC 0) for the dynamic-title spinner.
#
# Working: ⠋ project   (animated braille spinner, driven by title-spinner.sh)
# Blocked: ● project   (static attention marker — Claude needs the user)
# Idle:    project     (static)
#
# Source this file from a hook script, then call one title_on_* wrapper.
# Everything here is a silent no-op outside Warp, when /dev/tty is
# unavailable, or when the user opts out with WARP_CLAUDE_DYNAMIC_TITLE=0.
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
    fi
    [ -z "$cwd" ] && cwd="$PWD"
    basename "$cwd"
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
