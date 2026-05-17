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
