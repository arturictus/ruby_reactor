# bin/demo_scenarios.rb

Redis.new(url: RubyReactor.configuration.storage.redis_url).flushdb

puts "=== 1. Running EtlReactor (ActiveRecord Integration) ==="
begin
  result = EtlReactor.run
  puts "Result: #{result.success? ? 'Success' : 'Failure'}"
  puts "Value: #{result.value}"
  puts "Pending Orders: #{Order.where(status: 'pending').count}"
  puts "Processed Orders: #{Order.where(status: 'processed').count}"
rescue => e
  puts "Error: #{e.message}"
end
puts "\n"

puts "=== 2. Running MapDemoReactor (Inline Map) ==="
begin
  # Run just the inline part or the whole reactor? The whole reactor runs all maps.
  result = MapDemoReactor.run(
    inline_list: [1, 2, 3, 4, 5],
    async_list: (1..10).to_a,
    batch_list: (1..100).to_a,
    ar_query: Product.all
  )
  puts "Result Class: #{result.class}"
  if result.is_a?(RubyReactor::DispatchResult)
    puts "Reactor Status: Async Execution Started (Job ID: #{result.job_id})"
  else
    puts "Result: #{result.success? ? 'Success' : 'Failure'}"
    if result.success?
      puts "Reactor Status: #{result.status}"
    else
      puts "Error: #{result.error}"
    end
  end
rescue => e
  puts "Exception: #{e.message}"
  puts e.backtrace.first(5)
end
puts "\n"

puts "=== 3. Running Async Patterns ==="
puts "-- FullAsyncReactor --"
res = FullAsyncReactor.run(param: "test")
puts "Result Class: #{res.class} (Expected: RubyReactor::DispatchResult)"

puts "-- BackgroundDemoReactor --"
res = BackgroundDemoReactor.run(user_id: "user_123")
puts "Result Class: #{res.class} (Expected: RubyReactor::DispatchResult)"

puts "-- AsyncStepDemoReactor --"
res = AsyncStepDemoReactor.run(email: "demo@example.com")
puts "Result Class: #{res.class} (the reactor keeps running; :send_email is out in its own job)"

puts "-- AsyncReactorDemoReactor --"
res = AsyncReactorDemoReactor.run(user_id: "user_123")
puts "Result Class: #{res.class} (children run independently, linked by execution id)"
puts "\n"

puts "=== 4. Running Composition ==="
puts "-- ParentReactor --"
res = ParentReactor.run(a: 5, b: 3)
if res.success?
  puts "Result: #{res.value}"
else
  puts "Failure: #{res.error}"
end

puts "-- InlineCompositionReactor --"
res = InlineCompositionReactor.run(numbers: [10, 20, 30, 40])
if res.success?
  puts "Result: #{res.value}"
else
  puts "Failure: #{res.error}"
end

puts "\n"
puts "=== 5. Running OrderProcessingReactor (Mock) ==="
puts "-- Success Scenario --"
res = OrderProcessingReactor.run(
  order_id: "ord_1",
  product_id: "prod_1",
  quantity: 5,
  amount: 100
)
if res.is_a?(RubyReactor::DispatchResult)
  puts "Async execution started: #{res.job_id}"
else
  puts "Result: #{res.success? ? 'Success' : 'Failure'} - #{res.value}"
end

puts "-- Failure/Undo Scenario (Fail at check_inventory) --"
res = OrderProcessingReactor.run(
  order_id: "ord_2",
  product_id: "prod_1",
  quantity: 5,
  amount: 100,
  fail_at: :check_inventory
)
puts "Result: #{res.success? ? 'Success' : 'Failure'} - #{res.error}"
puts "\n"

puts "=== 6. Running PaymentWorkflow (Mock) ==="
puts "-- Success Scenario --"
res = PaymentWorkflow.run(order_id: "ord_pw_1")
puts "Result: #{res.success? ? 'Success' : 'Failure'} - #{res.value}"

puts "-- Failure Scenario (Fail at capture_payment) --"
res = PaymentWorkflow.run(order_id: "ord_pw_2", fail_at: :capture_payment)
puts "Result: #{res.success? ? 'Success' : 'Failure'} - #{res.error}"
puts "\n"

puts "=== 7. Interrupt Demos ==="
puts "These require manual interaction:"
puts "1. Visit /reactors to start Form Demo."
puts "2. Use curl for Webhook Demo."
