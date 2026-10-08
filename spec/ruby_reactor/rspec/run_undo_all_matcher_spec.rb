# frozen_string_literal: true

require "spec_helper"

# 010 API §7: `have_run_undo_all(:map).with_elements(n)` reads the map's
# `:undo_all` execution-trace entry.
module RunUndoAllMatcherSpec
  MapRollbackFixtures.parent(self, :Fails, MapRollbackFixtures::ElemOk, b_fails: true, undo_all: :to_a.to_proc)
  MapRollbackFixtures.parent(self, :Passes, MapRollbackFixtures::ElemOk, undo_all: :to_a.to_proc)
end

RSpec.describe "have_run_undo_all", type: :reactor do
  it "matches a map rolled back through undo_all, with its element count" do
    subject = test_reactor(RunUndoAllMatcherSpec::Fails, { items: [0, 1, 2] })

    expect(subject).to be_failure
    expect(subject).to have_run_undo_all(:m)
    expect(subject).to have_run_undo_all(:m).with_elements(3)
    expect(subject).not_to have_run_undo_all(:m).with_elements(2)
  end

  it "does not match a run that never rolled back" do
    subject = test_reactor(RunUndoAllMatcherSpec::Passes, { items: [0, 1] })

    expect(subject).to be_success
    expect(subject).not_to have_run_undo_all(:m)
  end
end
