# cmux Agent Bus — Design (v2, complexity-minimized)

Status: draft v2
Owner: cmux-terminal-control
Audience: cmux maintainers, herdr maintainers, skill authors

## TL;DR

A multi-agent communication bus for cmux, built **almost entirely on
top of cmux's already-shipped `notification.*` RPCs**. Adds zero new
RPC verbs beyond the one already added (`notification.wait`).
The "schema" is a JSON shape carried in the existing `body` string,
plus a `kind=agent.bus` discriminator so bus messages don't pollute
the user-facing notification badge.

This document describes the contract. Implementation = ~200 lines of
Swift (a body validator + a kind filter on the existing
`v2NotificationCreate` and `v2NotificationWait`) + ~300 lines of
Python wrapper. No new daemon-side state machinery.

## 1. Why not a separate event stream

We considered porting herdr's `events.subscribe` model, which holds a
socket open and streams events until the client disconnects (see
`herdr/src/api/server.rs::stream_subscriptions`). That model has real
benefits — the client never round-trips per event — but it requires:

- A new socket-level streaming mode in `TerminalController.swift`.
- A subscription registry with idle expiry, filter matching, and ring
  buffer per subscription.
- Cursor-dropped recovery semantics.
- An entire parallel notification queue.

cmux already has a notification queue with a blocking single-event
wait (`notification.wait`, body-substring filter, daemon-side block).
Calling it in a loop costs ~1 RPC per delivered event. For agent
coordination — where events arrive seconds-to-minutes apart, not
milliseconds — that overhead is negligible compared to the LLM
calls those events represent. Optimizing it would be premature.

So v1 of the bus is **a JSON convention over `notification.*`**, not
a new subsystem. v2 can promote it to a streaming endpoint if we
ever measure the round trips actually mattering.

## 2. Goals

