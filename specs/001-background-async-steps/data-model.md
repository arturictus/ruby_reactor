# Data Model: Background Execution & Real Async Steps

This is a library feature — "entities" are DSL/runtime constructs and the storage records backing them, not application data.

## Background Hand-off Point

Reactor-class-level declaration, one per reactor.

| Field | Type | Notes |
|---|---|---|
| `after` | Symbol | Name of the step after which remaining steps hand off. Must reference a step defined in the same reactor (validated at class-definition time, FR-002). |

**Storage**: not persisted as its own record — it's compiled into which step's completion triggers `StepExecutor#handle_async_step`-style enqueue. Enforced-single via a class-level guard (raising if `background` is declared twice).

**Validation rules**:
- Exactly zero or one `background after:` per reactor class (FR-002).
- `after:` step name must exist in `steps` at the time `background` is evaluated, or at class-definition-close time if steps can be declared afterward (implementation detail for tasks phase).

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

- `dispatched`: parent process has, in one synchronous step: (1) enqueued the `StepWorker` job, (2) written a `composed_contexts[step_name] = { type: :async_step_ref, name:, dispatched_at: }` reference onto its own context (see Async Step ↔ context linkage below), and (3) marked the step graph-complete for scheduling purposes (siblings may now proceed). No result exists yet.
- `running`/`completed`: opaque to the parent process except through the Step Result Record; the parent only observes "record exists with a terminal value" or "record absent" (treated as still-pending, subject to FR-005's timeout).

**Relationships**: An `async_step` is a dependency-graph node like any other step — other steps that declare `argument :x, result(:async_step_name)` get an automatic DAG edge (existing `DependencyGraph#add_step` behavior, unchanged) and, per FR-005, block-poll for the terminal record when they resolve that argument.

**Async Step ↔ context linkage (FR-008, FR-014)**: the *reference* (not the result) lives in `context.composed_contexts[step_name]`, the same field `compose`/`map` already populate for their own children — see research.md decision 8. The dashboard's existing `hydrate_composed_contexts` pipeline (`lib/ruby_reactor/web/api.rb`) is extended with a branch for `type: :async_step_ref` that resolves the Step Result Record to show current status/result, mirroring how it already resolves `:map_ref`.

## Async Reactor

A step declared with `async_reactor :name, ChildReactorClass`.

| Field | Type | Notes |
|---|---|---|
| `name` | Symbol | Step name in the parent. |
| `child_reactor_class` | Class | Must be a `RubyReactor::Reactor` subclass. |
| `argument_mappings` | Hash | Same shape as `compose`'s `argument_mappings` — maps parent-visible sources to the child's inputs. |

**Relationships**:
- Linked to the parent via `context.composed_contexts[step_name] = { type: :async_reactor_ref, name:, execution_id:, reactor_class_name:, dispatched_at: }` — written synchronously by the dispatching step, same field and pattern `compose`/`map` already use (research.md decision 8). Unlike `async_step`, no separate Step Result Record is needed for the *outcome*: the child is a normal, independently addressable `Reactor` with its own context row, so its terminal result is reached via the existing `storage.retrieve_context(execution_id, reactor_class_name)` / `ChildReactorClass.find(execution_id)` — the same lookup any other reactor execution uses.
- **Not** added to the parent's compensation graph — no `compensate`/`undo` block is registered for this step (see spec Clarifications: compensation is opt-in via a later step reading the result, never automatic).
- FR-008/FR-014: this `composed_contexts` entry is what the web dashboard's `hydrate_composed_contexts` reads to render the reference and drill into the child's own step structure (`build_structure` recursion, same as `compose`/`map`'s `nested_structure`).

## Step Result Record (new storage-level entity)

The durable record backing `async_step` completion. (`async_reactor` needs no equivalent record — per the relationship above, its outcome is simply its own context row, reached by execution id through the existing `retrieve_context`/`find` path.) This avoids what would otherwise be a race-prone write into the parent's context blob from a worker running concurrently with the still-executing parent process.

| Field | Type | Notes |
|---|---|---|
| `context_id` | String (UUID) | The **parent** reactor's context id — the bucket is scoped per parent execution. |
| `step_name` | Symbol/String | The `async_step`/`async_reactor` step's name within that parent. |
| `status` | Enum: `dispatched`, `completed` | `dispatched` written synchronously at enqueue time (so `result()` knows "pending, keep polling" vs. "never dispatched, don't wait"); `completed` written by the async unit's own worker. |
| `serialized_result` | String (via `ContextSerializer.serialize_value`) | The step's `Success`/`Failure` value, same serialization the existing map-result bucket uses. |
| `reactor_class_name` | String | Needed for storage-key namespacing, mirrors every other storage primitive's `reactor_class_name` parameter. |

**Storage interface additions** (`RubyReactor::Storage::Adapter`, implemented by `RedisAdapter`):

```ruby
store_step_result(context_id, step_name, serialized_result, reactor_class_name)
retrieve_step_result(context_id, step_name, reactor_class_name)
```

Modeled directly on the existing `store_map_result(map_id, index, serialized_result, reactor_class_name, strict_ordering:)` / `retrieve_map_results(...)` pair (`lib/ruby_reactor/storage/adapter.rb:14-20`) — same TTL policy as `context_ttl` (records must not outlive the parent context's own retention window).

## Configuration additions

| Knob | Default | Notes |
|---|---|---|
| `Configuration#async_wait_timeout` | TBD at implementation (documented explicitly, FR-005) | Seconds a `result()` block-poll will wait before failing the referencing step with a timeout. Single global value — no per-reactor/per-reference override (Clarifications, Question 3). |

## State/behavior changes to existing entities

- **`StepConfig`** (`lib/ruby_reactor/dsl/step_builder.rb`): the `async`/`async?` accessor is removed; using `async true` inside a `step` block raises a definition-time error naming the replacement DSL (FR-003). `ComposeBuilder#async` (`dsl/compose_builder.rb:31-33`) is **unaffected** — it configures the existing step-level hand-off behavior for a `compose` step and is a separate, already-consistent mechanism (single flag, no multi-step ambiguity), out of scope for this feature.
- **`DependencyGraph`**: no schema change; `complete_step` is now called for an `async_step` at dispatch time rather than at true completion — a deliberate, documented divergence from every other step type, captured here so it isn't mistaken for a bug during implementation review.
- **Reactor-class DSL** (`lib/ruby_reactor/dsl/reactor.rb`): three new class macros — `background(after:)`, `async_step(name, impl = nil, &block)`, `async_reactor(name, child_reactor_class, &block)` — alongside the existing `step`, `compose`, `map`, `interrupt`. The existing reactor-level `async`/`async?` (whole-reactor async) is unchanged.
- **`Context#composed_contexts`**: gains two new `type:` tags in its value union — `:async_step_ref` and `:async_reactor_ref` — alongside the existing `:composed` and `:map_ref`. No schema/serialization change (it's already a generic `Hash`, already serialized/deserialized as-is); this is purely a new convention for the `type:` field's allowed values, consumed by `Web::API.hydrate_composed_contexts` and by the new `TestSubject#async_step`/`#async_reactor` traversal helpers (mirroring `#composed`/`#map`).
- **`Web::API`** (`lib/ruby_reactor/web/api.rb`): `determine_step_type` gains `async_step`/`async_reactor` branches (replacing the removed `config.async?` branch); `build_structure` drops the per-step `async:` field; `hydrate_composed_contexts` gains resolution branches for the two new ref types, mirroring `hydrate_map_ref`. See research.md decision 8.
- **GUI** (`gui/src/components/DagVisualizer.tsx`, `StepInspector.tsx`): need new rendering cases for the `'async_step'`/`'async_reactor'` step types surfaced by the API above — a task-phase implementation item, called out here so it isn't missed (constitution Principle IV: dashboard must stay current with the reactor state model).
