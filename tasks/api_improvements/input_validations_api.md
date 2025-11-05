```ruby
# ...existing code...

# Add this new class for building input validations
class InputBuilder
  attr_reader :schema

  def initialize(name, optional: false)
    @name = name
    @optional = optional
    @schema = nil
  end

  def filled(type, **options)
    @schema = Dry::Validation::Contract.build do
      if @optional
        optional(@name).filled(type, **options)
      else
        required(@name).filled(type, **options)
      end
    end
  end

  def maybe(type, **options)
    @schema = Dry::Validation::Contract.build do
      optional(@name).maybe(type, **options)
    end
  end

  def hash(**options, &block)
    @schema = Dry::Validation::Contract.build do
      if @optional
        optional(@name).hash(**options, &block)
      else
        required(@name).hash(**options, &block)
      end
    end
  end

  # Add more methods as needed for other dry-validation features, e.g.:
  def array(**options, &block)
    @schema = Dry::Validation::Contract.build do
      if @optional
        optional(@name).array(**options, &block)
      else
        required(@name).array(**options, &block)
      end
    end
  end
end

# ...existing code...

def input(name, optional: false, &block)
  if block
    builder = InputBuilder.new(name, optional: optional)
    # Check if the block expects an argument (new API) or not (old API for compatibility)
    if block.arity == 1
      block.call(builder)  # New API: |input| input.filled(:string)
    else
      # Fallback to old API: direct dry-validation block
      @input_validations[name] = block
    end
    # If new API was used, store the built schema
    @input_validations[name] = builder.schema if builder.schema
  end

  @inputs[name] = { optional: optional, description: nil }
end

# ...existing code...
```