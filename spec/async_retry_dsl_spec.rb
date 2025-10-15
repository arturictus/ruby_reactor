# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RubyReactor Async and Retry DSL" do
  describe "Reactor DSL extensions" do
    it "supports async class method" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        async true
      end

      expect(reactor_class.async?).to be true
    end

    it "supports retry_defaults class method" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        retry_defaults max_attempts: 5, backoff: :linear, base_delay: 2
      end

      expect(reactor_class.get_retry_defaults).to eq({
        max_attempts: 5,
        backoff: :linear,
        base_delay: 2
      })
    end
  end

  describe "Step DSL extensions" do
    it "supports async option in step builder" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        step :test_step do
          async true

          run { |args, context| RubyReactor.Success("done") }
        end
      end

      step_config = reactor_class.steps[:test_step]
      expect(step_config.async?).to be true
    end

    it "supports retry configuration in step builder" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        step :test_step do
          retries max_attempts: 3, backoff: :exponential, base_delay: 1, idempotent: true

          run { |args, context| RubyReactor.Success("done") }
        end
      end

      step_config = reactor_class.steps[:test_step]
      expect(step_config.retryable?).to be true
      expect(step_config.idempotent?).to be true
      expect(step_config.retry_config[:max_attempts]).to eq(3)
      expect(step_config.retry_config[:backoff]).to eq(:exponential)
      expect(step_config.retry_config[:base_delay]).to eq(1)
    end

    it "supports idempotent method in step builder" do
      reactor_class = Class.new(RubyReactor::Reactor) do
        step :test_step do
          idempotent true

          run { |args, context| RubyReactor.Success("done") }
        end
      end

      step_config = reactor_class.steps[:test_step]
      expect(step_config.idempotent?).to be true
    end
  end

  describe "Core classes" do
    it "RetryContext tracks step attempts" do
      context = RubyReactor::RetryContext.new

      expect(context.attempts_for_step(:step1)).to eq(0)

      context.increment_attempt_for_step(:step1)
      expect(context.attempts_for_step(:step1)).to eq(1)

      context.increment_attempt_for_step(:step1)
      expect(context.attempts_for_step(:step1)).to eq(2)
    end

    it "RetryContext checks retry eligibility" do
      context = RubyReactor::RetryContext.new

      expect(context.can_retry_step?(:step1, 3)).to be true

      context.increment_attempt_for_step(:step1)
      expect(context.can_retry_step?(:step1, 3)).to be true

      context.increment_attempt_for_step(:step1)
      context.increment_attempt_for_step(:step1)
      expect(context.can_retry_step?(:step1, 3)).to be false
    end

    it "RetryQueuedResult indicates retry was queued" do
      result = RubyReactor::RetryQueuedResult.new(:step1, 2, Time.now + 60)

      expect(result.retry_queued?).to be true
      expect(result.success?).to be false
      expect(result.failure?).to be false
      expect(result.step_name).to eq(:step1)
      expect(result.attempt_number).to eq(2)
    end
  end
end