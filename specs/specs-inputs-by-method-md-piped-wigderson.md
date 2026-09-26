# Plan: `inputs.order_id` (implement specs/inputs_by_method.md)

## Context

`Step#inputs` is a plain Hash, so a typo like `inputs[:order_id]` (declared `:order_guid`) returns `nil` and blows up later, far from the bug — worst in `undo`/`compensate`, which skip validation. The design doc (`specs/inputs_by_method.md`) decides: step code reads inputs through a frozen read-only `Step::Inputs` object (`inputs.order_id`); any unreadable name raises `Error::UndeclaredInputError` naming the step and its declared inputs. No `[]`, no shim — every call site migrates in the same change (`feat!`). This plan implements that doc as written; deviations/additions found while reading the code are marked **(new)**.

Branch: `inputs_by_method` off `main`. Test-first (Constitution III): new specs first, then lib, then migration.

**Step 0 (on approval):** copy this plan to `specs/inputs_by_method_plan.md` (next to the design doc) and stop there. Implementation starts only when asked.

## 1. New code (lib)

**`lib/ruby_reactor/step/inputs.rb`** — `RubyReactor::Step::Inputs` (Zeitwerk picks it up).
- `initialize(values, contract: nil, owner:)`: `@values = values.to_h` (so passing an `Inputs` or nil is safe), readable `@names` = `contract.declarations.keys` when the contract has declarations, else `@values.keys.map(&:to_sym)` **(new: a contract with only `validate_inputs` and no `input` falls back to present keys instead of making everything unreadable)**; `@redacted = contract&.redacted_names || []`; `freeze`.
- `method_missing(name, *args)`: readable name and no args → `Utils::FetchIndifferent.call(@values, name)`; else raise `UndeclaredInputError`. `respond_to_missing?` → `@names.include?(name) || super`.
- `to_h` → supplied readable names only, symbol keys, via FetchIndifferent (key present as sym or string). `alias to_hash to_h`.
- `inspect` → `to_h` with redacted names replaced by `InputContract::REDACTED`.

**`lib/ruby_reactor/error/undeclared_input_error.rb`** — `< NoMethodError`, `def retryable? = false`. Message: `"#{owner} has no input :#{name}. Declared inputs: :a, :b."` (`none` when empty). Retry path already honours it: `Failure#retryable?` (`lib/ruby_reactor.rb:167`) and `StepFailureError#retryable?` ask the error.

**Reserved names** — `InputContract#input` (`lib/ruby_reactor/step/input_contract.rb:25`): raise `Error::ValidationError` when `Step::Inputs.public_method_defined?(name)`. Checked all 141 input names in spec/demo_app/docs: no clashes.

## 2. Injection points (the only places the object is built)

| Where | Change |
|---|---|
| `Step#initialize` (`lib/ruby_reactor/step.rb:44`) | `@inputs = Inputs.new(inputs, contract: (self.class.input_contract if self.class.declares_inputs?), owner: self.class.name)`. Covers `.run`/`.undo`/`.compensate`. Update header comment example (`step.rb:8`). |
| `Step.enforce_contract!` / `with_defaults` (`step.rb:168-179`) | **(new)** `arguments.to_h` first, so a documented nested call `OtherStep.run(inputs, context)` from a step body, and TestSubject's `original` callable, still hand the contract a Hash. |
| `StepConfig` (`lib/ruby_reactor/dsl/step_builder.rb`) | Add `def wrap_inputs(arguments) = Step::Inputs.new(arguments, contract: input_contract, owner: "step :#{name}")`. |
| `StepConfig#call_body` (`step_builder.rb:367`) | `run_block.call(wrap_inputs(arguments), context)`. Duck-typed `impl.run` (line 372) unchanged. |
| `CompensationManager#compensate_step` / `#undo_step` (`lib/ruby_reactor/executor/compensation_manager.rb:126,171`) | Wrap `arguments` with `step_config.wrap_inputs` before the inline block call only. |
| `TestSubject#original_impl_for` duck-impl lambda (`lib/ruby_reactor/rspec/test_subject.rb:772`) | **(new)** `impl.run(args.to_h, ctx)`. Mock blocks replace `@run_block`, so they receive `Inputs` like the body they stand in for — the `Step` path is covered by the `to_h` above. |

## 3. Returning inputs from a step

