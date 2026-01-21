# frozen_string_literal: true

require "spec_helper"
require "support/map_mock_test_reactor"
require "support/nested_inline_reactors"

RSpec.describe "Nested Reactor Helpers" do
  include RubyReactor::RSpec::Helpers

  # Using existing reactors defined in spec/support/nested_inline_reactors.rb
  # Support::NestedInlineRootReactor (has :child_process)
  # Support::MultipleComposeRootReactor (has :child1, :child2)

  describe "fluent mocking" do
    subject(:reactor) { test_reactor(reactor_class, inputs: { id: "test" }) }

    let(:reactor_class) { Support::MultipleComposeRootReactor }

    context "with composed steps" do
      it "mocks inner step of a composed reactor" do
        reactor.composed(:child2).mock_step(:async_step) do |args, _ctx|
          RubyReactor::Success("mocked_#{args[:id]}")
        end

        expect(reactor).to be_success

        # Verify the mock behavior
        child2_subject = reactor.composed(:child2)
        expect(child2_subject).to have_run_step(:async_step).returning("mocked_child2")
      end

      it "can traverse composed steps" do
        expect(reactor).to be_success
        child1 = reactor.composed(:child1)
        expect(child1).to be_success
        expect(child1).to have_run_step(:async_step).returning("async_done_child1")
      end
    end
  end

  describe "map mocking and traversal" do
    # Define a simple map reactor inline for testing
    subject(:reactor) { test_reactor(map_reactor_class, inputs: { list: [1, 2, 3] }) }

    let(:map_reactor_class) { Support::MapMockTestReactor }

    it "mocks inner step of a map reactor" do
      reactor.map(:process_list).mock_step(:transform) do |args, ctx, original|
        if args[:value] == 2
          RubyReactor::Success(999) # Mock specific value
        else
          original.call(args, ctx)
        end
      end

      expect(reactor).to be_success

      # Verify via traversal
      elements = reactor.map_elements(:process_list)
      expect(elements.size).to eq(3)

      expect(elements[0]).to have_run_step(:transform).returning(2) # 1 * 2
      expect(elements[1]).to have_run_step(:transform).returning(999) # Mocked
      expect(elements[2]).to have_run_step(:transform).returning(6) # 3 * 2
    end

    it "traverses individual elements" do
      expect(reactor).to be_success

      element = reactor.map_element(:process_list, index: 1)
      expect(element).to have_run_step(:transform).returning(4)
    end
  end
end
