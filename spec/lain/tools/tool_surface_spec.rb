# frozen_string_literal: true

# The approval partition as data, kept out of the RSpec block for
# Lint/ConstantDefinitionInBlock -- the same shape ParallelSafetySpecSupport
# uses for the concurrency partition.
module ToolSurfaceSpecSupport
  # Tier 3: the model controls a command string handed to `sh -c`. The axis that
  # predicts danger is the model-controlled command string, not
  # read-versus-write (see Lain::Tool#requires_approval? and the plan's "Tool
  # tiers"), which is why this list is short and every addition to it is an
  # argument rather than a category.
  GATED = %w[bash core_exec].freeze

  # Everything else, derived rather than written down: a new tool is ungated by
  # DEFAULT here and must be argued into GATED, which is the safe direction to
  # be wrong in only because the completeness example below names it either way.
  UNGATED = (ToolRegistry.names - GATED).freeze
end

# The properties every shipped tool must declare, asked of the WHOLE toolset
# rather than once per tool spec.
#
# Each of these was previously hand-rolled in 19 of spec/lain/tools/*_spec.rb as
# "has a model-facing name and description" and "is not gated by approval and is
# tier 1", with the wording drifting file to file. Individually correct;
# collectively blind. Nothing asked the question of the toolset, so a tool could
# ship with no name pin and no tier decision and every spec would stay green --
# the failure `shipped_skills_spec.rb` records for `gherkin-tests`, waiting to
# happen again on the axis that decides whether a human sees the call.
#
# The roster is DERIVED from {ToolRegistry}, and {ToolRegistry.shipped_names}
# closes it against the directory, so this spec cannot fall behind the tools it
# guards.
RSpec.describe "the shipped toolset's model-facing surface" do
  describe "every tool names itself" do
    ToolRegistry.names.each do |name|
      it "#{name} answers its registry name, and a non-empty description" do
        tool = ToolRegistry.build(name)

        expect(tool.name).to eq(name)
        expect(tool.description).to be_a(String)
        expect(tool.description).not_to be_empty
      end
    end
  end

  describe "the approval partition" do
    it "gates exactly the tools that take a model-controlled command string" do
      ToolSurfaceSpecSupport::GATED.each do |name|
        expect(ToolRegistry.build(name).requires_approval?).to be(true), "expected #{name} to require approval"
      end
    end

    it "leaves every other shipped tool ungated" do
      ToolSurfaceSpecSupport::UNGATED.each do |name|
        expect(ToolRegistry.build(name).requires_approval?).to be(false), "expected #{name} NOT to require approval"
      end
    end
  end

  # The completeness check, and the reason this file exists: the registry must
  # be EXACTLY the tools on disk. A tool added to lib/lain/tools without a
  # builder fails by name here rather than going unpinned.
  it "covers every tool the toolset ships -- none missing, none invented" do
    expect(ToolRegistry.names.sort).to match_array(ToolRegistry.shipped_names)
  end
end
