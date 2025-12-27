# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Map Inline Execution" do
  let(:double_reactor_class) do
    Class.new(RubyReactor::Reactor) do
      input :number

      step :double do
        argument :number, input(:number)
        run { |args, _| RubyReactor::Success(args[:number] * 2) }
      end

      returns :double
    end
  end

  let(:map_root_reactor_class) do
    double_class = double_reactor_class
    Class.new(RubyReactor::Reactor) do
      input :numbers

      map :doubled_numbers, double_class do
        source input(:numbers)
        argument :number, element(:doubled_numbers)
      end
    end
  end

  let(:inline_map_reactor_class) do
    Class.new(RubyReactor::Reactor) do
      input :numbers

      map :doubled_numbers do
        source input(:numbers)

        argument :number, element(:doubled_numbers)

        step :double do
          argument :val, input(:number)
          run { |args, _| RubyReactor::Success(args[:val] * 2) }
        end

        returns :double
      end
    end
  end

  let(:collect_map_reactor_class) do
    Class.new(RubyReactor::Reactor) do
      input :numbers

      map :sum_doubles do
        source input(:numbers)

        argument :number, element(:sum_doubles)

        step :double do
          argument :val, input(:number)
          run { |args, _| RubyReactor::Success(args[:val] * 2) }
        end

        returns :double

        # rubocop:disable Style/SymbolProc
        collect do |results|
          # rubocop:enable Style/SymbolProc
          results.sum
        end
      end
    end
  end

  it "executes map with class-based reactor" do
    result = map_root_reactor_class.run(numbers: [1, 2, 3])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:doubled_numbers]).to eq([2, 4, 6])
  end

  it "executes map with inline reactor definition" do
    result = inline_map_reactor_class.run(numbers: [1, 2, 3])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:doubled_numbers]).to eq([2, 4, 6])
  end

  it "executes map with collect transformation" do
    result = collect_map_reactor_class.run(numbers: [1, 2, 3])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:sum_doubles]).to eq(12) # (2+4+6)
  end

  it "handles empty source" do
    result = map_root_reactor_class.run(numbers: [])

    expect(result).to be_a(RubyReactor::Success)
    expect(result.value[:doubled_numbers]).to eq([])
  end

  context "when source comes from a previous step" do
    let(:map_from_step_result_reactor) do
      Class.new(RubyReactor::Reactor) do
        step :generate_numbers do
          run { |_, _| RubyReactor::Success([10, 20, 30]) }
        end

        map :doubled_numbers do
          source result(:generate_numbers)

          argument :number, element(:doubled_numbers)

          step :double do
            argument :val, input(:number)
            run { |args, _| RubyReactor::Success(args[:val] * 2) }
          end

          returns :double
        end
      end
    end

    it "executes map with source from previous step" do
      result = map_from_step_result_reactor.run

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:doubled_numbers]).to eq([20, 40, 60])
    end
  end

  context "with different step interactions" do
    let(:map_from_step_result_reactor) do
      Class.new(RubyReactor::Reactor) do
        input :ids
        input :multiplier

        step :generate_numbers do
          argument :ids, input(:ids)
          argument :multiplier, input(:multiplier)
          run { |args, _| RubyReactor::Success(args[:ids].map { |id| id * args[:multiplier] }) }
        end

        map :doubled_numbers do
          source result(:generate_numbers)
          argument :multiplier, input(:multiplier)

          argument :number, element(:doubled_numbers)

          step :double do
            argument :val, input(:number)
            argument :multiplier, input(:multiplier)
            run { |args, _| RubyReactor::Success(args[:val] * args[:multiplier]) }
          end

          returns :double
        end

        step :sum_doubles do
          argument :doubled_numbers, result(:doubled_numbers)
          run { |args, _| RubyReactor::Success(args[:doubled_numbers].sum) }
        end

        step :filter_evens do
          argument :doubled_numbers, result(:doubled_numbers)
          run { |args, _| RubyReactor::Success(args[:doubled_numbers].select(&:even?)) }
        end
      end
    end

    it "executes map with source from previous step" do
      result = map_from_step_result_reactor.run(ids: [1, 2, 3], multiplier: 3)

      expect(result).to be_a(RubyReactor::Success)
      expect(result.value[:doubled_numbers]).to eq([9, 18, 27])
      expect(result.value[:sum_doubles]).to eq(54)
      expect(result.value[:filter_evens]).to eq([18])
    end
  end

  context "composed contexts" do
    it "stores child context references in composed_contexts for map step" do
      # Let's use Executor directly for testing to inspect context
      context = RubyReactor::Context.new({ numbers: [1, 2] }, inline_map_reactor_class)
      executor = RubyReactor::Executor.new(inline_map_reactor_class, {}, context)
      executor.execute

      expect(context.composed_contexts).to have_key(:doubled_numbers)
      composed_data = context.composed_contexts[:doubled_numbers]
      expect(composed_data[:type]).to eq(:map_ref)
      expect(composed_data[:map_id]).to eq("#{context.context_id}:doubled_numbers")

      # Verify that the child context IDs are in Redis (via our storage adapter)
      storage = RubyReactor.configuration.storage_adapter
      context_ids = storage.retrieve_map_element_context_ids(composed_data[:map_id], context.reactor_class.name)
      expect(context_ids.length).to eq(2)

      # Verify at least one child context exists and has results
      child_data = storage.find_context_by_id(context_ids.last)
      expect(child_data["intermediate_results"]).to have_key("double")
    end
  end
end
