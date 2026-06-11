# frozen_string_literal: true

module RubyReactor
  module Web
    class CoordinationSerializer
      class << self
        def build(reactor_class, inputs:, context_id:)
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

          result
        end

        private

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
