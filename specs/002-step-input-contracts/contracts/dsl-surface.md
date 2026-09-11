# Public DSL Contract: Step Input Contracts

**Feature**: `specs/002-step-input-contracts/` | **Date**: 2026-09-10

The gem's external interface is its DSL. This document is the contract that
`spec/ruby_reactor/dsl/` specs assert against and that README must match.

## 1. `input` — declare a contract (step class)

```ruby
input(name, type = nil, optional: false, default: nil, redact: false,
      validate: nil, **predicates, &block)
```

Available on any class that `include RubyReactor::Step`. Signature is intentionally identical
to the reactor's `input`, minus `transform:` (a step does not transform its own inputs — the
reactor's `argument` does that).

```ruby
class ValidatedUserStep
  include RubyReactor::Step

  input :name,  :string,  min_size?: 2
  input :email, :string
  input :age,   :integer, gteq?: 18
  input :bio,   :string,  optional: true, default: "No bio provided", max_size?: 100
  input :token, :string,  redact: true

  input :window do |i|                      # Form 2 — macro block
    i.filled(:integer, gteq?: 1, lteq?: 24)
  end

  input :payload, validate: PayloadSchema    # Form 3 — pre-built schema

  def self.run(args, context)
    Success(profile_from(args))
  end
end
```

**Forms** (dispatch matches `Dsl::Reactor::ClassMethods#build_input_validator_for`):

| Form | Written as | Compiles to |
|---|---|---|
| 0 | `input :x` | declaration only, no rule |
| 1 | `input :x, :string, min_size?: 2` | `required(:x).filled(:string, min_size?: 2)` |
| 1b | `input :x, User` | `required(:x).filled(type?: User)` |
| 1-opt | `input :x, :string, optional: true` | `optional(:x).maybe(:string)` |
| 2 | `input :x do \|i\| ... end` | block bound to the value macro |
| 3 | `input :x, validate: Schema` | the supplied schema |

## 2. `validate_inputs` — cross-field rules (step class)

```ruby
class ChargeStep
  include RubyReactor::Step

  input :amount,   :decimal, gt?: 0
  input :currency, :string

  validate_inputs do
    required(:amount).filled(:decimal, lt?: 10_000)
  end
end
```

Composes with the per-input rules; applied last, wins on conflict — same precedence as the
reactor's existing `validate_args`.

## 3. `inputs do ... end` — declare a contract (inline step)

```ruby
step :charge do
  inputs do
    input :amount,   :decimal, gt?: 0
    input :currency, :string,  included_in?: %w[USD EUR GBP]

    validate_inputs do
      required(:amount).filled(:decimal, lt?: 10_000)
    end
  end

  argument :amount,   input(:amount)     # `input(:x)` here is still the template reference
  argument :currency, input(:currency)

  run { |args, _| charge!(args) }
end
```

The wrapper block exists because inside a `step` block, bare `input(:x)` already means
"reference the reactor input" (`Dsl::TemplateHelpers#input`). Inside `inputs do`, `input`
unambiguously declares. The declaration lines are byte-identical to a step class's, so moving
an inline step into a class is deleting the wrapper.

## 4. `argument` — wiring only

```ruby
argument(name, source, transform: nil)
```

Unchanged for dependency resolution and value mapping.

| Step owns a contract? | `argument :x, src` | `argument :x, src, :string, gt?: 0` | `validate_args do ... end` |
|---|---|---|---|
| Yes | ✅ | ❌ raises at the `step` macro | ❌ raises at the `step` macro |
| No | ✅ | ✅ + deprecation notice | ✅ + deprecation notice |

An `argument` naming an input a contract-owning step does not declare raises at the `step`
macro.

## 5. Name-based resolution

A declared input with no `argument` is satisfied by the reactor input of the same name.

```ruby
class MyReactor < RubyReactor::Reactor
  input :amount
  input :currency

  step :charge, ChargeStep          # both inputs resolved by name
end
```

Rules:

- Reactor inputs only — never another step's result.
- An explicit `argument` always wins and is never overwritten.
- A required input satisfied by neither raises before execution begins, naming the step, the
  input, and both ways to satisfy it.

## 6. Introspection

```ruby
ChargeStep.input_contract          # => RubyReactor::Step::InputContract
ChargeStep.declared_inputs         # => { amount: InputDeclaration, ... }
ChargeStep.required_input_names    # => [:amount, :currency]
ChargeStep.declares_inputs?        # => true
```

Read-only. Used by `validate_definition!`, by tooling, and by the dashboard.

## 7. Enforcement points

| Entry point | Enforced | Mechanism |
|---|---|---|
| Reactor step execution | ✅ | prepended `run` (class) / `args_validator` (inline) |
| Retry attempt | ✅ | same, re-validated per attempt |
| `async_step` worker | ✅ | prepended `run` (class); explicit call in `StepWorker#execute_step_body` (inline) |
| `background` hand-off worker | ✅ | ordinary step execution inside the worker |
| Resume after interrupt | ✅ | ordinary step execution |
| Each `map` iteration | ✅ | child reactor's own step execution |
| `ChargeStep.run(args, ctx)` directly | ✅ | prepended `run` |
| `compensate` / `undo` | ❌ by design | rollback receives already-validated arguments |
| Step that a `where`/guard skips | ❌ by design | a step that never runs never validates |

## 8. Errors

| Situation | Error | Carries |
|---|---|---|
| Contract violated | `RubyReactor::Error::InputValidationError` (raised) | `field_errors`, `step_name`, `step_arguments` |
| Rules declared in reactor and step class | `RubyReactor::Error::ValidationError` at the `step` macro | reactor, step, argument, owning class |
| `argument` for an undeclared input | `RubyReactor::Error::ValidationError` at the `step` macro | reactor, step, unknown argument |
| Required input unwired and unmatched | `RubyReactor::Error::ValidationError` before execution | reactor, step, input, both remedies |
| `default:` on a required input | `RubyReactor::Error::ValidationError` at the `input` call | input name |
| Contract declared, dry-validation missing | `LoadError` at declaration | install instruction (existing message) |

A raised `InputValidationError` reaches the caller as a `Failure` carrying `validation_errors`,
after completed steps are rolled back — the existing path in
`Executor::ResultHandler#handle_execution_error`. `have_validation_error(:field)` matches it
unchanged.

## 9. Presence semantics

A value is "provided" when its key exists, never when it is truthy.

| Supplied | Required input | Optional input with `default:` |
|---|---|---|
| `false` | ✅ passes, step receives `false` | keeps `false`, default not applied |
| `0`, `""`, `[]` | ✅ passes | value kept |
| `nil` | ❌ "must be filled" | default applied |
| key absent | ❌ "is missing" | default applied |

Holds for values sourced from reactor inputs, prior step results, and nested paths within
either.

## 10. Compatibility

- Additive: every existing reactor and step class compiles and behaves identically.
- `argument` with types/predicates and `validate_args` keep working for steps that declare no
  contract; deprecated in favor of a step-owned contract, removal no earlier than the next
  MAJOR.
- Falsey-value resolution changes for anyone who relied on `false` arriving as `nil` — a bug
  fix, recorded under Bug Fixes in the changelog.
