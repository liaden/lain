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
  let(:captured) { {} }

  # A structured tool's write: what the path held is captured on the turn's
  # first write to it, the bytes land, and the path joins the write-set.
  def put(name, bytes)
    path = File.join(dir, name)
    captured[path] ||= Lain::Session::PreImage.new(bytes: File.file?(path) ? File.binread(path) : nil)
    File.binwrite(path, bytes)
    write_set << path unless write_set.include?(path)
  end

  # One committed tool-result turn, then the settle's snapshot, recorded with
  # the turn's trees and the pre-images its tools captured -- the order
  # {Lain::Agent::SnapshotSlot} keeps. `pre_images:` overrides what `put`
  # captured, for a turn whose capture a spec states outright.
  def turn(timeline, pair: Lain::Workspace::Snapshot::Scope::NoTrees, by: writer, pre_images: captured.dup)
    captured.clear
    timeline.commit(role: :user, content: [{ "type" => "text", "text" => "turn" }]).tap do |committed|
      event = by.write(timeline: committed, paths: write_set)
      log.record(event, pair:, pre_images:) if event
    end
  end

  # What a tool captured before its first write to `name` in the turn: the
  # bytes, or nil for a path that did not exist.
  def before(name, bytes) = { File.join(dir, name) => Lain::Session::PreImage.new(bytes:) }

  def uncaptured(name) = { File.join(dir, name) => Lain::Session::PreImage::Unrecorded }

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

    # A plan step's closure reads the :snapshot body, and a replay addresses
    # it by digest: pre-images ride beside the record, never inside it.
    it "keeps a turn's pre-images out of the snapshot body and out of the entry" do
      File.binwrite(File.join(dir, "a.rb"), "human's a")
      put("a.rb", "a v1")
      turn(start, pre_images: before("a.rb", "human's a"))

      expect(events.first.body.keys).to contain_exactly("files", "root", "snapshot_scope")
      expect(log.first.to_h.keys).to eq(%i[turn snapshot files scope])
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

    # The map cannot show a turn that put back what an earlier turn wrote over
    # a human's edit; the pre-image can.
    it "keeps an entry whose map repeats the one before when its pre-images show replaced bytes" do
      put("x.txt", "A")
      first = turn(start)
      File.binwrite(File.join(dir, "x.txt"), "human")
      put("x.txt", "A")
      turn(first, by: Lain::Workspace::Snapshot.new(root: dir))

      expect(log.count).to eq(2)
      expect(log.undo(store:).moves).to eq([move("x.txt", "human", "A")])
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
      expect(log.undo(store:)).to be(described_class::Undo::NOTHING)
    end

    context "with a turn the write-set scope recorded" do
      it "moves each path the turn wrote back to what it held before, skipping what the turn left alone" do
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

      # The undone record is out of the history, so a later uncaptured write
      # does not take the bytes it held for a pre-image: disk went back past it.
      it "never takes an undone turn's bytes for a later turn's pre-image" do
        put("a.rb", "a v1")
        turn_a = turn(start)
        put("a.rb", "a v2")
        turn_b = turn(turn_a)
        log.undone(log.undo(store:))
        put("a.rb", "a v3")
        turn(turn_b, pre_images: uncaptured("a.rb"))

        expect(log.undo(store:).moves).to eq([move("a.rb", "a v1", "a v3")])
      end

      it "deletes a path its tools created, from a pre-image saying nothing stood there" do
        put("x.txt", "made")
        turn(start, pre_images: before("x.txt", nil))

        undo = log.undo(store:)

        expect(undo.moves).to eq([move("x.txt", nil, "made")])
        expect(undo.blocked).to be_empty
      end

      it "restores the bytes a first overwrite replaced, with no earlier record to lean on" do
        File.binwrite(File.join(dir, "keep.txt"), "committed")
        put("keep.txt", "overwritten")
        turn(start, pre_images: before("keep.txt", "committed"))

        expect(log.undo(store:).moves).to eq([move("keep.txt", "committed", "overwritten")])
      end

      # The pre-image is what disk held when the turn's tools reached the path;
      # an earlier record is only what some earlier turn left there.
      it "puts back the pre-image rather than the latest earlier record when both exist" do
        put("a.rb", "a v1")
        turn_a = turn(start)
        File.binwrite(File.join(dir, "a.rb"), "edited by hand")
        put("a.rb", "a v2")
        turn(turn_a, pre_images: before("a.rb", "edited by hand"))

        expect(log.undo(store:).moves).to eq([move("a.rb", "edited by hand", "a v2")])
      end

      it "plans no move for a path the turn wrote back to exactly its pre-image" do
        put("a.rb", "same")
        turn(start, pre_images: before("a.rb", "same"))

        undo = log.undo(store:)

        expect([undo.moves, undo.blocked]).to eq([[], []])
      end

      # The write-set is the whole session's, so a path an earlier turn wrote is
      # in this turn's map, with whatever a human or a shell has since put
      # there. The turn did not write it, so there is nothing of its to put back.
      it "skips, never blames or reverts, a path the turn did not write" do
        put("c.txt", "an earlier turn's")
        first = turn(start)
        File.binwrite(File.join(dir, "c.txt"), "edited by hand")
        put("e.txt", "this turn's")
        turn(first)

        undo = log.undo(store:)

        expect(undo.moves).to eq([move("e.txt", nil, "this turn's")])
        expect(undo.blocked).to be_empty
      end

      # A write no tool captured a pre-image for: it may have been a human's
      # file, so the undo names it rather than guess it did not exist.
      it "blocks a path the turn wrote without a captured pre-image, as unrecorded" do
        put("a.rb", "a v1")
        turn(start, pre_images: uncaptured("a.rb"))

        undo = log.undo(store:)

        expect(undo.blocked).to eq([blocker("a.rb", :unrecorded)])
        expect(undo.moves).to be_empty
      end

      it "falls back to the latest earlier record for a path written without a captured pre-image" do
        put("a.rb", "a v1")
        turn_a = turn(start)
        put("a.rb", "a v2")
        turn(turn_a, pre_images: uncaptured("a.rb"))

        expect(log.undo(store:).moves).to eq([move("a.rb", "a v1", "a v2")])
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

      it "plans from the trees alone, whatever pre-images its tools captured" do
        planned = move("made.txt", nil, "m")
        put("a.rb", "a v1")
        turn(start, pair: SnapshotLogSpecSupport::Pair.new(moves: [planned]), by: landing,
                    pre_images: before("a.rb", "older"))

        undo = log.undo(store:)

        expect([undo.moves, undo.blocked]).to eq([[planned], []])
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

  # What a writer is resumed from once the undo's moves are made: the undone
  # map with each move's earlier side in place.
  it "says what the file map holds once an undo's moves are made" do
    put("a.rb", "a v1")
    put("b.rb", "b v1")
    turn_a = turn(start)
    put("a.rb", "a v2")
    put("c.rb", "made")
    turn(turn_a)

    expect(log.undo(store:).left).to eq(log.first.files)
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
