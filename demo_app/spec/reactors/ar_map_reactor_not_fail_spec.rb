require "rails_helper"

describe ArMapReactorNotFail do


  describe "#process_event" do
    it "processes an ActiveRecord model event and maps it correctly" do
      (10..20).each do |n|
        Product.find_or_create_by(name: "Product #{n}", stock: n >= 15 ? 6 : 0)
      end
      
      reactor = test_reactor(described_class, { filter: { stock: 5 } })
      
      expect(reactor).to be_success
      products = reactor.result.value
      products.successes.each do |product|
        expect(product).to be_a(Product)
        expect(product.stock).to be >= 5
      end
      products.failures.count.should be > 0
    end
  end
end
