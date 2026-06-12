#!/bin/bash
# Tests for the Warp Claude Code plugin hook scripts.
#
# Validates that each hook script produces correctly structured JSON payloads
# by piping mock Claude Code hook input into the scripts and checking the output.
#
# Usage: ./tests/test-hooks.sh
#
# Since the hook scripts write OSC sequences to /dev/tty (not stdout),
# we test build-payload.sh directly — it's the shared JSON construction logic
# that all hook scripts use.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
source "$SCRIPT_DIR/build-payload.sh"

PASSED=0
FAILED=0

# --- Test helpers ---

assert_eq() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $test_name"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ $test_name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_json_field() {
    local test_name="$1"
    local json="$2"
    local field="$3"
    local expected="$4"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null)
    assert_eq "$test_name" "$expected" "$actual"
}

# --- Tests ---

echo "=== build-payload.sh ==="

echo ""
echo "--- Common fields ---"
PAYLOAD=$(build_payload '{"session_id":"sess-123","cwd":"/Users/alice/my-project"}' "stop")
assert_json_field "v is 1" "$PAYLOAD" ".v" "1"
assert_json_field "agent is claude" "$PAYLOAD" ".agent" "claude"
assert_json_field "event is stop" "$PAYLOAD" ".event" "stop"
assert_json_field "session_id extracted" "$PAYLOAD" ".session_id" "sess-123"
assert_json_field "cwd extracted" "$PAYLOAD" ".cwd" "/Users/alice/my-project"
assert_json_field "project is basename of cwd" "$PAYLOAD" ".project" "my-project"

echo ""
echo "--- Common fields with missing data ---"
PAYLOAD=$(build_payload '{}' "stop")
assert_json_field "empty session_id" "$PAYLOAD" ".session_id" ""
assert_json_field "empty cwd" "$PAYLOAD" ".cwd" ""
assert_json_field "empty project" "$PAYLOAD" ".project" ""

echo ""
echo "--- Extra args are merged ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "stop" \
    --arg query "hello" \
    --arg response "world")
assert_json_field "query merged" "$PAYLOAD" ".query" "hello"
assert_json_field "response merged" "$PAYLOAD" ".response" "world"
assert_json_field "common fields still present" "$PAYLOAD" ".session_id" "s1"

echo ""
echo "--- Stop event ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "stop" \
    --arg query "write a haiku" \
    --arg response "Memory is safe, the borrow checker stands guard" \
    --arg transcript_path "/tmp/transcript.jsonl")
assert_json_field "event is stop" "$PAYLOAD" ".event" "stop"
assert_json_field "query present" "$PAYLOAD" ".query" "write a haiku"
assert_json_field "response present" "$PAYLOAD" ".response" "Memory is safe, the borrow checker stands guard"
assert_json_field "transcript_path present" "$PAYLOAD" ".transcript_path" "/tmp/transcript.jsonl"

echo ""
echo "--- Permission request event ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "permission_request" \
    --arg summary "Wants to run Bash: rm -rf /tmp" \
    --arg tool_name "Bash" \
    --argjson tool_input '{"command":"rm -rf /tmp"}')
assert_json_field "event is permission_request" "$PAYLOAD" ".event" "permission_request"
assert_json_field "summary present" "$PAYLOAD" ".summary" "Wants to run Bash: rm -rf /tmp"
assert_json_field "tool_name present" "$PAYLOAD" ".tool_name" "Bash"
assert_json_field "tool_input.command present" "$PAYLOAD" ".tool_input.command" "rm -rf /tmp"

echo ""
echo "--- Idle prompt event ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj","notification_type":"idle_prompt"}' "idle_prompt" \
    --arg summary "Claude is waiting for your input")
assert_json_field "event is idle_prompt" "$PAYLOAD" ".event" "idle_prompt"
assert_json_field "summary present" "$PAYLOAD" ".summary" "Claude is waiting for your input"

echo ""
echo "--- JSON special characters in values ---"
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp/proj"}' "stop" \
    --arg query 'what does "hello world" mean?' \
    --arg response 'It means greeting. Use: printf("hello")')
assert_json_field "quotes in query preserved" "$PAYLOAD" ".query" 'what does "hello world" mean?'
assert_json_field "parens in response preserved" "$PAYLOAD" ".response" 'It means greeting. Use: printf("hello")'

echo ""
echo "--- Protocol version negotiation ---"

# Default: no env var set → falls back to plugin max (1)
unset WARP_CLI_AGENT_PROTOCOL_VERSION
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop")
assert_json_field "defaults to v1 when env var absent" "$PAYLOAD" ".v" "1"

# Warp declares v1 → use 1
export WARP_CLI_AGENT_PROTOCOL_VERSION=1
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop")
assert_json_field "v1 when warp declares 1" "$PAYLOAD" ".v" "1"

