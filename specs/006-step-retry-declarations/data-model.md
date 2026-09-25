# Data Model: Step-Scoped Retry Declarations

No persisted data changes. The per-execution attempt record (`RetryContext#step_attempts`)
and its serialization stay the same. Everything below is class-level configuration held in
memory.

## Retry Policy

A frozen-shape hash. It is the same shape every consumer reads today.

| Key            | Type                              | Default        | Validation (declaration time, `ArgumentError`) |
|----------------|-----------------------------------|----------------|------------------------------------------------|
| `max_attempts` | Integer                           | `3` (declared) | `Integer`, `>= 1`                              |
| `backoff`      | Symbol                            | `:exponential` | one of `:exponential`, `:linear`, `:fixed`     |
| `base_delay`   | Numeric (incl. AS::Duration)      | `1`            | `Numeric`, `>= 0`                              |

`NO_RETRIES = { max_attempts: 1, backoff: :exponential, base_delay: 1 }` is the effective
policy when nothing is declared. `retryable?` is false for it.

## Declaration holders

| Holder                              | How it declares                      | Reader                   | Inheritance                            |
|-------------------------------------|--------------------------------------|--------------------------|----------------------------------------|
| Step class (`< RubyReactor::Step`)  | `retries …` in class body            | `.retry_config` (or nil) | copied to subclass on `inherited`      |
| `StepBuilder` (step / async_step)   | `retries …` in the reactor step block | `#retry_config` (or nil) | n/a                                    |
| `ComposeBuilder`, `AsyncReactorBuilder` | `retries …` in the block         | `#retry_config` (or nil) | n/a                                    |
| Reactor class                       | **none**: `retry_defaults` raises `DeprecatedDslError` | n/a | n/a                            |

All four `retries` entry points come from one module (`Dsl::Retryable`), so vocabulary,
defaults and validation are identical.

## Effective policy (`StepConfig`)

```text
StepConfig#retry_config
  = own (from builder)                         -> source :step_block
  | impl.retry_config  (impl responds, non-nil) -> source :step_class
  | NO_RETRIES                                  -> source :none

StepConfig#retry_source  ∈ { :step_block, :step_class, :none }
```

Resolved lazily on each read, like `lock_config`. The reactor class is never consulted.

## Definition-time rules

| Rule                                                               | Where                         | Error                        |
|--------------------------------------------------------------------|-------------------------------|------------------------------|
| Invalid policy value                                               | `Retryable#retries`           | `ArgumentError`              |
| `retries` in step block **and** on `impl` (own or inherited)       | `StepBuilder#build`           | `Error::ValidationError`     |
| `retry_defaults` called on a reactor                               | `Dsl::Reactor.retry_defaults` | `Error::DeprecatedDslError`  |

## Runtime (unchanged)

The attempt record is `RetryContext#step_attempts[step_name]`, kept through serialization and
requeue. `RetryManager` (in-process and background requeue) and `StepWorker` (`async_step`)
compare it with `step_config.retry_config[:max_attempts]`. A direct `Step.run` never
consults a policy (`StepCoordination#retry_pending?` is false for direct calls).
