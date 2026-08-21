# Data Model: Background Execution & Real Async Steps

This is a library feature — "entities" are DSL/runtime constructs and the storage records backing them, not application data.

## Background Hand-off Point

Reactor-class-level declaration, one per reactor.

| Field | Type | Notes |
|---|---|---|
| `mode` | Symbol — `:after` or `:before` | Which side of the cut point the declaration named. Derived from which keyword the author supplied. |
| `step` | Symbol | The named step. For `:after`, the last step to run in the calling process; for `:before`, the first step to run in the worker. Must reference a step defined in the same reactor (validated at class-definition time, FR-002). |

Exposed to the runtime, `TestSubject`, and the dashboard as a single normalized reader — `background_handoff → { mode:, step: }` — never as a one-sided `background_after`. One concept with two trigger positions, not two parallel features: every consumer branches on `mode`, so no consumer can be accidentally implemented for `after:` only.

**Storage**: not persisted as its own record — it compiles into which step reaching which position triggers the `StepExecutor#handle_async_step`-style enqueue. Enforced-single via a class-level guard.

**Validation rules** (all definition-time errors):
- Exactly zero or one `background` declaration per reactor class (FR-002).
- Exactly one of `after:`/`before:` per declaration — both or neither raises (FR-002).
- The named step must exist in `steps` at the time `background` is evaluated, or at class-definition-close time if steps can be declared afterward (implementation detail for tasks phase).
- `background` combined with whole-reactor `async true` is rejected — the hand-off point would be silently meaningless inside a reactor that already runs entirely in a worker (spec Edge Cases).
- `returns` naming an `async_step` or `async_reactor` is rejected — the return value must come from a same-process step (spec Edge Cases).

## Async Step

A step declared with `async_step :name` (or `async_step :name, ImplClass`) instead of `step`.

| Field | Type | Notes |
|---|---|---|
| `name` | Symbol | Step name, same namespace as regular steps. |
| `arguments` / `run_block` / `impl` | (existing `StepConfig` fields) | Same shape as a regular step — `async_step` is a `StepConfig` with a dispatch-mode marker, not a new config type. |
| dispatch-mode marker | Boolean/Symbol | Distinguishes "run inline" vs "dispatch as an independent unit" at `StepExecutor#execute_step` time. |

**Lifecycle** (state machine, tracked via the new Step Result Record below, keyed by `(context_id, step_name)`):

```
dispatched -> running -> completed(Success)
                       -> completed(Failure)
```

