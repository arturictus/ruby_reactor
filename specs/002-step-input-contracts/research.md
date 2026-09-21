# Phase 0 Research: Step Input Contracts

**Feature**: `specs/002-step-input-contracts/` | **Date**: 2026-09-10

All findings below come from reading the current implementation, not from assumption. File
references are to the state of `step_validations` at the time of writing.

## Current state (what exists today)

| Concern | Where it lives now |
|---|---|
| Step argument wiring + rules | `Dsl::StepBuilder#argument` (`lib/ruby_reactor/dsl/step_builder.rb:41`) — one call does source mapping, transform, type, and predicates |
| Cross-field rules | `Dsl::StepBuilder#validate_args` (`step_builder.rb:76`) |
| Schema construction | `Validation::SchemaBuilder` (`build_inline`, `build_args`, `apply_inline_rules`) |
| Enforcement (inline path) | `Executor::StepExecutor#validate_step_arguments` (`step_executor.rb:312`) — **raises** `Error::InputValidationError` |
| Failure shaping | `Executor::ResultHandler#handle_execution_error` (`result_handler.rb:39`) — rollback + `build_validation_failure` |
| Step classes | `RubyReactor::Step` (`lib/ruby_reactor/step.rb`) — 43 lines: result helpers plus `run`/`compensate`/`undo` stubs. **No declaration DSL at all.** |

### Finding 1 — class steps have no contract surface and no implicit inputs

`resolve_arguments` builds only from `step_config.arguments`. `run_step_implementation`
(`step_executor.rb:346-353`) falls back to `@context.inputs` **only when the step has a run
block**. A class step with no `argument` declarations receives `{}`. FR-020's name-based
fallback is therefore new behavior for class steps, not a preserved one.

### Finding 2 — there are two step execution paths, and only one validates

- Inline/retry/resume: `execute_step` → `execute_step_with_retry` → `safe_execute_step_sync`
  → `execute_step_sync_without_result_handling` → `validate_step_arguments`. ✅
- `async_step` worker: `StepWorker#execute_step_body` (`step_worker.rb:112-118`) calls
  `step_config.run_block.call` / `step_config.impl.run` directly. **No validation.** ❌

FR-003 ("enforced on every execution path") is not satisfiable by adding rules to
`step_config` alone.

### Finding 3 — raising is the established validation protocol

`safe_execute_step_sync` (`step_executor.rb:186`) explicitly re-raises
`Error::InputValidationError` so it is never retried and never wrapped as a generic step
failure. `handle_execution_error` then rolls back completed steps and calls
`build_validation_failure`, producing the `validation_errors` payload that
`have_validation_error` (`rspec/matchers.rb:154`) reads. Any new enforcement point that
raises this error inherits the correct failure shape, saga rollback, retry suppression, and
matcher support for free.

### Finding 4 — `input` is already overloaded, and collides inside step blocks

- On a reactor body, `Dsl::Reactor::ClassMethods#input` (`dsl/reactor.rb:70`) **declares**.
- Inside `step ... do ... end`, `StepBuilder` includes `Dsl::TemplateHelpers`, whose
  `input(name, path = nil)` (`template_helpers.rb:8`) **returns a `Template::Input`** used as
  an argument source.

So `input` means "declare" in one scope and "reference" in an adjacent one. Any inline-step
contract syntax must not make that worse. This is the single biggest design constraint on
FR-007/FR-012.

### Finding 5 — falsey values are lost before a step sees them

`Context#get_input` (`context.rb:67`) and `#get_result` (`context.rb:79`) both use
`@inputs[name.to_sym] || @inputs[name.to_s]`; `Template::Result#fetch`
(`template/result.rb:178`) repeats the pattern for nested lookups. A supplied `false`
resolves to `nil`. Under contracts this escalates from a silent wrong value into a spurious
"must be filled" failure (FR-023).

### Finding 6 — internal steps include `RubyReactor::Step`

