# frozen_string_literal: true

module RubyReactor
  module Web
    class CoordinationSerializer
      class << self
        def build(reactor_class, inputs:, context_id:, execution_trace: [], private_data: {})
          return {} unless reactor_class

          adapter = RubyReactor.configuration.storage_adapter
          normalized_inputs = normalize_inputs(inputs)
          result = {}

          if reactor_class.lock_config
            result[:lock] = build_lock(reactor_class.lock_config, normalized_inputs, context_id, adapter)
          end

          if reactor_class.semaphore_config
            result[:semaphore] = build_semaphore(reactor_class.semaphore_config, normalized_inputs, adapter)
          end

          if reactor_class.rate_limit_config
            result[:rate_limit] = build_rate_limit(reactor_class.rate_limit_config, normalized_inputs, adapter)
          end

          if reactor_class.period_config
            result[:period] = build_period(reactor_class.period_config, normalized_inputs, adapter)
          end

          if reactor_class.respond_to?(:steps)
            steps = build_steps(reactor_class, context_id, execution_trace, adapter)
            result[:steps] = steps unless steps.empty?
          end

          waiting = private_data[:step_contention] || private_data["step_contention"]
          result[:waiting] = normalize_waiting(waiting) if waiting

          result
        end

        private

        # US7/FR-029: one row per coordinating step, keyed to the step's
        # OWN resolved arguments (from its latest `:run` trace entry), not
        # the reactor's inputs. A step not yet reached is reported "pending"
        # rather than omitted, so the dashboard's step list is stable.
        def build_steps(reactor_class, context_id, execution_trace, adapter)
          reactor_class.steps.filter_map do |name, step_config|
            next unless step_config.respond_to?(:declares_coordination?) && step_config.declares_coordination?

            build_step_entry(name, step_config, context_id, execution_trace, adapter)
          end
        end

        def build_step_entry(name, step_config, context_id, execution_trace, adapter)
          entry = latest_run_entry(execution_trace, name)
          return { step: name.to_s, state: "pending" } unless entry

          primitive, config = step_config.coordination_declarations.first
          return { step: name.to_s, state: "pending" } unless primitive

          args = entry[:arguments] || entry["arguments"] || {}
          built = build_step_primitive(primitive, config, args, context_id, adapter)
          { step: name.to_s, primitive: primitive.to_s }.merge(built)
        end

        def build_step_primitive(primitive, config, args, context_id, adapter)
          case primitive
          when :lock then build_lock(config, args, context_id, adapter)
          when :semaphore then build_semaphore(config, args, adapter)
          when :rate_limit then build_rate_limit(config, args, adapter)
          when :period then build_period(config, args, adapter)
          else { key: resolve_key(config[:key_proc], args) }
          end
        rescue StandardError => e
          { key: nil, error: e.message }
        end

        def latest_run_entry(execution_trace, step_name)
          Array(execution_trace).reverse_each.find do |e|
            type = e[:type] || e["type"]
            step = e[:step] || e["step"]
            type.to_s == "run" && step.to_s == step_name.to_s
          end
        end

        def normalize_waiting(waiting)
          {
            step: (waiting[:step] || waiting["step"]).to_s,
            key: waiting[:key] || waiting["key"],
            primitive: (waiting[:primitive] || waiting["primitive"]).to_s,
            attempts: waiting[:attempts] || waiting["attempts"],
            next_attempt_at: waiting[:next_attempt_at] || waiting["next_attempt_at"]
          }
        end

        def normalize_inputs(inputs)
          return {} unless inputs.is_a?(Hash)

          inputs.transform_keys(&:to_sym)
        end

        def resolve_key(key_proc, inputs)
          key_proc.call(inputs).to_s
        end

        def build_lock(config, inputs, context_id, adapter)
          key = resolve_key(config[:key_proc], inputs)
          prefixed = "lock:#{key}"
          info = adapter.lock_info(prefixed)
          ttl = adapter.lock_ttl(prefixed)

          {
            configured: {
              ttl: config[:ttl],
              wait: config[:wait],
              auto_extend: config.fetch(:auto_extend, true)
            },
            key: key,
            state: lock_state(info, context_id, ttl)
          }
        rescue StandardError => e
          lock_error_payload(config, e)
        end

        def lock_state(info, context_id, ttl)
          if info
            {
              held: true,
              owner: info[:owner],
              owned_by_this_context: info[:owner] == context_id,
              reentrant_count: info[:count],
              ttl: ttl
            }
          else
            { held: false, ttl: ttl }
          end
        end

        def lock_error_payload(config, error)
          {
            configured: {
              ttl: config[:ttl],
              wait: config[:wait],
              auto_extend: config.fetch(:auto_extend, true)
            },
            key: nil,
            key_error: error.message
          }
        end

        def build_semaphore(config, inputs, adapter)
          key = resolve_key(config[:key_proc], inputs)
          state = adapter.semaphore_state(key)

          {
            configured: {
              limit: config[:limit],
              wait: config[:wait]
            },
            key: key,
            state: state
          }
        rescue StandardError => e
          {
            configured: { limit: config[:limit], wait: config[:wait] },
            key: nil,
            key_error: e.message
          }
        end

        def build_rate_limit(config, inputs, adapter)
          key = resolve_key(config[:key_proc], inputs)
          now = Time.now.to_i
          windows = config[:limits].map do |window|
            every = window[:name].to_sym
            {
              name: window[:name],
              limit: window[:limit],
              period_seconds: window[:period_seconds],
              count: adapter.rate_limit_count(key, every, now: now),
              ttl: adapter.rate_limit_ttl(key, every, now: now)
            }
          end

          {
            configured: { limits: map_limits(config[:limits]) },
            key: key,
            state: windows
          }
        rescue StandardError => e
          {
            configured: { limits: map_limits(config[:limits]) },
            key: nil,
            key_error: e.message
          }
        end

        def map_limits(limits)
          Array(limits).map do |window|
            {
              name: window[:name],
              limit: window[:limit],
              period_seconds: window[:period_seconds]
            }
          end
        end

        def build_period(config, inputs, adapter)
          key = resolve_key(config[:key_proc], inputs)
          every = config[:every]
          bucket_key = RubyReactor::Period.key(key, every)
          marked = adapter.period_marker?(key, every)
          ttl = adapter.period_ttl(key, every)

          {
            configured: { every: every.to_s },
            key: key,
            bucket_key: bucket_key,
            state: {
              marked: marked,
              ttl: ttl
            }
          }
        rescue StandardError => e
          {
            configured: { every: config[:every].to_s },
            key: nil,
            bucket_key: nil,
            key_error: e.message
          }
        end
      end
    end
  end
end
