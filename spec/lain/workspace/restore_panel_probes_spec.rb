# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# W2 review-panel probes over Lain::Workspace::Restore. Each example exercises
# one panel condition or claim from the implementer's hand-back
# (.handback-W2.md) that the acceptance-criteria spec (restore_spec.rb) does
# not already pin. These are throwaway probes, not a permanent regression
# suite -- left in the worktree per the review protocol, not committed.
RSpec.describe "W2 panel probes: Workspace::Restore" do
  def block(text) = [{ "type" => "text", "text" => text }]

  def write_file(root, name, bytes)
    path = File.join(root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
    path
  end

  def read_file(root, name) = File.binread(File.join(root, name))

  def exist?(root, name) = File.exist?(File.join(root, name))

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  let(:store) { Lain::Store.new }
  let(:log) { [] }

  def restorer(root: dir, projection_log: log)
    described_class.new(projection: Lain::Event::Projection.new(projection_log), store:, root:)
  end

  let(:described_class) { Lain::Workspace::Restore }

  def commit(timeline, number)
    role = number.odd? ? :user : :assistant
    timeline.commit(role:, content: block("turn-#{number}")).tap do |committed|
      log << store.fetch(committed.head_digest)
    end
  end

  # --- Probe 1: byte-for-byte round trip, including binary/invalid-UTF-8 -----

  describe "probe 1: binary / invalid-UTF-8 round trip" do
    it "round trips arbitrary bytes byte-for-byte, including invalid UTF-8" do
      binary = (+"\xff\x00\xfe\x01\xC0\xAF").force_encoding(Encoding::BINARY)
      writer = Lain::Workspace::Snapshot.new(root: dir)
      path = write_file(dir, "bin.dat", binary)
      timeline = commit(Lain::Timeline.empty(store:), 1)
      log << writer.write(timeline:, paths: [path])

      File.delete(path) # absence is clean (nothing to clobber); no force needed
      restorer.restore(turn: 1)

      restored = read_file(dir, "bin.dat")
      expect(restored.b).to eq(binary.b)
      expect(restored.bytesize).to eq(binary.bytesize)
    end
  end

  # --- Probe 2: sequential restores (2 -> 5 -> 2), in-force map correctness -

  describe "probe 2: sequential restores 2 -> 5 -> 2 on ONE Restore instance" do
    it "keeps in-force correct across a back-forward-back sequence" do
      writer = Lain::Workspace::Snapshot.new(root: dir)
      t2 = commit(commit(Lain::Timeline.empty(store:), 1), 2)
      a2 = write_file(dir, "a.txt", "v1")
      log << writer.write(timeline: t2, paths: [a2])

      t3 = commit(t2, 3)
      File.binwrite(a2, "v2")
      write_file(dir, "b.txt", "b-v1")
      t5 = commit(commit(t3, 4), 5)
      log << writer.write(timeline: t5, paths: [a2, File.join(dir, "b.txt")])

      restore = restorer
      restore.restore(turn: 2)
      expect(read_file(dir, "a.txt")).to eq("v1")
      expect(exist?(dir, "b.txt")).to be(false)

      restore.restore(turn: 5)
      expect(read_file(dir, "a.txt")).to eq("v2")
      expect(read_file(dir, "b.txt")).to eq("b-v1")

      # Third hop, back to 2 again -- restore's OWN turn-5 writes must not
      # register as out-of-band dirt.
      restore.restore(turn: 2)
      expect(read_file(dir, "a.txt")).to eq("v1")
      expect(exist?(dir, "b.txt")).to be(false)
    end
  end

  # --- Probe 3: dirty vs an OLDER snapshot's blob ----------------------------

  describe "probe 3: bytes matching an older (not the in-force) snapshot" do
    it "does NOT flag as dirty when disk bytes equal turn-2's blob but turn-5 is in force" do
      writer = Lain::Workspace::Snapshot.new(root: dir)
      t2 = commit(commit(Lain::Timeline.empty(store:), 1), 2)
      a = write_file(dir, "a.txt", "v1")
      log << writer.write(timeline: t2, paths: [a])

      t3 = commit(t2, 3)
      File.binwrite(a, "v2")
      t5 = commit(commit(t3, 4), 5)
      log << writer.write(timeline: t5, paths: [a])

      # Roll disk back to v1 bytes BY HAND (out of band), while the log's
      # in-force snapshot (last one, turn 5) says v2. The handback's "clean"
      # definition is keyed off in_force (last snapshot), not "any snapshot
      # ever recorded these bytes" -- so this should be DIRTY relative to
      # in-force even though v1 bytes are legitimately in the log at turn 2.
      File.binwrite(a, "v1")

      expect { restorer.restore(turn: 2) }
        .to raise_error(Lain::Workspace::Restore::Dirty, /a\.txt/)
    end

    it "IS dirty for truly foreign bytes that no blob in the log holds" do
      writer = Lain::Workspace::Snapshot.new(root: dir)
      t2 = commit(commit(Lain::Timeline.empty(store:), 1), 2)
      a = write_file(dir, "a.txt", "v1")
      log << writer.write(timeline: t2, paths: [a])

      File.binwrite(a, "never recorded anywhere")

      expect { restorer.restore(turn: 2) }
        .to raise_error(Lain::Workspace::Restore::Dirty, /a\.txt/)
    end
  end

  # --- Probe 4: force waives Dirty but never EscapesRoot ---------------------

  describe "probe 4: force semantics" do
    it "force: true waives Dirty" do
      writer = Lain::Workspace::Snapshot.new(root: dir)
      t2 = commit(commit(Lain::Timeline.empty(store:), 1), 2)
      a = write_file(dir, "a.txt", "v1")
      log << writer.write(timeline: t2, paths: [a])
      File.binwrite(a, "rogue")

      expect { restorer.restore(turn: 2, force: true) }.not_to raise_error
      expect(read_file(dir, "a.txt")).to eq("v1")
    end

    it "force: true does NOT waive EscapesRoot" do
      outside = write_file(dir, "outside.txt", "v1")
      project = File.join(dir, "project").tap { |p| Dir.mkdir(p) }
      writer = Lain::Workspace::Snapshot.new(root: project)
      timeline = commit(Lain::Timeline.empty(store:), 1)
      log << writer.write(timeline:, paths: [outside])

      expect { restorer(root: project).restore(turn: 1, force: true) }
        .to raise_error(Lain::Workspace::Restore::EscapesRoot)
    end
  end

  # --- Probe 5: empty total-deletion map refuses nothing ---------------------

  describe "probe 5: empty map restore refuses nothing, even with prior dirt" do
    it "restoring an empty snapshot deletes everything without raising Dirty, " \
       "because an in-force-present/disk-absent pairing to a NEW absence isn't the check" do
      writer = Lain::Workspace::Snapshot.new(root: dir)
      t1 = commit(Lain::Timeline.empty(store:), 1)
      a = write_file(dir, "a.txt", "v1")
      log << writer.write(timeline: t1, paths: [a])

      t2 = commit(t1, 2)
      File.delete(a)
      log << writer.write(timeline: t2, paths: [a]) # empty manifest, real event

      expect { restorer.restore(turn: 2) }.not_to raise_error
      expect(exist?(dir, "a.txt")).to be(false)
    end
  end

  # --- Probe 6: partial-failure atomicity -------------------------------------
  # CONVERTED (fix round, FIX 2): the defect this probe pinned -- raw Errno
  # escaping and a stale in-force ledger after a mid-apply failure -- is fixed;
  # the fixed behavior (PartialApply naming what landed, per-operation ledger,
  # clean unforced retry) is a permanent spec in restore_spec.rb under
  # "mid-apply IO failure".

  # --- Probe 7: relocated root (already covered in main spec; re-probe briefly)

  describe "probe 7: relocated root" do
    it "restores under a DIFFERENT root than capture, ignoring the payload's recorded root" do
      original = File.join(dir, "captured").tap { |p| Dir.mkdir(p) }
      writer = Lain::Workspace::Snapshot.new(root: original)
      t1 = commit(Lain::Timeline.empty(store:), 1)
      a = write_file(original, "a.txt", "hello")
      log << writer.write(timeline: t1, paths: [a])

      elsewhere = File.join(dir, "elsewhere").tap { |p| Dir.mkdir(p) }
      restorer(root: elsewhere).restore(turn: 1)

      expect(read_file(elsewhere, "a.txt")).to eq("hello")
      expect(exist?(original, "a.txt")).to be(true) # untouched; different root entirely
    end
  end

  # --- Probe 8: symlink in the target path — confinement hole? ---------------
  # CONVERTED (fix round, FIX 1): the hole this probe demonstrated -- restore
  # writing recorded bytes THROUGH an in-root symlink to an outside target --
  # is closed; a symlink at any managed path now refuses as EscapesRoot before
  # any IO, force notwithstanding. Permanent specs live in restore_spec.rb
  # under "confinement / symlinks at managed paths".

  # --- Probe 9: turn addressing agrees with Projection#workspace_at ----------

  describe "probe 9: turn addressing parity with Projection#workspace_at" do
    it "restore(turn:) selects the exact same snapshot workspace_at(turn) would return" do
      writer = Lain::Workspace::Snapshot.new(root: dir)
      t2 = commit(commit(Lain::Timeline.empty(store:), 1), 2)
      a = write_file(dir, "a.txt", "v1")
      snap2 = writer.write(timeline: t2, paths: [a])
      log << snap2

      t3 = commit(t2, 3)
      File.binwrite(a, "v2")
      t5 = commit(commit(t3, 4), 5)
      snap5 = writer.write(timeline: t5, paths: [a])
      log << snap5

      # Ask workspace_at directly for turns 2, 3, 4, 5 -- restore should
      # agree with it at every one (turn 3 and 4 still resolve to snap2,
      # the "at or before" window). ONE restore instance, matching the
      # documented one-writer-per-session usage (a fresh instance per call
      # re-seeds in_force from the log's LAST snapshot and would flag the
      # prior iteration's own rewind-back as dirty -- see probe 2 / the
      # handback's own noted follow-up, not re-litigated here).
      projection = Lain::Event::Projection.new(log)
      restore = restorer
      [2, 3, 4].each do |turn|
        restore.restore(turn:)
        expected = store.fetch(projection.workspace_at(turn).body.fetch("files").fetch("a.txt")).bytes
        expect(read_file(dir, "a.txt")).to eq(expected)
        expect(read_file(dir, "a.txt")).to eq("v1")
      end

      restore.restore(turn: 5)
      expect(read_file(dir, "a.txt")).to eq("v2")
    end
  end
end
