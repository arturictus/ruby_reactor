# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Dependency Inference" do
  class DependencyInferenceReactor < RubyReactor::Reactor
    input :user_id

    step :step_a do
      run { Success("A") }
    end

    step :step_b do
      argument :input_a, result(:step_a)
      run { Success("B") }
    end

    step :step_c do
      argument :input_b, result(:step_b)
      run { Success("C") }
    end
  end

  it "does not pollute StepConfig with inferred dependencies" do
    steps = DependencyInferenceReactor.steps

    expect(steps[:step_a].dependencies).to be_empty
    expect(steps[:step_b].dependencies).to be_empty # Inferred, not explicit
    expect(steps[:step_c].dependencies).to be_empty # Inferred, not explicit
  end

  it "builds dependency graph correctly with inferred dependencies" do
    graph = RubyReactor::DependencyGraph.new
    DependencyInferenceReactor.steps.each_value { |step| graph.add_step(step) }

    # Verify the exposed dependencies accessor
    deps = graph.dependencies

    expect(deps[:step_a]).to be_empty
    expect(deps[:step_b]).to contain_exactly(:step_a)
    expect(deps[:step_c]).to contain_exactly(:step_b)
  end
end
