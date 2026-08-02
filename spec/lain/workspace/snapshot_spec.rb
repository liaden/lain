# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Workspace::Snapshot do
  # A store with one committed turn, so snapshots have a turn to name as their
  # causal parent -- the same shape the Agent's tool_results commit leaves.
  def committed_timeline(store = Lain::Store.new)
    Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
  end

  def write_file(dir, name, bytes)
    File.join(dir, name).tap { |path| File.binwrite(path, bytes) }
  end

  subject(:writer) { described_class.new(observer:, root: dir) }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  let(:events) { [] }
  let(:observer) { ->(event) { events << event } }

  describe Lain::Workspace::Snapshot::Blob do
    it "content-addresses its bytes: same bytes, same digest; different bytes, different digest" do
      expect(described_class.new(bytes: "hello").digest).to eq(described_class.new(bytes: "hello").digest)
      expect(described_class.new(bytes: "hello").digest).not_to eq(described_class.new(bytes: "other").digest)
      expect(described_class.new(bytes: "hello").digest).to start_with("blake3:")
    end

    it "is binary-safe: non-UTF-8 bytes address without raising" do
      blob = described_class.new(bytes: (+"\xff\x00\xfe").force_encoding(Encoding::BINARY))

      expect(blob.digest).to start_with("blake3:")
      expect(blob.bytes.bytes).to eq([0xff, 0x00, 0xfe])
    end

    it "is a frozen value: equal by digest, deduplicating in a Store" do
      store = Lain::Store.new
      first = described_class.new(bytes: "same")

      expect(first).to be_deeply_frozen
      expect(first).to eq(described_class.new(bytes: "same"))
      store.put(first)
      expect { store.put(described_class.new(bytes: "same")) }.not_to change(store, :size)
    end
  end

  # T12's byte-identity proof. Every literal below was captured by running a
  # scripted session against the tree as it stood BEFORE the scope object
  # existed (`git show main:lib/lain/workspace/snapshot.rb`), so it is evidence
  # that the default arm is a refactor, not a transcription of this card's own
  # output. Only the root is substituted -- the real one is a tmpdir, and the
  # payload records it verbatim -- so each pinned digest is the digest that
  # snapshot really has when rooted at NORMALIZED_ROOT. The dumped bytes are
  # pinned alongside the digests because {Lain::Canonical} sorts keys before
  # hashing, so a digest alone could not catch a renamed or reordered key.
  describe "the default scope, against digests captured before this card" do
    normalized_root = "/w"

    def normalized(event, root)
      payload = Lain::Event::Payload.new(kind: :snapshot, body: event.body.merge("root" => root))
      { keys: event.body.keys,
        bytes: Lain::Canonical.dump(event.body.merge("root" => root)),
        payload_digest: payload.digest,
        event_digest: Lain::Canonical.digest(event.payload.merge("payload_digest" => payload.digest)) }
    end

    # One stateful writer over three writes, exactly as the capture script ran
    # it: the skip logic and the last-files memory are part of what is pinned.
    let(:sequence) do
      writer = described_class.new(root: dir)
      a = write_file(dir, "a.txt", "alpha")
      b = write_file(dir, "b.txt", "beta")
      timeline = committed_timeline
      events = { two_files: writer.write(timeline:, paths: [a, b]) }
      File.binwrite(a, "bash rewrote me")
      events[:out_of_band] = writer.write(timeline:, paths: [a, b])
      [a, b].each { |path| File.delete(path) }
      events[:total_deletion] = writer.write(timeline:, paths: [a, b])
      events.transform_values { |event| normalized(event, normalized_root) }
    end

    it "reproduces the pre-card digest for a two-file write-set" do
      expect(sequence.fetch(:two_files)).to eq(
        keys: %w[files root snapshot_scope],
        bytes: '{"files":{"a.txt":"blake3:0d8c5eaed5d24af0b26b4982c89e17e7df51ecfa1a7655365a9a58c3883aaa69",' \
               '"b.txt":"blake3:a08ddaf158de8b9b7affcea15de583d36f59f22f2f42a785410b2c30bfa740bb"},' \
               '"root":"/w","snapshot_scope":"write-set only: paths recorded via Session#record_write; ' \
               'out-of-band mutations (e.g. bash) outside that set are not captured"}',
        payload_digest: "blake3:e8ad505710020e34fb3a91ec646b0f87ee3e9a662333d8fc1fd575981d6dcd2b",
        event_digest: "blake3:5c4b1e2fed263f52811587052440b6c9383fb405cdcb124a3b7b56b7542b72d0"
      )
    end

    # The escalation trigger at :190, pinned by digest: bash rewriting a
    # write-set file still lands the new bytes, under the same key.
    it "reproduces the pre-card digest for a file mutated out of band" do
      expect(sequence.fetch(:out_of_band)).to eq(
        keys: %w[files root snapshot_scope],
        bytes: '{"files":{"a.txt":"blake3:c3a726c4c817c9b5e3a47b1655ad857d2f08f1051873a696df1797bc2d0f18d1",' \
               '"b.txt":"blake3:a08ddaf158de8b9b7affcea15de583d36f59f22f2f42a785410b2c30bfa740bb"},' \
               '"root":"/w","snapshot_scope":"write-set only: paths recorded via Session#record_write; ' \
               'out-of-band mutations (e.g. bash) outside that set are not captured"}',
        payload_digest: "blake3:3f54cc7b6fc7083987c546d1c55cb847e636a5c837bd3f8cda35e05c148b0947",
        event_digest: "blake3:b09b075ef5eca2fa71dc567d39e32697589387f8a1b05eedd26ea01ae52156db"
      )
    end

    it "reproduces the pre-card digest for total write-set deletion" do
      expect(sequence.fetch(:total_deletion)).to eq(
        keys: %w[files root snapshot_scope],
        bytes: '{"files":{},"root":"/w","snapshot_scope":"write-set only: paths recorded via ' \
               'Session#record_write; out-of-band mutations (e.g. bash) outside that set are not captured"}',
        payload_digest: "blake3:ee64e418694d858213ecde12c8ee6da66a9014713e072f225caff009ffeed693",
        event_digest: "blake3:edd9cf62a3fc9d36931ba71514f09b591f1d77af778cb2b514d33e339bb976dc"
      )
    end

    # Plan::Closure reads this constant as its no-snapshot fallback, so the
    # name survives the move; the scope is now where the text lives.
    it "keeps SCOPE_NOTE the write-set scope's own note" do
      expect(Lain::Workspace::Snapshot::SCOPE_NOTE)
        .to eq(Lain::Workspace::Snapshot::Scope::WriteSet.new.note)
    end
  end

  describe Lain::Workspace::Snapshot::Scope do
    it "passes a scope instance through resolution unchanged" do
      scope = Lain::Workspace::Snapshot::Scope::WriteSet.new

      expect(described_class.resolve(scope)).to be(scope)
    end

    it "resolves a short name to a fresh scope of that kind" do
      expect(described_class.resolve(:write_set)).to be_a(Lain::Workspace::Snapshot::Scope::WriteSet)
    end

    it "raises on an unknown name, naming the registered scopes" do
      expect { described_class.resolve(:everything) }
        .to raise_error(described_class::Unknown, /everything.*write_set/m)
    end

    it "hands the write-set straight back, ignoring the root" do
      scope = Lain::Workspace::Snapshot::Scope::WriteSet.new

      expect(scope.paths(write_set: %w[a b], root: Pathname.new("/w"))).to eq(%w[a b])
    end
  end

  describe "an injected scope" do
    # T13's shape in miniature: a scope that widens the set beyond the
    # write-set, records the root it was handed, and names its own policy.
    let(:scope_class) do
      Class.new do
        attr_reader :roots

        def initialize(extra)
          @extra = extra
          @roots = []
        end

        def paths(write_set:, root:)
          @roots << root
          write_set + @extra
        end

        def note = "everything the scope could find"
      end
    end

    def widening_scope(extra) = scope_class.new(extra)

    it "captures the paths the scope returns, not the write-set it was handed" do
      tracked = write_file(dir, "tracked.txt", "in the write set")
      discovered = write_file(dir, "discovered.txt", "found by the scope")

      event = described_class.new(observer:, root: dir, scope: widening_scope([discovered]))
                             .write(timeline: committed_timeline, paths: [tracked])

      expect(event.body.fetch("files").keys).to contain_exactly("discovered.txt", "tracked.txt")
    end

    it "writes the scope's own note as snapshot_scope, never a hardcoded string" do
      path = write_file(dir, "a.txt", "alpha")

      event = described_class.new(observer:, root: dir, scope: widening_scope([]))
                             .write(timeline: committed_timeline, paths: [path])

      expect(event.body.fetch("snapshot_scope")).to eq("everything the scope could find")
    end

    # One source of truth for the root: the scope keys nothing itself, so it
    # must be told the same root the payload records.
    it "hands the scope the workspace root the payload names" do
      path = write_file(dir, "a.txt", "alpha")
      scope = widening_scope([])

      described_class.new(observer:, root: dir, scope:).write(timeline: committed_timeline, paths: [path])

      expect(scope.roots.map(&:to_s)).to eq([File.expand_path(dir)])
    end

    it "resolves a scope named at construction" do
      path = write_file(dir, "a.txt", "alpha")

      event = described_class.new(observer:, root: dir, scope: :write_set)
                             .write(timeline: committed_timeline, paths: [path])

      expect(event.body.fetch("snapshot_scope")).to eq(Lain::Workspace::Snapshot::SCOPE_NOTE)
    end
  end

  describe "#write" do
    # AC (a mutating tool snapshots), the writer half: one :snapshot event whose
    # payload content-addresses each written file's bytes into the Store.
    it "lands ONE :snapshot event, causally parented to the turn, addressing each file's bytes" do
      a = write_file(dir, "a.txt", "alpha")
      b = write_file(dir, "b.txt", "beta")
      timeline = committed_timeline

      event = writer.write(timeline:, paths: [a, b])

      expect(events).to eq([event])
      expect(event.kind).to eq(:snapshot)
      expect(event.causal_parents).to eq([timeline.head_digest])
      expect(event.body.fetch("files").keys).to contain_exactly("a.txt", "b.txt")
      event.body.fetch("files").each do |key, digest|
        expect(timeline.store.fetch(digest).bytes).to eq(File.binread(File.join(dir, key)))
      end
    end

    # Fix round (FIX 2): keys are WORKSPACE-ROOT-RELATIVE, with the root
    # recorded once as payload data. Absolute keys baked tmpdirs/$HOME into the
    # content-addressed file map, breaking cross-machine replay and
    # relocated-workspace restore -- and W2 freezes this format.
    it "keys the file map root-relative, recording the root once as payload data" do
      path = write_file(dir, "a.txt", "alpha")
      timeline = committed_timeline

      event = writer.write(timeline:, paths: [path])

      expect(event.body.fetch("root")).to eq(File.expand_path(dir))
      expect(event.body.fetch("files").keys).to eq(["a.txt"])
    end

    it "yields the IDENTICAL file map for identical content under two different roots" do
      roots = %w[left right].map { |name| File.join(dir, name).tap { |root| Dir.mkdir(root) } }
      maps = roots.map do |root|
        write_file(root, "app.rb", "same bytes everywhere")
        event = described_class.new(root:).write(timeline: committed_timeline,
                                                 paths: [File.join(root, "app.rb")])
        event.body.fetch("files")
      end

      expect(maps.first).to eq(maps.last)
      expect(Lain::Canonical.digest(maps.first)).to eq(Lain::Canonical.digest(maps.last))
    end

    # A write-set path outside the root cannot be hidden and cannot be invented
    # a home: it keys by its honest lexical ../ path. (Restore-side policy for
    # such keys is W2's decision; the payload just tells the truth.)
    it "keys a write-set file outside the root by its lexical ../ path" do
      outside = write_file(dir, "outside.txt", "escapee")
      root = File.join(dir, "project").tap { |path| Dir.mkdir(path) }
      timeline = committed_timeline

      event = described_class.new(observer:, root:).write(timeline:, paths: [outside])

      expect(event.body.fetch("files").keys).to eq(["../outside.txt"])
    end

    # The escalation trigger's invariant, pinned: snapshots are additive to the
    # DAG and invisible to render chains -- ask_human's idiom.
    it "never enters a render chain: render_parent nil, Timeline head and ancestry untouched" do
      path = write_file(dir, "a.txt", "alpha")
      timeline = committed_timeline

      event = writer.write(timeline:, paths: [path])

      expect(event.render_parent).to be_nil
      expect(timeline.ancestor_digests).not_to include(event.digest)
      expect(timeline.store.key?(event.digest)).to be(true)
    end

    it "correlates the snapshot to the turn's chain, payload-then-envelope in the shared Store" do
      path = write_file(dir, "a.txt", "alpha")
      timeline = committed_timeline

      event = writer.write(timeline:, paths: [path])

      expect(event.correlation).to eq(timeline.correlation)
      expect(timeline.store.fetch(event.payload_digest).body).to eq(event.body)
    end

    # AC: unchanged files share storage.
    it "shares the unchanged file's blob across consecutive snapshots, one Store copy" do
      unchanged = write_file(dir, "a.txt", "alpha")
      changed = write_file(dir, "b.txt", "beta")
      timeline = committed_timeline

      first = writer.write(timeline:, paths: [unchanged, changed])
      size_after_first = timeline.store.size
      File.binwrite(changed, "beta v2")
      second = writer.write(timeline:, paths: [unchanged, changed])

      shared_digest = first.body.fetch("files").fetch("a.txt")
      expect(second.body.fetch("files").fetch("a.txt")).to eq(shared_digest)
      # Exactly three new objects: the changed blob, the new payload, the new
      # envelope. The unchanged blob was NOT stored a second time.
      expect(timeline.store.size).to eq(size_after_first + 3)
    end

    # AC: read-only turns snapshot nothing -- both the never-wrote case and the
    # nothing-changed-since-last-snapshot case.
    it "writes nothing for a write-set that never had files" do
      timeline = committed_timeline

      expect(writer.write(timeline:, paths: [])).to be_nil
      expect(events).to be_empty
    end

    it "writes nothing when the write-set bytes are unchanged since the last snapshot" do
      path = write_file(dir, "a.txt", "alpha")
      timeline = committed_timeline
      writer.write(timeline:, paths: [path])

      expect(writer.write(timeline:, paths: [path])).to be_nil
      expect(events.size).to eq(1)
    end

    # AC: bash is an honest gap. The policy is write-set only, and every
    # snapshot SAYS so -- the snapshot_scope note rides the payload, so the gap
    # is declared in the record itself, never a silent wrong snapshot.
    it "captures only the write-set and declares that scope in the payload" do
      inside = write_file(dir, "inside.txt", "tracked")
      write_file(dir, "outside.txt", "bash wrote this")
      timeline = committed_timeline

      event = writer.write(timeline:, paths: [inside])

      expect(event.body.fetch("files").keys).to eq(["inside.txt"])
      expect(event.body.fetch("snapshot_scope")).to include("write-set")
    end

    # The flip side of the honest gap: a write-set file mutated OUT of band
    # (bash editing a file edit_file once wrote) IS re-captured, because the
    # writer hashes current bytes rather than trusting who wrote them.
    it "re-snapshots a write-set file mutated out of band" do
      path = write_file(dir, "a.txt", "alpha")
      timeline = committed_timeline
      first = writer.write(timeline:, paths: [path])

      File.binwrite(path, "bash rewrote me")
      second = writer.write(timeline:, paths: [path])

      expect(second).not_to be_nil
      new_digest = second.body.fetch("files").fetch("a.txt")
      expect(new_digest).not_to eq(first.body.fetch("files").fetch("a.txt"))
      expect(timeline.store.fetch(new_digest).bytes).to eq("bash rewrote me")
    end

    it "records a deleted write-set file by omission, as a fresh snapshot" do
      kept = write_file(dir, "a.txt", "alpha")
      doomed = write_file(dir, "b.txt", "beta")
      timeline = committed_timeline
      writer.write(timeline:, paths: [kept, doomed])

      File.delete(doomed)
      event = writer.write(timeline:, paths: [kept, doomed])

      expect(event.body.fetch("files").keys).to eq(["a.txt"])
    end

    # Fix round (FIX 1): deleting the ENTIRE write-set must enter the record.
    # The empty-manifest early return silently kept the stale last snapshot
    # asserting the files existed -- W2's restore would have resurrected them.
    # Empty AFTER non-empty is a real snapshot recording total deletion; empty
    # with no history is still nothing to say.
    it "records total write-set deletion as an EMPTY snapshot, never silence" do
      only = write_file(dir, "only.txt", "soon gone")
      timeline = committed_timeline
      writer.write(timeline:, paths: [only])

      File.delete(only)
      event = writer.write(timeline:, paths: [only])

      expect(event).not_to be_nil
      expect(event.body.fetch("files")).to eq({})
      expect(events.size).to eq(2)
    end

    it "records a file recreated after total deletion -- the resurrection is new content" do
      only = write_file(dir, "only.txt", "soon gone")
      timeline = committed_timeline
      writer.write(timeline:, paths: [only])
      File.delete(only)
      writer.write(timeline:, paths: [only])

      write_file(dir, "only.txt", "soon gone")
      event = writer.write(timeline:, paths: [only])

      expect(event).not_to be_nil
      expect(event.body.fetch("files").keys).to eq(["only.txt"])
      expect(events.size).to eq(3)
    end

    it "does not re-record emptiness: two writes over a fully deleted set land one empty snapshot" do
      only = write_file(dir, "only.txt", "soon gone")
      timeline = committed_timeline
      writer.write(timeline:, paths: [only])
      File.delete(only)
      writer.write(timeline:, paths: [only])

      expect(writer.write(timeline:, paths: [only])).to be_nil
      expect(events.size).to eq(2)
    end

    # Fix round (FIX 3): File.file? then File.binread races an external delete.
    # The race must collapse into the omission semantics it raced -- omission
    # already means deletion -- never an exception out of the loop.
    it "omits a file deleted between the existence check and the read (TOCTOU)" do
      kept = write_file(dir, "kept.txt", "still here")
      doomed = write_file(dir, "doomed.txt", "racing")
      timeline = committed_timeline
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with(doomed).and_raise(Errno::ENOENT)

      event = writer.write(timeline:, paths: [kept, doomed])

      expect(event.body.fetch("files").keys).to eq(["kept.txt"])
    end
  end

  # The Gherkin end-to-end: a real Agent over Provider::Mock, a real EditFile,
  # a real Session -- the turn commits, the snapshot lands.
  describe "through the Agent" do
    let(:toolset) { Lain::Toolset.new([Lain::Tools::EditFile.new, EchoTool.new]) }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
    let(:session) { Lain::Session.new }

    def edit_call(id, path, from, to)
      [id, "edit_file", { "path" => path, "old_string" => from, "new_string" => to }]
    end

    def run_agent(responses)
      agent = Lain::Agent.new(
        provider: Lain::Provider::Mock.new(responses:),
        toolset:, context:, session:,
        snapshot_writer: writer
      )
      agent.ask("edit please")
      agent
    end

    # AC: a mutating tool snapshots -- a turn whose edit_file writes two files.
    it "lands one :snapshot causally parented to the tool_results turn, addressing both files" do
      a = write_file(dir, "a.txt", "alpha one")
      b = write_file(dir, "b.txt", "beta one")
      session.record_read(a)
      session.record_read(b)

      agent = run_agent([tool_response(edit_call("tu_1", a, "one", "two"),
                                       edit_call("tu_2", b, "one", "two")),
                         text_response("edited")])

      expect(events.size).to eq(1)
      snapshot = events.first
      results_turn = agent.timeline.to_a[2]
      expect(results_turn.role).to eq("user")
      expect(snapshot.causal_parents).to eq([results_turn.digest])
      expect(snapshot.body.fetch("files").keys).to contain_exactly("a.txt", "b.txt")
      expect(agent.timeline.store.fetch(snapshot.body.fetch("files").fetch("a.txt")).bytes)
        .to eq("alpha two")
      expect(agent.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
    end

    # AC: read-only turns snapshot nothing -- a whole run of non-mutating tools.
    it "snapshots nothing for a run of read-only tool turns" do
      run_agent([tool_response(["tu_1", "echo", { "text" => "just looking" }]),
                 text_response("done")])

      expect(events).to be_empty
    end

    # A read-only turn AFTER a mutating one adds no second snapshot: the
    # write-set is unchanged, so there is nothing new to record.
    it "does not re-snapshot on a later read-only turn" do
      a = write_file(dir, "a.txt", "alpha one")
      session.record_read(a)

      run_agent([tool_response(edit_call("tu_1", a, "one", "two")),
                 tool_response(["tu_2", "echo", { "text" => "peek" }]),
                 text_response("done")])

      expect(events.size).to eq(1)
    end
  end
end
