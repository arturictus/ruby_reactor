# frozen_string_literal: true

module RubyReactor
  module Dsl
    # `queue <name>` on a reactor or step class (011 R-01). The writer is
    # private, so it works where `self` is the class — a `class` body, a
    # `Class.new { }` block, `self.queue` — and a call with an explicit
    # receiver (`MyReactor.queue(:x)`) reaches `method_missing` and raises:
    # declarations are fixed for the life of the process (FR-004).
    #
    # ponytail: `send(:queue, ...)` / `class_eval { queue ... }` reopen the
    # class on purpose and get past the freeze; add a first-run seal if
    # someone needs it.
    module StaticQueue
      # A declared queue name as stored and compared: a non-empty String.
      def self.normalize!(name, owner_label)
        valid = (name.is_a?(Symbol) || name.is_a?(String)) && !name.to_s.empty?
        return name.to_s if valid

        raise Error::ValidationError,
              "#{owner_label} declares `queue #{name.inspect}`: a queue name must be a non-empty Symbol or String."
      end

      # The class's own declaration, else its superclass's.
      def declared_queue
        @queue || (superclass.declared_queue if superclass.respond_to?(:declared_queue))
      end

      def method_missing(name, *args, &block)
        raise Error::StaticConfigurationError if name == :queue

        super
      end

      def respond_to_missing?(name, include_private = false)
        super
      end

      private

      # Re-declaring the SAME queue is a no-op: a class body can be evaluated
      # twice (code reload, a spec reopening a fixture class).
      def queue(name)
        value = StaticQueue.normalize!(name, self.name || inspect)
        return if @queue == value

        if @queue
          raise Error::ValidationError,
                "#{self.name || inspect} already declares `queue :#{@queue}` and cannot also declare " \
                "`queue :#{value}`. A class has exactly one queue."
        end

        @queue = value
      end
    end
  end
end
