# cmux team plan.json — schema reference

LLMs emit a `plan.json` that describes a multi-agent task DAG. The
runtime (`python -m cmux_term.team_runner run plan.json`) handles
everything else: validation, top-tab/panel allocation, DAG scheduling,
inter-task wiring, durable state, resume after a crash.

## Top-level shape

```jsonc
{
  "version": 1,                          // required, must be 1
  "name": "csv-pipeline",                // shown as the team's tab-group title
  "workspace": "/abs/path",              // cwd for every task. required
  "max_concurrency": 4,                  // 1..8; default 3. Cap on simultaneous panels.
  "layout": "auto",                      // auto | main-vertical | main-horizontal
                                         //      | even-horizontal | even-vertical | tiled
  "main_fraction": 0.6,                  // 0.2..0.8 — main panel size for main-* layouts
  "spill_prompt_threshold_bytes": 4000,  // prompts > N bytes auto-spill to a context file
  "on_failure": "abort",                 // abort | isolate | continue
  "timeout_ms": 600000,                  // whole-plan budget; default 10 min
  "tasks": [ ... ]
}
```

## Task shape

```jsonc
{
  "id": "scrape",                        // ^[A-Za-z0-9_.:-]{1,32}$, unique
  "prompt": "Convert ...",               // what the agent should do.
                                         // may include $inputs.<id>.outputs[<n>]
                                         // tokens — they substitute the predecessor's
                                         // declared output paths at spawn time.
  "needs": [],                           // DAG predecessors by id
  "peers": [],                           // informational — sibling task ids that
                                         // share scope. Not enforced as deps.
  "role": "worker",                      // worker | main | coordinator | lead
                                         // (layout hint; see Roles below)
  "agent": "claude",                     // claude | codex | aider
  "outputs": ["/abs/out.json"],          // paths predecessors can reference via
                                         // $inputs.<this_id>.outputs[<n>]. They
                                         // are checked on done — missing => task
                                         // is marked failed.
  "expect_artifacts": [],                // additional files the team runner asserts
                                         // exist after the run. Same effect as outputs
                                         // but not visible to descendants via $inputs.
  "close_on_done": "always",             // always | never | auto
  "context_file": null,                  // null or absolute path. If set, agent
                                         // is told to Read this file for context.
  "panel_direction": "auto",             // auto | right | down — split direction hint
  "timeout_ms": 600000,                  // per-task budget
  "extra_env": {}                        // optional env overrides (str -> str)
}
```

## Roles

`role` is a lightweight hint to the layout engine. Business meaning
goes in `prompt`; this only affects panel placement.

| role          | Layout effect (when `layout: auto`)                       |
| ------------- | --------------------------------------------------------- |
| `worker`      | regular split panel. Default.                             |
| `main`        | gets the larger pane in main-vertical/main-horizontal.    |
| `coordinator` | spawned in its own dedicated top tab; does not split.     |
| `lead`        | promoted to main slot when the team picks main-* layout.  |

There is **no privileged channel** between roles — every task talks
to the runtime via the same agent bus. If `coordinator` needs to
direct other tasks dynamically, it does so by inspecting state and
emitting messages, not by virtue of its role string.

## DAG semantics

- A task is **ready** when all of its `needs` are `done`.
- A task with no `needs` is a source.
- The runner enforces topological order; `max_concurrency` caps the
  number of tasks that can be in `running` at once.
- `$inputs.X.outputs[N]` substitution requires `X` to be in `needs`.
  The runtime fails validation if it isn't.

## Failure handling

| `on_failure` | Behaviour when task `T` fails                                |
| ------------ | ------------------------------------------------------------ |
| `abort`      | Cancel every still-running task; mark pending as `cancelled`.|
| `isolate`    | Mark `T`'s transitive descendants as `skipped`. Other branches keep going. |
| `continue`   | Log the failure; keep scheduling everything. Diagnostic only.|

## Durable state

Every state transition is persisted to
`<workspace>/.cmux-team/<plan-name>/state.json`. Use the runner CLI:

```bash
python -m cmux_term.team_runner status plan.json   # show progress
python -m cmux_term.team_runner run plan.json      # run (or resume)
python -m cmux_term.team_runner run plan.json --no-resume   # discard prior state
python -m cmux_term.team_runner run plan.json --no-retry    # don't re-run prior failures
python -m cmux_term.team_runner reset plan.json    # archive state.json
python -m cmux_term.team_runner cancel plan.json   # mark running -> cancelled (best-effort)
python -m cmux_term.team_runner schema             # print this doc
```

### Resume semantics

On `run`:

1. `plan.json` is parsed and validated.
2. A canonical hash of the structural fields (workspace, on_failure,
   tasks[*].{id,prompt,needs,outputs,inputs,role,panel_direction,
   close_on_done,context_file,timeout_ms,extra_env}) is computed.
3. If `state.json` exists with the same hash:
   - Tasks already in `done` are kept (artifacts pass to descendants
     via `$inputs`); they do NOT re-run.
   - Tasks left in `running` (a prior process died mid-flight) are
     reset to `pending` and re-attempted.
   - Tasks in `failed` / `cancelled` are reset to `pending` by default
     (override with `--no-retry`).
4. If `state.json` exists with a DIFFERENT hash, it is archived under
   `state.<hash>.<ts>.json` and a fresh state begins. Cosmetic plan
   changes (renaming, layout, max_concurrency) do NOT trigger this.

### Task statuses

```
pending → running → done
                  → failed
                  → cancelled
       → skipped         (set when an ancestor failed under on_failure=isolate)
```

`status` is reported by `team_runner status` and by every emitted
event line during a run.
