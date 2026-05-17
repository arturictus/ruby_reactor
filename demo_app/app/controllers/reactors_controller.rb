class ReactorsController < ApplicationController
  def index
    # Just a landing page to start demos
  end

  def create
    # Start the form demo
    reactor = FormInterruptReactor.run(user_name: params[:user_name] || "Guest")
    # In a real app we'd persist the reactor_id to DB or session. 
    # Here we redirect to show it.
    redirect_to reactor_path(reactor.context.reactor_id)
  end

  def show
    @reactor_id = params[:id]
    # We load the reactor context from storage
    # RubyReactor doesn't have a public API to just "load" without running, 
    # but we can check status/context if we had it.
    # However, to "resume", we need the ID.
    
    # For demo purposes, we assume we are at the paused step if visited here.
    @paused_step = :wait_for_user_input
  end

  def update
    @reactor_id = params[:id]
    bio = params[:bio]

    # Resume the reactor
    # method: continue(reactor_id, payload, step_name)
    result = FormInterruptReactor.continue(
      reactor_id: @reactor_id,
      payload: { bio: bio },
      step_name: :wait_for_user_input
    )

    if result.success?
      render plain: "Reactor finished successfully! Result: #{result.value}"
    else
      render plain: "Reactor failed or still paused. Status: #{result.status}"
    end
  end
end
