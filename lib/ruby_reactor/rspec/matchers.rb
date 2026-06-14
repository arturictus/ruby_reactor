# frozen_string_literal: true

module RubyReactor
  module RSpec
    # rubocop:disable Metrics/ModuleLength
    module Matchers
      # rubocop:disable Metrics/BlockLength
      ::RSpec::Matchers.define :be_success do
        match do |subject|
          subject.ensure_executed! if subject.respond_to?(:ensure_executed!)
          subject.success?
        end

        failure_message do |subject|
          result = subject.respond_to?(:result) ? subject.result : subject
          if result&.failure?
            format_failure_message(result)
          elsif subject.respond_to?(:reactor_instance)
            "expected reactor to be success, but failed (Status: #{subject.reactor_instance.context.status})"
          else
            "expected #{subject.inspect} to be success"
          end
        end

        def format_failure_message(error)
          # Safely extract values
          err_msg = error.respond_to?(:error) ? error.error.to_s : error.to_s
          ex_class = error.respond_to?(:exception_class) ? error.exception_class : nil
          step = error.respond_to?(:step_name) ? error.step_name : nil
          file = error.respond_to?(:file_path) ? error.file_path : nil
          line = error.respond_to?(:line_number) ? error.line_number : nil
          snippet = error.respond_to?(:code_snippet) ? error.code_snippet : nil
          backtrace = error.respond_to?(:backtrace) ? error.backtrace : nil

          lines = []
          lines << "Error: #{ex_class || "UnknownError"}"
          lines << err_msg.to_s
          lines << "Step: :#{step}" if step
          lines << "File: #{file}:#{line}" if file

          append_snippet(lines, snippet)
          append_backtrace(lines, backtrace)

          lines.join("\n")
        end

        def append_snippet(lines, snippet)
          return unless snippet.is_a?(Array) && !snippet.empty?

          lines << ""
          snippet.each do |s|
            prefix = s[:target] ? "--> " : "    "
            lines << "#{prefix}#{s[:content]}"
          end
        end

        def append_backtrace(lines, backtrace)
          return unless backtrace && !backtrace.empty?

          lines << ""
          lines << "Backtrace:"
          lines << backtrace.take(10).map { |l| "- #{l}" }
        end
      end

      ::RSpec::Matchers.define :be_failure do
        match do |subject|
          subject.ensure_executed! if subject.respond_to?(:ensure_executed!)
          subject.failure?
        end

        failure_message do |_subject|
          "expected reactor to be failure, but succeeded"
        end
      end

      ::RSpec::Matchers.define :have_run_step do |step_name|
        match do |subject|
          subject.ensure_executed!
          @trace = subject.reactor_instance.context.execution_trace
          @entry = @trace.find { |t| t[:step].to_s == step_name.to_s }

          return false unless @entry

          matches_result?(subject, step_name) && matches_order?
        end

        def matches_result?(subject, step_name)
          return true unless @check_result

          actual_result = subject.step_result(step_name)
          if @expected_result.is_a?(Regexp)
            actual_result.to_s.match?(@expected_result)
          else
            values_match?(@expected_result, actual_result)
          end
        end

        def matches_order?
          return true unless @after_step

          after_index = @trace.index(@entry)
          before_entry = @trace.find { |t| t[:step].to_s == @after_step.to_s }

          return false unless before_entry

          after_index > @trace.index(before_entry)
        end

        chain :returning do |value|
          @check_result = true
          @expected_result = value
        end

        chain :after do |step|
          @after_step = step
        end

        failure_message do |subject|
          msg = "expected reactor to have run step :#{step_name}"
          if @check_result
            actual_result = subject.step_result(step_name)
            msg += " returning #{@expected_result.inspect}, but returned #{actual_result.inspect}"
          end
          msg += " after :#{@after_step}" if @after_step
          msg
        end
      end

      ::RSpec::Matchers.define :have_retried_step do |step_name|
        match do |subject|
          subject.ensure_executed!
          attempts = subject.reactor_instance.context.retry_context.attempts_for_step(step_name)
          retries = attempts - 1

          if @expected_retries
            retries == @expected_retries
          else
            retries.positive?
          end
        end

        chain :times do |count|
          @expected_retries = count
        end

        failure_message do |_subject|
          msg = "expected reactor to have retried step :#{step_name}"
          msg += " #{@expected_retries} times" if @expected_retries
          msg
        end
      end

      ::RSpec::Matchers.define :have_validation_error do |field|
        match do |subject|
          subject.ensure_executed!
          return false unless subject.failure?

          # Try to get validation errors from failure reason
          reason = subject.reactor_instance.context.failure_reason || {}

          # If failure is InputValidationError, it might be serialized differently
          # Or stored in validation_errors key
          errors = reason["validation_errors"] || reason[:validation_errors]

          if errors
            errors.key?(field.to_s) || errors.key?(field.to_sym)
          else
            false
          end
        end

        failure_message do |_subject|
          "expected reactor to have validation error on :#{field}"
        end
      end

      # Matcher to check if reactor is paused at an interrupt
      ::RSpec::Matchers.define :be_paused do
        match do |subject|
          subject.ensure_executed!
          subject.paused?
        end

        failure_message do |subject|
          "expected reactor to be paused, but status was #{subject.reactor_instance.context.status}"
        end

        failure_message_when_negated do |_subject|
          "expected reactor not to be paused, but it is"
        end
      end

      # Matcher to check if reactor is paused at a specific interrupt step
      # Works with both single and multiple concurrent interrupts
      ::RSpec::Matchers.define :be_paused_at do |*step_names|
        match do |subject|
          subject.ensure_executed!
          return false unless subject.paused?

          ready_steps = subject.ready_interrupt_steps
          step_names.all? { |name| ready_steps.include?(name.to_sym) }
        end

        failure_message do |subject|
          if subject.paused?
            ready_steps = subject.ready_interrupt_steps
            if step_names.size == 1
              "expected reactor to be paused at :#{step_names.first}, " \
                "but ready interrupt steps are: #{ready_steps.inspect}"
            else
              "expected reactor to be paused at #{step_names.map { |s| ":#{s}" }.join(", ")}, " \
                "but ready interrupt steps are: #{ready_steps.inspect}"
            end
          else
            "expected reactor to be paused at #{step_names.map { |s| ":#{s}" }.join(", ")}, " \
              "but status was #{subject.reactor_instance.context.status}"
          end
        end

        failure_message_when_negated do |_subject|
          "expected reactor not to be paused at #{step_names.map { |s| ":#{s}" }.join(", ")}, but it is"
        end
      end

      # Matcher to check the exact set of ready interrupt steps
      ::RSpec::Matchers.define :have_ready_interrupts do |*expected_steps|
        match do |subject|
          subject.ensure_executed!
          return false unless subject.paused?

          actual_steps = subject.ready_interrupt_steps.sort
          expected = expected_steps.map(&:to_sym).sort
          actual_steps == expected
        end

        failure_message do |subject|
          if subject.paused?
            actual_steps = subject.ready_interrupt_steps
            "expected ready interrupt steps to be #{expected_steps.map { |s| ":#{s}" }}, " \
              "but got #{actual_steps.inspect}"
          else
            "expected reactor to be paused with ready interrupt steps, " \
              "but status was #{subject.reactor_instance.context.status}"
          end
        end

        failure_message_when_negated do |subject|
          actual_steps = subject.ready_interrupt_steps
          "expected ready interrupt steps not to be #{expected_steps.map { |s| ":#{s}" }}, " \
            "but it was #{actual_steps.inspect}"
        end
      end

      # ---------------------------------------------------------------------
      # Lock / Semaphore / Rate-limit / Period state matchers
      # ---------------------------------------------------------------------
      #
      # These assert against the live Redis state via the configured storage
      # adapter, so they work for any test that has actually exercised the
      # reactor (or interacted with the primitives directly).

      def self.coordination_adapter
        RubyReactor.configuration.storage_adapter
      end

      # Distinguishes `RubyReactor::Skipped` from a plain `Success`. Works on
      # any object with a `skipped?` predicate.
      #
      # Examples:
      #   expect(result).to be_skipped
      #   expect(result).to be_skipped.because(:period)
      #   expect(result).to be_skipped.at_step(:second)
      ::RSpec::Matchers.define :be_skipped do
        match do |subject|
          subject.ensure_executed! if subject.respond_to?(:ensure_executed!)
          actual = subject.respond_to?(:result) ? subject.result : subject
          next false unless actual.respond_to?(:skipped?) && actual.skipped?
          next false if @expected_reason && actual.reason != @expected_reason
          next false if @expected_step && actual.step_name != @expected_step

          true
        end

        chain :because do |reason|
          @expected_reason = reason
        end

        chain :at_step do |step|
          @expected_step = step
        end

        failure_message do |subject|
          actual = subject.respond_to?(:result) ? subject.result : subject
          if !actual.respond_to?(:skipped?) || !actual.skipped?
            "expected result to be Skipped, got #{actual.class}"
          elsif @expected_reason && actual.reason != @expected_reason
            "expected Skipped reason #{@expected_reason.inspect}, got #{actual.reason.inspect}"
          else
            "expected Skipped at_step #{@expected_step.inspect}, got #{actual.step_name.inspect}"
          end
        end

        failure_message_when_negated do
          "expected result not to be Skipped"
        end
      end

      # Asserts that an exclusive lock is currently held in Redis. Subject is
      # the user-provided lock key (without the "lock:" prefix).
      #
      #   expect("order:42").to be_locked
      #   expect("order:42").to be_locked.by("ctx-abc")
      ::RSpec::Matchers.define :be_locked do
        match do |key|
          info = Matchers.coordination_adapter.lock_info("lock:#{key}")
          next false unless info
          next true unless @expected_owner

          info[:owner] == @expected_owner
        end

        chain :by do |owner|
          @expected_owner = owner
        end

        failure_message do |key|
          info = Matchers.coordination_adapter.lock_info("lock:#{key}")
          if info.nil?
            "expected lock 'lock:#{key}' to be held, but it is free"
          else
            "expected lock 'lock:#{key}' to be held by #{@expected_owner.inspect}, " \
              "but is held by #{info[:owner].inspect}"
          end
        end

        failure_message_when_negated do |key|
          info = Matchers.coordination_adapter.lock_info("lock:#{key}")
          "expected lock 'lock:#{key}' not to be held, but is held by #{info[:owner].inspect}"
        end
      end

      # Asserts the number of unallocated semaphore tokens. Subject is the
      # user-provided semaphore name (without the "semaphore:" prefix).
      #
      #   expect("api_limit").to have_available_tokens(3)
      ::RSpec::Matchers.define :have_available_tokens do |expected|
        match do |name|
          Matchers.coordination_adapter.semaphore_state(name)[:available] == expected
        end

        failure_message do |name|
          state = Matchers.coordination_adapter.semaphore_state(name)
          "expected semaphore '#{name}' to have #{expected} available tokens, " \
            "got #{state[:available]} (held: #{state[:held]}, limit: #{state[:limit]})"
        end
      end

      # Asserts the number of currently-checked-out semaphore tokens.
      #
      #   expect("api_limit").to have_held_tokens(2)
      ::RSpec::Matchers.define :have_held_tokens do |expected|
        match do |name|
          Matchers.coordination_adapter.semaphore_state(name)[:held] == expected
        end

        failure_message do |name|
          state = Matchers.coordination_adapter.semaphore_state(name)
          "expected semaphore '#{name}' to have #{expected} held tokens, " \
            "got #{state[:held]} (available: #{state[:available]}, limit: #{state[:limit]})"
        end
      end

      # Asserts the current rate-limit counter for a (key_base, period) pair.
      # Use `.for(period_unit)` to specify which window.
      #
      #   expect("stripe:42").to have_rate_limit_count(3).for(:second)
      ::RSpec::Matchers.define :have_rate_limit_count do |expected|
        match do |key_base|
          raise ArgumentError, "have_rate_limit_count requires .for(period)" unless @period

          Matchers.coordination_adapter.rate_limit_count(key_base, @period) == expected
        end

        chain :for do |period|
          @period = period
        end

        failure_message do |key_base|
          actual = Matchers.coordination_adapter.rate_limit_count(key_base, @period)
          "expected rate-limit '#{key_base}' (#{@period}) count to be #{expected}, got #{actual}"
        end
      end

      # Asserts that a `with_period` bucket has been marked. Use `.for(period)`.
      #
      #   expect("daily_report:7").to be_period_marked.for(:day)
      ::RSpec::Matchers.define :be_period_marked do
        match do |key_base|
          raise ArgumentError, "be_period_marked requires .for(period)" unless @period

          Matchers.coordination_adapter.period_marker?(key_base, @period)
        end

        chain :for do |period|
          @period = period
        end

        failure_message do |key_base|
          "expected period bucket #{RubyReactor::Period.key(key_base, @period).inspect} to be marked, but it is not"
        end

        failure_message_when_negated do |key_base|
          "expected period bucket #{RubyReactor::Period.key(key_base, @period).inspect} not to be marked, but it is"
        end
      end

      # Asserts the last-assigned ordered_lock nonce for a key. Subject is
      # the user-provided ordered_lock key (without the `ordered_lock:` prefix).
      #
      #   expect("orders:42").to have_ordered_lock_next(3)
      ::RSpec::Matchers.define :have_ordered_lock_next do |expected|
        match { |key| Matchers.coordination_adapter.ordered_lock_peek(key)[:next] == expected }

        failure_message do |key|
          state = Matchers.coordination_adapter.ordered_lock_peek(key)
          "expected ordered_lock '#{key}' next to be #{expected}, got #{state[:next]} " \
            "(last_completed: #{state[:last_completed]}, in_flight: #{state[:in_flight].inspect})"
        end
      end

      # Asserts the last-advanced cursor for an ordered_lock key.
      #
      #   expect("orders:42").to have_ordered_lock_last_completed(2)
      ::RSpec::Matchers.define :have_ordered_lock_last_completed do |expected|
        match do |key|
          Matchers.coordination_adapter.ordered_lock_peek(key)[:last_completed] == expected
        end

        failure_message do |key|
          state = Matchers.coordination_adapter.ordered_lock_peek(key)
          "expected ordered_lock '#{key}' last_completed to be #{expected}, " \
            "got #{state[:last_completed]} (next: #{state[:next]}, in_flight: #{state[:in_flight].inspect})"
        end
      end

      # Asserts the exact set of in-flight nonces for an ordered_lock key.
      # Order-insensitive — the matcher sorts both sides.
      #
      #   expect("orders:42").to have_ordered_lock_in_flight(2, 3)
      ::RSpec::Matchers.define :have_ordered_lock_in_flight do |*expected|
        match do |key|
          actual = Matchers.coordination_adapter.ordered_lock_peek(key)[:in_flight].sort
          actual == expected.flatten.map(&:to_i).sort
        end

        failure_message do |key|
          state = Matchers.coordination_adapter.ordered_lock_peek(key)
          "expected ordered_lock '#{key}' in_flight to be #{expected.flatten.sort.inspect}, " \
            "got #{state[:in_flight].inspect} (next: #{state[:next]}, last_completed: #{state[:last_completed]})"
        end
      end

      # Asserts an ordered_lock key has fully drained — counters GC'd, no
      # in-flight nonces. After a clean drain `peek` returns all zeros.
      #
      #   expect("orders:42").to be_ordered_lock_drained
      ::RSpec::Matchers.define :be_ordered_lock_drained do
        match do |key|
          state = Matchers.coordination_adapter.ordered_lock_peek(key)
          state[:next].zero? && state[:last_completed].zero? && state[:in_flight].empty?
        end

        failure_message do |key|
          state = Matchers.coordination_adapter.ordered_lock_peek(key)
          "expected ordered_lock '#{key}' to be drained, but state is #{state.inspect}"
        end

        failure_message_when_negated do |key|
          "expected ordered_lock '#{key}' not to be drained, but counters are all zero"
        end
      end

      # Add more matchers as per plan
      # rubocop:enable Metrics/BlockLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
