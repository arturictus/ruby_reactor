namespace :demo do
  desc "flush redis"
  
  task flush_redis: :environment do
    puts "Fushing redis at #{RubyReactor.configuration.storage.redis_url}"
    Redis.new(url: RubyReactor.configuration.storage.redis_url).flushdb
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
end
