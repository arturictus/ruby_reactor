# Phase 1 Data Model: Reactor Signal Semantics

Entities here are in-memory result objects plus the durable records they
produce. No database schema, no migration.

---

## Signal objects

All four are returned from a step body (or thrown by a helper) and consumed by
the executor.

### `RubyReactor::Success`

| Field | Type | Notes |
|---|---|---|
| `value` | any | flows to dependants via `result(:step)` |

Predicates: `success? → true`, `failure? → false`, `skipped? → false`,
`halted? → false` *(new)*.

Unchanged except for the added `halted?` predicate.

### `RubyReactor::Halt < Success` *(renamed from today's `Skipped`)*

| Field | Type | Notes |
|---|---|---|
| `value` | nil | always nil — a halt carries no result |
| `reason` | Symbol / String / nil | e.g. `:period`, `:ordered_lock_stale_batch`, or an author's string |
| `period_key` | String / nil | set by the period gate only |
| `step_name` | Symbol / nil | stamped by the result handler if the step did not set it |

Predicates: `success? → true` (inherited), `halted? → true`,
**no `skipped?` method** — a missed migration site raises `NoMethodError`
rather than silently reading `false`.

Construction: `RubyReactor.Halt(reason: …)`, `Halt(reason: …)` inside a
reactor/step, or `halt!(reason: …)`.

### `RubyReactor::Skipped < Success` *(new meaning)*

| Field | Type | Notes |
|---|---|---|
| `value` | any | **behaves exactly like `Success#value`** — this is FR-008 |
| `reason` | Symbol / String / nil | optional, recorded in the trace only |
| `step_name` | Symbol / nil | stamped by the result handler |

Predicates: `success? → true`, `skipped? → true`, `halted? → false`.

Construction: `RubyReactor.Skipped(value)`, `Skipped(value)`, `skip!(value)`.

**Validation rule**: a call whose sole argument is the keyword `reason:` raises
`ArgumentError` naming `Halt` (FR-006 / R6).

### `RubyReactor::Failure`

Unchanged fields. One addition:

| Field | Type | Notes |
|---|---|---|
| `retryable` | Boolean | now settable as `retry:` as well as `retryable:`; `retry:` wins when both given. Default resolution order: `opts[:retry]` → `retryable:` → `error.retryable?` → `true` |

Predicates unchanged, plus `halted? → false`.

---

## Signal → executor behaviour matrix

The authoritative table for every dispatch site. Rows are the four signals;
"attempts" is how many times the retry machinery may invoke the step.

| Signal | Reactor continues? | Value visible to dependants | Enrolled for rollback | Triggers compensation of prior steps | May be retried | Run status |
|---|---|---|---|---|---|---|
| `Success` | yes | yes | yes (undo stack) | no | no | `:completed` at end |
| `Skipped` | **yes** | **yes** | **no** | no | no | `:completed` at end |
| `Halt` | no — stops now | n/a | n/a | **no** | no | `:halted` |
| `Failure` | no | n/a | n/a | yes | yes, unless `retry: false` or step budget exhausted | `:failed` |

---

## Run status (`context.status`)

| Value | Meaning | Change |
|---|---|---|
| `:pending` | not started | unchanged |
| `:running` | in flight / handed to a worker | unchanged |
| `:paused` | interrupted | unchanged |
| `:completed` | reached the end — including runs containing skipped steps | unchanged |
| `:failed` | a step failed | unchanged |
| `:halted` | a step or gate halted cleanly | **new** |
| `:skipped` | *legacy* — written by pre-upgrade versions to mean halted | **read-only**: accepted on read and translated to halted; never written |

Whitelists to update: `storage/redis_adapter.rb:235`, `web/api.rb:150`,
`map/sweeper.rb:95`.

**Transitions**: `pending → running → {completed | failed | halted | paused}`.
A skipped step causes no status transition of its own.

---

## Execution trace entries

Appended to `context.execution_trace`, serialized with the context
(`context.rb:118`), and read back by the async result reconstruction
(`rspec/test_subject.rb:282`).

