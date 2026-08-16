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

**Error contract**: attempting to call `async` inside a `step` block MUST raise a `RubyReactor::Error::ValidationError` (or a new dedicated error subclass — implementation's choice, but it MUST be raised at reactor **class-definition** time, not at `run` time) whose message names both the removed syntax and its replacement(s): `background after:`, `async_step`, `async_reactor`.

## Added: `background after:`

```ruby
class MyReactor < RubyReactor::Reactor
  step :first
  step :second
  background after: :second
  step :third
end
```

- **Signature**: `self.background(after:)` — reactor class macro.
- **Constraint**: at most one `background` declaration per reactor class; a second declaration, or an `after:` value naming a step not defined in the class, MUST raise at class-definition time (FR-002).
- **Runtime contract**: steps up to and including `after:` execute in the calling process; `MyReactor.run` returns an `AsyncResult` once the `after:` step completes; steps declared after `background` execute in an independent worker job dispatched via `configuration.async_router`. Compensation for these later steps' failures works exactly as it does for any same-process step failure — `background` only changes *where* code runs, not the saga/compensation contract (US1 acceptance scenario 1).

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
    argument :email, result(:send_email)   # blocks (bounded poll) until :send_email is done
    run { |args| ... }
  end
end
```

- **Signature**: `self.async_step(name, impl = nil, &block)` — same call shape as `step`, builds the same `StepConfig` fields (`argument`, `run`, `compensate`, `undo`, `validate_args`, `validate_output`, `retries`, etc. all still work identically inside the block).
- **Runtime contract**:
  - Dispatches the step's work to an independent worker job; does **not** halt the calling reactor's execution of other ready steps that don't depend on it (US2 acceptance scenario 1).
  - Any step that references `result(:async_step_name)` blocks (bounded poll, `Configuration#async_wait_timeout`) until the async step's terminal result is available, then receives the same deserialized value a same-process step's result would produce (US2 acceptance scenario 2, FR-006).
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
- **Runtime contract**:
  - Dispatches `child_reactor_class` to run independently via `configuration.async_router`, linked to the parent by the child's `execution_id` for traceability/logging (FR-008, US3 acceptance scenario 4) — never added to the parent's compensation graph (FR-009).
  - If nothing in the parent reads `result(:name)`, the child's eventual failure never affects the parent (US3 acceptance scenario 1).
  - If a later step reads `result(:name)`, it blocks (same policy as `async_step`) until the child reactor reaches a terminal state, then receives the child's actual `Success`/`Failure` result object (not the enqueue-time `AsyncResult`), and may inspect `.success?`/`.value`/`.error` to decide whether to itself return `Failure` (US3 acceptance scenarios 2-3, FR-010).
  - A reference is recorded on the parent's own context (`composed_contexts[:create_profile] = { type: :async_reactor_ref, execution_id:, reactor_class_name:, ... }`) at dispatch time — the web dashboard renders `create_profile`/`create_account` as `async_reactor`-typed nodes and lets an operator open the linked child execution, the same drill-down `compose`/`map` already offer (FR-008, FR-014, US3 acceptance scenario 4).

## Unchanged (explicitly out of scope, called out to prevent accidental regression)

- Reactor-level `async true` ("Full Reactor Async") — `self.class.async?`, `lib/ruby_reactor/dsl/reactor.rb:44-50`.
- `compose` and its own step-level `async` flag (`ComposeBuilder#async`) — a single, unambiguous flag on a single compose step, not the confusing multi-step case this feature fixes.
- `map`'s dispatch/collection machinery — reused as an architectural pattern (see research.md) but its public DSL (`map`, `element`) is untouched.
- `result(:name)` for a **synchronous** step's result — resolves exactly as it does today (`Template::Result#resolve`), with zero added latency; the new blocking-poll path only activates for `async_step`/`async_reactor` references.
