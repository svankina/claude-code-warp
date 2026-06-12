# Animated Terminal-Title Spinner — Design

**Date:** 2026-06-12
**Status:** Approved approach (A — detached spinner daemon); spec pending user review

## Goal

Reproduce pi-warp's "Animated terminal title" feature in the `warp` Claude Code
plugin: while Claude is working, the terminal tab title shows an animated
braille spinner next to the project name; when Claude is blocked waiting on the
user it shows a static attention marker; when idle it shows the plain project
name.

| State | Title | Trigger |
|---|---|---|
| Working | `⠋ claude-code-warp` (animated) | `UserPromptSubmit`, work resuming after a tool runs |
| Blocked on user | `● claude-code-warp` (static) | `PermissionRequest`, idle `Notification` |
| Idle / done | `claude-code-warp` (static) | `Stop`, `SessionStart` |

The title base is the basename of the session `cwd` (from the hook input
JSON). No "Claude" prefix — Warp already shows the agent icon on the tab.

## Why a daemon

pi-warp is a long-lived in-process extension and animates with `setInterval`.
This plugin is short-lived bash hooks, so continuous animation requires a
detached background process that outlives each hook invocation.

## Components

### `scripts/title.sh` (new, sourced helper)

Shared functions used by the hook scripts:

- `title_enabled` — gate: inside Warp (`TERM_PROGRAM = WarpTerminal` or
  `WARP_CLI_AGENT_PROTOCOL_VERSION` set) AND not opted out
  (`WARP_CLAUDE_DYNAMIC_TITLE` ≠ `0`). Note this is deliberately **not**
  `should_use_structured` — OSC 0 titles are plain terminal sequences, not the
  cli-agent protocol, so they work on older Warp builds too.
- `title_base <hook-input-json>` — basename of `.cwd`, falling back to `$PWD`.
- `title_format_osc0 <text>` — returns `\x1b]0;<text>\x07`.
- `title_set <text>` — write OSC 0 to `/dev/tty`; silently no-op on failure.
- `title_spinner_start <session_id> <base>` — kill any existing spinner for
  the session, then spawn the daemon (see below) detached.
- `title_spinner_ensure <session_id> <base>` — start the spinner only if the
  PID file shows none running (used by `PostToolUse` to resume animation after
  a permission grant).
- `title_spinner_stop <session_id> [static-title]` — kill the daemon, remove
  the PID file, optionally set a static title (`● base` or `base`).

### `scripts/title-spinner.sh` (new, the daemon)

A loop that cycles the pi-warp frames `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` every 120 ms,
writing one OSC 0 sequence per frame to **stdout**. It exits when:

- the Claude process dies — the spawning hook passes its `$PPID` (the Claude
  process) and the loop checks `kill -0` each iteration; or
- it loses ownership — each iteration verifies the PID file still contains its
  own PID (a newer spinner or a stop event took over / cleaned up).

**TTY handling:** after `setsid` the daemon has no controlling terminal, so it
cannot open `/dev/tty` itself. The spawning hook opens `/dev/tty` *before*
detaching and wires it to the daemon's stdout; the inherited fd keeps working
after detach. This is portable to macOS (no `/proc` tricks).

### State

Per-session PID file: `${TMPDIR:-/tmp}/.warp-claude-title/<safe-session-id>.pid`
where `<safe-session-id>` is the hook's `session_id` sanitized with
`tr -c 'A-Za-z0-9_.-' '_'` (same scheme as the existing command cache).
Multiple concurrent sessions each get their own PID file and write to their own
PTY, so tabs don't interfere.

## Hook wiring (no new hook events)

| Hook script | Title action added |
|---|---|
| `on-prompt-submit.sh` | `title_spinner_start` |
| `on-post-tool-use.sh` | `title_spinner_ensure` |
| `on-permission-request.sh` | `title_spinner_stop` with `● base` |
| `on-notification.sh` (idle_prompt) | `title_spinner_stop` with `● base` |
| `on-stop.sh` | `title_spinner_stop` with plain `base` |
| `on-session-start.sh` | `title_spinner_stop` with plain `base` (also clears stale state on resume) |

Each call is appended to the existing scripts and guarded by `title_enabled`;
the existing notification logic is untouched and title failures never block a
hook (always exit 0 paths).

## Error handling

- `/dev/tty` unavailable (piped/headless): every title write silently no-ops;
  the spinner daemon is simply not spawned if the pre-detach open fails.
- Stale PID file (crashed session): `title_spinner_start` kills only a PID
  that is still alive **and** whose command matches `title-spinner.sh` before
  reusing the file, so an unrelated recycled PID is never killed.
- Orphan prevention: parent-liveness check (`kill -0` on the Claude PID) plus
  PID-file ownership check each frame; worst-case orphan lifetime is one
  120 ms tick.
- Opt-out: `WARP_CLAUDE_DYNAMIC_TITLE=0` disables all title behavior.

## Testing

Extend `tests/test-hooks.sh` (same assert style, no `/dev/tty` needed):

- `title_format_osc0` produces the exact escape sequence.
- `title_base` extracts cwd basename and falls back correctly.
- `title_enabled` honors the Warp-detection and opt-out env vars.
- PID-file lifecycle: start writes the file, ensure is a no-op while running,
  stop removes it and the daemon exits (run the daemon with stdout to a temp
  file standing in for the tty; assert frames were written and the process is
  gone after stop).
- Ownership/liveness: daemon exits when its PID file is removed and when the
  watched parent PID dies.

## Out of scope

- Warp-native title animation driven by session status (a Warp product
  change, tracked as the long-term ideal).
- Animating anything other than the terminal title (pi-warp's notifications
  and session-status features already exist in this plugin).
- A settings panel; the env-var opt-out is sufficient for now.