- `dispatched`: parent process has, synchronously and in this order (durable-write-before-enqueue, F2): (1) written the Step Result Record with status `dispatched` and the `composed_contexts[step_name] = { type: :async_step_ref, name:, dispatched_at: }` reference onto its own context (see Async Step ↔ context linkage below), (2) enqueued the `StepWorker` job, (3) marked the step graph-complete for scheduling purposes (siblings may now proceed). No result exists yet.
- `running`/`completed`: opaque to the parent process except through the Step Result Record; the parent only observes "record carries a terminal value" or "record still `dispatched`" (still-pending — keep waiting, subject to FR-005's timeout). A record *absent* entirely means the step was never dispatched — `result()` does not wait in that case. The parent may reach its own terminal state while a record is still `dispatched`; that is the fire-and-forget contract (FR-018), and the parent's status makes no claim about the unit's outcome.

**Relationships**: An `async_step` is a dependency-graph node like any other step — other steps that declare `argument :x, result(:async_step_name)` get an automatic DAG edge (existing `DependencyGraph#add_step` behavior, unchanged) and, per FR-005, enter the notified wait for the terminal record when they resolve that argument.

**Async Step ↔ context linkage (FR-008, FR-014)**: the *reference* (not the result) lives in `context.composed_contexts[step_name]`, the same field `compose`/`map` already populate for their own children — see research.md decision 8. The dashboard's existing `hydrate_composed_contexts` pipeline (`lib/ruby_reactor/web/api.rb`) is extended with a branch for `type: :async_step_ref` that resolves the Step Result Record to show current status/result, mirroring how it already resolves `:map_ref`.

## Async Reactor

A step declared with `async_reactor :name, ChildReactorClass`.

| Field | Type | Notes |
|---|---|---|
| `name` | Symbol | Step name in the parent. |
| `child_reactor_class` | Class | Must be a `RubyReactor::Reactor` subclass. |
| `argument_mappings` | Hash | Same shape as `compose`'s `argument_mappings` — maps parent-visible sources to the child's inputs. |

**Dispatch-time behavior** (FR-015, FR-016 — 2026-08-20 session):
- Dispatch reuses the full pre-enqueue sequence of a top-level async run (child input validation → ordered-lock nonce assignment where the child declares one → persist child context → enqueue), never raw `perform_async` — see research.md decision 3. A validation failure fails the dispatching step itself (normal parent saga handling), distinct from child-execution failure (FR-009).
- Deadlock guard: the child's `lock_config[:key_proc]` (and `semaphore_config` with `limit: 1`) is resolved against the mapped child inputs; a key matching one the dispatching execution currently holds fails the dispatch step immediately with an error naming the key and both reactor classes (research.md decision 9). No lock-owner sharing across the async boundary — reentrancy stays `compose`-only.

**Relationships**:
- Linked to the parent via `context.composed_contexts[step_name] = { type: :async_reactor_ref, name:, execution_id:, reactor_class_name:, dispatched_at: }` — written synchronously by the dispatching step, same field and pattern `compose`/`map` already use (research.md decision 8). Unlike `async_step`, no separate Step Result Record is needed for the *outcome*: the child is a normal, independently addressable `Reactor` with its own context row, so its terminal result is reached via the existing `storage.retrieve_context(execution_id, reactor_class_name)` / `ChildReactorClass.find(execution_id)` — the same lookup any other reactor execution uses.
- **Not** added to the parent's compensation graph — no `compensate`/`undo` block is registered for this step (see spec Clarifications: compensation is opt-in via a later step reading the result, never automatic).
- FR-008/FR-014: this `composed_contexts` entry is what the web dashboard's `hydrate_composed_contexts` reads to render the reference and drill into the child's own step structure (`build_structure` recursion, same as `compose`/`map`'s `nested_structure`).

## Step Result Record (new storage-level entity)

The durable record backing `async_step` completion. (`async_reactor` needs no equivalent record — per the relationship above, its outcome is simply its own context row, reached by execution id through the existing `retrieve_context`/`find` path.) This avoids what would otherwise be a race-prone write into the parent's context blob from a worker running concurrently with the still-executing parent process.

| Field | Type | Notes |
|---|---|---|
| `context_id` | String (UUID) | The **parent** reactor's context id — the bucket is scoped per parent execution. |
| `step_name` | Symbol/String | The `async_step`'s name within that parent. |
| `status` | Enum: `dispatched`, `completed` | `dispatched` written synchronously **before** the job is enqueued (same checkpoint-before-enqueue ordering the existing hand-off uses, F2) — so a crash after enqueue can never find a job with no record, and this record doubles as the **re-attach marker** (FR-017): on recovery/resume the dispatch path finds a record in any status and skips enqueue entirely, marking the node graph-complete as the original dispatch did, rather than duplicating the side effect. The `async_reactor` equivalent is the `:async_reactor_ref` entry in `composed_contexts` (research.md decision 10). `completed` written by the step's own worker. |
| `serialized_result` | String (via `ContextSerializer.serialize_value`) | The step's `Success`/`Failure` value, same serialization the existing map-result bucket uses. |
| `reactor_class_name` | String | Needed for storage-key namespacing, mirrors every other storage primitive's `reactor_class_name` parameter. |

**Storage interface additions** (`RubyReactor::Storage::Adapter`, implemented by `RedisAdapter`):

```ruby
store_step_result(context_id, step_name, serialized_result, reactor_class_name)
retrieve_step_result(context_id, step_name, reactor_class_name)
```

Modeled directly on the existing `store_map_result(map_id, index, serialized_result, reactor_class_name, strict_ordering:)` / `retrieve_map_results(...)` pair (`lib/ruby_reactor/storage/adapter.rb:14-20`) — same TTL policy as `context_ttl` (records must not outlive the parent context's own retention window).

**Retention across a fire-and-forget parent (FR-018)**: the worker loads the *parent* context by id, so the parent must outlive the dispatched unit — including the common case where the parent completes immediately and nothing ever waits on the unit. Dispatch therefore refreshes the parent context's TTL, and the record is stamped with the same window. A worker that still finds no parent context (swept, or beyond the window) writes a `completed`/`Failure` record for its unit and logs it per FR-012 rather than raising — an unhandled raise would only hand the job to the backend's retry machinery to fail identically N more times. See research.md decision 10.

## Completion Signal (new, ephemeral — not a stored entity)

The wake-up channel for FR-005's notified wait (research.md decision 4). Pure latency optimization: at-most-once, unpersisted, never load-bearing — every path falls back to the durable record above (or the child's context row).

| Channel | Published by | When |
|---|---|---|
| `rr:done:<parent_context_id>:<step_name>` | the `async_step`'s StepWorker | after `store_step_result` write |
| `rr:done:<child_execution_id>` | the `async_reactor` child's executor | after its terminal context save (unconditional — no-subscriber publish is near-free) |

Uses the existing, currently-unused `Storage::Adapter#publish`/`#subscribe` primitives (`adapter.rb:38-44`, implemented at `redis_adapter.rb:177-183`). Ordering contract: durable write **before** publish; waiter subscribes **before** its first record check; waiter re-checks the record on a coarse fallback interval. The subscriber MUST use a dedicated Redis connection (`SUBSCRIBE` puts a connection into subscriber mode — blocking the shared client would poison all other storage calls).

## Configuration additions

| Knob | Default | Notes |
|---|---|---|
| `Configuration#async_wait_timeout` | `30` (seconds) | Seconds a `result()` notified wait will block before failing the referencing step with a timeout. Single global value — no per-reactor/per-reference override (Clarifications, Question 3). Rationale for 30s in research.md decision 5. |

**Derived (not configurable)**: the notified wait's fallback re-check interval is `async_wait_timeout / 10`, clamped to `1..5` seconds (3s at the default). It is a latency backstop for a lost signal, not a tuning surface — the clamp guarantees ≥10 re-checks inside any bound, so a dropped notification costs at most ~10% of the timeout. See research.md decision 4.

## State/behavior changes to existing entities

- **`StepConfig`** (`lib/ruby_reactor/dsl/step_builder.rb`): the `async`/`async?` accessor is removed; using `async true` inside a `step` block raises a definition-time error naming the replacement DSL (FR-003). `ComposeBuilder#async` (`dsl/compose_builder.rb:31-33`) is **removed too** — it sets the very `StepConfig` `async:` flag being deleted (`compose_builder.rb:62`), so it cannot survive the removal; it raises the same definition-time error (migration: `background before: :<that compose step>`, which reproduces the old flag's semantics exactly). `MapBuilder#async` (`dsl/map_builder.rb:43`) is genuinely unaffected: it is a map-internal element-dispatch mode passed as a step *argument*, and the map's own `StepConfig` is hardcoded `async: false` (`map_builder.rb:111`) — it never touched the removed flag. (An earlier pass of this document had the compose/map carve-outs backwards; corrected after verifying both builders.)
- **`DependencyGraph`**: no schema change; `complete_step` is now called for an `async_step` at dispatch time rather than at true completion — a deliberate, documented divergence from every other step type, captured here so it isn't mistaken for a bug during implementation review.
- **Reactor-class DSL** (`lib/ruby_reactor/dsl/reactor.rb`): three new class macros — `background(after: nil, before: nil)`, `async_step(name, impl = nil, &block)`, `async_reactor(name, child_reactor_class, &block)` — alongside the existing `step`, `compose`, `map`, `interrupt`. The existing reactor-level `async`/`async?` (whole-reactor async) is unchanged.
- **`Context#composed_contexts`**: gains two new `type:` tags in its value union — `:async_step_ref` and `:async_reactor_ref` — alongside the existing `:composed` and `:map_ref`. No schema/serialization change (it's already a generic `Hash`, already serialized/deserialized as-is); this is purely a new convention for the `type:` field's allowed values, consumed by `Web::API.hydrate_composed_contexts` and by the new `TestSubject#async_step`/`#async_reactor` traversal helpers (mirroring `#composed`/`#map`).
- **`Web::API`** (`lib/ruby_reactor/web/api.rb`): `determine_step_type` gains `async_step`/`async_reactor` branches (replacing the removed `config.async?` branch); `build_structure` drops the per-step `async:` field and instead exposes the reactor's single hand-off point once, as the normalized `{ mode:, step: }` pair (so the dashboard can mark the cut regardless of which side declared it); `hydrate_composed_contexts` gains resolution branches for the two new ref types, mirroring `hydrate_map_ref`. See research.md decision 8.
- **GUI** (`gui/src/components/DagVisualizer.tsx`, `StepInspector.tsx`): need new rendering cases for the `'async_step'`/`'async_reactor'` step types surfaced by the API above — a task-phase implementation item, called out here so it isn't missed (constitution Principle IV: dashboard must stay current with the reactor state model).
