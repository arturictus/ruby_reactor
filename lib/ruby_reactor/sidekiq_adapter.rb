# frozen_string_literal: true

module RubyReactor
  class SidekiqAdapter
    def self.perform_async(serialized_context, reactor_class_name = nil, intermediate_results: {})
      job_id = SidekiqWorkers::Worker.perform_async(serialized_context, reactor_class_name)
      context = ContextSerializer.deserialize(serialized_context)
      RubyReactor::AsyncResult.new(job_id: job_id, intermediate_results: intermediate_results,
                                   execution_id: context.context_id)
    end

    def self.perform_in(delay, serialized_context, reactor_class_name = nil, intermediate_results: {})
      job_id = SidekiqWorkers::Worker.perform_in(delay, serialized_context, reactor_class_name)
      context = ContextSerializer.deserialize(serialized_context)
      RubyReactor::AsyncResult.new(job_id: job_id, intermediate_results: intermediate_results,
                                   execution_id: context.context_id)
    end

    # rubocop:disable Metrics/ParameterLists
    def self.perform_map_element_async(map_id:, element_id:, index:, serialized_inputs:, reactor_class_info:,
                                       strict_ordering:, parent_context_id:, parent_reactor_class_name:, step_name:,
                                       batch_size: nil, serialized_context: nil, fail_fast: nil)
      RubyReactor::SidekiqWorkers::MapElementWorker.perform_async(
        {
          "map_id" => map_id,
          "element_id" => element_id,
          "index" => index,
          "serialized_inputs" => serialized_inputs,
          "reactor_class_info" => reactor_class_info,
          "strict_ordering" => strict_ordering,
          "parent_context_id" => parent_context_id,
          "parent_reactor_class_name" => parent_reactor_class_name,
          "step_name" => step_name,
          "batch_size" => batch_size,
          "serialized_context" => serialized_context,
          "fail_fast" => fail_fast
        }
      )
    end

    def self.perform_map_element_in(delay, map_id:, element_id:, index:, serialized_inputs:, reactor_class_info:,
                                    strict_ordering:, parent_context_id:, parent_reactor_class_name:, step_name:,
                                    batch_size: nil, serialized_context: nil)
      RubyReactor::SidekiqWorkers::MapElementWorker.perform_in(
        delay,
        {
          "map_id" => map_id,
          "element_id" => element_id,
          "index" => index,
          "serialized_inputs" => serialized_inputs,
          "reactor_class_info" => reactor_class_info,
          "strict_ordering" => strict_ordering,
          "parent_context_id" => parent_context_id,
          "parent_reactor_class_name" => parent_reactor_class_name,
          "step_name" => step_name,
          "batch_size" => batch_size,
          "serialized_context" => serialized_context
        }
      )
    end
    # rubocop:enable Metrics/ParameterLists

    # rubocop:disable Metrics/ParameterLists
    def self.perform_map_collection_async(parent_context_id:, map_id:, parent_reactor_class_name:, step_name:,
                                          strict_ordering:, timeout:)
      RubyReactor::SidekiqWorkers::MapCollectorWorker.perform_async(
        {
          "parent_context_id" => parent_context_id,
          "map_id" => map_id,
          "parent_reactor_class_name" => parent_reactor_class_name,
          "step_name" => step_name,
          "strict_ordering" => strict_ordering,
          "timeout" => timeout
        }
      )
    end
    # rubocop:enable Metrics/ParameterLists

    def self.perform_map_execution_async(map_id:, serialized_inputs:, reactor_class_info:, strict_ordering:,
                                         parent_context_id:, parent_reactor_class_name:, step_name:, fail_fast: nil)
      RubyReactor::SidekiqWorkers::MapExecutionWorker.perform_async(
        {
          "map_id" => map_id,
          "serialized_inputs" => serialized_inputs,
          "reactor_class_info" => reactor_class_info,
          "strict_ordering" => strict_ordering,
          "parent_context_id" => parent_context_id,
          "parent_reactor_class_name" => parent_reactor_class_name,
          "step_name" => step_name,
          "fail_fast" => fail_fast
        }
      )
    end

    def self.inline!(&block)
      if defined?(Sidekiq::Testing)
        Sidekiq::Testing.inline!(&block)
      else
        yield
      end
    end
  end
end
