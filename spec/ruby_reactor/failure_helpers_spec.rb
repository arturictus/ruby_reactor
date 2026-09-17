# frozen_string_literal: true

require "spec_helper"

# A Failure means the same thing wherever an author builds one, so every
# helper takes exactly the arguments RubyReactor.Failure takes.
RSpec.describe "Failure helpers" do
  {
    "a class step" => -> { Class.new(RubyReactor::Step).new({}, nil) },
    "an inline block (DSL)" => -> { Object.new.extend(RubyReactor::Dsl::TemplateHelpers) }
  }.each do |where, receiver|
    it "#{where}'s Failure accepts the same arguments as RubyReactor.Failure" do
      failure = receiver.call.Failure("declined", retryable: false, step_name: :charge)

      expect(failure).to have_attributes(
        class: RubyReactor::Failure, error: "declined", retryable?: false, step_name: :charge
      )
    end
  end
end
