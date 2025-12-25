# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Resume Metadata Regression" do
  let(:reactor_class) do
    klass = Class.new(RubyReactor::Reactor) do
      input :data

      step :failing_step do
        run do |_args, _context|
          raise "Something went wrong"
        end
      end
    end
    stub_const("FailingTestReactor", klass)
    klass
  end

  it "preserves step_name in failure_reason when failing during resume_execution" do
    # 1. Create a context that is about to run the failing step
    context = RubyReactor::Context.new({ data: "test" }, reactor_class)
    context.current_step = :failing_step
    context.inline_async_execution = true # Simulate worker context

    # 2. Initialize executor with this context
    executor = RubyReactor::Executor.new(reactor_class, {}, context)

    # 3. Resume execution - this will trigger the failing_step
    # which will raise a StandardError, caught by StepExecutor,
    # then raised as StepFailureError by ResultHandler,
    # then caught by Executor#resume_execution,
    # and finally handled by Executor#handle_resume_error.
    result = executor.resume_execution

    expect(result).to be_a(RubyReactor::Failure)
    expect(result.step_name).to eq(:failing_step)

    # Verify the context's failure_reason which is stored in Redis
    expect(context.failure_reason).not_to be_nil
    expect(context.failure_reason[:step_name]).to eq(:failing_step)
    expect(context.failure_reason[:message]).to match(/Something went wrong/)
  end
end
