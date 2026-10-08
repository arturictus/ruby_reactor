# frozen_string_literal: true

module RubyReactor
  # A resume claims its interrupt before anything runs (010 R-04): the first
  # `SET NX` wins, in every execution mode, and the claim holds the validated
  # payload. Only the execution that owns the run's lock copies a claim into
  # the context (J-5), at the start of `Executor#resume_execution`, so a
  # resume never writes the run from outside it.
  module InterruptClaims
    module_function

    # true when this call won the interrupt; false when a resume already did.
    # `path` is the interrupt's step path (010 R-05); a nested one is keyed `a.b`.
    def claim!(context, path, payload)
      storage.claim_interrupt_resume(context.context_id, storage_name(context), key(Array(path)),
                                     JSON.generate(ContextSerializer.serialize_value(payload)))
    end

    # `{ step => payload }` (a nested interrupt: `{ [child, step] => payload }`) for the claimed interrupts that have no result yet.
    def unapplied(context)
      paths = pending_interrupts(context)
      return {} if paths.empty?

      raw = storage.retrieve_interrupt_resumes(context.context_id, storage_name(context), paths.map { |p| key(p) })
      paths.filter_map do |path|
        [path.one? ? path.first : path, ContextSerializer.deserialize_value(JSON.parse(raw[key(path)]))] if raw.key?(key(path))
      end.to_h
    end

    # Copies every unapplied claim into the context that paused at it (010 R-06).
    # Returns their steps.
    def apply!(context)
      claims = unapplied(context)
      claims.each do |step, payload|
        path = Array(step)
        path[0...-1].reduce(context) { |ctx, name| child(ctx, name) }.set_result(path.last, payload)
      end
      claims.keys
    end

    # Step paths of the interrupts without a result, here and in paused composed children.
    def pending_interrupts(context, prefix = [])
      steps = context.reactor_class.respond_to?(:steps) ? context.reactor_class.steps : {}
      own = steps.select { |name, config| config.respond_to?(:interrupt?) && config.interrupt? && !context.has_result?(name) }
                 .keys.map { |name| prefix + [name] }
      nested = steps.keys.flat_map do |name|
        (c = child(context, name)) ? pending_interrupts(c, prefix + [name]) : []
      end
      own + nested
    end

    def child(context, name)
      entry = context.composed_contexts[name] || context.composed_contexts[name.to_s]
      c = entry.is_a?(Hash) && (entry[:context] || entry["context"])
      c if c.is_a?(Context) && c.status.to_s == "paused"
    end

    def key(path)
      path.join(".")
    end

    def storage_name(context)
      RubyReactor.reactor_storage_name(context.reactor_class)
    end

    def storage
      RubyReactor.configuration.storage_adapter
    end
  end
end
