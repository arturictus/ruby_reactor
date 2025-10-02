# frozen_string_literal: true

module RubyReactor
  module Dsl
    module Reactor
      def self.included(base)
        base.extend(ClassMethods)
        base.instance_variable_set(:@inputs, {})
        base.instance_variable_set(:@steps, {})
        base.instance_variable_set(:@return_step, nil)
        base.instance_variable_set(:@middlewares, [])
      end

      module ClassMethods
        include RubyReactor::Dsl::TemplateHelpers

        attr_reader :inputs, :steps, :return_step, :middlewares

        def input(name, transform: nil, description: nil)
          inputs[name] = {
            transform: transform,
            description: description
          }
        end

        def step(name, impl = nil, &block)
          builder = RubyReactor::Dsl::StepBuilder.new(name, impl)
          
          if block_given?
            builder.instance_eval(&block)
          end
          
          step_config = builder.build
          steps[name] = step_config
          step_config
        end

        def returns(step_name)
          @return_step = step_name
        end

        # Alias for backward compatibility
        alias_method :return, :returns

        def middleware(middleware_class)
          middlewares << middleware_class
        end

        def inputs
          @inputs ||= {}
        end

        def steps
          @steps ||= {}
        end

        def middlewares
          @middlewares ||= []
        end

        # Entry point for running the reactor
        def run(inputs = {})
          reactor = new
          reactor.run(inputs)
        end

        def call(inputs = {})
          run(inputs)
        end
      end
    end
  end
end