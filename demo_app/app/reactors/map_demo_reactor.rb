class MapDemoReactor < RubyReactor::Reactor
  input :inline_list
  input :async_list
  input :batch_list
  input :ar_query
  input :fail_at_reactor, optional: true
  input :fail_at_step, optional: true

  # 1. Simple Inline Map (Synchronous)
  map :inline_map do
    source input(:inline_list)
    argument :number, element(:inline_map)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    
    step :double do
      argument :number, input(:number)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args| 
        puts "[EXECUTION] RUN inline_map.double - number: #{args[:number]}"
        if args[:fail_at_reactor]&.to_sym == :inline_map && args[:fail_at_step]&.to_sym == :double
          Failure("Simulated failure at inline_map.double")
        else
          Success(args[:number] * 2) 
        end
      end
      undo do |result, args|
        puts "[COMPENSATION] UNDO inline_map.double - number: #{args[:number]}, result: #{result}"
      end
    end

    step :increment do
      argument :number, result(:double)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        puts "[EXECUTION] RUN inline_map.increment - number: #{args[:number]}"
        if args[:fail_at_reactor]&.to_sym == :inline_map && args[:fail_at_step]&.to_sym == :increment
          Failure("Simulated failure at inline_map.increment")
        else
          Success(args[:number] + 1)
        end
      end
      undo do |result, args|
        puts "[COMPENSATION] UNDO inline_map.increment - number: #{args[:number]}, result: #{result}"
      end
    end

    returns :increment
  end

  # 2. Simple Async Map
  map :async_map do
    source input(:async_list)
    argument :number, element(:async_map)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    async true

    step :square do
      argument :number, input(:number)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        puts "[EXECUTION] RUN async_map.square - number: #{args[:number]}"
        if args[:fail_at_reactor]&.to_sym == :async_map && args[:fail_at_step]&.to_sym == :square
          Failure("Simulated failure at async_map.square")
        else
          Success(args[:number] ** 2)
        end
      end
      undo do |result, args|
        puts "[COMPENSATION] UNDO async_map.square - number: #{args[:number]}, result: #{result}"
      end
    end

    step :to_string do
      argument :value, result(:square)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        puts "[EXECUTION] RUN async_map.to_string - value: #{args[:value]}"
        if args[:fail_at_reactor]&.to_sym == :async_map && args[:fail_at_step]&.to_sym == :to_string
          Failure("Simulated failure at async_map.to_string")
        else
          Success("Result: #{args[:value]}")
        end
      end
      undo do |result, args|
        puts "[COMPENSATION] UNDO async_map.to_string - value: #{args[:value]}, result: #{result}"
      end
    end

    returns :to_string
  end

  # 3. Batch Size with Big List
  map :batch_map do
    source input(:batch_list)
    argument :number, element(:batch_map)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    
    # Process in batches of 10 workers
    async true, batch_size: 10

    step :heavy_math do
      argument :number, input(:number)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        puts "[EXECUTION] RUN batch_map.heavy_math - number: #{args[:number]}"
        if args[:fail_at_reactor]&.to_sym == :batch_map && args[:fail_at_step]&.to_sym == :heavy_math
          Failure("Simulated failure at batch_map.heavy_math")
        else
          Success(Math.sqrt(args[:number]))
        end
      end
      undo do |result, args|
        puts "[COMPENSATION] UNDO batch_map.heavy_math - number: #{args[:number]}, result: #{result}"
      end
    end

    step :format_math do
      argument :value, result(:heavy_math)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        puts "[EXECUTION] RUN batch_map.format_math - value: #{args[:value]}"
        if args[:fail_at_reactor]&.to_sym == :batch_map && args[:fail_at_step]&.to_sym == :format_math
          Failure("Simulated failure at batch_map.format_math")
        else
          Success(format("%.2f", args[:value]))
        end
      end
      undo do |result, args|
        puts "[COMPENSATION] UNDO batch_map.format_math - value: #{args[:value]}, result: #{result}"
      end
    end

    returns :format_math
  end

  # 4. Batch Size with ActiveRecord Query
  map :ar_batch_map do
    # Pass an ActiveRecord::Relation or Enumerator
    source input(:ar_query)
    argument :product, element(:ar_batch_map)
    argument :fail_at_reactor, input(:fail_at_reactor)
    argument :fail_at_step, input(:fail_at_step)
    
    async true, batch_size: 2

    step :restock do
      argument :product, input(:product)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        # In async, args[:product] might be serialized.
        product = args[:product] 
        puts "[EXECUTION] RUN ar_batch_map.restock - product: #{product.id}"
        if args[:fail_at_reactor]&.to_sym == :ar_batch_map && args[:fail_at_step]&.to_sym == :restock
          Failure("Simulated failure at ar_batch_map.restock")
        else
          Success("Checked stock for #{product.name}")
        end
      end
      undo do |result, args|
        puts "[COMPENSATION] UNDO ar_batch_map.restock - product: #{args[:product].id}, result: #{result}"
      end
    end

    step :tag_product do
      argument :product, input(:product)
      argument :restock_status, result(:restock)
      argument :fail_at_reactor, input(:fail_at_reactor)
      argument :fail_at_step, input(:fail_at_step)
      run do |args|
        puts "[EXECUTION] RUN ar_batch_map.tag_product - product: #{args[:product].id}"
        if args[:fail_at_reactor]&.to_sym == :ar_batch_map && args[:fail_at_step]&.to_sym == :tag_product
          Failure("Simulated failure at ar_batch_map.tag_product")
        else
          Success("Tagged #{args[:product].name} with status: #{args[:restock_status]}")
        end
      end
      undo do |result, args|
        puts "[COMPENSATION] UNDO ar_batch_map.tag_product - product: #{args[:product].id}, result: #{result}"
      end
    end

    returns :tag_product
  end
end
