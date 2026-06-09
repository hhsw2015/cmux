---
name: cmux-terminal-control
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

## Token Budget (read first)

Each `surface.screen_text` returns the full visible grid (~2 KB for an
80×24 panel). Naive polling burns context fast. **Push waiting into the
daemon, read full screen only when you must.**

**Banned patterns** (do not write):

- `screen_text` in a `while` loop comparing to expected substring.
  Use `wait_for_text` — daemon polls internally, returns one bool.
- `screen_text` followed by `sleep` followed by `screen_text`.
  Use `wait_for_idle` — daemon settles for you.
- `screen_text` *just to check* if the screen changed.
  Use `surface.screen_hash` — returns 32-byte digest + seq, ~50 byte response.
- Reading the full grid when you only care about the last line
  (shell prompt, vim status bar, less footer).
  Use `surface.screen_region` with `last_rows`.

**Recommended pattern**:

1. Send input → `wait_for_text` (or `wait_for_idle`) — never `sleep`.
2. Cache previous `screen_hash`. On each tick, ask for the hash; if
   unchanged, do nothing. Only fetch full text when hash differs.
3. Read full `screen_text` only at decision points or for final
   verification, not every iteration.
4. For multi-step scripted flows, use `surface.expect` (one RPC,
   N steps inside the daemon) instead of N round trips.

**Rule of thumb**: an automated TUI session should average
≤ 200 bytes of RPC response per agent step. If you are reading a full
screen grid every step, the loop is wrong.

## Generic TUI Categories

Every interactive terminal program falls into one of these shapes; pick
the right primitive accordingly:

| Shape | Examples | Wait primitive | Read primitive |
|---|---|---|---|
| **Line-based REPL / shell** | bash, zsh, python, ipython, psql | `wait_for_text` on prompt regex (`\$ $` / `>>> `) | `screen_region {last_rows: 5}` |
| **Full-screen modal** | vim, less, man, k9s | `wait_for_text` on status-line marker (`-- INSERT --`, `(END)`) | `screen_region {last_rows: 1}` for status, `screen_text` for body |
| **Menu / picker** | fzf, lazygit, gh, htop | `wait_for_idle` after arrow keys | `screen_text` once, `screen_hash` between keystrokes |
| **Input prompt / confirmation** | sudo, ssh password, `(y/n)` | `wait_for_text` on the literal prompt string | none — send and `wait_for_idle` |
| **Long-running stream** | docker logs, kubectl logs, tail -f | `wait_for_text` on a known marker line | `screen_region {last_rows: 10}` |

When unsure: probe with `surface.screen_region {last_rows: 3}` first.
A single line tells you 80% of the time which category you are in.

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

| You want | Use | Typical bytes |
|---|---|---|
| Current visible viewport text (alternate-screen TUI) | `surface.screen_text` | ~2 KB |
| Just the bottom N rows (prompt / status line) | `surface.screen_region {last_rows: N}` | ~80 B/row |
| Just changed rows since last seq | `surface.screen_diff {since_seq}` | 30-200 B |
| Did the screen change since last poll? | `surface.screen_hash` | ~100 B |
| What kind of TUI is this? (shell / vim / less / menu / prompt) | `surface.tui_probe` | ~150 B |
| Wait until a string appears on screen | `surface.wait_for_text` | ~50 B |
| Wait until output settles (no new bytes for `settle_ms`) | `surface.wait_for_idle` | ~50 B |
| Run a multi-step send/wait flow in one round trip | `surface.expect` | ~200 B (final only) |

> Do **not** treat scrollback as the visible state of an alternate-screen
> TUI. `surface.screen_text` reads the libghostty grid directly — that is
> the one source of truth for "what the user sees right now".

### Long-Running Loops: Use `screen_diff`, Not `screen_text`

For agents that read streamed output (LLM completion, `tail -f`,
`docker logs`), call `screen_diff` with the previous `state_seq` each
tick:

```bash
SEQ=0
while ! done; do
  RESP=$(cmux rpc surface.screen_diff "{\"surface_id\":\"$SURF\",\"since_seq\":$SEQ}")
  SEQ=$(echo "$RESP" | jq -r .state_seq)
  if [ "$(echo "$RESP" | jq -r .changed)" = "true" ]; then
    if [ "$(echo "$RESP" | jq -r .full)" = "true" ]; then
      echo "$RESP" | jq -r .text       # full reload (alt-screen toggle)
    else
      echo "$RESP" | jq -r '.dirty[] | "\(.y): \(.text)"'   # only changed rows
    fi
  fi
done
```

A 1000-iteration polling loop on an idle pane costs ~30 KB total with
`screen_diff` vs ~2 MB with `screen_text`. Same precision (you see every
character that hits the screen), 60x cheaper.

### Routing Decisions: Use `tui_probe`, Not `screen_text` Parsing

If your agent needs to know "am I at a shell prompt yet?" or "is vim in
insert mode?", call `tui_probe` and switch on the `kind` field:

```bash
KIND=$(cmux rpc surface.tui_probe "{\"surface_id\":\"$SURF\"}" | jq -r .kind)
case "$KIND" in
  shell_prompt)    cmux rpc surface.send_text "..." ;;
  vim_normal)      cmux rpc surface.send_key "{...,\"key\":\"i\"}" ;;
  vim_insert)      cmux rpc surface.send_text "..." ;;
  less_pager)      cmux rpc surface.send_key "{...,\"key\":\"q\"}" ;;
  input_prompt)    cmux rpc surface.send_text "y\n" ;;
  running_command) cmux rpc surface.wait_for_idle "..." ;;
  unknown)         cmux rpc surface.screen_text "..." ;;  # fallback
esac
```

Possible `kind` values: `shell_prompt`, `repl_prompt`, `vim_normal`,
`vim_insert`, `vim_visual`, `vim_replace`, `vim_command`, `less_pager`,
`input_prompt`, `running_command`, `unknown`. The classifier is
heuristic; always have a fallback for `unknown`.

### Multi-Step Flows: Use `surface.expect`, Not Loops

```bash
cmux rpc surface.expect "$(jq -nc \
  --arg sid "$SURF" \
  '{
    surface_id: $sid,
    steps: [
      {send: "ls\n"},
      {wait_text: "$ ", timeout_ms: 3000},
      {send: "cd /tmp\n"},
      {wait_text: "$ ", timeout_ms: 3000}
    ],
    stop_on_error: true,
    tail_rows: 5
  }')"
```

Returns `{completed, total, steps[], tail, error?}`. Four steps in one
RPC instead of four RPCs + four waits. Saves ~70% over the naive
loop, and the daemon never returns until the whole sequence finishes
(or one step fails with `stop_on_error: true`).

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
