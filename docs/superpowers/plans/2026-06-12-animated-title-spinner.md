# Animated Terminal-Title Spinner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While Claude works, animate a braille spinner (`⠋ project`) in the Warp tab title; show `● project` when blocked on the user; plain `project` when idle.

**Architecture:** A sourced bash helper (`title.sh`) gives every existing hook a one-line `title_on_*` call. A detached daemon (`title-spinner.sh`) writes OSC 0 frames every 120 ms to the PTY it inherited at spawn time, and self-terminates via a per-session PID-file ownership check plus a liveness check on the Claude process. No new hook events, no new dependencies.

**Tech Stack:** Bash, OSC 0 escape sequences, the repo's existing `tests/test-hooks.sh` harness (plain asserts, no framework).

**Spec:** `docs/superpowers/specs/2026-06-12-animated-title-spinner-design.md`

**Execution notes:**
- Work in a git worktree: `git worktree add .worktrees/title-spinner -b title-spinner` (per user's global CLAUDE.md; use the superpowers:using-git-worktrees skill). All paths below are relative to the worktree root.
- The main checkout has unrelated uncommitted changes to `on-session-start.sh` and `warp-notify.sh` — do NOT touch or include them; the worktree branches from clean `main`.
- Run tests with: `bash plugins/warp/tests/test-hooks.sh` (exit 0, `0 failed`).
- The test harness uses `set -uo pipefail` — everything in `title.sh` must be nounset-safe.
- Design deviations from the spec, decided here: (1) no `setsid` (absent on macOS) — a double-fork `( cmd & )` orphans the daemon just as well; (2) the daemon writes its own PID file (the spawner can't learn the PID through a double fork); (3) the watched Claude PID comes from an ancestor walk (`_title_claude_pid`), not bare `$PPID`, because hooks may run under an intermediate shell that exits immediately; (4) a `WARP_TITLE_TTY` env override exists so tests can substitute a temp file for `/dev/tty`.

---

## File map

| File | Role |
|---|---|
| `plugins/warp/scripts/title.sh` (create) | Sourced helpers: gating, title formatting/writing, PID-file paths, spinner lifecycle, `title_on_*` event wrappers |
| `plugins/warp/scripts/title-spinner.sh` (create) | The detached animation daemon |
| `plugins/warp/scripts/on-prompt-submit.sh` (modify) | start spinner |
| `plugins/warp/scripts/on-post-tool-use.sh` (modify) | ensure spinner running |
| `plugins/warp/scripts/on-permission-request.sh` (modify) | stop spinner → `● project` |
| `plugins/warp/scripts/on-notification.sh` (modify) | stop spinner → `● project` |
| `plugins/warp/scripts/on-stop.sh` (modify) | stop spinner → `project` |
| `plugins/warp/scripts/on-session-start.sh` (modify) | clear stale spinner → `project` |
| `plugins/warp/tests/test-hooks.sh` (modify) | tests for all of the above |
| `README.md` (modify) | document the feature + opt-out |

State at runtime: `${TMPDIR:-/tmp}/.warp-claude-title/<sanitized-session-id>.pid` (same sanitization scheme as the existing command cache in `warp-notify.sh`).

---

### Task 1: `title.sh` core helpers

**Files:**
- Create: `plugins/warp/scripts/title.sh`
- Test: `plugins/warp/tests/test-hooks.sh`

- [ ] **Step 1: Write the failing tests**

Append to `plugins/warp/tests/test-hooks.sh`, immediately BEFORE the `# --- Summary ---` section:

```bash
echo ""
echo "=== title.sh ==="

source "$SCRIPT_DIR/title.sh"

echo ""
echo "--- title_format_osc0 ---"
assert_eq "osc0 format" "$(printf '\033]0;hello\007')" "$(title_format_osc0 'hello')"

echo ""
echo "--- title_base ---"
assert_eq "basename of cwd" "my-project" "$(title_base '{"cwd":"/Users/alice/my-project"}')"
assert_eq "falls back to PWD basename" "$(basename "$PWD")" "$(title_base '{}')"
assert_eq "falls back on invalid json" "$(basename "$PWD")" "$(title_base 'not json')"

echo ""
echo "--- _title_session_id ---"
assert_eq "extracts session id" "sess-9" "$(_title_session_id '{"session_id":"sess-9"}')"
assert_eq "missing id falls back" "nosession" "$(_title_session_id '{}')"

echo ""
echo "--- _title_pid_file ---"
assert_eq "pid file path" "${TMPDIR:-/tmp}/.warp-claude-title/sess-123.pid" "$(_title_pid_file 'sess-123')"
assert_eq "sanitizes unsafe chars" "${TMPDIR:-/tmp}/.warp-claude-title/a_b_c.pid" "$(_title_pid_file 'a/b:c')"

echo ""
echo "--- title_enabled ---"
( unset TERM_PROGRAM WARP_CLI_AGENT_PROTOCOL_VERSION WARP_CLAUDE_DYNAMIC_TITLE 2>/dev/null
  title_enabled )
assert_eq "disabled outside Warp" "1" "$?"
( unset WARP_CLI_AGENT_PROTOCOL_VERSION WARP_CLAUDE_DYNAMIC_TITLE 2>/dev/null
  TERM_PROGRAM=WarpTerminal title_enabled )
assert_eq "enabled via TERM_PROGRAM" "0" "$?"
( unset TERM_PROGRAM WARP_CLAUDE_DYNAMIC_TITLE 2>/dev/null
  WARP_CLI_AGENT_PROTOCOL_VERSION=2 title_enabled )
assert_eq "enabled via protocol version" "0" "$?"
( unset WARP_CLI_AGENT_PROTOCOL_VERSION 2>/dev/null
  TERM_PROGRAM=WarpTerminal WARP_CLAUDE_DYNAMIC_TITLE=0 title_enabled )
assert_eq "opt-out wins" "1" "$?"

echo ""
echo "--- title_set ---"
TITLE_TEST_DIR=$(mktemp -d)
WARP_TITLE_TTY="$TITLE_TEST_DIR/tty" title_set "proj"
assert_eq "writes osc0 to tty" "$(printf '\033]0;proj\007')" "$(cat "$TITLE_TEST_DIR/tty")"
WARP_TITLE_TTY="$TITLE_TEST_DIR/no/such/dir/tty" title_set "proj"
assert_eq "unwritable tty is silent no-op" "0" "$?"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: FAIL — `source: .../title.sh: No such file or directory` (harness aborts; that counts as the failing state).

- [ ] **Step 3: Create `plugins/warp/scripts/title.sh`**

```bash
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
    title_format_osc0 "${1:-}" >> "$(_title_tty)" 2>/dev/null || true
}

# Per-session PID file, session id sanitized like warp-notify.sh's cache.
_title_pid_file() {
    local safe
    safe=$(printf '%s' "${1:-nosession}" | tr -c 'A-Za-z0-9_.-' '_')
    printf '%s/%s.pid' "$TITLE_STATE_DIR" "$safe"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: PASS — all new `title.sh` asserts ✓, `0 failed`, and all pre-existing tests still ✓.

- [ ] **Step 5: Commit**

```bash
git add plugins/warp/scripts/title.sh plugins/warp/tests/test-hooks.sh
git commit -m "feat: add title.sh core helpers for dynamic terminal titles"
```

---

### Task 2: `title-spinner.sh` daemon

**Files:**
- Create: `plugins/warp/scripts/title-spinner.sh`
- Test: `plugins/warp/tests/test-hooks.sh`

- [ ] **Step 1: Write the failing tests**

Append to `plugins/warp/tests/test-hooks.sh` (after the Task 1 block, still before `# --- Summary ---`):

```bash
echo ""
echo "--- title-spinner.sh daemon ---"

SPINNER="$SCRIPT_DIR/title-spinner.sh"

# Writes animated frames while the watched pid is alive
SPIN_OUT="$TITLE_TEST_DIR/spin-tty"
SPIN_PIDF="$TITLE_TEST_DIR/spin.pid"
sleep 5 & SPIN_WATCH=$!
bash "$SPINNER" "proj" "$SPIN_WATCH" "$SPIN_PIDF" >> "$SPIN_OUT" 2>/dev/null &
SPIN_PID=$!
sleep 0.6
grep -q '⠋ proj' "$SPIN_OUT"
assert_eq "spinner frame written" "0" "$?"
grep -q '⠙ proj' "$SPIN_OUT"
assert_eq "frames advance" "0" "$?"
assert_eq "pid file holds daemon pid" "$SPIN_PID" "$(cat "$SPIN_PIDF")"

# Loses pid-file ownership → exits without touching the title further
echo "99999" > "$SPIN_PIDF"
sleep 0.5
kill -0 "$SPIN_PID" 2>/dev/null
assert_eq "daemon exits on ownership loss" "1" "$?"
assert_eq "usurped pid file left alone" "99999" "$(cat "$SPIN_PIDF")"
kill "$SPIN_WATCH" 2>/dev/null

# Watched pid dies → daemon restores plain title and removes its pid file
SPIN_OUT2="$TITLE_TEST_DIR/spin-tty2"
SPIN_PIDF2="$TITLE_TEST_DIR/spin2.pid"
sleep 0.3 & SPIN_WATCH2=$!
bash "$SPINNER" "proj" "$SPIN_WATCH2" "$SPIN_PIDF2" >> "$SPIN_OUT2" 2>/dev/null &
SPIN_PID2=$!
sleep 1.2
kill -0 "$SPIN_PID2" 2>/dev/null
assert_eq "daemon exits when watched pid dies" "1" "$?"
grep -q "$(printf '\033]0;proj\007')" "$SPIN_OUT2"
assert_eq "plain title restored on watch death" "0" "$?"
[ -f "$SPIN_PIDF2" ]
assert_eq "pid file removed on watch death" "1" "$?"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: the new daemon asserts FAIL (`title-spinner.sh: No such file or directory` → frames never written); earlier tests still pass.

- [ ] **Step 3: Create `plugins/warp/scripts/title-spinner.sh`**

```bash
#!/bin/bash
# Animated terminal-title spinner daemon.
#
# Usage: title-spinner.sh <base-title> <watch-pid> <pid-file>
#
# Writes one OSC 0 frame ("⠋ base") to STDOUT every 120 ms; the spawner wires
# stdout to the controlling terminal BEFORE detaching, so writes keep reaching
# the PTY after this process is orphaned. Exits when:
#   - the pid file no longer contains this pid (a newer spinner or a stop
#     event took ownership — the new owner controls the title), or
#   - <watch-pid> (the Claude process) dies — then it restores the plain
#     static title and removes the pid file, or
#   - a frame write fails (the terminal went away).

BASE="${1:-}"
WATCH_PID="${2:-}"
PID_FILE="${3:-}"

[ -n "$PID_FILE" ] || exit 0

FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
INTERVAL=0.12

printf '%s' "$$" > "$PID_FILE" 2>/dev/null || exit 0

i=0
while :; do
    [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] || exit 0
    if [ -z "$WATCH_PID" ] || ! kill -0 "$WATCH_PID" 2>/dev/null; then
        break
    fi
    printf '\033]0;%s %s\007' "${FRAMES[$((i % ${#FRAMES[@]}))]}" "$BASE" || break
    i=$(( (i + 1) % ${#FRAMES[@]} ))
    sleep "$INTERVAL"
done

# Claude died (or the tty went away) without a Stop hook: leave a clean title.
printf '\033]0;%s\007' "$BASE" 2>/dev/null
rm -f "$PID_FILE" 2>/dev/null
exit 0
```

Then: `chmod +x plugins/warp/scripts/title-spinner.sh`

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: PASS, `0 failed`. (These tests involve real timing; if one flakes, bump the post-spawn sleeps slightly — never assert faster than one 0.12 s frame interval.)

- [ ] **Step 5: Commit**

```bash
git add plugins/warp/scripts/title-spinner.sh plugins/warp/tests/test-hooks.sh
git commit -m "feat: add title-spinner daemon with ownership and liveness checks"
```

---

### Task 3: Spinner lifecycle in `title.sh`

**Files:**
- Modify: `plugins/warp/scripts/title.sh` (append)
- Test: `plugins/warp/tests/test-hooks.sh`

- [ ] **Step 1: Write the failing tests**

Append to `plugins/warp/tests/test-hooks.sh` (after the Task 2 block):

```bash
echo ""
echo "--- _title_claude_pid ---"

# A probe run under a parent whose command line contains "claude" must return
# that parent's pid (the ancestor walk), not its immediate $PPID blindly.
TITLE_PROBE="$TITLE_TEST_DIR/probe.sh"
cat > "$TITLE_PROBE" <<PROBE_EOF
source "$SCRIPT_DIR/title.sh"
_title_claude_pid
PROBE_EOF
TITLE_HOST="$TITLE_TEST_DIR/fake-claude-host.sh"
cat > "$TITLE_HOST" <<HOST_EOF
echo "\$\$"
bash "$TITLE_PROBE"
HOST_EOF
HOST_OUT=$(bash "$TITLE_HOST")
assert_eq "finds claude ancestor" "$(echo "$HOST_OUT" | head -1)" "$(echo "$HOST_OUT" | tail -1)"

echo ""
echo "--- spinner lifecycle ---"

LIFE_TTY="$TITLE_TEST_DIR/life-tty"
LIFE_INPUT='{"session_id":"title-life-1","cwd":"/tmp/proj"}'
LIFE_PIDF=$(_title_pid_file "title-life-1")
export TERM_PROGRAM=WarpTerminal
export WARP_TITLE_TTY="$LIFE_TTY"

# working → spinner starts
title_on_working "$LIFE_INPUT"
sleep 0.6
LIFE_PID=$(cat "$LIFE_PIDF" 2>/dev/null)
[ -n "$LIFE_PID" ] && kill -0 "$LIFE_PID" 2>/dev/null
assert_eq "working starts a live spinner" "0" "$?"
grep -q '⠋ proj' "$LIFE_TTY"
assert_eq "spinner animates the base title" "0" "$?"

# tool_done while running → same daemon (ensure is a no-op)
title_on_tool_done "$LIFE_INPUT"
sleep 0.3
assert_eq "ensure keeps the same daemon" "$LIFE_PID" "$(cat "$LIFE_PIDF" 2>/dev/null)"

# blocked → daemon killed, attention marker written
title_on_blocked "$LIFE_INPUT"
sleep 0.4
kill -0 "$LIFE_PID" 2>/dev/null
assert_eq "blocked kills the spinner" "1" "$?"
[ -f "$LIFE_PIDF" ]
assert_eq "blocked removes the pid file" "1" "$?"
grep -q '● proj' "$LIFE_TTY"
assert_eq "blocked writes attention marker" "0" "$?"

# tool_done while stopped → spinner restarts (post-permission-grant path)
title_on_tool_done "$LIFE_INPUT"
sleep 0.6
LIFE_PID2=$(cat "$LIFE_PIDF" 2>/dev/null)
[ -n "$LIFE_PID2" ] && kill -0 "$LIFE_PID2" 2>/dev/null
assert_eq "tool_done restarts spinner after blocked" "0" "$?"

# idle → daemon killed, plain title written
title_on_idle "$LIFE_INPUT"
sleep 0.4
kill -0 "$LIFE_PID2" 2>/dev/null
assert_eq "idle kills the spinner" "1" "$?"
grep -q "$(printf '\033]0;proj\007')" "$LIFE_TTY"
assert_eq "idle writes plain title" "0" "$?"

# disabled → no spinner at all
WARP_CLAUDE_DYNAMIC_TITLE=0 title_on_working "$LIFE_INPUT"
sleep 0.4
[ -f "$LIFE_PIDF" ]
assert_eq "opt-out spawns nothing" "1" "$?"

unset WARP_TITLE_TTY
unset TERM_PROGRAM
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: FAIL — `_title_claude_pid: command not found`, `title_on_working: command not found`, etc.

- [ ] **Step 3: Append the lifecycle functions to `plugins/warp/scripts/title.sh`**

```bash
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/warp/scripts/title.sh plugins/warp/tests/test-hooks.sh
git commit -m "feat: add spinner lifecycle and per-event title wrappers"
```

---

### Task 4: Wire the six hook scripts

Pattern for every hook: read `INPUT` FIRST, call the `title_on_*` wrapper, THEN run the existing gate/logic unchanged. The title call must sit before the `should_use_structured` early-exit so titles also work on legacy Warp builds (`title_enabled` does its own Warp detection). Hooks that `exec` a legacy script which reads stdin must now pipe `$INPUT` into it, since stdin has already been consumed.

**Files:**
- Modify: `plugins/warp/scripts/on-prompt-submit.sh`
- Modify: `plugins/warp/scripts/on-post-tool-use.sh`
- Modify: `plugins/warp/scripts/on-permission-request.sh`
- Modify: `plugins/warp/scripts/on-notification.sh`
- Modify: `plugins/warp/scripts/on-stop.sh`
- Modify: `plugins/warp/scripts/on-session-start.sh`
- Test: `plugins/warp/tests/test-hooks.sh`

- [ ] **Step 1: Write the failing tests**

Append to `plugins/warp/tests/test-hooks.sh` (inside/after the existing `=== Routing ===` additions, before `# --- Summary ---`):

```bash
echo ""
echo "--- Hook-level title integration ---"

HOOK_TTY="$TITLE_TEST_DIR/hook-tty"
HOOK_INPUT='{"session_id":"hook-title-1","cwd":"/tmp/proj"}'
HOOK_PIDF=$(_title_pid_file "hook-title-1")

# prompt-submit on legacy Warp (no protocol version) still starts the spinner
echo "$HOOK_INPUT" | TERM_PROGRAM=WarpTerminal WARP_TITLE_TTY="$HOOK_TTY" \
    bash "$HOOK_DIR/on-prompt-submit.sh" >/dev/null 2>&1
sleep 0.6
HOOK_SPID=$(cat "$HOOK_PIDF" 2>/dev/null)
[ -n "$HOOK_SPID" ] && kill -0 "$HOOK_SPID" 2>/dev/null
assert_eq "prompt-submit starts spinner" "0" "$?"
grep -q '⠋ proj' "$HOOK_TTY"
assert_eq "spinner output reached the hook tty" "0" "$?"

# stop kills it and leaves a plain title
echo "$HOOK_INPUT" | TERM_PROGRAM=WarpTerminal WARP_TITLE_TTY="$HOOK_TTY" \
    bash "$HOOK_DIR/on-stop.sh" >/dev/null 2>&1
sleep 0.4
kill -0 "$HOOK_SPID" 2>/dev/null
assert_eq "stop kills the spinner" "1" "$?"
grep -q "$(printf '\033]0;proj\007')" "$HOOK_TTY"
assert_eq "stop writes plain title" "0" "$?"

# permission-request leaves the attention marker
echo "$HOOK_INPUT" | TERM_PROGRAM=WarpTerminal WARP_TITLE_TTY="$HOOK_TTY" \
    bash "$HOOK_DIR/on-prompt-submit.sh" >/dev/null 2>&1
sleep 0.4
echo "$HOOK_INPUT" | TERM_PROGRAM=WarpTerminal WARP_TITLE_TTY="$HOOK_TTY" \
    bash "$HOOK_DIR/on-permission-request.sh" >/dev/null 2>&1
sleep 0.4
grep -q '● proj' "$HOOK_TTY"
assert_eq "permission-request writes attention marker" "0" "$?"
[ -f "$HOOK_PIDF" ]
assert_eq "permission-request removes pid file" "1" "$?"

# opt-out is honored end to end
echo "$HOOK_INPUT" | TERM_PROGRAM=WarpTerminal WARP_TITLE_TTY="$HOOK_TTY" \
    WARP_CLAUDE_DYNAMIC_TITLE=0 bash "$HOOK_DIR/on-prompt-submit.sh" >/dev/null 2>&1
sleep 0.4
[ -f "$HOOK_PIDF" ]
assert_eq "opt-out: no spinner from hooks" "1" "$?"
```

Note: the pre-existing routing test "legacy Warp shows active message" pipes `< /dev/null` into `on-session-start.sh` with `TERM_PROGRAM=WarpTerminal` — after this task that hook also calls `title_on_idle`, which with no `WARP_TITLE_TTY` writes to `/dev/tty` and silently no-ops in CI. It must keep passing unchanged.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: the four spinner/marker asserts FAIL (hooks don't touch titles yet); everything else passes.

- [ ] **Step 3: Edit the hooks**

`on-prompt-submit.sh` — replace lines 6–17 (from `SCRIPT_DIR=` through `INPUT=$(cat)`) with:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read hook input from stdin
INPUT=$(cat)

# Animate the tab title while Claude works (no-op outside Warp).
source "$SCRIPT_DIR/title.sh"
title_on_working "$INPUT"

source "$SCRIPT_DIR/should-use-structured.sh"

# No legacy equivalent for this hook
if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/build-payload.sh"
```

(The rest of the file — `QUERY=` extraction onward — is unchanged; just delete the now-duplicate `INPUT=$(cat)` and its comment.)

`on-post-tool-use.sh` — same restructure, with `title_on_tool_done "$INPUT"` as the wrapper call:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read hook input from stdin
INPUT=$(cat)

# Keep the tab-title spinner alive (restarts it after a permission grant).
source "$SCRIPT_DIR/title.sh"
title_on_tool_done "$INPUT"

source "$SCRIPT_DIR/should-use-structured.sh"

# No legacy equivalent for this hook
if ! should_use_structured; then
    exit 0
fi

source "$SCRIPT_DIR/build-payload.sh"
```

`on-permission-request.sh` — same restructure, wrapper call `title_on_blocked "$INPUT"`, comment `# Show the attention marker in the tab title (no-op outside Warp).`

`on-notification.sh` — wrapper call `title_on_blocked "$INPUT"`; this hook HAS a legacy fallback whose script reads stdin, so the gate block becomes:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read hook input from stdin
INPUT=$(cat)

# Show the attention marker in the tab title (no-op outside Warp).
source "$SCRIPT_DIR/title.sh"
title_on_blocked "$INPUT"

source "$SCRIPT_DIR/should-use-structured.sh"

# Legacy fallback for old Warp versions (stdin already consumed — pipe it)
if ! should_use_structured; then
    if [ "$TERM_PROGRAM" = "WarpTerminal" ]; then
        printf '%s' "$INPUT" | "$SCRIPT_DIR/legacy/on-notification.sh"
    fi
    exit 0
fi

source "$SCRIPT_DIR/build-payload.sh"
```

`on-stop.sh` — wrapper call `title_on_idle "$INPUT"`, comment `# Clear the tab-title spinner; Claude is done (no-op outside Warp).`, and the same piped legacy fallback using `legacy/on-stop.sh`. Delete the later duplicate `INPUT=$(cat)` line and its comment; everything from the `STOP_HOOK_ACTIVE=` check onward is unchanged.

`on-session-start.sh` — insert after the `install-commands.sh` line (line 9) and before the legacy-fallback block:

```bash
# Read hook input from stdin
INPUT=$(cat)

# Reset the tab title; clears any spinner left over from a previous session.
source "$SCRIPT_DIR/title.sh"
title_on_idle "$INPUT"
```

Then delete the later duplicate `INPUT=$(cat)` and its comment (currently lines 26–27). The legacy `exec "$SCRIPT_DIR/legacy/on-session-start.sh"` stays as-is — that legacy script never reads stdin.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: PASS, `0 failed` — including the pre-existing "legacy Warp shows active message" and "exits 0 without protocol version" routing tests.

- [ ] **Step 5: Manual smoke test (inside Warp)**

From a Warp tab, in the worktree: run `claude`, submit a prompt, and watch the tab title show the animated `⠋ <project>`; trigger a permission prompt → `● <project>`; let it finish → plain `<project>`. Verify `ls ${TMPDIR:-/tmp}/.warp-claude-title/` is empty after the turn ends. (Requires pointing Claude Code at the worktree plugin or copying scripts over the installed plugin — note in the PR if not feasible; the hook-level tests cover the logic.)

- [ ] **Step 6: Commit**

```bash
git add plugins/warp/scripts/on-*.sh plugins/warp/tests/test-hooks.sh
git commit -m "feat: drive dynamic tab titles from all six hooks"
```

---

### Task 5: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the feature to README.md**

Insert after the `### 📡 Session Status` section (after line 22):

```markdown
### ⠋ Dynamic Terminal Title

The tab title animates while Claude works, so a glance tells you the session state:

- **Working** — `⠋ project` with an animated braille spinner
- **Needs you** — `● project` when Claude is waiting on a permission prompt or idle
- **Done** — plain `project`

Works on any Warp build (it uses plain OSC 0 titles, not the structured protocol). Disable it by setting `WARP_CLAUDE_DYNAMIC_TITLE=0` in your environment.
```

And in the `## Configuration` section, append:

```markdown
To turn off the animated tab title, export `WARP_CLAUDE_DYNAMIC_TITLE=0` before launching Claude Code.
```

- [ ] **Step 2: Full test run**

Run: `bash plugins/warp/tests/test-hooks.sh`
Expected: PASS, `0 failed`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document the dynamic terminal title feature"
```

---

## Self-review notes (already applied)

- Spec coverage: gating/opt-out (Task 1), daemon + frames + liveness/ownership (Task 2), lifecycle + `●` blocked marker + restart-after-grant (Task 3), all six hooks incl. legacy-Warp support and stdin piping to legacy scripts (Task 4), docs (Task 5). Spec's "kills only a PID … whose command matches title-spinner.sh" → `_title_spinner_pid`.
- Deviations from spec are intentional and listed under Execution notes (no setsid, daemon-written PID file, ancestor walk, test tty override).
- Type/name consistency: `title_on_working` / `title_on_tool_done` / `title_on_blocked` / `title_on_idle`, `_title_pid_file`, `TITLE_STATE_DIR`, `WARP_TITLE_TTY`, `WARP_CLAUDE_DYNAMIC_TITLE` used identically across tasks.
