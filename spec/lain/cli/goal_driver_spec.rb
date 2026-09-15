# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::CLI::GoalDriver do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 256) }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  def iterations
    Lain::Journal.records(journal_io.string.lines, type: "goal_iteration").to_a
  end

  # A Timeline whose head is a settled assistant turn carrying `text` -- the
  # marker source the driver reads between asks, without standing up an Agent.
  def settled_with(text)
    Lain::Timeline.empty
                  .commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
  end

  describe "a Null driver (no standing goal)" do
    subject(:driver) { described_class.new(journal:) }

    it "is inactive and answers the poll with nothing to do, cheaply and silently" do
      notices = []

      expect(driver).not_to be_active
      expect(driver.poll(settled_with("anything")) { |n| notices << n }).to be_nil
      expect(notices).to be_empty
      expect(iterations).to be_empty
    end
  end

  describe "goal loops until done-signal" do
    subject(:driver) { described_class.new(journal:) }

    # A real Agent over a Provider::Mock scripting two continue turns then an
    # explicit done marker -- faithful to the AC.
    let(:provider) do
      Lain::Provider::Mock.new(responses: [text_response("still working"),
                                           text_response("more to do"),
                                           text_response("all specs pass -- #{described_class::DONE}")])
    end
    let(:agent) { Lain::Agent.new(provider:, toolset:, context:) }

    # Mirrors the Repl's converse loop: poll the driver between asks, feed each
    # returned prompt to the agent, stop when the driver has nothing more.
    def drive(driver, agent)
      notices = []
      prompt = driver.poll(agent.timeline) { |n| notices << n }
      while prompt
        agent.ask(prompt)
        prompt = driver.poll(agent.timeline) { |n| notices << n }
      end
      notices
    end

    it "re-prompts with the goal plus a continue/done instruction after each settled turn" do
      driver.start("make the specs green")
      first = driver.poll(agent.timeline)

      expect(first).to include("make the specs green").and include(described_class::DONE)
    end

    it "stops on the marker, driving exactly the scripted turns" do
      driver.start("make the specs green")
      notices = drive(driver, agent)

      expect(provider.call_count).to eq(3)
      expect(driver).not_to be_active
      expect(notices.join).to match(/reached|complete|done/i)
    end

    it "journals each iteration as a goal-attributed event" do
      driver.start("make the specs green")
      drive(driver, agent)

      expect(iterations.size).to eq(3)
      expect(iterations.map { |r| r["goal"] }.uniq).to eq(["make the specs green"])
      expect(iterations.map { |r| r["surface"] }.uniq).to eq(["goal"])
    end
  end

  describe "hard stops" do
    let(:unfinished) { settled_with("continuing to work") }

    it "stops on /goal off, going idle without driving another turn" do
      driver = described_class.new(journal:)
      driver.start("make the specs green")
      driver.stop

      expect(driver).not_to be_active
      expect(driver.poll(unfinished)).to be_nil
      expect(iterations).to be_empty
    end

    it "stops at the iteration cap (default 5), reporting the ceiling inline" do
      driver = described_class.new(journal:)
      driver.start("make the specs green")
      notices = []
      prompts = Array.new(6) { driver.poll(unfinished) { |n| notices << n } }

      expect(prompts.compact.size).to eq(5)
      expect(iterations.size).to eq(5)
      expect(driver).not_to be_active
      expect(notices.join).to include("5")
    end

    it "honours a lower cap" do
      driver = described_class.new(journal:, cap: 2)
      driver.start("make the specs green")
      prompts = Array.new(4) { driver.poll(unfinished) }

      expect(prompts.compact.size).to eq(2)
    end

    it "stops on a budget interrupt, reporting it inline" do
      driver = described_class.new(journal:)
      driver.start("make the specs green")
      driver.poll(unfinished)
      driver.interrupt

      notices = []
      expect(driver.poll(unfinished) { |n| notices << n }).to be_nil
      expect(driver).not_to be_active
      expect(notices.join).to match(/interrupt/i)
    end
  end

  # The objective's turn cannot be pinned when `/goal` runs -- the command
  # dispatches lib-side with ZERO Timeline commits, and the objective reaches
  # the chain only when the Repl feeds this driver's own re-prompt through
  # #ask. So the driver pins on the poll AFTER its first drive, and it finds
  # the turn by CONTENT: the naive positional read (the head at /goal time)
  # names the previous topic, so no positional assumption is trusted here.
  describe "auto-pinning the objective" do
    subject(:driver) { described_class.new(journal:) }

    let(:provider) do
      Lain::Provider::Mock.new(responses: [text_response("still working"),
                                           text_response("more to do"),
                                           text_response("all done -- #{described_class::DONE}")])
    end
    let(:session) { Lain::Session.new }
    let(:agent) { Lain::Agent.new(provider:, toolset:, context:, session:) }

    def run_to_stop(driver, agent)
      prompt = driver.poll(agent.timeline)
      while prompt
        agent.ask(prompt)
        prompt = driver.poll(agent.timeline)
      end
    end

    def pinned_turns
      agent.timeline.ancestors.select { |turn| session.pinned?(turn.digest) }
    end

    def text_of(turn)
      turn.content.select { |block| block["type"] == "text" }.map { |block| block["text"] }.join
    end

    def pin_records
      Lain::Journal.records(journal_io.string.lines, type: "goal_pin").to_a
    end

    def miss_records
      Lain::Journal.records(journal_io.string.lines, type: "goal_pin_missed").to_a
    end

    # The verbatim re-prompt, built by a throwaway driver over its own journal
    # so a decoy turn can be byte-identical to what the real one will drive with.
    def objective_prompt(goal)
      described_class.new(journal: Lain::Journal.new(io: StringIO.new)).start(goal).poll(Lain::Timeline.empty)
    end

    it "pins nothing before its first driven turn is committed" do
      driver.start("make the specs green", session:)
      expect(session.pins).to be_empty

      driver.poll(agent.timeline)

      expect(session.pins).to be_empty
    end

    it "pins the objective's own turn, identified by content and not by position" do
      agent.ask("an unrelated earlier question")
      stale_head = agent.timeline.head_digest

      driver.start("make the specs green", session:)
      run_to_stop(driver, agent)

      expect(session).not_to be_pinned(stale_head)
      expect(pinned_turns.size).to eq(1)
      expect(pinned_turns.first.role).to eq("user")
      expect(text_of(pinned_turns.first)).to include("make the specs green").and include(described_class::DONE)
    end

    it "pins once, not once per driven iteration" do
      driver.start("make the specs green", session:)
      run_to_stop(driver, agent)

      expect(iterations.size).to eq(3)
      expect(session.pins.size).to eq(1)
    end

    # The pin must never be recorded speculatively: Session refuses a blank
    # digest loudly, and there is nothing to name when the driven prompt never
    # reached the Timeline (a torn ask, an interrupted loop).
    it "pins nothing when the driven prompt never reached the Timeline" do
      driver.start("make the specs green", session:)
      driver.poll(agent.timeline)

      expect { driver.poll(agent.timeline) }.not_to raise_error
      expect(session.pins).to be_empty
    end

    it "degrades silently when no session is threaded in" do
      driver.start("make the specs green")

      expect { run_to_stop(driver, agent) }.not_to raise_error
      expect(session.pins).to be_empty
    end

    it "does not pin, and does not raise, through the Null driver" do
      expect(described_class::Null.start("make the specs green", session:)).to be(described_class::Null)
      expect(session.pins).to be_empty
    end

    # The pin runs before the delegate's own poll can retire it. A goal the
    # agent finishes on its FIRST driven turn is the case that proves it: the
    # poll that finds the objective's turn is the same poll that reads the done
    # marker, so a stop-check-first ordering pins nothing at all.
    it "pins an objective the agent finished on its first driven turn" do
      done_at_once = Lain::Provider::Mock.new(responses: [text_response("done -- #{described_class::DONE}")])
      quick = Lain::Agent.new(provider: done_at_once, toolset:, context:, session:)

      driver.start("make the specs green", session:)
      run_to_stop(driver, quick)

      expect(iterations.size).to eq(1)
      expect(session.pins.size).to eq(1)
    end

    # Head-first traversal is REQUIRED, not incidental: root-first would find
    # this decoy -- a human turn typed with the verbatim re-prompt before the
    # driver ever ran -- and pin the wrong turn.
    it "pins the driven turn, not an earlier decoy carrying the same text" do
      agent.ask(objective_prompt("make the specs green"))
      decoy = agent.timeline.ancestors.find { |turn| turn.role == "user" }

      driver.start("make the specs green", session:)
      run_to_stop(driver, agent)

      expect(session.pins.size).to eq(1)
      expect(session).not_to be_pinned(decoy.digest)
      expect(pinned_turns.first.digest).not_to eq(decoy.digest)
    end

    # A deferred poll is exactly when the Repl hands the human back `you>`
    # (repl.rb:106), so `/goal off` can land there. The pin therefore runs
    # AHEAD of the quiescence gate.
    it "pins ahead of the quiescence gate, so an unquiet fleet cannot strand the objective" do
      quiet = true
      deferred = described_class.new(journal:, quiescent: -> { quiet })
      deferred.start("make the specs green", session:)
      agent.ask(deferred.poll(agent.timeline))

      quiet = false
      expect(deferred.poll(agent.timeline)).to be_nil
      expect(session.pins.size).to eq(1)

      deferred.stop
      expect(session.pins.size).to eq(1)
    end

    describe "the Journal record (the pin is the point of the card, so it is evidence)" do
      it "journals the pin, naming the digest and the goal surface" do
        driver.start("make the specs green", session:)
        run_to_stop(driver, agent)

        expect(pin_records.size).to eq(1)
        expect(pin_records.first["digest"]).to eq(session.pins.first)
        expect(pin_records.first["goal"]).to eq("make the specs green")
        expect(pin_records.first["surface"]).to eq("goal")
        expect(miss_records).to be_empty
      end

      # Pinning nothing on a rewritten prompt is the safe direction, but it
      # must not also be a silent one -- once per run, when the run ends.
      # A stop carries no timeline, so the run's last words wait for the
      # driver's next look at one ({#settle_pin}), which the Repl takes before
      # every line.
      it "journals the objective going unprotected when the run ends without a pin" do
        driver.start("make the specs green", session:)
        driver.poll(agent.timeline)

        driver.stop
        driver.settle_pin(agent.timeline)

        expect(session.pins).to be_empty
        expect(pin_records).to be_empty
        expect(miss_records.size).to eq(1)
        expect(miss_records.first["goal"]).to eq("make the specs green")
      end

      # `/goal off` is the RARE ending. A goal that runs out its cap (or signals
      # done) retires from inside the poll itself, and the report has to reach
      # the bench on that path too -- the common one.
      it "journals it on the cap ending too, with no /goal off to close the run" do
        capped = described_class.new(journal:, cap: 2)
        capped.start("make the specs green", session:)

        3.times { capped.poll(agent.timeline) }

        expect(capped).not_to be_active
        expect(session.pins).to be_empty
        expect(miss_records.size).to eq(1)
      end

      # `:LainGoalOff` and `/mode -goal` stop the driver from outside, at any
      # moment -- mid-iteration, before any poll has seen the objective's turn.
      it "pins a goal stopped from outside at its next look at the timeline, and journals no miss" do
        driver.start("make the specs green", session:)
        agent.ask(driver.poll(agent.timeline))

        driver.stop
        driver.settle_pin(agent.timeline)
        driver.settle_pin(agent.timeline)

        expect(session.pins.size).to eq(1)
        expect(pin_records.size).to eq(1)
        expect(miss_records).to be_empty
      end

      it "says nothing either way for a goal that never drove a turn" do
        driver.start("make the specs green", session:)
        driver.stop

        expect(pin_records).to be_empty
        expect(miss_records).to be_empty
      end
    end
  end

  # The driver owns the `goal` layer: it raises it when a goal starts standing
  # and lowers it whichever way the goal ends, over the mode switch a real chat
  # holds, so `/mode` and the prompt's lighter say what the driver is doing.
  describe "the goal layer" do
    let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
    let(:board) do
      Lain::CLI::Switchboard.for(chronicle:, options: {}, model: "claude-opus-4-8",
                                 toolset: Lain::Toolset.new(ToolRegistry.names.map { |name| ToolRegistry.build(name) }),
                                 test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared)
    end
    let(:unfinished) { settled_with("continuing to work") }

    def driver_over(board, **options)
      described_class.new(journal:, layer: described_class::Layer.new(-> { board.mode_switch }), **options)
    end

    def raised? = board.mode_switch.layers.include?(:goal)

    def goal_flips
      flips = Lain::Journal.records(journal_io.string.lines, type: "mode_switch")
      flips.select { |flip| flip["surface"] == "goal" }.to_a
    end

    it "is raised when a goal starts standing, and journaled as the goal's own flip" do
      driver = driver_over(board)
      driver.start("make the specs green")

      expect(raised?).to be(true)
      expect(goal_flips.map { |flip| flip["to_layers"] }).to eq([["goal"]])
    end

    it "is lowered when the agent signals the goal is met" do
      driver = driver_over(board)
      driver.start("make the specs green")
      driver.poll(unfinished)
      driver.poll(settled_with("done -- #{described_class::DONE}"))

      expect([driver.active?, raised?]).to eq([false, false])
    end

    it "is lowered at the cap, on /goal off, and on an interrupt" do
      endings = {
        cap: ->(driver) { 2.times { driver.poll(unfinished) } },
        off: lambda(&:stop),
        interrupt: ->(driver) { driver.interrupt.poll(unfinished) }
      }

      endings.each do |ending, finish|
        driver = driver_over(board, cap: 1)
        driver.start("make the specs green")
        finish.call(driver)

        expect(raised?).to be(false), "the goal layer outlived the goal's #{ending} ending"
      end
    end

    it "journals no flip for a goal layer that is already down, so an idle poll writes nothing" do
      driver = driver_over(board)
      3.times { driver.poll(unfinished) }
      driver.stop

      expect(goal_flips).to be_empty
    end
  end

  # Whether the fleet is quiet is the wiring's to answer -- a parked approval or
  # a pending human question -- so the driver is handed the question, not the fleet.
  describe "quiescence" do
    it "defers -- drives nothing, stays active -- while the fleet is unquiet" do
      open = false
      driver = described_class.new(journal:, quiescent: -> { open })
      driver.start("make the specs green")

      expect(driver.poll(settled_with("continuing"))).to be_nil
      expect(driver).to be_active
      expect(iterations).to be_empty

      open = true
      expect(driver.poll(settled_with("continuing"))).to be_a(String)
      expect(iterations.size).to eq(1)
    end
  end
end
