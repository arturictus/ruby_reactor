# db/seeds.rb

puts "Seeding data..."

Product.destroy_all
Order.destroy_all

products = [
  { name: "Laptop", price: 1200.0, stock: 50 },
  { name: "Mouse", price: 25.0, stock: 200 },
  { name: "Keyboard", price: 75.0, stock: 150 },
  { name: "Monitor", price: 300.0, stock: 80 },
  { name: "Headphones", price: 100.0, stock: 120 }
]

Product.create!(products)
puts "Created #{Product.count} products."

orders = [
  { user_name: "Alice", total: 1225.0, status: "pending" },
  { user_name: "Bob", total: 75.0, status: "pending" },
  { user_name: "Charlie", total: 300.0, status: "pending" }
]

Order.create!(orders)
puts "Created #{Order.count} orders."
