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

## Goal: 100% precision, low token cost, fast

The skill is held to three hard constraints, **in this priority order**:

1. **Precision = 100%**. Every keystroke you send must land where you
   expect. If you can't verify it landed, you can't claim it landed.
2. **Token efficiency**. Avoid full-screen reads. Use daemon-side
   waits, hashes, region reads, and probes instead.
3. **Speed**. Millisecond-scale, not second-scale. Never use bare
   `sleep` — the daemon already provides `wait_for_*` for every wait
   you need.

If a tactic violates (1), drop it even if it would help (2) and (3).

## Multi-agent coordination: cmux Agent Bus

For team-of-agents work (one dispatcher + N workers, agents talking
to each other, pipeline / peer review patterns), use the **cmux Agent
Bus**. See `docs/design/agent-bus.md` for the full spec.

It's a JSON-envelope channel layered on cmux's existing
`notification.create` / `notification.wait` RPCs:

- Each agent gets a stable `agent_id` (auto-assigned by `AgentSession`).
- Agents publish typed messages via `cmux rpc notification.create`
  with `title="agent.bus"` and a JSON body starting with `{"$bus":1,...}`.
- The cmux daemon stores them with `kind="bus"` (no UI alert).
- Dispatchers wait via `cmux rpc notification.wait kind=bus body_contains=...`,
  which is a single blocking RPC that returns when a matching message
  arrives — true push from the client's POV.

Python helpers in `cmux_term.bus`:
- `publish_command(...)` — exact shell command for an agent's Bash tool.
- `AgentBus().wait(from_=..., kind=..., ref=..., timeout_ms=...)` —
  block for one message.
- `AgentBus().wait_any(agents=[...], kind="done")` — first finisher wins.
- `AgentBus().wait_all(agents=[...], kind="done")` — all must finish.

`AgentSession.delegate(prompt, notify="bus")` is the default; the lib
appends the bus protocol prose teaching the agent how to publish.
Token budget per round-trip: ~1 RPC for delegate, ~1 RPC per
delivered bus message, plus the cost of reading any artifacts the
agent wrote to disk. Independent of agent panel scroll length.

```python
from cmux_term import ClaudeAgent, AgentBus, Surface

# 3 parallel workers
parent = Surface.from_focused_or_split().id
fleet = [ClaudeAgent.spawn(parent, cwd=f"/tmp/work/{i}") for i in range(3)]
refs  = [a.delegate(f"task #{i}: ...", notify="bus") for i, a in enumerate(fleet)]

bus = AgentBus()
msgs = bus.wait_all(agents=[a.agent_id for a in fleet],
                    kind="done", timeout_ms=10*60_000)
for m in msgs:
    # artifacts on disk are the source of truth; bus only signals
    print(f"{m.from_} done: {m.summary}; artifacts={m.artifacts}")
```

## Track 1 (PRIMARY): delegate to an Agent CLI

**For non-trivial work, this is almost always the right answer.**

Your role is **dispatcher + acceptor**, NOT executor. The agent does
the work, the agent reviews its own work, the agent notifies you, you
accept the result. Your context window is precious — every token spent
reading sub-agent output during execution is a token you can't spend
dispatching the next task.

Core principles:

1. **Push, not poll.** The agent fires a cmux notification when done;
   you wait on the notification queue. Polling the screen costs tokens
   linearly with task length — push costs O(1).
2. **Sub-agent self-reviews.** Tell the agent to run its own tests,
   verify its output, and only signal done when satisfied. Never use
   your own context to scrape its progress.
3. **Big results go through files.** If the result is more than a
   sentence, have the agent write it to a file and tell you the path.
   Then read the file when (and only when) you need it.
4. **Verify on disk + spot-check, not by re-reading the conversation.**
   When the notification fires, check the artifact (file content, exit
   code, git log). If you must inspect terminal state, use cheap reads
   (`screen_tail(8)`, `last_lines(3)`) — never `screen_text()` mid-run.

```python
from cmux_term import Surface, ClaudeAgent

# Find any surface to split from (e.g. the focused one)
parent = Surface.from_focused_or_split(direction="right")

# Spawn claude in a NEW dedicated panel rooted at /tmp/project.
# Under the hood: surface.split with working_directory=cwd, then we
# inject `claude --dangerously-skip-permissions`. Avoids the
# zsh-keystroke-eating gauntlet on fresh shells.
a = ClaudeAgent.spawn(parent, cwd="/tmp/project")
token = a.delegate(
    "Refactor utils/parser.py to use dataclasses, add tests, "
    "run pytest until green. Don't ask for confirmation.",
    notify="cmux",  # agent fires cmux notification when done — push, not poll
)
# Single push wait — we burn ~0 tokens until the notification arrives.
a.wait_for_done(
    token,
    notify="cmux",
    timeout_ms=10 * 60_000,
    check_disk="/tmp/project/utils/parser.py",
)

# verify on disk via subprocess — never via screen scraping
import subprocess
r = subprocess.run(["pytest"], cwd="/tmp/project", capture_output=True, text=True)
assert r.returncode == 0
```