- **G1.** Agents (sub-agent CLIs running in cmux panels) and the
  dispatcher (the user's main session) all talk over one shared bus.
- **G2.** Push-shaped from the dispatcher's POV: one RPC per event,
  daemon-side block, no client-side polling.
- **G3.** Agents can talk to each other, not just dispatcher ↔ agent.
  Filter by recipient (`to`) makes "team chat" work.
- **G4.** Structured JSON envelope with a closed `kind` enum + open
  `extra` map. Bigger payloads go through file paths in `artifacts`.
- **G5.** No new top-level RPC verbs. Implementation reuses
  `notification.create`, `notification.wait`, `notification.list`,
  `notification.dismiss` already shipped.
- **G6.** Bus messages do NOT spam the user's macOS notification
  bell. We add a `kind` selector at the daemon level so "agent bus"
  messages skip UI delivery.
- **G7.** v1 dispatcher is single-threaded — only one `wait` outstanding
  at a time. Multiple `wait` calls from concurrent processes can
  legitimately race (both consume the same message). Documented here
  rather than fixed in v1; we add a server-side "consume" mark in v2 if
  it bites.

Non-goals:

- Cross-machine bus (cmux is single-host).
- Persistent durable queue (we drop messages on cmux restart on
  purpose; artifacts on disk are the source of truth).
- Agent → dispatcher input delivery via the bus (that goes through
  the panel's stdin via `surface.send_text` — already works).

## 3. Wire schema (JSON body of cmux notification)

The body of every bus notification is **strict JSON** matching this
shape. Anything that doesn't parse cleanly as bus JSON is treated as
a regular user-facing notification (existing behavior).

```jsonc
{
  "$bus":      1,                    // schema version. Required first key.
  "from":      "agent_a1b2c3d4",     // who sent this
  "to":        "*",                  // recipient filter:
                                     //   "*"     → broadcast (any subscriber)
                                     //   "<id>"  → addressed to a specific agent or "dispatcher"
                                     //   ["<id>", "<id>", ...] → multicast
  "kind":      "done",               // closed enum, see §3.1
  "ref":       "tok_xyz",            // optional task token from delegate(); ties messages to a task
  "thread":    "tok_xyz",            // optional grouping id; defaults to ref
  "summary":   "wrote 3 files, tests pass",  // ≤400 chars, human-friendly one-liner
  "artifacts": ["/tmp/p1/foo.py"],   // optional file paths that carry the real content
  "extra":     { ... }               // free-form, ≤2 KiB JSON-encoded
}
```

Validation rules (enforced daemon-side at publish time):

- The body MUST start with the literal bytes `{"$bus":1` so that
  `notification.list` consumers can skip non-bus rows with a single
  `String.hasPrefix` check.
- Total body byte length ≤ **4096**. Reject larger publishes with
  `payload_too_large`. Most "done" envelopes are ~200 B.
- `from` and `kind` are required. `from` must match
  `/^[a-zA-Z0-9_.:-]{1,64}$/`. `kind` must be one of the §3.1 enum
  values.
- `to` defaults to `"*"` if omitted.

On the producer side, agents publish via the cmux CLI. The Python
helper computes the exact shell command:

```bash
cmux rpc notification.create '{"title":"agent.bus","body":"{\"$bus\":1,\"from\":\"a1\",\"kind\":\"done\",\"ref\":\"tok\",\"summary\":\"...\"}"}'
```

The fixed `title="agent.bus"` is what the daemon uses (see §4.1) to
suppress UI delivery.

### 3.1 `kind` enum

| `kind`         | Direction(s)            | Meaning |
|---|---|---|
| `done`         | agent → dispatcher      | Task fully complete, self-verified. |
| `progress`     | agent → dispatcher      | Optional heartbeat. Same `ref`/`thread`. |
| `needs_input`  | agent → dispatcher      | Blocked on a question. Dispatcher must answer (via `chat()` over panel stdin) and the agent will then emit another `progress`/`done`. |
| `error`        | agent → dispatcher      | Fatal failure. `summary` describes; `extra.detail` may have a log path. |
| `log`          | any → any               | Best-effort log. May be ignored. |
| `cancel`       | dispatcher → agent      | Reserved. v1 doesn't enforce delivery — the dispatcher uses panel `send_key("ctrl+c")` to actually interrupt. The bus message is informational. |
| `note`         | any → any               | Free-form message between teammates. Used for agent ↔ agent collaboration. |
| `ack`          | any → any               | Acknowledges a previous message by `ref`. Used to confirm receipt of `note`. |

### 3.2 Bounds

- Max body bytes: **4096** (~JSON-encoded). Larger → `payload_too_large`.
- Bus messages share the existing `TerminalNotificationStore` ring,
  which already caps at the daemon's notification limit. Ring rollover
  is acceptable; consumers that miss messages discover this via
  artifacts on disk.
- Max concurrent `notification.wait` calls: same as the daemon's
  socket connection limit (effectively unlimited; each one is a
  thread blocked in `Thread.sleep`).

## 4. Implementation — Swift

### 4.1 Daemon-side changes — short, surgical

#### 4.1.1 Add a `kind` discriminator to `TerminalNotification`

`Sources/TerminalNotificationStore.swift` defines
`struct TerminalNotification`. Add ONE field with a default:

```swift
enum TerminalNotificationKind: String, Codable {
    case user    // Default. Existing path. Drives macOS notification.
    case bus     // Agent-to-agent message. No UI side effects.
}

struct TerminalNotification: Identifiable, Hashable {
    // ... existing fields ...
    var kind: TerminalNotificationKind = .user
}
```

Default value keeps every existing call site unchanged → backward
compatible. No migration of persisted state needed.

#### 4.1.2 Add `recordBusNotification` short path

```swift
extension TerminalNotificationStore {
    /// Record a bus notification: append to the ring, fan out to
    /// observers, but skip cooldown / policy hooks / UI handlers.
    /// Returns the persisted notification (with id + createdAt).
    @MainActor
    func recordBusNotification(
        body: String,
        title: String = "agent.bus"
    ) -> TerminalNotification {
        let now = Date()
        let n = TerminalNotification(
            id: UUID(),
            tabId: UUID(),               // dummy — bus is workspace-agnostic
            surfaceId: nil,
            panelId: nil,
            title: title,
            subtitle: "",
            body: body,
            createdAt: now,
            isRead: true,                // pre-read so UI doesn't badge
            paneFlash: false,            // no flash
            clickAction: nil,
            kind: .bus
        )
        notifications.append(n)
        // No deliverNotificationSideEffects, no policy hook eval,
        // no cooldown — bus is a pure data channel.
        objectWillChange.send()          // for any SwiftUI observer
        return n
    }
}
```

This is **the entire** ingestion path for bus messages — ~25 lines.
No interaction with `addNotification`'s policy/cooldown/UI engine.

#### 4.1.3 Two-factor bus detection in `v2NotificationCreate`

```swift
private func v2NotificationCreate(params: [String: Any]) -> V2CallResult {
    // ... existing title/subtitle/body parsing ...
    if title == "agent.bus", body.hasPrefix("{\"$bus\":1") {
        if (body.utf8.count) > 4096 {
            return .err(code: "payload_too_large",
                        message: "bus body > 4096 bytes", data: nil)
        }
        guard validateBusEnvelope(body) else {
            return .err(code: "invalid_params",
                        message: "bus body did not parse as a valid envelope",
                        data: nil)
        }
        var stored: TerminalNotification?
        v2MainSync {
            stored = TerminalNotificationStore.shared
                .recordBusNotification(body: body, title: title)
        }
        guard let stored else {
            return .err(code: "internal_error",
                        message: "failed to record bus message", data: nil)
        }
        return .ok([
            "id": stored.id.uuidString,
            "created_at": iso8601String(stored.createdAt),
            "kind": "bus",
        ])
    }
    // ... existing user-notification path unchanged ...
}
```

Two-factor: `title` exact match AND body prefix. The prefix check
costs ~10 ns and removes the "user happens to title their alert
'agent.bus'" collision. Misformatted bus titles fall through to the
user path (caller observes UI alert; that's the loud, noticeable
failure mode we want for misuse).

`validateBusEnvelope(_:)` (≤30 LOC):
- `JSONSerialization.jsonObject(with:)` — must succeed.
- top-level must be a dict.
- must contain `"$bus"` set to integer `1`.
- must contain `"from"` (string ≤64 chars, `[A-Za-z0-9_.:-]+`).
- must contain `"kind"` ∈ `done / progress / needs_input / error / log / cancel / note / ack`.

#### 4.1.4 List + wait honor the new `kind` field

`v2NotificationList` filters to `kind == .user` by default. New
optional param `include_bus: bool` (default false) opts in:

```swift
private func v2NotificationList(_ params: [String: Any] = [:]) -> [String: Any] {
    let includeBus = (params["include_bus"] as? Bool) ?? false
    var items: [[String: Any]] = []
    v2MainSync {
        items = TerminalNotificationStore.shared.notifications
            .filter { includeBus || $0.kind == .user }
            .map { notificationPayload($0, opened: nil, includeReadState: true) }
    }
    return ["notifications": items]
}
```

`v2NotificationWait` accepts a new optional `kind` filter
(`"user"` / `"bus"` / unset = both). When filtering for bus
messages, the daemon scans `notifications` looking for entries with
`kind == .bus` AND optional body/title substring match. Bus is the
overwhelmingly common case for the new `wait` calls, so the daemon's
inner loop short-circuits quickly even on a busy notification ring.

#### 4.1.5 `notificationPayload` includes `kind`

Existing `notificationPayload(...)` adds one line:
`"kind": notification.kind.rawValue`. Pure addition; old clients
ignore unknown keys.

### 4.2 Diff size

Net Swift LOC added/changed (estimated):

| File | LOC |
|---|---|
| `Sources/TerminalNotificationStore.swift` | +30 (kind field, recordBusNotification) |
| `Sources/TerminalController.swift`        | +60 (validate, dispatch, list/wait kind filter) |
| Total | ~90 |

No new files. No changes to socket/dispatch infrastructure.

### 4.2 Daemon-side `notification.wait` filters (already shipped)

`notification.wait` already supports `body_contains` + `title_contains`
+ `since_iso` + `timeout_ms` (added earlier in this branch). To
filter cheaply by bus fields, the client passes a `body_contains`
that targets a JSON substring it knows will be present in matching
messages, e.g.:

- `'"from":"agent_a1"'` → match messages from a specific agent.
- `'"to":"dispatcher"'` → match messages addressed to dispatcher.
- `'"kind":"done"'` → match completion messages.
- `'"ref":"tok_xyz"'` → match messages tied to a specific task.

Multiple filters AND-combine: pass `body_contains` with the most
selective key, then re-check the others client-side after parsing.

This means the existing `notification.wait` is sufficient for v1 of
the bus. The daemon code is unchanged beyond the publish-side filter
in §4.1.

### 4.3 No new RPC verbs

Existing surface that the bus uses:

- `notification.create` — publish (with `title="agent.bus"` ⇒ bus mode)
- `notification.wait` — block until matching message arrives
- `notification.list` — debug dump / drain
- `notification.dismiss` — clean up after consuming

No new methods. No new schemas at the RPC level. No new socket modes.

## 5. Implementation — Python

`skills/cmux-terminal-control/lib/cmux_term/bus.py` becomes a thin
helper that:

1. **Producers (`publish_command`)**: assemble the bus envelope, JSON-
   encode, escape for shell, return the full
   `cmux rpc notification.create '...'` command string. Agents run
   this from their Bash tool; we never touch their PTY directly.

2. **Consumers (`AgentBus`)**:
   - `wait(*, from_=..., to=..., kind=..., ref=..., timeout_ms=...)`:
     calls `notification.wait` with the most selective `body_contains`,
     parses, re-validates the other filters, dismisses on match.
     Returns an `AgentBusMessage`.
   - `wait_any(filters_list, timeout_ms)`: like wait, but on the most
     general filter; client-side selects the first match in any of
     the per-filter lists. Used for "first agent to finish wins".
   - `wait_all(filters_list, timeout_ms)`: loop wait_any until each
     filter has matched once.
   - `drain()`: non-blocking dump via `notification.list`,
     parse-filter-keep, dismiss kept ones.

API shape:

```python
from cmux_term.bus import AgentBus, BusFilter, publish_command

# producer (agent side, called from agent's Bash tool)
cmd = publish_command(
    from_="agent_a1", to="dispatcher", kind="done",
    ref="tok_xyz", summary="wrote 3 files, tests pass",
    artifacts=["/tmp/p1/foo.py"],
)
# → cmux rpc notification.create '{"title":"agent.bus","body":"..."}'

# consumer (dispatcher)
bus = AgentBus()
msg = bus.wait(from_="agent_a1", kind="done", timeout_ms=600_000)
print(msg.summary, msg.artifacts)

# multi-agent
msg = bus.wait_any(
    [BusFilter(from_="agent_a1", kind="done"),
     BusFilter(from_="agent_a2", kind="done"),
     BusFilter(from_="agent_a3", kind="done")],
    timeout_ms=600_000,
)
print(f"first done: {msg.from_}")
```

## 6. Team-of-agents patterns

The bus enables team-style coordination beyond dispatcher-fanout:

### 6.1 Worker pool with a coordinator

```
Coordinator (dispatcher)
   ├─ delegate to Worker A: parse logs → /tmp/findings_a.json
   ├─ delegate to Worker B: parse logs → /tmp/findings_b.json
   └─ delegate to Worker C: parse logs → /tmp/findings_c.json
                  ↓ (each publishes "done" with artifact path)
   Coordinator wait_all → reads 3 artifact files → synthesis
```

### 6.2 Pipeline (A → B → C)

A finishes, publishes `done` with `to=B`. B's prompt subscribes:
"wait until you receive a `note` from `A` with kind=done and `ref` X,
then start". B does its work, publishes `done` with `to=C`. Etc.
The bus naturally handles the handoff because messages survive in the
ring until consumed.

### 6.3 Peer review

Two Claude agents working on the same file:
- A writes the implementation, publishes `note kind=ack ref=X` to B
  with the file path.
- B reads, runs tests, publishes `note kind=ack ref=X` back to A with
  feedback.
- A iterates.

Dispatcher only watches for the final `done` from either.

### 6.4 Mention / address book

Because `to` accepts a list, you can address a subset of the team:

```jsonc
{ "$bus":1, "from":"reviewer", "to":["coder_a","coder_b"],
  "kind":"note", "summary":"both of you should rebase" }
```

## 7. Failure modes

| Failure | Behavior |
|---|---|
| Agent crashes silently | `wait()` times out at the user-set deadline. Dispatcher reads the agent's panel tail (cheap RPC) to diagnose. |
| Agent publishes `error` | `wait()` returns it. Dispatcher reads `summary`/`extra.detail`. May ask for retry via `chat()`. |
| Agent publishes `needs_input` | `wait(kind="needs_input")` returns it. Dispatcher answers via `chat()` (panel stdin). |
| Daemon restart | Bus messages lost. Dispatcher's next `wait` returns nothing within timeout. Dispatcher checks artifacts on disk; re-issues lost tasks. Documented as a known limitation. |
| Ring rollover (rare; would need 2K+ bus messages) | Older messages dropped. Dispatcher already accepts artifacts as truth, so missed messages don't change correctness. |
| Two agents publish the same `ref` | Both messages stored. `wait(ref=X)` returns the first one; second is matched by a subsequent `wait` if the dispatcher cares. |
| Body too large | `payload_too_large` at publish. Agent's prompt MUST tell it to use `artifacts` for big content. We enforce via the 4 KiB cap. |
| Body isn't valid bus JSON | Daemon-side validation rejects it with `invalid_params`. Agents that misformat see this as a `cmux rpc` error and can retry. |

## 8. Migration plan

Each step independently shippable.

1. **M0 (this commit).** Document this design (this file).
2. **M1.** Daemon-side: add `bodyParsesAsBusEnvelope` + the
   "agent.bus title bypasses UI" path in `v2NotificationCreate`.
   Add the 4 KiB cap. ~50 LOC change in `TerminalController.swift` +
   `TerminalNotificationStore.swift`. **Backward compatible**:
   existing `notification.create` callers without `title="agent.bus"`
   are unaffected.
3. **M2.** Python `cmux_term/bus.py`: replace the in-progress draft
   with the §5 final shape. Wire `AgentSession.delegate(notify="bus")`
   as default for ClaudeAgent / CodexAgent. Keep the existing
   `notify="cmux"` fallback for old daemons.
4. **M3.** Update `agent_demo.py` + `agent_demo_full.py` to use the
   bus.
5. **M4.** Add `multi_agent_demo.py`: 3 parallel Claude workers
   producing artifacts + a coordinator that runs `wait_all`. Headline
   end-to-end test.
6. **M5.** herdr-side: mirror the same JSON envelope under herdr's
   own notification surface (or a thin `agent.bus.publish` wrapper).
   Cross-daemon dispatcher works because the wire format is identical.

## 9. Acceptance criteria

The feature is "done" when:

- [ ] M2 ships and `agent_demo.py` runs end-to-end with `notify="bus"`.
- [ ] `multi_agent_demo.py`: 3 concurrent Claude agents → coordinator
      receives 3 `done` messages → coordinator reads 3 artifact files
      → synthesizes a single result. Total dispatcher-side RPCs ≤
      `4 + N_messages` (one per delegate, one per wait).
- [ ] No regression on user-facing `notification.create` (existing
      tests pass; the macOS notification badge does NOT light up for
      bus messages).
- [ ] Round-trip `needs_input`: agent posts question via
      `kind="needs_input"`; dispatcher receives via `wait(kind="needs_input")`,
      answers via `chat()`, agent receives reply via stdin (existing
      mechanism), publishes `done`. Dispatcher's full loop touches the
      bus only for the `needs_input` and `done` events.
- [ ] Total Swift diff in M1 ≤ 200 lines net. No new files in
      `Sources/` beyond what `agent-bus.md` already calls out (a
      possible new helper file for `bodyParsesAsBusEnvelope`).

## 10. Why this is the right scope

The previous draft of this design proposed a parallel `AgentBusStore`
with its own ring, subscriptions, idle expiry timer, dropped-cursor
recovery, and 6 new RPC verbs. That is **what herdr does** — for
good reason there: herdr serves dozens of streaming UI events
(layout / pane focus / agent status) per second, and the persistent-
connection streaming model amortizes the framing cost.

cmux's agent bus traffic is fundamentally different:

- 1-10 messages per task, not 10 per second.
- Tasks last seconds to minutes.
- Each message represents an LLM turn worth $0.05+, so RPC overhead
  is rounding error.

Building a streaming subscription system would burn ~1500 lines of
Swift, introduce its own bugs, and deliver no observable improvement.
Reusing `notification.*` ships a working bus today with ~50 lines of
Swift and the new RPCs we already merged.

If profiling later shows `notification.wait` round trips actually
costing real wall time, we promote this to a streaming endpoint then.
YAGNI applies until measured.
