# frozen_string_literal: true

module RubyReactor
  module RSpec
    module Matchers
      ::RSpec::Matchers.define :be_success do
        match do |subject|
          subject.ensure_executed!
          subject.success?
        end

        failure_message do |subject|
          result = subject.result
          if result && result.failure?
            error = result # Use the Failure object which contains all metadata
            # Safely extract values
            err_msg = error.respond_to?(:error) ? error.error.to_s : error.to_s
            # If error.error is the message string, use it.
            # Note: RubyReactor::Failure#error_message does extraction logic usually.

            ex_class = error.respond_to?(:exception_class) ? error.exception_class : nil
            step = error.respond_to?(:step_name) ? error.step_name : nil
            file = error.respond_to?(:file_path) ? error.file_path : nil
            line = error.respond_to?(:line_number) ? error.line_number : nil
            snippet = error.respond_to?(:code_snippet) ? error.code_snippet : nil
            backtrace = error.respond_to?(:backtrace) ? error.backtrace : nil

            # Error details are now extracted by RubyReactor::Failure#initialize when error is a Hash
            # so we don't need to try and parse the message string manually.

            # Build Formatted Message
            lines = []
            lines << "Error: #{ex_class || "UnknownError"}"
            lines << "#{err_msg}"
            lines << "Step: :#{step}" if step
            lines << "File: #{file}:#{line}" if file

            if snippet.is_a?(Array) && !snippet.empty?
              lines << ""
              snippet.each do |s|
                prefix = s[:target] ? "--> " : "    "
                lines << "#{prefix}#{s[:content]}"
              end
            end

            if backtrace && !backtrace.empty?
              lines << ""
              lines << "Backtrace:"
              lines << backtrace.take(10).map { |l| "- #{l}" }
            end

            lines.join("\n")
          else
            "expected reactor to be success, but failed (Status: #{subject.reactor_instance.context.status})"
          end
        end
      end

      ::RSpec::Matchers.define :be_failure do
        match do |subject|
          subject.ensure_executed!
          subject.failure?
        end

        failure_message do |_subject|
          "expected reactor to be failure, but succeeded"
        end
      end

      # rubocop:disable Metrics/BlockLength
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

      # Add more matchers as per plan
      # rubocop:enable Metrics/BlockLength
    end
  end
end
