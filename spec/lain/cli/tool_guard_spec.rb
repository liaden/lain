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
  # for this file's own reason, one slot over: the claim is that the listing
  # guard filters through the BOARD's policy rather than through a second
  # filter built beside it, and a double answering `filter` cannot tell those
  # apart. The default is the live one because that is what {CLI::Wiring} now
  # builds; a queueless board with no classifier passes the Null.
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

# A queue that refuses every release, so the fail-open block below can carry a
# CONTROL arm. Without one, "the secret came through" is equally well explained
# by a region detector that never fired, and the example would pin nothing.
class ToolGuardSpecDecliningQueue
  module Verdict
    def self.approved? = false
  end

  # `outstanding:` is accepted and discarded, but cannot become the unused-
  # argument underscore: it is a KEYWORD, so the name is the duck.
  def adjudicate(_effect, _context, outstanding: nil) # rubocop:disable Lint/UnusedMethodArgument
    Verdict
  end
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
    # the swap away from it could not happen silently. It has happened, so the
    # pin is INVERTED rather than deleted: a stack entry is still only half of
    # what makes a guard live, and this is the other half.
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

    # An unattended run is the only run with no queue, and the substitution has
    # to happen HERE: the middleware refuses a nil queue outright, so without it
    # a `--non-interactive` chat raises at construction.
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

  # {Lain::Middleware::RedactSecretReads::Unqueued}'s docstring is the
  # load-bearing account of this run's ONE fail-open, and until this block
  # nothing executable joined its two halves: `switchboard_spec` pins the deny,
  # `redact_secret_reads_spec` pins the approve over a HAND-BUILT Unqueued, and
  # no board ever reached both. Either half could move and the docstring would
  # go stale in silence -- the exact failure this card exists to remove.
  #
  # So: ONE unattended board, both halves, off the real Switchboard. This cannot
  # go red today, and that is the point -- round 11's deferred flip to deny
  # lands here as a red example on purpose, instead of quietly leaving a lying
  # comment behind.
  describe "the fail-open an unattended run ships with", :seam do
    let(:base) { Lain::Toolset.new([Lain::Tools::Bash.new, Lain::Tools::ReadFile.new]) }
    let(:board) do
      Lain::CLI::Switchboard.new(journal:, model: "claude-opus-4-8", toolset: base, attended: false)
    end
    let(:secret) { "AKIAIOSFODNN7EXAMPLE" }
    let(:body) { "harmless line\naws_access_key_id = #{secret}\ntail\n" }

    # The real read, driven through a real guard stack over a real file --
    # a seam, not a double: what is under test is what the BYTES do.
    def bytes_read_through(stack, path)
      Sync do
        stack.call({ effect: read_call(path), context: Lain::Session.new }) do |inner|
          invocation = Lain::Tool::Invocation.new(tool_use_id: inner.fetch(:effect).tool_use_id,
                                                  context: inner.fetch(:context))
          inner.merge(result: Lain::Tools::ReadFile.new.call(inner.fetch(:effect).input, invocation))
        end
      end.fetch(:result).content
    end

    def with_secret_file
      Dir.mktmpdir do |dir|
        path = File.join(dir, "creds.txt")
        File.write(path, body)
        yield path
      end
    end

    # The single condition both halves read. Asserted first because if this ever
    # stops being nil, neither example below is testing what it says.
    it "wires no approval queue at all" do
      expect(board.approvals).to be_nil
    end

    it "DENIES every gated call, because nobody is there to ask" do
      told = board.gate(inner: Lain::Effect::Handler::Live.new(toolset: board.toolset.current))
                  .call(Lain::Effect::ToolCall.new(tool_use_id: "tu_gate", name: "bash",
                                                   input: { "command" => "ls" }),
                        Lain::Session.new)

      expect(told.is_error).to be(true)
      expect(told.content).to include("no approval is possible")
    end

    # The other direction, off the SAME board: the secret is released whole.
    it "and APPROVES every sensitive region, releasing the bytes verbatim" do
      with_secret_file do |path|
        content = bytes_read_through(described_class.stack(chronicle, board), path)

        expect(content).to include(secret)
        expect(content).not_to include("<redacted")
      end
    end

    # The control: identical bytes, identical guard, a queue that says no. It
    # masks -- so the release above is a real decision, not a detector asleep.
    it "is a real release -- the same read masks when a queue declines" do
      with_secret_file do |path|
        guard = Lain::Middleware::RedactSecretReads.new(ledger: board.ledger,
                                                        queue: ToolGuardSpecDecliningQueue.new,
                                                        journal: chronicle.instrumentation.journal)

        content = bytes_read_through(Lain::Middleware::Stack.new([guard]), path)

        expect(content).not_to include(secret)
        expect(content).to include("<redacted")
      end
    end
  end
end
