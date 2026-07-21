# frozen_string_literal: true

require "async"
require "stringio"

# E3's fixture, kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module QueueConcurrencySpecSupport
  # A tool that is BOTH approval-gated and parallel-safe -- a combination no
  # shipped tool claims today (the E1 audit opted no gated tool in), declared
  # here deliberately: the queue must host N concurrently parked callers
  # whatever generates them, and gathered dispatch is the cheapest way to
  # produce two gated fibers parked at once through the real
  # ToolRunner -> Gate -> Queue path.
  class GatedApprovalTool < Lain::Tool
    def initialize(name:)
      super()
      @tool_name = name
    end

    def name = @tool_name
    def description = "test double: a parallel-safe tool that requires approval"
    def input_schema = { type: :object, properties: {} }
    def parallel_safe? = true
    def requires_approval? = true

    protected

    def perform(_input, _context)
      Lain::Tool::Result.ok("#{@tool_name} ran")
    end
  end
end

# E3: pins the fiber-safety invariant on {Approval::Queue}'s side. `@parked`
# is a plain Array on purpose: its mutations (`<<` in admit, `delete` in
# settle's ensure) are straight-line Ruby with no yield point, and every park
# happens on an Async primitive BETWEEN those mutations -- so N gated fibers
# admit N independent pendings with no lock. This spec makes that bite: it was
# proven RED by temporarily rewriting admit's push as a read-yield-write
# (`snapshot = @parked; sleep; @parked = snapshot + [pending]`), a classic
# lost update that dropped one of the two concurrent pendings from the parked
# list, then restored.
#
# ESCALATION RULE (the card's whole point): if this spec ever needs a NEW lock
# in Approval::Queue to pass, the between-IO-yields claim has failed and E1/E2
# are unsound -- that diagnosis belongs to a human, not to a patch.
RSpec.describe "Approval::Queue pendings under concurrent gather" do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  # Bounded is a number, not a mood (the flood spec's precedent): gated_a's
  # 0.1s timeout window opens at its park, and the sibling fiber's approve is
  # scheduled within microseconds of the two dequeues -- ~5 orders of
  # magnitude of margin, wall-clock rather than structural. What could eat it
  # is a >100ms process stall (major GC, CI preemption) landing inside that
  # microseconds-wide critical window; the injectable clock cannot close this,
  # because the AC demands the REAL timeout path for gated_b.
  let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 0.1) }

  def runner_over(queue)
    toolset = Lain::Toolset.new(
      [QueueConcurrencySpecSupport::GatedApprovalTool.new(name: "gated_a"),
       QueueConcurrencySpecSupport::GatedApprovalTool.new(name: "gated_b")]
    )
    live = Lain::Effect::Handler::Live.new(toolset:)
    Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Gate.new(policy: queue, inner: live))
  end

  it "parks two independent pendings; one approved resolves ok, one timed out errors, both journal" do
    runner = runner_over(queue)
    response = tool_response(["tu_1", "gated_a", {}], ["tu_2", "gated_b", {}])

    blocks = Sync do |task|
      run = task.async { runner.run(response, context: nil) }

      # Both gated fibers are parked before either is decided: two DISTINCT
      # pendings, both visible on the sibling surface (the parked list) at
      # once. The timeout is a failure bound -- a sequential dispatch would
      # park gated_a's fiber and never enqueue gated_b.
      pendings = task.with_timeout(1) { [queue.dequeue, queue.dequeue] }
      expect(pendings.map(&:tool)).to contain_exactly("gated_a", "gated_b")
      expect(queue.count).to eq(2)

      pendings.find { |pending| pending.tool == "gated_a" }.approve(surface: "spec")
      run.wait
    ensure
      run&.stop
    end

    expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
    approved, timed_out = blocks
    expect(approved).to include("is_error" => false, "content" => "gated_a ran")
    expect(timed_out).to include("is_error" => true)
    expect(timed_out["content"]).to match(/denied/)

    # Two approval_decision records, distinct verdicts, each pending settled
    # on its own terms: the approve by the surface, the deny by the clock.
    decisions = Lain::Journal.records(journal_io.string.lines, type: "approval_decision").to_a
    expect(decisions.map { |record| record.values_at("tool", "verdict", "surface", "timed_out") })
      .to contain_exactly(["gated_a", "approve", "spec", false],
                          ["gated_b", "deny", "timeout", true])
    expect(queue.count).to eq(0)
  end
end
