# frozen_string_literal: true

require "spec_helper"

# Regression: a `fan_out` map is its own hand-off point (the collector resumes
# the parent in its own worker). When a `background before:/after:` cut point
# sits on a step AFTER the map, the collector's resumed context must be
# recognized as already running in a worker, or `StepExecutor#handoff_at?`
# re-fires the cut point and enqueues a second, redundant hand-off.
RSpec.describe "map fan-out followed by a background cut point" do
  before do
    allow(RubyReactor.configuration).to receive(:async_router).and_return(RubyReactor::Adapters::Sidekiq::Router)
    Sidekiq::Testing.fake!
  end

  after { Sidekiq::Testing.inline! }

  class MapBackgroundHandoffDoubleReactor < RubyReactor::Reactor
    input :number

    step :double do
      argument :number, input(:number)
      run { |args, _ctx| RubyReactor.Success(args[:number] * 2) }
    end

    returns :double
  end

  class MapThenBackgroundReactor < RubyReactor::Reactor
    input :numbers

    map :doubled, MapBackgroundHandoffDoubleReactor do
      source input(:numbers)
      argument :number, element(:doubled)
      fan_out
    end

    step :after_map do
      argument :doubled, result(:doubled)
      run { |_args, _ctx| RubyReactor.Success(:done) }
    end

    background after: :after_map

    returns :after_map
  end

  let(:element_worker) { RubyReactor::Adapters::Sidekiq::MapElementWorker }
  let(:collector_worker) { RubyReactor::Adapters::Sidekiq::MapCollectorWorker }
  let(:background_worker) { RubyReactor::Adapters::Sidekiq::Worker }

  it "completes in the collector's own job instead of enqueueing another hand-off" do
    reactor = MapThenBackgroundReactor.new
    result = reactor.run(numbers: [1, 2, 3])
    context_id = reactor.context.context_id

    expect(result).to be_a(RubyReactor::DispatchResult) # the map itself is the first hand-off

    element_worker.drain
    collector_worker.drain

    # The bug: the collector's resumed context still looks like the ORIGINAL
    # caller (inline_async_execution defaults false on deserialize), so the
    # `background after: :after_map` cut point re-fires and queues a second
    # Worker job instead of finishing here.
    expect(background_worker.jobs).to be_empty

    context = MapThenBackgroundReactor.find(context_id).context
    expect(context.status.to_s).to eq("completed")
    expect(context.intermediate_results[:after_map]).to eq(:done)
  end
end
