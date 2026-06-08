---
name: terminal-control
description: >
  Drive and observe terminal applications (TUIs / REPLs / interactive CLIs)
  inside cmux panels using the cmux socket RPCs (`surface.screen_text`,
  `surface.wait_for_text`, `surface.wait_for_idle`, `surface.send_text`,
  `surface.send_key`, `surface.split`, `workspace.create`).
  Use when an agent must operate or verify a TUI such as vim/nvim, lazygit,
  htop, k9s, fzf, ranger, claude-code, codex, or any shell-based interactive
  workflow inside a real cmux panel.
  Triggers: "control vim", "drive a TUI", "automate terminal", "operate in
  panel", "agent control terminal", "cmux 自动化", "cmux 控制终端".
---

# cmux Terminal Control

Use the **cmux socket RPCs** to observe the actual visible terminal state
of a panel and drive interaction deterministically. Self-contained — no
`termctrl` binary required. Equivalent RPCs exist on the herdr fork
(`pane.screen_text` / `pane.wait_for_text` / `pane.wait_for_idle`); use
those when targeting a remote/headless herdr daemon instead of a local
cmux app.

## Prerequisites

- cmux app running (the one that owns the local panels you want to drive).
- `cmux` CLI on PATH (`/Applications/cmux.app/Contents/Resources/bin/cmux`,
  symlinked when you install the app).
- All examples below use shell `$SURF` for the target surface UUID.

## The Smallest Workflow

For a one-shot "spawn a process in a fresh panel, wait until it settles,
read the screen, then close":

```bash
# 1. Open a workspace + first surface in /tmp/work
RESP=$(cmux rpc workspace.create '{"name":"work","cwd":"/tmp/work"}')
SURF=$(echo "$RESP" | jq -r .surface_id)

# 2. Run the program, wait until output stops, read the screen.
cmux rpc surface.send_text "{\"surface_id\":\"$SURF\",\"text\":\"my-terminal-app\\n\"}"
cmux rpc surface.wait_for_idle "{\"surface_id\":\"$SURF\",\"settle_ms\":400,\"deadline_ms\":5000}"
cmux rpc surface.screen_text "{\"surface_id\":\"$SURF\"}"

# 3. Done. The panel stays open for the user; close it manually if needed.
```

For interactive/repeated inspection (drive a long-lived TUI):

```bash
SURF=...           # existing surface UUID
cmux rpc surface.send_text "{\"surface_id\":\"$SURF\",\"text\":\"my-app\\n\"}"
cmux rpc surface.wait_for_text "{\"surface_id\":\"$SURF\",\"substring\":\"Ready\",\"timeout_ms\":5000}"
cmux rpc surface.screen_text "{\"surface_id\":\"$SURF\"}"
cmux rpc surface.send_text "{\"surface_id\":\"$SURF\",\"text\":\"help\\n\"}"
cmux rpc surface.wait_for_text "{\"surface_id\":\"$SURF\",\"substring\":\"Commands\",\"timeout_ms\":5000}"
cmux rpc surface.screen_text "{\"surface_id\":\"$SURF\"}"
```

## Choose The Correct Observation

| You want | Use |
|---|---|
| Current visible viewport text (alternate-screen TUI) | `surface.screen_text` |
| Wait until a string appears on screen | `surface.wait_for_text` |
| Wait until output settles (no new bytes for `settle_ms`) | `surface.wait_for_idle` |

> Do **not** treat scrollback as the visible state of an alternate-screen
> TUI. `surface.screen_text` reads the libghostty grid directly — that is
> the one source of truth for "what the user sees right now".

## Drive Input Precisely

`surface.send_text` writes raw bytes to the PTY. `surface.send_key` sends
a single named key (`enter`, `escape`, `ctrl+c`, `tab`, `up`, `down`, …).

```bash
# plain text + Enter
cmux rpc surface.send_text "{\"surface_id\":\"$SURF\",\"text\":\"/connect\\n\"}"

# arrow + enter
cmux rpc surface.send_key "{\"surface_id\":\"$SURF\",\"key\":\"down\"}"
cmux rpc surface.send_key "{\"surface_id\":\"$SURF\",\"key\":\"enter\"}"

# Ctrl-C
cmux rpc surface.send_key "{\"surface_id\":\"$SURF\",\"key\":\"ctrl+c\"}"
```

JSON literal escapes inside `send_text` payload work as you expect:
`\n` for newline, `` for Escape (used to leave vim insert mode),
`	` for Tab, `` for Ctrl-C, etc.

> **Always `wait_for_text` or `wait_for_idle` after sending input.**
> Do not `sleep`. The whole point of these RPCs is to replace timing
> guesses with state-driven waits.

## The Vim/Nvim Pattern

