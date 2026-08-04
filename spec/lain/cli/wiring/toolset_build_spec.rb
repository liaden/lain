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

  # The run's real switches, not a double: `/mode` and `/yolo` write these, and
  # the whole T11 claim is that a child reads them LIVE. A stub with a fixed
  # posture would pass whether or not the read is live, which is the one thing
  # worth asserting here.
  # Its own journal, not this file's `RecordingChannel`: a switch flip goes
  # through `#record`, which is the Journal duck rather than the Channel one.
  # `toolset:` is the whole shipped registry, the base `switchboard_spec.rb`
  # itself resolves postures against -- `plan` names `ask_human`, so a narrower
  # base would raise {Toolset::UnknownTool} on the flip rather than attenuate.
  let(:switchboard) do
    Lain::CLI::Switchboard.new(journal: Lain::Journal.new(io: StringIO.new), yolo: false, model: "test-model",
                               toolset: Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }))
  end

  def build_with(options, **over)
    described_class.new(backend:, provider:, chronicle:, options:, supervisor:, parent:, journal:, library:, epic:,
                        **over)
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

    # T11: the two axes the session's posture governs reach a child through the
    # ONE spawn seam, read LIVE off the run's switches.
    describe "the session posture the children inherit" do
      # A THUNK, exactly as `wiring.rb` passes one: the board requires the
      # session's base `toolset:` (T10) and that toolset is what #build
      # RETURNS, so a board cannot exist when this seam is constructed. Both
      # axes are therefore delegators that read through it at call time.
      subject(:toolset_build) { build_with(options, switchboard: -> { switchboard }) }

      def child_permits
        toolset_build.build(recorder, ask_human:)
        toolset_build.role_spawn.seam.permits
      end

      def child_gate
        toolset_build.build(recorder, ask_human:)
        toolset_build.role_spawn.seam.gate_policy
      end

      # Asserted through behaviour rather than by identity: the seam holds a
      # delegator, and what matters is that the answer comes from the board's
      # ONE policy switch -- so flipping that switch must change the answer.
      it "answers a child's gated call through the board's own policy switch" do
        gate = child_gate
        effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: {})

        switchboard.policy_switch.switch(Lain::Effect::Handler::Gate::ApproveAll.new, surface: "spec")
        expect(gate.call(effect, nil)).to be(true)

        switchboard.policy_switch.switch(Lain::Effect::Handler::Gate::DenyAll.new, surface: "spec")
        expect(gate.call(effect, nil)).to be(false)
      end

      it "permits everything under the default posture" do
        expect(child_permits.include?(:bash)).to be(true)
      end

      # The card's live-read requirement, and the reason `permits` is a
      # delegator rather than a captured value: the seam is a frozen Data built
      # ONCE, above, and the flip happens AFTER it exists. A captured
      # `Permits` would answer `true` here and hand every child a `bash` the
      # session no longer holds.
      it "stops permitting bash the moment /mode plan flips, though the seam was built before the flip" do
        permits = child_permits
        switchboard.mode_switch.switch(Lain::Mode.new(posture: :plan), surface: "spec")

        expect(permits.include?(:bash)).to be(false)
        expect(permits.include?(:read_file)).to be(true)
      end

      it "permits bash again when the posture leaves plan, since attenuation is per-spawn and not cumulative" do
        permits = child_permits
        switchboard.mode_switch.switch(Lain::Mode.new(posture: :plan), surface: "spec")
        switchboard.mode_switch.switch(Lain::Mode.new(posture: :manual), surface: "spec")

        expect(permits.include?(:bash)).to be(true)
      end

      # End to end, through the assembly the exe actually runs: a real
      # Switchboard, this build's real seam, the real role-spawn seam, a real
      # `:dev` Subagent, and the schema its child was really rendered. `:dev`
      # holds `bash` in the catalog (`role/catalog.rb:22`) and the capability
      # floor really ships one, so the tool is genuinely there to lose.
      context "when a dev child is spawned over a scripted provider" do
        let(:provider) { Lain::Provider::Mock.new(responses: [text_response("done")]) }
        # A real handle, where the outer `let` only ever has its identity
        # asserted: this context is the one that actually CALLS the thunk.
        let(:parent) { -> { Lain::Timeline.empty(store: Lain::Store.new) } }

        def spawn_dev
          toolset_build.build(recorder, ask_human:)
          toolset_build.role_spawn.call(:dev, :fresh, "go")
          provider.last_request.tools.map { |tool| tool["name"] }
        end

        it "renders bash to a dev child while the session is in accept_edits" do
          expect(spawn_dev).to include("bash")
        end

        it "renders no bash to a dev child spawned after /mode plan" do
          switchboard.mode_switch.switch(Lain::Mode.new(posture: :plan), surface: "spec")

          rendered = spawn_dev
          expect(rendered).not_to include("bash", "edit_file", "write_file")
          expect(rendered).to include("read_file", "grep")
        end

        # T10: the capability this chunk grants, end to end through the
        # assembly the exe runs. `:dev`'s `only`-set never names ask_human
        # (`role/catalog.rb:22`) and neither does the capability floor a child
        # attenuates from, so the tool can only be there because the SPAWN
        # granted it -- one asker per child, over the child's own handle.
        it "renders ask_human to a dev child, though neither the floor nor the role names it" do
          expect(Lain::CLI::Wiring::BaseTools.build(recorder).map(&:name)).not_to include("ask_human")
          expect(spawn_dev).to include("ask_human")
        end

        # The pin the escalation trigger asks for: {ChildBuilder#permitted}
        # intersects a child's set with the session posture's, so a rung that
        # stopped permitting ask_human would MUTE every child's questions,
        # silently and with this file still green. `plan` is the only rung that
        # attenuates at all, and it names ask_human deliberately
        # (`mode/posture.rb`'s READ_ONLY, with the reasoning beside it) -- this
        # is what fails if that decision is ever quietly reversed.
        it "keeps rendering ask_human to a dev child after /mode plan, because every rung permits it" do
          switchboard.mode_switch.switch(Lain::Mode.new(posture: :plan), surface: "spec")

          expect(spawn_dev).to include("ask_human")
        end
      end
    end

    # T10: who a child asks the human THROUGH. The run has ONE
    # {Wiring::Askers} -- one queue the human drains, one directory an answer
    # is routed back through -- and it reaches a child on the spawn seam, for
    # `provider:`'s exact reason: a second one built down there would be a
    # second answer to "who is holding this question".
    describe "the ask-the-human seam a child inherits" do
      let(:notified) { [] }
      let(:notifier) { instance_double(Lain::Notify) }
      let(:askers) do
        Lain::CLI::Wiring::Askers.new(notifier:, observer: Lain::Event::ChainWriter::Null.new)
      end

      before { allow(notifier).to receive(:question) { |agent:, text:| notified << [agent, text] } }

      it "hands the spawn seam the run's own askers, never a second one" do
        build = build_with(options, askers:)
        build.build(recorder, ask_human:)

        expect(build.role_spawn.seam.askers).to be(askers)
        expect(build.role_spawn.seam.askers).to be(build.build(recorder, ask_human:).fetch("subagent").seam.askers)
      end

      # Defaulted for `switchboard:`'s exact reason and with the same warning:
      # the direct-construction seam the specs drive, where a child's question
      # would reach no queue and no desktop. The exe always passes the run's.
      it "falls back to the seam wired to nothing when a build is handed none" do
        toolset_build.build(recorder, ask_human:)

        expect(toolset_build.role_spawn.seam.askers).to be_a(Lain::CLI::Wiring::Askers)
      end

      # The one child path that ships today, driven end to end: the chat's own
      # `subagent` really asking a question, over the run's real Askers. Its
      # TOOL is named "subagent" because that is what the model calls; what it
      # IS is a researcher, and that is what the arrival note and the desktop
      # must say. Naming the tool would have changed the rendered schema bytes,
      # so the two names are separate keywords -- and this is what says they
      # are wired to the right ends.
      context "when the chat's own subagent asks the human" do
        let(:store) { Lain::Store.new }
        let(:parent) { -> { Lain::Timeline.empty(store:) } }
        let(:provider) do
          Lain::Provider::Mock.new(responses: [tool_response(["c1", "ask_human", { "question" => "which db?" }]),
                                               text_response("done")])
        end

        def dispatch(subagent)
          subagent.call({ "prompt" => "go" }, Lain::Tool::Invocation.new(context: Lain::Session::Null.instance))
        end

        def arrival(task, timeout: 3)
          pumped_until(task, timeout:, reason: "a question reaching the human's queue") do
            !askers.questions.empty?
          end
          askers.questions.dequeue
        end

        # The `ensure` is what lets this example FAIL rather than wedge: an
        # unannounced child never returns from its dispatch, and a raise out
        # of a Sync with a task parked on `Promise#await` never comes back --
        # a hang the runner reports as a pass.
        def spawned_asking(subagent)
          Sync do |task|
            run = task.async { dispatch(subagent) }
            begin
              askers.directory.reply("postgres", arrival(task).digest)
              run.wait
            ensure
              run.stop
            end
          end
        end

        it "tells the human the ROLE is asking, not the model-facing tool name" do
          build = build_with(options, askers:)

          spawned_asking(build.build(recorder, ask_human:).fetch("subagent"))

          expect(notified).to eq([["researcher", "which db?"]])
        end
      end
    end

    # A build handed no board at all -- the direct-construction seam the rest
    # of this file drives. It must behave exactly as every spawn did before
    # children were gated, or this card's default would be a live behaviour
    # change nobody asked for.
    it "leaves a boardless build's children ungated and unattenuated" do
      toolset_build.build(recorder, ask_human:)
      seam = toolset_build.role_spawn.seam
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: {})

      expect(seam.gate_policy.call(effect, nil)).to be(true)
      expect(seam.permits.include?(:bash)).to be(true)
    end

    # The live thunk reads nil until {Wiring#build_agent} has run. That must
    # raise rather than fall back to {NoSwitchboard}: a fallback would silently
    # ungate a real session if the assembly order ever changed, which is the
    # one failure this card exists to remove.
    #
    # BOTH axes, because they fail differently and the gate is the sharper one:
    # a `|| NoSwitchboard` on `permits` alone hands a child the capabilities the
    # session no longer holds, but the same fallback on `gate_policy` resolves
    # to {NoSwitchboard#policy_switch} -- which is `UNGATED`, an `ApproveAll` --
    # and silently ungates every child in the run. Pinning only one axis leaves
    # the worse regression free to land green.
    it "refuses loudly, rather than ungating, if a spawn beats the board into existence" do
      build = build_with(options, switchboard: -> {})
      build.build(recorder, ask_human:)
      seam = build.role_spawn.seam

      expect { seam.permits.include?(:bash) }.to raise_error(NoMethodError, /mode_switch/)
      expect { seam.gate_policy.call(nil, nil) }.to raise_error(NoMethodError, /policy_switch/)
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
