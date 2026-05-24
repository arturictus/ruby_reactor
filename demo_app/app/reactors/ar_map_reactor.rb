class ArMapReactor < RubyReactor::Reactor
  input :filter do
    required(:filter).filled(:hash)
  end

  map :prepare_products do
    argument :filter, input(:filter)
    source do |args|
      stock = args[:filter][:stock] || args[:filter]["stock"]
      puts "Stock Argument #{stock}"
      q = Product.where("stock >= ?", stock) 
      puts q.class
      q
    end
    argument :product, element(:prepare_products)
    async true, batch_size: 2
    
    step :get_product do
      run do |args|
        puts "Fetching product id: #{args[:product].id}"
        Success(args[:product])
      end
    end

    step :check_product do
      argument :product, result(:get_product)
      run do |args|
        raise "NO Stock" if args[:product].stock < 1
        Success("Correct")
      end
    end

    step :update_product do
      argument :product, result(:get_product)
      wait_for :check_product

      run do |args|
        p = args[:product]
        Product.increment_counter(:stock, p.id)
        puts p.class
        Success(p)
      end
    end

    step :randomly_fail do
      wait_for :update_product
      run do
        raise "Random error triggered!" if rand > 0.5
        Success("Survived")
      end
    end

    returns :update_product
  end

  step :show_results do
    argument :products, result(:prepare_products)
    run do |args|
      col = args[:products]
      puts "Result of map class is: #{col.class}"
      col.successes.each do |e|
        puts "id: #{e.id}, stock: #{e.stock}"
      end
      puts "Errors count: #{col.failures.count}"
      Success()
    end
  end
end