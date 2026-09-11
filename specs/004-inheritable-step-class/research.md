# Phase 0 Research: Inheritable Step Class

No `NEEDS CLARIFICATION` markers remain in the Technical Context (see plan.md) or the
spec. This file records the design decisions Phase 1 depends on, found by reading the
current implementation rather than by external research — this is an internal refactor of
an existing subsystem, not a new-technology adoption.

## D1: Class-level entry point shape

**Decision**: `RubyReactor::Step` exposes exactly three class methods —
`self.run(arguments, context)`, `self.undo(result, arguments, context)`,
`self.compensate(reason, arguments, context)` — matching the call sites that already
exist in `step_executor.rb` (`step_config.impl.run(arguments, @context)`) and
`compensation_manager.rb` (`step_config.impl.compensate(error, arguments, @context)` /
`step_config.impl.undo(result.value, arguments, @context)`). `self.call` is defined as an
alias of `self.run` (`singleton_class.alias_method :call, :run` in `inherited`, or simply
`def self.call(...) = run(...)`).

**Rationale**: Zero call-site changes needed in the executor, compensation manager, or
`rspec/test_subject.rb` — all three already call `impl.run` / `impl.compensate` /
`impl.undo` with exactly these signatures today (verified by reading
`lib/ruby_reactor/executor/step_executor.rb:357-361` and
`lib/ruby_reactor/executor/compensation_manager.rb:76-121`). The refactor changes what
happens *inside* those three class methods, not who calls them or with what arguments —
this is what keeps User Story 2 (every execution path unaffected) achievable without
touching the executor.

**Alternatives considered**:
- *A single `self.call(action, ...)` dispatcher* — rejected: would require changing three
  call sites for no behavioral gain, and obscures the three distinct lifecycle actions
  behind a string/symbol dispatch.
- *Keep `run`/`undo`/`compensate` as the only spellings, no `call` alias* — rejected: the
  prompt explicitly asks for `class_alias :call, :run`-equivalent, and the demo/README
  narrative style favors reading a step invocation as `MyStep.call(args, context)` in some
  examples; costs nothing to alias.

## D2: Fresh instance per lifecycle action (closes the Complexity Tracking risk)

**Decision**: Every class-level entry point builds its **own** instance —
`new(arguments, context)` for `run`, and a separate `new(arguments, context)` (plus the
one value that action alone receives — `result` for undo, `reason` for compensate) for
`undo`/`compensate`. No instance is cached or shared across actions on the class.

