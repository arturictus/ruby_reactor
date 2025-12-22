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

      if result.success?
        puts "✅ SUCCESS: Workflow completed successfully."
        puts "   Result: #{result.value.inspect}"
      else
        puts "❌ FAILED: Workflow failed as expected."
        puts "   Error: #{result.message}"
      end
    end
  end
end