Vim is the canonical "easy to break, hard to drive blindly" TUI. The
sequence below works reliably:

```bash
SURF=...
# 1. Launch vi from a clean shell prompt
cmux rpc surface.send_text "{\"surface_id\":\"$SURF\",\"text\":\"vi /tmp/work/hello.txt\\n\"}"

# 2. Wait until vi has finished drawing (status line shows the file name)
cmux rpc surface.wait_for_text "{\"surface_id\":\"$SURF\",\"substring\":\"hello.txt\",\"timeout_ms\":5000}"
cmux rpc surface.wait_for_idle "{\"surface_id\":\"$SURF\",\"settle_ms\":400,\"deadline_ms\":3000}"

# 3. Atomic edit: i (insert) + content + ESC + :wq + Enter, single send
cmux rpc surface.send_text "{\"surface_id\":\"$SURF\",\"text\":\"ihello from cmux agent\\nline 2\\nline 3\\u001b:wq\\n\"}"

# 4. Wait for the shell prompt to return
cmux rpc surface.wait_for_idle "{\"surface_id\":\"$SURF\",\"settle_ms\":400,\"deadline_ms\":3000}"

# 5. Verify
cat /tmp/work/hello.txt
```

Why send the whole `i…:wq\n` block as one `send_text`: vi's
mode-switch happens **inside** the buffered input, so a single byte
stream lets vi see the bytes in the same order regardless of round-trip
delay between RPC calls. Splitting `i` and the body across two RPCs
introduces races where keystrokes can be misclassified.

### Vim swap-file gotcha

If a previous session left a swap file behind, vi opens with a recovery
prompt instead of normal mode, and your `i` will be interpreted as
"answer ([O]/E/R/D/Q/A)". Always inspect:

```bash
cmux rpc surface.screen_text "{\"surface_id\":\"$SURF\"}"
```

after launching vi. If you see `swap file ... already exists`, send
`D` (delete) or `R` (recover) before continuing — never assume vi is in
normal mode.

## Open A New Panel For The Task

Two options:

```bash
# Split the focused panel rightwards (keeps the user's existing layout)
RESP=$(cmux rpc surface.split '{"direction":"right"}')
SURF=$(echo "$RESP" | jq -r .surface_id)

# Or open a fresh workspace with its own working directory
RESP=$(cmux rpc workspace.create '{"name":"task","cwd":"/path/to/cwd"}')
SURF=$(echo "$RESP" | jq -r .surface_id)
```

Use a **dedicated panel** for agent-driven work so any errant keystrokes
do not stomp on the user's terminal. A workspace gives you an isolated
shell with a clean cwd; a split keeps you in the user's workspace but in
a separate PTY.

## Targeting

All four observation/input RPCs accept `surface_id` (UUID) or
`workspace_id` to target a panel; if omitted, the focused surface is
used. Always pass `surface_id` for agent automation — focus may change
out from under you.

```json
{"surface_id": "C8F9268C-239F-4D07-8AB2-02C81AE322F3"}
{"workspace_id": "F7A5194F-F0F6-47D3-987E-D3EAE91D84DC"}
```

## Recover From Problems

| Symptom | Action |
|---|---|
| `surface.send_text` returns `queued: true` then later the input never appears | The panel's PTY is not running yet. `wait_for_idle` first, then re-send. |
| Screen shows shell prompt instead of the program you launched | The launch command was eaten by a stuck program. Send `ctrl+c` (or `q` for some pagers), then `clear\n`, then re-launch. |
| `wait_for_text` times out | Inspect with `surface.screen_text` to see what the panel actually shows; the substring may have wrapped or the program may be stuck on a confirmation prompt. |
| Vim writes content into the wrong buffer | Swap-file recovery prompt — see the swap-file gotcha above. |
| `cmux rpc` hangs | Verify the cmux app is running; `cmux workspace list` should respond instantly. |

## Why This Beats Hooks Alone

Agent-CLI hooks (Claude Code's `PreToolUse`, Codex events) only fire
for events the upstream chose to expose. They cannot observe:

- Token-by-token streaming output (e.g. an LLM's mid-response thinking)
- TUI status bars, progress bars, modal dialogs
- Programs without any hook surface (vim, lazygit, htop, custom CLIs)

`surface.screen_text` works for **all** of those — it reads what the
user sees, not what the program was nice enough to broadcast.

## Independence From herdr / termctrl

These cmux RPCs are self-contained: cmux owns the local ghostty PTY and
reads its grid directly via `ghostty_surface_render_grid_json`. The
herdr fork has the same-shape RPCs (`pane.screen_text` etc.) implemented
independently against libghostty-vt; use those when controlling a remote
herdr daemon. **Never** depend on the `termctrl` binary — it would
require its own PTY and is not the path cmux/herdr use.
