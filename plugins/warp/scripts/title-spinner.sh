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

printf '%s\n' "$$" > "$PID_FILE" 2>/dev/null || exit 0

i=0
owner=""
while :; do
    IFS= read -r owner < "$PID_FILE" 2>/dev/null || owner=""
    [ "$owner" = "$$" ] || exit 0
    if [ -z "$WATCH_PID" ] || ! kill -0 "$WATCH_PID" 2>/dev/null; then
        break
    fi
    printf '\033]0;%s %s\007' "${FRAMES[$((i % ${#FRAMES[@]}))]}" "$BASE" || break
    i=$(( (i + 1) % ${#FRAMES[@]} ))
    sleep "$INTERVAL"
done

# Claude died (or the tty went away) without a Stop hook: leave a clean title.
# Re-check ownership first - a newer spinner may have taken over between the
# last loop check and now; its title and pid file are not ours to touch.
IFS= read -r owner < "$PID_FILE" 2>/dev/null || owner=""
if [ "$owner" = "$$" ]; then
    printf '\033]0;%s\007' "$BASE" 2>/dev/null
    rm -f "$PID_FILE" 2>/dev/null
fi
exit 0
