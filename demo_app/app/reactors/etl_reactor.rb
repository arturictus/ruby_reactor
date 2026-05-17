class EtlReactor < RubyReactor::Reactor
  step :fetch_pending_orders do
    run do |_, _|
      orders = Order.where(status: "pending").to_a
      # Serialize AR objects to simple hashes or IDs to avoid marshalling issues in complex scenarios,
      # but RubyReactor handles arguments. Best practice for async is passing IDs, but here we show object passing for sync/inline.
      # For safety in serialized context, we'll map to IDs if this were async.
      # Since this is sync, we can pass objects.
      Success(orders)
    end
  end

  step :transform_data do
    argument :orders, result(:fetch_pending_orders)

    run do |args, _|
      transformed = args[:orders].map do |order|
        {
          id: order.id,
          original_total: order.total,
          tax: order.total * 0.1,
          final_total: order.total * 1.1,
          processed_at: Time.now
        }
      end
      Success(transformed)
    end
  end

  step :update_orders do
    argument :data, result(:transform_data)

    run do |args, _|
      count = 0
      args[:data].each do |item|
        Order.find(item[:id]).update!(
          total: item[:final_total],
          status: "processed"
        )
        count += 1
      end
      Success("Processed #{count} orders")
    end
  end

  returns :update_orders
end
