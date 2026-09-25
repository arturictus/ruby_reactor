# Implementation Plan: Step-Scoped Retry Declarations

**Branch**: `retry_confs_in_steps` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/006-step-retry-declarations/spec.md`

## Summary

Two phases, delivered in this order (spec FR-017):

- **Phase A: remove `retry_defaults`.** `retry_defaults` becomes a stub that raises
  `DeprecatedDslError`. Every read of it is deleted: the three builder fallbacks, the
  `RetryManager` fallback, the `TestSubject` copies, and the `included` ivar. After this,
  `StepConfig`'s policy can come only from its own block. Ships as a standalone `feat!`
  commit with the suite green.
- **Phase B: `retries` on step classes.** A new `Dsl::Retryable` module, modeled on
  `Dsl::Lockable::ClassMethods`, provides `retries` with validation, a `retry_config` reader,
  and `inherited` propagation. `RubyReactor::Step` extends it; the step, compose and
  async-reactor builders include it, which replaces their duplicated `retries` methods.
  `StepConfig#retry_config` resolves lazily in the order own declaration, then
  `impl.retry_config`, then `NO_RETRIES`, the same way `lock_config` does. Declaring the policy
  both on the class and in the step block is refused, like locks.

Runtime retry code (`RetryManager`, `StepWorker`, `RetryContext`) is unchanged apart from
deleting the fallback. Direct `Step.run` already never retries (research R7).

## Technical Context

**Language/Version**: Ruby >= 3.0

**Primary Dependencies**: existing only: dry-validation, Sidekiq/ActiveJob adapters. No new
gems.

**Storage**: Redis (unchanged; no new keys, no serialization change)

**Testing**: RSpec against real Redis (`bundle exec rspec`); `demo_app` RSpec with the shipped
`RubyReactor::RSpec` surface; RuboCop

**Target Platform**: Ruby gem (MRI), sync and background (Sidekiq/ActiveJob) execution

**Project Type**: library (gem) + `demo_app` Rails integration example

**Performance Goals**: no runtime cost beyond one extra `||` per `retry_config` read

**Constraints**: public API change. The removal is breaking (`feat!`, migration note). Phase B
is additive. Behavior for reactors that never used `retry_defaults` must not change.

**Scale/Scope**: about 8 lib files touched, 1 new module; ~4 spec files migrated; 1 new spec
file; 1 demo reactor + rake task + spec; ~10 docs files

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
| --- | --- | --- |
| I. Gem-first | ✅ | All code in `lib/`, reachable via `require "ruby_reactor"`; no host coupling. |
| II. Saga integrity | ✅ | Compensation after the last attempt is unchanged; the new specs cover exhaust-then-compensate on class steps. |
| III. Test-first, real infra | ✅ | Each phase starts with failing specs; background paths drained against real Redis; no Redis mocking. |
| IV. Observability | ✅ | `retry_attempt` events and `MaxRetriesExhaustedFailure` unchanged; `StepConfig#retry_source` adds introspection. |
| V. Simplicity & SemVer | ✅ | One module replaces 3 duplicated methods (net deletion); no policy object (R3). Removal ships as `feat!` with a migration note (R9). |
| VI. Demo-app proof | ✅ | `StepRetryDemoReactor` + `demo:step_retry` + spec using only the shipped matchers (`have_retried_step`, `be_failure`, `be_success`). |
| Workflow: class-based steps in docs/examples | ✅ | Docs lead with the step class form. |