### Big results — file handoff, not scrollback scraping

When the agent's deliverable is more than a few lines (research notes,
analysis, refactor plan), tell it to dump to a file:

```python
token = a.delegate(
    "Survey every callsite of `LegacyFoo` in this repo and write a "
    "migration plan to ./MIGRATION.md (≥1 paragraph per call site). "
    "When done, signal me.",
    notify="cmux",
)
a.wait_for_done(token, notify="cmux", check_disk="./MIGRATION.md")
plan = open("./MIGRATION.md").read()  # NOW we read — once, not throughout
```

This keeps your context flat regardless of how much the sub-agent
produced.

### Two interaction modes — pick by task shape, not by reflex

**Interactive (default)** — chat back and forth, steer turn by turn.
Each turn: delegate/chat → wait_for_done → check artifact → next turn:

```python
a = ClaudeAgent.spawn(parent, cwd="/tmp/project")
t1 = a.delegate("draft a CLI for csv → json", notify="cmux")
a.wait_for_done(t1, notify="cmux")
t2 = a.chat("good. now add a --pretty flag and a test", notify="cmux")
a.wait_for_done(t2, notify="cmux")
```

Use when:
- Mid-complexity, you want to steer in real time.
- Requirements are fluid; you'll know what to ask for after seeing
  the first draft.
- The agent is likely to ask clarifying questions.

**Goal mode (optional)** — install a long-running objective, walk away:

```python
a.set_goal("Get the test suite to 90%+ coverage, then exit. "
           "Pick the most uncovered modules first.")
a.wait_for_text("Goal complete", timeout_ms=30 * 60_000)
```

Use when:
- The task is heavy and well-specified.
- You want token cost on YOUR side near zero.
- You'd otherwise be sitting there pressing "continue" for an hour.

**You can mix freely.** Goal mode does NOT lock out interaction:
- `a.chat("hint: look at the JSON parser first")` mid-run still steers it.
- `a.update_goal("...")` overwrites the active goal with a new one.
- `a.clear_goal()` drops autonomy and returns to plain chat.

Don't reach for /goal reflexively. Many useful tasks finish in 1-3
turns and benefit from staying interactive.

### When NOT to use this track

- Smoke tests / one-off scripts — too much CLI cold-start overhead.
- Tasks where you genuinely need byte-level control (driving vim,
  navigating fzf, scrubbing through htop). For those, fall to Track 2.

## Track 2 (FALLBACK): drive a TUI directly

Use only when there's no agent that could do this for you. Examples:
- Driving vim/nvim/less/lazygit by keypress.
- Walking through an interactive picker (fzf, gh, k9s).
- Watching a long-running stream (`tail -f`, `docker logs`) for a marker.

This is the verify-each-step world covered by `raw`/`atomic`/`flow`.
The 3-layer guidance below applies only to this track. Default to
**atomic** for unfamiliar TUIs; promote to **raw** only when you're
confident; reach for **flow.batch** when you have a known multi-step
shell chain.

If a Track 2 task is *getting complicated*, that's usually a sign you
should escalate to Track 1: have the agent write a script that does
the work, then run that script.

## Use the Python helper library — pick the right layer

The skill ships with `lib/cmux_term/` (a Python package with three
layers + a batch executor). **Use it.** Choose the layer that matches
your confidence and step granularity — this is how you get both
precision AND token efficiency.

```python
import sys
sys.path.insert(0, "/Users/<you>/Dev/cmux/skills/cmux-terminal-control/lib")
from cmux_term import Surface, raw, atomic, batch
from cmux_term.batch import send_line, send_key, wait_text, wait_idle

s = Surface.from_focused_or_split(direction="right")
s.wait_ready()
```

### Three layers — LLM picks per task

| Layer | Verify | Cost / op | Use when |
|---|---|---|---|
| **L1 `raw.*`** | none | 1 RPC | Confidence ≥ 95%, repetitive ops, you'll add ONE trailing `expect`. |
| **L2 `atomic.*` / `s.press`/`s.type`** | yes, every step | ~3 RPC (hash + send + wait_change) | Confidence < 90%, branchy logic, interactive TUI where wrong state corrupts everything downstream. |
| **L3 `flow.*` / `s.type_line` / `s.vim_edit` / `s.run_script` / `s.run_steps`** | composite | varies (1 RPC for `run_steps`) | Multi-step composites with built-in verify, OR pack N steps into ONE daemon-side RPC. |

