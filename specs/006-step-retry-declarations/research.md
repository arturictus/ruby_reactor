# Research: Step-Scoped Retry Declarations

Every decision below was checked against the code on `retry_confs_in_steps` (base `900d6522`).
Nothing in Technical Context was left open.

## R1 — How `retry_defaults` works today

**Finding**:

- `Dsl::Reactor.included` sets `@retry_defaults = {max_attempts: 3, …}` on
  `RubyReactor::Reactor` **only** (`lib/ruby_reactor/dsl/reactor.rb:14`). Nothing copies it to
  subclasses.
- The reader `retry_defaults` lazily returns `{max_attempts: 1, …}` for any subclass that never
  called it (`dsl/reactor.rb:58-68`).
- `StepBuilder#build`, `ComposeBuilder#build` and `AsyncReactorBuilder#build` **snapshot**
  `@reactor.retry_defaults` into `retry_config` when their own block declared none
  (`step_builder.rb:163`, `compose_builder.rb:74`, `async_reactor_builder.rb:52`). So a
  `retry_defaults` line only affects steps declared *after* it. This is the "unpredictable"
  behavior the user called out.
- `RetryManager#calculate_backoff_delay` falls back to `reactor_class.retry_defaults` for
  `backoff`/`base_delay` (`executor/retry_manager.rb:29-30`).
- `RSpec::TestSubject` copies `@retry_defaults` into its three generated execution subclasses
  (`rspec/test_subject.rb:559, 651, 739`).

**Consequence**: a reactor that never called `retry_defaults` already runs undeclared steps
exactly once. Removing the feature changes behavior only for reactors that call it (spec US1
scenario 3).

**Callers to migrate**: `spec/async_retry_dsl_spec.rb:23-33`, `spec/ruby_reactor_spec.rb:14, 221`,
`spec/support/order_processing_reactor.rb:28`, `demo_app/spec/support/order_processing_reactor.rb:28`,
plus docs (see R10).

## R2 — How to remove `retry_defaults`

**Decision**: replace the method with a stub that raises `Error::DeprecatedDslError` when the
class is defined, and delete every read of it (the builder fallbacks, the `RetryManager`
fallback, the `TestSubject` copies, and the `included` ivar).

**Rationale**: this is exactly how the project removed `async true` on reactors
(`dsl/reactor.rb:48-56`) and `async` in step/compose blocks (`step_builder.rb:119-131`). A call
fails loudly at load time with a migration message instead of being silently ignored. The
error names the reactor (`name` or `"anonymous reactor"`) and says: declare `retries` on each
step class or step block that needs it.

**Alternatives considered**:

- *Deprecation warning, keep working for one release*: rejected. The user asked to remove it
  altogether, and keeping it alive also keeps the ordering bug from R1.
- *Delete the method outright (`NoMethodError`)*: rejected. It gives no migration hint and
  breaks the project's established removal pattern.

**Delivery**: this is Phase A of the plan and ships first, as its own commit, with the full
suite green (spec FR-017).

## R3 — Where `retries` lives for a step class

**Decision**: a new module `RubyReactor::Dsl::Retryable`, modeled on `Dsl::Lockable::ClassMethods`,
containing:

- `retries(max_attempts: 3, backoff: :exponential, base_delay: 1)`: validates, then stores
  `@retry_config`;
- `retry_config`: the reader, `nil` when nothing was declared;
- `inherited(subclass)`: copies `@retry_config` to the subclass, exactly like
  `Lockable#inherited`.

`RubyReactor::Step` **extends** it (class-level DSL). `StepBuilder`, `ComposeBuilder` and
`AsyncReactorBuilder` **include** it, which replaces their three identical `retries` methods.
The same is already done with `Lockable::ClassMethods` in `StepBuilder` (`step_builder.rb:8`).

**Rationale**: the user asked us to emulate the locks design. One module gives both forms the
same vocabulary, the same defaults and the same validation (spec FR-001/FR-002/FR-004), and it
removes duplication instead of adding it. Inheritance by copying in `inherited` matches locks,
so a subclass redeclaring its policy leaves its parent and siblings untouched (FR-010).

**Alternatives considered**:

- *Walk `superclass` in the reader (like `input_contract`)*: works too, but it would be a
  second inheritance mechanism next to Lockable's. Rejected for consistency.
- *A `RetryPolicy` value object*: rejected. There is only one consumer shape (a 3-key hash
  read by `RetryManager`/`StepWorker`), so an object would be an abstraction with no second
  use case (Constitution V).

## R4 — Validation of retry values

**Decision**: `Retryable#retries` raises `ArgumentError` when the declaration is made if:

- `max_attempts` is not an `Integer` `>= 1`;
- `backoff` is not one of `%i[exponential linear fixed]`;
- `base_delay` is not a `Numeric` `>= 0`.

The message names the owner (`name`: the step symbol in a builder, the class name on a step
class), the option and the bad value.

**Rationale**: `ArgumentError` at declaration time is what `with_period`, `with_rate_limit`
and `validate_rollback_wait!` already do (`dsl/lockable.rb`). An unknown backoff strategy
fails today only at the first retry (`RetryContext.calculate_backoff_delay` raises
`ArgumentError`, `retry_context.rb:94`), which can be in production, days later.
`ActiveSupport::Duration` (`5.seconds`) passes the `Numeric` check, because
`Duration#is_a?` delegates to its value, so the documented Rails idiom keeps working.

