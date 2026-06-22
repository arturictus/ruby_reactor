# Pluggable Background Adapters (Sidekiq → ActiveJob)

## Goal

Today RubyReactor is hardwired to Sidekiq for everything async: enqueuing,
resuming, map-element fan-out/collection, and the recovery sweeper. We want
to support other background processors — starting with ActiveJob — without
duplicating the reactor-resume/snooze/escalate logic per adapter.

## What's already abstracted (good news)

The **enqueue side** is already behind a seam:

- `RubyReactor.configuration.async_router` (default `RubyReactor::SidekiqAdapter`,
  [configuration.rb:106-108](../lib/ruby_reactor/configuration.rb#L106-L108)) is the
  only thing the core engine calls to go async. Call sites:
  [reactor.rb:117](../lib/ruby_reactor/reactor.rb#L117),
  [reactor.rb:319](../lib/ruby_reactor/reactor.rb#L319),
  [step/map_step.rb:274](../lib/ruby_reactor/step/map_step.rb#L274),
  [step/map_step.rb:285](../lib/ruby_reactor/step/map_step.rb#L285),
  [map/dispatcher.rb:177](../lib/ruby_reactor/map/dispatcher.rb#L177),
  [map/element_executor.rb:155](../lib/ruby_reactor/map/element_executor.rb#L155),
  [map/element_executor.rb:176](../lib/ruby_reactor/map/element_executor.rb#L176),
  [executor/retry_manager.rb:59,80](../lib/ruby_reactor/executor/retry_manager.rb#L59),
  [executor/step_executor.rb:219](../lib/ruby_reactor/executor/step_executor.rb#L219),
  [sweeper.rb:48](../lib/ruby_reactor/sweeper.rb#L48),
  [map/sweeper.rb:99](../lib/ruby_reactor/map/sweeper.rb#L99).
- The router contract is 5 class methods on `SidekiqAdapter`
  ([sidekiq_adapter.rb](../lib/ruby_reactor/sidekiq_adapter.rb)):
  `perform_async`, `perform_in`, `perform_map_element_async`,
  `perform_map_element_in`, `perform_map_collection_async`. All return
  `RubyReactor::AsyncResult`.
- An adapter for any other queueing backend just needs to implement that
  same 5-method contract and assign it to `config.async_router`. **This part
  needs no rework.**

## What's NOT abstracted (the actual gap)

The **worker/job side** — the classes the queue invokes — bakes Sidekiq in
directly. **Decision: these move into `RubyReactor::Adapters::Sidekiq::*`**
(renamed from `RubyReactor::SidekiqWorkers::*`), with a sibling
`RubyReactor::Adapters::ActiveJob::*` for the new adapter — see
[Namespace](#namespace) below.

| Class (today) | File | Sidekiq coupling |
|---|---|---|
| `SidekiqWorkers::Worker` | [worker.rb](../lib/ruby_reactor/sidekiq_workers/worker.rb) | `include ::Sidekiq::Worker`, `sidekiq_options`, `sidekiq_retries_exhausted`, and internally calls `self.class.perform_in(...)` to reschedule snoozes (lines 116, 91-117) |
| `SidekiqWorkers::MapElementWorker` | [map_element_worker.rb](../lib/ruby_reactor/sidekiq_workers/map_element_worker.rb) | `include ::Sidekiq::Worker`; body is a 1-line delegate to `Map::ElementExecutor.perform` |
| `SidekiqWorkers::MapCollectorWorker` | [map_collector_worker.rb](../lib/ruby_reactor/sidekiq_workers/map_collector_worker.rb) | same — 1-line delegate to `Map::Collector.perform` |
| `SidekiqWorkers::SweeperWorker` | [sweeper_worker.rb](../lib/ruby_reactor/sidekiq_workers/sweeper_worker.rb) | `include ::Sidekiq::Worker`, `sidekiq_options retry: false`, self-reschedules via `perform_in` / class-level `perform_in` in `schedule_next` |

Plus test-side coupling:

- [rspec/sidekiq_helpers.rb](../lib/ruby_reactor/rspec/sidekiq_helpers.rb) hardcodes
  the 3 Sidekiq worker classes and `Sidekiq::Testing` fake-mode draining.
- [rspec/test_subject.rb:194-203,433](../lib/ruby_reactor/rspec/test_subject.rb#L194-L203)
  gates job-processing on `defined?(Sidekiq::Testing)` and forces
  `async_router` back to `SidekiqAdapter`.
- [ruby_reactor.rb:22-27](../lib/ruby_reactor.rb#L22-L27) optionally requires
  `sidekiq`; [ruby_reactor.rb:359](../lib/ruby_reactor.rb#L359) calls
  `SidekiqWorkers::SweeperWorker.schedule_next` directly from
  `RubyReactor.start_sweeper!`.

The real logic worth extracting lives almost entirely in
`SidekiqWorkers::Worker#perform` (~65 lines): rehydrate context from
storage, deserialize, resolve `reactor_class`, mark
`inline_async_execution`, run `Executor#resume_execution`, and on
lock/semaphore/rate-limit/ordered-lock contention either snooze (re-enqueue
with a computed delay) or escalate to `failed`. None of that is
Sidekiq-specific — it only *touches* Sidekiq via `self.class.perform_in` to
reschedule.

## Proposal

### 1. Normalize the enqueue API at the job-class boundary, not in the shared logic

`Sidekiq::Worker` gives every job class `.perform_async` / `.perform_in` for
free. ActiveJob doesn't — it has `.perform_later` and
`.set(wait: delay).perform_later`. Rather than teach the shared logic two
different reschedule calls, give every framework-specific job class the
same two class methods, so the shared mixin can keep calling
`self.class.perform_in(...)` unchanged:

```ruby
module RubyReactor
  module Adapters
    module ActiveJob
      module Compat
        def perform_async(*args) = perform_later(*args)
        def perform_in(delay, *args) = set(wait: delay).perform_later(*args)
      end
    end
  end
end
```

### 2. Extract `RubyReactor::Worker` — the framework-agnostic mixin

Move the body of `Adapters::Sidekiq::Worker#perform` (and its private snooze/
escalate/deserialization-failure helpers) into a plain module with no
`Sidekiq` reference:

```ruby
module RubyReactor
  module Worker
    def perform(context_id, reactor_class_name = nil, snooze_count = 0)
      # ...exact same logic as today's SidekiqWorkers::Worker#perform...
    end

    private
    # handle_snooze, compute_snooze_delay, hinted_retry?, escalate_snooze,
    # log_infrastructure_failure, handle_deserialization_failure,
    # build_failed_context_payload — unchanged, moved verbatim.
  end
end
```

`Adapters::Sidekiq::Worker` then becomes:

```ruby
module RubyReactor
  module Adapters
    module Sidekiq
      class Worker
        include ::Sidekiq::Worker
        include RubyReactor::Worker

        sidekiq_options retry: RubyReactor.configuration.sidekiq_retry_count,
                        dead: false, queue: RubyReactor.configuration.sidekiq_queue
      end
    end
  end
end
```

And a new `Adapters::ActiveJob::Worker`:

```ruby
module RubyReactor
  module Adapters
    module ActiveJob
      class Worker < ::ActiveJob::Base
        extend Compat
        include RubyReactor::Worker

        queue_as { RubyReactor.configuration.sidekiq_queue } # or a renamed generic config
      end
    end
  end
end
```

Same pattern applies to `MapElementWorker` / `MapCollectorWorker` — they're
already a 1-line delegate, so genericizing is just swapping the include; no
logic to extract.

### 3. Sweeper

`SweeperWorker`'s window-claim-lock + self-reschedule logic
([sweeper_worker.rb:30-70](../lib/ruby_reactor/sidekiq_workers/sweeper_worker.rb#L30-L70))
is also framework-agnostic except for the `perform_in` call in
`schedule_next`. Extract the same way into `RubyReactor::SweeperJob`,
included into both `Adapters::Sidekiq::SweeperWorker` (`sidekiq_options retry: false`)
and an `Adapters::ActiveJob::SweeperWorker`. `RubyReactor.start_sweeper!`
([ruby_reactor.rb:356-360](../lib/ruby_reactor.rb#L356-L360)) needs to call
through whichever sweeper job class matches the configured adapter instead
of hardcoding `Adapters::Sidekiq::SweeperWorker`.

### 4. New `RubyReactor::Adapters::ActiveJob::Router`

Mirrors today's `RubyReactor::Adapters::Sidekiq::Router` (renamed from
`SidekiqAdapter`) exactly — same 5 methods, just pointing at the
`Adapters::ActiveJob::*` job classes instead of `Adapters::Sidekiq::*`. No
changes needed to any core call site; swap is purely
`config.async_router = RubyReactor::Adapters::ActiveJob::Router`.

### 5. Optional config sugar

`configuration.rb` already does this pattern for storage
([configuration.rb:114-121](../lib/ruby_reactor/configuration.rb#L114-L121)):
a single `storage.adapter` symbol resolves to a concrete adapter instance.
Could mirror it — `config.queue_adapter = :sidekiq | :active_job` resolving
both `async_router` and the sweeper job class — but this is sugar, not
required for the feature to work. Confirm whether you want it.

### 6. Test helpers

`rspec/sidekiq_helpers.rb` and the `Sidekiq::Testing` branch in
`rspec/test_subject.rb` only fire for Sidekiq today. For ActiveJob, Rails
already ships `ActiveJob::TestHelper` (`perform_enqueued_jobs`,
`have_enqueued_job`) which covers most of this generically. We'd still want
something equivalent to `drain_async_jobs` (loops until self-rescheduling
jobs — e.g. ordered-lock snoozes — stop producing new ones), so
`test_subject.rb`'s job-processing gate needs to branch on which
testing framework is active (or be driven by `configuration.async_router`)
rather than hardcoding `defined?(Sidekiq::Testing)`.

### 7. Loading

`ruby_reactor.rb:22-27` optionally `require "sidekiq"`. Add the same
optional-require pattern for `active_job`, so neither dependency is forced
on users who only need one.

## Namespace

**Decided: `RubyReactor::Adapters::Sidekiq::*` / `RubyReactor::Adapters::ActiveJob::*`.**

Renames/moves required (mechanical, but touches every reference):

| Today | Becomes |
|---|---|
| `RubyReactor::SidekiqAdapter` | `RubyReactor::Adapters::Sidekiq::Router` |
| `RubyReactor::SidekiqWorkers::Worker` | `RubyReactor::Adapters::Sidekiq::Worker` |
| `RubyReactor::SidekiqWorkers::MapElementWorker` | `RubyReactor::Adapters::Sidekiq::MapElementWorker` |
| `RubyReactor::SidekiqWorkers::MapCollectorWorker` | `RubyReactor::Adapters::Sidekiq::MapCollectorWorker` |
| `RubyReactor::SidekiqWorkers::SweeperWorker` | `RubyReactor::Adapters::Sidekiq::SweeperWorker` |
| (new) | `RubyReactor::Adapters::ActiveJob::Router` |
| (new) | `RubyReactor::Adapters::ActiveJob::{Worker,MapElementWorker,MapCollectorWorker,SweeperWorker}` |

Files move from `lib/ruby_reactor/sidekiq_workers/*.rb` +
`lib/ruby_reactor/sidekiq_adapter.rb` to
`lib/ruby_reactor/adapters/sidekiq/*.rb` (Zeitwerk-driven, so the directory
move IS the rename — no manual `module` boilerplate beyond nesting). New
ActiveJob side lives in `lib/ruby_reactor/adapters/active_job/*.rb`.

References that need updating for the rename:
- [configuration.rb:107](../lib/ruby_reactor/configuration.rb#L107) — `@async_router ||= RubyReactor::SidekiqAdapter`
- [ruby_reactor.rb:359](../lib/ruby_reactor.rb#L359) — `SidekiqWorkers::SweeperWorker.schedule_next`
- [rspec/sidekiq_helpers.rb](../lib/ruby_reactor/rspec/sidekiq_helpers.rb) — `worker_classes` list
- [rspec/test_subject.rb:196](../lib/ruby_reactor/rspec/test_subject.rb#L196) — stub target
- [spec/ruby_reactor/sidekiq_workers/worker_spec.rb](../spec/ruby_reactor/sidekiq_workers/worker_spec.rb),
  [spec/ruby_reactor/sidekiq_workers/sweeper_worker_spec.rb](../spec/ruby_reactor/sidekiq_workers/sweeper_worker_spec.rb) —
  `described_class` references, move to `spec/ruby_reactor/adapters/sidekiq/`

## Retry config — decided: generic

`sidekiq_retry_count` / `sidekiq_queue` rename to `config.job_retry_count` /
`config.queue_name`, used by both adapters:

- `Adapters::Sidekiq::Worker` → `sidekiq_options retry: config.job_retry_count, dead: false, queue: config.queue_name`
- `Adapters::ActiveJob::Worker` → maps to `retry_on StandardError, attempts: config.job_retry_count` (infra
  failures only — reactor-specific errors are already caught by the shared
  snooze/escalate logic in `RubyReactor::Worker` before they'd ever reach
  the framework's retry layer) and `queue_as { config.queue_name }`.
- `sidekiq_retries_exhausted` (currently an empty hook) → ActiveJob
  equivalent is `retry_on ... do |job, error| ... end` / `discard_on`.

`configuration.rb` changes: add `job_retry_count`/`queue_name` as the
canonical attrs; keep `sidekiq_retry_count`/`sidekiq_queue` as deprecated
aliases delegating to the new names so existing configs don't break.

None of this requires touching the enqueue-side call sites in
`reactor.rb`, `executor/*`, `map/*` — that seam already works (it just calls
through `config.async_router`, whose value changes, not its call sites).
The work is isolated to: `lib/ruby_reactor/worker.rb` (new),
`lib/ruby_reactor/sweeper_job.rb` (new), the `sidekiq_workers/` →
`adapters/sidekiq/` move + rename, `adapters/active_job/*.rb` (new, 5
classes: `Router` + 4 job classes), and the test-helper /
`start_sweeper!` branching described above.
