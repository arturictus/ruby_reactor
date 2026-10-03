# frozen_string_literal: true

require "spec_helper"

# 009 R-13, I-6: a resume that hands off persists the context BEFORE it
# releases the run's `async:` lock. Released first, another worker could take
# the lock, load the pre-save blob, and have its progress overwritten by the
# late save.
module ContextLockSaveOrderSpec
  class Elem < RubyReactor::Reactor
    input :i
    step(:double) do
      argument :i, input(:i)
      run { |args, _ctx| RubyReactor.Success(args.i * 2) }
    end
  end

  class Background < RubyReactor::Reactor
    background all: true
    input :items
    map :m, Elem do
      source input(:items)
      argument :i, element(:m)
      fan_out
    end
  end
end

RSpec.describe "Executor#resume_execution save order" do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  it "stores the context before releasing the context lock when the resume hands off" do
    id = ContextLockSaveOrderSpec::Background.run(items: [1, 2]).execution_id
    order = []
    allow_any_instance_of(RubyReactor::Lock).to receive(:release).and_wrap_original do |original, *args|
      order << :release if original.receiver.key == "lock:async:#{id}"
      original.call(*args)
    end
    allow(storage).to receive(:store_context).and_wrap_original do |original, context_id, *rest|
      order << :store if context_id == id
      original.call(context_id, *rest)
    end

    job = RubyReactor::Adapters::Sidekiq::Worker.jobs.shift
    RubyReactor::Adapters::Sidekiq::Worker.new.perform(*job["args"])

    expect(order).to include(:store, :release)
    expect(order.rindex(:store)).to be < order.index(:release)
  end
end
