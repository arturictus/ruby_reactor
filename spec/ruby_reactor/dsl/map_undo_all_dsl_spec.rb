# frozen_string_literal: true

require "spec_helper"

# 010 R-12 / FR-027: `undo_all` on a map is optional, takes a block, and is
# declared at most once.
RSpec.describe "map undo_all declaration (010 US7)" do
  def map_config(&map_body)
    klass = Class.new(RubyReactor::Reactor) do
      input :items
      map(:m, MapRollbackFixtures::ElemOk) do
        source input(:items)
        argument :i, element(:m)
        instance_eval(&map_body)
      end
    end
    klass.steps[:m]
  end

  it "keeps the block on the map's declaration" do
    config = map_config { undo_all(&:to_a) }

    expect(config.arguments[:undo_all_block][:source].value).to be_a(Proc)
  end

  it "adds nothing when not declared" do
    expect(map_config { nil }.arguments).not_to have_key(:undo_all_block)
  end

  it "rejects a second declaration" do
    expect do
      map_config do
        undo_all { :first }
        undo_all { :second }
      end
    end
      .to raise_error(RubyReactor::Error::ValidationError, /map :m declares undo_all twice/)
  end

  it "rejects undo_all without a block" do
    expect { map_config { undo_all } }
      .to raise_error(RubyReactor::Error::ValidationError, /map :m undo_all needs a block/)
  end
end