`MapStep`, `ComposeStep`, and `AsyncReactorStep` all `include RubyReactor::Step`. Anything
added to that module must be inert for a step that declares no contract.

### Finding 7 — no registry of user reactor classes

`Registry` (`lib/ruby_reactor/registry.rb`) holds only dynamically-generated reactors from
inline `map`/`compose`. There is no list of all user-defined reactor classes, so there is no
place to hang a global "validate every reactor at boot" pass without adding one.

---

## Decisions

### D1 — A contract is declared with `input` on the step class

```ruby
class ChargeStep
  include RubyReactor::Step

  input :amount,   :decimal, gt?: 0
  input :currency, :string,  included_in?: %w[USD EUR GBP]
  input :user,     User
  input :note,     :string,  optional: true, max_size?: 100

  def self.run(args, context) = Success(charge!(args))
end
```

**Rationale**: matches the user's sketch and the reactor's own `input`. No collision exists in
a step class body — `Step` does not include `TemplateHelpers`.

**Signature** is deliberately identical to `Dsl::Reactor::ClassMethods#input`:
`input(name, type = nil, optional: false, default: nil, redact: false, **predicates, &block)`,
including the Form-2 macro block (`input :x do |i| ... end`) and `validate:` for a pre-built
schema. Reuses `Dsl::ValidationHelpers` verbatim.

**Alternatives rejected**: `accepts` / `param` — a third word for a concept the library
already names twice.

### D2 — Inline steps declare a contract inside an `inputs do ... end` block

```ruby
step :charge do
  inputs do
    input :amount,   :decimal, gt?: 0
    input :currency, :string,  included_in?: %w[USD EUR GBP]
  end

  argument :amount,   input(:amount)      # still the template reference
  argument :currency, input(:currency)

  run { |args, _| charge!(args) }
end
```

**Rationale**: Finding 4. Inside the `inputs` block, `self` is a contract builder where
`input` unambiguously declares; outside it, `input(:x)` keeps meaning the template reference
it has always meant. Zero back-compat risk, no arity magic, and the declaration lines are
byte-identical to the ones in a step class — moving an inline step into a class is deleting
the wrapper (FR-007, SC-005).

**Alternatives rejected**:

- *Arity overload* — `input(:x)` returns a template, `input(:x, :string)` declares. Tempting
  (no extra nesting) but `input :x` as a bare statement becomes silently meaningless, and the
  same token in the same block would mean two different things depending on argument count.
  This is exactly the "strange bugs and hard-to-debug validation errors" the spec exists to
  remove.
- *Renaming the template helper* to `reactor_input(:x)` — breaks every existing reactor.

### D3 — Enforcement lives in the step, via a prepended `run`

`Step.included(base)` prepends a wrapper onto `base.singleton_class`. The wrapper validates
the arguments against the contract and then calls `super`. A step with no contract skips
straight to `super` (Finding 6).

**Rationale**: one enforcement point covers all three call sites — the executor
(`step_executor.rb:353`), the async worker (`step_worker.rb:118`, Finding 2), and direct
invocation (FR-022) — instead of three. `TestSubject`'s mock wrapper
(`rspec/test_subject.rb:647`) calls `impl.run`, so mocked steps validate too.

On violation the wrapper **raises** `Error::InputValidationError` (Finding 3), not a `Failure`
— that is the protocol the executor, the rollback path, and `have_validation_error` already
speak.

**Step attribution**: the step class knows its own name but not the reactor's step name.
`safe_execute_step_sync`'s existing `rescue Error::InputValidationError` (`step_executor.rb:186`)
gains `e.step_name ||= step_config.name` before the re-raise — attribution stamped where the
name is known.

**Alternatives rejected**: building the step's validator into `StepConfig#args_validator` at
DSL time. Simpler-looking, but leaves the worker path unvalidated and direct invocation
unvalidated, and re-centralizes in the reactor what this feature is trying to move into the
step.

### D4 — Inline contracts reuse `args_validator`; the worker path gets the missing call

