# Changelog

## [0.6.0](https://github.com/arturictus/ruby_reactor/compare/v0.5.4...v0.6.0) (2026-08-16)


### Features

* ActiveJob Support ([#42](https://github.com/arturictus/ruby_reactor/issues/42)) ([0fb6dc4](https://github.com/arturictus/ruby_reactor/commit/0fb6dc4ae4b16c34e0aa33a66f95df3e14ae0807))
## Unreleased

### ⚠ BREAKING CHANGES

* **The per-step `async` flag is removed.** `async true` inside a `step` **or a
  `compose`** block now raises `RubyReactor::Error::DeprecatedDslError` (a
  subclass of `Error::ValidationError`) at reactor **class-definition** time.

  It was ambiguous: only the **first** flagged step in a reactor ever took
  effect, and every later one was silently ignored. A reactor now declares one
  hand-off point instead, nameable from either side:

  ```ruby
  # Before — only the first `async true` did anything
  step :process_payment do
    async true
    # ...
  end

  # After — the exact equivalent
  step :process_payment do
    # ...
  end

  background before: :process_payment
  ```

  **Migration:** for a flagged step `:x`, use `background before: :x`. That
  reproduces the old semantics precisely — `:x` and everything after it move to
  the worker — without having to identify a predecessor step. The same applies to
  `async` inside a `compose` block. `after: :x` is the other side of the same cut
  point (`:x` stays in the calling process); the two coincide in a linear chain
  but pin different steps in a DAG.

  Not affected: the map-internal `async` element dispatch option
  (`map :items do async true, batch_size: 2 end`) — a different mechanism that
  keeps working unchanged.

  One behavior change falls out of "exactly one hand-off point per reactor":
  resuming a reactor past its hand-off point now finishes in the resuming
  process, where the old per-step flag would queue a second, undeclared hand-off.

* `RubyReactor::Dsl::StepConfig#async?` and the per-step `async:` field in the
  dashboard's `Web::API` step structure are gone. The dashboard now exposes the
  reactor's normalized hand-off point once, as `background_handoff`.

* **Whole-reactor `async true` is removed.** It named the same hand-off idea as
  `background`, with a different word, and read confusingly next to the new
  `async_step` / `async_reactor` step macros (both "async" + "reactor", meaning
  different things). Using it now raises `RubyReactor::Error::DeprecatedDslError`
  at class-definition time.

  ```ruby
  # Before
  class OrderProcessingReactor < RubyReactor::Reactor
    async true
    # ...
  end

  # After — identical behavior, including validating inputs inside the worker
  class OrderProcessingReactor < RubyReactor::Reactor
    background all: true
    # ...
  end
  ```

  **Migration:** replace `async true` with `background all: true`. `async?` (the
  reader) is unchanged and still answers the same question.

### Features

* **`background after:` / `background before:` / `background all:`** — one
  unambiguous, reactor-level cut point between what runs in the calling process
  and what runs in a worker (`all:` — the whole reactor, replacing the old
  whole-reactor `async true`).
* **`async_step`** — dispatch one step's work to its own job while the reactor
  keeps running every other ready step. Dependent steps read the outcome through
  the existing `result(:name)` helper, which gains a bounded notified wait.
* **`async_reactor`** — dispatch a whole nested reactor to run independently,
  linked to the parent by execution id for traceability but excluded from its
  compensation graph. A dispatch-time guard fails loudly instead of deadlocking
  when a child declares a lock key the parent holds.
* **`Configuration#async_wait_timeout`** (default `30` seconds) — bounds how long
  a step blocks reading a dispatched result. Never an unbounded wait.
* The dashboard renders both new step types and drills into an `async_reactor`
  child's own execution.

**Compensation for the two new units is opt-in, by design.** A failing
`async_step` / `async_reactor` does not automatically compensate its parent — it
was dispatched precisely so the parent would not depend on it. A later step that
reads the result and returns `Failure` triggers compensation normally, so no
failure is unrecoverable, just not automatic.

## [0.5.4](https://github.com/arturictus/ruby_reactor/compare/v0.5.3...v0.5.4) (2026-06-18)


### documentation

* emphasize class-based steps as preferred way  ([#38](https://github.com/arturictus/ruby_reactor/issues/38)) ([0ee6234](https://github.com/arturictus/ruby_reactor/commit/0ee62346fd0c49d97c57cef780a6a7135d4253cd))

## [0.5.3](https://github.com/arturictus/ruby_reactor/compare/v0.5.2...v0.5.3) (2026-06-17)


### Features

* Durability & Recovery ([#39](https://github.com/arturictus/ruby_reactor/issues/39)) ([103e583](https://github.com/arturictus/ruby_reactor/commit/103e5835b413eec2302fa63f3e998d487cfd9eaf))

## [0.5.2](https://github.com/arturictus/ruby_reactor/compare/v0.5.1...v0.5.2) (2026-06-14)


### Features

* Nonce lock ([#26](https://github.com/arturictus/ruby_reactor/issues/26)) ([5925cac](https://github.com/arturictus/ruby_reactor/commit/5925cac7af93f59be6c0a8a98ab020f96080f60b))

## [0.5.1](https://github.com/arturictus/ruby_reactor/compare/v0.5.0...v0.5.1) (2026-06-14)


### Features

* streamline input validation DSL and enhance error handling ([#35](https://github.com/arturictus/ruby_reactor/issues/35)) ([e32f3ec](https://github.com/arturictus/ruby_reactor/commit/e32f3ec91d87cf7a5060558ee705089f1dc76ca6))

## [0.5.0](https://github.com/arturictus/ruby_reactor/compare/v0.4.1...v0.5.0) (2026-06-11)


### Features

* Middlewares & OpenTelemetry ([#32](https://github.com/arturictus/ruby_reactor/issues/32)) ([a9e10ce](https://github.com/arturictus/ruby_reactor/commit/a9e10ceb6fa6381ead57a5905931343f8d1182d1))

## [0.4.1](https://github.com/arturictus/ruby_reactor/compare/v0.4.0...v0.4.1) (2026-05-25)


### Bug Fixes

* trigger release pipeline ([#29](https://github.com/arturictus/ruby_reactor/issues/29)) ([862478b](https://github.com/arturictus/ruby_reactor/commit/862478b3d0811b00e920119057bf4c1bfb1808af))
* trigger release workflows ([#31](https://github.com/arturictus/ruby_reactor/issues/31)) ([ed44dcd](https://github.com/arturictus/ruby_reactor/commit/ed44dcd00e3288e2fab99f9794821943dacc1d4b))

## [0.4.0](https://github.com/arturictus/ruby_reactor/compare/ruby_reactor-v0.3.2...ruby_reactor/v0.4.0) (2026-05-17)


### Features

* `AsyncResult` returning intermediate_results ([#10](https://github.com/arturictus/ruby_reactor/issues/10)) ([0cb96d6](https://github.com/arturictus/ruby_reactor/commit/0cb96d66e88097665998601276e38e1c2249c581))
* enhance deserialization error handling in Sidekiq worker ([#23](https://github.com/arturictus/ruby_reactor/issues/23)) ([60dde95](https://github.com/arturictus/ruby_reactor/commit/60dde95606d52cc6a9d352ad0117b4092a1ebb9d))
* Enhance failure messages with step, reactor, redacted inputs, a… ([#11](https://github.com/arturictus/ruby_reactor/issues/11)) ([952feae](https://github.com/arturictus/ruby_reactor/commit/952feaeb6ebbe5fbe2daf470263d8e769ba64138))
* Introduce reactor interrupt functionality, allowing pausing and… ([#13](https://github.com/arturictus/ruby_reactor/issues/13)) ([53d0861](https://github.com/arturictus/ruby_reactor/commit/53d0861f0238f0e2247e581b0a27cba2f42cfba6))
* Rspec helpers ([#19](https://github.com/arturictus/ruby_reactor/issues/19)) ([cb71f80](https://github.com/arturictus/ruby_reactor/commit/cb71f80c0708dacf6c10c0beac88446b00f30f54))
* Web Dashboard ([#14](https://github.com/arturictus/ruby_reactor/issues/14)) ([80255dd](https://github.com/arturictus/ruby_reactor/commit/80255dd40800af8f6ed804de9c6f151331742fd5))
