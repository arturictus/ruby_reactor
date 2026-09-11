# Public API Contract: `RubyReactor::Step`

RubyReactor is a library (Constitution Principle I) — its "contract" is the public Ruby
API surface it exposes to gem consumers, not a network endpoint. This document is that
contract for the step-authoring surface this feature replaces.

## Authoring contract

```ruby
class MyStep < RubyReactor::Step
  input :email, :string, format?: EMAIL_REGEX
  input :user_id, :integer

  def run
    # `inputs` and `context` expose the validated arguments and the workflow context.
    # Return a result wrapper, or end early with a signal.
    fail!("nop") unless something
    Success(value: inputs[:user_id])
  end

  def undo
    # `result` holds this step's own stored result value.
    Skipped() # default if omitted
  end

  def compensate
    # `reason` holds the failure that triggered rollback.
    Skipped() # default if omitted
  end
end
```

Instance readers: `inputs`, `context`, `result` (undo only), `reason` (compensate only).
All set once in the constructor; see data-model.md.

- **MUST** subclass `RubyReactor::Step`. `include RubyReactor::Step` on a plain class is
  no longer supported (FR-012) — it is not a compatibility path, it is simply gone.
- **MUST** declare inputs, if any, with `input`/`validate_inputs` at the class level,
  identically to the input-contracts feature (FR-002). Declaring none means no validation
  runs, and `run` receives the raw resolved arguments (unchanged behavior).
- **MUST** implement `run` as an instance method with no required parameters. Omitting it
  raises `NotImplementedError` naming the subclass when the step is invoked (FR-010).
- **MAY** implement `undo`/`compensate` as instance methods with no required parameters;
  omitting either defaults to `Skipped()` (FR-009).
- Inside `run`/`undo`/`compensate`, `Success`, `Failure`, `Halt`, `Skipped`, and the
  signal helpers `success!`/`skip!`/`fail!`/`halt!` are available as bare instance calls
  (FR-008).

## Invocation contract (what every caller in the library gets)

```ruby
RubyReactor::Step.run(arguments, context)   # => Success/Failure/Halt/Skipped
RubyReactor::Step.call(arguments, context)  # alias of .run
RubyReactor::Step.undo(result, arguments, context)       # => Success/Failure/Halt/Skipped
RubyReactor::Step.compensate(reason, arguments, context) # => Success/Failure/Halt/Skipped
```

- **MUST** be pure from the caller's perspective: given the same `arguments`/`context`
  (and `result`/`reason` for undo/compensate), behavior does not depend on whether `.run`
  was previously called on the same class in the same process (FR-009, D2).
- **MUST NOT** raise `StepSignals`' internal throw to the caller — every signal is
  translated into the matching result wrapper before `.run`/`.undo`/`.compensate` return
  (FR-007).
- **MUST** raise the existing `Error::InputValidationError` (with `step_name` and
  `step_arguments` set) when the declared contract rejects `arguments`, before the
  instance's `run` method executes (FR-006) — same error class and same attributes as
  today, only relocated internally (D-series decisions in research.md).
- That error's `retryable?` **MUST** be `false` (FR-017, research.md D10), so any `Failure`
  built from it — on the synchronous path, the async worker, or surfaced through a
  composed reactor — is non-retryable without its caller having to say so.
- An ordinary (non-signal) exception raised inside `run`/`undo`/`compensate` **MUST**
  propagate unchanged — this contract governs signals and validation only.

## Compatibility note

This is a **breaking change** to the public API (Constitution Principle V — SemVer). No
prior form is preserved. Any code outside this repository using
`include RubyReactor::Step` with `def self.run` must convert to
`class Foo < RubyReactor::Step` with an instance `def run` to keep working. `CHANGELOG.md`
records this under a breaking-change heading with a before/after example (spec FR-015,
User Story 5); release-please's `bump-minor-pre-major` takes 0.7.0 to 0.8.0.