**Rationale**: Async execution already runs `run` and a later `undo`/`compensate` in
different invocations, potentially different processes (Sidekiq workers) — `step_worker.rb`
and `compensation_manager.rb` are separate call sites with no shared Ruby object between
them today (the mixin design made this true "for free" because there was never an
instance at all). Making the constructor the *only* place state enters an instance, and
giving each action its own instance, preserves that guarantee: an author cannot
accidentally memoize something in `run` and read it back in `undo`, because `undo`'s
instance never ran `run`. This directly satisfies spec FR-009 ("run on a fresh instance so
that behaviour is identical whether or not the run happened in the same process") and the
Edge Case "Run and rollback happen in different processes."

**Alternatives considered**:
- *One instance per class-level call, reused across a script/test that chains actions
  manually* — rejected: no call site in the codebase does this, and it would create an
  attractive nuisance (author writes code that "happens to work" only when run and undo
  land in the same process during tests, then breaks in production async execution).
- *Memoized instance keyed by context id* — rejected: unnecessary caching layer, and the
  existing `undo_stack`/compensation path already carries `arguments` and `result`/`reason`
  forward explicitly (see `compensation_manager.rb`'s `undo_stack` entries), so there is
  nothing an instance needs to remember between actions.

## D3: Instance constructor signature and accessors

**Decision**: `initialize(inputs, context, result: nil, reason: nil)` stores everything
the instance can ever read. Reader names, decided here so tasks.md does not have to:

| Reader | Holds | Available in |
|---|---|---|
| `inputs` | the validated (or raw, when no contract) argument hash | run, undo, compensate |
| `context` | the workflow `RubyReactor::Context` | run, undo, compensate |
| `result` | the step's own stored result value | undo only (nil elsewhere) |
| `reason` | the failure that triggered rollback | compensate only (nil elsewhere) |

`undo` and `compensate` therefore take no parameters either — matching the description's
example shape (`def run` / `def undo` / `def compensate` with no explicit parameter list)
while still giving the instance everything the class-level entry point receives.

**Rationale**: The feature description's example shows zero-arg instance methods, which
only works if the instance already holds everything it needs from construction. This
matches the "form object" / "interactor" idiom common in the Rails codebases the gem
targets (brownfield compatibility, spec User Story 3). `inputs` (plural) is chosen over
`input`/`arguments` because it mirrors `context.inputs` on the reactor side and the inline
`inputs do ... end` contract block, and stays visibly distinct from `arguments`, the word
the executor uses everywhere for the *unvalidated* resolved hash — reviewers can tell at a
glance which side of validation a value is on.

**Alternatives considered**:
- *`input` (singular), mirroring the declaration keyword* — rejected: reads oddly for a
  hash (`input[:amount]`), and the singular already means "one declaration" at class
  level.
- *`arguments`, mirroring the executor* — rejected: same word for pre- and post-validation
  values invites the exact confusion the contract exists to remove.

**Alternatives considered**:
- *Instance methods keep taking `(arguments, context)` as parameters, mirroring the old
  class methods 1:1* — rejected: defeats the point of the refactor (spec explicitly wants
  `def run` reading state via accessors, not parameters) and just relocates the same
  shape one level down.

## D4: Signal translation stays a `catch` at the class-level entry point

**Decision**: The class-level `run`/`undo`/`compensate` wrap the instance-method call in
`catch(StepSignals::TAG) { ... }` (for `run`, validation happens *before* entering the
catch, so an `InputValidationError` still raises rather than being confused with a
signal). The executor's and compensation manager's existing outer catches around
`step_config.impl.*` stay in place unchanged; the two levels nest safely because
`catch`/`throw` resolve at the innermost matching tag, and the outer ones still do the
real work for inline `run_block`/`compensate_block`/`undo_block` steps.

**This is not merely redundant — it fixes a latent bug.** `StepWorker#execute_step_body`
(`lib/ruby_reactor/step_worker.rb`) calls `step_config.impl.run(arguments, context)` with
**no** `catch(StepSignals::TAG)` at all (verified: the file contains no `catch`). Today a
`fail!`/`success!`/`skip!`/`halt!` inside a class step executed by the `async_step` /
`background` worker escapes as `UncaughtThrowError`, which is a `StandardError`, so the
worker's `rescue StandardError` reports a Failure wrapping the wrong error (and marks it
retryable). Moving the catch into the base class makes class steps behave identically on
the worker path with no worker change — this is exactly spec User Story 2 scenario 2.
Consequences carried into tasks.md:

- A red test first: a class step calling `fail!("x")` under `async_step` must yield
  `Failure("x")`, not a Failure wrapping `UncaughtThrowError`.
- Inline `run_block` steps on the worker path remain uncaught. That is pre-existing, out
  of scope (spec FR-013: inline blocks "keep working unchanged"), and gets a one-line note
  in `CHANGELOG.md`'s known-issues or a follow-up issue — not silently ignored.
- The comment in `lib/ruby_reactor/step_signals.rb` listing the catch sites
  (`step_executor.rb`, `compensation_manager.rb`) is stale; update it to name
  `RubyReactor::Step`'s entry points as the catch site for class steps.

**Rationale**: Spec FR-007 requires signals to be "translated at the class-level entry
point," a property of `RubyReactor::Step`'s own three methods, not of any caller. Owning
the catch in the base class is what makes every current and future call site (executor,
worker, direct call in a unit test) behave the same without each remembering to wrap.

**Alternatives considered**:
- *Remove the executor-level catch since it becomes dead code for class-based steps* —
  rejected: it is not dead for inline block steps, and removing working code the feature
  doesn't require touching is the kind of speculative churn Principle V rules out.
- *Add a `catch` to the worker instead of the base class* — rejected: fixes one caller,
  leaves the next one (a direct `MyStep.run` in a unit test, a future dispatcher) to
  rediscover the bug; FR-007 puts the responsibility on the step class.

## D5: Default `undo`/`compensate` and "must implement" error

**Decision**: The base class's own instance-level `undo`/`compensate` return
`RubyReactor.Skipped()` (today's default, moved from the `ClassMethods` module verbatim).
The base class's instance-level `run` raises `NotImplementedError` naming the subclass
(`"#{self.class} must implement #run"`), preserving today's message shape
(`"#{self} must implement .run method"`) with `.` replaced by `#` to reflect that it is
now an instance method.

**Rationale**: Directly satisfies spec FR-009 and FR-010; minimizes behavior change for
every subclass that already relies on the "compensation/undo default to skip" contract
(every demo reactor and most spec support reactors do not define both).

**Alternatives considered**: None — this is a direct behavior-preserving port.

## D6: Migration scope for the three built-in steps

**Decision**: `ComposeStep`, `MapStep`, and `AsyncReactorStep` become
`class ComposeStep < RubyReactor::Step` etc., with their `self.run`/`self.compensate`/
`self.undo` bodies moved into instance `run`/`compensate`/`undo` methods that read
`inputs`/`context` (and `reason`/`result`) via the D3 accessors instead of method
parameters. Their `class << self; private; ...; end` helper methods (argument-building,
dispatch, deadlock detection, etc.) move to **private instance methods** — with two
exceptions that stay **public class methods** because they are called from outside the
step: `MapStep.build_mapped_inputs` and `MapStep.resolve_element`, used by
`lib/ruby_reactor/map/helpers.rb:32` for element workers. None of the three declare
`input`/`validate_inputs` today (they receive a pre-built `arguments` hash assembled by
the DSL layer, e.g. `arguments[:composed_reactor_class]`), so no input contract is added
for them — only the authoring shape changes.

`ComposeStep` additionally carries a dead `initialize(composed_reactor_class,
argument_mappings = {})` and two `attr_reader`s — nothing in `lib/`, `spec/`, or
`demo_app/` ever calls `ComposeStep.new` (verified by grep). It would shadow the base
class's `initialize(inputs, context, ...)`, so it is deleted, not migrated.

**Rationale**: Spec FR-014 requires this; these three are the only "library-internal
steps" that used the mixin form (verified: an anchored `grep -rn "include RubyReactor::Step$"`
across `lib/` hits exactly these three files — an unanchored grep also matches
`include RubyReactor::StepSignals` in `step.rb` and `dsl/template_helpers.rb`, which are
not migrations). Converting private class helpers to private instance methods is a
mechanical, behavior-preserving move — that logic only ever received `arguments`/`context`
as explicit parameters. `MapStep` is the largest diff (~300 lines) and should be its own
task with the existing `spec/ruby_reactor/step/map_step_spec.rb` and `spec/map/` suites
as the red/green gate.

**Alternatives considered**:
- *Leave the three built-in steps on a separate, lighter-weight internal mixin instead of
  the public `RubyReactor::Step` base class* — rejected: spec FR-014 is explicit these
  migrate too, and a second internal-only step-authoring mechanism reintroduces the exact
  "two ways to build a step" variance the spec's Assumptions section rules out.

## D7: Inline block steps (reactor DSL `step ... do |args, ctx| ... end`)

**Decision**: Untouched. Inline block steps are stored as `run_block`/`compensate_block`/
`undo_block` procs on `StepConfig` (see `dsl/step_builder.rb`) and invoked directly by the
executor/compensation manager, never through `RubyReactor::Step`. They already get
`StepSignals` via `include RubyReactor::StepSignals` in `dsl/template_helpers.rb`. Nothing
here changes their behavior or signature.

**Rationale**: Spec explicitly scopes inline blocks as "keep working unchanged" (FR-013,
Edge Cases). They are a different authoring surface (a block, not a class) and were never
affected by the `singleton_class.prepend` workaround this feature removes.

## D8: Migration inventory (counts by anchored grep, for tasks.md sizing)

Pattern: `grep -rn "include RubyReactor::Step$"` (anchored — the unanchored form also
matches `StepSignals`). Counted 2026-09-11; `/speckit-tasks` re-runs it.

| Area | Files | Occurrences | Notes |
|---|---|---|---|
| `lib/ruby_reactor/step/` | 3 | 3 | the built-ins (D6) |
| `spec/` | 13 | 34 | `spec/support/reactors/*.rb` shared steps + per-spec inline classes |
| `demo_app/app/reactors/` | 3 | 7 | `validated_user_step.rb` (1), `user_etl_reactor.rb` (5), `reserve_inventory.rb` (1) |
| `demo_app/spec/` | 2 | 6 | |
| `README.md` | 1 | 5 | |
| `documentation/` | 7 | 28 | `getting_started`, `core_concepts`, `composition`, `async_reactors`, `README`, `examples/order_processing`, `examples/payment_processing` |

- No gem dependency changes, no `Gemfile`/`gemspec` edits required.
- Version bump: `.release-please-config.json` sets `bump-minor-pre-major: true`, so a
  `feat!:` / `BREAKING CHANGE:` commit takes 0.7.0 → **0.8.0**, not 1.0.0. The
  `CHANGELOG.md` entry still goes under a breaking-change heading with a before/after
  example (spec FR-015); the number is release-please's business.

## D9: `module Step` becomes `class Step` — every reopening must change together

**Decision**: All five files that currently open `module RubyReactor::Step` —
`step.rb`, `step/input_contract.rb`, `step/compose_step.rb`, `step/map_step.rb`,
`step/async_reactor_step.rb` — switch to `class Step` in the same commit. The nested
constants keep their names (`RubyReactor::Step::InputContract`,
`RubyReactor::Step::ComposeStep`, `RubyReactor::Step::MapStep`,
`RubyReactor::Step::AsyncReactorStep`), so the five `lib/` references
(`dsl/compose_builder.rb`, `dsl/map_builder.rb`, `dsl/async_reactor_builder.rb`,
`dsl/step_builder.rb`, `map/helpers.rb`) and two `spec/` references are untouched.

**Rationale**: Ruby raises `TypeError: Step is not a module` the moment a `module Step`
reopening loads after `class Step` (or the reverse), so a partial conversion cannot even
boot — this is a hard ordering constraint, not a style choice. Keeping the built-in steps
nested inside their own parent class (`class Step; class MapStep < Step`) is legal, a
little unusual to read, and the smallest diff; the three built-ins are internal plumbing
addressed by the DSL builders, never by users, so the namespace is not a public-API
concern.

**Alternatives considered**:
- *Move the built-ins to a sibling namespace (`RubyReactor::Steps::MapStep`)* — rejected
  for this change: seven reference edits plus rename churn for zero user-visible benefit.
  Worth revisiting only if a fourth built-in step appears (Principle V).

## Outcome

All unknowns resolved. No `NEEDS CLARIFICATION` remains. Proceeding to Phase 1.
