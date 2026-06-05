#!/bin/bash
# Discovers the slash commands available to this Claude Code session and prints
# them as a JSON array of {name, description?, argument_hint?} objects on stdout.
#
# This feeds the protocol-v2 `commands` field of warp://cli-agent session_start
# notifications so Warp can surface the agent's own slash commands in its
# rich-input autocomplete (Claude Code does not expose its resolved command
# registry to hooks, so we reconstruct it from the same sources Claude reads).
#
# Sources, in increasing precedence (later wins on name collision):
#   1. Curated built-ins (shipped with Claude Code, no file on disk)
#   2. Enabled plugins' command dirs (~/.claude/plugins/.../commands)
#   3. Project commands (<cwd>/.claude/commands)
#   4. User commands (~/.claude/commands)
#
# Usage: discover-commands.sh [cwd]   (cwd defaults to $PWD)
#
# Requires jq. Prints "[]" if jq is missing or nothing is found.

set -uo pipefail

CWD="${1:-$PWD}"

if ! command -v jq &>/dev/null; then
    echo "[]"
    exit 0
fi

# --- Curated built-in commands ----------------------------------------------
# Claude Code's built-ins aren't files, so we maintain a conservative list of
# stable, broadly useful ones. Names are exactly what Claude Code recognizes.
BUILTINS='[
  {"name":"add-dir","description":"Add a new working directory","argument_hint":"[path]"},
  {"name":"agents","description":"Manage agent configurations"},
  {"name":"clear","description":"Clear conversation history and free up context"},
  {"name":"compact","description":"Compact the conversation to save context","argument_hint":"[instructions]"},
  {"name":"config","description":"Open the config panel"},
  {"name":"context","description":"Visualize current context usage"},
  {"name":"cost","description":"Show the total cost and duration of the session"},
  {"name":"doctor","description":"Diagnose and verify your Claude Code installation"},
  {"name":"exit","description":"Exit the REPL"},
  {"name":"export","description":"Export the current conversation to a file or clipboard"},
  {"name":"help","description":"Show help and available commands"},
  {"name":"hooks","description":"Manage hook configurations"},
  {"name":"init","description":"Initialize a CLAUDE.md with codebase documentation"},
  {"name":"mcp","description":"Manage MCP servers"},
  {"name":"memory","description":"Edit Claude memory files"},
  {"name":"model","description":"Set the AI model for Claude Code","argument_hint":"[model]"},
  {"name":"output-style","description":"Set the output style"},
  {"name":"permissions","description":"Manage allow/deny tool permissions"},
  {"name":"pr-comments","description":"Get comments from a GitHub pull request"},
  {"name":"release-notes","description":"View release notes"},
  {"name":"resume","description":"Resume a previous conversation"},
  {"name":"review","description":"Review a pull request","argument_hint":"[pr]"},
  {"name":"rewind","description":"Rewind the conversation and/or code"},
  {"name":"status","description":"Show version, account, and connectivity status"},
  {"name":"usage","description":"Show plan usage limits"},
  {"name":"vim","description":"Toggle vim editing mode"}
]'

# --- Frontmatter helpers -----------------------------------------------------
# Extract a scalar field from a markdown file's YAML frontmatter (the block
# between the first two `---` lines). Strips surrounding quotes. Empty if absent.
frontmatter_field() {
    local file="$1" field="$2"
    awk -v field="$field" '
        NR == 1 && $0 ~ /^---[[:space:]]*$/ { infm = 1; next }
        infm && $0 ~ /^---[[:space:]]*$/ { exit }
        infm {
            # Match "field:" at the start of the line.
            if ($0 ~ "^" field "[[:space:]]*:") {
                sub("^" field "[[:space:]]*:[[:space:]]*", "")
                # Strip matching surrounding single or double quotes.
                gsub(/^"|"$/, ""); gsub(/^'"'"'|'"'"'$/, "")
                print
                exit
            }
        }
    ' "$file"
}

# Emit one compact JSON object per `*.md` file in a commands directory.
# $1 = directory, $2 = name prefix (e.g. a plugin namespace, or "").
emit_command_dir() {
    local dir="$1" prefix="$2"
    [ -d "$dir" ] || return 0
    local file rel name desc hint
    while IFS= read -r -d '' file; do
        rel="${file#"$dir"/}"
        rel="${rel%.md}"
        # Subdirectories become `:`-separated namespaces (Claude Code convention).
        name="${prefix}${rel//\//:}"
        desc="$(frontmatter_field "$file" "description")"
        hint="$(frontmatter_field "$file" "argument-hint")"
        jq -nc --arg name "$name" --arg desc "$desc" --arg hint "$hint" '
            {name: $name}
            + (if $desc != "" then {description: $desc} else {} end)
            + (if $hint != "" then {argument_hint: $hint} else {} end)
        '
    done < <(find -L "$dir" -type f -name '*.md' -print0 2>/dev/null)
}

# --- Collect from all sources (low precedence first) -------------------------
{
    echo "$BUILTINS" | jq -c '.[]'

    # Enabled plugins' command dirs.
    PLUGINS_JSON="$HOME/.claude/plugins/installed_plugins.json"
    if [ -f "$PLUGINS_JSON" ]; then
        while IFS= read -r install_path; do
            [ -n "$install_path" ] && emit_command_dir "$install_path/commands" ""
        done < <(jq -r '
            .plugins // {} | to_entries[] | .value[]? | .installPath // empty
        ' "$PLUGINS_JSON" 2>/dev/null)
    fi

    # Project-scoped commands.
    emit_command_dir "$CWD/.claude/commands" ""

    # User-scoped commands.
    emit_command_dir "$HOME/.claude/commands" ""
} | jq -s '
    # Later entries win on name collision; emit a stable, sorted array.
    reduce .[] as $c ({}; .[$c.name] = $c) | [.[]] | sort_by(.name)
'
