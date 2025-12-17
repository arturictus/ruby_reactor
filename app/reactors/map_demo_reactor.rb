class MapDemoReactor < RubyReactor::Reactor
  input :inline_list
  input :async_list
  input :batch_list
  input :ar_query

  # 1. Simple Inline Map (Synchronous)
  map :inline_map do
    source input(:inline_list)
    argument :number, element(:inline_map)
    
    step :double do
      argument :number, input(:number)
      run do |args| 
        Success(args[:number] * 2) 
      end
    end
    returns :double
  end

  # 2. Simple Async Map
  map :async_map do
    source input(:async_list)
    argument :number, element(:async_map)
    async true

    step :square do
      argument :number, input(:number)
      run do |args|
        # Simulate work
        Success(args[:number] ** 2)
      end
    end
    returns :square
  end

  # 3. Batch Size with Big List
  map :batch_map do
    source input(:batch_list)
    argument :number, element(:batch_map)
    
    # Process in batches of 10 workers
    async true, batch_size: 10

    step :heavy_math do
      argument :number, input(:number)
      run do |args|
        Success(Math.sqrt(args[:number]))
      end
    end
    returns :heavy_math
  end

  # 4. Batch Size with ActiveRecord Query
  map :ar_batch_map do
    # Pass an ActiveRecord::Relation or Enumerator
    source input(:ar_query)
    argument :product, element(:ar_batch_map)
    
    async true, batch_size: 2

    step :restock do
      argument :product, input(:product)
      run do |args|
        # In async, args[:product] might be serialized.
        product = args[:product] 
        Success("Checked stock for #{product.name}")
      end
    end
    returns :restock
  end
end
