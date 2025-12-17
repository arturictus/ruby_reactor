class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.string :user_name
      t.decimal :total
      t.string :status

      t.timestamps
    end
  end
end