# Warp declares a higher version than the plugin knows → capped to plugin current
export WARP_CLI_AGENT_PROTOCOL_VERSION=99
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop")
assert_json_field "capped to plugin current when warp is ahead" "$PAYLOAD" ".v" "1"

# Warp declares a lower version than the plugin knows → use warp's version
# (not testable with PLUGIN_MAX=1 since there's no v0, but we verify the min logic
# by temporarily overriding the variable)
PLUGIN_CURRENT_PROTOCOL_VERSION=5
export WARP_CLI_AGENT_PROTOCOL_VERSION=3
PAYLOAD=$(build_payload '{"session_id":"s1","cwd":"/tmp"}' "stop")
assert_json_field "uses warp version when plugin is ahead" "$PAYLOAD" ".v" "3"
PLUGIN_CURRENT_PROTOCOL_VERSION=1

# Clean up
unset WARP_CLI_AGENT_PROTOCOL_VERSION

echo ""
echo "=== should-use-structured.sh ==="

source "$SCRIPT_DIR/../scripts/should-use-structured.sh"

echo ""
echo "--- No protocol version → legacy ---"
unset WARP_CLI_AGENT_PROTOCOL_VERSION
unset WARP_CLIENT_VERSION
should_use_structured
assert_eq "no protocol version returns false" "1" "$?"

echo ""
echo "--- Protocol set, no client version → legacy ---"
export WARP_CLI_AGENT_PROTOCOL_VERSION=1
unset WARP_CLIENT_VERSION
should_use_structured
assert_eq "missing WARP_CLIENT_VERSION returns false" "1" "$?"

echo ""
echo "--- Protocol set, dev version → always structured (dev was never broken) ---"
export WARP_CLI_AGENT_PROTOCOL_VERSION=1
export WARP_CLIENT_VERSION="v0.2026.03.30.08.43.dev_00"
should_use_structured
assert_eq "dev version returns true" "0" "$?"

echo ""
echo "--- Protocol set, broken stable version → legacy ---"
export WARP_CLIENT_VERSION="v0.2026.03.25.08.24.stable_05"
should_use_structured
assert_eq "exact broken stable version returns false" "1" "$?"

echo ""
echo "--- Protocol set, newer stable version → structured ---"
export WARP_CLIENT_VERSION="v0.2026.04.01.08.00.stable_00"
should_use_structured
assert_eq "newer stable version returns true" "0" "$?"

echo ""
echo "--- Protocol set, broken preview version → legacy ---"
export WARP_CLIENT_VERSION="v0.2026.03.25.08.24.preview_05"
should_use_structured
assert_eq "exact broken preview version returns false" "1" "$?"

echo ""
echo "--- Protocol set, newer preview version → structured ---"
export WARP_CLIENT_VERSION="v0.2026.04.01.08.00.preview_00"
should_use_structured
assert_eq "newer preview version returns true" "0" "$?"

# Clean up
unset WARP_CLI_AGENT_PROTOCOL_VERSION
unset WARP_CLIENT_VERSION

echo ""
echo "=== emit-terminal-sequence.sh ==="

source "$SCRIPT_DIR/../scripts/emit-terminal-sequence.sh"

echo ""
echo "--- Version comparison ---"
_version_at_least "2.1.141" "2.1.141"
assert_eq "equal versions" "0" "$?"
_version_at_least "2.1.142" "2.1.141"
assert_eq "newer patch" "0" "$?"
_version_at_least "2.2.0" "2.1.141"
assert_eq "newer minor" "0" "$?"
_version_at_least "3.0.0" "2.1.141"
assert_eq "newer major" "0" "$?"
_version_at_least "2.1.140" "2.1.141"
assert_eq "older patch" "1" "$?"
_version_at_least "2.0.999" "2.1.141"
assert_eq "older minor" "1" "$?"
_version_at_least "1.9.999" "2.1.141"
assert_eq "older major" "1" "$?"

echo ""
echo "--- Version parsing ---"
assert_eq "bare version" "2.1.141" "$(_parse_cc_version '2.1.141')"
assert_eq "prefixed with name" "2.1.141" "$(_parse_cc_version 'claude 2.1.141')"
assert_eq "prefixed with v" "2.1.141" "$(_parse_cc_version 'Claude Code v2.1.141')"
assert_eq "empty string" "" "$(_parse_cc_version '')"
assert_eq "no version" "" "$(_parse_cc_version 'no version here')"

echo ""
echo "--- _supports_terminal_sequence ---"

unset CLAUDE_CODE_VERSION
_supports_terminal_sequence
assert_eq "unset version → false" "1" "$?"

export CLAUDE_CODE_VERSION="2.1.141"
_supports_terminal_sequence
assert_eq "exact min version → true" "0" "$?"

export CLAUDE_CODE_VERSION="claude 2.1.150"
_supports_terminal_sequence
assert_eq "newer with prefix → true" "0" "$?"

export CLAUDE_CODE_VERSION="2.1.100"
_supports_terminal_sequence
assert_eq "older version → false" "1" "$?"

