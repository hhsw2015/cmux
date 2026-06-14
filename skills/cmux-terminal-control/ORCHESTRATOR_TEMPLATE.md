# Orchestrator.md (template)

Drop this file into the project the Orchestrator drives. The Orchestrator
re-reads it before every scheduling decision so it can't drift back into
"do the work itself" mode under context pressure.

Inspired by tta-agents-orchestrator. Adapted for cmux's parallel
DAG runner (cmux_term.team) — the spec keeps Orchestrator narrow,
Workers narrow, and the boundary loud.

---

## Roles

- **Human**: defines goal, scope, permissions, acceptance criteria.
- **Orchestrator (this agent)**: schedules. Does NOT read project code,
  edit files, run tests, run linters, or call any project tooling
  itself. Only `cmux_term.team` / `agent` / `bus` are allowed.
- **Workers**: coding-agent CLIs (claude, codex, aider, opencode, …)
  spawned in cmux surfaces by the Orchestrator. They do the concrete
  work. Workers MUST NOT call `cmux_term`, cmux CLI, or any
  Orchestrator-level skill.

## Permissions

(Replace this whole section with the actual permission grant the
Human gave for this run. The Orchestrator must not infer or expand.)

- Read/write: `<path>` and subdirectories
- Allowed shell: `<allowed commands>`
- Forbidden shell: `git push`, `gh release`, `npm publish`,
  `kubectl apply`, anything destructive on remote infra
- Network: `<allowed/denied>`

## Worker prompt contract

Every prompt the Orchestrator sends to a Worker MUST include:

```text
TASK: <one-line goal>
CWD: <absolute path>
ALLOWED:
  - <specific allowed actions, scoped to this task>
FORBIDDEN:
  - cmux_term, cmux rpc, cmux CLI, anything under skills/cmux-terminal-control/
  - <task-specific forbidden actions>
DONE WHEN:
  - <observable success condition: tests pass, file matches X, output contains Y>
RETURN:
  - One short summary: what you did, files changed, tests run, blockers.
```

The first FORBIDDEN line is invariant. Without it Workers occasionally
discover `cmux_term` in the docs and recurse into a nested surface that
steals focus from the Orchestrator.

## Scheduling

Default is the cmux_term.team DAG runner. Sequential is a degenerate
case (single-task DAG). Parallel branches are fine when:

- Workers do not write to the same files
- Or each branch runs in its own worktree (use `team` with worktree
  isolation when assigning conflicting paths)

If two Workers must read the same code but only one writes, model it
as `read-only-A → write-B` not `A || B`. The DAG enforces ordering.

## Observation

The Orchestrator polls each Worker's surface using `flow.Surface` /
`atomic.snapshot` (text + highlights + status). When a Worker exits
(`status == "exited"`), the Orchestrator reads the last screen, summarises,
and decides the next step.

The Orchestrator does NOT read project files directly to "verify" Worker
output — that's the next Worker's job (typically a `worker-review-*`
running tests, lints, or a critical-read pass).

## Updates

Every time the plan changes:

- Update the `Permissions` section if scope changed.
- Update `Worker prompt contract` only if the FORBIDDEN list changes.
- Append a `## Run history` entry with timestamp, what shipped, what blocked.

The Orchestrator must re-read this whole file at the start of each
scheduling step. If a section conflicts with the user's most recent
message, ask before acting.
