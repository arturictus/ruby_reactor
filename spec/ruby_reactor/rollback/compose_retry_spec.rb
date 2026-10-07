# frozen_string_literal: true

require "spec_helper"

# US2 (F-02, 008 R-14): a parent never retries a nested reactor as a whole.
# The child retries its own steps; a park/resume still resumes.
module ComposeRetrySpec
  class Child < RollbackRecorder::Reactor
    tag "child"
    recording_step :c1
  end

  class ChildRetriesOnce < RollbackRecorder::Reactor
    tag "child"
    recording_step :c1
    recording_step(:c2, after: :c1, fail: 1) { retries max_attempts: 2, base_delay: 0 }
  end

  class ChildRetriesExhausted < RollbackRecorder::Reactor
    tag "child"
    input :from_a
    recording_step :c1
    recording_step(:c2, after: :c1, fail: true) { retries max_attempts: 2, base_delay: 0 }
  end

  class RetriesInChild < RollbackRecorder::Reactor
    compose :child, ChildRetriesOnce
  end

  class RetriesInChildThenFails < RollbackRecorder::Reactor
    compose :child, ChildRetriesOnce
    recording_step :b, after: :child, fail: true
  end

  class ChildExhausted < RollbackRecorder::Reactor
    recording_step :a
    compose(:child, ChildRetriesExhausted) { argument :from_a, result(:a) }
  end

  class ParkingStep < RubyReactor::Step
    input :key

    with_lock { |a| "compose_retry:park:#{a[:key]}" }

    def run
      RollbackRecorder.record("run:child.c2")
      Success(:ok)
    end
  end

  class ParkingChild < RollbackRecorder::Reactor
    tag "child"
    input :key
    recording_step :c1
    step :c2, ParkingStep do
      argument :key, input(:key)
      wait_for :c1
    end
  end

  class ParkingParent < RollbackRecorder::Reactor
    background all: true
    input :key
    compose(:child, ParkingChild) { argument :key, input(:key) }
  end
end

RSpec.describe "a nested reactor is never retried as a whole", type: :reactor do
  let(:worker_class) { RubyReactor::Adapters::Sidekiq::Worker }

  it "rejects `retries` on a compose (class form)" do
    expect { Class.new(RubyReactor::Reactor) { compose(:child, ComposeRetrySpec::Child) { retries max_attempts: 2 } } }
      .to raise_error(RubyReactor::Error::DeprecatedDslError, /:child\b.*own steps/m)
  end

  it "rejects `retries` in an inline compose block" do
    expect do
      Class.new(RubyReactor::Reactor) do
        compose :child do
          retries max_attempts: 2
          step(:c1) { run { |_args, _ctx| RubyReactor.Success(1) } }
        end
      end
    end.to raise_error(RubyReactor::Error::DeprecatedDslError, /:child\b.*own steps/m)
  end

  it "rejects `retries` on an async_reactor" do
    expect { Class.new(RubyReactor::Reactor) { async_reactor(:child, ComposeRetrySpec::Child) { retries max_attempts: 2 } } }
      .to raise_error(RubyReactor::Error::DeprecatedDslError, /:child\b.*own steps/m)
  end

  it "lets the child retry its own step without re-running the others (S-compose-05b)" do
    result = ComposeRetrySpec::RetriesInChild.run({})

    expect(result).to be_success
    expect(RollbackRecorder.log).to eq(%w[run:child.c1 run:child.c2 run:child.c2])
  end

  it "undoes each child step exactly once on a later parent failure" do
    result = ComposeRetrySpec::RetriesInChildThenFails.run({})

    expect(result).to be_failure
    expect(RollbackRecorder.log).to eq(
      %w[run:child.c1 run:child.c2 run:child.c2 run:b compensate:b undo:child.c2 undo:child.c1]
    )
  end

  it "fails the compose, without running the child again, once the child's retries run out" do
    result = ComposeRetrySpec::ChildExhausted.run({})

    expect(result).to be_failure
    expect(RollbackRecorder.log).to eq(
      %w[run:a run:child.c1 run:child.c2 run:child.c2 compensate:child.c2 undo:child.c1 undo:a]
    )
  end

  it "resumes, not retries, a child that parked after c1 completed" do
    key = SecureRandom.hex(4)
    holder = RubyReactor::Lock.new("compose_retry:park:#{key}", owner: "external", ttl: 30, auto_extend: false)
    holder.acquire
    ComposeRetrySpec::ParkingParent.run(key: key)

    worker_class.new.perform(*worker_class.jobs.shift["args"]) # parks at c2
    holder.release
    worker_class.new.perform(*worker_class.jobs.shift["args"]) # resumes

    expect(RollbackRecorder.log).to eq(%w[run:child.c1 run:child.c2])
  ensure
    holder&.release
  end
end
