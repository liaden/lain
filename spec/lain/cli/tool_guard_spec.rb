# frozen_string_literal: true

require "stringio"

# The Switchboard's side of this seam. Only the two slots {ToolGuard} reads --
# a real Ledger and a real Queue, never doubles, because every claim here is
# about IDENTITY: that the guard holds the BOARD's one ledger and the BOARD's
# one queue. A double answering plausible messages cannot tell the board's
# ledger from a freshly constructed second one, which is exactly the mistake
# this file exists to catch.
class ToolGuardSpecBoard
  attr_reader :ledger, :approvals

  def initialize(approvals: nil)
    @ledger = Lain::Sensitivity::Ledger.new
    @approvals = approvals
  end
end

# A chronicle that is actually JOURNALING. `Chronicle::Null`'s
# `instrumentation.journal` IS `Channel::Null.instance`, so against it
# `journal: chronicle.instrumentation.journal` and `journal:
# Channel::Null.instance` are the same object -- every assertion passes under
# both, and the one line that carries the mask record to disk looks tested
# while nothing tests it. Only a real journal can tell them apart.
class ToolGuardSpecChronicle
  attr_reader :journal

  def initialize(journal)
    @journal = journal
  end

  def instrumentation = Lain::Agent::Instrumentation.new(journal: @journal)
end

# The tool phase's guards, and the wiring line each rests on. The stack itself
# is one expression, which is why it went untested: it looks like plumbing. It
# is not -- `board.approvals || Unqueued.instance` decides whether a run asks a
# human before sending a secret, and `board.ledger` decides whether the run has
# one release ledger or two.
RSpec.describe Lain::CLI::ToolGuard do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  # Journaling, never the Null chronicle -- see {ToolGuardSpecChronicle}.
  let(:chronicle) { ToolGuardSpecChronicle.new(journal) }
  let(:queue) { Lain::Approval::Queue.new(journal:) }

  def guards(board) = described_class.stack(chronicle, board).to_a

  def read_guard(board) = guards(board).grep(Lain::Middleware::RedactSecretReads).first

  describe "the stack it builds" do
    it "puts the write, read and listing guards in the tool phase, in that order" do
      expect(guards(ToolGuardSpecBoard.new).map(&:class))
        .to eq([Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths])
    end

    # Pinned by NAME, and asserting the guard is inert, because a stack entry
    # is only half of what makes a guard live: nothing constructs a
    # {Lain::Sensitivity} classifier yet, so the only filter there is to pass
    # is the Null. Naming it here is what stops the swap to a real filter from
    # happening silently, and what stops the example above from reading as
    # "the listing guard works" when it cannot yet withhold anything.
    it "wires the listing guard with the Null filter, because no classifier is constructed yet" do
      guard = guards(ToolGuardSpecBoard.new).grep(Lain::Middleware::WithholdSecretPaths).first

      expect(guard.filter).to be(Lain::Sensitivity::Filter::Null.instance)
    end
  end

  # The left branch of `board.approvals || Unqueued.instance`, which no example
  # reached before: every board in the suite carried a nil queue, so a wiring
  # that ALWAYS substituted the always-approve stand-in -- silently approving
  # and releasing every region of every read, in every run, with no human
  # anywhere -- passed the whole suite.
  describe "which queue the read guard parks on" do
    it "parks on the board's own queue when the run wired one" do
      board = ToolGuardSpecBoard.new(approvals: queue)

      expect(read_guard(board).queue).to be(queue)
    end

    it "is not the always-approve stand-in when a real queue exists" do
      board = ToolGuardSpecBoard.new(approvals: queue)

      expect(read_guard(board).queue).not_to be_a(Lain::Middleware::RedactSecretReads::Unqueued)
    end

    # `--yolo` is the only run with no queue, and the substitution has to happen
    # HERE: the middleware refuses a nil queue outright, so without it a yolo
    # chat raises at construction.
    it "substitutes the unqueued stand-in only when the board wired none" do
      expect(read_guard(ToolGuardSpecBoard.new).queue)
        .to be(Lain::Middleware::RedactSecretReads::Unqueued.instance)
    end
  end

  # `Telemetry::ReadRedacted` is now the ONLY record that a path was masked --
  # `SessionRecord::Replay` folds it and nothing else rebuilds the masked set --
  # so this keyword became security-bearing the moment the resume path landed.
  # Send it to `Channel::Null` instead and the live session still refuses while
  # every resumed one PERMITS the write, and the secret on disk is replaced by
  # its own placeholder.
  describe "which journal the read guard records a mask into" do
    it "records into the chronicle's journal, not a discard" do
      expect(read_guard(ToolGuardSpecBoard.new).journal).to be(journal)
    end

    it "is not the Null channel, which would drop the only record of the mask" do
      expect(read_guard(ToolGuardSpecBoard.new).journal).not_to be(Lain::Channel::Null.instance)
    end

    # The consequence, checked rather than inferred: a record written through
    # the guard's journal is one a replay can find.
    it "so a mask it records is one a resume can read back" do
      read_guard(ToolGuardSpecBoard.new).journal <<
        Lain::Telemetry::ReadRedacted.new(tool_use_id: "tu_1", path: "/repo/.env", regions: 1, released: 0)

      expect(Lain::SessionRecord::Replay.new(journal_io.string.each_line).session.masked_read?("/repo/.env"))
        .to be(true)
    end
  end

  # A fresh `Sensitivity::Ledger.new` here would answer every message the
  # board's does and hold none of its releases -- the second ledger that class's
  # own no-default rule exists to prevent. Only identity can see it.
  describe "which ledger the read guard releases into" do
    it "holds the board's ledger itself, never a second one" do
      board = ToolGuardSpecBoard.new

      expect(read_guard(board).ledger).to be(board.ledger)
    end

    # The identity assertion above is the mechanical statement; this is the
    # consequence a reader can check, and it fails against any second ledger
    # whatever its construction.
    it "so a release the guard makes is one the board can see" do
      board = ToolGuardSpecBoard.new
      regions = Lain::Sensitivity::Regions.detect("API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n")

      read_guard(board).ledger.release("/repo/.env", regions)

      expect(board.ledger.released?("/repo/.env", regions.first.digest)).to be(true)
    end
  end
end