export CLAUDE_CODE_VERSION="garbage"
_supports_terminal_sequence
assert_eq "unparseable version → false" "1" "$?"

unset CLAUDE_CODE_VERSION

echo ""
echo "--- emit_terminal_sequence output ---"

# With known new version → outputs terminalSequence JSON
export CLAUDE_CODE_VERSION="2.1.141"
OUTPUT=$(emit_terminal_sequence "test-seq")
assert_json_field "new CC outputs terminalSequence" "$OUTPUT" ".terminalSequence" "test-seq"
unset CLAUDE_CODE_VERSION

# --- Routing tests ---
# These test the hook scripts as subprocesses to verify routing behavior.
# We override /dev/tty writes since they'd fail in CI.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"

echo ""
echo "=== Routing ==="

echo ""
echo "--- SessionStart routing ---"

# Legacy Warp (TERM_PROGRAM=WarpTerminal, no protocol version)
OUTPUT=$(TERM_PROGRAM=WarpTerminal bash "$HOOK_DIR/on-session-start.sh" < /dev/null 2>/dev/null)
SYS_MSG=$(echo "$OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null)
assert_eq "legacy Warp shows active message" \
    "🔔 Warp plugin active. You'll receive native Warp notifications when tasks complete or input is needed." \
    "$SYS_MSG"

echo ""
echo "--- Modern-only hooks exit silently without protocol version ---"

for HOOK in on-permission-request.sh on-prompt-submit.sh on-post-tool-use.sh; do
    echo '{}' | bash "$HOOK_DIR/$HOOK" 2>/dev/null
    assert_eq "$HOOK exits 0 without protocol version" "0" "$?"
done

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
assert_eq "strips control chars" "evilproj" "$(title_base "{\"cwd\":\"/tmp/evil$(printf '\007\033')proj\"}")"

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
wait "$SPIN_PID" "$SPIN_WATCH" 2>/dev/null || true

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
wait "$SPIN_PID2" "$SPIN_WATCH2" 2>/dev/null || true

echo ""
echo "--- _title_claude_pid ---"

TITLE_PROBE="$TITLE_TEST_DIR/probe.sh"
cat > "$TITLE_PROBE" <<PROBE_EOF
source "$SCRIPT_DIR/title.sh"
_title_claude_pid
PROBE_EOF
ln -sf /bin/bash "$TITLE_TEST_DIR/claude-fake"
TITLE_HOST="$TITLE_TEST_DIR/host.sh"
cat > "$TITLE_HOST" <<HOST_EOF
echo "\$\$"
bash "$TITLE_PROBE"
HOST_EOF
HOST_OUT=$("$TITLE_TEST_DIR/claude-fake" "$TITLE_HOST")
assert_eq "finds claude-named ancestor by comm" "$(echo "$HOST_OUT" | head -1)" "$(echo "$HOST_OUT" | tail -1)"

SHELL_HOST="$TITLE_TEST_DIR/claude-wrapper.sh"
cat > "$SHELL_HOST" <<HOST_EOF
echo "\$\$"
bash "$TITLE_PROBE"
HOST_EOF
OUTER_HOST="$TITLE_TEST_DIR/outer.sh"
cat > "$OUTER_HOST" <<OUTER_EOF
echo "\$\$"
bash "$SHELL_HOST"
OUTER_EOF
TREE_OUT=$("$TITLE_TEST_DIR/claude-fake" "$OUTER_HOST")
TREE_A=$(echo "$TREE_OUT" | sed -n 1p)
TREE_B=$(echo "$TREE_OUT" | sed -n 2p)
TREE_RESULT=$(echo "$TREE_OUT" | sed -n 3p)
assert_eq "skips shell wrapper, selects claude ancestor" "$TREE_A" "$TREE_RESULT"
[ "$TREE_RESULT" = "$TREE_B" ]
assert_eq "shell wrapper itself is not selected" "1" "$?"

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

RACE_INPUT='{"session_id":"title-race-1","cwd":"/tmp/proj"}'
RACE_PIDF=$(_title_pid_file "title-race-1")
export TERM_PROGRAM=WarpTerminal
export WARP_TITLE_TTY="$TITLE_TEST_DIR/race-tty"
title_on_working "$RACE_INPUT"
RACE_PID=$(cat "$RACE_PIDF" 2>/dev/null)
[ -n "$RACE_PID" ]
assert_eq "race spinner published its pid" "0" "$?"
title_on_blocked "$RACE_INPUT"
sleep 0.5
[ -n "$RACE_PID" ] && kill -0 "$RACE_PID" 2>/dev/null
assert_eq "immediate stop kills just-started spinner" "1" "$?"
[ -f "$RACE_PIDF" ]
assert_eq "race leaves no pid file" "1" "$?"
unset WARP_TITLE_TTY
unset TERM_PROGRAM

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

# --- Summary ---

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
