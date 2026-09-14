# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::Switchboard do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  # A REAL Toolset, for the reason resolution_spec and posture_spec both record:
  # a verifying double's `#only` accepts any argument list at all, so a posture
  # naming a tool no live set holds would satisfy every example here and raise
  # at the first `/mode plan` of a real session instead.
  let(:base) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

  def switchboard(toolset: base, **rest)
    described_class.new(journal:, model: "claude-opus-4-8", toolset:, **rest)
  end

  def mode(posture) = Lain::Mode.new(posture:)

  def layout_run = Lain::Middleware::GuardTestLayout::Run.undeclared

  def gated_call = Struct.new(:name, :input, :tool_use_id).new("bash", { "command" => "ls" }, "tu_1")

  def mode_records = Lain::Journal.records(journal_io.string.lines, type: "mode_switch").to_a

  def policy_records = Lain::Journal.records(journal_io.string.lines, type: "policy_switch").to_a

  # The wiring entry a real chat reaches (`exe/lain#chat` -> {CLI::Wiring#switchboard}
  # -> {BoardBuild.for}). Driven here rather than only through `new` because the
  # question these two examples answer is about the OPTIONS HASH -- which flags
  # this entry reads and what a default one resolves to -- and `new` never sees
  # a hash at all.
  describe ".for, the wiring entry" do
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }

    def board_for(**options)
      described_class.for(chronicle:, options:, model: "claude-opus-4-8", toolset: base, test_layout: layout_run)
    end

    # The session's ONE layout run, which the parent's tool guard and every
    # child's read off the board. `.for` requires it: a chat with no layout
    # decision behind it is a mis-wire, not a default.
    describe "the test layout it carries" do
      it "holds the run it was handed, by identity" do
        run = layout_run
        board = described_class.for(chronicle:, options: {}, model: "claude-opus-4-8", toolset: base,
                                    test_layout: run)

        expect(board.test_layout).to be(run)
      end

      it "refuses a wiring entry that names no test layout" do
        expect { described_class.for(chronicle:, options: {}, model: "claude-opus-4-8", toolset: base) }
          .to raise_error(ArgumentError, /test_layout/)
      end

      # The tool guard is built over ONE value, and it holds the board's own
      # slots rather than copies of them.
      it "holds the guard's inputs as one value, over the board's own slots" do
        run = layout_run
        board = described_class.for(chronicle:, options: {}, model: "claude-opus-4-8", toolset: base,
                                    test_layout: run)
        inputs = board.guard_inputs

        expect(inputs).to be_a(Lain::CLI::ToolGuard::Inputs)
        expect([inputs.ledger, inputs.approvals, inputs.sensitivity, inputs.test_layout])
          .to eq([board.ledger, board.approvals, board.sensitivity, run])
        expect(inputs.approvals).to be(board.approvals)
        expect(inputs.ledger).to be(board.ledger)
      end

      it "gives a directly built board a run of its own that declares no layout" do
        expect(switchboard.test_layout.layout).to be(Lain::TestLayout::None)
        expect(switchboard.test_layout).not_to be(switchboard.test_layout)
      end
    end

    # `.for` is the only construction a real chat reaches, so a classifier this
    # entry dropped would be a rung disarmed everywhere while `new` stayed green.
    it "carries the classifier factory through to the ladder's triage rung" do
      factory = ->(_cwd) { Lain::Approval::Escalation::Triage::AnyPath.new }
      board = described_class.for(chronicle:, options: {}, model: "claude-opus-4-8", toolset: base,
                                  classifiers: factory, test_layout: layout_run)

      expect(board.ladder.first.instance_variable_get(:@sensitivity)).to be(factory)
    end

    # There is no longer a flag that skips either half: a chat gets the parked
    # list and the asking posture, and `/mode auto` is the only way out of them.
    it "wires the approval queue and starts on accept_edits, with no flag to skip either" do
      board = board_for

      expect(board.approvals).to be_a(Lain::Approval::Queue)
      expect(board.mode_switch.posture.name).to eq(:accept_edits)
    end

    # `--non-interactive` is the only flag this entry reads, and it answers
    # "who decides a gated call" with "nobody can".
    it "wires no queue for an unattended session, and a gate that denies" do
      board = board_for(non_interactive: true)

      expect(board.approvals).to be_nil
      expect(board.policy_switch.call(gated_call, nil)).to be(false)
    end
  end

  describe "the approval side" do
    # The queue is still the parked list, but what the gate holds is the
    # LADDER over it -- the deterministic rungs answer first, and the queue is
    # where a call lands when they abstain.
    it "wires the queue as the parked list and the ladder over it as the gate's starting policy" do
      board = switchboard

      expect(board.approvals).to be_a(Lain::Approval::Queue)
      expect(board.ladder).to be_a(Lain::Approval::Escalation)
      expect(board.policy_switch.current).to be(board.ladder)
    end

    it "wires the deterministic rungs below the surfaces, journaling to the session journal" do
      board = switchboard

      expect(board.ladder.map(&:name)).to eq(%w[triage rules surfaces])

      Sync do |task|
        parked = task.async { board.policy_switch.call(gated_call, nil) }
        task.with_timeout(1) { board.approvals.dequeue }

        expect(Lain::Journal.records(journal_io.string.lines, type: "escalation")
                            .map { |record| record["rung"] }.to_a).to eq(%w[triage rules])
      ensure
        parked&.stop
      end
    end

    # The rules rung was wired EMPTY, because the remembered answers need a
    # project root this board does not hold. It takes them as `rules:` now, and
    # what decides whether a root's `[approval]` table may fill that list is
    # {Lain::Project::Consent} -- not this class, which only carries them.
    it "hands the ladder's rules rung whatever the session consented to" do
      allower = Class.new(Lain::Approval::Rule) do
        def name = "spec_allow"
        def decide(call) = allow(call, because: "the session remembered this")
      end.new

      board = switchboard(rules: [allower])

      expect(board.policy_switch.call(gated_call, nil)).to be(true)
      expect(Lain::Journal.records(journal_io.string.lines, type: "escalation")
                          .select { |record| record["rung"] == "rules" }
                          .map { |record| record["verdict"] }.to_a).to eq(%w[allow])
    end

    # The third vocabulary on this board, and the one that had no wiring at all
    # until this board grew it: `sensitivity:` is the run's PATH BOUNDARY (a
    # policy, asked `gates?`), and `classifiers:` is a FACTORY the triage rung
    # calls per gated command to anchor the argv it reads on the cwd THAT call
    # named.
    describe "the triage rung's classifier factory" do
      def factory_of(board) = board.ladder.first.instance_variable_get(:@sensitivity)

      it "hands the rung whatever the session was built with" do
        factory = ->(_cwd) { Lain::Approval::Escalation::Triage::AnyPath.new }

        expect(factory_of(switchboard(classifiers: factory))).to be(factory)
      end

      # The default is the inert one, deliberately: a board built with no
      # project has no home to anchor a {Lain::Sensitivity} on. What must NOT
      # happen is a live session silently keeping it -- which is what
      # board_build_spec's identity example pins.
      it "defaults to the inert AnyPath, which protects nothing" do
        expect(factory_of(switchboard)).to be_a(Lain::Approval::Escalation::Triage::AnyPath)
      end
    end

    # The FOURTH thing that rung reads, and the only one the board shares with
    # something outside itself: the session's {Lain::Shell::Verdict} is also
    # what {Lain::Tools::Bash} chooses its arm with, so this board must carry
    # the instance it was handed rather than construct its own. Two default
    # constructions cannot disagree -- the object is frozen and pure -- but a
    # board holding its own would leave the project's exclusion table off the
    # ladder while the tool still honoured it.
    describe "the triage rung's shell verdict" do
      def verdict_of(board) = board.ladder.first.instance_variable_get(:@verdict)

      let(:excluding_curl) do
        Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: ["curl"]))
      end
      let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }

      it "hands the rung whatever the session was built with" do
        expect(verdict_of(switchboard(verdict: excluding_curl))).to be(excluding_curl)
      end

      # `.for` is the only construction a real chat reaches, so a verdict this
      # entry dropped would be the exclusion table disarmed everywhere while
      # `new` stayed green.
      it "carries it through the wiring entry to the ladder" do
        board = described_class.for(chronicle:, options: {}, model: "claude-opus-4-8", toolset: base,
                                    verdict: excluding_curl, test_layout: layout_run)

        expect(verdict_of(board)).to be(excluding_curl)
      end

      # The default restricts nothing, which is what a board built with no
      # project has to mean.
      it "defaults to a verdict that restricts no program" do
        expect(verdict_of(switchboard).call("curl http://example.com")).to be_allow
      end

      # The THIRD posture, and it is a fact about the wiring rather than a
      # defect: a session with nobody to ask gets a one-rung ladder that
      # refuses everything, so the exclusion table is never consulted there.
      # The tool still holds the same verdict and still chooses its arm.
      it "is not consulted at all by an unattended session's one-rung ladder" do
        board = switchboard(attended: false, verdict: excluding_curl)

        expect(board.ladder.map(&:name)).to eq(%w[unattended])
      end
    end

    # The default is what every caller gets until one passes a consented
    # project's answers, and it has to be the behaviour from before that rung existed, exactly: an
    # empty rung abstains, and the call goes on parking on the queue.
    it "wires no rules by default, so the rung abstains and the call still parks" do
      board = switchboard

      Sync do |task|
        parked = task.async { board.policy_switch.call(gated_call, nil) }
        task.with_timeout(1) { board.approvals.dequeue }

        expect(Lain::Journal.records(journal_io.string.lines, type: "escalation")
                            .select { |record| record["rung"] == "rules" }
                            .map { |record| record["verdict"] }.to_a).to eq(%w[abstain])
      ensure
        parked&.stop
      end
    end
  end

  # The card that built the ledger owns this: the masking arm reads it and the
  # prompt arm writes it, through different files in different waves, so two
  # half-wirings would give the run two ledgers and a release control that
  # silently releases nothing. One board, one ledger, and it is exposed for that
  # reason alone.
  #
  # `switchboard` here is the HELPER METHOD at the top of this file, not a `let`,
  # so every call builds a fresh board. That is what makes "the SAME one every
  # time" and "not shared between two boards" agree rather than contradict --
  # the first pins one board, the second pins two. Memoize the helper into a
  # `let` and the second example goes red for a reason that is not about the
  # subject.
  describe "the region ledger" do
    it "holds one" do
      expect(switchboard.ledger).to be_a(Lain::Sensitivity::Ledger)
    end

    it "answers the SAME one every time, so a late reader cannot get a second" do
      board = switchboard

      expect(board.ledger).to be(board.ledger)
    end

    # The posture decides who is asked, not whether the run has somewhere to
    # record an answer -- and an unattended session wires no queue, so this is
    # the arm most likely to be skipped by accident.
    it "holds one for an unattended session too, where there is no queue" do
      expect(switchboard(attended: false).ledger).to be_a(Lain::Sensitivity::Ledger)
    end

    it "does not share one between two boards, which is what a run-scoped ledger means" do
      expect(switchboard.ledger).not_to be(switchboard.ledger)
    end
  end

  describe "the model side" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    it "grafts the live model slot onto a context, read at render time" do
      board = switchboard
      grafted = board.graft(Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64))

      board.model_switch.switch("claude-haiku-4-5", surface: "tty")

      expect(grafted.render(timeline:, toolset: Lain::Toolset.new).model).to eq("claude-haiku-4-5")
    end
  end

  # An earlier card established WHERE the live mode lives; these are the examples that
  # say a flip DOES something -- it re-binds the gate policy the construction-
  # fixed Gate reads and the capability set the construction-fixed Agent renders.
  describe "the mode side, bound to the live gate and the live toolset" do
    let(:store) { Lain::Store.new }
    let(:timeline) do
      Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 64) }

    def rendered_tools(board) = context.render(timeline:, toolset: board.toolset).tools.map { |tool| tool["name"] }

    # `--non-interactive`, and the choice the card that added it had to make in
    # the open. A gated call asks a human; a headless run has none, so the
    # honest answer is no.
    # DenyAll is what Middleware::Gate already calls "correct when no
    # interactive frontend is attached", and the alternative -- a queue nobody
    # drains -- parks the call until a fail-closed timeout denies it anyway,
    # after a wait no one is there to end.
    describe "--non-interactive, where the gate has nobody to ask" do
      it "denies a tier-3 call instead of parking it" do
        board = switchboard(attended: false)

        expect(board.policy_switch.call(gated_call, nil)).to be(false)
      end

      it "wires no approval queue, because nothing could drain one" do
        expect(switchboard(attended: false).approvals).to be_nil
      end

      # The queue is nil here; the LADDER is not, and it is a LADDER -- one rung
      # that refuses -- rather than a bare {Gate::DenyAll} substituted beside
      # it. Two things follow. `#ladder` answers the same kind of thing on both
      # arms, so "this session has no ladder" is unrepresentable rather than
      # merely handled, and {Lain::Mode::Resolution}'s nil guard stays the loud
      # backstop it was written to be instead of being masked by a `||` on the
      # only production path. The second is the record, below.
      it "stands a one-rung refusing ladder where the asking one would be, rather than answering nil" do
        board = switchboard(attended: false)

        expect(board.ladder).to be_a(Lain::Approval::Escalation)
        expect(board.ladder.map(&:name)).to eq(%w[unattended])
        expect(board.ladder.call(gated_call, nil)).to be(false)
      end

      # {Gate::DenyAll} holds no journal at all, so an unattended run's refusals
      # left NO escalation record and the bench could not compare an unattended
      # arm's denials against an attended one's. A ladder journals every rung it
      # consults, which is what makes the two arms comparable.
      it "journals its refusal, so an unattended arm's denials are on the record too" do
        board = switchboard(attended: false)

        board.policy_switch.call(gated_call, nil)

        expect(Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a)
          .to include(a_hash_including("rung" => "unattended", "verdict" => "deny", "faulted" => false))
      end

      # The capability set is untouched: this flag answers "who approves", not
      # "what may be called". A headless run that quietly lost `edit_file`
      # would be a third policy nobody chose.
      it "leaves the session holding every tool it was built with" do
        board = switchboard(attended: false)

        expect(board.mode_switch.posture.name).to eq(:accept_edits)
        expect(board.toolset.names).to match_array(base.names)
      end

      it "journals no flip for the mode it was constructed in" do
        switchboard(attended: false)

        expect(mode_records).to be_empty
        expect(policy_records).to be_empty
      end

      # The other half of the same policy, and the half that reaches the model.
      # A denial that reads byte-for-byte like a human answering "no" is a
      # decision that could have gone the other way, so a model retries it --
      # for the whole run, against a gate nobody can open. The refusal has to
      # say that nobody was asked and nobody can be.
      describe "what the model is told when the gate refuses" do
        # The REAL layers a session dispatches through, over the real runner
        # and a real Live, because the sentence under test is produced by the
        # gate and read by the model off a tool_result, and a double anywhere
        # in that path would be asserting on the double.
        def refusal(board)
          dispatch_call("bash", { "command" => "ls" }, toolset: board.toolset, layers: board.gate,
                                                       context: Lain::Session.new).content
        end

        it "says no approval is possible, rather than that approval was denied" do
          told = refusal(switchboard(attended: false))

          expect(told).to include("no approval is possible", "--non-interactive")
          expect(told).not_to include("approval denied")
        end

        it "says retrying cannot help, and what to do instead" do
          told = refusal(switchboard(attended: false))

          expect(told).to include("retrying will fail the same way")
          expect(told).to include("without this tool")
        end

        it "leaves an attended session's denial exactly as it was" do
          expect(refusal(switchboard)).to include("approval denied for tool \"bash\"")
        end
      end
    end

    describe "a posture flip at runtime" do
      it "approves a tier-3 call without parking it once the posture switches to auto" do
        board = switchboard
        board.mode_switch.switch(mode(:manual), surface: "tty")

        Sync do |task|
          parked = task.async { board.policy_switch.call(gated_call, nil) }
          task.with_timeout(1) { board.approvals.dequeue }
          expect(board.approvals.each.count).to eq(1)

          board.mode_switch.switch(mode(:auto), surface: "tty")

          # Bounded, and not as belt-and-braces: a break that leaves the policy
          # switch untouched parks this call on the queue FOREVER, and an
          # unbounded example then hangs the whole suite instead of failing --
          # which is how a mutation run lost a five-minute batch to it.
          expect(task.with_timeout(1) { board.policy_switch.call(gated_call, nil) }).to be(true)
          expect(board.approvals.each.count).to eq(1)
        ensure
          parked&.stop
        end
      end

      it "restores the queue when the posture switches back to an asking rung" do
        board = switchboard

        board.mode_switch.switch(mode(:auto), surface: "tty")
        # The board STARTS on the ladder, so asserting only the destination is
        # vacuous -- "never moved" and "moved back" are the same reading. This
        # is the leg that tells them apart.
        expect(board.policy_switch.current).not_to be(board.ladder)

        board.mode_switch.switch(mode(:manual), surface: "tty")

        expect(board.policy_switch.current).to be(board.ladder)
      end

      # The gate flip rides the SAME journal the mode flip does, so a transcript
      # shows one policy history rather than two half-histories to be joined by
      # hand.
      it "journals the gate flip through the one policy switch, attributed to the surface" do
        board = switchboard

        board.mode_switch.switch(mode(:auto), surface: "editor")

        expect(policy_records.last).to include("to" => "approve_all", "surface" => "editor")
      end
    end

    describe "plan, which takes the capability away rather than gating it" do
      it "drops edit_file from a subsequent render" do
        board = switchboard
        board.mode_switch.switch(mode(:manual), surface: "tty")
        expect(rendered_tools(board)).to include("edit_file")

        board.mode_switch.switch(mode(:plan), surface: "tty")

        expect(rendered_tools(board)).not_to include("edit_file")
      end

      # The whole reason this card did not have to rebuild the Agent: the
      # capability set is a SLOT the Agent and its executor already hold, so the
      # object identity wiring_spec pins across a session survives the flip.
      it "re-binds the slot in place, so the Agent still holds the object it was built with" do
        board = switchboard
        live = board.toolset

        board.mode_switch.switch(mode(:plan), surface: "tty")

        expect(board.toolset).to equal(live)
        expect(live.names).not_to include("edit_file", "write_file", "bash")
        expect(live.fetch("read_file")).to be_a(Lain::Tools::ReadFile)
      end

      # The slot is the possession, and possession IS authorization here -- so
      # the reader the Agent hands around must not offer a way to disarm a live
      # session with no journal line and no mode change behind it. The board is
      # the only writer.
      it "hands out a read-only face: no writer, and frozen" do
        live = switchboard.toolset

        expect(live).to be_frozen
        expect(live).not_to respond_to(:bind)
        expect(live).not_to respond_to(:only)
      end

      # A slot is not a value. Said out loud because Toolset#== exists and the
      # asymmetry would otherwise read as an oversight.
      it "is not == to the set it holds, in either direction" do
        live = switchboard.toolset

        expect(live == live.current).to be(false)
        expect(live.current == live).to be(false)
      end

      it "restores the full set on the way back out, because it re-resolves from the base" do
        board = switchboard
        board.mode_switch.switch(mode(:plan), surface: "tty")

        board.mode_switch.switch(mode(:manual), surface: "tty")

        expect(board.toolset.names).to eq(base.names)
      end
    end
  end

  # The snapshot slot is born in the agent build and bound here, because the
  # board is the one object a `/mode` flip goes through.
  # The two layers every tool call of a session passes before it is
  # interpreted, driven through the real runner. The interpreter is a Mock that
  # records, so "it did not run" is an observation rather than an inference
  # from a refusal's wording -- and `bash` never really runs.
  describe "#gate, the layers a session's tool calls pass" do
    def recording(ran)
      Lain::Effect::Handler::Mock.new do |effect, _context|
        ran << effect.name
        Lain::Tool::Result.ok("the interpreter ran")
      end
    end

    it "refuses an effect its policy denies before the interpreter runs" do
      ran = []
      board = switchboard(attended: false)

      result = dispatch_call("bash", { "command" => "ls" }, toolset: board.toolset, layers: board.gate,
                                                            handler: recording(ran))

      expect(result).to have_attributes(is_error: true, content: /no approval is possible for tool "bash"/)
      expect(ran).to be_empty
    end

    it "hands an effect its policy allows to the interpreter, whose result comes back" do
      ran = []
      board = switchboard
      board.mode_switch.switch(mode(:auto), surface: "tty")

      result = dispatch_call("bash", { "command" => "ls" }, toolset: board.toolset, layers: board.gate,
                                                            handler: recording(ran))

      expect(result).to eq(Lain::Tool::Result.ok("the interpreter ran"))
      expect(ran).to eq(%w[bash])
    end

    # Approval can take as long as a human takes, and a `/mode` flip in that
    # window may withdraw the very capability being asked about. Plan's promise
    # is that a mutating tool cannot be run, so the call that comes back from
    # the queue approved must still find the tool it was judged as -- driven
    # through the real board, whose flip re-binds the live toolset the runner
    # resolves against.
    describe "a flip while the call waits on a human" do
      def parked_then(board, flip)
        ran = []
        board.mode_switch.switch(mode(:manual), surface: "tty")
        result = Sync do |task|
          call = task.async do
            dispatch_call("bash", { "command" => "rm -rf build" }, toolset: board.toolset, layers: board.gate,
                                                                   handler: recording(ran))
          end
          pending = task.with_timeout(1) { board.approvals.dequeue }
          board.mode_switch.switch(mode(flip), surface: "tty")
          pending.approve(surface: "spec")
          task.with_timeout(1) { call.wait }
        end
        [result, ran]
      end

      it "refuses a call whose tool the flip withdrew, and the interpreter never runs" do
        result, ran = parked_then(switchboard, :plan)

        expect(result).to eq(Lain::Tool::Result.error('no tool named "bash" is available'))
        expect(ran).to be_empty
      end

      it "runs the approved call when the flip left its tool in place" do
        result, ran = parked_then(switchboard, :auto)

        expect(result).to eq(Lain::Tool::Result.ok("the interpreter ran"))
        expect(ran).to eq(%w[bash])
      end
    end

    # The order is a security posture: a denied path is not approvable, so the
    # refusal that no answer lifts sits outside the gate that asks.
    it "lists the path refusal ahead of the approval gate" do
      expect(switchboard.gate.map(&:class)).to eq([Lain::Middleware::Sensitivity, Lain::Middleware::Gate])
    end

    it "judges both layers against the board's one path policy" do
      board = switchboard

      expect(board.gate.map { |layer| layer.instance_variable_get(:@sensitivity) }).to all(be(board.sensitivity))
    end
  end

  describe "the snapshot slot" do
    let(:slot) { instance_spy(Lain::Agent::SnapshotSlot) }

    it "answers the starting posture's scope, so the slot is born with it" do
      expect(switchboard.snapshot_scope).to eq(:shadow_git)
    end

    it "hands every flip's scope to the slot it was bound" do
      board = switchboard
      board.bind_snapshots(slot)

      board.mode_switch.switch(mode(:plan), surface: "tty")
      board.mode_switch.switch(mode(:auto), surface: "tty")

      expect(slot).to have_received(:rebind).with(:write_set).ordered
      expect(slot).to have_received(:rebind).with(:shadow_git).ordered
      expect(board.snapshot_scope).to eq(:shadow_git)
    end

    it "flips harmlessly before any slot is bound" do
      expect { switchboard.mode_switch.switch(mode(:plan), surface: "tty") }.not_to raise_error
    end

    it "hands the bound slot to the command surface" do
      board = switchboard
      board.bind_snapshots(slot)

      kwargs = board.surface_kwargs(conductor: instance_double(Lain::CLI::Conductor),
                                    tty: instance_double(Lain::Frontend::TTY))

      expect(kwargs.fetch(:snapshots)).to be(slot)
    end

    # `/survey` walks a tree through the run's path boundary, so the board hands
    # it over the same way it hands over the ledger and the snapshot slot.
    # IDENTITY: a second policy over a second classifier is precisely the
    # divergence -- a listing enumerating what the gate refuses -- and two
    # policies compiled from one file agree until the file changes.
    it "hands the run's path boundary to the command surface" do
      classifier = Lain::Sensitivity.new(home: "/home/tester", cwd: "/home/tester/project")
      policy = Lain::Sensitivity::Policy.new(sensitivity: classifier)
      board = switchboard(sensitivity: policy)

      kwargs = board.surface_kwargs(conductor: instance_double(Lain::CLI::Conductor),
                                    tty: instance_double(Lain::Frontend::TTY))

      expect(kwargs.fetch(:sensitivity)).to be(policy)
    end

    it "writes the snapshot after a flip to plan under the write-set scope", :seam do
      Dir.mktmpdir do |root|
        board = switchboard
        slot = Lain::Agent::SnapshotSlot.new(root:, scope: board.snapshot_scope,
                                             paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => root,
                                                                           "HOME" => root }))
        board.bind_snapshots(slot)
        board.mode_switch.switch(mode(:plan), surface: "tty")
        written = File.join(root, "a.rb").tap { |path| File.write(path, "written\n") }

        event = slot.write(timeline: Lain::Timeline.empty(store: Lain::Store.new)
                                                   .commit(role: :user, content: [{ "type" => "text", "text" => "t" }]),
                           paths: [written])

        expect(event.body.fetch("snapshot_scope")).to eq(Lain::Workspace::Snapshot::Scope::WriteSet::NOTE)
      end
    end
  end

  it "hands /approve a tty-signing drain prompt whose reads route through the conductor" do
    conductor = instance_double(Lain::CLI::Conductor)
    tty = instance_double(Lain::Frontend::TTY)
    prompt = switchboard.surface_kwargs(conductor:, tty:).fetch(:approval_prompt)
    pending = Lain::Approval::Queue::Pending.new(
      effect: Struct.new(:name, :input, :tool_use_id).new("bash", { "command" => "ls" }, "tu_1"),
      requester: "agent", clock: -> { 0.0 }
    )
    allow(conductor).to receive(:read_reply).with(tty, /bash/).and_return("y")

    prompt.decide(pending)

    expect(pending.surface).to eq("tty")
    expect(pending).to be_approved
  end

  # A direct unit spec over the decorator itself, collaborators doubled --
  # the `board.mode_switch.switch(...)` examples above prove the end-to-end
  # behaviour through a real Toolset; this one proves the ORDER the
  # implementation comment claims: the toolset handed to the inner switch is
  # read off the resolution BEFORE #apply gets a chance to move anything, not
  # re-read from a live slot afterward.
  describe Lain::CLI::Switchboard::BoundSwitch do
    it "passes the toolset of the resolution it applies, read before apply moves anything" do
      mode = Lain::Mode.new(posture: :plan)
      resolution = Lain::Mode::Resolution.new(toolset: Lain::Toolset.new, gate_policy: ->(*) { false },
                                              snapshot_scope: :write_set)
      seen = []
      inner_switch = Object.new
      inner_switch.define_singleton_method(:switch) { |_mode, surface:, toolset:| seen << [:switch, surface, toolset] }
      inner_switch.define_singleton_method(:current) { mode }
      resolve = ->(candidate) { candidate == mode ? resolution : raise("unexpected mode: #{candidate.inspect}") }
      apply = ->(res, surface:) { seen << [:apply, surface, res.toolset] }

      described_class.new(inner_switch, resolve:, apply:).switch(mode, surface: "spec")

      # ORDER is the claim: `switch` sees the resolution's toolset FIRST, and
      # `apply` -- the only thing that could have moved a live slot -- runs
      # only after. Both entries also carry the SAME toolset object, so a
      # reader cannot mistake this for two resolutions agreeing by accident.
      expect(seen).to eq([[:switch, "spec", resolution.toolset], [:apply, "spec", resolution.toolset]])
    end
  end
end
