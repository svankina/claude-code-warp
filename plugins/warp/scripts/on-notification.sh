#!/bin/bash
# Hook script for Claude Code Notification event (idle_prompt only)
# Sends a structured Warp notification when Claude has been idle

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
        exit $?
    fi
    exit 0
fi

source "$SCRIPT_DIR/build-payload.sh"

# Extract notification-specific fields
NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"' 2>/dev/null)
MSG=$(echo "$INPUT" | jq -r '.message // "Input needed"' 2>/dev/null)
[ -z "$MSG" ] && MSG="Input needed"

BODY=$(build_payload "$INPUT" "$NOTIF_TYPE" \
    --arg summary "$MSG")

"$SCRIPT_DIR/warp-notify.sh" "warp://cli-agent" "$BODY"
