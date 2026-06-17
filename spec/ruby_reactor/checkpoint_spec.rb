# frozen_string_literal: true

require "spec_helper"

# Phase 2: save-per-step durable checkpoints. checkpoint! always serializes and
# stores the ROOT context under the root's key (F1), and the on_step_complete
# callback is wired into every executor including the nested ones ComposeStep
# builds (F8) — so a composed sub-reactor's per-step checkpoint advances the ROOT
# blob, never a sub-key.
class CkChildReactor < RubyReactor::Reactor
  input :n
  step :double do
    argument :n, input(:n)
    run { |a, _| RubyReactor.Success(a[:n] * 2) }
  end
end

class CkParentReactor < RubyReactor::Reactor
  input :n
  step :prep do
    argument :n, input(:n)
    run { |a, _| RubyReactor.Success(a[:n] + 1) }
  end
  compose :child, CkChildReactor do
    argument :n, result(:prep)
  end
end

class CkThreeStepReactor < RubyReactor::Reactor
  input :n
  step :a do
    argument :n, input(:n)
    run { |args, _| RubyReactor.Success(args[:n] + 1) }
  end
  step :b do
    argument :a, result(:a)
    run { |args, _| RubyReactor.Success(args[:a] + 1) }
  end
  step :c do
    argument :b, result(:b)
    run { |args, _| RubyReactor.Success(args[:b] + 1) }
  end
end

RSpec.describe "Per-step checkpoints" do
  let(:storage) { RubyReactor.configuration.storage_adapter }

  def count_root_writes
    writes = 0
    allow(storage).to receive(:store_context).and_wrap_original do |orig, id, serialized, name|
      writes += 1 unless JSON.parse(serialized)["parent_context_id"]
      orig.call(id, serialized, name)
    end
    yield
    writes
  end

  describe "checkpoint_min_interval throttling" do
    around do |example|
      original = RubyReactor.configuration.checkpoint_min_interval
      example.run
      RubyReactor.configuration.checkpoint_min_interval = original
    end

    it "writes a checkpoint after every step when the interval is 0 (default)" do
      RubyReactor.configuration.checkpoint_min_interval = 0
      writes = count_root_writes { expect(CkThreeStepReactor.run(n: 1)).to be_success }
      # running save (1) + one checkpoint per completed step (3) + terminal save (1).
      expect(writes).to be >= 4
    end

    it "coalesces mid-run checkpoints when the interval is large" do
      RubyReactor.configuration.checkpoint_min_interval = 3600
      throttled = count_root_writes { expect(CkThreeStepReactor.run(n: 1)).to be_success }

      RubyReactor.configuration.checkpoint_min_interval = 0
      unthrottled = count_root_writes { expect(CkThreeStepReactor.run(n: 1)).to be_success }

      # A large interval suppresses the 2nd/3rd per-step checkpoints, so it must
      # write strictly fewer times than the per-step default for the same reactor.
      expect(throttled).to be < unthrottled
    end
  end

  it "checkpoints the ROOT repeatedly across steps (save-per-step, not one terminal save)" do
    root_id = nil
    writes_by_id = Hash.new(0)
    allow(storage).to receive(:store_context).and_wrap_original do |orig, id, serialized, name|
      writes_by_id[id] += 1
      # The root is the context with no parent_context_id.
      root_id ||= id unless JSON.parse(serialized)["parent_context_id"]
      orig.call(id, serialized, name)
    end

    expect(CkParentReactor.run(n: 1)).to be_success

    # The root received several writes (running save + a checkpoint per completed
    # step, including the nested child's inner step via the F8 callback) — not a
    # single terminal save. (The child executor's own observability save_context
    # legitimately writes its sub-key too; that is separate from checkpoint!.)
    expect(writes_by_id[root_id]).to be >= 3
  end

  it "embeds the nested child's completed inner step in the ROOT blob (F8 resume state)" do
    CkParentReactor.run(n: 5)
    # The exact state a rehydrate-by-root-id worker would resume from: the root
    # carries the parent's prep result AND the composed child's inner-step progress.
    stored = storage.scan_reactors.find { |r| r[:class] == "CkParentReactor" }
    data = storage.retrieve_context(stored[:id], "CkParentReactor")

    expect(data["intermediate_results"]).to have_key("prep")
    child = data["composed_contexts"]["child"]["context"]
    child = child["value"] if child.is_a?(Hash) && child.key?("value")
    expect(child["intermediate_results"]).to have_key("double")
  end

  describe "deserialize_hash" do
    it "round-trips a stored context identically to the string path" do
      context = RubyReactor::Context.new({ n: 7 }, CkParentReactor)
      context.status = :running
      serialized = RubyReactor::ContextSerializer.serialize(context)

      from_string = RubyReactor::ContextSerializer.deserialize(serialized)
      from_hash = RubyReactor::ContextSerializer.deserialize_hash(JSON.parse(serialized))

      expect(from_hash.context_id).to eq(from_string.context_id)
      expect(from_hash.status).to eq(from_string.status)
      expect(from_hash.inputs).to eq(from_string.inputs)
    end

    it "schema-validates and raises on an unknown version" do
      expect do
        RubyReactor::ContextSerializer.deserialize_hash("schema_version" => "0.0", "context_id" => "x")
      end.to raise_error(RubyReactor::Error::SchemaVersionError)
    end
  end
end
