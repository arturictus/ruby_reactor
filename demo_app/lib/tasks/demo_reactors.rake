namespace :demo do
  desc "flush redis"
  
  task flush_redis: :environment do
    puts "Fushing redis at #{RubyReactor.configuration.storage.redis_url}"
    Redis.new(url: RubyReactor.configuration.storage.redis_url).flushdb
    Product.delete_all
    puts "✅ SUCCESS"
  end

  desc "Run PaymentWorkflow with all failure scenarios"
  task payment_workflow: [:environment, :flush_redis] do
    fail_at_scenarios = [nil, :get_order, :authorize_payment, :capture_payment, :fulfill_order]

    fail_at_scenarios.each do |fail_at|
      puts "\n--- Running PaymentWorkflow with fail_at: #{fail_at.inspect} ---"
      order_id = "order_#{SecureRandom.hex(4)}"

      result = PaymentWorkflow.call(order_id: order_id, fail_at: fail_at)

      if result.is_a?(RubyReactor::AsyncResult)
        puts "⏳ ASYNC: Workflow started asynchronously."
        puts "   Execution ID: #{result.execution_id}"
      elsif result.success?
        puts "✅ SUCCESS: Workflow completed successfully."
        puts "   Result: #{result.value.inspect}"
      else
        puts "❌ FAILED: Workflow failed as expected."
        puts "   Error: #{result.message}"
      end
    end
  end
  desc "Run OrderProcessingReactor with all failure scenarios"
  task order_processing: [:environment, :flush_redis] do
    fail_at_scenarios = [nil, :validate_order, :check_inventory, :reserve_inventory, :process_payment]

    fail_at_scenarios.each do |fail_at|
      puts "\n--- Running OrderProcessingReactor with fail_at: #{fail_at.inspect} ---"
      order_id = "order_#{SecureRandom.hex(4)}"

      result = OrderProcessingReactor.call(
        order_id: order_id,
        fail_at: fail_at,
        product_id: "prod_1",
        quantity: 1,
        amount: 100
      )

      if result.is_a?(RubyReactor::AsyncResult)
        puts "⏳ ASYNC: Workflow started asynchronously."
        puts "   Execution ID: #{result.execution_id}"
      elsif result.success?
        puts "✅ SUCCESS: Workflow completed successfully."
        puts "   Result: #{result.value.inspect}"
      else
        puts "❌ FAILED: Workflow failed as expected."
        puts "   Error: #{result.message}"
      end
    end
  end

  desc "Run ParentReactor"
  task parent_reactor: [:environment, :flush_redis] do
    ParentReactor.run(a: 1, b: 2)

    ParentReactor.run(a: 1, b: "a")

    def run_reactor(a, b, fail_at_reactor = nil, fail_at_step = nil)
      puts "\n>>> Running ParentReactor(a: #{a}, b: #{b}, fail_at_reactor: #{fail_at_reactor.inspect}, fail_at_step: #{fail_at_step.inspect})"
      result = ParentReactor.run(
        a: a, 
        b: b, 
        fail_at_reactor: fail_at_reactor, 
        fail_at_step: fail_at_step
      )
      
      if result.success?
        puts "SUCCESS: #{result.value}"
      else
        # In case error method is not available, we use inspect or access internal error if possible
        err_msg = result.respond_to?(:error) ? result.error : result.inspect
        puts "FAILURE: #{err_msg}"
      end
    end

    # 1. Success case
    run_reactor(10, 5)

    # 2. Failure in child_reactor.add
    run_reactor(10, 5, :child_reactor, :add)

    # 3. Failure in child_reactor.wait_for
    run_reactor(10, 5, :child_reactor, :wait_for)

    # 4. Failure in math_operation.multiply
    run_reactor(10, 5, :math_operation, :multiply)

    # 5. Failure in math_operation.do_something
    run_reactor(10, 5, :math_operation, :do_something)

    # 6. Failure in parent_reactor.format_result
    run_reactor(10, 5, :parent_reactor, :format_result)
    puts "✅ SUCCESS"
  end

  desc "Map reactor"
  task map: [:environment, :flush_redis] do

   

    def run_map_reactor(params)
      puts "\n>>> Running MapDemoReactor(#{params.inspect})"
      result = MapDemoReactor.call(params)

      if result.is_a?(RubyReactor::AsyncResult)
        puts "⏳ ASYNC: Map started asynchronously."
        puts "   Execution ID: #{result.execution_id}"
        puts "   Dashboard: http://localhost:3000/ruby_reactor/#{result.execution_id}"
      elsif result.success?
        puts "SUCCESS: #{result.value.inspect}"
      else
        err_msg = result.respond_to?(:error) ? result.error : result.inspect
        puts "FAILURE: #{err_msg}"
      end
    end

    inline_list = [1, 2, 3]
    async_list = [4, 5, 6]
    batch_list = (1..20).to_a
    # Ensure some products exist for AR map
    Product.find_or_create_by!(name: "Product A")
    Product.find_or_create_by!(name: "Product B")
    ar_query = Product.all.to_a

    common_params = {
      inline_list: inline_list,
      async_list: async_list,
      batch_list: batch_list,
      ar_query: ar_query
    }

    # 1. Success case
    run_map_reactor(common_params)

    # 2. Failure in inline_map.double
    run_map_reactor(common_params.merge(fail_at_reactor: :inline_map, fail_at_step: :double))

    # 3. Failure in async_map.square
    run_map_reactor(common_params.merge(fail_at_reactor: :async_map, fail_at_step: :square))

    # 4. Failure in batch_map.heavy_math
    run_map_reactor(common_params.merge(fail_at_reactor: :batch_map, fail_at_step: :heavy_math))

    # 5. Failure in ar_batch_map.restock
    run_map_reactor(common_params.merge(fail_at_reactor: :ar_batch_map, fail_at_step: :restock))

    # 6. Failure in inline_map.increment
    run_map_reactor(common_params.merge(fail_at_reactor: :inline_map, fail_at_step: :increment))

    # 7. Failure in async_map.to_string
    run_map_reactor(common_params.merge(fail_at_reactor: :async_map, fail_at_step: :to_string))

    # 8. Failure in batch_map.format_math
    run_map_reactor(common_params.merge(fail_at_reactor: :batch_map, fail_at_step: :format_math))

    # 9. Failure in ar_batch_map.tag_product
    run_map_reactor(common_params.merge(fail_at_reactor: :ar_batch_map, fail_at_step: :tag_product))

    puts "✅ MAP VERIFICATION COMPLETE"
  end

  desc "Interrupt reactors"
  task interrupt: [:environment, :flush_redis] do
    def run_interrupt_reactor(name, reactor_class, params)
      puts "\n>>> Running #{name} (#{params.inspect})"
      result = reactor_class.call(params)

      if result.is_a?(RubyReactor::AsyncResult)
        puts "⏳ ASYNC: Workflow started/paused asynchronously."
        puts "   Execution ID: #{result.execution_id}"
      elsif result.success?
        puts "✅ SUCCESS: Workflow completed successfully."
        puts "   Result: #{result.value.inspect}"
      else
        puts "❌ FAILED: Workflow failed as expected."
        err_msg = result.respond_to?(:error) ? result.error : result.inspect
        puts "   Error: #{err_msg}"
      end
    end

    # FormInterruptReactor Scenarios
    puts "\n=== FormInterruptReactor Scenarios ==="
    
    # 1. Success (pauses at interrupt)
    run_interrupt_reactor("FormInterruptReactor [Success]", FormInterruptReactor, { user_name: "Alice" })

    # # 2. Fail at async_step_before
    run_interrupt_reactor("FormInterruptReactor [Fail: async_step_before]", FormInterruptReactor, { user_name: "Alice", fail_at: :async_step_before })

    # # 3. Fail at prepare_application
    run_interrupt_reactor("FormInterruptReactor [Fail: prepare_application]", FormInterruptReactor, { user_name: "Alice", fail_at: :prepare_application })

    # # 4. Fail at finalize_application (will pause first)
    run_interrupt_reactor("FormInterruptReactor [Fail: finalize_application]", FormInterruptReactor, { user_name: "Alice", fail_at: :finalize_application })

    # # 5. Fail at async_step_after (will pause first)
    run_interrupt_reactor("FormInterruptReactor [Fail: async_step_after]", FormInterruptReactor, { user_name: "Alice", fail_at: :async_step_after })

    # # 6. Validation Error
    run_interrupt_reactor("FormInterruptReactor [Validation Error]", FormInterruptReactor, {})


    # WebhookInterruptReactor Scenarios
    puts "\n=== WebhookInterruptReactor Scenarios ==="

    # # 1. Success (pauses at interrupt)
    run_interrupt_reactor("WebhookInterruptReactor [Success]", WebhookInterruptReactor, { provider_id: "stripe" })

    # # 2. Fail at async_step_before
    run_interrupt_reactor("WebhookInterruptReactor [Fail: async_step_before]", WebhookInterruptReactor, { provider_id: "stripe", fail_at: :async_step_before })

    # # 3. Fail at initiate_request
    run_interrupt_reactor("WebhookInterruptReactor [Fail: initiate_request]", WebhookInterruptReactor, { provider_id: "stripe", fail_at: :initiate_request })

    # # 4. Fail at process_response (will pause first)
    run_interrupt_reactor("WebhookInterruptReactor [Fail: process_response]", WebhookInterruptReactor, { provider_id: "stripe", fail_at: :process_response })

    # # 5. Fail at async_step_after (will pause first)
    run_interrupt_reactor("WebhookInterruptReactor [Fail: async_step_after]", WebhookInterruptReactor, { provider_id: "stripe", fail_at: :async_step_after })

    # # 6. Validation Error
    run_interrupt_reactor("WebhookInterruptReactor [Validation Error]", WebhookInterruptReactor, {})

    puts "\n✅ INTERRUPT DEMO COMPLETE"
  end
 
  desc "All demo reactors"
  task all: [:environment, :flush_redis, :payment_workflow, :order_processing, :parent_reactor, :map, :interrupt, :etl, :ar, :coordination] do
    puts "excuting all reactors"
  end

  desc "User ETL reactor"
  task etl: [:environment, :flush_redis] do
    def run_etl_scenario(name, data)
      puts "\n=== Running Scenario: #{name} ==="
      puts "Starting ETL process with #{data.length} records..."
      
      result = UserEtlReactor.call(
        source_file: "users_export_2024.csv",
        csv_data: data,
        output_destinations: [:database, :search_index]
      )

      if result.is_a?(RubyReactor::AsyncResult)
        puts "⏳ ASYNC: ETL started successfully."
        puts "   Execution ID: #{result.execution_id}"
        puts "   Dashboard: http://localhost:3000/ruby_reactor/#{result.execution_id}"
      elsif result.success?
        puts "✅ SUCCESS: ETL completed synchronously."
        puts "   Result: #{result.value.inspect}"
      else
        puts "❌ FAILED: ETL failed."
        err_msg = result.respond_to?(:error) ? result.error : result.inspect
        puts "   Error: #{err_msg}"
      end
    end

    # Scenario 1: Clean Data (Success)
    clean_data = [
      { "id" => "1", "name" => "Alice Smith", "email" => "verified@example.com", "phone" => "555-0101", "age" => "30" },
      { "id" => "2", "name" => "Bob Jones", "email" => "unverified@example.com", "phone" => "555-0102", "age" => "25" }
    ]
    run_etl_scenario("Clean Data", clean_data)

    # Scenario 2: Data needing cleaning (Success)
    # Phone numbers will be normalized, emails downcased
    dirty_data = [
      { "id" => "3", "name" => "  Charlie  ", "email" => "  Verified@Example.com ", "phone" => "(555) 010-3", "age" => "40" },
      { "id" => "4", "name" => "Dave", "email" => "unverified@example.com", "phone" => "555.0104", "age" => "35" }
    ]
    run_etl_scenario("Data Cleaning", dirty_data)

    # Scenario 3: Invalid Data (Failure)
    invalid_data = [
      { "id" => "5", "name" => "Eve", "email" => "verified@example.com", "phone" => "555-0105", "age" => "28" },
      { "id" => "6", "name" => "F", "email" => "invalid_email", "phone" => "123", "age" => "150" } # Invalid
    ]
    run_etl_scenario("Invalid Data", invalid_data)
  end

  desc "Active Record reactor"
  task ar: [:environment, :flush_redis] do
    (100..300).each do |n|
      Product.find_or_create_by(name: "Product #{n}", stock: n >= 150 ? 1 : 0)
    end

    ArMapReactor.run(filter: {stock: 1})
    ArMapReactorNotFail.run(filter: {stock: 1})
  end

  desc "Run coordination demo reactors (locks, semaphores, rate limits, periods)"
  task coordination: [:environment, :flush_redis] do
    def run_coordination_reactor(name, reactor_class, params)
      puts "\n>>> Running #{name}: #{reactor_class.name}(#{params.inspect})"
      result = reactor_class.call(params)

      if result.is_a?(RubyReactor::AsyncResult)
        puts "⏳ ASYNC: Reactor started asynchronously."
        puts "   Execution ID: #{result.execution_id}"
        puts "   Dashboard: http://localhost:3000/ruby_reactor/#{result.execution_id}"
      elsif result.respond_to?(:skipped?) && result.skipped?
        puts "⏭️  SKIPPED: #{result.reason.inspect}"
        puts "   Execution ID: #{result.execution_id}" if result.respond_to?(:execution_id)
        puts "   Dashboard: http://localhost:3000/ruby_reactor/#{result.execution_id}" if result.respond_to?(:execution_id)
      elsif result.success?
        puts "✅ SUCCESS: #{result.value.inspect}"
        if result.respond_to?(:execution_id) && result.execution_id
          puts "   Execution ID: #{result.execution_id}"
          puts "   Dashboard: http://localhost:3000/ruby_reactor/#{result.execution_id}"
        end
      else
        err_msg = result.respond_to?(:error) ? result.error : result.inspect
        puts "❌ FAILURE: #{err_msg}"
      end
    end

    puts "\n=== LockDemoReactor ==="
    puts "Sync prefix (prepare + verify) runs inline; process_refund hands off to Sidekiq."
    puts "Requires Sidekiq. Open dashboard URLs while the worker holds the lock during process_refund."

    run_coordination_reactor(
      "Refund in progress (sync prefix, worker holds lock during process_refund)",
      LockDemoReactor,
      { order_id: "demo_order_1", hold_seconds: 10 }
    )

    run_coordination_reactor(
      "Concurrent refund on same order (worker snoozes on lock contention)",
      LockDemoReactor,
      { order_id: "demo_order_1", hold_seconds: 10 }
    )

    puts "\n=== SemaphoreDemoReactor ==="
    puts "Full-async pipeline (validate → charge → record). Launch three jobs to saturate the pool (limit: 2)."

    run_coordination_reactor(
      "Gateway call 1",
      SemaphoreDemoReactor,
      { request_id: "req_a", hold_seconds: 10 }
    )

    run_coordination_reactor(
      "Gateway call 2",
      SemaphoreDemoReactor,
      { request_id: "req_b", hold_seconds: 10 }
    )

    run_coordination_reactor(
      "Gateway call 3 (over capacity, async snooze)",
      SemaphoreDemoReactor,
      { request_id: "req_c", hold_seconds: 10 }
    )

    puts "\n=== RateLimitDemoReactor ==="

    run_coordination_reactor(
      "Burst of 4 calls (3 allowed, 4th exceeds per-second limit)",
      RateLimitBurstDemoReactor,
      { account_id: "demo_account" }
    )

    puts "\n=== PeriodDemoReactor ==="

    run_coordination_reactor(
      "First run marks the daily bucket",
      PeriodDemoReactor,
      { org_id: "demo_org" }
    )

    run_coordination_reactor(
      "Second run skipped (period dedup)",
      PeriodDemoReactor,
      { org_id: "demo_org" }
    )

    puts "\n✅ COORDINATION DEMO COMPLETE"
  end
end
