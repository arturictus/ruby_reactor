# frozen_string_literal: true

require "spec_helper"

# FR-003: the per-step `async` flag is removed. Only the FIRST flagged step in a
# reactor ever took effect and the rest were silently ignored, so the failure has
# to be loud and it has to happen at class-definition time — a reactor that still
# carries the old syntax must never load, let alone run.
RSpec.describe "the removed per-step `async` flag" do
  def define_reactor(&block)
    Class.new(RubyReactor::Reactor, &block)
  end

  describe "inside a `step` block" do
    it "raises at class-definition time" do
      expect do
        define_reactor do
          step :first do
            async true
            run { RubyReactor.Success(1) }
          end
        end
      end.to raise_error(RubyReactor::Error::DeprecatedDslError)
    end

    it "names every replacement in the message" do
      expect do
        define_reactor do
          step :first do
            async true
          end
        end
      end.to raise_error(RubyReactor::Error::DeprecatedDslError) { |e|
        expect(e.message).to include("background")
        expect(e.message).to include("async_step")
        expect(e.message).to include("async_reactor")
      }
    end

    it "is caught by existing `Error::ValidationError` rescues" do
      expect do
        define_reactor do
          step :first do
            async true
          end
        end
      end.to raise_error(RubyReactor::Error::ValidationError)
    end

    it "raises even for `async false`, so no stale call site survives quietly" do
      expect do
        define_reactor do
          step :first do
            async false
          end
        end
      end.to raise_error(RubyReactor::Error::DeprecatedDslError)
    end
  end

  describe "inside a `compose` block" do
    it "raises at class-definition time" do
      child = define_reactor do
        step :inner do
          run { RubyReactor.Success(:inner) }
        end
      end

      expect do
        define_reactor do
          compose :sub_flow, child do
            async true
          end
        end
      end.to raise_error(RubyReactor::Error::DeprecatedDslError)
    end

    it "points at `background before:` as the exact migration" do
      child = define_reactor do
        step :inner do
          run { RubyReactor.Success(:inner) }
        end
      end

      expect do
        define_reactor do
          compose :sub_flow, child do
            async true
          end
        end
      end.to raise_error(/background before:/)
    end
  end

  describe "the map-internal `async` option" do
    it "still works untouched — it is element dispatch, not step hand-off" do
      element = define_reactor do
        input :element
        step :double do
          argument :element, input(:element)
          run { |args| RubyReactor.Success(args[:element] * 2) }
        end
      end

      reactor = nil
      expect do
        reactor = define_reactor do
          input :numbers
          map :doubled, element do
            source input(:numbers)
            async true, batch_size: 2
          end
        end
      end.not_to raise_error

      expect(reactor.steps[:doubled]).to be_a(RubyReactor::Dsl::StepConfig)
    end
  end

  it "leaves reactor-level `async true` alone" do
    reactor = define_reactor do
      async true
      step :only do
        run { RubyReactor.Success(:ok) }
      end
    end

    expect(reactor.async?).to be true
  end
end
