# frozen_string_literal: true

# Step input contracts: the reactor wires, the step validates.
#
# ValidatedUserStep declares every rule. This reactor declares none, and has no
# `argument` lines either — each of the step's inputs resolves from the reactor
# input of the same name. A violating value fails before the step body runs,
# with `validation_errors` and `step_name: :profile`.
class ValidatedSignupReactor < RubyReactor::Reactor
  input :name
  input :email
  input :age
  input :marketing_opt_in

  step :profile, ValidatedUserStep

  returns :profile
end
