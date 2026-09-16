# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Switchboard do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  # A REAL Toolset: the rules rung reads a call's tier off it, and a double
  # would answer whatever an example stubbed.
  let(:base) { Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }) }

  def switchboard(toolset: base, **rest)
    described_class.new(journal:, model: "claude-opus-4-8", toolset:, **rest)
  end

  def mode(approval) = Lain::Mode.new(approval:)

  def layout_run = Lain::Middleware::GuardTestLayout::Run.undeclared

  def gated_call = Struct.new(:name, :input, :tool_use_id).new("bash", { "command" => "ls" }, "tu_1")

  # The layers a session's tool calls pass, as the tool guard builds them over
  # this board -- the one place a chat's stack is assembled.
  def tool_stack(board)
    Lain::CLI::ToolGuard.stack(Lain::CLI::ToolGuard::Journaled.new(journal:), board).to_a
  end

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

      # The gate is built from the same value: the board's ONE policy switch,
      # which every mode flip reaches, and the sentence its refusals are
      # reported in -- decided once, because whether a human is attached does
      # not change for a session's whole life.
      it "carries the board's one policy switch and its refusal sentence among the guard's inputs" do
        board = described_class.for(chronicle:, options: { non_interactive: true }, model: "claude-opus-4-8",
                                    toolset: base, test_layout: layout_run)

        expect(board.guard_inputs.policy).to be(board.policy_switch)
        expect(board.guard_inputs.denial).to start_with("no approval is possible for tool %<name>s")
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
    # list and ask approval, and `/mode auto` is the only way out of them.
    it "wires the approval queue and starts in checkout ask, with no flag to skip either" do
      board = board_for

      expect(board.approvals).to be_a(Lain::Approval::Queue)
      expect(board.mode_switch.current).to eq(Lain::Mode.new)
    end

    # `--non-interactive` answers "who decides a gated call" with "nobody can".
    # It and `--auto-approve`, which only seeds a mode layer, are the two flags
    # this entry reads.
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

      # A fact about the wiring rather than a defect: a session with nobody to
      # ask gets a one-rung ladder that refuses everything under `ask`, so the
      # exclusion table is never consulted there.
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

  # A worker leased into a checkout of its own runs its commands there, so the
  # rungs that read a command's words are rebuilt over the factory its
  # environment answers, and everything else about the gate stays the board's.
  describe "the gate policy a worker is judged by" do
    let(:classifiers) { Lain::CLI::Wiring::BoardBuild::Classifiers.new(home: "/home/tester", cwd: "/srv/project") }
    let(:leased) { Lain::WorkerEnv.new(cwd: "/srv/lease", env: {}, checkout: "/srv/lease") }
    let(:remembered) do
      Class.new(Lain::Approval::Rule) do
        def name = "remembered"
        def decide(_call) = nil
      end.new
    end

    def board
      @board ||= switchboard(classifiers:, rules: [remembered],
                             approving: Lain::CLI::Wiring::BoardBuild.method(:approving))
    end

    def policy_for(worker_env) = board.guard_inputs.policy_for.call(worker_env)

    def factories_of(ladder)
      triage, rules = ladder.to_a
      [triage, rules.instance_variable_get(:@rules).last].map { |held| held.instance_variable_get(:@sensitivity) }
    end

    it "is the board's own policy switch for a worker no lease cut a checkout for" do
      expect(policy_for(Lain::WorkerEnv.new(cwd: "/srv/project/lib", env: {}))).to be(board.policy_switch)
    end

    it "judges a leased worker's triage and rules rungs over ONE factory, anchored on its checkout" do
      triage_factory, rules_factory = factories_of(policy_for(leased).current)

      expect(triage_factory).to be(rules_factory)
      expect(triage_factory).not_to be(classifiers)
      expect(triage_factory.instance_variable_get(:@roots)).to eq(["/srv/lease"])
    end

    it "keeps the remembered answers ahead of the approving rule, and leaves the parent's ladder as it was" do
      rules = policy_for(leased).current.to_a[1].instance_variable_get(:@rules)

      expect(rules.map(&:name)).to eq(%w[remembered composed_term])
      expect(factories_of(board.ladder)).to all(be(classifiers))
    end

    it "parks a leased worker's call on the board's one queue" do
      expect(policy_for(leased).current.to_a.last.queue).to be(board.approvals)
    end

    it "follows the session's approval level as a flip moves it" do
      policy = policy_for(leased)
      board.mode_switch.switch(mode(:auto), surface: "tty")
      moved = policy.current.label
      board.mode_switch.switch(mode(:ask), surface: "tty")

      expect([moved, policy.current.label]).to eq(%w[auto ask])
    end

    it "journals a leased worker's rulings where the parent's land" do
      Sync do |task|
        parked = task.async { policy_for(leased).call(gated_call, nil) }
        task.with_timeout(1) { board.approvals.dequeue }

        expect(Lain::Journal.records(journal_io.string.lines, type: "escalation")
                            .map { |record| record["rung"] }.to_a).to eq(%w[triage rules])
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

    # The approval level decides who is asked, not whether the run has somewhere to
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
  # fixed Gate reads, and leaves the capability set the Agent renders alone.
  describe "the mode side, bound to the live gate" do
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

        expect(board.mode_switch.current).to eq(Lain::Mode.new)
        expect(board.toolset).to be(base)
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
          dispatch_call("bash", { "command" => "ls" }, toolset: board.toolset, layers: tool_stack(board),
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

    describe "an approval flip at runtime" do
      it "approves a tier-3 call without parking it once approval switches to auto" do
        board = switchboard

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

      it "restores the queue when approval switches back to ask" do
        board = switchboard

        board.mode_switch.switch(mode(:auto), surface: "tty")
        # The board STARTS on the ladder, so asserting only the destination is
        # vacuous -- "never moved" and "moved back" are the same reading. This
        # is the leg that tells them apart.
        expect(board.policy_switch.current).not_to be(board.ladder)

        board.mode_switch.switch(mode(:ask), surface: "tty")

        expect(board.policy_switch.current).to be(board.ladder)
      end

      # The gate flip rides the SAME journal the mode flip does, so a transcript
      # shows one policy history rather than two half-histories to be joined by
      # hand.
      it "journals the gate flip through the one policy switch, attributed to the surface" do
        board = switchboard

        board.mode_switch.switch(mode(:auto), surface: "editor")

        expect(policy_records.last).to include("from" => "ask", "to" => "auto", "surface" => "editor")
      end

      # One approval level, one name in the record, whoever is attached.
      it "names the unattended ask ladder ask too, so its gate flips read ask and auto" do
        board = switchboard(attended: false)

        board.mode_switch.switch(mode(:auto), surface: "tty")
        board.mode_switch.switch(mode(:ask), surface: "tty")

        expect(policy_records.map { |record| record.values_at("from", "to") }).to eq([%w[ask auto], %w[auto ask]])
      end

      # A flip back to the level in force selects the very ladder already
      # there, so the policy switch sees nothing moved and writes nothing.
      it "journals no gate flip when a mode flip leaves approval where it was" do
        board = switchboard

        board.mode_switch.switch(Lain::Mode.new(layers: %i[notify]), surface: "tty")

        expect([mode_records.size, policy_records]).to eq([1, []])
      end
    end
  end

  # The layers every tool call of a session passes before it is interpreted,
  # built over this board and driven through the real runner. The interpreter
  # is a Mock that records, so "it did not run" is an observation rather than
  # an inference from a refusal's wording -- and `bash` never really runs.
  describe "the tool stack built over this board" do
    def recording(ran)
      Lain::Effect::Handler::Mock.new do |effect, _context|
        ran << effect.name
        Lain::Tool::Result.ok("the interpreter ran")
      end
    end

    it "refuses an effect its policy denies before the interpreter runs" do
      ran = []
      board = switchboard(attended: false)

      result = dispatch_call("bash", { "command" => "ls" }, toolset: board.toolset, layers: tool_stack(board),
                                                            handler: recording(ran))

      expect(result).to have_attributes(is_error: true, content: /no approval is possible for tool "bash"/)
      expect(ran).to be_empty
    end

    it "hands an effect its policy allows to the interpreter, whose result comes back" do
      ran = []
      board = switchboard
      board.mode_switch.switch(mode(:auto), surface: "tty")

      result = dispatch_call("bash", { "command" => "ls" }, toolset: board.toolset, layers: tool_stack(board),
                                                            handler: recording(ran))

      expect(result).to eq(Lain::Tool::Result.ok("the interpreter ran"))
      expect(ran).to eq(%w[bash])
    end

    # Approval can take as long as a human takes, and a `/mode` flip in that
    # window changes the policy the NEXT call is ruled by, never the answer a
    # parked call is waiting on -- driven through the real board.
    describe "a flip while the call waits on a human" do
      def parked_then(board, flip)
        ran = []
        result = Sync do |task|
          call = task.async do
            dispatch_call("bash", { "command" => "rm -rf build" }, toolset: board.toolset,
                                                                   layers: tool_stack(board), handler: recording(ran))
          end
          pending = task.with_timeout(1) { board.approvals.dequeue }
          board.mode_switch.switch(mode(flip), surface: "tty")
          pending.approve(surface: "spec")
          task.with_timeout(1) { call.wait }
        end
        [result, ran]
      end

      it "runs the approved call, the tool still in place after a flip to auto" do
        result, ran = parked_then(switchboard, :auto)

        expect(result).to eq(Lain::Tool::Result.ok("the interpreter ran"))
        expect(ran).to eq(%w[bash])
      end
    end

    # What the model reads off a refused call's tool_result, through the board a
    # real chat builds. A refusal the session decided before anyone could be
    # asked says why and that no approval will lift it, because the model
    # otherwise concludes the tool itself is unavailable and routes around it.
    # A human's no stays the sentence it always was.
    describe "what an attended session tells the model a refusal was" do
      let(:home) { "/home/tester" }
      let(:classifiers) { Lain::CLI::Wiring::BoardBuild::Classifiers.new(home:, cwd: "/srv/project") }
      let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }

      def told(board, command)
        dispatch_call("bash", { "command" => command }, toolset: board.toolset, layers: tool_stack(board),
                                                        context: Lain::Session.new).content
      end

      # What the journal reason carries for a journal READER, and what a model
      # would misread: an opening "allow", the path's refusal said twice, and
      # the verdict's disclaimer about safety.
      def expect_plain(refusal)
        expect(refusal).not_to include("shell verdict allow")
        expect(refusal).not_to include(Lain::Shell::Verdict::CLAIM)
        expect(refusal).not_to include("never whether it is safe")
        expect(refusal.scan("no approval").size).to eq(1)
      end

      # Scenario: a protected-path deny says why
      it "names the protected path a command reads, and says no approval will lift it" do
        refusal = told(switchboard(classifiers:), "cat #{home}/.ssh/id_rsa")

        expect(refusal).to eq(
          %(refused tool "bash": the command names a path this session protects: "#{home}/.ssh/id_rsa" ) \
          "is a protected path; no approval will lift this, so do not re-send the same command in another form"
        )
        expect_plain(refusal)
      end

      # Scenario: a project exclusion deny names the exclusion
      it "names the program the project's [shell] exclude table refuses" do
        excluding_curl = Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: ["curl"]))
        board = described_class.for(chronicle:, options: {}, model: "claude-opus-4-8", toolset: base,
                                    verdict: excluding_curl, test_layout: layout_run)

        refusal = told(board, "curl http://example.com")

        expect(refusal).to eq(
          %(refused tool "bash": the session's capability set excludes: "curl"; ) \
          "no approval will lift this, so do not re-send the same command in another form"
        )
        expect_plain(refusal)
      end

      # Scenario: a human's denial is unchanged
      it "keeps a human's denial byte-for-byte" do
        board = switchboard

        result = Sync do |task|
          call = task.async do
            dispatch_call("bash", { "command" => "rm -rf build" }, toolset: board.toolset, layers: tool_stack(board),
                                                                   handler: recording([]))
          end
          task.with_timeout(1) { board.approvals.dequeue }.deny(surface: "tty")
          task.with_timeout(1) { call.wait }
        end

        expect(result).to eq(Lain::Tool::Result.error('approval denied for tool "bash"'))
      end
    end

    # A bare callable is adapted by the Gate into a ruling with no reason. No
    # production policy may need that, or its refusals could never say why.
    describe "the policy the gate holds" do
      def held(board) = tool_stack(board).last.instance_variable_get(:@policy)

      it "is the board's own policy switch, not an adapter over it" do
        board = switchboard

        expect(held(board)).to be(board.policy_switch)
      end

      it "switches only between policies that answer a ruling themselves, attended or not" do
        levels = Lain::Mode::Approval::NAMES.reverse
        [switchboard, switchboard(attended: false)].each do |board|
          levels.each do |approval|
            board.mode_switch.switch(mode(approval), surface: "tty")

            expect(board.policy_switch.current).to respond_to(:rule), "#{approval} resolved to a Boolean-only policy"
          end
        end
      end
    end

    # The order is a security posture: a denied path is not approvable, so the
    # refusal that no answer lifts sits outside the gate that asks, and the
    # gate is last, so nothing rewrites what it approved.
    it "ends in the path refusal and then the approval gate" do
      expect(tool_stack(switchboard).last(2).map(&:class)).to eq([Lain::Middleware::Sensitivity, Lain::Middleware::Gate])
    end

    it "judges both layers against the board's one path policy" do
      board = switchboard

      expect(tool_stack(board).last(2).map { |layer| layer.instance_variable_get(:@sensitivity) })
        .to all(be(board.sensitivity))
    end
  end

  describe "the snapshot slot" do
    let(:slot) { instance_spy(Lain::Agent::SnapshotSlot) }

    # The slot falls back to the write-set scope by itself when the shadow
    # store fails, so no mode chooses a scope.
    it "answers the shadow scope every mode writes under, so the slot is born with it" do
      expect(switchboard.snapshot_scope).to eq(:shadow_git)
    end

    it "leaves the bound slot's scope alone across a mode flip" do
      board = switchboard
      board.bind_snapshots(slot)

      board.mode_switch.switch(mode(:auto), surface: "tty")

      expect(slot).not_to have_received(:rebind)
      expect(board.snapshot_scope).to eq(:shadow_git)
    end

    it "flips harmlessly before any slot is bound" do
      expect { switchboard.mode_switch.switch(mode(:auto), surface: "tty") }.not_to raise_error
    end

    it "hands the bound slot to the command surface" do
      board = switchboard
      board.bind_snapshots(slot)

      kwargs = board.surface_kwargs(conductor: instance_double(Lain::CLI::Conductor))

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

      kwargs = board.surface_kwargs(conductor: instance_double(Lain::CLI::Conductor))

      expect(kwargs.fetch(:sensitivity)).to be(policy)
    end
  end

  it "hands /approve a tty-signing drain prompt whose reads route through the conductor" do
    conductor = instance_double(Lain::CLI::Conductor)
    prompt = switchboard.surface_kwargs(conductor:).fetch(:approval_prompt)
    pending = Lain::Approval::Queue::Pending.new(
      effect: Struct.new(:name, :input, :tool_use_id).new("bash", { "command" => "ls" }, "tu_1"),
      requester: "agent", clock: -> { 0.0 }
    )
    allow(conductor).to receive(:read_reply).with(/bash/).and_return("y")

    prompt.decide(pending)

    expect(pending.surface).to eq("tty")
    expect(pending).to be_approved
  end

  # The auto_approve layer end to end, over the two objects a real chat builds
  # it from, in the order the chat builds them: the toolset build first, which
  # makes the surface over a thunk, then the board that holds the mode switch
  # the surface reads. The provider answers APPROVE to anything, so a decision
  # signed auto_approver is proof the surface ran, and a provider that was
  # never asked is proof it did not.
  describe "the auto_approve layer, over the toolset build a chat assembles" do
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
    let(:home) { "/home/tester" }
    let(:sensitivity) do
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: "#{home}/proj"))
    end
    let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }) }
    let(:provider) { Lain::Provider::Mock.new(responses: [text_response("APPROVE")]) }
    let(:ran) { [] }
    let(:handler) do
      Lain::Effect::Handler::Mock.new do |effect, _context|
        ran << effect.name
        Lain::Tool::Result.ok("the interpreter ran")
      end
    end

    def chat(**options)
      board = nil
      build = toolset_build(options, -> { board })
      build.build(Lain::Memory::Recorder.new, ask_human: Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.new }))
      board = described_class.for(chronicle:, options:, model: "claude-opus-4-8", toolset: base, sensitivity:,
                                  test_layout: layout_run)
      [board, build]
    end

    def toolset_build(options, switchboard)
      Lain::CLI::Wiring::ToolsetBuild.new(
        backend:, provider:, chronicle: Lain::CLI::Chronicle::Null.new, options:, switchboard:,
        supervisor: Lain::Supervisor.new(journal: RecordingChannel.new),
        parent: -> { Lain::Timeline.empty(store: Lain::Store.new) }, journal: RecordingChannel.new,
        library: backend.library, epic: Lain::CLI::EpicMount::NoEpic, root: "/srv/switchboard-project",
        askers: SpecNulls::UnwiredAskers.build
      )
    end

    def typed(board, args)
      Lain::CLI::Command::Mode.new.call(args, instance_double(Lain::CLI::Command::Env, mode_switch: board.mode_switch))
    end

    # The automatic surface as the Repl's fan-out spawns it, and the only
    # watcher: whatever decides a pending here is that surface or the human the
    # example plays after it.
    def watching(board, build, task) = [task.async { build.auto_surface.watch(board.approvals) }]

    def dispatched(board, task, name, input)
      task.async { dispatch_call(name, input, toolset: board.toolset, layers: tool_stack(board), handler:) }
    end

    def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

    # Scenario: turning the layer on lets the automatic approver decide
    it "lets the automatic approver decide a call parked after /mode +auto_approve" do
      board, build = chat
      typed(board, "+auto_approve")

      result = Sync do |task|
        watchers = watching(board, build, task)
        call = dispatched(board, task, "bash", { "command" => "rm -rf build" })
        task.with_timeout(5) { call.wait }
      ensure
        [*watchers, call].compact.each(&:stop)
      end

      expect(board.mode_switch.approval.name).to eq(:ask)
      expect(result).to eq(Lain::Tool::Result.ok("the interpreter ran"))
      expect(decisions.map { |record| record["surface"] }).to eq([Lain::Approval::AutoSurface::SURFACE])
    end

    # Scenario: turning the layer off returns decisions to the human
    it "leaves a call parked after /mode -auto_approve to the human, and never asks the role" do
      board, build = chat
      typed(board, "+auto_approve")
      typed(board, "-auto_approve")

      surfaces = Sync do |task|
        watchers = watching(board, build, task)
        call = dispatched(board, task, "bash", { "command" => "rm -rf build" })
        pumped_until(task, reason: "the call to park") { board.approvals.any? }
        settle_for(task, 0.3)
        undecided = board.approvals.none?(&:decided?)
        board.approvals.first.deny(surface: "tty")
        task.with_timeout(1) { call.wait }
        [undecided, decisions.map { |record| record["surface"] }]
      ensure
        [*watchers, call].compact.each(&:stop)
      end

      expect(surfaces).to eq([true, ["tty"]])
      expect([provider.call_count, ran]).to eq([0, []])
    end

    # Scenario: the launch flag shows its lighter
    it "seeds the layer from --auto-approve, so the first prompt carries AA and /mode lists it" do
      board, = chat(auto_approve: true)
      run_state = Lain::Frontend::PromptComposer::RunState.new(
        agent: instance_double(Lain::Agent, occupancy: 0.0, dispatching?: false,
                                            context: instance_double(Lain::Context, model: "opus")),
        clock: Lain::RunClock.new(clock: -> { 0.0 }), status_feed: instance_double(Lain::StatusFeed, state: {}),
        mode: board.mode_switch
      )

      expect(run_state.to_h["mode"]).to eq("AA")
      expect(typed(board, "")).to include("auto_approve")
    end

    # The status line and a bench reader fold the mode off the journal, never
    # off the live board, so a layer the flag turned on has to be written down
    # before the first prompt or they show nothing until the first /mode.
    it "journals the launch flag's layer once, as the record /mode writes, before any prompt" do
      chat(auto_approve: true)

      expect(mode_records).to contain_exactly(
        a_hash_including("from_approval" => "ask", "to_approval" => "ask", "from_layers" => [],
                         "to_layers" => %w[auto_approve], "surface" => described_class::LAUNCH_SURFACE)
      )
      expect(policy_records).to be_empty
    end

    it "starts with no layer when the flag is absent, and journals no mode at all" do
      board, = chat

      expect([board.mode_switch.layers.to_a, mode_records]).to eq([[], []])
    end

    # Scenario: a denied path stays unliftable under the layer
    it "refuses a protected private key at the path boundary before any surface is asked" do
      board, build = chat(auto_approve: true)

      result = Sync do |task|
        watchers = watching(board, build, task)
        call = dispatched(board, task, "read_file", { "path" => "#{home}/.ssh/id_rsa" })
        task.with_timeout(1) { call.wait }
      ensure
        [*watchers, call].compact.each(&:stop)
      end

      expect(result).to have_attributes(is_error: true, content: /no approval can lift this/)
      expect([board.approvals.to_a, decisions, provider.call_count, ran]).to eq([[], [], 0, []])
    end
  end

  # A mode is scope × approval, driven through the production entry and the
  # command a human types, so the flip under test is the flip a chat makes.
  describe "a mode is scope × approval, over the production entry" do
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
    let(:home) { "/home/tester" }
    let(:classifiers) { Lain::CLI::Wiring::BoardBuild::Classifiers.new(home:, cwd: "#{home}/project") }

    def board_for(**options)
      described_class.for(chronicle:, options:, model: "claude-opus-4-8", toolset: base, classifiers:,
                          test_layout: layout_run)
    end

    def typed(board, args)
      Lain::CLI::Command::Mode.new.call(args, instance_double(Lain::CLI::Command::Env, mode_switch: board.mode_switch))
    end

    # Scenario: auto still honours a triage deny
    #
    # The interpreter is a recording Mock, so a regression that approves the
    # call is an observation and never a real write under a home directory.
    it "denies a command writing under a protected path under /mode auto, rather than approving it" do
      ran = []
      board = board_for
      typed(board, "auto")

      result = dispatch_call("bash", { "command" => "cp spare.key #{home}/.ssh/id_ed25519" },
                             toolset: board.toolset, layers: tool_stack(board), context: Lain::Session.new,
                             handler: Lain::Effect::Handler::Mock.new { |effect, _| ran << effect.name })

      expect(result).to have_attributes(is_error: true, content: /refused tool "bash".*protects/)
      expect(ran).to be_empty
      expect(board.policy_switch.current.map(&:name)).to eq(%w[triage rules auto])
    end

    it "approves the remainder under /mode auto, where nothing above refused, without parking it" do
      board = board_for
      typed(board, "auto")

      expect(board.policy_switch.call(gated_call, nil)).to be(true)
      expect(board.approvals).to be_none
    end

    # Scenario: a no-op flip journals nothing
    it "writes no mode_switch or policy_switch record for a flip that moves nothing" do
      board = board_for
      typed(board, "+vi")
      before = [mode_records.size, policy_records.size]

      typed(board, "+vi")

      expect([mode_records.size, policy_records.size]).to eq(before)
    end

    # Scenario: the toolset does not change with the mode
    it "renders the same tool block before and after /mode auto" do
      board = board_for
      before = board.toolset.digest

      typed(board, "auto")

      expect(board.toolset.digest).to eq(before)
      expect(board.toolset).to be(base)
    end
  end

  # Production-shaped: the board's journal is a JournalTee with a real
  # StatusFeed as its sink, and the feed cannot publish (a state dir that is a
  # file). The session file must keep agreeing with the live mode, gate
  # included, and a retry must not break the chain the loader walks.
  # Plan scope, over a spike that leases a plain directory: what moves on a
  # flip, what is given back, and how a command is judged once the session is
  # confined. The seam spec drives the same over real git.
  describe "plan scope" do
    around do |example|
      Dir.mktmpdir("lain-board-plan") do |dir|
        @base = File.realpath(dir)
        @home = File.join(@base, "project").tap { FileUtils.mkdir_p(_1) }
        example.run
      end
    end

    # Leases a fresh directory per acquire, and remembers every lease.
    let(:spike) do
      Class.new do
        attr_reader :leases

        def initialize(base)
          @base = base
          @leases = []
        end

        def acquire
          dir = File.join(@base, "spike-#{@leases.size}").tap { FileUtils.mkdir_p(_1) }
          Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {}),
                                     origin: Lain::Isolation::Lease::Origin.new(path: dir)).tap { @leases << _1 }
        end

        def reminder(lease) = "confined to #{lease.worker_env.checkout}"

        def release(lease)
          lease.release
          "gave back #{lease.worker_env.checkout}"
        end
      end.new(@base)
    end

    let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @home, env: {})) }
    let(:slot) { instance_spy(Lain::Agent::SnapshotSlot, root: @home) }

    def board(**rest)
      @board ||= switchboard(spike:, **rest).bind_session(session).tap { _1.bind_snapshots(slot) }
    end

    def plan!(approval = :ask) = board.mode_switch.switch(Lain::Mode.new(scope: :plan, approval:), surface: "tty")

    def spiked = spike.leases.last.worker_env.checkout

    describe "a flip into plan" do
      it "leases a directory and moves the session's tools and reminders there" do
        plan!

        expect(session.worker_env.cwd).to eq(spiked)
        expect(session.reminders).to eq(["confined to #{spiked}"])
        expect(board.mode_switch.scope.name).to eq(:plan)
      end

      it "roots the snapshots at the lease" do
        plan!

        expect(slot).to have_received(:rebind).with(root: spiked)
      end

      it "journals the flip as a scope move" do
        plan!

        expect(mode_records).to contain_exactly(a_hash_including("from_scope" => "checkout", "to_scope" => "plan"))
      end

      it "leases once however many times the approval moves inside plan" do
        plan!
        plan!(:auto)
        plan!(:ask)

        expect(spike.leases.size).to eq(1)
        expect(spike.leases.first).not_to be_released
      end

      it "refuses with no session bound, leasing nothing and journaling nothing" do
        unbound = switchboard(spike:)

        expect { unbound.mode_switch.switch(Lain::Mode.new(scope: :plan), surface: "tty") }
          .to raise_error(Lain::Mode::Scope::Unavailable, /no session is bound/)
        expect([spike.leases, mode_records]).to eq([[], []])
      end

      it "refuses on a board with no project to cut a spike from, as a scope that is unavailable" do
        unscoped = switchboard.bind_session(session)

        expect { unscoped.mode_switch.switch(Lain::Mode.new(scope: :plan), surface: "tty") }
          .to raise_error(Lain::Mode::Scope::Unavailable, /plan scope could not be entered: .*needs a project/)
        expect([unscoped.mode_switch.scope.name, mode_records]).to eq([:checkout, []])
      end

      # A lease taken and then left behind by a setup that raised is a spike
      # nobody holds and nothing releases.
      it "gives the lease back when the scope cannot be set up after the lease was taken" do
        broken = spike
        broken.define_singleton_method(:reminder) { |_env| raise IOError, "unreadable" }

        expect { plan! }.to raise_error(Lain::Mode::Scope::Unavailable, /unreadable/)
        expect(spike.leases.first).to be_released
        expect([session.scope, mode_records]).to eq([Lain::Session::Unconfined, []])
      end

      # The record commits a flip. One refused leaves the session where it was,
      # so the lease taken for it must not be left behind.
      it "gives the lease back and leaves the session unconfined when the record is refused" do
        refusing = Object.new
        refusing.define_singleton_method(:record) { |_record| raise IOError, "closed" }
        refused = described_class.new(journal: refusing, model: "m", toolset: base, spike:).bind_session(session)

        expect { refused.mode_switch.switch(Lain::Mode.new(scope: :plan), surface: "tty") }.to raise_error(IOError)
        expect(spike.leases.first).to be_released
        expect([session.scope, refused.mode_switch.scope.name]).to eq([Lain::Session::Unconfined, :checkout])
      end
    end

    describe "a flip back to the checkout" do
      it "says what giving the spike back did, for the command to show" do
        plan!
        board.mode_switch.switch(Lain::Mode.new, surface: "tty")

        expect(board.mode_switch.said).to eq("gave back #{spike.leases.first.worker_env.checkout}")
      end

      it "says nothing for a flip that moved no scope" do
        board.mode_switch.switch(mode(:auto), surface: "tty")

        expect(board.mode_switch.said).to eq("")
      end

      it "releases the lease and returns the session to where it was built" do
        plan!
        board.mode_switch.switch(Lain::Mode.new, surface: "tty")

        expect(spike.leases.first).to be_released
        expect([session.worker_env.cwd, session.reminders]).to eq([@home, []])
        expect(slot).to have_received(:rebind).with(root: @home)
      end

      it "restores the checkout's own ladders" do
        plan!
        board.mode_switch.switch(Lain::Mode.new, surface: "tty")

        expect(board.policy_switch.current).to be(board.ladder)
      end
    end

    describe "a command under plan" do
      def parked(policy, context: session)
        Sync do |task|
          call = task.async { policy.call(gated_call, context) }
          task.with_timeout(1) { board.approvals.dequeue }
        ensure
          call&.stop
        end
      end

      it "is judged by the plan ladder for the approval level in force" do
        plan!(:auto)

        expect(board.policy_switch.current.label).to eq("plan auto")
      end

      # Nothing proved `ls`'s words confined, so under auto it still waits,
      # and for a person: the automatic approver is not offered it.
      it "parks for a human even under auto, where nothing automatic may take it" do
        plan!(:auto)

        pending_call = parked(board.policy_switch)

        expect(pending_call).to be_humans_only
      end

      it "records why a command under auto waited, once a human decides it" do
        plan!(:auto)
        Sync do |task|
          call = task.async { board.policy_switch.call(gated_call, session) }
          task.with_timeout(1) { board.approvals.dequeue }.deny(surface: "tty")
          call.wait
        end

        because = start_with("plan scope cannot confine this command to #{spiked}")
        expect(Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a.last)
          .to include("rung" => "surfaces", "reason" => because)
      end

      it "approves a call that is no command under auto, as the checkout does" do
        plan!(:auto)
        read = Struct.new(:name, :input, :tool_use_id).new("read_file", { "path" => "a.rb" }, "tu_2")

        expect(board.policy_switch.call(read, session)).to be(true)
      end

      it "refuses an unconfined command outright when nobody attends" do
        unattended = switchboard(spike:, attended: false).bind_session(session)
        unattended.mode_switch.switch(Lain::Mode.new(scope: :plan, approval: :auto), surface: "tty")

        expect(unattended.policy_switch.call(gated_call, session)).to be(false)
      end

      # A human's remembered answer is about a command's shape in the checkout,
      # and says nothing about the spike: under plan only the confinement rule
      # may approve a command.
      it "never approves a command on a remembered allow, and parks it for a human instead" do
        remembered = Lain::Approval::Remembered.new(allow: [{ "tool" => "bash", "input" => { "command" => "ls" } }])
        board(rules: [remembered], approving: Lain::CLI::Wiring::BoardBuild.method(:approving))
        plan!(:auto)

        expect(parked(board.policy_switch)).to be_humans_only
      end

      it "still refuses a command on a remembered deny" do
        remembered = Lain::Approval::Remembered.new(deny: [{ "tool" => "bash", "input" => { "command" => "ls" } }])
        board(rules: [remembered], approving: Lain::CLI::Wiring::BoardBuild.method(:approving))
        plan!(:auto)

        expect(board.policy_switch.call(gated_call, session)).to be(false)
      end

      it "hands the board's scope to the tool stack, confining every session judged through it" do
        plan!

        expect(board.guard_inputs.scope.current).to be(session.scope)
      end

      it "judges a child lent the spike by the plan ladder for the level in force" do
        board(classifiers: Lain::CLI::Wiring::BoardBuild::Classifiers.new(home: "/home/tester", cwd: @home))
        plan!(:auto)
        policy = board.guard_inputs.policy_for.call(session.worker_env)

        expect(policy).to be_a(Lain::CLI::Switchboard::Leased)
        expect(policy.current.label).to eq("plan auto")
      end
    end
  end

  describe "a flip whose state-feed publish fails", :seam do
    it "applies whole, writes one record however often it is retried, and leaves the record loadable" do
      Dir.mktmpdir do |dir|
        blocked = File.join(dir, "not-a-dir").tap { |path| File.write(path, "") }
        feed = Lain::StatusFeed.new(path: File.join(blocked, "state.json"))
        board = described_class.new(journal: Lain::CLI::JournalTee.new(journal, feed), model: "m", toolset: base,
                                    test_layout: layout_run)
        env = instance_double(Lain::CLI::Command::Env, mode_switch: board.mode_switch)

        raised = Array.new(2) do
          Lain::CLI::Command::Mode.new.call("auto", env)
          nil
        rescue Lain::StatusFeed::Publication::Unpublishable => e
          e
        end

        expect(raised.first).to be_a(Lain::StatusFeed::Publication::Unpublishable)
        expect(mode_records.map { |record| record["to_approval"] }).to eq(["auto"])
        expect(board.mode_switch.approval.name).to eq(:auto)
        expect(board.policy_switch.current).to have_attributes(label: "auto")
        expect { Lain::Compare::Mode.from_journal(journal_io.string.lines) }.not_to raise_error
      end
    end
  end

  # A direct unit spec over the decorator itself, collaborators doubled --
  # the `board.mode_switch.switch(...)` examples above prove the end-to-end
  # behaviour; this one proves the ORDER the implementation comment claims:
  # nothing is journaled for a mode that cannot be resolved, and the policy
  # moves only after the flip is recorded.
  describe Lain::CLI::Switchboard::BoundSwitch do
    def scoping(seen, ladders: { ask: :ladders })
      move = Lain::CLI::Switchboard::Scoping::Move.new(ladders:, commit: -> { seen << [:commit] },
                                                       abandon: -> { seen << [:abandon] })
      Object.new.tap { |held| held.define_singleton_method(:move) { |_scope| move.tap { seen << [:move] } } }
    end

    it "moves the scope, resolves, switches, commits the move, then applies" do
      mode = Lain::Mode.new(approval: :auto)
      resolution = Lain::Mode::Resolution.new(gate_policy: ->(*) { false })
      seen = []
      inner_switch = Object.new
      inner_switch.define_singleton_method(:switch) { |_mode, surface:| seen << [:switch, surface] }
      inner_switch.define_singleton_method(:current) { mode }
      resolve = lambda do |candidate, ladders|
        seen << [:resolve, ladders]
        candidate == mode ? resolution : raise("unexpected mode: #{candidate.inspect}")
      end
      apply = ->(res, surface:) { seen << [:apply, surface, res] }

      described_class.new(inner_switch, scoping: scoping(seen), resolve:, apply:).switch(mode, surface: "spec")

      expect(seen).to eq([[:move], [:resolve, { ask: :ladders }], [:switch, "spec"], [:commit],
                          [:apply, "spec", resolution]])
    end

    it "switches nothing, and gives the scope's move back, when the mode cannot be resolved" do
      seen = []
      inner_switch = instance_double(Lain::Mode::Switch)
      resolve = ->(_candidate, _ladders) { raise Lain::Mode::Resolution::Unknown, "no policy" }

      expect do
        described_class.new(inner_switch, scoping: scoping(seen), resolve:, apply: ->(*) {})
                       .switch(Lain::Mode.new, surface: "spec")
      end.to raise_error(Lain::Mode::Resolution::Unknown)
      expect(seen).to eq([[:move], [:abandon]])
    end
  end
end
