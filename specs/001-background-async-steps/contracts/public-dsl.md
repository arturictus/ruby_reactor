# Contract: Public DSL Surface

This gem's "interface" is its Ruby DSL, consumed by host applications that subclass `RubyReactor::Reactor`. This contract documents the exact public surface this feature adds, changes, or removes, so implementation and tests can be checked against it directly.

## Removed

```ruby
class MyReactor < RubyReactor::Reactor
  step :do_thing do
    async true   # REMOVED — raises a definition-time error (FR-003)
  end
end
```

```ruby
class MyReactor < RubyReactor::Reactor
  compose :sub_flow, SubReactor do
    async true   # ALSO REMOVED — same StepConfig hand-off flag, same definition-time error
  end
end
```

**Error contract**: attempting to call `async` inside a `step` **or `compose`** block MUST raise a `RubyReactor::Error::ValidationError` (or a new dedicated error subclass — implementation's choice, but it MUST be raised at reactor **class-definition** time, not at `run` time) whose message names both the removed syntax and its replacement(s): `background after:`/`background before:`, `async_step`, `async_reactor`. (`ComposeBuilder#async` sets the very `StepConfig` flag this feature removes — `dsl/compose_builder.rb:62` — so it cannot survive; the exact migration for a compose that handed off is `background before: :<that compose step>`, which reproduces the old semantics precisely — the flagged step and everything after it moved to the worker — without the author having to identify a predecessor.)

**Not removed**: the `async` option inside a `map` block (`MapBuilder#async`, `dsl/map_builder.rb:43`) is a map-internal element-dispatch mode passed as a step *argument* — the map's own `StepConfig` is hardcoded `async: false` (`map_builder.rb:111`), so it does not touch the removed flag and keeps working unchanged.

## Added: `background after:` / `background before:`

```ruby
class MyReactor < RubyReactor::Reactor
  step :first
  step :second
  background after: :second     # :second is the LAST step in the calling process
  step :third
end

class EquivalentInLinearFlow < RubyReactor::Reactor
  step :first
  step :second
  background before: :third     # :third is the FIRST step in the worker
  step :third
end
```

- **Signature**: `self.background(after: nil, before: nil)` — reactor class macro, exactly one keyword supplied.
- **The two forms** name one cut point from opposite sides, and each carries a *guarantee about the step it names*:
  - `after: :x` — `:x` runs in the calling process, and is the last step to do so.
  - `before: :x` — `:x` runs in the worker, and is the first step to do so; it never executes in the calling process.

  In a linear reactor where `:third` immediately follows `:second`, `after: :second` and `before: :third` are equivalent. In a branching workflow they are not, and the author picks whichever step they actually need pinned.
- **Constraints** (all raise at class-definition time, FR-002):
  - at most one `background` declaration per reactor class;
  - the named step must be defined in the class (either keyword);
  - exactly one of `after:`/`before:` — supplying both, or neither, raises;
  - combining `background` with whole-reactor `async true` raises (the hand-off point would be silently meaningless inside a reactor that already runs entirely in a worker — see spec Edge Cases).
- **Runtime contract**: hand-off is triggered by *reaching the named step*, not by the declaration's lexical position — the declaration may sit anywhere in the class body. For `after: :x`, the trigger fires when `:x` completes; for `before: :x`, it fires when `:x` is selected to run, and `:x` is left unexecuted for the worker to run. Either way: checkpoint, enqueue the remainder via `configuration.async_router`, return an `AsyncResult` to the caller. In a DAG with parallel branches, any independent step that became ready and executed before the trigger fired has already run in the calling process; everything not yet executed at the trigger moment runs in the worker — this caveat is identical for both forms. Compensation for worker-side step failures works exactly as it does for any same-process step failure — `background` only changes *where* code runs, not the saga/compensation contract (US1 acceptance scenarios 1-2). Inside the worker the hand-off never re-triggers (the existing `inline_async_execution` guard).
- **Never-reached trigger**: if the named step is skipped by a `where`/guard condition, or the reactor fails before reaching it, the hand-off simply never fires and the run completes in the calling process. No step is stranded — the hand-off only ever relocates *remaining* work.
- **`before:` naming the first step** is legal, and is not the same as whole-reactor `async true`: every step body runs in the worker, but input validation still happens in the calling process, so invalid inputs fail the caller synchronously instead of failing inside a worker.

## Added: `async_step`

```ruby
class MyReactor < RubyReactor::Reactor
  async_step :send_email do
    argument :to, input(:email)
    run { |args| Mailer.send(args[:to]) }
  end

  step :do_something_same_thread do
    run { do_work }
  end

  step :check_email do
    argument :email, result(:send_email)   # blocks (notified wait, bounded by timeout) until :send_email is done
    run { |args| ... }
  end
end
```

- **Signature**: `self.async_step(name, impl = nil, &block)` — same call shape as `step`, builds the same `StepConfig` fields (`argument`, `run`, `compensate`, `undo`, `validate_args`, `validate_output`, `retries`, etc. all still work identically inside the block).
- **Runtime contract**:
  - Dispatches the step's work to an independent worker job; does **not** halt the calling reactor's execution of other ready steps that don't depend on it (US2 acceptance scenario 1).
  - Any step that references `result(:async_step_name)` blocks — notified wait: woken by the completion signal the finishing worker publishes after its durable write, with a coarse fallback re-check of the durable record, bounded overall by `Configuration#async_wait_timeout` (spec Clarifications, Session 2026-08-20) — until the async step's terminal result is available. **Read semantics**: on `Success`, the reader receives the same deserialized raw value a same-process step's result would produce (US2 acceptance scenario 2, FR-006); on `Failure`, the reader receives the `Failure` object itself as the argument value — a same-process step's failure would have halted the reactor before any reader ran, so there is no sync-behavior to mirror here, and injecting the `Failure` is what lets the reader "see the failure and decide" per the spec's clarified compensation model (US2 acceptance scenario 3). This matches `async_reactor`'s wrapped-result-on-inspection pattern.
  - `returns :async_step_name` raises at class-definition time — the reactor's return value must come from a same-process step (spec Edge Cases).
  - Dispatch is **not** suppressed inside a worker: an `async_step` declared after a `background` hand-off point (or reached during a worker resume) still dispatches to its own independent job — the existing `inline_async_execution` guard suppresses only the *hand-off* re-trigger, never `async_step`/`async_reactor` dispatch (spec Edge Cases).
  - Reactor-level `lock`/`semaphore`/`rate_limit` windows are held by the process executing the reactor's own steps — the async step's work runs *outside* those windows (in its own job, which acquires nothing). A step body that needs mutual exclusion must arrange it itself.
  - If the async step fails and no later step reads its result, the parent reactor's compensation is **not** automatically triggered (US2 acceptance scenario 3, FR-011). A later step that does read the result and observes failure may itself return `Failure` to trigger compensation.
  - `compensate`/`undo` blocks declared on an `async_step` still register normally — they only run if the step's own failure is surfaced into the parent's compensation path via the opt-in mechanism above, never automatically.
  - A reference to the dispatched unit is recorded on the parent's own context (`composed_contexts[:send_email] = { type: :async_step_ref, ... }`) at dispatch time, and the web dashboard renders `send_email` as an `async_step`-typed node (FR-008, FR-014).

## Added: `async_reactor`

```ruby
class MyReactor < RubyReactor::Reactor
  async_reactor :create_profile, CreateProfileReactor  # fire-and-forget, no downstream reference

  async_reactor :create_account, CreateAccountReactor do
    argument :user_id, input(:user_id)
  end

  step :verify_all do
    argument :account, result(:create_account)   # blocks until create_account finishes
    run do |args, context|
      if args[:account].success?
        Success(args[:account].value)
      else
        Failure(args[:account].error)   # opt-in compensation trigger
      end
    end
  end
end
```

- **Signature**: `self.async_reactor(name, child_reactor_class, &block)` — `argument` inside the block maps parent-visible sources to the child reactor's inputs, same shape as `compose`.
- **Dispatch contract** (the part that runs in the parent's process, FR-015/FR-016):
  - Dispatch applies the same pre-enqueue safeguards as a top-level async run: the child's inputs are validated and, if the child declares `with_ordered_lock`, its ordering nonce is assigned at enqueue. A child-input validation failure fails **the dispatching step** (normal saga handling in the parent) — this is a dispatch failure, not a child-execution failure, and is deliberately outside FR-009's no-auto-compensation rule.
  - Deadlock guard: if the child declares an exclusive `lock` (or a `semaphore` with `limit: 1`) whose resolved key equals one the dispatching execution currently holds, the dispatch step fails immediately with an error naming the lock key and both reactor classes. The error message MUST enumerate the three remediations, ranked: (1) use `compose` if the child belongs in the parent's critical section and its result is needed — the wait means the work is sequential anyway; (2) narrow the lock keys if parent and child actually protect different resources; (3) restructure so the locked reactor never reads the child's result — fire-and-forget with verification in the child itself or in a successor reactor outside the lock window. Lock ownership is never shared across the async boundary (parent and child run concurrently — shared ownership would break mutual exclusion); owner-based reentrancy remains for `compose` only. Transitive cross-execution cycles are out of the guard's reach (undetectable at dispatch) — documentation advises consistent key-acquisition order, with the FR-005 timeout as backstop.
- **Runtime contract**:
  - Dispatches `child_reactor_class` to run independently via `configuration.async_router`, linked to the parent by the child's `execution_id` for traceability/logging (FR-008, US3 acceptance scenario 4) — never added to the parent's compensation graph (FR-009).
  - If nothing in the parent reads `result(:name)`, the child's eventual failure never affects the parent (US3 acceptance scenario 1).
  - If a later step reads `result(:name)`, it blocks (same notified-wait policy as `async_step` — the child publishes its completion signal after its terminal save) until the child reactor reaches a terminal state, then receives the child's actual `Success`/`Failure` result object (not the enqueue-time `AsyncResult`), and may inspect `.success?`/`.value`/`.error` to decide whether to itself return `Failure` (US3 acceptance scenarios 2-3, FR-010).
  - A reference is recorded on the parent's own context (`composed_contexts[:create_profile] = { type: :async_reactor_ref, execution_id:, reactor_class_name:, ... }`) at dispatch time — the web dashboard renders `create_profile`/`create_account` as `async_reactor`-typed nodes and lets an operator open the linked child execution, the same drill-down `compose`/`map` already offer (FR-008, FR-014, US3 acceptance scenario 4).
  - `returns :async_reactor_name` raises at class-definition time, same as for `async_step`.
  - A child that *pauses* at an interrupt step is not terminal: a reader keeps polling and hits the FR-005 timeout unless the child is resumed within the bound (spec Edge Cases). The child is an ordinary independently-recoverable execution — the existing sweeper/durability machinery covers its crash recovery with no new mechanism.

## Unchanged (explicitly out of scope, called out to prevent accidental regression)

- Reactor-level `async true` ("Full Reactor Async") — `self.class.async?`, `lib/ruby_reactor/dsl/reactor.rb:44-50`. (Its only new interaction: combining it with `background after:` is a definition-time error, see above.)
- `compose` itself — synchronous, fully compensation-linked nested execution, untouched. (Its `async` flag is removed — see the Removed section — but everything else about `compose` is unchanged.)
- `map`'s dispatch/collection machinery and its full DSL including the map-internal `async` element-dispatch option — reused as an architectural pattern (see research.md) but untouched.
- `result(:name)` for a **synchronous** step's result — resolves exactly as it does today (`Template::Result#resolve`), with zero added latency; the new notified-wait path only activates for `async_step`/`async_reactor` references.
