# frozen_string_literal: true

require "async"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ApprovalViewSpecSupport
  # The minimal effect {Approval::Queue::Pending} reads: a name, an input, and
  # the tool_use_id the park record correlates on (auto_surface_spec's fixture
  # shape, and approval_surfaces_spec's).
  Effect = Struct.new(:name, :input, :tool_use_id)

  # An editor inlet that RECORDS instead of rendering. It answers the duck
  # {Lain::Frontend::Neovim::RpcThread} publishes -- nil once the post is
  # queued, a refusal sentence when nothing took it -- so a spec can drive both
  # halves without a real editor.
  class SpyRpc
    attr_reader :posts
    attr_accessor :refusal

    def initialize(refusal: nil)
      @posts = []
      @refusal = refusal
    end

    def set_approval(lines, generation, rows)
      @posts << { lines:, generation:, rows: }
      @refusal
    end

    def last = @posts.last
  end
end

# T36: lain://approval, the editor's own surface on {Lain::Approval::Queue}.
#
# EVERY EXAMPLE THAT MATTERS DRIVES A REAL QUEUE AND A REAL PARKED FIBER. The
# claim under test is not "a buffer gets some lines" -- an implementation that
# renders and wires nothing passes that -- it is that answering from the editor
# UNPARKS the gated call with the verdict the human pressed, that a surface
# which lost the race changes nothing, and that a pending the clock already
# denied can never be resolved by a keypress on the row it left behind.
#
# The queue's timeout is short on purpose: it is the COUNTERFACTUAL. A view
# that resolved nothing leaves its pending to the fail-closed clock, which
# denies it and signs the denial `timeout` -- so "nothing happened" is visible
# in the verdict and in the journal rather than being quiet.
RSpec.describe Lain::Frontend::Neovim::ApprovalView do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:rpc) { ApprovalViewSpecSupport::SpyRpc.new }
  let(:view) { described_class.new(rpc:) }

  def effect(name = "bash", input = { "command" => "pwd" }, id = "tu_1")
    ApprovalViewSpecSupport::Effect.new(name, input, id)
  end

  def decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a

  # A real queue with real gated fibers parked in it. The block runs with every
  # pending admitted and the view already rendered, and the result carries the
  # verdicts the gated fibers finally received -- the only evidence that a
  # decision reached the agent rather than merely the journal.
  #
  # `with_timeout` bounds the whole thing, so a view that resolves nothing
  # fails in words instead of hanging: under parallel_rspec a hung worker
  # reports as "fewer examples, zero failures".
  def gated(timeout: 0.4, calls: [effect], &block)
    Sync do |task|
      queue = Lain::Approval::Queue.new(journal:, timeout:)
      parked = calls.map { |call| task.async { queue.call(call, nil) } }
      task.with_timeout(10) { answered(queue, parked, &block) }
    ensure
      parked&.each(&:stop)
    end
  end

  # The bounded half: every call admitted and rendered, then the example's own
  # gesture, then the verdicts the gated fibers actually received.
  def answered(queue, parked)
    spun_until { queue.count == parked.size }
    view.sweep(queue)
    outcome = yield(queue)
    { outcome:, verdicts: parked.map(&:wait) }
  end

  # A scheduler yield that is not a wall-clock wait: the parked fibers only
  # make progress when this one gives the reactor a turn. Deliberately NOT
  # named `pumped_until` -- that is a shared helper with a different signature
  # (spec/support/wait_until.rb), and shadowing it here would read as a call to
  # the shared one.
  def spun_until(limit: 5000)
    ticks = 0
    until yield
      raise "condition never held" if (ticks += 1) > limit

      Async::Task.current.sleep(0.001)
    end
  end

  # The stamp on the buffer the human is looking at.
  def generation = rpc.last[:generation]

  describe "the round trip that was never written" do
    it "resolves the parked call with the verdict pressed in the editor" do
      result = gated { |_queue| view.decide(1, "approve", generation:) }

      expect(result[:verdicts]).to eq([true])
      expect(result[:outcome]).to be_decided
    end

    it "denies when the human presses deny -- the two verdicts are not swapped" do
      result = gated { |_queue| view.decide(1, "deny", generation:) }

      expect(result[:verdicts]).to eq([false])
      expect(decisions.map { |record| record.fetch("verdict") }).to eq(["deny"])
    end

    it "signs its decision with its own surface, so a transcript never reads it as the terminal's" do
      gated { |_queue| view.decide(1, "approve", generation:) }

      expect(decisions.map { |record| record.fetch("surface") }).to eq([described_class::SURFACE])
      expect(described_class::SURFACE).not_to eq(Lain::Frontend::ApprovalPolicy::SURFACE)
    end

    it "answers the row the cursor is on, not the first one" do
      result = gated(calls: [effect("bash", { "command" => "one" }, "tu_1"),
                             effect("write", { "path" => "two" }, "tu_2")]) do |_queue|
        view.decide(2, "approve", generation:)
      end

      expect(result[:verdicts][1]).to be(true)
      expect(decisions.first).to include("tool" => "write", "verdict" => "approve",
                                         "surface" => described_class::SURFACE)
    end
  end

  describe "first answer wins, and the loser changes nothing" do
    it "leaves the terminal's answer standing when the terminal got there first" do
      result = gated do |queue|
        queue.first.approve(surface: Lain::Frontend::ApprovalPolicy::SURFACE)
        view.decide(1, "deny", generation:)
      end

      expect(result[:verdicts]).to eq([true])
      expect(result[:outcome]).not_to be_decided
      expect(decisions.map { |record| record.fetch("surface") })
        .to eq([Lain::Frontend::ApprovalPolicy::SURFACE])
    end

    it "names the surface that beat it and the verdict it gave, so the refusal is not a mystery" do
      result = gated do |queue|
        queue.first.approve(surface: Lain::Frontend::ApprovalPolicy::SURFACE)
        view.decide(1, "deny", generation:)
      end

      expect(result[:outcome].report).to include(Lain::Frontend::ApprovalPolicy::SURFACE, "approve")
    end

    it "refuses its OWN second answer: one row cannot be answered twice" do
      result = gated do |_queue|
        [view.decide(1, "approve", generation:), view.decide(1, "deny", generation:)]
      end

      expect(result[:outcome].map(&:decided?)).to eq([true, false])
      expect(result[:verdicts]).to eq([true])
      expect(decisions.size).to eq(1)
    end
  end

  describe "the timeout is real and fails closed" do
    let(:window) { 0.1 }

    it "never resolves a pending the clock already denied" do
      result = gated(timeout: 0.05) do |queue|
        spun_until { queue.first.nil? || queue.first.decided? }
        view.decide(1, "approve", generation:)
      end

      expect(result[:verdicts]).to eq([false])
      expect(result[:outcome]).not_to be_decided
      expect(decisions.map { |record| record.fetch("surface") })
        .to eq([Lain::Approval::Queue::TIMEOUT_SURFACE])
    end

    # THE MUTATION THAT SURVIVED EVERYTHING ELSE, and the narrow window it
    # lives in. The example below waits for the queue to be EMPTY, which a view
    # that rendered every parked call -- decided or not -- passes unchanged.
    #
    # A pending is DECIDED before it LEAVES: `Approval::Queue#settle` removes it
    # in an ensure that runs on the gated fiber, so between the answer and that
    # fiber's next turn the queue still lists a call nobody can answer any more.
    # Rendering it is a row that looks live and can only refuse. The
    # `queue.count` assertion is the precondition: without it this example goes
    # vacuous the moment the removal stops being deferred.
    it "drops a row the instant it is answered, before its parked fiber has even woken" do
      gated(timeout: window) do |queue|
        queue.first.approve(surface: "elsewhere")

        expect(queue.count).to eq(1)
        expect(queue.first).to be_decided
        view.sweep(queue)
        expect(rpc.last[:rows]).to eq(0)
      end

      expect(rpc.last[:lines]).to eq(described_class::EMPTY)
    end

    it "drops the expired row from the next rendering rather than leaving it answerable" do
      gated(timeout: 0.05) do |queue|
        expect(rpc.last[:rows]).to eq(1)
        spun_until { queue.none? }
        view.sweep(queue)
      end

      expect(rpc.last[:rows]).to eq(0)
      expect(rpc.last[:lines]).to eq(described_class::EMPTY)
    end

    # The poll interval is 60 seconds here on purpose: only the watch's OWN
    # teardown sweep can clear the row in that window, so an implementation
    # that merely polls -- and leaves a stale row when the ask's surfaces are
    # stopped -- fails this and passes nothing else differently.
    it "re-renders when its watch stops, so a torn-down ask leaves no row claiming to be answerable" do
      unpolled = described_class.new(rpc:, poll_interval: 60)

      Sync do |task|
        queue = Lain::Approval::Queue.new(journal:, timeout: 30)
        parked = task.async { queue.call(effect, nil) }
        watcher = task.async { unpolled.watch(queue) }
        task.with_timeout(10) do
          spun_until { rpc.last && rpc.last[:rows] == 1 }
          parked.stop
          spun_until { queue.none? }
          expect(rpc.last[:rows]).to eq(1)
          watcher.stop
          spun_until { rpc.last[:rows].zero? }
        end
      end
    end
  end

  describe "a gesture is resolved against the rendering the human is looking at" do
    it "refuses a rendering it no longer holds rather than guessing" do
      result = gated { |_queue| view.decide(1, "approve", generation: generation + 10_000) }

      expect(result[:outcome]).not_to be_decided
      expect(result[:outcome].report).to include(described_class::BUFFER)
      expect(result[:verdicts]).to eq([false])
    end

    it "refuses a line that names no row" do
      result = gated do |_queue|
        [view.decide(0, "approve", generation:), view.decide(9, "approve", generation:)]
      end

      expect(result[:outcome].map(&:decided?)).to eq([false, false])
      expect(result[:verdicts]).to eq([false])
    end

    it "refuses an unknown verdict rather than letting anything fall toward approve" do
      result = gated { |_queue| view.decide(1, "yes", generation:) }

      expect(result[:outcome]).not_to be_decided
      expect(result[:outcome].report).to include("approve", "deny", '"yes"')
      expect(result[:verdicts]).to eq([false])
      expect(decisions.map { |record| record.fetch("surface") })
        .to eq([Lain::Approval::Queue::TIMEOUT_SURFACE])
    end

    it "resolves an OLD rendering's row to the call that rendering drew, never to its neighbour" do
      result = gated(calls: [effect("bash", { "command" => "one" }, "tu_1"),
                             effect("write", { "path" => "two" }, "tu_2")]) do |queue|
        stale = generation
        queue.first.approve(surface: "elsewhere")
        view.sweep(queue)
        view.decide(1, "deny", generation: stale)
      end

      # Line 1 of the stale rendering was the call already answered, so the
      # gesture changes nothing -- it does NOT deny the survivor that moved up
      # into that row.
      expect(result[:outcome]).not_to be_decided
      expect(decisions.map { |record| record.fetch("tool") }).to eq(%w[bash write])
      expect(decisions.first.fetch("surface")).to eq("elsewhere")
      expect(decisions.last.fetch("surface")).to eq(Lain::Approval::Queue::TIMEOUT_SURFACE)
    end
  end

  # Nothing in this block turns on WHICH way the clock finally decided, so the
  # counterfactual window is short: what is under test is what reached the
  # editor, and a parked call that outlives the example is stopped anyway.
  describe "rendering" do
    let(:window) { 0.1 }

    it "shows the tool and its input the way the terminal prompt does" do
      gated(timeout: window) { |_queue| nil }

      expect(rpc.last[:lines].first).to include("bash", { "command" => "pwd" }.inspect)
    end

    it "names who is asking, so a fleet's rows are separable" do
      gated(timeout: window) { |_queue| nil }

      expect(rpc.last[:lines].first).to include("agent")
    end

    it "stamps how many leading lines are rows, so the editor's keys are inert on the rest" do
      gated(timeout: window) { |_queue| nil }

      expect(rpc.last[:rows]).to eq(1)
      expect(rpc.last[:lines].size).to be > 1
      expect(rpc.last[:lines].last).to include("LainApprove", "LainDeny")
    end

    it "OBSERVES the queue and never drains it, so the terminal surface still sees the pending" do
      taken = gated(timeout: window) { |queue| Async::Task.current.with_timeout(2) { queue.dequeue } }

      expect(taken[:outcome].tool).to eq("bash")
      expect(taken[:verdicts]).to eq([false])
    end

    it "posts once per CHANGE, not once per poll" do
      gated(timeout: window) do |queue|
        3.times { view.sweep(queue) }
        expect(rpc.posts.size).to eq(1)
      end
    end

    it "keeps retrying while the editor refuses the post, so a full queue is not a lost rendering" do
      rpc.refusal = described_class::DETACHED

      gated(timeout: window) do |queue|
        view.sweep(queue)
        expect(rpc.posts.size).to eq(2)
        rpc.refusal = nil
        view.sweep(queue)
        view.sweep(queue)
        expect(rpc.posts.size).to eq(3)
      end
    end

    it "hands out no rendering the editor refused, so a gesture citing one is refused too" do
      rpc.refusal = described_class::DETACHED

      result = gated(timeout: window) { |_queue| view.decide(1, "approve", generation: rpc.last[:generation]) }

      expect(result[:outcome]).not_to be_decided
      expect(result[:verdicts]).to eq([false])
    end
  end

  describe "the surface nobody wired" do
    it "refuses the render honestly rather than reporting one that never happened" do
      expect(described_class::Detached.set_approval([], 1, 0)).to eq(described_class::DETACHED)
    end

    it "is the DEFAULT, so an unwired view can never claim a row is on screen" do
      unwired = described_class.new

      Sync do |task|
        queue = Lain::Approval::Queue.new(journal:, timeout: 0.4)
        parked = task.async { queue.call(effect, nil) }
        task.with_timeout(10) do
          spun_until { queue.one? }
          unwired.sweep(queue)
          expect(unwired.decide(1, "approve", generation: 1)).not_to be_decided
          expect(parked.wait).to be(false)
        end
      end
    end
  end
end