**Behavior change**: `max_attempts: 0`, which today means "no retry", is now refused and must
be written `max_attempts: 1` (spec Assumptions). It goes in the migration note.

## R5 — Effective policy and precedence on `StepConfig`

**Decision**: `StepConfig` stores the builder's own declaration (`nil` when none) and resolves
it lazily, the same way `lock_config` does (`step_builder.rb:286-304`):

```text
retry_config  = own declaration || impl.retry_config (if impl responds) || NO_RETRIES
retry_source  = :step_block | :step_class | :none
```

`NO_RETRIES = { max_attempts: 1, backoff: :exponential, base_delay: 1 }.freeze`.
`retryable?`, `RetryManager`, `StepWorker` and `StepCoordination#retry_pending?` keep reading
`retry_config` unchanged. Every hash now carries all three keys, so the reactor fallbacks in
`RetryManager` are unnecessary and removed in Phase A.

**Rationale**: resolving lazily through `impl` is what makes the class policy apply on every
path that already consults `step_config.retry_config`, with no per-path changes: the
in-process `RetryManager`, the background requeue, `StepWorker` for `async_step`, and resume
(FR-011/FR-012). `retry_source` covers the introspection requirement (FR-014) with one method.

**Alternatives considered**: snapshotting `impl.retry_config` at build time. Rejected: it
diverges from the lock readers and would miss a class policy declared after the reactor
references the class (for example after a reopen or reload).

## R6 — Conflict between class and step block

**Decision**: `StepBuilder#build` gains `check_retry_conflict!`, next to
`check_coordination_conflicts!`. It raises `Error::ValidationError` when the block declared
`retries` **and** `@impl.respond_to?(:retry_config) && @impl.retry_config`. The message has
the same shape as the lock one: `"<Reactor> step :<name> declares `retries` inline, but
<Class> declares it too. Keep ONE: …"`, and it also mentions subclassing as the way to vary
the policy per workflow.

**Rationale**: FR-009 asks for the same rule as locks. An inherited class policy counts as a
declaration, since `retry_config` returns the copied value.

`ComposeBuilder` and `AsyncReactorBuilder` need no check: their `impl` is an internal
`ComposeStep`/`AsyncReactorStep` that never declares retries.

## R7 — Direct invocation (clarified: runs once)

**Finding**: `Step.run` never enters `RetryManager`. `StepCoordination#retry_pending?` already
returns `false` for direct calls (`context_state?` is `!@direct && …`,
`step_coordination.rb:533-540, 679-681`), and the existing comment says so: "A direct call has
no retry policy of its own — it is never retried."

**Decision**: no runtime change. Add one spec proving that a step class declaring
`retries max_attempts: 3` and called directly runs once and returns its failure. Document it
in `retry_configuration.md` and next to the direct-call docs, contrasting it with locks
(FR-013).

## R8 — Test surface (`TestSubject`, matchers)

**Finding**: `mock_step` and `failing_at` replace only `@run_block` on the step config
(`test_subject.rb:797-826`), so `impl`, and with it the class policy, is kept. The
`have_retried_step` matcher (`rspec/matchers.rb:130`) reads attempt counts from the context,
not from the declaration.

**Decision**: no new matcher. Delete the three `@retry_defaults` copies (Phase A). Add specs
proving that `failing_at`/`mock_step` on a class step still retries under the class policy
(FR-015).

## R9 — Versioning

**Finding**: the version is `0.8.3`, managed by release-please. Earlier breaking removals
were released as `feat!` with a `⚠ BREAKING CHANGES` section and a **Migration:** line in
`CHANGELOG.md` (for example `async true`, `CHANGELOG.md:329`).

**Decision**: Phase A lands as a `feat!:` commit whose `BREAKING CHANGE:` footer carries the
migration text. Release-please generates the CHANGELOG entry from it. The pre-1.0 bump size
is release-please's call, as with earlier breaking releases. Phase B is a plain `feat:`.

## R10 — Documentation and demo impact

**`retry_defaults` appears in**:

- `documentation/retry_configuration.md` (the "Reactor-Level Defaults" section) and
  `documentation/core_concepts.md` (≈ line 360, "Uses reactor defaults");
- `documentation/background_and_async.md` (≈ lines 482-530);
- `documentation/examples/{inventory_management,order_processing,payment_processing}.md`;
- the stale copies under `demo_app/documentation/` (`async_reactors.md`, the same `examples/`
  files, `retry_configuration.md`).

**README**: the Features bullet (line 24) and the Retry Configuration blurb (line 1486,
"configure retries at the reactor or step level") both need rewording.

**Demo (Constitution VI)**: there is no retry-specific demo today. Retries appear only inline
in `signal_demo_reactor.rb` and `order_processing_reactor.rb`. Add `StepRetryDemoReactor` using
class steps, the `demo:step_retry` rake task, and
`demo_app/spec/reactors/step_retry_demo_reactor_spec.rb`, modeled on
`step_lock_demo_reactor.rb` and `inheritable_step_demo_reactor_spec.rb`.
