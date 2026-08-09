# frozen_string_literal: true

require "stringio"

# The Switchboard's side of this seam. Only the two slots {ToolGuard} reads --
# a real Ledger and a real Queue, never doubles, because every claim here is
# about IDENTITY: that the guard holds the BOARD's one ledger and the BOARD's
# one queue. A double answering plausible messages cannot tell the board's
# ledger from a freshly constructed second one, which is exactly the mistake
# this file exists to catch.
class ToolGuardSpecBoard
  attr_reader :ledger, :approvals, :sensitivity

  # `sensitivity` is a REAL {Lain::Sensitivity::Policy} over a REAL classifier
  # for this file's own reason, one slot over: T23's claim is that the listing
  # guard filters through the BOARD's policy rather than through a second
  # filter built beside it, and a double answering `filter` cannot tell those
  # apart. The default is the live one because that is what {CLI::Wiring} now
  # builds; a `--yolo`-shaped board with no classifier passes the Null.
  def initialize(approvals: nil, sensitivity: nil)
    @ledger = Lain::Sensitivity::Ledger.new
    @approvals = approvals
    @sensitivity = sensitivity || Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: "/home/tester", cwd: "/home/tester/project")
    )
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

  def read_call(path) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => path })

  describe "the stack it builds" do
    it "puts the write, read and listing guards in the tool phase, in that order" do
      expect(guards(ToolGuardSpecBoard.new).map(&:class))
        .to eq([Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths])
    end

    # This example was the Null pin -- "wires the listing guard with the Null
    # filter, because no classifier is constructed yet" -- and it existed so
    # T23's swap could not happen silently. It has happened, so the pin is
    # INVERTED rather than deleted: a stack entry is still only half of what
    # makes a guard live, and this is the other half.
    #
    # Identity against `board.sensitivity.filter`, never `be_a(Filter)`: a
    # filter built HERE from a freshly constructed classifier would be a real
    # Filter, would answer every message, and would judge a DIFFERENT set of
    # paths than the gate -- the run enumerating a path its own gate refuses to
    # read. Only sameness can see that, and the shape makes it structural: the
    # Policy exposes no classifier, so this is the only filter reachable.
    it "wires the listing guard with the board's own filter, over the classifier the gate reads" do
      board = ToolGuardSpecBoard.new
      guard = guards(board).grep(Lain::Middleware::WithholdSecretPaths).first

      expect(guard.filter).to be(board.sensitivity.filter)
      expect(guard.filter).not_to be(Lain::Sensitivity::Filter::Null.instance)
    end

    # The consequence a reader can check, and it fails against any second
    # filter whatever its construction: the row the gate would gate is the row
    # this guard drops.
    it "so a path the gate gates is a path the listing guard withholds" do
      board = ToolGuardSpecBoard.new
      guard = guards(board).grep(Lain::Middleware::WithholdSecretPaths).first
      gated = "/home/tester/project/.env"

      expect(board.sensitivity.gates?(read_call(gated))).to be(true)
      expect(guard.filter.sift([gated]) { |row| [row] }.withheld.map(&:reason)).to eq([:credential])
    end

    # The other half of the Null story: a board that resolved no classifier
    # produces byte-identical listings, with no `if filter` anywhere.
    it "passes the Null filter through when the board wired no classifier" do
      board = ToolGuardSpecBoard.new(sensitivity: Lain::Sensitivity::Policy::Null.instance)
      guard = guards(board).grep(Lain::Middleware::WithholdSecretPaths).first

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
