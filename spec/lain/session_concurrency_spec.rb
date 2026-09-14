# frozen_string_literal: true

require "async"
require "stringio"

# This spec's fixture, kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
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

  # A journal whose write IS a yield point, which a StringIO-backed one never
  # is. Half of {Session#record_read}'s ordering claim -- that the journal
  # write runs AFTER the Set mutation -- is invisible without this: swap those
  # two lines against a StringIO journal and every other example in this file
  # still passes, because the write between the check and the mutate cannot
  # hand the scheduler to the sibling fiber. Against this one it can, and two
  # fibers then both see "first".
  class YieldingJournal
    def initialize = @records = []

    attr_reader :records

    def <<(record)
      sleep 0
      @records << record
      self
    end
  end
end

# Pins the fiber-safety invariant the gathered-tool concurrency rests on.
# {Session#record_read} is a check-then-mutate pair (the read-set is asked
# whether this is a transition, then mutated, then a journal line is
# conditionally written), and its documented claim (session.rb) is that no
# yield point sits between the check and the mutate --
# both are pure Ruby, no IO -- so two fibers reading the same path can never
# both see "first". This spec makes that claim bite: it was proven RED by
# temporarily inserting a `sleep` (a scheduler yield) between the check and
# the mutate, which made both fibers journal the same path, then restored.
#
# ESCALATION RULE (the card's whole point): if this spec ever needs a NEW lock
# in Session to pass, the no-yield claim has failed and the concurrent gather
# is unsound -- that diagnosis belongs to a human, not to a patch.
RSpec.describe "Session read-set coherence under concurrent gather" do
  it "records one path once and journals exactly one session_read across two gathered readers" do
    journal_io = StringIO.new
    journal = Lain::Journal.new(io: journal_io)
    session = Lain::Session.new(journal:)

    entered = Async::Queue.new
    release = Async::Queue.new
    path = "/tmp/shared.rb"
    toolset = Lain::Toolset.new(
      [SessionConcurrencySpecSupport::GatedReadTool.new(name: "reader_a", path:, entered:, release:),
       SessionConcurrencySpecSupport::GatedReadTool.new(name: "reader_b", path:, entered:, release:)]
    )
    runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new, toolset:)
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

    # The read-set holds the path once...
    expect(session.read?(path)).to be(true)
    expect(session.reads).to eq([path])
    # ...and the journal holds exactly ONE session_read for it: the second
    # fiber saw "already read", because check-and-mutate ran without a yield.
    reads = Lain::Journal.records(journal_io.string.lines, type: "session_read").to_a
    expect(reads.map { |record| record["path"] }).to eq([path])
  end

  # The sibling claim, and the one the dedupe could break: two fibers reading
  # DIFFERENT files must each be recorded and each journaled. A transition
  # check that consulted "has anything been read" rather than "has THIS path
  # been read" passes the same-path example above and loses a read here.
  it "records and journals both paths when two gathered readers read different files" do
    journal_io = StringIO.new
    journal = Lain::Journal.new(io: journal_io)
    session = Lain::Session.new(journal:)

    entered = Async::Queue.new
    release = Async::Queue.new
    toolset = Lain::Toolset.new(
      [SessionConcurrencySpecSupport::GatedReadTool.new(name: "reader_a", path: "/tmp/a.rb", entered:, release:),
       SessionConcurrencySpecSupport::GatedReadTool.new(name: "reader_b", path: "/tmp/b.rb", entered:, release:)]
    )
    runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new, toolset:)
    response = tool_response(["tu_1", "reader_a", {}], ["tu_2", "reader_b", {}])

    Sync do |task|
      run = task.async { runner.run(response, context: session) }

      # Both readers are provably mid-dispatch before either records: the
      # timeout is a failure bound, not a synchronization.
      expect(task.with_timeout(1) { [entered.dequeue, entered.dequeue] })
        .to contain_exactly("reader_a", "reader_b")
      2.times { release.enqueue(:go) }
      expect(run.wait).to all(include("is_error" => false))
    ensure
      run&.stop
    end

    expect(session.read?("/tmp/a.rb")).to be(true)
    expect(session.read?("/tmp/b.rb")).to be(true)
    reads = Lain::Journal.records(journal_io.string.lines, type: "session_read").to_a
    expect(reads.map { |record| record["path"] }).to contain_exactly("/tmp/a.rb", "/tmp/b.rb")
  end

  # The ordering half of the claim, which the two examples above cannot reach:
  # they pin that nothing yields BETWEEN the check and the mutate, and this
  # pins that the journal write is not moved ABOVE the mutate. Proven to bite
  # the same two ways as the rest: swapping those two lines makes both fibers
  # journal the same path, and no lock is needed to make it pass.
  it "journals one line for one path even when the journal write yields the fiber" do
    journal = SessionConcurrencySpecSupport::YieldingJournal.new
    session = Lain::Session.new(journal:)

    entered = Async::Queue.new
    release = Async::Queue.new
    path = "/tmp/shared.rb"
    toolset = Lain::Toolset.new(
      [SessionConcurrencySpecSupport::GatedReadTool.new(name: "reader_a", path:, entered:, release:),
       SessionConcurrencySpecSupport::GatedReadTool.new(name: "reader_b", path:, entered:, release:)]
    )
    runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new, toolset:)
    response = tool_response(["tu_1", "reader_a", {}], ["tu_2", "reader_b", {}])

    Sync do |task|
      run = task.async { runner.run(response, context: session) }

      expect(task.with_timeout(1) { [entered.dequeue, entered.dequeue] })
        .to contain_exactly("reader_a", "reader_b")
      2.times { release.enqueue(:go) }
      expect(run.wait).to all(include("is_error" => false))
    ensure
      run&.stop
    end

    expect(session.read?(path)).to be(true)
    expect(journal.records.grep(Lain::Telemetry::SessionRead).map(&:path)).to eq([path])
  end
end

# The completeness bit's monotonicity, driven under the SAME real gather.
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
  let(:session) { Lain::Session.new(journal:) }
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
    runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new, toolset:)
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
