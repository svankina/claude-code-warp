---
description: Fork this Claude Code session into Warp (new window; set WARPFORK_PANE=1 for a split pane)
argument-hint: "[session-id]  (default: current session)"
---

# /warpfork

Forks the current Claude Code session (resumed with `--fork-session`) into Warp.
Default opens a new window; `WARPFORK_PANE=1` splits the current pane (Linux/X11),
and `WARPFORK_MODE=split` uses the native `warp://action/split_pane` deep link on
Warp builds that support it.

Run this and report the output:

```bash
~/.local/bin/warpfork $ARGUMENTS
```
