# Session Persistence — Regression Baseline

Snapshot of cmux's pre-integration metrics. Each Phase 1+ landing must keep
deviations within the bounds below or block release.

## Test counts

| Package | Tests | Notes |
|---------|-------|-------|
| cmuxTests (app) | varies | Run via `xcodebuild -scheme cmux-unit` |
| CMUXZmx pkg | 55 | After Phase 0.3 |

## Performance budgets

Allowed regression vs current `main`:

| Metric | Baseline | Max regression |
|--------|----------|----------------|
| panel create latency | ~50 ms | +2.5 ms |
| panel close latency  | ~30 ms | +1.5 ms |
| split create | ~80 ms | +4 ms |
| Cold launch to ready window | ~800 ms | +40 ms |
| Steady-state main-thread frame | <16 ms (60 fps) | unchanged |
| Idle memory (3 panels) | ~150 MB | +7.5 MB |
| 30s timer CPU | <0.5% | unchanged |

## Regression watch list

These cmux behaviors must remain identical when `engine = none`:

- `Cmd+W` closes panel + kills child
- `Cmd+D` / `Cmd+Shift+D` opens new shell
- Workspace JSON written on quit, read on launch
- Agent restore (Claude/Codex/Cursor) works as before
- Tab/split UI: bonsplit drag/drop, divider drag, close button
- Right sidebar modes (Files/Find/Vault/Sessions/Feed/Dock)
- Browser panel
- SSH workspace creation
- IME composition (Pinyin/Bopomofo/Zhuyin)
- Find overlay
- Notifications

## How to validate

```bash
# Build + unit tests (mac runner)
gh workflow run "Build app" --repo manaflow-ai/cmux
gh workflow run "CI" --repo manaflow-ai/cmux

# Local CMUXZmx package
cd Packages/CMUXZmx && swift test

# E2E with real zmx (local)
brew install zmx
CMUX_E2E_REQUIRE_ZMX=1 swift test --filter E2EBackend

# Manual smoke (engine = none)
# 1. Settings > Session Persistence > Engine: None
# 2. Quit cmux
# 3. Reopen — workspace state must match exactly
# 4. Run baseline scenarios from "Regression watch list"
```

## Performance probe template

When a phase changes a hot path, record:

```
Phase: <number> <title>
Date: YYYY-MM-DD
Build: <git sha>

panel create:        N ms (Δ vs baseline)
panel close:         N ms (Δ vs baseline)
split create:        N ms (Δ vs baseline)
launch:              N ms (Δ vs baseline)
idle main-thread:    N ms (Δ vs baseline)
idle memory:         N MB (Δ vs baseline)
```

## Phase ledger

| Phase | Date | Tests | Perf delta | Notes |
|-------|------|-------|------------|-------|
| 0.1 feature flags | 2026-05-17 | +6 | unchanged | flag reads only |
| 0.2 backend protocol | 2026-05-17 | +13 | unchanged | new files only |
| 0.3 E2E framework | 2026-05-17 | +3 | unchanged | skip-on-missing |
| 0.4 baseline | 2026-05-17 | — | — | this doc |
| 0.5 debug logging | 2026-05-17 | 0 | unchanged | DEBUG-only wrappers |
| 1.1 tsm api discovery | 2026-05-17 | 0 | unchanged | docs only |
| 1.2 tsm cli wrappers | 2026-05-17 | +18 | unchanged | new files |
| 1.3 TsmBackend | 2026-05-17 | +13 | unchanged | new files |
| 2.1 close audit | 2026-05-17 | 0 | unchanged | docs |
| 2.2 chokepoint plumbing | 2026-05-17 | +1 | unchanged | dispatcher returns false |
| 2.3 keepAlive + bg store | 2026-05-17 | +5 | unchanged | dispatcher gated on flag |
| 3 background sidebar | 2026-05-17 | 0 | unchanged | view-only file |
| 4 project manifest | 2026-05-17 | +6 | unchanged | new files |
| 5 polling event source | 2026-05-17 | +2 | unchanged | new files |
| 6 branch switcher | 2026-05-17 | +4 | unchanged | new files |
| 7 agent merge reducer | 2026-05-17 | +6 | unchanged | new files |
| 8 exit banner view | 2026-05-17 | 0 | unchanged | view-only file |
| 9 validation | 2026-05-17 | +4 | unchanged | E2E + this row |

Final pkg test count: 108/108.

## Acceptance check (engine = none)

Manual smoke (run before merging):
- [ ] cmux launches with `engine` unset; no Background section in sidebar.
- [ ] Cmd+W closes panel + kills child (matches pre-integration).
- [ ] Quit + relaunch restores workspace state identically.
- [ ] No new files left on disk under `~/Library/Application Support/cmux/`
      besides what the user already had.
- [ ] No new env vars set on PTY children.

## Acceptance check (engine = zmx, default flags)

- [ ] `tsm` not installed: cmux still launches; resolver returns
      `ZmxBackend()`.
- [ ] User runs `zmx attach foo` in a panel: badge appears within 3s.
- [ ] Close cmux + reopen: panel re-attaches automatically.
- [ ] Engine flag flipped off mid-run: badges drop, no further sweeps.

## Acceptance check (engine = tsm, dogfood)

- [ ] tsm binary present: resolver returns `TsmBackend`,
      `activeDeepBackend()` non-nil.
- [ ] Project save → quit → open: panels recreate at recorded layout.
- [ ] Branch switch: detach → switch → attach completes <2s without
      orphaning sessions.
- [ ] tsm uninstalled mid-run: every active feature degrades to no-op.

## Rollout plan

DEBUG builds: every flag default-on for internal dogfood.
RELEASE builds: every flag default-off; surface engine selector in
Settings; flip individual flags on after at least one week of dogfood.
