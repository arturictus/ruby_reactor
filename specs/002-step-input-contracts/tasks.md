---

description: "Task list for Step Input Contracts"
---

# Tasks: Step Input Contracts

**Input**: Design documents from `specs/002-step-input-contracts/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/dsl-surface.md, quickstart.md

**Tests**: REQUIRED. Constitution III makes test-first mandatory. Write each story's specs, watch
them fail, then implement. Real Redis always (`docker compose up -d redis-test`). The async worker
claim uses the live lane (`for_each_real_async_backend` from `spec/support/real_async_backend.rb`).
`Sidekiq::Testing.inline!` is not allowed in these specs.

**Organization**: Grouped by user story. The plan's Phase 2 outline maps as: plan 1 → Phase 2,
plans 2–3 → US1, plan 4 → US2, plan 5 → US3, plan 6 → US4, plan 7 → US5, plan 8 → Polish.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: User story the task belongs to (US1–US5)

## Findings from the code that the tasks below encode

Read these before starting. Each was found in the current code and is not in plan.md, or it
corrects plan.md.

1. **Zeitwerk naming.** `Zeitwerk::Loader.for_gem` (`lib/ruby_reactor.rb:37`) maps
   `utils/fetch_indifferent.rb` to the constant `RubyReactor::Utils::FetchIndifferent`. research D8's
   `RubyReactor::Utils.fetch_indifferent(...)` module function would fail eager loading. Use
   `RubyReactor::Utils::FetchIndifferent.call(hash, key)`, which matches
   `Utils::BacktraceLocation.parse` (T003).
2. **A subclass's `def self.run` skips a wrapper prepended onto its parent.** The singleton
   ancestry of `class Child < ParentStep` is `[Child.singleton, <wrapper>, ParentStep.singleton, ...]`,
   so `Child.run` runs before the parent's prepended wrapper. `Step::ClassMethods#inherited` has to
   prepend the wrapper onto every subclass's singleton class too (T010). A child that calls `super`
   validates twice. That is harmless: validation is idempotent and defaults are already applied.
3. **`args_validator` cannot apply defaults.** `validate_step_arguments` (`step_executor.rb:312`)
   discards the validated value. Switching it to use `result.to_h` would change behavior for
   existing validators, because `Dry::Schema.Params` coerces values and drops undeclared keys. So
   inline contracts do **not** compile to `args_validator`, which supersedes research D4. They are
   enforced by the same `InputContract#enforce!` call the class wrapper uses, at the two run-block
   call sites (`StepExecutor#run_step_implementation`, `StepWorker#execute_step_body`). That leaves
   one enforcement method called from three places instead of two mechanisms, and SC-005
   equivalence holds by construction (T020, T023).
4. **The step receives the resolved values, never the schema's coerced output.** This matches
   today's `validate_step_arguments`. `enforce!` returns `args` merged with defaults, not
   `result.to_h`.
5. **The worker process needs the inferred wiring too.** D7 appends inferred wirings to
   `StepConfig#arguments` inside `validate_definition!`. `StepWorker` runs in a fresh process and
   resolves arguments directly (`step_worker.rb:150`) without building an `Executor`. If nothing in
   that process calls `validate_definition!`, a name-resolved class step receives `{}` in the
   worker and fails with "is missing". `validate_definition!` is therefore called from
   `Reactor#run`, `Executor#initialize` (resume, map, compose, background workers), and
   `StepWorker#perform_unit` (T028). It is memoized, so the extra calls cost nothing.
6. **Step attribution is overwritten, not `||=`.** For direct invocation (FR-022), the wrapper
   stamps `step_name` with the step class's name. Inside a reactor, the executor must then
   **overwrite** it with the reactor's step name (`:charge`, not `"ChargeStep"`). research D3's
   `e.step_name ||= step_config.name` would keep the class name (T012).
7. **`Failure` never redacts `step_arguments`.** `Failure#append_step_arguments`
   (`lib/ruby_reactor.rb:274`) prints every value, and `run_step_implementation` writes raw
   arguments into the execution trace, which the dashboard reads. FR-015 is met by masking at the
   source: `enforce!` puts a redacted copy on `error.step_arguments`, and the trace entry uses
   `input_contract.redact(arguments)` (T008, T012).
8. **Validation failures in the worker are retried and lose their shape.**
   `StepWorker#execute_step_body` wraps every exception in a generic `Failure(e)`, which is
   retryable by default, so `retry?` would loop. The new `InputValidationError` branch must pass
   `retryable: false` and `validation_errors:` (T015).
9. **Fixture files load with the whole suite.** `spec_helper.rb:56` requires
   `spec/support/**/*.rb`. A fixture that calls `input` before the DSL exists breaks loading for
   every spec. Fixtures that use the new DSL are created only after the DSL task they depend on
   (T013 after T009, T022 after T019). Everything else is defined inline in the spec with
   `stub_const`/`Class.new`.
