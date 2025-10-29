# frozen_string_literal: true

module RubyReactor
  class Executor
    class GraphManager
      def initialize(reactor_class, dependency_graph, context)
        @reactor_class = reactor_class
        @dependency_graph = dependency_graph
        @context = context
      end

      def build_and_validate!
        build_dependency_graph
        validate_graph!
      end

      def mark_completed_steps_from_context
        @context.intermediate_results.each_key do |step_name|
          @dependency_graph.complete_step(step_name)
        end
      end

      private

      def build_dependency_graph
        @reactor_class.steps.each_value do |step_config|
          @dependency_graph.add_step(step_config)
        end
      end

      def validate_graph!
        return unless @dependency_graph.has_cycles?

        raise Error::DependencyError.new(
          "Dependency graph contains cycles",
          context: @context
        )
      end
    end
  end
end