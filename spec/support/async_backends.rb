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
    if backend == :active_job
      ActiveJob::Base.queue_adapter = :test
      # spec_helper leaves Sidekiq in fake mode for every example, and
      # `AsyncTestHelpers` prefers Sidekiq whenever it is faking — so the
      # ActiveJob lane only actually exercises ActiveJob once Sidekiq's test
      # mode is off.
      Sidekiq::Testing.disable!
    end
    example.run
  ensure
    ActiveJob::Base.queue_adapter = original_adapter
    Sidekiq::Testing.fake!
  end

  before do
    allow(RubyReactor.configuration).to receive(:async_router).and_return(AsyncBackends::BACKENDS.fetch(backend))
    if backend == :active_job
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    else
      Sidekiq::Worker.clear_all
    end
  end
end

RSpec.configure do |config|
  config.extend AsyncBackends
end
