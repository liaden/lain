# frozen_string_literal: true

require "tmpdir"

# A tree pair whose moves a spec states outright, so the log's planning over a
# shadow turn is visible without a git repository behind it.
module SnapshotLogSpecSupport
  class Pair
    attr_reader :moves

    def initialize(moves: [], ignored: [])
      @moves = moves
      @ignored = ignored
    end

    def staged? = true

    def moved? = true

    def keys = @moves.map(&:key)

    def ignored?(key) = @ignored.include?(key)
  end

  # A write-set scope that lands every write, as a shadow turn whose trees
  # moved does even when its file map repeats the last one.
  class Landing < Lain::Workspace::Snapshot::Scope::WriteSet
    def unchanged?(**) = false
  end
end

RSpec.describe Lain::Workspace::SnapshotLog do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  let(:store) { Lain::Store.new }
  let(:events) { [] }
  let(:log) { described_class.new(observer: ->(event) { events << event }) }
  let(:writer) { Lain::Workspace::Snapshot.new(root: dir) }
  let(:write_set) { [] }
  let(:start) { Lain::Timeline.empty(store:) }

  # A structured tool's write: the bytes land and the path joins the write-set.
  def put(name, bytes)
    path = File.join(dir, name)
    File.binwrite(path, bytes)
    write_set << path unless write_set.include?(path)
  end

  # One committed tool-result turn, then the settle's snapshot, recorded with
  # the turn's trees -- the order {Lain::Agent::SnapshotSlot} keeps.
  def turn(timeline, pair: Lain::Workspace::Snapshot::Scope::NoTrees, by: writer)
    timeline.commit(role: :user, content: [{ "type" => "text", "text" => "turn" }]).tap do |committed|
      event = by.write(timeline: committed, paths: write_set)
      log.record(event, pair:) if event
    end
  end

  def side(bytes) = Lain::Workspace::Revert::Side.new(bytes:, mode: nil)

  def move(key, before, after)
    Lain::Workspace::Revert::Move.new(key:, before: before && side(before), after: after && side(after))
  end

  def blocker(key, reason) = Lain::Workspace::Revert::Blocker.new(key:, reason:)

  describe "recording" do
    it "keys each snapshot by the turn digest it names as its cause" do
      put("a.rb", "a v1")
      first = turn(start)

      expect(log.map(&:turn)).to eq([first.head_digest])
      expect(log.first.snapshot).to eq(events.first.digest)
    end

    it "holds digests only, as a deeply frozen value, since the bytes already live in the Store" do
      put("a.rb", "a v1")
      turn(start)

      expect(log.first.files.keys).to eq(["a.rb"])
      expect(Ractor.shareable?(log.first)).to be(true)
    end

    it "tees every snapshot it records on to the observer it was given" do
      put("a.rb", "a v1")
      turn(start)

      expect(events.map(&:kind)).to eq([:snapshot])
    end

    # A rebound writer starts with no memory of what the last one wrote, so its
    # first snapshot can repeat the previous one byte for byte. Recording it
    # would make one /undo restore nothing at all.
    it "records no second entry for a map identical to the one before, when no trees moved" do
      put("a.rb", "a v1")
      turn(turn(start), by: Lain::Workspace::Snapshot.new(root: dir))

      expect(log.count).to eq(1)
    end

    # A deletion leaves a shadow map unchanged; the trees are what moved.
    it "keeps an entry whose trees moved even when its map repeats the one before" do
      put("a.rb", "a v1")
      turn(turn(start), by: Lain::Workspace::Snapshot.new(root: dir), pair: SnapshotLogSpecSupport::Pair.new)

      expect(log.count).to eq(2)
    end
  end

  describe "#undo" do
    it "says there is nothing to undo before any turn changed a file" do
      expect(log.undo(store:)).to be_nothing
    end

    context "with a turn the write-set scope recorded" do
      it "moves each path back to its latest earlier record, skipping what the turn left alone" do
        put("a.rb", "a v1")
        put("b.rb", "b v1")
        turn_b = turn(turn(start)) # turn A writes both; turn B writes nothing
        put("a.rb", "a v2")
        turn_c = turn(turn_b)

        undo = log.undo(store:)

        expect(undo.turn).to eq(turn_c.head_digest)
        expect(undo.moves).to eq([move("a.rb", "a v1", "a v2")])
        expect(undo.blocked).to be_empty
      end

      it "walks further back once an undo has been taken" do
        put("a.rb", "a v1")
        turn_a = turn(start)
        put("a.rb", "a v2")
        turn_b = turn(turn_a)
        put("a.rb", "a v3")
        turn(turn_b)
        log.undone(log.undo(store:))

        undo = log.undo(store:)

        expect(undo.turn).to eq(turn_b.head_digest)
        expect(undo.moves).to eq([move("a.rb", "a v1", "a v2")])
      end

      # The undone record is out of the history, so a later turn's undo does
      # not take the bytes it held for a pre-image: disk went back past it.
      it "never takes an undone turn's bytes for a later turn's pre-image" do
        put("a.rb", "a v1")
        turn_a = turn(start)
        put("a.rb", "a v2")
        turn_b = turn(turn_a)
        log.undone(log.undo(store:))
        put("a.rb", "a v3")
        turn(turn_b)

        expect(log.undo(store:).moves).to eq([move("a.rb", "a v1", "a v3")])
      end

      # Nothing recorded what the path held before lain first wrote it: it may
      # have been a human's file, so the undo names it and plans no move.
      it "blocks a path first written in the turn, as unrecorded" do
        put("a.rb", "a v1")
        turn(start)

        undo = log.undo(store:)

        expect(undo.blocked).to eq([blocker("a.rb", :unrecorded)])
        expect(undo.moves).to be_empty
      end
    end

    context "with a turn the shadow scope recorded" do
      let(:landing) { Lain::Workspace::Snapshot.new(root: dir, scope: SnapshotLogSpecSupport::Landing.new) }

      it "plans exactly the moves its trees hold" do
        planned = move("made.txt", nil, "m")
        turn(start, pair: SnapshotLogSpecSupport::Pair.new(moves: [planned]), by: landing)

        expect(log.undo(store:).moves).to eq([planned])
      end

      # A structured tool wrote a path git never stages. The trees cannot say
      # what it held before, so the undo names it rather than skipping it.
      it "blocks a write-set path the turn changed that the trees never staged" do
        put("app.log", "log by tool")
        turn(start, pair: SnapshotLogSpecSupport::Pair.new(ignored: ["app.log"]))

        expect(log.undo(store:).blocked).to eq([blocker("app.log", :ignored)])
      end

      it "blocks a write-set path outside the root" do
        project = File.join(dir, "project").tap { |path| Dir.mkdir(path) }
        escape = File.join(dir, "escape.txt").tap { |path| File.binwrite(path, "x") }
        write_set << escape
        turn(start, pair: SnapshotLogSpecSupport::Pair.new, by: Lain::Workspace::Snapshot.new(root: project))

        expect(log.undo(store:).blocked).to eq([blocker("../escape.txt", :outside_root)])
      end

      it "leaves out a write-set path the turn did not change" do
        put("a.rb", "a v1")
        turn_a = turn(start)
        turn(turn_a, pair: SnapshotLogSpecSupport::Pair.new(moves: [move("y.txt", nil, "y")]), by: landing)

        undo = log.undo(store:)

        expect(undo.moves.map(&:key)).to eq(["y.txt"])
        expect(undo.blocked).to be_empty
      end
    end
  end

  # How `/undo` names a turn to a human: by how many turns are still
  # undoable, never counting ones already undone, and never by a digest.
  it "counts the turns still undoable with each plan" do
    put("a.rb", "a v1")
    turn_a = turn(start)
    put("a.rb", "a v2")
    turn(turn_a)

    first = log.undo(store:)
    log.undone(first)

    expect([first.remaining, log.undo(store:).remaining]).to eq([2, 1])
  end

  describe "#skip" do
    it "drops the latest turn without planning a move, and says which it dropped" do
      put("a.rb", "a v1")
      turn_a = turn(start)
      put("a.rb", "a v2")
      turn_b = turn(turn_a)

      skipped = log.skip

      expect([skipped.turn, skipped.remaining]).to eq([turn_b.head_digest, 2])
      expect(log.map(&:turn)).to eq([turn_a.head_digest])
    end
  end

  describe "#undone" do
    it "refuses a plan that is no longer the latest, so a stale undo cannot pop the wrong turn" do
      put("a.rb", "a v1")
      turn_a = turn(start)
      stale = log.undo(store:)
      put("a.rb", "a v2")
      turn(turn_a)

      expect { log.undone(stale) }.to raise_error(described_class::Moved)
      expect(log.count).to eq(2)
    end
  end
end
