# Public API Contract: Interrupt Inside a Composed Child

Every addition is backward compatible. Calls that do not use a path behave as before.

## `Reactor.run` / `Reactor#run`

When a composed child reaches an interrupt, the run returns an `InterruptResult` with:

- `paused?` → `true`, `status` → `:paused`;
- `execution_id` → **the root's** id;
- `correlation_id` → the child interrupt's correlation id, or `nil`.

`Reactor.find(id).result` rebuilds an `InterruptResult` with the root's id, and without
`correlation_id` (unchanged).

## `Reactor.continue(id:, payload:, step_name:)`, `Reactor#continue(payload:, step_name:)`

`step_name` takes either form:

| `step_name` | Meaning |
| --- | --- |
| `:approve` / `"approve"` | A step of the root (unchanged). |
| `[:fulfil, :approve]` / `["fulfil", "approve"]` | The interrupt `:approve` inside compose `:fulfil`. |
| `[:order, :fulfil, :approve]` | Two composes deep. |
| `[:approve]` | Same as `:approve`. |

Errors:

- `RubyReactor::Error::ValidationError` when the name or path is not a pending interrupt
  (`"Cannot resume: expected step '<current>' or ready steps <ready_interrupt_steps> but got
  '<name>'"`). Nothing changes and the run stays `paused`. A bare name must now be a pending
  interrupt: naming any other ready step is refused, where it used to be accepted.
- `RubyReactor::Error::ValidationError` when the reactor loaded is a composed child: "Cannot
  resume: <Class> is a composed child; continue its root run".
- Every existing error keeps its meaning and is driven by the nested interrupt's own declaration:
  not paused, cancelled, invalid payload (`InputValidationError` from the class method),
  `max_attempts` exhaustion (`Failure`, run rolled back from the root and `failed`), and
  lock/semaphore `AcquisitionError` (run stays paused).

`resume: :background` on the nested interrupt enqueues **the root's** worker.

## `Reactor.continue_by_correlation_id(correlation_id:, payload:, step_name:)`

Called on the **root** class with the path. Called on the child class, it raises the
composed-child `ValidationError` above.

## `Reactor.interrupt_key(step_name)` (new, public)

Normalizes a step name the way `continue` reads it. `:a`, `"a"` and `[:a]` all give `:a`;
`["f", "a"]` gives `[:f, :a]`.

## `Reactor#ready_interrupt_steps` (new, public)

```ruby
Order.find(id).ready_interrupt_steps # => [[:fulfil, :approve]]
```

Returns `[]` unless the run is `paused`. Root-level interrupts come back as Symbols, nested ones as
Arrays. A root can be paused at a nested interrupt and have one of its own ready at the same
time, so the list can mix both: `[:audit, [:fulfil, :approve]]`.

## RSpec surface (`require "ruby_reactor/rspec"`)

| API | Change |
| --- | --- |
| `subject.ready_interrupt_steps` | Delegates to `Reactor#ready_interrupt_steps`, so it includes paths. |
| `be_paused_at([:fulfil, :approve])` | Matches a path. `be_paused_at(:a, :b)` still means two root interrupts. Failure messages print entries with `inspect`. |
| `have_ready_interrupts(:audit, [:fulfil, :approve])` | Exact set, paths included. |
| `subject.resume(payload:, step: [:fulfil, :approve])` | Resumes a nested interrupt. With one pending interrupt, `step` may be omitted. |

## Map elements

An `interrupt` reached inside a map element, directly or through a compose, fails that element
with `Failure("interrupt :<name> is not supported inside a map element")`. Before this feature it
crashed with `NoMethodError`.