| Event | Entry | Change |
|---|---|---|
| Step ran | `{ type: :run, step:, timestamp:, arguments: }` | unchanged |
| Clean halt | `{ type: :halt, step:, reason:, timestamp: }` | **renamed** from `type: :skipped` |
| Step skipped | `{ type: :skipped, step:, reason:, timestamp: }` | **new meaning** — one step, run continues |
| Compensation | `{ type: :compensate, step:, result:, arguments:, timestamp:, skipped: }` | `skipped:` flag added |
| Undo | `{ type: :undo, step:, result:, arguments:, timestamp:, skipped: }` | `skipped:` flag added |
| Undo failure | `{ type: :undo_failure, step:, error:, timestamp: }` | unchanged |

Trace entries carry the *reason*, never the skipped value — values already live
in `context.intermediate_results`.

---

## Undo stack

`{ step:, arguments:, result: }` entries, unchanged in shape.

**Rule change**: a `Skipped` step is **not** pushed (FR-010). `Success` steps
are pushed as today. Consequence: rollback after a later failure walks past
skipped steps entirely.

---

## Serialization

`ContextSerializer.serialize_value` (`context_serializer.rb:38-56`) currently
maps any `Success` to `{"_type" => "Success"}`. `Halt` and `Skipped` need their
own `_type` arms **before** the `Success` arm, so undo-stack entries and map
element results round-trip with their identity intact rather than degrading to
plain `Success`.

| `_type` | Fields |
|---|---|
| `"Success"` | `value` |
| `"Skipped"` | `value`, `reason` |
| `"Halt"` | `reason`, `period_key`, `step_name` |
| `"Failure"` | unchanged (already includes `retryable`) |

---

## Telemetry attributes

`open_telemetry.rb` — halt sites (`:505`, `:581`) switch from `result.skipped?`
to `result.halted?` and emit `reactor.status`/`step.status` = `"halted"` with
`*_halt_reason`. A step that is skipped emits `step.status = "skipped"`. The
compensation and undo sites (`:603`, `:624`) already branch on `skipped?` and
become *accurate* once the defaults return `Skipped` — no edit needed.

---

## Dashboard step-node state (`gui/`)

The DAG's per-step node state is derived in `DagVisualizer.tsx`, not returned by
the API. Derivation order after this change (first match wins):

| Node state | Derived from |
|---|---|
| `failed` | `context.failure_reason.step_name === step` |
| `halted` | trace entry `{ type: 'halt', step }` |
| `skipped` | trace entry `{ type: 'skipped', step }` |
| `completed` | a value exists in `intermediate_results[step]` |
| `running` | in the trace, no value yet, run status `running` |
| `cancelled` | still `pending` while the run is `failed`/`cancelled` |
| `pending` | none of the above — includes steps never reached on a halted run, which are **not** cancelled because nothing was rolled back |

The `halted`/`skipped` checks must run **after** the value check, since a
skipped step has a value and would otherwise be painted `completed`.

Node presentation to add in `StepNode` (`statusColors` + `StatusIcon`) and
`GroupNode` (`statusBorderColors`):

| State | Treatment |
|---|---|
| `skipped` | distinct from completed — muted/sky with a skip icon |
| `halted` | distinct from both completed and cancelled — the stop is clean |

## Dashboard rollback-list state (`StepInspector.tsx`)

| State | Derived from | Meaning |
|---|---|---|
| `executed` | `:compensate` / `:undo` trace entry with `skipped: false` | logic ran |
| `not_implemented` | same entry with `skipped: true` | no logic was defined |
| `pending` | step in the undo stack with no trace entry | rollback not reached |

`not_implemented` is new. Without it, every never-written compensation reports
as executed once the defaults return `Skipped`.

## Dashboard run-status vocabulary

| Surface | Change |
|---|---|
| `StatusBadge.tsx` | add `halted`; retain a `skipped` entry for per-step display |
| `ReactorDetail.tsx` | status colour keyed on `halted` |
| `LiveView.tsx`, `ReactorClassInstances.tsx` | filter option `halted` / "Halted" |
| `lib/reactors.ts` | `halted` counts in the success bucket (as `skipped` does today) |
