# Contract: Test, Trace, and Dashboard Surface

What halted runs and skipped steps look like to tests, operators, and telemetry.

## RSpec matchers

```ruby
expect(result).to be_halted                       # clean halt
expect(result).to be_halted.because(:period)      # with reason
expect(result).to be_halted.at_step(:second)      # with halting step

expect(result).to be_skipped.at_step(:maybe_sync) # ONE step was skipped
expect(result).to be_success                      # a run with skipped steps is still a success
```

- `be_halted` is the previous `be_skipped` verbatim — same `.because` /
  `.at_step` chains — asserting `halted?`.
- `be_skipped` is repurposed: it asserts a step was skipped, reading the result
  or the execution trace. A halted run does **not** satisfy `be_skipped`.
- Every existing clean-halt test migrates by renaming the matcher. Nothing else
  in those tests changes (SC-001).

## Test subject / async reconstruction

`RubyReactor::RSpec::TestSubject` maps the persisted status to a result object:

| Status | Reconstructed result |
|---|---|
| `"completed"` | `Success` of the return step's value |
| `"failed"` | the stored `Failure` |
| `"paused"` | `InterruptResult` |
| `"halted"` | `Halt` rebuilt from the last `type: :halt` trace entry (reason + step) |
| `"skipped"` *(legacy)* | same as `"halted"` |

Skipped steps need no reconstruction — their values are in
`intermediate_results` like any success.

## Execution trace

```ruby
run.context.execution_trace
# => [{ type: :run,     step: :first,      ... },
#     { type: :skipped, step: :maybe_sync, reason: "already synced", ... },
#     { type: :run,     step: :notify,     ... }]
```

Halted runs end with `{ type: :halt, step:, reason: }`.

Rollback entries carry a `skipped:` flag saying whether the logic existed:

```ruby
{ type: :compensate, step: :charge, skipped: false, result: :refunded, ... }
{ type: :compensate, step: :log,    skipped: true,  result: nil, ... }
```

## Dashboard / storage statuses

Accepted status values: `pending`, `running`, `paused`, `completed`, `failed`,
`halted`, plus legacy `skipped` on read (shown as halted).

A run containing skipped steps is `completed`, not `halted` — the two are
distinguishable at a glance, and per-step skips are visible in the trace.

## OpenTelemetry attributes

| Span | Attribute | Value |
|---|---|---|
| reactor | `reactor.status` | `"halted"` (was `"skipped"`) |
| reactor | `reactor.halt_reason` | halt reason |
| step | `step.status` | `"halted"` or `"skipped"` |
| step | `step.halt_reason` / `step.skipped_reason` | corresponding reason |
| compensation | `compensation.status` | `"skipped"` when no compensation was defined |
| undo | `undo.status` | `"skipped"` when no undo was defined |

The compensation and undo branches already exist and already read `skipped?`;
they become accurate rather than dead once the defaults return `Skipped`.

## Dashboard (`gui/`)

Run-level surfaces:

| Surface | After this change |
|---|---|
| Status badge | `halted` badge, visually distinct from `completed` and `failed` |
| Status filters (live view, per-class list) | `Halted` option |
| Run detail header | `halted` status colour |
| Per-class aggregates | halted runs count as clean outcomes, not errors |

Step-level surfaces:

| Surface | After this change |
|---|---|
| DAG node | a skipped step renders in its own state, never as `completed` — derived from the `skipped` trace entry, not from the presence of a result value |
| DAG node | the halting step renders as `halted`; steps never reached stay `pending`, not `cancelled` (nothing was rolled back) |
| Step inspector — rollback list | three states: compensation/undo that ran, that was never written, and that has not been reached |

The shipped bundle under `lib/ruby_reactor/web/public/` is build output of
`gui/`. Rebuild with `rake build:ui` and commit it, or a released gem serves the
old vocabulary.
