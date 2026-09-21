# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Agent::SnapshotSlot do
  around do |example|
    Dir.mktmpdir("lain-slot-project") do |root|
      Dir.mktmpdir("lain-slot-state") do |state|
        @root = root
        @state = state
        example.run
      end
    end
  end

  attr_reader :root, :state

  let(:store) { Lain::Store.new }
  let(:notes) { [] }
  let(:log) { Lain::Workspace::SnapshotLog.new(observer: ->(event) { notes << event.body.fetch("snapshot_scope") }) }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => state }) }

  def slot(scope: :write_set) = described_class.new(root:, scope:, log:, paths:)

  def turn(text = "turn")
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => text }])
  end

  def put(name, bytes) = File.join(root, name).tap { |path| File.binwrite(path, bytes) }

  def scope_note(name) = Lain::Workspace::Snapshot::Scope.fetch(name).note

  it "answers the root it was filled for, expanded, and the scope in force" do
    filled = slot(scope: :shadow_git)

    expect(filled.root).to eq(File.expand_path(root))
    expect(filled.label).to eq("shadow_git")
    expect(filled.log).to be(log)
  end

  # A chat that never calls a tool never pays for a shadow baseline, and never
  # writes the state home at all.
  it "shells no git and writes no state until it is primed" do
    slot(scope: :shadow_git)

    expect(Dir.children(state)).to be_empty
  end

  it "writes through a writer rooted at its root, under its scope, and records it" do
    event = slot.write(timeline: turn, paths: [put("a.rb", "one")])

    expect(event.body).to include("root" => File.expand_path(root), "snapshot_scope" => scope_note(:write_set))
    expect(log.count).to eq(1)
  end

  # The containment itself belongs to the scope, which cannot journal; this
  # slot owns the journal, so a dropped path is recorded here or nowhere.
  describe "a write-set path outside the slot's root" do
    let(:journal) { [] }
    let(:channel) { [] }

    def journaling_slot = described_class.new(root:, scope: :write_set, log:, paths:, journal:, channel:)

    def narrowed(stream = journal) = stream.grep(described_class::SnapshotNarrowed)

    # A written file the slot's root does not reach, for the length of an example.
    def elsewhere
      Dir.mktmpdir("lain-slot-elsewhere") do |dir|
        escape = File.join(dir, "escape.txt")
        File.binwrite(escape, "escapee")
        yield escape
      end
    end

    it "contributes no entry, and tells the journal and the human what was dropped" do
      elsewhere do |escape|
        event = journaling_slot.write(timeline: turn, paths: [put("a.rb", "one"), escape])

        expect(event.body.fetch("files").keys).to eq(["a.rb"])
        expect(narrowed.map { |record| [record.scope, record.root, record.dropped] })
          .to eq([["write_set", File.expand_path(root), 1]])
        expect(narrowed(channel)).to eq(narrowed)
      end
    end

    # The journal keeps every turn; the human hears it once. The session's write
    # set is cumulative, so the same path is dropped again every turn after --
    # a line per turn would scribble the pane it is meant to inform.
    it "tells the human once while the same narrowing repeats, journalling each turn" do
      elsewhere do |escape|
        filled = journaling_slot
        inside = put("a.rb", "one")
        3.times { |index| filled.write(timeline: turn("turn #{index}"), paths: [inside, escape]) }

        expect(narrowed.size).to eq(3)
        expect(narrowed(channel).size).to eq(1)
      end
    end

    it "tells the human again when the narrowing itself changes" do
      elsewhere do |escape|
        filled = journaling_slot
        inside = put("a.rb", "one")
        filled.write(timeline: turn("one"), paths: [inside, escape])
        filled.write(timeline: turn("two"), paths: [inside, escape, "#{escape}.2"])

        expect(narrowed(channel).map(&:dropped)).to eq([1, 2])
      end
    end

    it "says nothing at all for a turn whose every path is inside the root" do
      journaling_slot.write(timeline: turn, paths: [put("a.rb", "one")])

      expect([narrowed, narrowed(channel)]).to eq([[], []])
    end
  end

  # The wedge this containment removes: under plan scope the session's write
  # set keeps growing while the slot's root moves into the spike and back, so
  # a spike path used to reach the checkout's snapshot as a ../ key that
  # /undo can only refuse -- and it refuses the newest turn forever, since a
  # blocked entry is never popped.
  describe "a plan-scope spike the slot later leaves", :seam do
    it "leaves /undo addressing the newest reversible turn" do
      Dir.mktmpdir("lain-slot-spike") do |spike|
        put("kept.txt", "the human's own\n")
        filled = slot(scope: :shadow_git)
        filled.rebind(root: spike).prime
        spiked = File.join(spike, "note.md").tap { |path| File.binwrite(path, "spiked\n") }
        filled.write(timeline: turn("in the spike"), paths: [spiked])
        filled.rebind(root:).prime
        made = put("made.rb", "back in the checkout\n")
        filled.write(timeline: turn("after the spike"), paths: [spiked, made])

        undo = log.undo(store:)

        expect(undo.blocked).to eq([])
        expect(undo.moves.map(&:key)).to eq(["made.rb"])
      end
    end
  end

  describe "a shadow turn's trees", :seam do
    # Each prime restages the before-tree, so what a human did between two
    # turns lands there and never in the second turn's undo.
    it "records each turn with the trees its prime and its settle staged" do
      put("h.txt", "original\n")
      filled = slot(scope: :shadow_git).prime
      put("made.txt", "m\n")
      filled.write(timeline: turn, paths: [])
      put("h.txt", "HUMAN EDIT, keep me\n")
      filled.prime
      put("y.txt", "y\n")
      filled.write(timeline: turn("second"), paths: [])

      expect(log.undo(store:).moves.map(&:key)).to eq(["y.txt"])
    end

    it "records a turn that only deleted a file" do
      put("z.txt", "precious\n")
      filled = slot(scope: :shadow_git).prime
      File.delete(File.join(root, "z.txt"))
      filled.write(timeline: turn, paths: [])

      expect(log.undo(store:).moves.map { |move| [move.key, move.before&.bytes, move.after] })
        .to eq([["z.txt", "precious\n", nil]])
    end
  end

  # A broken shadow store must never cost a turn its answers. The turn it
  # breaks is recorded as the write-set scope would record it, the failure is
  # journaled, and the next turn tries the shadow store again.
  describe "a shadow store that fails" do
    let(:journal) { [] }

    # git that fails on the calls `fails` names, `times` times, then works.
    def git_failing(on:, times: Float::INFINITY)
      real = Mixlib::ShellOut.public_method(:new)
      left = times
      lambda do |*argv, **options|
        failing = left.positive? && on.intersect?(argv)
        left -= 1 if failing
        raise Errno::ENOENT, "git" if failing

        real.call(*argv, **options)
      end
    end

    def failing_slot(**git)
      scope = Lain::Workspace::Snapshot::Scope::ShadowGit.new(paths:, shell_out_factory: git_failing(**git))
      described_class.new(root:, scope:, log:, paths:, journal:)
    end

    def degraded = journal.grep(described_class::SnapshotDegraded)

    it "records the turn under the write-set scope when the prime fails, and journals why" do
      filled = failing_slot(on: %w[init add])

      filled.prime
      event = filled.write(timeline: turn, paths: [put("a.rb", "one")])

      expect(event.body.fetch("snapshot_scope")).to eq(scope_note(:write_set))
      expect(degraded.map(&:phase)).to eq([:prime])
      expect(degraded.first.reason).to include("shadow git")
    end

    # The journal is the experiment's record, not the human's screen: the
    # human is told on the chat's live channel that this turn's shell changes
    # cannot be undone.
    it "tells the human, on the channel it was given, that the turn is degraded" do
      channel = []
      scope = Lain::Workspace::Snapshot::Scope::ShadowGit.new(paths:, shell_out_factory: git_failing(on: %w[init]))
      filled = described_class.new(root:, scope:, log:, paths:, journal:, channel:)

      filled.prime

      expect(channel.grep(described_class::SnapshotDegraded).map(&:phase)).to eq([:prime])
    end

    it "records the turn under the write-set scope when the settle fails", :seam do
      filled = failing_slot(on: %w[diff-index])

      filled.prime
      event = filled.write(timeline: turn, paths: [put("a.rb", "one")])

      expect(event.body.fetch("snapshot_scope")).to eq(scope_note(:write_set))
      expect(degraded.map(&:phase)).to eq([:settle])
    end

    it "tries the shadow store again on the next turn", :seam do
      filled = failing_slot(on: %w[init add], times: 1)
      filled.prime
      filled.write(timeline: turn, paths: [put("a.rb", "one")])

      filled.prime
      put("b.txt", "made by a shell\n")
      event = filled.write(timeline: turn("second"), paths: [])

      expect(event.body.fetch("snapshot_scope")).to eq(scope_note(:shadow_git))
    end
  end

  # An undo moves disk behind the writer's back. Told what disk now holds, a
  # write-set turn that writes an undone change again lands a snapshot rather
  # than matching the stale memory and landing nothing.
  it "measures the next write-set turn from the state an undo put back" do
    filled = slot
    path = put("a.rb", "1")
    filled.write(timeline: turn("one"), paths: [path], pre_images: { path => Lain::Session::PreImage.new(bytes: nil) })
    File.binwrite(path, "2")
    filled.write(timeline: turn("two"), paths: [path], pre_images: { path => Lain::Session::PreImage.new(bytes: "1") })
    undo = log.undo(store:)
    Lain::Workspace::Revert.new(root:).apply(undo.moves)
    filled.undone(undo)

    File.binwrite(path, "2")
    filled.write(timeline: turn("three"), paths: [path],
                 pre_images: { path => Lain::Session::PreImage.new(bytes: "1") })

    expect(log.count).to eq(2)
    expect(log.to_a.last.turn).to eq(turn("three").head_digest)
  end

  describe "#rebind" do
    # A same-scope flip (accept_edits to auto) must not reset the writer: a
    # fresh one remembers nothing, so it would land a duplicate of the last
    # snapshot and a fresh shadow baseline for no change at all.
    it "keeps the writer when the scope does not change" do
      filled = slot
      path = put("a.rb", "one")
      filled.write(timeline: turn, paths: [path])

      filled.rebind(:write_set)
      filled.write(timeline: turn("again"), paths: [path])

      expect(notes.size).to eq(1)
    end

    it "writes the next snapshot under the new scope", :seam do
      filled = slot(scope: :shadow_git)
      filled.write(timeline: turn, paths: [])

      filled.rebind(:write_set)
      filled.write(timeline: turn("after"), paths: [put("a.rb", "one")])

      expect(filled.label).to eq("write_set")
      expect(notes).to eq([scope_note(:write_set)])
    end

    # Plan scope moves the session's writes into a spike, so what a turn
    # changed is measured there rather than in the checkout it cannot touch.
    it "roots the next snapshot at a new root, keeping the scope" do
      filled = slot
      filled.write(timeline: turn, paths: [put("a.rb", "one")])
      Dir.mktmpdir("lain-slot-spike") do |spike|
        filled.rebind(root: spike)
        File.write(File.join(spike, "b.rb"), "two")
        event = filled.write(timeline: turn("in the spike"), paths: [File.join(spike, "b.rb")])

        expect([filled.root, filled.label]).to eq([File.expand_path(spike), "write_set"])
        expect(event.body).to include("root" => File.expand_path(spike))
      end
    end

    it "keeps the writer when neither the scope nor the root changes" do
      filled = slot
      path = put("a.rb", "one")
      filled.write(timeline: turn, paths: [path])

      filled.rebind(root:)
      filled.write(timeline: turn("again"), paths: [path])

      expect(notes.size).to eq(1)
    end

    it "stays lazy when rebound before the first prime, so a scope never used costs nothing" do
      filled = slot(scope: :shadow_git)

      filled.rebind(:write_set)
      filled.write(timeline: turn, paths: [put("a.rb", "one")])

      expect(Dir.children(state)).to be_empty
    end
  end

  # What a board holds before any slot is handed to it: a flip moves nothing,
  # and anything that would read the snapshots refuses by name.
  describe described_class::Unbound do
    it "takes a rebind as a no-op" do
      expect(described_class.rebind(:write_set)).to be(described_class)
      expect(described_class.rebind(root: "/elsewhere")).to be(described_class)
    end

    it "refuses to answer a log or a root" do
      expect { described_class.log }.to raise_error(Lain::Agent::SnapshotSlot::NotBound, /snapshot slot/)
      expect { described_class.root }.to raise_error(Lain::Agent::SnapshotSlot::NotBound)
    end
  end
end
