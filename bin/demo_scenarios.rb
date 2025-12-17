# bin/demo_scenarios.rb

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
  if result.is_a?(RubyReactor::AsyncResult)
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
puts "Result Class: #{res.class} (Expected: RubyReactor::AsyncResult)"

puts "-- PartialAsyncReactor --"
res = PartialAsyncReactor.run(user_id: "user_123")
puts "Result Class: #{res.class} (Expected: RubyReactor::AsyncResult)"
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
puts "=== 5. Interrupt Demos ==="
puts "These require manual interaction:"
puts "1. Visit /reactors to start Form Demo."
puts "2. Use curl for Webhook Demo."
