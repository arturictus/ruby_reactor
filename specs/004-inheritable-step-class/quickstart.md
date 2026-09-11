# Quickstart: Validating the Inheritable Step Class

Prerequisites: repo checked out on this feature branch, Redis reachable
(Constitution Principle III — `bundle exec rspec` fails fast at suite start if not),
`bundle install` run.

## 1. Unit-level proof (User Story 1)

Write a throwaway subclass and invoke it directly — no reactor needed, matching how the
input-contracts feature was validated:

```ruby
class QuickstartStep < RubyReactor::Step
  input :amount, :integer, gt?: 0

  def run
    fail!("too much") if inputs[:amount] > 100
    Success(charged: inputs[:amount])
  end
end

ctx = RubyReactor::Context.new({})
QuickstartStep.run({ amount: 10 }, ctx)   # => Success(charged: 10)
QuickstartStep.run({ amount: 200 }, ctx)  # => Failure("too much")
QuickstartStep.run({ amount: -1 }, ctx)   # raises RubyReactor::Error::InputValidationError, step_name "QuickstartStep"
```

Expected: first call succeeds with the body's value; second call returns the `fail!`
signal translated to a `Failure`, proving User Story 1 scenario 3; third call **raises**
(a direct call surfaces the validation error itself — the executor and worker are what
turn it into a rolled-back `Failure`) and never runs the body, proving scenario 2. See
[contracts/step-lifecycle.md](./contracts/step-lifecycle.md) for the full invocation
contract.

## 1b. Worker-path signal proof (User Story 2 scenario 2, research.md D4)

The one behavior that *changes* on purpose: a class step calling `fail!` under
`async_step` / `background` must now produce the intended `Failure`, not a Failure wrapping
`UncaughtThrowError`. Write this spec first and watch it fail on the current code:

```ruby
# spec/ruby_reactor/step_signals_worker_spec.rb (sketch)
class WorkerFailStep < RubyReactor::Step
  def run = fail!("nope")
end
# reactor with `async_step :boom, WorkerFailStep`; run with drain_async_jobs
expect(result).to be_failure
expect(result.error).to eq("nope")   # today: an UncaughtThrowError instance
```

## 2. Full-suite regression proof (User Story 2)

```sh
bundle exec rspec
bundle exec rubocop
```

Expected: 100% pass, identical to the pre-refactor baseline (spec SC-003). This exercises
every execution path — sync executor, async worker, retry, compensation/undo, compose,
map, and the RSpec test-subject interception surface — because those specs already cover
those paths against whatever step classes exist; after migration (research.md D6, D8)
they exercise the same paths against the new base class.

## 3. Brownfield adapter proof (User Story 3)

```ruby
# Pre-existing, untouched service:
class LegacyChargeService
  def initialize(user_id) = @user_id = user_id
  def call = @user_id.positive? ? OpenStruct.new(success?: true, id: 42) : OpenStruct.new(success?: false, error: "bad user")
end

class ChargeStep < RubyReactor::Step
  input :user_id, :integer

  def run
    outcome = LegacyChargeService.new(inputs[:user_id]).call
    outcome.success? ? Success(charge_id: outcome.id) : Failure(outcome.error)
  end
end
```

Expected: `LegacyChargeService` is never modified; `ChargeStep` is ≤10 lines (spec SC-004).

## 4. Demo-app acceptance proof (User Story 5, Constitution Principle VI)

```sh
docker compose up -d
docker compose run --rm demo-app bin/rails demo:inheritable_step   # new task added by this feature
docker compose run --rm demo-app bundle exec rspec spec/reactors   # demo_app has its own Gemfile/.rspec
```

Expected: printed success and failure/rollback outcomes for the new demo reactor; the
full `demo_app/spec/reactors/` suite passes using only the shipped `lib/ruby_reactor/rspec.rb`
test surface (no hand-rolled scaffolding, per Principle VI). Run the demo specs from
inside `demo_app/` (or via the compose service as above), never from the gem root.

## 5. Old authoring style is gone (User Story 5)

```sh
grep -rnE "include RubyReactor::Step\b" lib spec demo_app README.md documentation
```

Expected: zero matches (spec SC-002). The `\b` matters: without it the grep also hits
`include RubyReactor::StepSignals`, which is legitimate and stays. Any real match is
unfinished migration work, not an acceptable remainder.
