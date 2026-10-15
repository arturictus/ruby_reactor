# frozen_string_literal: true

module RubyReactor
  module Adapters
    module Sidekiq
      # Every method enqueues on `queue:` (011 R-03), or on the global
      # `queue_name` read now when it is nil. A given queue is also added to
      # the job's arguments, so the job knows where it runs; without one the
      # arguments are exactly what they were before queues existed.
      class Router
        # Identity-only payload: the worker rehydrates the live context from storage
        # by (context_id, reactor_class_name). The caller already holds context_id, so
        # there is no blob to deserialize here.
        def self.perform_async(context_id, reactor_class_name = nil, intermediate_results: {}, queue: nil)
          job_id = on(RubyReactor::Adapters::Sidekiq::Worker, queue)
                   .perform_async(context_id, reactor_class_name, *([0, queue.to_s] if queue))
          RubyReactor::DispatchResult.new(job_id: job_id, intermediate_results: intermediate_results,
                                          execution_id: context_id)
        end

        # `snooze_count` is the root Worker's snooze counter, carried only with a queue.
        # rubocop:disable Metrics/ParameterLists
        def self.perform_in(delay, context_id, reactor_class_name = nil, intermediate_results: {}, queue: nil,
                            snooze_count: 0)
          # rubocop:enable Metrics/ParameterLists
          job_id = on(RubyReactor::Adapters::Sidekiq::Worker, queue)
                   .perform_in(delay, context_id, reactor_class_name, *([snooze_count, queue.to_s] if queue))
          RubyReactor::DispatchResult.new(job_id: job_id, intermediate_results: intermediate_results,
                                          execution_id: context_id)
        end

        # One `async_step`'s work, dispatched as its own independent unit. The
        # payload is identity-only for the same reason every other dispatch here
        # is: the worker rehydrates the parent context from storage.
        def self.perform_step_async(root_context_id:, reactor_class_name:, step_context_id:, step_name:, queue: nil)
          job_id = on(RubyReactor::Adapters::Sidekiq::StepWorker, queue).perform_async(
            with_queue({
                         "root_context_id" => root_context_id,
                         "reactor_class_name" => reactor_class_name,
                         "step_context_id" => step_context_id,
                         "step_name" => step_name.to_s
                       }, queue)
          )
          RubyReactor::DispatchResult.new(job_id: job_id)
        end

        # Delayed re-enqueue of an `async_step`'s body — the park path
        # (Finding 6): the worker rescues `StepCoordination::Contended` and
        # reschedules itself instead of failing, carrying the contention
        # attempt count forward so `lock_snooze_max_attempts` still bounds it.
        # rubocop:disable Metrics/ParameterLists
        def self.perform_step_in(delay, root_context_id:, reactor_class_name:, step_context_id:, step_name:,
                                 contention_attempts: 0, queue: nil)
          # rubocop:enable Metrics/ParameterLists
          job_id = on(RubyReactor::Adapters::Sidekiq::StepWorker, queue).perform_in(
            delay,
            with_queue({
                         "root_context_id" => root_context_id,
                         "reactor_class_name" => reactor_class_name,
                         "step_context_id" => step_context_id,
                         "step_name" => step_name.to_s,
                         "contention_attempts" => contention_attempts
                       }, queue)
          )
          RubyReactor::DispatchResult.new(job_id: job_id)
        end

        def self.perform_map_element_async(queue: nil, owner_queue: nil, **args)
          job_id = on(RubyReactor::Adapters::Sidekiq::MapElementWorker, queue)
                   .perform_async(with_queue(map_element_payload(**args), queue, owner_queue))
          RubyReactor::DispatchResult.new(job_id: job_id)
        end

        def self.perform_map_element_in(delay, queue: nil, owner_queue: nil, **args)
          job_id = on(RubyReactor::Adapters::Sidekiq::MapElementWorker, queue)
                   .perform_in(delay, with_queue(map_element_payload(**args), queue, owner_queue))
          # Return an DispatchResult so RetryManager#handle_async_retry recognises the
          # element was successfully requeued and yields a RetryQueuedResult.
          RubyReactor::DispatchResult.new(job_id: job_id)
        end

        # rubocop:disable Metrics/ParameterLists
        def self.map_element_payload(map_id:, element_id:, index:, serialized_inputs:, reactor_class_info:,
                                     strict_ordering:, parent_context_id:, parent_reactor_class_name:,
                                     step_name:, batch_size: nil, serialized_context: nil, atomic: nil)
          # rubocop:enable Metrics/ParameterLists
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
            "atomic" => atomic
          }
        end
        private_class_method :map_element_payload

        # One element's rollback in a fan-out map's distributed rollback (009
        # R-07); the `_in` form is its requeue on a contended element lock.
        def self.perform_map_element_rollback_async(queue: nil, **args)
          job_id = on(RubyReactor::Adapters::Sidekiq::MapElementRollbackWorker, queue)
                   .perform_async(with_queue(map_element_rollback_payload(**args), queue))
          RubyReactor::DispatchResult.new(job_id: job_id)
        end

        def self.perform_map_element_rollback_in(delay, queue: nil, **args)
          job_id = on(RubyReactor::Adapters::Sidekiq::MapElementRollbackWorker, queue).perform_in(
            delay, with_queue(map_element_rollback_payload(**args), queue)
          )
          RubyReactor::DispatchResult.new(job_id: job_id)
        end

        # rubocop:disable Metrics/ParameterLists
        def self.map_element_rollback_payload(map_id:, position:, element_context_id:, reactor_class_info:,
                                              parent_reactor_class_name:, step_name:, batch_size:, owner_context_id:,
                                              owner_reactor_class_name:, attempt: 0)
          {
            "map_id" => map_id, "position" => position, "element_context_id" => element_context_id,
            "reactor_class_info" => reactor_class_info, "parent_reactor_class_name" => parent_reactor_class_name,
            "step_name" => step_name, "batch_size" => batch_size, "owner_context_id" => owner_context_id,
            "owner_reactor_class_name" => owner_reactor_class_name, "attempt" => attempt
          }
        end
        # rubocop:enable Metrics/ParameterLists
        private_class_method :map_element_rollback_payload

        # rubocop:disable Metrics/ParameterLists
        def self.perform_map_collection_async(parent_context_id:, map_id:, parent_reactor_class_name:, step_name:,
                                              strict_ordering:, timeout:, queue: nil)
          job_id = on(RubyReactor::Adapters::Sidekiq::MapCollectorWorker, queue).perform_async(
            with_queue({
                         "parent_context_id" => parent_context_id,
                         "map_id" => map_id,
                         "parent_reactor_class_name" => parent_reactor_class_name,
                         "step_name" => step_name,
                         "strict_ordering" => strict_ordering,
                         "timeout" => timeout
                       }, queue)
          )
          RubyReactor::DispatchResult.new(job_id: job_id)
        end
        # rubocop:enable Metrics/ParameterLists

        def self.on(worker_class, queue)
          worker_class.set(queue: (queue || RubyReactor.configuration.queue_name).to_s)
        end
        private_class_method :on

        def self.with_queue(payload, queue, owner_queue = nil)
          payload["queue"] = queue.to_s if queue
          payload["owner_queue"] = owner_queue.to_s if owner_queue
          payload
        end
        private_class_method :with_queue
      end
    end
  end
end
