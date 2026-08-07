# frozen_string_literal: true

require "async"
require "stringio"

# E3's fixture, kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module SessionConcurrencySpecSupport
  # A parallel-safe read tool built on the entered/release Async::Queue idiom
  # (spec/lain/tools/parallel_safety_spec.rb): it announces entry, parks until
  # released, and only THEN records its read -- so both tools are provably
  # mid-dispatch before either touches the shared session, and the record_read
  # calls land while the sibling fiber is still in flight. Deterministic where
  # a real ReadFile would not be: a read completing inside one scheduler tick
  # exercises no interleaving at all.
  class GatedReadTool < Lain::Tool
    def initialize(name:, path:, entered:, release:, complete: true)
      super()
      @tool_name = name
      @path = path
      @complete = complete
      @entered = entered
      @release = release
    end

    def name = @tool_name
    def description = "test double: parks mid-dispatch, then records a session read"
    def input_schema = { type: :object, properties: {} }
    def parallel_safe? = true

    protected

    def perform(_input, invocation)
      @entered.enqueue(@tool_name)
      @release.dequeue
      session_of(invocation).record_read(@path, complete: @complete)
      Lain::Tool::Result.ok(@tool_name)
    end
  end
end

# E3: pins the fiber-safety invariant E1/E2's concurrency rests on.
# {Session::Journaled#record_read} is a check-then-mutate pair (read? then
# record_read then a conditional journal write), and its documented claim
# (session.rb) is that no yield point sits between the check and the mutate --
# both are pure Ruby, no IO -- so two fibers reading the same path can never
# both see "first". This spec makes that claim bite: it was proven RED by
# temporarily inserting a `sleep` (a scheduler yield) between the check and
# the mutate, which made both fibers journal the same path, then restored.
#
# ESCALATION RULE (the card's whole point): if this spec ever needs a NEW lock
# in Session to pass, the no-yield claim has failed and E1/E2 are unsound --
# that diagnosis belongs to a human, not to a patch.
RSpec.describe "Session read-set coherence under concurrent gather" do
  it "records one path once and journals exactly one session_read across two gathered readers" do
    journal_io = StringIO.new
    journal = Lain::Journal.new(io: journal_io)
    inner = Lain::Session.new
    session = Lain::Session::Journaled.new(session: inner, journal:)

    entered = Async::Queue.new
    release = Async::Queue.new
    path = "/tmp/shared.rb"
    toolset = Lain::Toolset.new(
      [SessionConcurrencySpecSupport::GatedReadTool.new(name: "reader_a", path:, entered:, release:),
       SessionConcurrencySpecSupport::GatedReadTool.new(name: "reader_b", path:, entered:, release:)]
    )
    runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new(toolset:))
    response = tool_response(["tu_1", "reader_a", {}], ["tu_2", "reader_b", {}])

    Sync do |task|
      run = task.async { runner.run(response, context: session) }

      # Both readers are provably mid-dispatch before either records: the
      # timeout is a failure bound (a sequential dispatch would park reader_a
      # and never enter reader_b), not a synchronization.
      overlap = task.with_timeout(1) { [entered.dequeue, entered.dequeue] }
      expect(overlap).to contain_exactly("reader_a", "reader_b")
      release.enqueue(:go)
      release.enqueue(:go)

      blocks = run.wait
      expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
      expect(blocks).to all(include("is_error" => false))
    ensure
      run&.stop
    end

    # The read-set holds the path once (a Set, queried through both layers)...
    expect(session.read?(path)).to be(true)
    expect(inner.read?(path)).to be(true)
    # ...and the journal holds exactly ONE session_read for it: the second
    # fiber saw "already read", because check-and-mutate ran without a yield.
    reads = Lain::Journal.records(journal_io.string.lines, type: "session_read").to_a
    expect(reads.map { |record| record["path"] }).to eq([path])
  end
end

# T22: the completeness bit's monotonicity, driven under the SAME real gather.
#
# The card's first escalation trigger is explicitly about two sibling fibers
# racing a complete read into a partial one, and every other monotonicity
# example in this suite is SEQUENTIAL -- two calls in a row on one fiber. That
# is a weaker claim than the one the design makes. A refactor of {ReadSet} to a
# single `Hash{path => bool}` that downgrades only under interleaving passes
# every sequential AC and fails only here, which is exactly why these live in
# this file rather than beside them.
#
# Same escalation rule as above: if these can only pass by adding a lock to
# Session, the no-yield claim has failed and that is a diagnosis for a human.
RSpec.describe "Session read completeness under concurrent gather" do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:inner) { Lain::Session.new }
  let(:session) { Lain::Session::Journaled.new(session: inner, journal:) }
  let(:path) { "/tmp/shared.rb" }

  let(:entered) { Async::Queue.new }
  let(:release) { Async::Queue.new }

  def read_records = Lain::Journal.records(journal_io.string.lines, type: "session_read").to_a
  def replayed = Lain::SessionRecord::Replay.new(journal_io.string.each_line).session

  def reader(name, complete)
    SessionConcurrencySpecSupport::GatedReadTool.new(name:, path:, complete:, entered:, release:)
  end

  def gather(complete_a:, complete_b:)
    toolset = Lain::Toolset.new([reader("reader_a", complete_a), reader("reader_b", complete_b)])
    runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new(toolset:))
    response = tool_response(["tu_1", "reader_a", {}], ["tu_2", "reader_b", {}])

    Sync { |task| both_land(task, runner, response) }
  end

  # Both readers are provably mid-dispatch before either records: the timeout
  # is a failure bound (a sequential dispatch would park reader_a and never
  # enter reader_b), not a synchronization.
  def both_land(task, runner, response)
    run = task.async { runner.run(response, context: session) }
    expect_both_mid_dispatch(task)
    2.times { release.enqueue(:go) }
    expect(run.wait).to all(include("is_error" => false))
  ensure
    run&.stop
  end

  def expect_both_mid_dispatch(task)
    expect(task.with_timeout(1) { [entered.dequeue, entered.dequeue] })
      .to contain_exactly("reader_a", "reader_b")
  end

  it "cannot race a complete read down to a partial one (complete recorded first)" do
    gather(complete_a: true, complete_b: false)

    expect(session.read?(path)).to be(true)
    expect(session.partially_read?(path)).to be(false)
    expect(replayed.read?(path)).to be(true)
  end

  it "cannot race a complete read down to a partial one (partial recorded first)" do
    gather(complete_a: false, complete_b: true)

    expect(session.read?(path)).to be(true)
    expect(replayed.read?(path)).to be(true)
  end

  # Two partial reads stay partial and journal ONCE -- the dedupe has to hold
  # under interleaving too, not only on one fiber.
  it "leaves a doubly-partial concurrent read partial, and journals it once" do
    gather(complete_a: false, complete_b: false)

    expect(session.partially_read?(path)).to be(true)
    expect(read_records.size).to eq(1)
    expect(replayed.partially_read?(path)).to be(true)
  end
end