- `RubyReactor.Success` (`lib/ruby_reactor.rb:391`): `Success.new(value.is_a?(Step::Inputs) ? value.to_h : value)`.
- `ResultHandler#handle_unknown_result` (`lib/ruby_reactor/executor/result_handler.rb:192`): build `success_result` first, then `validate_step_output` on `success_result.value`, **and (new) `@context.set_result(..., success_result.value)`** — the doc's swap alone would still store the raw `Inputs` in context.

## 4. Built-in steps

Per the doc, `MapStep`, `ComposeStep`, `AsyncReactorStep` declare their keys (`input :source`, `input :fan_out, optional: true`, …, untyped → no validator, `enforce!` is a no-op) and switch `inputs[:x]` → `inputs.x` (31 sites). `fail_fast: inputs.fail_fast.nil? || inputs.fail_fast` stays.
- **(new)** drop `inputs[:step_name] ||` in `map_step.rb:193`: `step_name` is never wired, and once declared, `validate_definition!` would wire it by name from a reactor input called `:step_name`.

## 5. Migration (no shim)

Counts: `inputs[` — spec 131, docs 49, README 10, demo_app 44; `args[` — spec 378, docs 157, README 54, demo_app 414 (most in inline blocks).
- Step bodies only (class `run`/`undo`/`compensate`, inline `run`/`undo`/`compensate` blocks, TestSubject mock blocks): `x[:k]` → `x.k`. Hand edits, not a global replace — lock/semaphore/rate-limit key procs, `validate_inputs`, `where`/`guard`, `transform:` procs stay Hashes.
- Other Hash use on inputs (`each`, `slice`, `eq(hash)` in specs) → `.to_h`. `**inputs`, `merge(inputs)`, `Success(inputs)` keep working.
- Docs/README/`demo_app/documentation`: rename inline block param `args` → `inputs`; `documentation/core_concepts.md` step-inputs section documents reader API, `UndeclaredInputError`, reserved names, `to_h`/`**`, `Success(inputs)` conversion (nested not converted).
- Order: lib → `spec/` → `demo_app/` → docs/README.

**Silent-pass trap:** a spec that expects a step to fail still passes if an unmigrated `[]` now fails it for a different reason. So grep is the driver and the suite is the net, not the other way round.

## 6. Demo (Constitution VI)

Via `/speckit-demo-tests`: `demo_app/app/reactors/undeclared_input_demo_reactor.rb` (step reads a typo'd input), `demo:undeclared_input` in `demo_app/lib/tasks/demo_reactors.rake`, `demo_app/spec/reactors/undeclared_input_demo_reactor_spec.rb` asserting failure with `UndeclaredInputError` and one attempt despite `retries`.

## 7. Tests (written first)

`spec/ruby_reactor/step/inputs_spec.rb`:
- reader returns value; declared-optional absent → `nil`; `false` stays `false`; string-keyed hash readable.
- undeclared name raises `UndeclaredInputError` with exact message; `respond_to?`; clash with private Kernel name (`select`) as a declared input reads fine.
- contract-less step reads present keys only; unwired inline step with `inputs do` reads only declared.
- `to_h` omits unsupplied optionals; `**inputs`; `inspect` redacts; frozen, no `[]`.
- `input :method` → `ValidationError` at class definition.
- class `undo`/`compensate` and inline `run`/`undo`/`compensate` blocks receive `Inputs`; typo in `compensate` surfaces as rollback failure naming the input.
- step with `retries max_attempts: 3` + typo → one attempt.
- `Success(inputs)` sync (`result(:step, :x)` works) and async round trip (Hash, not a string); bare `run { |inputs| inputs }` stored/validated as Hash.
- nested `OtherStep.run(inputs, context)` from a step body works; TestSubject `mock_step` with `original.call(args, ctx)` on a class step works.

## Verification

1. `bundle exec rspec` (real Redis) green; rerun flaky async specs alone before chasing them.
2. `cd demo_app && bundle exec rspec` green; `bin/rails demo:undeclared_input` shows the error.
3. `bundle exec rubocop` clean.
4. Residual audit: `grep -rnE 'inputs\[|\bargs\[' lib spec demo_app documentation README.md` — every remaining hit is a Hash context (key procs, validators, `where`/`guard`, reactor DSL `inputs[name]` in `dsl/reactor.rb`).
5. Commit as `feat!:` with a migration note (`inputs[:x]` → `inputs.x`, Hash methods → `inputs.to_h`).
