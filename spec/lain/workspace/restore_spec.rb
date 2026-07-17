# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Workspace::Restore do
  def block(text) = [{ "type" => "text", "text" => text }]

  def write_file(root, name, bytes)
    File.join(root, name).tap { |path| File.binwrite(path, bytes) }
  end

  def read_file(root, name) = File.binread(File.join(root, name))

  def exist?(root, name) = File.exist?(File.join(root, name))

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir, :timeline

  let(:store) { Lain::Store.new }
  let(:log) { [] }

  def restorer(root: dir)
    described_class.new(projection: Lain::Event::Projection.new(log), store:, root:)
  end

  def projection = Lain::Event::Projection.new(log)

  # One committed turn appended to both axes: the Timeline (conversation) and
  # the event log Projection#workspace_at counts :turn events in.
  def commit(timeline, number)
    role = number.odd? ? :user : :assistant
    timeline.commit(role:, content: block("turn-#{number}")).tap do |committed|
      log << store.fetch(committed.head_digest)
    end
  end

  def story_paths
    ["a.txt", "b.txt", "c.txt", "lib/deep.rb"].map { |name| File.join(dir, name) }
  end

  # The Gherkin's story: snapshots at turns 2 and 5.
  #   turn-2 state: a.txt "alpha v1", b.txt "beta v1"
  #   turn-5 state: a.txt "alpha v2", b.txt deleted, c.txt and lib/deep.rb added
  # Disk is left in the turn-5 state, matching the record.
  def build_story
    writer = Lain::Workspace::Snapshot.new(root: dir)
    snapshot_turn_five(writer, commit(snapshot_turn_two(writer), 3))
  end

  def snapshot_turn_two(writer)
    paths = [write_file(dir, "a.txt", "alpha v1"), write_file(dir, "b.txt", "beta v1")]
    commit(commit(Lain::Timeline.empty(store:), 1), 2).tap do |timeline|
      log << writer.write(timeline:, paths:)
    end
  end

  def snapshot_turn_five(writer, timeline)
    mutate_to_turn_five_state
    commit(commit(timeline, 4), 5).tap do |committed|
      log << writer.write(timeline: committed, paths: story_paths)
    end
  end

  def mutate_to_turn_five_state
    File.binwrite(File.join(dir, "a.txt"), "alpha v2")
    File.delete(File.join(dir, "b.txt"))
    write_file(dir, "c.txt", "gamma v1")
    Dir.mkdir(File.join(dir, "lib"))
    write_file(dir, "lib/deep.rb", "module Deep; end")
  end

  before { @timeline = build_story }

  # Scenario: restore files, keep conversation.
  describe "restore files, keep conversation" do
    it "restores the write-set to the turn-2 blobs byte-for-byte" do
      restorer.restore(turn: 2)

      projection.workspace_at(2).body.fetch("files").each do |key, digest|
        expect(read_file(dir, key)).to eq(store.fetch(digest).bytes)
      end
      expect(read_file(dir, "a.txt")).to eq("alpha v1")
      expect(read_file(dir, "b.txt")).to eq("beta v1")
    end

    it "deletes files the turn-2 snapshot does not hold -- state, not overlay" do
      restorer.restore(turn: 2)

      expect(exist?(dir, "c.txt")).to be(false)
      expect(exist?(dir, "lib/deep.rb")).to be(false)
    end

    it "leaves the Timeline head unchanged: restore never even sees a Timeline" do
      head_before = timeline.head_digest

      restorer.restore(turn: 2)

      expect(timeline.head_digest).to eq(head_before)
      expect(timeline.to_a.size).to eq(5)
    end

    it "reports what it did: written and deleted keys, frozen" do
      result = restorer.restore(turn: 2)

      expect(result.written).to contain_exactly("a.txt", "b.txt")
      expect(result.deleted).to contain_exactly("c.txt", "lib/deep.rb")
      expect(result.written).to be_frozen
      expect(result.deleted).to be_frozen
    end

    it "refuses namedly when no snapshot exists at or before the turn" do
      expect { restorer.restore(turn: 1) }
        .to raise_error(Lain::Workspace::Restore::NoSnapshot, /turn 1/)
    end
  end

  # Scenario: restore both axes.
  describe "restore both axes" do
    it "combined with Timeline#rewind, files and conversation agree on the turn-2 state" do
      rewound = timeline.rewind(3)
      restorer.restore(turn: rewound.to_a.size)

      expect(rewound.to_a.map { |turn| turn.content.first.fetch("text") }).to eq(%w[turn-1 turn-2])
      files = projection.workspace_at(rewound.to_a.size).body.fetch("files")
      expect(files.keys).to contain_exactly("a.txt", "b.txt")
      files.each { |key, digest| expect(read_file(dir, key)).to eq(store.fetch(digest).bytes) }
    end

    it "restores forward again cleanly: its own writes are never dirty" do
      restore = restorer
      restore.restore(turn: 2)
      restore.restore(turn: 5)

      expect(read_file(dir, "a.txt")).to eq("alpha v2")
      expect(exist?(dir, "b.txt")).to be(false)
      expect(read_file(dir, "c.txt")).to eq("gamma v1")
      expect(read_file(dir, "lib/deep.rb")).to eq("module Deep; end")
    end
  end

  # Scenario: restore refuses dirty surprises. Dirty means the ON-DISK bytes
  # deviate from the last state lain recorded -- clobbering them would lose
  # bytes no blob holds.
  describe "restore refuses dirty surprises" do
    it "refuses namedly when a target file was modified out of band since the snapshot" do
      write_file(dir, "a.txt", "rogue bash edit")

      expect { restorer.restore(turn: 2) }
        .to raise_error(Lain::Workspace::Restore::Dirty, /a\.txt/)
    end

    it "applies nothing on refusal -- no partial restore" do
      write_file(dir, "a.txt", "rogue bash edit")

      expect { restorer.restore(turn: 2) }.to raise_error(Lain::Workspace::Restore::Dirty)
      expect(read_file(dir, "a.txt")).to eq("rogue bash edit")
      expect(read_file(dir, "c.txt")).to eq("gamma v1")
      expect(exist?(dir, "b.txt")).to be(false)
    end

    it "counts a file recreated out of band (the record says deleted) as dirty" do
      write_file(dir, "b.txt", "resurrected by bash")

      expect { restorer.restore(turn: 2) }
        .to raise_error(Lain::Workspace::Restore::Dirty, /b\.txt/)
    end

    it "does not count an out-of-band deletion as dirty: absent bytes cannot be clobbered" do
      File.delete(File.join(dir, "c.txt"))

      restorer.restore(turn: 2)

      expect(read_file(dir, "a.txt")).to eq("alpha v1")
    end

    it "force: true waives the dirty check and clobbers" do
      write_file(dir, "a.txt", "rogue bash edit")

      restorer.restore(turn: 2, force: true)

      expect(read_file(dir, "a.txt")).to eq("alpha v1")
    end
  end

  # Fix round (FIX 2, from panel probe 6): apply is delete-then-write with no
  # rollback, so a mid-apply IO failure leaves disk in a state no snapshot
  # recorded. What the fix owes is not atomicity but TRUTH: the raised error
  # names what landed, and the in-force ledger advances per successful
  # operation, so the failure stays loud-and-safe -- a spurious Dirty at
  # worst, never a silent clobber built on a stale ledger.
  describe "mid-apply IO failure" do
    def fail_binwrite_for(key)
      allow(File).to receive(:binwrite).and_call_original
      allow(File).to receive(:binwrite).with(File.join(dir, key), anything)
                                       .and_raise(Errno::EACCES, "permission denied")
    end

    # Turn-2 target writes a.txt then b.txt (map order is sorted); failing
    # b.txt leaves a.txt restored, c.txt and lib/deep.rb already deleted, and
    # b.txt never created.
    it "raises PartialApply naming exactly what landed, with the IO error as cause" do
      fail_binwrite_for("b.txt")

      expect { restorer.restore(turn: 2) }.to raise_error(
        Lain::Workspace::Restore::PartialApply
      ) do |error|
        expect(error.written).to eq(["a.txt"])
        expect(error.deleted).to contain_exactly("c.txt", "lib/deep.rb")
        expect(error.cause).to be_a(Errno::EACCES)
      end
      expect(read_file(dir, "a.txt")).to eq("alpha v1")
      expect(exist?(dir, "b.txt")).to be(false)
    end

    it "keeps the ledger truthful: a retry is Dirty exactly where bytes are unaccounted" do
      restore = restorer
      write_file(dir, "b.txt", "foreign bytes") # before the stub, out of band
      fail_binwrite_for("b.txt")

      expect { restore.restore(turn: 2, force: true) }
        .to raise_error(Lain::Workspace::Restore::PartialApply)

      # a.txt's freshly-restored bytes ARE in the ledger (clean on retry);
      # b.txt's foreign bytes never entered it (the write failed first), so
      # the retry refuses there and only there -- loud-and-safe, never stale.
      expect { restore.restore(turn: 2) }.to raise_error(Lain::Workspace::Restore::Dirty) do |error|
        expect(error.message).to include("b.txt")
        expect(error.message).not_to include("a.txt")
      end
    end

    it "recovers on an UNFORCED retry once the failure clears: nothing it did looks dirty" do
      restore = restorer
      fail_binwrite_for("b.txt")
      expect { restore.restore(turn: 2) }.to raise_error(Lain::Workspace::Restore::PartialApply)

      allow(File).to receive(:binwrite).and_call_original
      restore.restore(turn: 2)

      expect(read_file(dir, "a.txt")).to eq("alpha v1")
      expect(read_file(dir, "b.txt")).to eq("beta v1")
      expect(exist?(dir, "c.txt")).to be(false)
    end
  end

  # W1 froze the payload format for exactly this: keys are root-relative, so
  # the injected restore root -- not the recorded one -- says where they land.
  describe "relocated restore" do
    it "restores into a different root than the snapshot recorded, creating directories" do
      elsewhere = File.join(dir, "elsewhere").tap { |path| Dir.mkdir(path) }

      restorer(root: elsewhere).restore(turn: 5)

      expect(read_file(elsewhere, "a.txt")).to eq("alpha v2")
      expect(read_file(elsewhere, "lib/deep.rb")).to eq("module Deep; end")
    end
  end

  # A total-deletion snapshot is an EMPTY file map (W1 FIX 1); restoring it
  # means deleting the write-set files, never resurrecting them.
  describe "total-deletion snapshot" do
    it "restores the empty map by deleting the write-set files" do
      restore = restorer
      restore.restore(turn: 2)

      only_log = []
      only_root = File.join(dir, "solo").tap { |path| Dir.mkdir(path) }
      only = write_file(only_root, "only.txt", "soon gone")
      writer = Lain::Workspace::Snapshot.new(root: only_root)
      solo_timeline = Lain::Timeline.empty(store:).commit(role: :user, content: block("t1"))
      only_log << store.fetch(solo_timeline.head_digest)
      only_log << writer.write(timeline: solo_timeline, paths: [only])
      solo_timeline = solo_timeline.commit(role: :assistant, content: block("t2"))
      only_log << store.fetch(solo_timeline.head_digest)
      File.delete(only)
      only_log << writer.write(timeline: solo_timeline, paths: [only])

      solo = described_class.new(projection: Lain::Event::Projection.new(only_log),
                                 store:, root: only_root)
      solo.restore(turn: 1)
      expect(read_file(only_root, "only.txt")).to eq("soon gone")

      result = solo.restore(turn: 2)
      expect(exist?(only_root, "only.txt")).to be(false)
      expect(result.deleted).to eq(["only.txt"])
      expect(result.written).to be_empty
    end
  end

  # The panel's condition for this card: "../" keys are refuse-or-confine on
  # restore -- never blind-write outside the restore root. We refuse, wholly,
  # before any IO, and force: true does not reach past confinement.
  describe "confinement" do
    # Its own log: the escaping snapshot must be the one workspace_at(1) finds.
    def escaping_setup
      outside = write_file(dir, "outside.txt", "recorded v1")
      project = File.join(dir, "project").tap { |path| Dir.mkdir(path) }
      escape_log = escaping_log(project, outside)
      File.binwrite(outside, "edited since")
      [outside, described_class.new(projection: Lain::Event::Projection.new(escape_log),
                                    store:, root: project)]
    end

    def escaping_log(project, outside)
      writer = Lain::Workspace::Snapshot.new(root: project)
      timeline = Lain::Timeline.empty(store:).commit(role: :user, content: block("t1"))
      [store.fetch(timeline.head_digest), writer.write(timeline:, paths: [outside])]
    end

    it "refuses a snapshot whose keys escape the restore root" do
      outside, restore = escaping_setup

      expect { restore.restore(turn: 1) }
        .to raise_error(Lain::Workspace::Restore::EscapesRoot, %r{\.\./outside\.txt})
      expect(File.binread(outside)).to eq("edited since")
    end

    it "refuses even when forced: force waives dirtiness, never confinement" do
      outside, restore = escaping_setup

      expect { restore.restore(turn: 1, force: true) }
        .to raise_error(Lain::Workspace::Restore::EscapesRoot)
      expect(File.binread(outside)).to eq("edited since")
    end

    # Fix round (FIX 1, from panel probe 8): the lexical key check cannot see a
    # symlink AT the path -- File.binwrite follows links, so a link planted at
    # a managed path would carry recorded bytes wherever it points, including
    # outside the root. A symlink at any managed path refuses like an escaping
    # key: never follow, never confine-and-write, and force does not reach it.
    describe "symlinks at managed paths" do
      def symlinked_setup
        root = File.join(dir, "root").tap { |path| Dir.mkdir(path) }
        outside_target = write_file(dir, "outside-target.txt", "pre-existing outside content")
        restore = described_class.new(projection: Lain::Event::Projection.new(link_log(root)),
                                      store:, root:)
        [root, outside_target, restore]
      end

      # Snapshot a REGULAR file at root/link.txt, then vacate the path so each
      # example can plant its own symlink there before restoring.
      def link_log(root)
        writer = Lain::Workspace::Snapshot.new(root:)
        timeline = Lain::Timeline.empty(store:).commit(role: :user, content: block("t1"))
        captured = write_file(root, "link.txt", "captured content")
        [store.fetch(timeline.head_digest), writer.write(timeline:, paths: [captured])].tap do
          File.delete(captured)
        end
      end

      it "refuses a target path that is now a symlink out of root, before the dirty check" do
        root, outside_target, restore = symlinked_setup
        File.symlink(outside_target, File.join(root, "link.txt"))

        expect { restore.restore(turn: 1) }
          .to raise_error(Lain::Workspace::Restore::EscapesRoot, /link\.txt/)
        expect(File.binread(outside_target)).to eq("pre-existing outside content")
      end

      it "refuses even when forced, and writes nothing through the link" do
        root, outside_target, restore = symlinked_setup
        File.symlink(outside_target, File.join(root, "link.txt"))

        expect { restore.restore(turn: 1, force: true) }
          .to raise_error(Lain::Workspace::Restore::EscapesRoot, /link\.txt/)
        expect(File.binread(outside_target)).to eq("pre-existing outside content")
        expect(File.symlink?(File.join(root, "link.txt"))).to be(true)
      end

      it "refuses a symlink even when it points INSIDE the root: never follow, period" do
        root, _outside_target, restore = symlinked_setup
        decoy = write_file(root, "decoy.txt", "innocent bystander")
        File.symlink(decoy, File.join(root, "link.txt"))

        expect { restore.restore(turn: 1, force: true) }
          .to raise_error(Lain::Workspace::Restore::EscapesRoot, /link\.txt/)
        expect(File.binread(decoy)).to eq("innocent bystander")
      end
    end
  end
end
