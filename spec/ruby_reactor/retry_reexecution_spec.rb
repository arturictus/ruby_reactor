# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Retry Re-execution Regression" do
  class RegressionReactor < RubyReactor::Reactor
    step :step1 do
      run do |_args, _context|
        $step_counts[:step1] += 1
        RubyReactor.Success("step1_done")
      end
    end

    step :step2 do
      async true
      run do |_args, _context|
        $step_counts[:step2] += 1
        RubyReactor.Success("step2_done")
      end
    end

    step :step3 do
      retries max_attempts: 3, backoff: :fixed, base_delay: 0.01
      run do |_args, _context|
        $step_counts[:step3] += 1
        if $step_counts[:step3] < 3
          RubyReactor.Failure("retry_me")
        else
          RubyReactor.Success("step3_done")
        end
      end
    end
  end

  before do
    $step_counts = Hash.new(0)
  end

  it "does not re-execute completed steps during retries" do
    RegressionReactor.call({})

    expect($step_counts[:step1]).to eq(1)
    expect($step_counts[:step2]).to eq(1)
    expect($step_counts[:step3]).to eq(3) # Initial + 2 retries
  end
end
