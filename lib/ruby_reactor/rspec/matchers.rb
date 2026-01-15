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
          "expected reactor to be success, but failed with: #{subject.error.inspect}"
        end
      end

      ::RSpec::Matchers.define :be_failure do
        match do |subject|
          subject.ensure_executed!
          subject.failure?
        end

        failure_message do |subject|
          "expected reactor to be failure, but succeeded"
        end
      end

      ::RSpec::Matchers.define :have_run_step do |step_name|
        match do |subject|
          subject.ensure_executed!
          # Check if step is in execution trace
          trace = subject.reactor_instance.context.execution_trace
          entry = trace.find { |t| t[:step].to_s == step_name.to_s }

          return false unless entry

          result_matched = true
          if @check_result
            # Compare with actual result
            actual_result = subject.step_result(step_name)
            result_matched = if @expected_result.is_a?(Regexp)
                               actual_result.to_s.match?(@expected_result)
                             else
                               values_match?(@expected_result, actual_result)
                             end
          end

          order_matched = true
          if @after_step
            after_index = trace.index(entry)
            before_entry = trace.find { |t| t[:step].to_s == @after_step.to_s }
            if before_entry
              before_index = trace.index(before_entry)
              order_matched = after_index > before_index
            else
              order_matched = false
            end
          end

          result_matched && order_matched
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
            retries > 0
          end
        end

        chain :times do |count|
          @expected_retries = count
        end

        failure_message do |subject|
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

        failure_message do |subject|
          "expected reactor to have validation error on :#{field}"
        end
      end

      # Add more matchers as per plan
    end
  end
end
