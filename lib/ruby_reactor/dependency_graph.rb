# frozen_string_literal: true

module RubyReactor
  class DependencyGraph
    def initialize
      @nodes = {}
      @edges = {}
      @dependencies = {} # Store dependencies for each step
      @completed = Set.new
    end

    def add_step(step_config)
      step_name = step_config.name
      @nodes[step_name] = step_config
      @edges[step_name] = Set.new

      # Calculate and store dependencies
      dependencies = []

      # Add dependencies from argument sources
      step_config.arguments.each_value do |arg_config|
        source = arg_config[:source]
        if source.is_a?(RubyReactor::Template::Result)
          dependencies << source.step_name
          add_dependency(step_name, source.step_name)
        end
      end

      # Add explicit dependencies
      step_config.dependencies.each do |dep_step|
        dependencies << dep_step
        add_dependency(step_name, dep_step)
      end

      @dependencies[step_name] = dependencies.uniq
    end

    def add_dependency(step_name, dependency_name)
      @edges[dependency_name] ||= Set.new
      @edges[dependency_name] << step_name
    end

    def ready_steps
      ready = []
      @nodes.each do |step_name, step_config|
        next if @completed.include?(step_name)

        # Check if all dependencies are completed
        dependencies = @dependencies[step_name] || []
        ready << step_config if dependencies.all? { |dep| @completed.include?(dep) }
      end
      ready
    end

    def complete_step(step_name)
      @completed << step_name
    end

    def has_cycles?
      visited = Set.new
      rec_stack = Set.new

      @nodes.each_key do |node|
        next if visited.include?(node)
        return true if cycle_detected?(node, visited, rec_stack)
      end

      false
    end

    def topological_sort
      return [] if has_cycles?

      visited = Set.new
      stack = []

      @nodes.each_key do |node|
        next if visited.include?(node)

        topological_sort_util(node, visited, stack)
      end

      stack.reverse.map { |name| @nodes[name] }
    end

    def all_completed?
      @completed.size == @nodes.size
    end

    def pending_steps
      @nodes.keys - @completed.to_a
    end

    def topological_sort_util(node, visited, stack)
      visited << node

      dependents = @edges[node] || Set.new
      dependents.each do |dependent|
        next if visited.include?(dependent)

        topological_sort_util(dependent, visited, stack)
      end

      stack << node
    end

    private

    def cycle_detected?(node, visited, rec_stack)
      visited << node
      rec_stack << node

      dependents = @edges[node] || Set.new
      dependents.each do |dependent|
        if !visited.include?(dependent)
          return true if cycle_detected?(dependent, visited, rec_stack)
        elsif rec_stack.include?(dependent)
          return true
        end
      end

      rec_stack.delete(node)
      false
    end
  end
end
