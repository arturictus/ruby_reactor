# Quickstart: Validating Background Execution & Real Async Steps

Prerequisites: repo checked out on this branch, `bundle install` run (repo root and `demo_app/`), Redis running (`docker-compose up -d` at repo root; the gem's suite reads `RUBY_REACTOR_TEST_REDIS_URL`, defaulting to `redis://localhost:6780` — see `spec/spec_helper.rb:13`). Real Redis, not mocked, per the constitution's storage requirement.

## 1. Gem-level unit/integration specs

```bash
bundle exec rspec spec/ruby_reactor/dsl/reactor_background_spec.rb        # background after:
bundle exec rspec spec/ruby_reactor/dsl/async_step_spec.rb                # async_step
bundle exec rspec spec/ruby_reactor/dsl/async_reactor_spec.rb             # async_reactor
bundle exec rspec spec/ruby_reactor/rspec/test_subject_async_spec.rb      # TestSubject support for the new DSL
```

(Exact spec file names are placeholders for the tasks phase — see contracts/public-dsl.md for the acceptance scenarios each must cover, taken directly from spec.md's User Stories 1–3.)

Expected outcomes, mapped to spec.md acceptance scenarios:

- A reactor with `background after: :second` runs `:first`/`:second` inline and `:third` via a dispatched job; `MyReactor.run` returns an `AsyncResult`; `TestSubject`'s `drain_async_jobs` completes it (US1, SC-001).
- A reactor still using `step { async true }` raises a `ValidationError` at class-definition time, not at run time (US1 acceptance scenario 2, SC-004).
- An `async_step` reactor: a sibling step with no dependency on it completes without waiting; a step declaring `argument :x, result(:async_step_name)` receives the correct value once available (US2, SC-002).
- An `async_step` failure with no downstream reader does NOT flip the parent to `failed`/trigger compensation; a downstream reader that inspects the failure and returns `Failure` DOES trigger compensation (US2 acceptance scenario 3, Clarifications).
- An `async_reactor` with no reader: forcing the child to fail does not compensate the parent. An `async_reactor` with a reader: the reader's `run` block sees the child's real `Success`/`Failure` and can choose to propagate (US3, SC-003).
- A `result()` reference to a never-completing async unit fails with a timeout error, not an indefinite hang (SC-005) — verify by pointing `Configuration#async_wait_timeout` at a short value in the spec and never draining the corresponding job.
- The notified wait is race-free (FR-005, Session 2026-08-20 clarification): a completion that lands *before* the waiter subscribes is still found (subscribe-then-check), and a dropped signal is caught by the fallback re-check — verify with a spec that completes the async unit before the reader step runs, and one that publishes nothing and relies on the record alone.
- An `async_reactor` whose child declares the same `lock` key the parent holds fails at dispatch with an error naming the key and both reactors (FR-015) — not a wait-then-timeout.
- Dispatching an `async_reactor` with invalid child inputs fails the dispatching step in the parent (FR-016), while a child that fails *during execution* still never auto-compensates the parent (FR-009).

## 2. Sidekiq AND ActiveJob backends both pass

Per Assumptions (spec.md) and Technical Context (plan.md), this feature must not hardcode a backend. Run the relevant spec files twice — once with the default (`Sidekiq::Testing.fake!`) and once with `config.async_router = RubyReactor::Adapters::ActiveJob::Router` + `ActiveJob::Base.queue_adapter = :test` — however the existing test suite's backend-parameterization convention already does this (check `spec/support/` for a shared-example/shared-context wrapping both backends before inventing a new one).

## 3. `demo_app` end-to-end

```bash
cd demo_app
bin/rails db:test:prepare   # if needed
bundle exec rspec spec/reactors/background_after_demo_reactor_spec.rb
bundle exec rspec spec/reactors/async_step_demo_reactor_spec.rb
bundle exec rspec spec/reactors/async_reactor_demo_reactor_spec.rb
```

These exercise the new example reactors (`app/reactors/*.rb`, replacing `partial_async_reactor.rb`'s old syntax) through the full Rails/Sidekiq(or ActiveJob) stack the demo app wires up, giving a real (not just unit-tested) confirmation that the feature works end-to-end — the closest thing this library has to a "run it in a browser" check for a non-UI gem.

## 4. Manual smoke check (optional, for a human reviewer)

```ruby
# bin/console or demo_app's bin/console
result = MyReactor.run(...)
result.class            # => RubyReactor::AsyncResult (background) or RubyReactor::Success (no background)
RubyReactor::RSpec::AsyncTestHelpers.drain_async_jobs if defined?(RubyReactor::RSpec) # in a test/console context
MyReactor.find(result.execution_id).result
```

## 5. Web dashboard visibility (FR-008, FR-014, SC-006)

```bash
bundle exec rspec spec/ruby_reactor/web/api_spec.rb   # determine_step_type / hydrate_composed_contexts additions
cd gui && npm run dev                                  # or npm test if component tests exist
```

Run a reactor with an `async_step` and one with an `async_reactor` (e.g. the new `demo_app` example reactors from step 3), open the dashboard, and confirm: the step renders with a distinct `async_step`/`async_reactor` badge (not falling back to generic `step`), and for `async_reactor`, clicking through opens the linked child execution — the same drill-down `compose`/`map` already provide. This is a UI-affecting change (constitution: "For UI or frontend changes, start the dev server and use the feature in a browser before reporting the task as complete") — do not report FR-014 done from passing specs alone.

## 6. Documentation review

- `documentation/async_reactors.md` and its duplicate `demo_app/documentation/async_reactors.md` render correctly and no longer show `step { async true }` as the recommended step-level pattern.
- `README.md`'s "Step-Level Async" subsection reflects `background after:`.
- `CHANGELOG.md` has a breaking-change entry under the correct semantic heading (constitution Development Workflow requirement).

## Done criteria

All specs above pass; `bundle exec rubocop` is clean (constitution requirement, no `--disable-pending-cops`); `demo_app`'s specs pass against both configured backends if the demo app is wired to test both (verify via its `config/` — otherwise document which single backend the demo exercises).