### Decision recipe

```
                +--- 95%+ confident, just text into a quiet prompt
                |        → raw.send_text + 1 atomic.expect
                |
  task starts --+--- < 90% confident OR vim/TUI mid-edit
                |        → atomic.press / atomic.type per step
                |
                +--- > 3 high-confidence shell commands in a row
                |        → batch.run_steps([...]) — one RPC, daemon fail-fast
                |
                +--- known multi-line script (no need to read intermediate state)
                |        → s.run_script("""...""")
                |
                +--- vim open-edit-save
                         → s.vim_edit(path, content=...) or substitute=...
```

### Examples

```python
# Layer 1 — fast batch with one trailing checkpoint
raw.send_text(s.id, "echo step1\n")
raw.send_text(s.id, "echo step2\n")
raw.send_text(s.id, "echo step3\n")
atomic.expect(s.id, "step3", timeout_ms=5000)

# Layer 2 — verify each step (interactive TUI)
s.launch("/usr/bin/vi -u NONE file.txt", expect="file.txt")
s.press("i")                      # raises if screen doesn't change
s.expect("INSERT")
s.type("hello world")
s.press("escape")
s.exec_ex(":wq")
s.assert_back_at_shell()

# Layer 3 — composite vim edit (one method, internal verify)
s.vim_edit("hello.txt", content="line one\nline two")
s.vim_edit("hello.txt", substitute=("line one", "line ONE"))

# Layer 3 — batch via surface.expect (one round trip, daemon-side fail-fast)
# IMPORTANT: chain multiple shell commands with `&&` inside ONE step rather
# than many `send_line` steps. Real shells (zsh + syntax-highlighting,
# fish, bash with custom prompts) buffer input across keystrokes and will
# silently concatenate back-to-back send_lines that lack a real prompt
# settle in between. `&&` collapses N commands into one logical line that
# the shell evaluates in one go.
from cmux_term.batch import send_line_steps, wait_text
s.run_steps([
    *send_line_steps(
        "git add . && git -c user.email=a@b -c user.name=t commit -m 'wip' "
        "&& git log --oneline"
    ),
    wait_text("wip", timeout_ms=3000),
])

# Layer 3 — run a multiline script in one shot
s.run_script("""
set -e
mkdir -p /tmp/proj && cd /tmp/proj
echo "hello" > a.txt
git init -q && git add -A && git commit -qm init
""", expect_after="master")

# Agent CLI track — schedule + observe long-running work
s.type_line("claude code 'fix the failing test'")
s.expect("✔ Done", timeout_ms=120000)
```

**Why a layered API instead of forcing verify-every-step**: every
verification round-trip costs ~150 B of tokens and ~50-100 ms of wall
time. For a 50-step shell chain at 95% confidence, verifying every
step is 50 wasted round trips. Pack into one `run_steps` or `raw`
chain + trailing `expect` and you do it in 1-3 RPCs. **The LLM is
responsible for picking the right layer**; the library is responsible
for making each layer trustworthy.

**Banned**: blindly verifying every byte AND blindly batching everything.
Pick deliberately. If you're unsure: when in doubt, drop one layer
deeper (raw → atomic → flow → flow+batch).

The library has been validated end-to-end:
- 65/65 keys verified byte-for-byte (a-z, 0-9, every symbol, shift+,
  ctrl+, alt+, F1-F20, all navigation/escape keys)
- 50/50 composite shell tasks (cd, sed, git, REPL, less, heredoc,
  Unicode, 200-char stress)
- 25/25 real TUI tasks (vim insert/normal/ex, fzf interactive, nvim
  with avante popups + lualine non-standard statusline)
- 1000-op random keystroke barrage leaves the panel responsive
- 5/5 stable runs of the smoke test through `python3 cmux_term.py`

If you find a case where the lib fails, **that is a bug to fix in
the lib, not a reason to drop down to raw RPCs.**

## When to use which RPC (cheat sheet)

**Computer Use track**:

```
1. send_key i               # one keystroke
2. wait_for_kind vim_insert # daemon polls until classifier matches
3. send_text "hello"        # type a word
4. wait_for_cursor row=0 col=5  # assert position
5. send_key escape
6. wait_for_kind vim_normal
7. ...
```

**Agent CLI track**:

```
1. send_text "claude code 'fix the failing test'\n"
2. while not done:
3.    h = screen_hash               # ~100 B; cache it
4.    if h != prev_h:
5.        d = screen_diff since=seq # ~30-200 B
6.        check d.dirty for milestones / errors
7.        if tui_probe.kind == input_prompt:  # CLI asked a question
8.            send_text "y\n"
9.    sleep 1                       # poll cadence is yours, daemon doesn't help
10. wait_for_text "✔ Done"          # final milestone
```

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
