# frozen_string_literal: true

# Fixtures for spec/ruby_reactor/async_step_single_writer_spec.rb: an
# `async_step` unit never writes its parent's context. The unit's body below
# stands in for the parent saving newer progress WHILE the unit runs, which is
# exactly what a unit writing back its older snapshot would revert.
class SingleWriterCheckpointStep < RubyReactor::Step
  input :marker

  def run
    storage = RubyReactor.configuration.storage_adapter
    root_id = context.root_context&.context_id || context.context_id
    newer = RubyReactor::ContextSerializer.deserialize_hash(storage.retrieve_context(root_id, "SingleWriterReactor"))
    newer.private_data[:parent_checkpoint] = inputs.marker
    storage.store_context(root_id, RubyReactor::ContextSerializer.serialize(newer), "SingleWriterReactor")
    Success(:done)
  end
end

class SingleWriterReactor < RubyReactor::Reactor
  input :marker

  async_step :unit, SingleWriterCheckpointStep do
    argument :marker, input(:marker)
  end

  step :after do
    run { RubyReactor.Success(:after) }
  end
end
