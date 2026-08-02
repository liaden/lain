# frozen_string_literal: true

# {Lain::CLI::Chronicle::Null#observer} answers a FRESH Null chain writer on
# every call, which cannot tell a forwarded observer from a discarded one -- the
# assertion would pass against `observer: Event::ChainWriter::Null.new`. This one
# holds ONE, so the spawn seam's observer member is an identity claim.
class ToolsetBuildChronicle < Lain::CLI::Chronicle::Null
  def observer = @observer ||= ->(event) { event }
end

# The capability half of the chat assembly, extracted from {Lain::CLI::Wiring}
# (T1 review, Fix 4) once that class hit its ClassLength budget with two more
# cards queued against it. Driven here as the standalone object the extraction
# claims it is: a real Backend, a real recorder, no Wiring anywhere.
RSpec.describe Lain::CLI::Wiring::ToolsetBuild do
  subject(:toolset_build) { build_with(options) }

  let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }) }
  let(:chronicle) { ToolsetBuildChronicle.new }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:journal) { RecordingChannel.new }
  let(:supervisor) { Lain::Supervisor.new(journal:) }
  let(:ask_human) { Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.new }) }
  let(:options) { {} }

  # The run's own spooled provider and live parent handle, held as lets so the
  # spawn seam's members can be asserted by identity rather than by type.
  let(:provider) { backend.provider(spool: chronicle.spool) }
  let(:parent) { -> { Lain::Timeline.new } }

  # The session's ONE library, injected -- what T40 replaced the `catalog:`
  # keyword and the `backend.slots` reach-through with. The live path hands in
  # the Backend's, which is where the run's single load lives.
  let(:library) { backend.library }

  # A chat outside an epic, which is the overwhelmingly common one: its whole
  # surface is `tools == []`, so nothing below has to know an epic tier exists.
  # The example that DOES care wires a real {Lain::CLI::EpicMount}.
  let(:epic) { Lain::CLI::EpicMount::NoEpic }

  def build_with(options)
    described_class.new(backend:, provider:, chronicle:, options:, supervisor:, parent:, journal:, library:, epic:)
  end

  describe "#build" do
    it "layers the capability floor, the child seam, and the two main-agent-only tools" do
      names = toolset_build.build(recorder, ask_human:).names

      expect(names).to include(*Lain::CLI::Wiring::BaseTools.build(recorder).map(&:name))
      expect(names).to include("subagent", "ask_human", "run_skill")
    end

    # The layering IS the policy: a child attenuates from the floor, so it must
    # not inherit the seam that asks the human a question, nor the one that
    # renders a skill back into a conversation that is not the child's.
    #
    # Read through {Lain::Tools::Subagent#attenuates_from} (T23), not through the
    # two-deep `@builder` / `@toolset` reach-through this used to use: that pinned
    # the {ChildBuilder} extraction's private shape, so the extraction could not
    # be reshaped without touching a spec about capability layering.
    # `not_to include` ALONE is vacuous -- it passes for an empty Toolset, so it
    # cannot tell "attenuated from the floor" from "attenuated to nothing". The
    # exact match is what makes the negative mean something.
    it "attenuates the child from the floor, never from the main agent's own set" do
      full = toolset_build.build(recorder, ask_human:)
      floor = Lain::CLI::Wiring::BaseTools.build(recorder).map(&:name)

      inherited = full.fetch("subagent").attenuates_from.names

      expect(inherited).to match_array(floor)
      expect(inherited).not_to include("ask_human", "run_skill", "subagent")
    end

    # T27: a chat outside an epic offers no review tool at all, and the way it
    # says so is an empty collection rather than a nil this build has to test
    # for. `include` on its own would be vacuous here, so the floor is pinned
    # too: the set must be the ordinary one, minus nothing.
    it "adds no review tool when the chat is in no epic" do
      names = toolset_build.build(recorder, ask_human:).names

      expect(names).not_to include("request_review")
      expect(names).to include("subagent", "ask_human", "run_skill")
    end

    context "when the chat resolved an epic" do
      # A Toolset digests its members' schemas at construction, so a member
      # reaching Toolset.new from lib/ must answer #to_schema. Stubbing it on a
      # VERIFYING double is honest rather than conventional: Lain::Tool really
      # declares #to_schema (tool.rb:150), so rspec checks the stub against the
      # real method.
      let(:review_tool) do
        instance_double(Lain::Tool, name: "request_review",
                                    to_schema: { "name" => "request_review", "description" => "review",
                                                 "input_schema" => { "type" => "object" } })
      end
      let(:epic) { instance_double(Lain::CLI::EpicMount, tools: [review_tool]) }

      # Whatever the mount hands over is appended AFTER the floor, which is what
      # makes it main-agent-only: a child attenuates from the floor, so it can
      # never inherit a tool that parks holding an artifact's baton in a
      # conversation nobody is watching.
      it "appends the epic's tools where a child cannot inherit them" do
        full = toolset_build.build(recorder, ask_human:)
        floor = Lain::CLI::Wiring::BaseTools.build(recorder).map(&:name)

        expect(full.fetch("request_review")).to be(review_tool)
        expect(full.fetch("subagent").attenuates_from.names).to match_array(floor)
      end
    end

    # T23: the six collaborators BOTH child seams attenuate over are one value,
    # built once. The identity is what makes "adding a seam member is a one-place
    # change" checkable -- two seams cannot drift when there is only one object.
    it "hands the subagent tool and the role_spawn seam the very same spawn seam" do
      full = toolset_build.build(recorder, ask_human:)

      expect(full.fetch("subagent").seam).to be(toolset_build.role_spawn.seam)
    end

    it "fills that seam from the run's provider, parent handle, journal, supervisor and chronicle observer" do
      toolset_build.build(recorder, ask_human:)
      seam = toolset_build.role_spawn.seam

      expect(seam.provider).to be(provider)
      expect(seam.parent).to be(parent)
      expect(seam.journal).to be(journal)
      expect(seam.supervisor).to be(supervisor)
      expect(seam.observer).to be(chronicle.observer)
      # Backend#context deliberately answers a FRESH value per call (its own
      # comment says so) and Context has no deep `==`, so the factory is checked
      # by what it renders. The system comes from the LIBRARY's slots, not from
      # `backend.context.system` -- reading the expected value off the subject
      # under test would pass however the factory renders.
      child_context = seam.context_factory.call
      expect([child_context.model, child_context.max_tokens, child_context.system])
        .to eq(["qwen3:4b", 64, library.slots.render])
    end

    # T15: run_skill's renderer used to call ReplMiddleware.renderer with NO
    # arguments, which loaded a catalog AND a slots of its own off `Dir.pwd`.
    # The comment above it claimed "loaded once from the project root"; it was
    # the third Slots of the session. T40 made the pair ONE injected library, so
    # this object no longer reaches through the Backend for the other half.
    it "renders run_skill through the injected library's catalog and slots" do
      toolset = toolset_build.build(recorder, ask_human:)
      renderer = toolset.fetch("run_skill").instance_variable_get(:@renderer)

      expect(renderer.instance_variable_get(:@catalog)).to be(library.catalog)
      expect(renderer.instance_variable_get(:@slots)).to be(library.slots)
    end

    it "frames the role_spawn seam against that same library's slots" do
      toolset_build.build(recorder, ask_human:)

      expect(toolset_build.role_spawn.instance_variable_get(:@slots)).to be(library.slots)
    end

    # The pair arrives as one keyword and it is required: a forgotten library
    # must be a loud ArgumentError, not a quiet second read of the tree.
    it "refuses to construct without the library" do
      expect do
        described_class.new(backend:, provider: backend.provider(spool: chronicle.spool), chronicle:, options:,
                            supervisor:, parent: -> { Lain::Timeline.new }, journal:, epic:)
      end.to raise_error(ArgumentError, /library/)
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
