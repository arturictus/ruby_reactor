# frozen_string_literal: true

# Every async spec in this feature must prove backend-agnosticism (spec.md
# Assumptions), so groups declare their examples ONCE and this helper replays
# them against both in-memory backends:
#
#   RSpec.describe MyThing do
#     for_each_async_backend do
#       it "dispatches" do ... end
#     end
#   end
#
# Sidekiq runs in fake mode and ActiveJob on the `:test` adapter; either way
# `AsyncTestHelpers.drain_async_jobs` picks the right drain path, so examples
# themselves never name a backend. For the orchestration lane (a caller blocked
# in the notified wait while a REAL worker completes the work) see
# spec/support/real_async_backend.rb — fakes cannot express that interleaving.
module AsyncBackends
  BACKENDS = {
    sidekiq: RubyReactor::Adapters::Sidekiq::Router,
    active_job: RubyReactor::Adapters::ActiveJob::Router
  }.freeze

  def for_each_async_backend(&block)
    BACKENDS.each_key do |backend|
      context "with the #{backend} backend" do
        include_context "an async backend", backend

        instance_eval(&block)
      end
    end
  end
end

RSpec.shared_context "an async backend" do |backend|
  let(:async_backend) { backend }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test if backend == :active_job
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    Sidekiq::Testing.fake!
  end

  # A `before` and not the `around`: the suite-wide hook that puts Sidekiq into
  # fake mode runs INSIDE any around block, and `AsyncTestHelpers` prefers
  # Sidekiq whenever it is faking — so the ActiveJob lane only really exercises
  # ActiveJob if Sidekiq's test mode is turned off after that hook has run.
  before do
    allow(RubyReactor.configuration).to receive(:async_router).and_return(AsyncBackends::BACKENDS.fetch(backend))
    if backend == :active_job
      Sidekiq::Testing.disable!
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    else
      Sidekiq::Worker.clear_all
    end
  end
end

RSpec.configure do |config|
  config.extend AsyncBackends
end
