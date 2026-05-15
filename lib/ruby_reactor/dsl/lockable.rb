# frozen_string_literal: true

module RubyReactor
  module Dsl
    module Lockable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        attr_reader :lock_config, :semaphore_config, :period_config, :rate_limit_config

        # Propagate lock/semaphore/period/rate-limit config to subclasses;
        # without this a subclass of a configured reactor would silently lose
        # those settings.
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@lock_config, @lock_config) if @lock_config
          subclass.instance_variable_set(:@semaphore_config, @semaphore_config) if @semaphore_config
          subclass.instance_variable_set(:@period_config, @period_config) if @period_config
          subclass.instance_variable_set(:@rate_limit_config, @rate_limit_config) if @rate_limit_config
        end

        # Configure locking for this reactor
        # @param ttl [Integer] Time to live in seconds (default: 60)
        # @param wait [Integer] Time to wait for lock in seconds (default: 0)
        # @param auto_extend [Boolean] When true (default), a background thread
        #   refreshes the lock TTL every ttl/3 seconds while the reactor runs,
        #   protecting steps that may legitimately outlast `ttl`. Pass `false`
        #   to disable and rely solely on `ttl` for expiry.
        # @yield [inputs] Block that returns the lock key string
        def with_lock(ttl: 60, wait: 0, auto_extend: true, &block)
          @lock_config = {
            ttl: ttl,
            wait: wait,
            auto_extend: auto_extend,
            key_proc: block
          }
        end

        # Configure semaphore for this reactor
        # @param limit [Integer] Maximum concurrent executions
        # @param wait [Integer] Time to wait for a token in seconds (default: 0)
        # @yield [inputs] Block that returns the semaphore key string
        def with_semaphore(limit:, wait: 0, &block)
          @semaphore_config = {
            limit: limit,
            wait: wait,
            key_proc: block
          }
        end

        # Configure a calendar-aligned dedup window for this reactor. The
        # reactor will run at most once per bucket per key; subsequent calls
        # in the same bucket return `RubyReactor::Skipped` without executing
        # any steps.
        #
        # Note: `with_period` is *dedup*, not *concurrency*. Two concurrent
        # racers can both see no marker and both run. Pair with `with_lock`
        # for true at-most-one semantics within the bucket.
        #
        # @param every [Symbol, Integer] :minute / :hour / :day / :week /
        #   :month / :year, or an integer number of seconds for a sliding
        #   bucket (index = `time.to_i / every`).
        # @yield [inputs] Block that returns the period key base. The final
        #   Redis marker key is `period:<base>:<bucket_id>`.
        def with_period(every:, &block)
          # Validate eagerly so misconfiguration surfaces at class load time.
          RubyReactor::Period.period_seconds(every)

          @period_config = {
            every: every,
            key_proc: block
          }
        end

        # Configure rate limiting for this reactor (fixed-window counter).
        # Pass either a single window via `limit:` + `period:`, or a hash of
        # windows via `limits:` for layered API quotas.
        #
        # @example Single window
        #   with_rate_limit(limit: 3, period: :second) { |i| "stripe:#{i[:account_id]}" }
        #
        # @example Multi-window (3/sec AND 100/min AND 5000/hr)
        #   with_rate_limit(
        #     limits: { second: 3, minute: 100, hour: 5000 }
        #   ) { |i| "stripe:#{i[:account_id]}" }
        #
        # @param limit [Integer] requests per period (single-window form)
        # @param period [Symbol, Integer] :second / :minute / :hour / :day /
        #   :week / :month / :year, or integer seconds (single-window form)
        # @param limits [Hash{Symbol,Integer => Integer}] mapping of period
        #   unit to limit (multi-window form)
        # @yield [inputs] Block returning the rate-limit key base.
        def with_rate_limit(limit: nil, period: nil, limits: nil, &block)
          normalized = normalize_rate_limit_args(limit, period, limits)

          @rate_limit_config = {
            limits: normalized,
            key_proc: block
          }
        end

        private

        def normalize_rate_limit_args(limit, period, limits)
          if limits
            raise ArgumentError, "with_rate_limit: use either :limits, or :limit + :period, not both" if limit || period

            limits.map do |period_key, limit_val|
              {
                period_seconds: RubyReactor::Period.period_seconds(period_key),
                limit: Integer(limit_val),
                name: period_key.to_s
              }
            end
          elsif limit && period
            [{
              period_seconds: RubyReactor::Period.period_seconds(period),
              limit: Integer(limit),
              name: period.to_s
            }]
          else
            raise ArgumentError, "with_rate_limit requires :limit + :period, or :limits"
          end
        end
      end
    end
  end
end
