# frozen_string_literal: true

require "tmpdir"

# A "bash-shaped" mutator: writes a file WITHOUT touching the session
# write-set, exactly what a shellout does from the snapshot policy's view.
class OutOfBandWriteTool < Lain::Tool
  def name = "sneaky_write"
  def description = "Writes bytes to a path without recording a write."
  def input_schema = { type: :object, properties: { path: { type: :string }, bytes: { type: :string } } }

  def perform(input, _context)
    File.binwrite(input.fetch("path"), input.fetch("bytes"))
    Lain::Tool::Result.ok("wrote out of band")
  end
end

# What snapshot_spec.rb does not pin: skip-by-content through a real Agent, blob dedup
# and domain separation, edge bytes, shareability, invisibility in the rendered Request.
RSpec.describe Lain::Workspace::Snapshot do
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

  describe "skip-by-content vs a dirty flag, through a real Agent" do
    let(:toolset) { Lain::Toolset.new([Lain::Tools::EditFile.new, OutOfBandWriteTool.new, EchoTool.new]) }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
    let(:session) { Lain::Session.new }

    def run_agent(responses)
      Lain::Agent.new(
        provider: Lain::Provider::Mock.new(responses:),
        toolset:, context:, session:,
        snapshot_writer: writer
      ).tap { |agent| agent.ask("go") }
    end

    it "captures a write-set file bash rewrote to DIFFERENT bytes in a turn with no edit_file" do
      a = write_file(dir, "a.txt", "alpha one")
      session.record_read(a)

      run_agent([
                  tool_response(["tu_1", "edit_file",
                                 { "path" => a, "old_string" => "one", "new_string" => "two" }]),
                  tool_response(["tu_2", "sneaky_write", { "path" => a, "bytes" => "bash rewrote me" }]),
                  text_response("done")
                ])

      expect(events.size).to eq(2)
      final = events.last.body.fetch("files").fetch("a.txt")
      expect(events.first.body.fetch("files").fetch("a.txt")).not_to eq(final)
    end

    it "lands NO second event when bash rewrites the file to the SAME bytes" do
      a = write_file(dir, "a.txt", "alpha one")
      session.record_read(a)

      run_agent([
                  tool_response(["tu_1", "edit_file",
                                 { "path" => a, "old_string" => "one", "new_string" => "two" }]),
                  tool_response(["tu_2", "sneaky_write", { "path" => a, "bytes" => "alpha two" }]),
                  text_response("done")
                ])

      expect(events.size).to eq(1)
    end
  end

  describe "revert-to-a-previous-blob dedup" do
    # Observed (and pinned): reverting a file to bytes the FIRST snapshot
    # recorded, at the SAME causal parent, re-derives the first payload digest
    # AND the first envelope digest -- the "third" event IS the first event,
    # and Store#put stores nothing at all. Content addressing collapsing an
    # identical fact into one address is correct; through the Agent the causal
    # parent is a fresh tool_results turn each time, so real runs never
    # collapse envelopes. The observer still fires per write call, so an
    # observer-side record (scribe) would see the duplicate even when the
    # Store deduplicates it.
    it "collapses a revert-to-first-state at the same parent into the FIRST event's digests, storing nothing new" do
      a = write_file(dir, "a.txt", "v1")
      b = write_file(dir, "b.txt", "stable")
      timeline = committed_timeline

      first = writer.write(timeline:, paths: [a, b])
      File.binwrite(a, "v2")
      writer.write(timeline:, paths: [a, b])
      size_before_revert = timeline.store.size
      File.binwrite(a, "v1")
      third = writer.write(timeline:, paths: [a, b])

      expect(third).not_to be_nil
      expect(third.body.fetch("files").fetch("a.txt")).to eq(first.body.fetch("files").fetch("a.txt"))
      expect(third.digest).to eq(first.digest)
      expect(timeline.store.size).to eq(size_before_revert)
    end
  end

  describe "FIXED (was FINDING): deleting the ENTIRE write-set enters the record" do
    # The finding: Snapshot#write returned nil on ANY empty manifest -- the
    # early return that made "empty write-set lands nothing" true also made
    # "every write-set file was deleted" invisible, so the last snapshot kept
    # claiming the file existed and W2's restore would have resurrected it.
    # The fix distinguishes the two empties: empty with NO snapshot history is
    # nothing to say; empty AFTER a non-empty snapshot is a real record of
    # total deletion.
    it "lands an EMPTY snapshot when the last write-set file is deleted" do
      only = write_file(dir, "only.txt", "soon gone")
      timeline = committed_timeline
      first = writer.write(timeline:, paths: [only])
      expect(first.body.fetch("files")).to have_key("only.txt")

      File.delete(only)
      deletion = writer.write(timeline:, paths: [only])

      expect(deletion).not_to be_nil
      expect(deletion.body.fetch("files")).to eq({})
      expect(events.size).to eq(2)
    end

    it "records the corollary: recreating the file with the SAME bytes is a fresh snapshot" do
      only = write_file(dir, "only.txt", "soon gone")
      timeline = committed_timeline
      writer.write(timeline:, paths: [only])
      File.delete(only)
      writer.write(timeline:, paths: [only])

      write_file(dir, "only.txt", "soon gone")

      # The record saw the delete, so it must see the resurrection too.
      resurrection = writer.write(timeline:, paths: [only])
      expect(resurrection).not_to be_nil
      expect(resurrection.body.fetch("files")).to have_key("only.txt")
    end
  end

  describe "blob domain separation" do
    it "keeps a file whose bytes ARE a canonical dump from colliding with that value's canonical digest" do
      value = { "files" => { "/tmp/a" => "blake3:00" }, "snapshot_scope" => "x" }
      canonical_bytes = Lain::Canonical.dump(value)

      blob = Lain::Workspace::Snapshot::Blob.new(bytes: canonical_bytes)

      expect(blob.digest).not_to eq(Lain::Canonical.digest(value))
    end

    it "cannot be spoofed by prepending the header: content 'blob 5\\0hello' is not the blob of 'hello'" do
      spoof = Lain::Workspace::Snapshot::Blob.new(bytes: "blob 5\0hello".b)
      real = Lain::Workspace::Snapshot::Blob.new(bytes: "hello")

      expect(spoof.digest).not_to eq(real.digest)
    end

    it "holds mechanically: canonical dumps escape NUL, so no canonical byte-string contains the header's \\0" do
      expect(Lain::Canonical.dump("\x00")).not_to include("\x00")
    end
  end

  describe "edge bytes" do
    it "snapshots an EMPTY file as a real zero-byte blob" do
      empty = write_file(dir, "empty.txt", "")
      timeline = committed_timeline

      event = writer.write(timeline:, paths: [empty])

      digest = event.body.fetch("files").fetch("empty.txt")
      expect(timeline.store.fetch(digest).bytes).to eq("")
    end

    it "round-trips invalid-UTF-8 binary bytes through the Store" do
      bin = write_file(dir, "blob.bin", (+"\xff\xfe\x00\x01").force_encoding(Encoding::BINARY))
      timeline = committed_timeline

      event = writer.write(timeline:, paths: [bin])

      digest = event.body.fetch("files").fetch("blob.bin")
      expect(timeline.store.fetch(digest).bytes.bytes).to eq([0xff, 0xfe, 0x00, 0x01])
    end
  end

  describe "Ractor shareability of the new value object" do
    it "keeps Blob deeply frozen and Ractor-shareable" do
      blob = Lain::Workspace::Snapshot::Blob.new(bytes: "hello")

      expect(blob).to be_deeply_frozen
    end
  end

  describe "render invisibility, checked at the Request bytes" do
    it "renders byte-identical Requests before and after a snapshot lands" do
      path = write_file(dir, "a.txt", "alpha")
      timeline = committed_timeline
      context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024)
      toolset = Lain::Toolset.new([EchoTool.new])

      before = context.render(timeline:, toolset:, workspace: Lain::Workspace.empty)
      writer.write(timeline:, paths: [path])
      after = context.render(timeline:, toolset:, workspace: Lain::Workspace.empty)

      expect(after).to eq(before)
      expect(timeline.head_digest).to eq(timeline.head_digest) # head untouched by construction
    end
  end

  describe "the durable-record story stays a gap (accepted and ticketed)" do
    # Session::Journaled#record_write deliberately writes no journal line, and
    # the Agent's DEFAULT snapshot writer observes with ChainWriter::Null --
    # nothing in lib/lain/cli wires Workspace::Snapshot to the Chronicle's
    # scribe observer. The Store is an in-memory Hash. Consequences, pinned:
    #   * a replayed session rebuilds with an EMPTY write-set (handback admits);
    #   * the :snapshot events themselves are in NO journal, so they do not
    #     survive the process -- "the Store is the durable record" is only true
    #     within one process lifetime;
    #   * even wired to the scribe, Telemetry::Message carries the ENVELOPE +
    #     payload body, but Blob bytes have no journal representation at all,
    #     so a replay could re-put the event yet never fetch its blobs.
    # W2 (same-process restore) is unaffected; W4 (replay-restart) cannot
    # restore files from the record as it stands.
    it "pins that record_write journals nothing" do
      journal = []
      journaled = Lain::Session::Journaled.new(session: Lain::Session.new, journal:)

      journaled.record_write("/tmp/app.rb")

      expect(journal).to be_empty
    end

    it "pins that the default Agent wiring observes snapshots with Null -- no journal, no scribe" do
      # The default writer's observer is ChainWriter::Null; the only evidence a
      # snapshot leaves is the in-memory Store entry.
      path = write_file(dir, "a.txt", "alpha")
      timeline = committed_timeline
      default_writer = described_class.new

      event = default_writer.write(timeline:, paths: [path])

      expect(timeline.store.key?(event.digest)).to be(true) # in-process only
    end
  end
end