10. **Class steps get no implicit inputs today** (research Finding 1). Until US4 lands, US1–US3
    specs must wire every input with an explicit `argument :x, input(:x)`.
11. **`InterruptBuilder < StepBuilder`** (`dsl/interrupt_builder.rb:5`). Interrupt steps would
    inherit `inputs`, and `InterruptBuilder#build` would silently drop the contract. Override it to
    raise (T021).
12. **Existing deprecation idiom:** `warn "[RubyReactor] DEPRECATION: ..."` guarded by an ivar
    (`dsl/reactor.rb:107`, `dsl/interrupt_builder.rb:40`). Don't use `warn(category: :deprecated)`:
    Ruby hides that category by default, which would make the FR-011 notice invisible (T030).

## Shared names used across tasks

- `RubyReactor::Step::InputContract` in `lib/ruby_reactor/step/input_contract.rb`. Includes
  `Dsl::ValidationHelpers`, so step classes don't gain those helper methods.
- `InputContract::Declaration = Struct.new(:name, :type, :optional, :default, :redact, :predicates,
  :macro_block, :schema, :validator, keyword_init: true)`. Use `Struct`, not `Data`: Ruby >= 3.0.
- `InputContract` API: `#input(name, type = nil, optional: false, default: nil, redact: false,
  validate: nil, **predicates, &block)`, `#validate_inputs(schema = nil, &block)`, `#declarations`
  (ordered `Hash{Symbol => Declaration}`), `#declares?(name)`, `#required_names`, `#optional_names`,
  `#defaults`, `#redacted_names`, `#empty?`, `#merge(child)` (returns a new contract, used for
  inheritance), `#redact(args)` (copy with redacted names → `"[REDACTED]"`), and
  `#enforce!(args)`. `enforce!` returns `args` plus defaults, or raises
  `Error::InputValidationError` with `field_errors`, `step_arguments = redact(args)`, and
  `step_name` left for the caller to stamp.
- Step class API: `input`, `validate_inputs`, `input_contract`, `declared_inputs`,
  `required_input_names`, `declares_inputs?`. `RubyReactor::Step::InputEnforcement` is the module
  prepended onto the singleton class.
- `StepConfig#inline_contract` (from `inputs do`, nil otherwise) and `StepConfig#input_contract`
  (`inline_contract` if present, else `impl.input_contract` when `impl` declares inputs, else nil).
- `StepConfig#arguments` entries gain `origin:` (`:explicit` from `argument`, `:inferred` from
  name-based resolution).
- `RubyReactor::Utils::FetchIndifferent.call(hash, key)` returns
  `hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key.to_s]`.
- Fixture file for the live worker: `spec/support/reactors/step_contract_reactors.rb`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Record where the suite stands before anything changes

- [X] T001 Run `docker compose up -d redis-test`, then `bundle exec rspec` and `bundle exec rubocop` on the untouched branch. Save the example/failure/pending counts and the rubocop offense count to `specs/002-step-input-contracts/baseline.txt`. SC-006 is checked against this file at the end (T031, T041)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Presence-correct value resolution (FR-023) and one shared validator dispatch. US1 AS6
and every default depend on the first; `InputContract` depends on the second.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T002 [P] Write `spec/ruby_reactor/falsey_input_resolution_spec.rb` (red). Cases, each asserting the step body receives exactly `false`, not nil: (a) reactor input `flag: false` → inline step `argument :flag, input(:flag)`; (b) same reactor input → class step `ReceivesFlag` (plain `include RubyReactor::Step`, no contract, defined with `stub_const`); (c) prior step returns `false`, next step wires `argument :flag, result(:first)`; (d) nested paths `input(:config, :notify)`, `input(:config, [:a, :notify])`, `result(:first, :flag)` with a `false` leaf; (e) `RubyReactor::Context#get_input` and `#get_result` for a symbol-keyed `false` and a string-keyed `false`; (f) the private `Template::Result#fetch` (call via `send`) on `{ success: false }` and `{ "success" => false }`; (g) `ContextSerializer.deserialize(ContextSerializer.serialize(ctx)).get_input(:flag) == false` for the serialization round trip. Also assert `0`, `""`, `[]` survive in (a)
- [X] T003 [P] Create `lib/ruby_reactor/utils/fetch_indifferent.rb` defining `RubyReactor::Utils::FetchIndifferent` with `def self.call(hash, key) = hash.key?(key.to_sym) ? hash[key.to_sym] : hash[key.to_s]`. The class name follows Zeitwerk (Finding 1). No spec of its own: T002 covers it
- [X] T004 Replace the `a || b` lookups with `Utils::FetchIndifferent.call` in `RubyReactor::Context#get_input` (`lib/ruby_reactor/context.rb:67`), `#get_result` (`context.rb:79`), and `Template::Result#fetch` (`lib/ruby_reactor/template/result.rb:177`). Keep `return nil if value.nil?` as is. T002 goes green and the rest of the suite stays at baseline (depends on T003)
- [X] T005 [P] Move the form dispatch out of `Dsl::Reactor::ClassMethods#build_input_validator_for` (`lib/ruby_reactor/dsl/reactor.rb:91`) into a public `build_declaration_validator(name, type, optional, validate, predicates, &block)` in `lib/ruby_reactor/dsl/validation_helpers.rb`. The reactor method keeps only its reactor-specific part, `warn_deprecated_input_block` when `block&.arity&.zero?`, and delegates the rest. This is a pure refactor: `spec/ruby_reactor/validations_spec.rb` must stay green unchanged (FR-009)