An inline step has no class to prepend to, so its `inputs` block compiles to an
`args_validator` on `StepConfig`, enforced by the existing `validate_step_arguments`. To
close Finding 2, `StepWorker#execute_step_body` gains the same validation call, and its
`rescue StandardError` grows an `Error::InputValidationError` branch so the worker produces
the same failure shape rather than a generic `Failure(e)`.

Two mechanisms, one protocol: both raise `Error::InputValidationError`, both land in
`build_validation_failure`.

### D5 — Reactor-side conflicts fail at the `step` macro

`StepBuilder#build` already has both `@impl` and `@arg_validations`. When `@impl` declares a
contract and the reactor supplied a type, predicates, `validate_args`, or an `inputs` block,
raise immediately — the error points at the offending line in the reactor class body
(FR-006). Same for an `argument` naming an input the contract does not declare (FR-018).

Message names the reactor, the step, the argument, and the owning step class.

### D6 — Satisfiability is checked by `validate_definition!`, memoized, at first execution

FR-021 needs the reactor's full input list, which is not known while the class body is still
executing — `input` declarations may follow `step` declarations. Finding 7 rules out a
global boot-time sweep.

`Reactor.validate_definition!` walks every step with a contract and asserts each required
input is satisfied by an explicit `argument` or a same-named reactor input. It is memoized
and invoked from `Reactor.run`/`.call` before execution begins, and from `test_reactor`, and
is public so an application can call it in an initializer or CI check.

**Deviation from spec wording**: FR-008/FR-021 and US4 say "when the reactor class is
loaded". Conflict and unknown-argument checks (D5) genuinely are load-time. The
satisfiability check fires at first execution instead. The user-visible property the spec
cares about — the error names the reactor, step, and input, and does not depend on reaching
that step at run time — holds either way: a reactor whose wiring is incomplete fails before
step one runs, not on the unlucky run that first reaches the step.

**Alternatives rejected**: `TracePoint(:end)` to detect the end of a class body (clever,
unreadable, breaks on reopened classes); requiring `input` before `step` (silently breaks
valid existing reactors).

### D7 — Name-based fallback resolves at `validate_definition!` time, reactor inputs only

An unwired declared input becomes `Template::Input.new(name)` appended to the step's
`arguments` — the same object an explicit `argument :x, input(:x)` produces, so nothing
downstream changes. Explicit wiring wins (never overwritten). Step results are never
consulted (FR-020), so resolution can't shift when an unrelated step is renamed.

### D8 — Presence means "supplied", via one shared helper

Add `RubyReactor::Utils.fetch_indifferent(hash, key)` —
`hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key.to_s]` — and use it at `context.rb:67`,
`context.rb:79`, and `template/result.rb:178`. Defaults (FR-013) apply when the key is absent
or the resolved value is `nil`; `false` is neither, so it survives.

**SemVer**: a fix, not a break — no documented behavior said `false` becomes `nil`.

### D9 — Deprecation, not removal, for reactor-declared rules

`argument :x, src, :string, gt?: 0` on a step with no contract keeps working unchanged
(FR-010). It emits a one-time-per-site deprecation naming the `input` replacement once the
step's own contract is the documented path (FR-011). Removal is a later MAJOR.

## Open risks

| Risk | Mitigation |
|---|---|
| Prepending to `singleton_class` surprises anyone who aliases or redefines `self.run` after `include` | Prepend happens at `include` time, so a later `def self.run` is still `super`'d correctly. Covered by a spec. |
| `inputs do` block inside `step` is a third nesting level | Only for inline steps; the constitution already names class steps the preferred style. |
| Two enforcement mechanisms (D3 prepend, D4 validator) could drift | Both raise the same error class through the same handler; a shared spec asserts identical outcomes for the class and inline forms (SC-005). |
| Falsey fix changes behavior for anyone relying on `false → nil` | Pre-existing defect; changelog note under Bug Fixes. |
