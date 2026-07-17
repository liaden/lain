# frozen_string_literal: true

require "json"
require "stringio"

# The approval queue behind Handler::Gate (I4): a gated tool call enqueues a
# Pending approval and parks its fiber on Gate's synchronous policy seam; a
# surface fiber answers, first answer wins, every decision journals, and an
# unanswered window denies (the fail-closed doctrine gate.rb pins).
RSpec.describe Lain::Approval::Queue do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:queue) { described_class.new(journal:) }

  def tool_call(name = "dangerous", input = { "text" => "boom" })
    Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)
  end

  def decision_records
    Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a
  end

  # The same tool-builder shape gate_spec uses: a tier-3 tool is one that
  # answers requires_approval? true about itself.
  def gated_tool(runs)
    Class.new(Lain::Tool) do
      def name = "dangerous"
      def description = "the dangerous tool"
      def requires_approval? = true
      def input_schema = { type: :object, properties: { text: { type: :string } }, required: [] }
      define_method(:perform) do |input, _invocation|
        runs << input
        Lain::Tool::Result.ok(input.fetch(:text, "ran"))
      end
    end.new
  end

  def gate_over(runs)
    live = Lain::Effect::Handler::Live.new(toolset: Lain::Toolset.new([gated_tool(runs)]))
    Lain::Effect::Handler::Gate.new(policy: queue, inner: live)
  end

  describe "a gated call parks on the queue" do
    it "enqueues, parks the calling fiber, and an approval resolves it into the tool run" do
      runs = []
      gate = gate_over(runs)

      Sync do |task|
        run = task.async { gate.call(tool_call("dangerous", { text: "went through" })) }

        # The gated fiber ran up to its await: the effect is enqueued, parked,
        # and the tool has NOT run.
        expect(queue.count).to eq(1)
        expect(runs).to be_empty

        pending = queue.dequeue
        expect(pending).to have_attributes(requester: "agent", tool: "dangerous")

        pending.approve(surface: "spec")
        expect(run.wait).to eq(Lain::Tool::Result.ok("went through"))
      end

      expect(runs.length).to eq(1)
    end

    it "parks the fiber, not the reactor: a sibling fiber proceeds while the call waits" do
      log = []
      gate = gate_over([])

      Sync do |task|
        run = task.async do
          log << :gated
          gate.call(tool_call)
          log << :resolved
        end
        task.async { log << :worker_ran }

        expect(log).to eq(%i[gated worker_ran])
        queue.dequeue.approve(surface: "spec")
        run.wait
        expect(log).to eq(%i[gated worker_ran resolved])
      end
    end

    it "returns the refusal Result on deny, and the tool never runs" do
      runs = []
      gate = gate_over(runs)

      Sync do |task|
        run = task.async { gate.call(tool_call) }
        queue.dequeue.deny(surface: "spec")

        result = run.wait
        expect(result).to have_attributes(is_error: true)
        expect(result.content).to match(/denied/)
      end

      expect(runs).to be_empty
    end

    it "empties its pending list once the decision settles" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.approve(surface: "spec")
        run.wait
      end

      expect(queue.count).to eq(0)
    end
  end

  describe "decisions are journaled evidence" do
    it "journals surface, verdict, and decision latency" do
      now = 100.0
      queue = described_class.new(journal:, requester: "the-agent", clock: -> { now })

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        now = 102.5
        queue.dequeue.approve(surface: "tty")
        expect(run.wait).to be(true)
      end

      expect(decision_records).to contain_exactly(
        a_hash_including("type" => "approval_decision", "requester" => "the-agent",
                         "tool" => "dangerous", "surface" => "tty", "verdict" => "approve",
                         "latency" => 2.5, "timed_out" => false)
      )
    end

    it "journals a denial under the same record type" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        queue.dequeue.deny(surface: "tty")
        expect(run.wait).to be(false)
      end

      expect(decision_records).to contain_exactly(a_hash_including("verdict" => "deny", "timed_out" => false))
    end
  end

  describe "timeout is deny" do
    let(:queue) { described_class.new(journal:, timeout: 0.01) }

    it "denies when no surface answers within the window (fail-closed holds)" do
      verdict = Sync { queue.call(tool_call, nil) }

      expect(verdict).to be(false)
    end

    it "journals the timeout as a timed-out denial" do
      Sync { queue.call(tool_call, nil) }

      expect(decision_records).to contain_exactly(
        a_hash_including("verdict" => "deny", "surface" => "timeout", "timed_out" => true)
      )
    end

    it "returns the refusal Result through the gate" do
      runs = []
      live = Lain::Effect::Handler::Live.new(toolset: Lain::Toolset.new([gated_tool(runs)]))
      gate = Lain::Effect::Handler::Gate.new(policy: queue, inner: live)

      result = Sync { gate.call(tool_call) }

      expect(result).to have_attributes(is_error: true)
      expect(runs).to be_empty
    end
  end

  # The Conductor#supervise grace/Ctrl-C path stops the gated fiber while it is
  # parked. An asked-and-abandoned approval must not linger: no leak in the
  # pending list, no ghost delivered to a surface (a human prompted to approve
  # a call nobody awaits), and no journal hole (probes/i4/probe_cancelled_requester.rb).
  describe "a cancelled requester abandons its pending" do
    def dequeue_or_nothing(task)
      task.with_timeout(0.05) { queue.dequeue }
    rescue Async::TimeoutError
      :nothing_delivered
    end

    it "removes the abandoned pending from the parked list" do
      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        expect(queue.count).to eq(1)

        run.stop

        expect(queue.count).to eq(0)
      end
    end

    it "journals the abandonment, so an asked-and-unanswered approval leaves no hole" do
      Sync do |task|
        task.async { queue.call(tool_call, nil) }.stop
      end

      expect(decision_records).to contain_exactly(
        a_hash_including("verdict" => "deny", "surface" => "abandoned", "timed_out" => false)
      )
    end

    it "never delivers the orphan to a surface" do
      Sync do |task|
        task.async { queue.call(tool_call, nil) }.stop

        expect(dequeue_or_nothing(task)).to eq(:nothing_delivered)
      end
    end

    it "skips the abandoned pending and delivers the next live one" do
      Sync do |task|
        task.async { queue.call(tool_call("dangerous", { "n" => 1 }), nil) }.stop
        live = task.async { queue.call(tool_call("dangerous", { "n" => 2 }), nil) }

        pending = queue.dequeue
        expect(pending.input).to eq({ "n" => 2 })

        pending.approve(surface: "tty")
        expect(live.wait).to be(true)
      end
    end

    it "makes a late surface answer a no-op on an abandoned pending" do
      pending = nil

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        pending = queue.first
        run.stop
      end

      expect(pending.approve(surface: "tty")).to be(false)
      expect(pending).to have_attributes(surface: "abandoned", decision: :deny)
    end
  end

  describe "first answer wins" do
    it "makes the second surface's answer a no-op: single-shot resolution, no double-run" do
      runs = []
      gate = gate_over(runs)

      Sync do |task|
        run = task.async { gate.call(tool_call) }

        # Two surfaces watching ONE pending approval: one drew it from the
        # queue, the other looked at the pending list.
        first_surface = queue.dequeue
        second_surface = queue.first

        expect(first_surface.approve(surface: "tty")).to be(true)
        expect(second_surface.deny(surface: "nvim")).to be(false)
        expect(second_surface).to have_attributes(surface: "tty", decision: :approve)
        run.wait
      end

      expect(runs.length).to eq(1)
      expect(decision_records).to contain_exactly(a_hash_including("surface" => "tty", "verdict" => "approve"))
    end

    it "keeps a late surface answer a no-op after the timeout already denied" do
      queue = described_class.new(journal:, timeout: 0.01)
      pending = nil

      Sync do |task|
        run = task.async { queue.call(tool_call, nil) }
        pending = queue.dequeue
        expect(run.wait).to be(false)
      end

      expect(pending.approve(surface: "tty")).to be(false)
      expect(pending).to have_attributes(surface: "timeout", decision: :deny)
    end
  end
end