**Checkpoint**: `false` reaches steps intact; one validator dispatch serves reactor inputs and, next, step contracts

---

## Phase 3: User Story 1 - A step class declares its own input contract (Priority: P1) 🎯 MVP

**Goal**: `input :x, :type, **rules` inside a step class, enforced before `run` on every
execution path (inline, retry, map, `background`, `async_step` worker, direct call). Failures use
the existing `InputValidationError` → rollback → `build_validation_failure` protocol.

**Independent Test**: A step class with a typed, bounded contract, run from a minimal reactor
that wires inputs with explicit `argument` lines and declares no rules. Conforming values succeed.
Violating values fail with `validation_errors` and `step_name`, and the body never runs.

### Tests for User Story 1 ⚠️

> Write these first and confirm they fail before implementation.

- [X] T006 [P] [US1] Write `spec/ruby_reactor/dsl/step_input_contract_spec.rb` (red), covering declaration and introspection, with fixtures defined inline via `stub_const`: Forms 0/1/1b/1-opt/2/3 from `contracts/dsl-surface.md` §1 each appear in `declared_inputs` with the right `type`/`optional`/`predicates`/`macro_block`/`schema`; `required_input_names` returns the non-optional names in declaration order; `declares_inputs?` is false for a plain step and for `RubyReactor::Step::MapStep`, `ComposeStep`, `AsyncReactorStep` (research Finding 6); redeclaring a name replaces the earlier one; inheritance: the child's contract is the parent's plus its own, a same-named child input replaces the parent's, and the parent's contract is unchanged; `validate_inputs` blocks from parent and child both apply; `input :x, default: 1` without `optional: true` raises `RubyReactor::Error::ValidationError` at the `input` call; `input` raises `LoadError` with the existing install message when `Dry::Schema` is hidden (`hide_const("Dry::Schema")`); enforcement survives (a) `def self.run` written after `include` and (b) a subclass defining its own `def self.run` (Finding 2). For (b), call `Child.run({}, ctx)` with an invalid value and expect `InputValidationError`
- [X] T007 [P] [US1] Write `spec/ruby_reactor/step_contract_enforcement_spec.rb` (red), covering sync execution paths with explicit `argument` wiring (Finding 10). Record body calls in a local array. Cases: US1 AS1–AS6, where AS6 is `input :notify, :bool` receiving `false`; a failure's `validation_errors` has each offending field, `step_name == :charge` (the reactor step name, Finding 6), `reactor_name` is set, and the body array is empty; `test_reactor(...)` + `have_validation_error(:amount)` matches; a completed prior step with `compensate` is rolled back (saga); a step with `retries max_attempts: 3` validates once and its body is never attempted; direct call `Step.run({ amount: 0 }, ctx)` raises `InputValidationError` with `step_name == "<StepClass>"` and the same `field_errors` as the reactor run (SC-010); `optional: true, default: "x"` applies for an absent key and for `nil`, not for `false`; `redact: true` shows `"[REDACTED]"` in `failure.step_arguments`, in `failure.message`, and in the `:run` execution-trace entry's `arguments`; a `map` over the class step fails when one element violates the contract; a step whose `where` is false produces no validation error; the same class used under two step names is validated independently for each

### Implementation for User Story 1

