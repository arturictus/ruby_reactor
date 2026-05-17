# frozen_string_literal: true

require "spec_helper"
require "dry-validation"

RSpec.describe "Dry::Validation Integration" do
  describe "Input Validation" do
    describe "basic input validation with schema blocks" do
      let(:user_registration_reactor) do
        Class.new(RubyReactor::Reactor) do
          input :username do
            required(:username).filled(:string, min_size?: 3, max_size?: 20)
          end

          input :email do
            required(:email).filled(:string, format?: /\A[^@\s]+@[^@\s]+\z/)
          end

          input :password do
            required(:password).filled(:string, min_size?: 8)
          end

          input :age, optional: true do
            optional(:age).maybe(:integer, gteq?: 13)
          end

          step :create_user do
            argument :username, input(:username)
            argument :email, input(:email)
            argument :password, input(:password)
            argument :age, input(:age)

            run do |args, _context|
              user = {
                id: SecureRandom.uuid,
                username: args[:username],
                email: args[:email],
                age: args[:age],
                created_at: Time.now
              }
              Success(user)
            end
          end

          returns :create_user
        end
      end

      context "with valid inputs" do
        it "successfully creates a user with all required fields" do
          result = user_registration_reactor.run(
            username: "alice123",
            email: "alice@example.com",
            password: "securepassword123",
            age: 25
          )

          expect(result).to be_a(RubyReactor::Success)
          user = result.value
          expect(user[:username]).to eq("alice123")
          expect(user[:email]).to eq("alice@example.com")
          expect(user[:age]).to eq(25)
          expect(user[:id]).to be_a(String)
          expect(user[:created_at]).to be_a(Time)
        end

        it "successfully creates a user without optional fields" do
          result = user_registration_reactor.run(
            username: "bob456",
            email: "bob@example.com",
            password: "anotherpassword"
          )

          expect(result).to be_a(RubyReactor::Success)
          user = result.value
          expect(user[:username]).to eq("bob456")
          expect(user[:email]).to eq("bob@example.com")
          expect(user[:age]).to be_nil
        end
      end

      context "with invalid inputs" do
        it "fails with username too short" do
          result = user_registration_reactor.run(
            username: "ab", # Too short
            email: "alice@example.com",
            password: "securepassword123"
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors[:username]).to include("size cannot be less than 3")
        end

        it "fails with invalid email format" do
          result = user_registration_reactor.run(
            username: "alice123",
            email: "invalid-email", # Invalid format
            password: "securepassword123"
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors[:email]).to include("is in invalid format")
        end

        it "fails with password too short" do
          result = user_registration_reactor.run(
            username: "alice123",
            email: "alice@example.com",
            password: "short" # Too short
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors[:password]).to include("size cannot be less than 8")
        end

        it "fails with age below minimum" do
          result = user_registration_reactor.run(
            username: "alice123",
            email: "alice@example.com",
            password: "securepassword123",
            age: 10 # Too young
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors[:age]).to include("must be greater than or equal to 13")
        end

        it "accumulates multiple validation errors" do
          result = user_registration_reactor.run(
            username: "a", # Too short
            email: "invalid", # Invalid format
            password: "123", # Too short
            age: 5 # Too young
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)

          errors = result.error.field_errors
          expect(errors.keys).to include(:username, :email, :password, :age)
          expect(errors[:username]).to include("size cannot be less than 3")
          expect(errors[:email]).to include("is in invalid format")
          expect(errors[:password]).to include("size cannot be less than 8")
          expect(errors[:age]).to include("must be greater than or equal to 13")
        end
      end
    end

    describe "nested input validation" do
      let(:order_processing_reactor) do
        Class.new(RubyReactor::Reactor) do
          input :order do
            required(:order).hash do
              required(:customer).hash do
                required(:name).filled(:string)
                required(:email).filled(:string, format?: /\A[^@\s]+@[^@\s]+\z/)
              end
              required(:items).each do
                schema do
                  required(:product_id).filled(:string)
                  required(:quantity).filled(:integer, gt?: 0)
                  required(:price).filled(:float, gt?: 0)
                end
              end
              optional(:shipping_address).hash do
                required(:street).filled(:string)
                required(:city).filled(:string)
                required(:zip_code).filled(:string)
              end
            end
          end

          step :process_order do
            argument :order, input(:order)

            run do |args, _context|
              order = args[:order]
              total = order[:items].sum { |item| item[:quantity] * item[:price] }

              processed_order = order.merge(
                id: SecureRandom.uuid,
                total: total,
                status: "processed"
              )

              Success(processed_order)
            end
          end

          returns :process_order
        end
      end

      context "with valid nested inputs" do
        it "successfully processes a complete order" do
          result = order_processing_reactor.run(
            order: {
              customer: {
                name: "John Doe",
                email: "john@example.com"
              },
              items: [
                { product_id: "prod-123", quantity: 2, price: 29.99 },
                { product_id: "prod-456", quantity: 1, price: 49.99 }
              ],
              shipping_address: {
                street: "123 Main St",
                city: "Anytown",
                zip_code: "12345"
              }
            }
          )

          expect(result).to be_a(RubyReactor::Success)
          order = result.value
          expect(order[:customer][:name]).to eq("John Doe")
          expect(order[:total]).to eq(109.97) # (2*29.99) + (1*49.99)
          expect(order[:status]).to eq("processed")
        end
      end

      context "with invalid nested inputs" do
        it "fails with invalid customer email" do
          result = order_processing_reactor.run(
            order: {
              customer: {
                name: "John Doe",
                email: "invalid-email" # Invalid
              },
              items: [
                { product_id: "prod-123", quantity: 1, price: 29.99 }
              ]
            }
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors.keys.map(&:to_s)).to include("order[customer][email]")
        end

        it "fails with invalid item quantity" do
          result = order_processing_reactor.run(
            order: {
              customer: {
                name: "John Doe",
                email: "john@example.com"
              },
              items: [
                { product_id: "prod-123", quantity: 0, price: 29.99 } # Invalid quantity
              ]
            }
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(RubyReactor::Error::InputValidationError)
          expect(result.error.field_errors.keys.map(&:to_s)).to include("order[items][0][quantity]")
        end
      end
    end

    describe "pre-defined schema objects" do
      let(:user_schema) do
        Dry::Schema.Params do
          required(:user).hash do
            required(:first_name).filled(:string, min_size?: 1)
            required(:last_name).filled(:string, min_size?: 1)
            required(:email).filled(:string, format?: /\A[^@\s]+@[^@\s]+\z/)
            optional(:phone).maybe(:string, format?: /\A\+?\d{10,15}\z/)
          end
        end
      end

      let(:user_profile_reactor) do
        schema = user_schema
        Class.new(RubyReactor::Reactor) do
          input :user, validate: schema

          step :create_profile do
            argument :user, input(:user)

            run do |args, _context|
              user = args[:user]
              profile = {
                full_name: "#{user[:first_name]} #{user[:last_name]}",
                email: user[:email],
                phone: user[:phone],
                profile_id: SecureRandom.uuid
              }
              Success(profile)
            end
          end

          returns :create_profile
        end
      end

      it "validates using pre-defined schema successfully" do
        result = user_profile_reactor.run(
          user: {
            first_name: "Alice",
            last_name: "Johnson",
            email: "alice@example.com",
            phone: "+1234567890"
          }
        )

        expect(result).to be_a(RubyReactor::Success)
        profile = result.value
        expect(profile[:full_name]).to eq("Alice Johnson")
        expect(profile[:email]).to eq("alice@example.com")
        expect(profile[:phone]).to eq("+1234567890")
      end

      it "fails validation with pre-defined schema" do
        result = user_profile_reactor.run(
          user: {
            first_name: "",
            last_name: "Johnson",
            email: "invalid-email",
            phone: "not-a-phone"
          }
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to be_a(RubyReactor::Error::InputValidationError)

        errors = result.error.field_errors
        expect(errors.keys.map(&:to_s)).to include(
          "user[first_name]", "user[email]", "user[phone]"
        )
      end
    end
  end

  describe "Argument Validation" do
    describe "step argument validation with validate_args" do
      let(:payment_processing_reactor) do
        Class.new(RubyReactor::Reactor) do
          input :amount
          input :currency
          input :card_token

          step :validate_payment_data do
            argument :amount, input(:amount)
            argument :currency, input(:currency)
            argument :card_token, input(:card_token)

            validate_args do
              required(:amount).filled(:decimal, gt?: 0)
              required(:currency).filled(:string, included_in?: %w[USD EUR GBP])
              required(:card_token).filled(:string, min_size?: 10)
            end

            run do |args, _context|
              # Simulate payment validation
              validated_data = {
                amount: args[:amount],
                currency: args[:currency],
                card_token: args[:card_token],
                validated_at: Time.now
              }
              Success(validated_data)
            end
          end

          step :process_payment do
            argument :validated_data, result(:validate_payment_data)

            run do |args, _context|
              data = args[:validated_data]
              # Simulate payment processing
              payment_result = {
                transaction_id: SecureRandom.uuid,
                amount: data[:amount],
                currency: data[:currency],
                status: "completed"
              }
              Success(payment_result)
            end
          end

          returns :process_payment
        end
      end

      context "with valid arguments" do
        it "successfully processes payment with valid data" do
          result = payment_processing_reactor.run(
            amount: 99.99,
            currency: "USD",
            card_token: "tok_1234567890"
          )

          expect(result).to be_a(RubyReactor::Success)
          payment = result.value
          expect(payment[:amount]).to eq(99.99)
          expect(payment[:currency]).to eq("USD")
          expect(payment[:status]).to eq("completed")
          expect(payment[:transaction_id]).to be_a(String)
        end
      end

      context "with invalid arguments" do
        it "fails with negative amount" do
          result = payment_processing_reactor.run(
            amount: -50.00, # Invalid
            currency: "USD",
            card_token: "tok_1234567890"
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("argument validation failed")
          expect(result.error).to include("amount")
          expect(result.error).to include("must be greater than 0")
        end

        it "fails with unsupported currency" do
          result = payment_processing_reactor.run(
            amount: 100.00,
            currency: "BTC", # Invalid
            card_token: "tok_1234567890"
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("argument validation failed")
          expect(result.error).to include("currency")
          expect(result.error).to include("must be one of")
        end

        it "fails with short card token" do
          result = payment_processing_reactor.run(
            amount: 100.00,
            currency: "USD",
            card_token: "short" # Invalid
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("argument validation failed")
          expect(result.error).to include("card_token")
          expect(result.error).to include("size cannot be less than 10")
        end
      end
    end

    describe "complex argument validation with nested structures" do
      let(:inventory_management_reactor) do
        Class.new(RubyReactor::Reactor) do
          input :product_data
          input :warehouse_id

          step :validate_and_prepare_inventory do
            argument :product_data, input(:product_data)
            argument :warehouse_id, input(:warehouse_id)

            validate_args do
              required(:product_data).hash do
                required(:name).filled(:string, min_size?: 2)
                required(:sku).filled(:string, format?: /\A[A-Z]{2}\d{6}\z/)
                required(:category).filled(:string, included_in?: %w[electronics clothing books])
                required(:price).filled(:decimal, gt?: 0)
                required(:stock_quantity).filled(:integer, gteq?: 0)
                optional(:description).maybe(:string, max_size?: 500)
              end
              required(:warehouse_id).filled(:string, format?: /\AWH-\d{4}\z/)
            end

            run do |args, _context|
              product = args[:product_data]
              inventory_item = {
                product_id: SecureRandom.uuid,
                name: product[:name],
                sku: product[:sku],
                category: product[:category],
                price: product[:price],
                stock_quantity: product[:stock_quantity],
                warehouse_id: args[:warehouse_id],
                description: product[:description],
                created_at: Time.now
              }
              Success(inventory_item)
            end
          end

          step :update_inventory do
            argument :inventory_item, result(:validate_and_prepare_inventory)

            run do |args, _context|
              item = args[:inventory_item]
              # Simulate inventory update
              updated_item = item.merge(
                last_updated: Time.now,
                status: "active"
              )
              Success(updated_item)
            end
          end

          returns :update_inventory
        end
      end

      context "with valid complex arguments" do
        it "successfully processes inventory item" do
          result = inventory_management_reactor.run(
            product_data: {
              name: "Wireless Headphones",
              sku: "EL123456",
              category: "electronics",
              price: 199.99,
              stock_quantity: 50,
              description: "High-quality wireless headphones with noise cancellation"
            },
            warehouse_id: "WH-0001"
          )

          expect(result).to be_a(RubyReactor::Success)
          item = result.value
          expect(item[:name]).to eq("Wireless Headphones")
          expect(item[:sku]).to eq("EL123456")
          expect(item[:category]).to eq("electronics")
          expect(item[:price]).to eq(199.99)
          expect(item[:stock_quantity]).to eq(50)
          expect(item[:warehouse_id]).to eq("WH-0001")
          expect(item[:status]).to eq("active")
        end
      end

      context "with invalid complex arguments" do
        it "fails with invalid SKU format" do
          result = inventory_management_reactor.run(
            product_data: {
              name: "Wireless Headphones",
              sku: "invalid-sku", # Invalid format
              category: "electronics",
              price: 199.99,
              stock_quantity: 50
            },
            warehouse_id: "WH-0001"
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("argument validation failed")
          expect(result.error).to include("sku")
          expect(result.error).to include("is in invalid format")
        end

        it "fails with invalid warehouse ID format" do
          result = inventory_management_reactor.run(
            product_data: {
              name: "Wireless Headphones",
              sku: "EL123456",
              category: "electronics",
              price: 199.99,
              stock_quantity: 50
            },
            warehouse_id: "INVALID" # Invalid format
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("argument validation failed")
          expect(result.error).to include("warehouse_id")
          expect(result.error).to include("is in invalid format")
        end

        it "fails with negative price" do
          result = inventory_management_reactor.run(
            product_data: {
              name: "Wireless Headphones",
              sku: "EL123456",
              category: "electronics",
              price: -50.00, # Invalid
              stock_quantity: 50
            },
            warehouse_id: "WH-0001"
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("argument validation failed")
          expect(result.error).to include("price")
          expect(result.error).to include("must be greater than 0")
        end
      end
    end

    describe "argument validation with custom predicates" do
      let(:booking_system_reactor) do
        Class.new(RubyReactor::Reactor) do
          input :booking_request

          step :validate_booking do
            argument :booking, input(:booking_request)

            validate_args do
              required(:booking).hash do
                required(:check_in).filled(:date)
                required(:check_out).filled(:date)
                required(:guests).filled(:integer, gteq?: 1, lteq?: 10)
                required(:room_type).filled(:string, included_in?: %w[standard deluxe suite])
              end
            end

            run do |args, _context|
              booking = args[:booking]

              # Custom validation: check_out must be after check_in
              if booking[:check_out] <= booking[:check_in]
                Failure("Check-out date must be after check-in date")
              else
                validated_booking = booking.merge(
                  booking_id: SecureRandom.uuid,
                  total_nights: (booking[:check_out] - booking[:check_in]).to_i,
                  validated_at: Time.now
                )
                Success(validated_booking)
              end
            end
          end

          step :confirm_booking do
            argument :validated_booking, result(:validate_booking)

            run do |args, _context|
              booking = args[:validated_booking]
              confirmed_booking = booking.merge(
                status: "confirmed",
                confirmation_code: "BK#{SecureRandom.hex(4).upcase}"
              )
              Success(confirmed_booking)
            end
          end

          returns :confirm_booking
        end
      end

      context "with valid booking arguments" do
        it "successfully processes booking" do
          result = booking_system_reactor.run(
            booking_request: {
              check_in: Date.parse("2024-12-20"),
              check_out: Date.parse("2024-12-25"),
              guests: 2,
              room_type: "deluxe"
            }
          )

          expect(result).to be_a(RubyReactor::Success)
          booking = result.value
          expect(booking[:total_nights]).to eq(5)
          expect(booking[:status]).to eq("confirmed")
          expect(booking[:confirmation_code]).to start_with("BK")
        end
      end

      context "with invalid booking arguments" do
        it "fails with check-out before check-in" do
          result = booking_system_reactor.run(
            booking_request: {
              check_in: Date.parse("2024-12-25"),
              check_out: Date.parse("2024-12-20"), # Before check-in
              guests: 2,
              room_type: "deluxe"
            }
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("Check-out date must be after check-in date")
        end

        it "fails with too many guests" do
          result = booking_system_reactor.run(
            booking_request: {
              check_in: Date.parse("2024-12-20"),
              check_out: Date.parse("2024-12-25"),
              guests: 15, # Too many
              room_type: "deluxe"
            }
          )

          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("argument validation failed")
          expect(result.error).to include("guests")
          expect(result.error).to include("must be less than or equal to 10")
        end
      end
    end
  end

  describe "Output Validation" do
    describe "step output validation with validate_output" do
      let(:data_processing_reactor) do
        Class.new(RubyReactor::Reactor) do
          input :raw_data

          step :process_data do
            argument :data, input(:raw_data)

            run do |args, _context|
              raw = args[:data]
              # Simulate data processing that might return invalid results
              processed = {
                id: SecureRandom.uuid,
                value: raw[:value].to_i * 2,
                category: raw[:category]&.upcase,
                timestamp: Time.now
              }
              Success(processed)
            end

            validate_output do
              required(:id).filled(:string, format?: /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
              required(:value).filled(:integer, gteq?: 0)
              required(:category).filled(:string, included_in?: %w[PRIMARY SECONDARY TERTIARY])
              required(:timestamp).filled
            end
          end

          step :store_result do
            argument :processed_data, result(:process_data)

            run do |args, _context|
              data = args[:processed_data]
              # Simulate storing the result
              stored = data.merge(
                stored_at: Time.now,
                storage_id: "store_#{SecureRandom.hex(4)}"
              )
              Success(stored)
            end
          end

          returns :store_result
        end
      end

      context "with valid output" do
        it "successfully processes and stores valid data" do
          result = data_processing_reactor.run(
            raw_data: {
              value: 25,
              category: "primary"
            }
          )

          expect(result).to be_a(RubyReactor::Success)
          stored = result.value
          expect(stored[:value]).to eq(50) # 25 * 2
          expect(stored[:category]).to eq("PRIMARY")
          expect(stored[:storage_id]).to start_with("store_")
        end
      end

      context "with invalid output" do
        it "fails when processing returns invalid category" do
          # This test would require mocking the step to return invalid output
          # For now, we'll test the validation logic by creating a custom step
          invalid_output_reactor = Class.new(RubyReactor::Reactor) do
            step :generate_invalid_output do
              run do |_args, _context|
                # Intentionally return invalid output
                invalid_result = {
                  id: "not-a-uuid", # Invalid UUID format
                  value: -10, # Invalid negative value
                  category: "INVALID", # Invalid category
                  timestamp: nil # Invalid nil timestamp
                }
                Success(invalid_result)
              end

              validate_output do
                required(:id).filled(:string,
                                     format?: /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
                required(:value).filled(:integer, gteq?: 0)
                required(:category).filled(:string, included_in?: %w[PRIMARY SECONDARY TERTIARY])
                required(:timestamp).filled
              end
            end

            returns :generate_invalid_output
          end

          result = invalid_output_reactor.run({})
          expect(result).to be_a(RubyReactor::Failure)
          expect(result.error).to be_a(String)
          expect(result.error).to include("output validation failed")
        end
      end
    end
  end

  describe "Error Handling and Edge Cases" do
    describe "missing dry-validation gem" do
      it "raises LoadError when dry-validation is not available" do
        # Temporarily hide the Dry constant
        if defined?(Dry)
          stub_const("Dry", nil) do
            expect do
              Class.new(RubyReactor::Reactor) do
                input :test do
                  required(:test).filled(:string)
                end
              end
            end.to raise_error(LoadError, /dry-validation gem is required/)
          end
        else
          expect do
            Class.new(RubyReactor::Reactor) do
              input :test do
                required(:test).filled(:string)
              end
            end
          end.to raise_error(LoadError, /dry-validation gem is required/)
        end
      end
    end

    describe "validation error formatting" do
      let(:complex_validation_reactor) do
        Class.new(RubyReactor::Reactor) do
          input :data do
            required(:data).hash do
              required(:user).hash do
                required(:profile).hash do
                  required(:personal).hash do
                    required(:name).filled(:string, min_size?: 2)
                    required(:age).filled(:integer, gteq?: 18)
                  end
                  required(:contact).hash do
                    required(:email).filled(:string, format?: /\A[^@\s]+@[^@\s]+\z/)
                    optional(:phone).maybe(:string)
                  end
                end
              end
              required(:preferences).each do
                schema do
                  required(:key).filled(:string)
                  required(:value).filled
                end
              end
            end
          end

          step :process do
            argument :data, input(:data)

            run do |args, _context|
              Success(args[:data])
            end
          end

          returns :process
        end
      end

      it "formats deeply nested validation errors correctly" do
        result = complex_validation_reactor.run(
          data: {
            user: {
              profile: {
                personal: {
                  name: "A", # Too short
                  age: 16 # Too young
                },
                contact: {
                  email: "invalid-email" # Invalid format
                }
              }
            },
            preferences: [
              { key: "", value: "test" }, # Empty key
              { key: "valid", value: nil } # Nil value
            ]
          }
        )

        expect(result).to be_a(RubyReactor::Failure)
        expect(result.error).to be_a(RubyReactor::Error::InputValidationError)

        errors = result.error.field_errors
        error_keys = errors.keys.map(&:to_s)

        # Check that nested error keys are properly formatted
        expect(error_keys).to include("data[user][profile][personal][name]")
        expect(error_keys).to include("data[user][profile][personal][age]")
        expect(error_keys).to include("data[user][profile][contact][email]")
        expect(error_keys).to include("data[preferences][0][key]")
        expect(error_keys).to include("data[preferences][1][value]")
      end
    end
  end
end
