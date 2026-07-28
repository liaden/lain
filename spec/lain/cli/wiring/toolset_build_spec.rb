# frozen_string_literal: true

# The capability half of the chat assembly, extracted from {Lain::CLI::Wiring}
# (T1 review, Fix 4) once that class hit its ClassLength budget with two more
# cards queued against it. Driven here as the standalone object the extraction
# claims it is: a real Backend, a real recorder, no Wiring anywhere.
RSpec.describe Lain::CLI::Wiring::ToolsetBuild do
  let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }) }
  let(:chronicle) { Lain::CLI::Chronicle::Null.new }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:journal) { RecordingChannel.new }
  let(:supervisor) { Lain::Supervisor.new(journal:) }
  let(:ask_human) { Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.new }) }
  let(:options) { {} }

  def build_with(options)
    described_class.new(backend:, provider: backend.provider(spool: chronicle.spool), chronicle:, options:,
                        supervisor:, parent: -> { Lain::Timeline.new }, journal:)
  end

  subject(:toolset_build) { build_with(options) }

  describe "#build" do
    it "layers the capability floor, the child seam, and the two main-agent-only tools" do
      names = toolset_build.build(recorder, ask_human:).names

      expect(names).to include(*Lain::CLI::Wiring::BaseTools.build(recorder).map(&:name))
      expect(names).to include("subagent", "ask_human", "run_skill")
    end

    # The layering IS the policy: a child attenuates from the floor, so it must
    # not inherit the seam that asks the human a question, nor the one that
    # renders a skill back into a conversation that is not the child's.
    it "attenuates the child from the floor, never from the main agent's own set" do
      full = toolset_build.build(recorder, ask_human:)
      builder = full.fetch("subagent").instance_variable_get(:@builder)
      inherited = builder.instance_variable_get(:@toolset).names

      expect(inherited).not_to include("ask_human", "run_skill", "subagent")
    end
  end

  describe "what the build discovers" do
    it "has no role_spawn seam until the toolset has been built" do
      expect(toolset_build.role_spawn).to be_nil

      toolset_build.build(recorder, ask_human:)

      expect(toolset_build.role_spawn).to be_a(Lain::Skill::RoleSpawn)
    end

    it "wires no auto surface without --auto-approve" do
      toolset_build.build(recorder, ask_human:)

      expect(toolset_build.auto_surface).to be_nil
    end

    # T12's invariant, now assertable directly: the third approval surface
    # folds through the SAME seam a `@role/skill` line does.
    it "wires an AutoSurface over its own role_spawn seam under --auto-approve" do
      build = build_with({ auto_approve: true })
      build.build(recorder, ask_human:)

      expect(build.auto_surface).to be_a(Lain::Approval::AutoSurface)
      expect(build.auto_surface.instance_variable_get(:@role_spawn)).to be(build.role_spawn)
    end
  end
end
