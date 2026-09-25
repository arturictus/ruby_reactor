# Contract: Retry DSL Surface

The public API after this feature. Anything not listed here keeps its current behavior.

## 1. Removed: `retry_defaults` (Phase A)

```ruby
class PaymentReactor < RubyReactor::Reactor
  retry_defaults max_attempts: 3   # => raises at class definition
end
```

- Raises `RubyReactor::Error::DeprecatedDslError` (a `ValidationError`) when the class body
  runs, whatever the arguments.
- Message (shape): ``"`retry_defaults` has been removed from PaymentReactor: reactor-wide
  defaults silently applied only to steps declared after them. Declare `retries` on each step
  class (or step block) that should retry; a step with no `retries` runs once."``
- There is no reader. `PaymentReactor.retry_defaults` with no arguments raises the same error.

## 2. `retries` on a step class (Phase B)

```ruby
class ChargeCard < RubyReactor::Step
  with_lock { |i| "card:#{i[:card_token]}" }
  input :card_token, :string
  retries max_attempts: 3, backoff: :exponential, base_delay: 5   # all keywords optional

  def run = Success(PaymentService.charge(inputs[:card_token]))
end
```

| Call                                   | Result                                                     |
|----------------------------------------|------------------------------------------------------------|
| `retries`                              | `{max_attempts: 3, backoff: :exponential, base_delay: 1}`  |
| `retries max_attempts: 5`              | `{max_attempts: 5, backoff: :exponential, base_delay: 1}`  |
| `retries max_attempts: 1`              | explicit "never retry"                                     |
| `retries max_attempts: 0` / `2.5` / `"3"` | `ArgumentError` naming `ChargeCard`, `max_attempts`, value |
| `retries backoff: :jitter`             | `ArgumentError` naming `ChargeCard`, `backoff`, value      |
| `retries base_delay: -1`               | `ArgumentError` naming `ChargeCard`, `base_delay`, value   |
| `ChargeCard.retry_config`              | the hash above, or `nil` if never declared                 |

Inheritance: `class ChargeCardEU < ChargeCard; end` returns ChargeCard's policy from
`retry_config`. Redeclaring in `ChargeCardEU` changes only `ChargeCardEU`.

## 3. `retries` in a reactor step block (unchanged vocabulary)

The same module provides it, so the table above also applies inside `step`, `async_step`,
`compose` and `async_reactor` blocks (the error names the step, e.g. `charge_card`).

```ruby
step :charge_card do                 # inline: valid, as today
  retries max_attempts: 3, backoff: :exponential, base_delay: 5
  run { |args, _ctx| PaymentService.charge(args[:card_token]) }
end

step :charge_card, LegacyCharge do   # class without its own policy: valid, as today
  retries max_attempts: 3
end

step :charge_card, ChargeCard do     # ChargeCard declares retries: REFUSED
  retries max_attempts: 5
end
# => Error::ValidationError at reactor definition:
#    "PaymentReactor step :charge_card declares `retries` inline, but ChargeCard declares it
#     too. Keep ONE: drop the inline declaration to use ChargeCard's, or remove it from
#     ChargeCard. To vary the policy per workflow, subclass ChargeCard."
```

## 4. Effective policy introspection

```ruby
PaymentReactor.steps[:charge_card].retry_config  # => {max_attempts: 3, backoff: …, base_delay: …}
PaymentReactor.steps[:charge_card].retry_source  # => :step_class | :step_block | :none
PaymentReactor.steps[:charge_card].retryable?    # => max_attempts > 1
```

## 5. Direct invocation

`ChargeCard.run(args)` / `.call(args)` runs **once**, whatever `retries` says, and returns
its `Failure` to the caller. Only a reactor coordinates retries. (Locks, by contrast, are
taken on a direct call.)

## 6. Runtime (unchanged)

Under a class policy, retry behavior is the same as under a step-block policy with the same
values: which failures are retried (`Failure#retryable?`, `fail!(retry: false)`, input
contract failures), attempt counting across requeues, in-process sleep versus background
`perform_in`, `MaxRetriesExhaustedFailure`, the `retry_attempt` middleware event, and
compensation after the last attempt.
