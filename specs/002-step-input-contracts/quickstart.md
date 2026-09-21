# Quickstart: Step Input Contracts

**Feature**: `specs/002-step-input-contracts/` | **Date**: 2026-09-10

How to run and verify this feature end to end. DSL details live in
[contracts/dsl-surface.md](./contracts/dsl-surface.md); design rationale in
[research.md](./research.md).

## Prerequisites

- Ruby >= 3.0, `bundle install`
- Docker (for the gem's test Redis on port 6780 and the demo app's Redis on 6380)

```bash
docker compose up -d redis-test        # required: spec_helper aborts without it
```

## Scenario 1 — a step class owns its contract (US1)

```ruby
class ValidatedUserStep
  include RubyReactor::Step

  input :name,  :string,  min_size?: 2
  input :email, :string
  input :age,   :integer, gteq?: 18
  input :bio,   :string,  optional: true, default: "No bio provided", max_size?: 100

  def self.run(args, _context)
    Success(args.merge(created_at: Time.now))
  end
end

class SignupReactor < RubyReactor::Reactor
  input :name
  input :email
  input :age

  step :profile, ValidatedUserStep      # no argument block — resolved by name
  returns :profile
end
```

**Expected**

```ruby
SignupReactor.run(name: "Ada", email: "ada@example.com", age: 36)
# => Success, bio defaulted to "No bio provided"

SignupReactor.run(name: "A", email: "ada@example.com", age: 17)
# => Failure; validation_errors has :name and :age; ValidatedUserStep.run never called
```

**Verify**

```bash
bundle exec rspec spec/ruby_reactor/dsl/step_input_contract_spec.rb
bundle exec rspec spec/ruby_reactor/step_contract_enforcement_spec.rb
```

## Scenario 2 — the reactor may not redeclare rules (US2)

```ruby
class BadReactor < RubyReactor::Reactor
  input :age
  step :profile, ValidatedUserStep do
    argument :age, input(:age), :integer, gteq?: 21   # ← rules on a contract-owning step
  end
end
# raises RubyReactor::Error::ValidationError when the class body runs,
# naming BadReactor, :profile, :age, and ValidatedUserStep
```

Same for `validate_args do ... end`, and for an `argument` naming an input the step never
declares.

**Verify**: `bundle exec rspec spec/ruby_reactor/dsl/step_contract_conflict_spec.rb`

## Scenario 3 — inline steps, same vocabulary (US3)

```ruby
step :charge do
  inputs do
    input :amount, :decimal, gt?: 0
  end
  argument :amount, input(:amount)
  run { |args, _| Success(charge!(args[:amount])) }
end
```

**Expected**: identical outcomes to the same declarations in a step class, for both
conforming and violating values (SC-005). The equivalence spec asserts this pair directly.

## Scenario 4 — missing wiring is caught before execution (US4)

```ruby
class IncompleteReactor < RubyReactor::Reactor
  input :name                       # :email and :age never declared or wired
  step :profile, ValidatedUserStep
end

IncompleteReactor.run(name: "Ada")
# => RubyReactor::Error::ValidationError naming :profile, :email, and how to satisfy it.
# ValidatedUserStep.run is never called; no step in the reactor runs.
```

Callable directly for a boot-time or CI check:

```ruby
IncompleteReactor.validate_definition!
```

## Scenario 5 — falsey values survive (FR-023)

```ruby
class NotifyStep
  include RubyReactor::Step
  input :notify, :bool
  def self.run(args, _ctx) = Success(args[:notify])
end

SomeReactor.run(notify: false)
# => Success(false) — not a "must be filled" failure, and not nil
```

Covers reactor inputs, prior step results, and nested paths through either.

**Verify**: `bundle exec rspec spec/ruby_reactor/falsey_input_resolution_spec.rb`

## Scenario 6 — every execution path (FR-003)

The async worker is the path that has no argument validation today
([research.md](./research.md) Finding 2), so it is the one worth running against real
infrastructure rather than `Sidekiq::Testing.inline!`:

```bash
docker compose up -d demo-redis sidekiq
docker compose run --rm demo-app bin/rails demo:validated_signup
```

**Expected output**: the passing run prints the created profile; the failing run prints a
validation failure naming the step and the offending fields; the `async_step` variant shows
the same failure produced inside the worker.

## Full suite

```bash
docker compose up -d redis-test
bundle exec rspec                     # gem suite
bundle exec rubocop                   # required by the constitution, no --disable-pending-cops

docker compose run --rm demo-app bundle exec rspec spec/reactors/validated_signup_reactor_spec.rb
docker compose run --rm demo-app bin/rails demo:validated_signup
```

## Acceptance checklist

| # | Claim | How it is verified |
|---|---|---|
| SC-001 | Contract readable from the step class alone | No demo reactor declares a rule for a contract-owning step |
| SC-002 | Same step, same rules in every reactor | Two reactors reuse `ValidatedUserStep`, zero per-reactor rules |
| SC-003 | Conflicts reported at definition | Scenario 2 raises when the class body runs |
| SC-004 | Unwired required inputs reported before execution | Scenario 4 |
| SC-005 | Inline ↔ class equivalence | Scenario 3 equivalence spec |
| SC-006 | Existing behavior preserved | Full gem suite green |
| SC-007 | Failure names reactor, step, fields | `have_validation_error` + failure payload assertions |
| SC-008 | Demo runs in docker, both paths | Scenario 6 |
| SC-009 | Name-matched reactors need no arguments | Scenario 1 has no argument block |
| SC-010 | Direct call ≡ reactor call | `ValidatedUserStep.run({age: 17}, ctx)` raises the same error |
| SC-011 | `false` arrives as `false` | Scenario 5 |
