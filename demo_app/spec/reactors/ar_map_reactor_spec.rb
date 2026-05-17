require "rails_helper"

describe ArMapReactor do


  describe "#process_event" do
    it "processes an ActiveRecord model event and maps it correctly" do
      (10..20).each do |n|
        Product.find_or_create_by(name: "Product #{n}", stock: n >= 15 ? 6 : 0)
      end
      
      reactor = test_reactor(described_class, { filter: { stock: 5 } })
      
      expect(reactor).to be_failure
      error = reactor.result
      expect(error.exception_class).to eq("RuntimeError")
      expect(error.message).to match("Random error triggered!")
    end
  end
end
