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
    subject(:reactor) { test_reactor(reactor_class, { id: "test" }) }

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

      it "mocks multiple composed reactors in the same test via block scoping" do
        # rubocop:disable Style/MultilineBlockChain -- this chained block-scoping is the DSL under test
        reactor
          .composed(:child1) do |child|
            child.mock_step(:async_step) { |args, _ctx| RubyReactor::Success("mocked1_#{args[:id]}") }
          end
          .composed(:child2) do |child|
            child.mock_step(:async_step) { |args, _ctx| RubyReactor::Success("mocked2_#{args[:id]}") }
          end
        # rubocop:enable Style/MultilineBlockChain

        expect(reactor).to be_success
        expect(reactor.composed(:child1)).to have_run_step(:async_step).returning("mocked1_child1")
        expect(reactor.composed(:child2)).to have_run_step(:async_step).returning("mocked2_child2")
      end

      it "stays usable directly as a subject after a non-block scoped chain" do
        subject = reactor.composed(:child2).mock_step(:async_step) do |args, _ctx|
          RubyReactor::Success("mocked_#{args[:id]}")
        end

        expect(subject).to be_success
      end

      it "mocks two inner steps of the same composed reactor without leaking scope to the parent" do
        reactor.composed(:child2)
               .mock_step(:async_step) { |args, _ctx| RubyReactor::Success("mocked_#{args[:id]}") }
               .mock_step(:other_step) { |_args, _ctx| RubyReactor::Success("also_mocked") }

        expect(reactor).to be_success
        child2 = reactor.composed(:child2)
        expect(child2).to have_run_step(:async_step).returning("mocked_child2")
        expect(child2).to have_run_step(:other_step).returning("also_mocked")
      end
    end

    context "with run_async(false)" do
      it "forces an async_reactor child's own background steps to run inline too" do
        synced = test_reactor(Support::AsyncReactorRootReactor, { id: "test" }, process_jobs: false)
                 .run_async(false)

        synced.run

        child = synced.async_reactor(:child_job)
        expect(child.reactor_instance.context.status.to_s).to eq("completed")
        expect(child).to have_run_step(:async_step).returning("async_done_test")
      end

      it "forces composed children's own background steps to run inline, not just the top level" do
        # process_jobs: false means nothing drains a background hand-off for
        # us — if run_async(false) didn't cascade into the composed children,
        # this would be left stuck at "running" instead of "completed".
        synced = test_reactor(reactor_class, { id: "test" }, process_jobs: false).run_async(false)

        synced.run

        expect(synced.reactor_instance.context.status.to_s).to eq("completed")
        expect(synced.composed(:child1)).to have_run_step(:async_step).returning("async_done_child1")
        expect(synced.composed(:child2)).to have_run_step(:async_step).returning("async_done_child2")
      end
    end
  end

  describe "map mocking and traversal" do
    # Define a simple map reactor inline for testing
    subject(:reactor) { test_reactor(map_reactor_class, { list: [1, 2, 3] }) }

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

    it "mocks sibling maps via block scoping without leaking scope between them" do
      reactor
        .map(:process_list) { |m| m.mock_step(:transform) { |_args, _ctx| RubyReactor::Success(0) } }
        .map(:label_list) { |m| m.mock_step(:label) { |_args, _ctx| RubyReactor::Success("mocked") } }

      expect(reactor).to be_success
      expect(reactor.map_element(:process_list, index: 0)).to have_run_step(:transform).returning(0)
      expect(reactor.map_element(:label_list, index: 0)).to have_run_step(:label).returning("mocked")
    end

    it "mocks only the targeted element when element_index is given" do
      reactor.map(:process_list).mock_step(:transform, element_index: 1) do |_args, _ctx|
        RubyReactor::Success(999)
      end

      expect(reactor).to be_success

      elements = reactor.map_elements(:process_list)
      expect(elements[0]).to have_run_step(:transform).returning(2) # untouched: 1 * 2
      expect(elements[1]).to have_run_step(:transform).returning(999) # mocked
      expect(elements[2]).to have_run_step(:transform).returning(6) # untouched: 3 * 2
    end
  end

  describe "fan-out maps" do
    subject(:reactor) { test_reactor(Support::FanOutMapMockTestReactor, { list: [1, 2, 3] }) }

    it "mocks an inner step of every element, not just of an inline map" do
      # A fan-out element job carries only the mapped reactor's NAME: if the
      # mocked subclass has no resolvable identity of its own, the worker
      # resolves back to the original class and the mock never runs.
      reactor.map(:process_list).mock_step(:transform, element_index: 1) do |_args, _ctx|
        RubyReactor::Success(999)
      end

      expect(reactor).to be_success

      elements = reactor.map_elements(:process_list)
      expect(elements.size).to eq(3)
      expect(elements[0]).to have_run_step(:transform).returning(2)
      expect(elements[1]).to have_run_step(:transform).returning(999)
      expect(elements[2]).to have_run_step(:transform).returning(6)
    end

    it "runs the whole map in-process under run_async(false)" do
      # Nothing drains element jobs here, so a still-fanned-out map would leave
      # the reactor parked at "running" instead of completing.
      synced = test_reactor(Support::FanOutMapMockTestReactor, { list: [1, 2, 3] }, process_jobs: false)
               .run_async(false)

      synced.run

      expect(synced.reactor_instance.context.status.to_s).to eq("completed")
      expect(synced.result.value).to eq([{ transform: 2 }, { transform: 4 }, { transform: 6 }])
    end
  end
end
