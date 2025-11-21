# frozen_string_literal: true

require "spec_helper"
require "sidekiq/testing"

RSpec.describe RubyReactor::AsyncResult do
  before do
    Sidekiq::Testing.fake!
    Sidekiq::Worker.clear_all
    allow(RubyReactor::Configuration.instance).to receive(:async_router).and_return(RubyReactor::AsyncRouter)
  end

  after do
    Sidekiq::Testing.fake!
  end

  describe "#get" do
    context "when AsyncResult is created with intermediate_results" do
      let(:intermediate_results) do
        {
          create_user: { id: 123, email: "test@example.com" },
          validate_email: "test@example.com",
          hash_password: "hashed_password_123"
        }
      end

      let(:async_result) do
        described_class.new(job_id: "job_123", intermediate_results: intermediate_results)
      end

      it "returns the result for a given step name as symbol" do
        expect(async_result.get(:create_user)).to eq({ id: 123, email: "test@example.com" })
      end

      it "returns the result for a given step name as string" do
        expect(async_result.get("create_user")).to eq({ id: 123, email: "test@example.com" })
      end

      it "returns nil for a step that doesn't exist" do
        expect(async_result.get(:non_existent_step)).to be_nil
      end

      it "can retrieve different step results" do
        expect(async_result.get(:validate_email)).to eq("test@example.com")
        expect(async_result.get(:hash_password)).to eq("hashed_password_123")
      end
    end

    context "when AsyncResult is created without intermediate_results" do
      let(:async_result) { described_class.new(job_id: "job_123") }

      it "returns nil for any step name" do
        expect(async_result.get(:any_step)).to be_nil
      end
    end

    context "when using step-level async with actual reactor execution" do
      let(:reactor_class) do
        Class.new(RubyReactor::Reactor) do
          input :email
          input :password

          step :validate_email do
            argument :email, input(:email)

            run do |args, _context|
              RubyReactor::Success(args[:email].downcase)
            end
          end

          step :hash_password do
            argument :password, input(:password)

            run do |args, _context|
              RubyReactor::Success("hashed_#{args[:password]}")
            end
          end

          step :create_user do
            async true
            argument :email, result(:validate_email)
            argument :password_hash, result(:hash_password)

            run do |args, _context|
              user = { id: 999, email: args[:email], password_hash: args[:password_hash] }
              RubyReactor::Success(user)
            end
          end

          returns :create_user
        end
      end

      it "includes results from steps executed before async handoff" do
        reactor = reactor_class.new
        result = reactor.run(email: "Test@Example.com", password: "secret123")

        expect(result).to be_a(described_class)

        # Steps that ran before async handoff should be available
        expect(result.get(:validate_email)).to eq("test@example.com")
        expect(result.get(:hash_password)).to eq("hashed_secret123")

        # The async step hasn't executed yet, so it shouldn't have a result
        expect(result.get(:create_user)).to be_nil
      end
    end

    context "when using full reactor async execution" do
      let(:reactor_class) do
        Class.new(RubyReactor::Reactor) do
          async

          input :user_id

          step :fetch_user do
            argument :user_id, input(:user_id)

            run do |args, _context|
              RubyReactor::Success({ id: args[:user_id], name: "Test User" })
            end
          end

          returns :fetch_user
        end
      end

      it "has no intermediate results since no steps have executed yet" do
        reactor = reactor_class.new
        result = reactor.run(user_id: 123)

        expect(result).to be_a(described_class)
        expect(result.get(:fetch_user)).to be_nil
      end
    end
  end

  describe "intermediate_results attribute" do
    it "exposes intermediate_results as a reader" do
      intermediate_results = { step1: "result1", step2: "result2" }
      async_result = described_class.new(job_id: "job_123", intermediate_results: intermediate_results)

      expect(async_result.intermediate_results).to eq(intermediate_results)
    end

    it "defaults to empty hash when not provided" do
      async_result = described_class.new(job_id: "job_123")

      expect(async_result.intermediate_results).to eq({})
    end
  end
end