- [x] Documentation impact identified: which `README.md` sections and which file(s) under
      `./documentation` this feature will require updating (Constitution Development Workflow;
      carried into tasks.md as a required task):
  - **Phase A**: `documentation/retry_configuration.md` (delete "Reactor-Level Defaults", add
    a "Migrating from `retry_defaults`" section), `documentation/core_concepts.md` (≈360,
    remove "Uses reactor defaults"), `documentation/background_and_async.md` (≈482-530),
    `documentation/examples/{inventory_management,order_processing,payment_processing}.md`,
    the `demo_app/documentation/` copies of the same, README line 1486 ("reactor or step
    level"), and `llms*.txt` if they mention it.
  - **Phase B**: `documentation/retry_configuration.md` (step class form first; precedence;
    conflict rule; subclassing to vary per workflow; direct call runs once, unlike locks),
    `documentation/core_concepts.md` retry section, the README Features bullet (line 24),
    and the README Retry Configuration blurb.

**Post-design re-check**: ✅ no violations. Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/006-step-retry-declarations/
├── spec.md
├── plan.md              # this file
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   └── dsl-surface.md   # Phase 1
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
lib/ruby_reactor/
├── dsl/
│   ├── retryable.rb              # NEW (B): retries + validation, retry_config, inherited
│   ├── reactor.rb                # A: retry_defaults -> DeprecatedDslError stub; drop included ivar
│   ├── step_builder.rb           # A: drop reactor fallback; B: include Retryable, drop own
│   │                             #    retries, check_retry_conflict!, StepConfig lazy
│   │                             #    retry_config + retry_source + NO_RETRIES
│   ├── compose_builder.rb        # A: drop fallback; B: include Retryable, drop own retries
│   └── async_reactor_builder.rb  # A: drop fallback; B: include Retryable, drop own retries
├── step.rb                       # B: extend Dsl::Retryable
├── executor/retry_manager.rb     # A: drop reactor_class.retry_defaults fallbacks
└── rspec/test_subject.rb         # A: drop 3 @retry_defaults copies

spec/
├── async_retry_dsl_spec.rb               # A: retry_defaults example -> asserts removal error
├── ruby_reactor_spec.rb                  # A: move retry_defaults into step-level retries
├── support/order_processing_reactor.rb   # A: same
└── ruby_reactor/step_retries/*_spec.rb  # NEW: removal (A); declaration, class_policy,
                                          #   step_block_parity, conflict, execution_paths,
                                          #   inheritance, introspection, test_surface (B)

demo_app/
├── spec/support/order_processing_reactor.rb      # A: drop retry_defaults
├── app/reactors/step_retry_demo_reactor.rb       # NEW (B)
├── lib/tasks/demo_reactors.rake                  # B: demo:step_retry
└── spec/reactors/step_retry_demo_reactor_spec.rb # NEW (B)
```

**Structure Decision**: single gem layout (`lib/`, `spec/`) plus `demo_app/`, as in every
earlier feature. The new module lives next to `dsl/lockable.rb`, which it mirrors.

## Phase A: remove `retry_defaults` (ships first, standalone)

1. **Red**: change `spec/async_retry_dsl_spec.rb:23-33` to expect `DeprecatedDslError`,
   message included. Add: a subclass of `RubyReactor::Reactor` with no retry declarations runs
   a failing step exactly once.
2. **Green**: stub in `dsl/reactor.rb`; delete the `included` ivar; builders pass their own
   `@retry_config` (initialized `nil`, not `{}`); `StepConfig` defaults to `NO_RETRIES` when
   nil; `RetryManager#calculate_backoff_delay` reads only `step_config.retry_config` (drop the
   now-unused `reactor_class` argument or rename it `_reactor_class`); delete the
   `TestSubject` copies.
3. Migrate `spec/ruby_reactor_spec.rb`, `spec/support/order_processing_reactor.rb` and
   `demo_app/spec/support/order_processing_reactor.rb` to step-level `retries` on the steps
   that relied on the default. Keep their assertions unchanged, so behavior is proven
   identical.
4. Docs (see the Constitution Check list) and the `BREAKING CHANGE:` footer with the
   migration text.
5. Gate: `grep retry_defaults` is clean except the stub and its spec; `rspec` and `rubocop`
   are green. Commit `feat!: remove reactor-wide retry_defaults`.

## Phase B: `retries` on step classes

1. **Red**: `spec/ruby_reactor/step_retries/*_spec.rb` (one file per story) covering the quickstart table.
2. **Green**:
   - `Dsl::Retryable` (R3, R4): `BACKOFF_STRATEGIES`, `retries`, `retry_config`,
     `inherited`.
   - `Step` extends it. `StepBuilder`, `ComposeBuilder` and `AsyncReactorBuilder` include it
     and delete their own `retries`; remove `retry_config` from `StepBuilder`'s
     `attr_accessor`.
   - `StepConfig` (R5): store `@retry_config` raw; lazy `retry_config`; `retry_source`.
   - `StepBuilder#check_retry_conflict!` (R6), called from `build` next to
     `check_coordination_conflicts!`.
3. **Demo** (Constitution VI): `StepRetryDemoReactor` with class steps, showing
   succeed-after-retry, exhaust-then-compensate, and a single-attempt undeclared step, using
   `base_delay` near zero so the task runs fast; the `demo:step_retry` task depends on
   `[:environment, :flush_redis]`; the spec uses only `test_reactor`, `failing_at`/`mock_step`,
   `be_success`, `be_failure` and `have_retried_step`.
4. Docs (Phase B list above).
5. Gate: `rspec`, `rubocop`, and the docker demo run. Commit `feat: declare retries on step
   classes`.

## Risks

- **Hidden `{}`-vs-`nil` assumptions.** Code that checks `retry_config.empty?` breaks once
  the builders pass `nil`. Mitigation: `grep -rn "retry_config" lib` during Phase A; every
  consumer goes through `StepConfig#retry_config`, which never returns nil.
- **`name` collision in validation messages.** Builders' `name` is the step symbol and
  `Step.name` is the class name. Both are what the message should show. An anonymous step
  class has `name == nil`, so fall back to `inspect`.
- **Rubocop.** `inherited` in an included module triggers no cop today (Lockable does the
  same). The unused `reactor_class` argument in `RetryManager` needs removing or renaming to
  `_reactor_class`.

## Complexity Tracking

No violations. The table is empty.
