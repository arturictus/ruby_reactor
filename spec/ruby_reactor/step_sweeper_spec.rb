# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyReactor::StepSweeper do
  subject(:sweeper) { described_class.new(storage: storage, async_router: router) }

  let(:storage) { RubyReactor.configuration.storage_adapter }
  let(:dispatched) { [] }
  let(:router) do
    captured = dispatched
    Class.new do
      define_singleton_method(:perform_step_async) { |**args| captured << args }
    end
  end

  let(:root_id) { "root-1" }
  let(:step_context_id) { "ctx-1" }

  def store_dispatched(step_name: :send_email, **overrides)
    record = {
      "status" => "dispatched",
      "dispatched_at" => Time.now.iso8601,
      "root_context_id" => root_id,
      "reactor_class_name" => "StepSweeperTestReactor",
      "step_context_id" => step_context_id,
      "step_name" => step_name.to_s
    }.merge(overrides)
    storage.store_step_result(step_context_id, step_name, record, "StepSweeperTestReactor")
  end

  def hold_lock(step_name)
    RubyReactor::Lock.new(
      RubyReactor.async_step_lock_key(step_context_id, step_name.to_s),
      owner: "live-worker", ttl: 60, auto_extend: false
    ).acquire
  end

  describe "#run_once" do
    it "re-dispatches a dispatched unit with no live worker" do
      store_dispatched

      expect(sweeper.run_once).to eq(1)
      expect(dispatched).to eq([{
                                 root_context_id: root_id,
                                 reactor_class_name: "StepSweeperTestReactor",
                                 step_context_id: step_context_id,
                                 step_name: "send_email"
                               }])
    end

    it "skips a unit whose worker still holds the liveness lock" do
      store_dispatched
      hold_lock(:send_email)

      expect(sweeper.run_once).to eq(0)
      expect(dispatched).to be_empty
    end

    it "skips a completed unit" do
      store_dispatched(status: "completed")
      storage.store_step_result(
        step_context_id, :send_email,
        { "status" => "completed", "success" => true }, "StepSweeperTestReactor"
      )

      expect(sweeper.run_once).to eq(0)
      expect(dispatched).to be_empty
    end

    it "skips a record predating recovery, which cannot name its root" do
      storage.store_step_result(
        step_context_id, :send_email,
        { "status" => "dispatched", "dispatched_at" => Time.now.iso8601 }, "StepSweeperTestReactor"
      )

      expect(sweeper.run_once).to eq(0)
      expect(dispatched).to be_empty
    end
  end
end