- [X] T008 [US1] Create `RubyReactor::Step::InputContract` in `lib/ruby_reactor/step/input_contract.rb` per Shared names. `input` calls `check_dry_validation_available!` eagerly, raises `Error::ValidationError` for `default:` without `optional: true`, stores a `Declaration`, and resets the memoized validators. The per-declaration validator comes from `build_declaration_validator` (T005). `enforce!(args)`: (1) apply defaults where the key is absent or the value is `nil` (never for `false`); (2) for each declaration with a validator, skip it when optional and the key is absent, otherwise call `validator.call({ name => value })` and merge `field_errors`, the same shape as `Dsl::Reactor::ClassMethods#validate_inputs` (`dsl/reactor.rb:182`); (3) run each `validate_inputs` block/schema (`create_input_validator`) over the whole hash, last, merging its errors over earlier ones; (4) on errors raise `Error::InputValidationError.new(errors)` with `step_arguments = redact(args)`; (5) otherwise return the args-with-defaults hash itself, not the schema output (Finding 4). `merge(child)` returns a new contract with `declarations.merge(child.declarations)` and both block lists concatenated
- [X] T009 [US1] In `lib/ruby_reactor/step.rb`, add to `Step::ClassMethods`: `input(...)` and `validate_inputs(...)` delegating to an own-class contract (`@own_input_contract ||= InputContract.new(owner: self)`); `input_contract` (superclass's `input_contract.merge(own)` when the superclass declares inputs, else own; memoized, and the memo is cleared by `input`/`validate_inputs`); `declared_inputs` (`input_contract.declarations`); `required_input_names`; `declares_inputs?` (`!input_contract.empty?`)
- [X] T010 [US1] In `lib/ruby_reactor/step.rb`, add `Step::InputEnforcement` with `def run(arguments, context)`: return `super` when `!declares_inputs?`; otherwise call `super(input_contract.enforce!(arguments), context)`, rescuing `Error::InputValidationError` to set `e.step_name = name` and re-raise. Prepend it in `Step.included(base)` (`base.singleton_class.prepend(InputEnforcement)`) and in a new `ClassMethods#inherited(subclass)` (`super` then prepend onto `subclass.singleton_class`) (Finding 2). `compensate`/`undo` are not wrapped (contract §7) (depends on T008, T009)
- [X] T011 [US1] In `lib/ruby_reactor/dsl/step_builder.rb`, add `StepConfig#input_contract` returning `impl.input_contract` when `impl.respond_to?(:declares_inputs?) && impl.declares_inputs?`, else nil. US3 extends it to inline contracts
- [X] T012 [US1] In `lib/ruby_reactor/executor/step_executor.rb`: (a) in `safe_execute_step_sync`'s `rescue Error::InputValidationError` (line 186), capture `=> e`, set `e.step_name = step_config.name` (overwrite, Finding 6) and `e.step_arguments ||= resolved_arguments`, then re-raise; (b) in `run_step_implementation`, write `arguments: step_config.input_contract ? step_config.input_contract.redact(arguments) : arguments` into the `:run` trace entry (Finding 7). T006 and T007 go green (depends on T010, T011)
- [X] T013 [US1] Create `spec/support/reactors/step_contract_reactors.rb` for the live worker (requires T009, Finding 9). Define `ContractChargeStep` (`input :amount, :integer, gteq?: 1`; `input :currency, :string, included_in?: %w[USD EUR]`; body returns `Success(args)`), `ContractAsyncStepReactor` (inputs `amount`, `currency`; `async_step :charge, ContractChargeStep` with explicit `argument` lines and `retries max_attempts: 3`; `step :confirm` with `argument :charge, result(:charge)` whose body returns `args[:charge]`, so a Failure from the worker becomes this reactor's failure, following `AsyncStepDemoReactor`'s reader pattern), and `ContractBackgroundReactor` (`background all: true`, one step using `ContractChargeStep`)
- [X] T014 [US1] Write `spec/ruby_reactor/step_contract_async_spec.rb` (red) using `for_each_real_async_backend`: `ContractAsyncStepReactor.run(amount: 0, currency: "USD")`. After the worker finishes (follow the waiting pattern in existing `for_each_real_async_backend` specs), the reactor's failure carries `validation_errors` with `:amount`, `step_name == :charge`, and `retryable == false`, and the worker attempted validation once (no retry). `amount: 5` succeeds. `ContractBackgroundReactor` with `amount: 0` fails the same way inside the hand-off worker (FR-003) (depends on T013)
- [X] T015 [US1] In `lib/ruby_reactor/step_worker.rb#execute_step_body`, add `rescue Error::InputValidationError => e` before the existing `rescue StandardError`, returning `RubyReactor.Failure(e, validation_errors: e.field_errors, step_name: @step_name, step_arguments: e.step_arguments || {}, reactor_name: @reactor_class_name, retryable: false)` (Finding 8). Class steps are already validated by the prepended `run`. T014 goes green (depends on T014)

**Checkpoint**: A step class owns its rules. Every execution path enforces them, and failures are attributed and redacted. MVP is shippable here.

---

## Phase 4: User Story 2 - The reactor wires values without redeclaring rules (Priority: P1)

**Goal**: For a contract-owning step, `argument` is wiring only. Rules in the reactor, or wiring for
an undeclared input, fail at the `step` macro (FR-006, FR-018).

**Independent Test**: A mapping-only reactor over a contract-owning step loads and runs. Adding a
typed `argument` or `validate_args` makes the class body raise, and the message names the reactor,
step, argument, and owning class.

### Tests for User Story 2 ⚠️

- [X] T016 [P] [US2] Write `spec/ruby_reactor/dsl/step_contract_conflict_spec.rb` (red). Each case builds a reactor with `Class.new(RubyReactor::Reactor) { ... }` and `stub_const` so the name is stable. Cases: a mapping-only reactor (`argument :amount, input(:amount)`, with and without `transform:`) loads and the step's contract governs at run time (AS1); `argument :amount, input(:amount), :integer` raises `RubyReactor::Error::ValidationError` whose message includes the reactor name, `:charge`, `:amount`, and the step class name (AS2); a predicates-only `argument :amount, input(:amount), gt?: 0` raises the same; `validate_args do ... end` raises the same class of error (AS3); `argument :bogus, value(1)` raises naming `:bogus` (FR-018); `async_step :charge, ChargeStep` with a typed argument raises identically; a step class with **no** contract plus a typed `argument` loads and enforces the reactor's rule (AS4, unchanged behavior)

### Implementation for User Story 2

- [X] T017 [US2] In `lib/ruby_reactor/dsl/step_builder.rb#build`, before creating the `StepConfig`, when `@impl.respond_to?(:declares_inputs?) && @impl.declares_inputs?`: raise `Error::ValidationError` if `@arg_validations` is non-empty (name the first offending argument) or `@validate_args_input` is set, and if any `@arguments` key is not in `@impl.input_contract.declarations`. Message (FR-006): `"#{reactor_label} step :#{@name} declares rules on argument :#{arg}, but #{@impl} owns its input contract. Move the rule into #{@impl} (`input :#{arg}, ...`) and keep only the wiring here: `argument :#{arg}, <source>`."`. Unknown argument (FR-018): `"#{reactor_label} step :#{@name} wires argument :#{arg}, which #{@impl} does not declare. Declared inputs: #{names}."`. Add a private `reactor_label` (`@reactor&.name || @reactor.inspect`). T016 goes green

**Checkpoint**: Wiring and rules are split for class steps, and conflicts are caught when the reactor class body runs.

---

## Phase 5: User Story 3 - Inline steps keep a single, coherent place for rules (Priority: P1)

**Goal**: `inputs do input ...; validate_inputs ... end` inside a `step` block. The lines are
identical to a step class's, and enforcement goes through the same `InputContract#enforce!`
(Finding 3).

**Independent Test**: The same declarations as an inline `inputs` block and as a step class, run
over the same conforming and violating inputs, give identical `success?`, value, and
`validation_errors`.

### Tests for User Story 3 ⚠️

- [X] T018 [P] [US3] Write `spec/ruby_reactor/dsl/inline_step_contract_spec.rb` (red). Cases: an inline `inputs` block with `input :amount, :integer, gteq?: 1`, `input :currency, :string, included_in?: %w[USD EUR]`, and a `validate_inputs` cross-field block fails with the same failure shape as the class form (AS1); the equivalence table (SC-005): for each input set in `[{amount: 5, currency: "USD"}, {amount: 0, currency: "USD"}, {amount: 5, currency: "JPY"}, {amount: 20_000, currency: "EUR"}]`, the inline reactor and a reactor using the same lines pasted into a step class give equal `success?`, value, and `validation_errors` (AS2); inside the `step` block but outside `inputs`, `input(:amount)` still returns a `Template::Input` (research Finding 4); defaults and `redact:` behave as in T007; conflicts raise `Error::ValidationError`: `inputs` inside `step :x, SomeStepClass`, `inputs` plus a typed `argument`, `inputs` plus `validate_args`, and an `argument` naming an undeclared input; `inputs do ... end` inside an `interrupt` block raises and points at `validate_payload`

### Implementation for User Story 3

- [X] T019 [US3] In `lib/ruby_reactor/dsl/step_builder.rb`: add `StepBuilder#inputs(&block)` that raises `Error::ValidationError` when `@impl` is set (`"`inputs` is for inline steps; declare `input` inside #{@impl}"`), otherwise builds `@inline_contract = Step::InputContract.new(owner: @name)` and `instance_eval`s the block on it. Pass `inline_contract:` into `StepConfig`, add the `StepConfig#inline_contract` reader, and change `StepConfig#input_contract` (T011) to return `inline_contract` when present. Extend T017's checks to inline contracts: typed `argument`/`validate_args` plus `inputs` raises, and an `argument` not declared in `inputs` raises (depends on T017)
- [X] T020 [US3] In `lib/ruby_reactor/executor/step_executor.rb#run_step_implementation`, in the `has_run_block?` branch, set `args_to_pass = step_config.inline_contract.enforce!(args_to_pass) if step_config.inline_contract` before `run_block.call`. T012(a) stamps the step name. T018 goes green (depends on T019)
- [X] T021 [US3] In `lib/ruby_reactor/dsl/interrupt_builder.rb`, override `inputs` to raise `Error::ValidationError`: `"interrupt :#{@name} does not take an `inputs` contract; validate the resume payload with `validate_payload`."` (Finding 11)
- [X] T022 [US3] Add `ContractInlineAsyncReactor` to `spec/support/reactors/step_contract_reactors.rb` (an `async_step :charge` with an `inputs` block matching `ContractChargeStep`, explicit `argument` lines, and the same `:confirm` reader). Add an example to `spec/ruby_reactor/step_contract_async_spec.rb` asserting the worker-side failure matches T014's, then confirm it fails (depends on T019)
- [X] T023 [US3] In `lib/ruby_reactor/step_worker.rb#execute_step_body`, in the `has_run_block?` branch, set `args = step_config.inline_contract.enforce!(args) if step_config.inline_contract`. T015's rescue produces the failure. T022 goes green (depends on T022)

**Checkpoint**: Inline and class steps share one vocabulary and one enforcement method, on every path.

---

## Phase 6: User Story 4 - Missing wiring is caught when the reactor is defined (Priority: P2)

**Goal**: A declared input with no `argument` resolves from the same-named reactor input. A
required input satisfied by neither raises before any step runs (FR-008, FR-020, FR-021).

**Independent Test**: `SignupReactor` (inputs matching the step's names, no `argument` lines) runs.
`IncompleteReactor` raises `Error::ValidationError` naming `:profile`, `:email`, and both remedies,
and no step has run.

### Tests for User Story 4 ⚠️

- [X] T024 [P] [US4] Write `spec/ruby_reactor/dsl/step_contract_wiring_spec.rb` (red). Cases: US4 AS1–AS6 for a class step; the same inference for an inline step with an `inputs` block; `Reactor.validate_definition!` is public and callable without running; the error message contains the reactor name, step name, input name, `argument :<input>, ...`, and `input :<input>`; the error is raised from `.run` before any step runs (a preceding step pushes to a local array, which stays empty) and from `test_reactor(...)`; inferred entries in `steps[:x].arguments` have `origin: :inferred` and `source` a `Template::Input` for the same name; explicit entries have `origin: :explicit` and are never replaced (AS6); step results are never consulted: a prior step named `:email` does not satisfy a missing `:email` input, which still raises; calling `validate_definition!` twice does not change `arguments.size`; a `test_reactor(...).mock_step(...)` run still resolves by name (TestSubject subclasses the reactor, `test_subject.rb:501`); FR-019: an inline step without a contract or arguments still receives all reactor inputs
- [X] T025 [P] [US4] Add `ContractNameResolvedAsyncReactor` to `spec/support/reactors/step_contract_reactors.rb` (inputs `amount`, `currency`; `async_step :charge, ContractChargeStep` with **no** `argument` lines; the `:confirm` reader). Add an example to `spec/ruby_reactor/step_contract_async_spec.rb` asserting `amount: 5` succeeds in the live worker and `amount: 0` fails with `validation_errors[:amount]`. This fails until T028 (Finding 5)

### Implementation for User Story 4

- [X] T026 [US4] In `lib/ruby_reactor/dsl/step_builder.rb#argument`, store `origin: :explicit` in the `@arguments[name]` hash alongside `source:` and `transform:`
- [X] T027 [US4] Add a public `validate_definition!` to `Dsl::Reactor::ClassMethods` in `lib/ruby_reactor/dsl/reactor.rb`. It returns immediately when `@definition_validated`. Otherwise, for each `steps` value that responds to `input_contract` and has a non-nil one, for each declared name: skip if `arguments.key?(name)`; else if `inputs.key?(name)`, add `arguments[name] = { source: Template::Input.new(name), transform: nil, origin: :inferred }`; else, if the input is required, raise `Error::ValidationError` with `"#{name || inspect} step :#{step} requires input :#{input}, which is neither wired nor a reactor input. Wire it (`argument :#{input}, input(:x)` / `result(:step)`) or declare `input :#{input}` on the reactor."`. Then set `@definition_validated = true`. Add `# ponytail: a reactor reopened after its first run is not re-checked`
- [X] T028 [US4] Call `validate_definition!` from three places (Finding 5): the first line of `RubyReactor::Reactor#run` (`lib/ruby_reactor/reactor.rb:88`), as `self.class.validate_definition!`, so it raises before the context is saved; `Executor#initialize` (`lib/ruby_reactor/executor.rb:21`), as `reactor_class.validate_definition! if reactor_class.respond_to?(:validate_definition!)`, before the dependency graph is built, which covers resume, background, map, and compose workers; and `StepWorker#perform_unit` (`lib/ruby_reactor/step_worker.rb:57`), as `context.reactor_class.validate_definition!` before the step lookup. T024 and T025 go green (depends on T026, T027)

**Checkpoint**: Reactors whose input names match their steps need no `argument` lines, and incomplete wiring fails before step one.

---

## Phase 7: User Story 5 - Existing reactors keep working through the transition (Priority: P2)

**Goal**: Rules on `argument`/`validate_args` for steps without a contract behave exactly as
before and print one deprecation notice per declaration site (FR-010, FR-011).

**Independent Test**: An unchanged reactor with typed arguments on an inline step returns the same
results and errors, and prints one `DEPRECATION` line per site.

### Tests for User Story 5 ⚠️

- [X] T029 [P] [US5] Write `spec/ruby_reactor/step_contract_deprecation_spec.rb` (red). Cases: defining a reactor with `argument :amount, input(:amount), :integer, gteq?: 1` on an inline step prints to stderr (`output(/\[RubyReactor\] DEPRECATION:.*step :charge.*argument :amount.*input :amount/).to_stderr`) and names the defining file and line; `validate_args` prints a notice naming `inputs do ... validate_inputs`; defining the same reactor twice from one call site (two `Class.new` calls in a loop) prints once; a class step with no contract plus a typed argument also prints, and its message names the class; conforming and violating runs of each reactor give the same `success?`, value, `validation_errors`, and `step_name` as before (AS1, AS2); a mapping-only `argument` prints nothing

### Implementation for User Story 5

- [X] T030 [US5] In `lib/ruby_reactor/dsl/step_builder.rb`, record `caller_locations(1, 1).first` in `argument` (when a type or predicates are given) and in `validate_args`. In `build`, after T017/T019's conflict checks pass, `warn` once per `"#{path}:#{lineno}"`, tracked in a `Set` held in a `StepBuilder` class-level ivar: `"[RubyReactor] DEPRECATION: #{path}:#{lineno} #{reactor_label} step :#{@name} declares rules on `argument :#{arg}`. Declare them on the step instead (`input :#{arg}, ...` in #{@impl || 'an `inputs do ... end` block'}) and keep `argument :#{arg}, <source>` for wiring. Removal no earlier than the next MAJOR."`. The `validate_args` variant points at `validate_inputs` (Finding 12). T029 goes green
- [X] T031 [US5] Run `bundle exec rspec` and compare with `specs/002-step-input-contracts/baseline.txt`. Every example that passed at baseline must still pass without edits (SC-006). Deprecation output is expected. The only allowed behavior change is FR-023: an example that asserted `false → nil` gets fixed and listed in the CHANGELOG Bug Fixes entry (T038)

**Checkpoint**: Upgrading changes nothing but stderr notices and the falsey fix.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Docs, changelog, and the constitution-required demo and acceptance run

**Constitution Principle VI — Demo-App Proof of Feature (required for any public API change):**

- [X] T032 [P] Create `demo_app/app/reactors/validated_user_step.rb` (`ValidatedUserStep`, following the `ReserveInventory` file precedent) with the exact contract from quickstart Scenario 1 (`name` min_size 2, `email`, `age` gteq 18, optional `bio` with default and max_size 100, `marketing_opt_in, :bool`). `run` logs via `Rails.logger` and returns `Success(args.merge(created_at: Time.current.iso8601))`
- [X] T033 [P] Create `demo_app/app/reactors/validated_signup_reactor.rb` (`ValidatedSignupReactor`: inputs `name`, `email`, `age`, `marketing_opt_in`; `step :profile, ValidatedUserStep` with no `argument` lines; `returns :profile`) and `demo_app/app/reactors/validated_signup_async_reactor.rb` (`ValidatedSignupAsyncReactor`: same inputs; `async_step :profile, ValidatedUserStep`; `step :welcome` reading `result(:profile)` and returning it). Neither reactor declares a rule (SC-001), and both reuse one step class (SC-002) (depends on T032)
- [X] T034 Register `demo:validated_signup` in `demo_app/lib/tasks/demo_reactors.rake` with a `desc` and `[:environment, :flush_redis]`, following `demo:signal_demo`'s `run_*` helper style. Print ✅/❌ lines for: a passing run (bio defaulted); `name: "A", age: 17` (print `validation_errors` and `step_name`); `marketing_opt_in: false` passing with `false` shown; the async variant failing inside the worker with the same `validation_errors`; and `ValidatedUserStep.run({ age: 17 }, nil)` rescued and printed (depends on T033)
- [X] T035 Write `demo_app/spec/reactors/validated_signup_reactor_spec.rb` (`type: :reactor`) using only `test_reactor`, `be_success`, `be_failure`, `have_validation_error`, `step_result`: the passing run and bio default; `have_validation_error(:name)` and `have_validation_error(:age)`; `marketing_opt_in: false` succeeds and `step_result(:profile)[:marketing_opt_in] == false`; the async variant (follow `demo_app/spec/reactors/async_step_demo_reactor_spec.rb`) fails with `have_validation_error(:age)`. If any assertion can't be expressed with the shipped surface, add the matcher to `lib/ruby_reactor/rspec/matchers.rb` in this change, never hand-rolled (depends on T033)
- [X] T036 Check `docker-compose.yml` (`demo-app`, `demo-sidekiq`, demo Redis). No new service or env var should be needed. If the async variant needs one, add it here (Constitution VI.4)

**Docs and release notes:**

- [X] T037 [P] Update `README.md`: in "Defining Steps" (line ~224), make the class-step example declare `input` lines. Rewrite "Step Argument & Output Validation" (line ~1021) to show the step-class contract first, the inline `inputs do` equivalent, the name-based resolution rule, the conflict and unknown-argument errors, the explicit "no per-reactor overrides: write two steps or relax the contract" note (spec Edge Cases), presence semantics (contract §9), and a migration block from `argument :x, src, :type, **rules` / `validate_args` to `input`/`validate_inputs`. Note that `validate_definition!` can run in an initializer or CI (FR-016)
- [X] T038 [P] Add to `CHANGELOG.md` under `## Unreleased`: **Features**, covering step input contracts (`input`/`validate_inputs` on step classes, `inputs do` for inline steps, name-based resolution, `validate_definition!`) plus the migration note and the deprecation of rules on `argument`/`validate_args` (removal no earlier than the next MAJOR); **Bug Fixes**, noting that a supplied `false` reactor input or step result no longer resolves to `nil` (`Context#get_input`, `#get_result`, `Template::Result#fetch`)

**Verification:**

- [X] T039 Run `bundle exec rubocop` with no `--disable-pending-cops`. The offense count must not exceed the baseline in `specs/002-step-input-contracts/baseline.txt`, and there are no new offenses in touched files
- [X] T040 Run the docker acceptance: `docker compose up -d demo-redis demo-sidekiq`, `docker compose run --rm demo-app bin/rails demo:validated_signup` (every printed line matches T034's expectations), and `docker compose run --rm demo-app bundle exec rspec spec/reactors/validated_signup_reactor_spec.rb` (SC-008)
- [X] T041 Walk quickstart.md Scenarios 1–6 and its acceptance checklist SC-001…SC-011, ticking each against the spec or demo output that proves it. Run the full `bundle exec rspec` one final time and compare it with the baseline

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies
- **Foundational (Phase 2)**: Depends on T001. Blocks all stories (US1 AS6 and defaults need T004; `InputContract` needs T005)
- **US1 (Phase 3)**: Depends on Phase 2
- **US2 (Phase 4)**: Depends on US1 (`declares_inputs?`, `input_contract` on step classes)
- **US3 (Phase 5)**: Depends on US1 (`InputContract`, T012 stamping, T015 worker rescue) and US2 (T019 extends T017's checks)
- **US4 (Phase 6)**: Depends on US1. Its inline-step case also needs US3's T019
- **US5 (Phase 7)**: Depends on US2 and US3 (the notice is emitted only after their conflict checks pass)
- **Polish (Phase 8)**: T032–T036 need US1 + US4 (the demo reactor has no `argument` lines). T037–T041 need all stories

### User Story Dependencies

```text
Phase 2 ──► US1 ──► US2 ──► US3 ──► US5
              │                 ▲
              └──────► US4 ─────┘ (inline case only)
```

### Within Each User Story

- Spec task first, confirmed red, then implementation, then green
- `step.rb` tasks (T009 → T010) are sequential: same file
- `step_builder.rb` tasks (T011, T017, T019, T026, T030) are sequential across phases: same file
- `step_contract_reactors.rb` / `step_contract_async_spec.rb` (T013, T014, T022, T025) are sequential: same files

### Parallel Opportunities

- Phase 2: T002, T003, T005 together (then T004 after T003)
- US1: T006 ∥ T007 (both red before any lib change)
- US2 ∥ US4 test writing: T016 ∥ T024 ∥ T025 once US1 is green
- US4 T024 ∥ US3 T018 (different spec files)
- US5: T029 can be written any time after US1
- Polish: T032 ∥ T037 ∥ T038, then T033 → T034/T035

---

## Parallel Example: User Story 1

```bash
# Both red specs at once:
Task: "T006 Write spec/ruby_reactor/dsl/step_input_contract_spec.rb (declaration, introspection, inheritance, subclass wrapping)"
Task: "T007 Write spec/ruby_reactor/step_contract_enforcement_spec.rb (sync paths, attribution, redaction, rollback, direct call)"

# After US1 is green, the next stories' specs at once:
Task: "T016 Write spec/ruby_reactor/dsl/step_contract_conflict_spec.rb"
Task: "T018 Write spec/ruby_reactor/dsl/inline_step_contract_spec.rb"
Task: "T024 Write spec/ruby_reactor/dsl/step_contract_wiring_spec.rb"
Task: "T029 Write spec/ruby_reactor/step_contract_deprecation_spec.rb"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. T001 baseline → Phase 2 (falsey fix + shared dispatch)
2. Phase 3: step-class contracts enforced on every path, including the live worker
3. **STOP and VALIDATE**: T006, T007, T014 green. Full suite at baseline
4. Shippable on its own: authors can move rules into step classes, and reactors using them wire
   inputs with explicit `argument` lines

### Incremental Delivery

1. + US2 → reactor-side conflicts rejected (the ambiguity the feature exists to remove)
2. + US3 → inline steps get the same vocabulary. The equivalence spec pins both forms
3. + US4 → name-based wiring and fail-before-step-one satisfiability
4. + US5 → deprecation notices. Migration is documented
5. Polish → demo app, README, CHANGELOG, docker acceptance

---

## Notes

- [P] = different files, no dependency on an incomplete task
- Run `docker compose up -d redis-test` before any spec. `spec_helper` aborts without Redis
- The deviations from research.md, D4 (no `args_validator` for inline contracts) and D3
  (overwrite, not `||=`), are explained in Findings 3 and 6. Reflect them in plan.md's Complexity
  Tracking row if a reviewer asks: there is now one enforcement method, not two mechanisms
- Commit after each green checkpoint
