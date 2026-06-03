#!/bin/bash
# Idempotently symlinks warpfork into ~/.local/bin and ~/.claude/commands.
# Called from on-session-start.sh. All output goes to /dev/null — this must
# not emit anything to stdout or it will corrupt the hook's JSON response.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BIN_DIR="${HOME}/.local/bin"
COMMANDS_DIR="${HOME}/.claude/commands"

mkdir -p "$BIN_DIR" "$COMMANDS_DIR"

ln -sf "${PLUGIN_ROOT}/bin/warpfork"        "${BIN_DIR}/warpfork"           2>/dev/null || true
ln -sf "${PLUGIN_ROOT}/commands/warpfork.md" "${COMMANDS_DIR}/warpfork.md"  2>/dev/null || true
