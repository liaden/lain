# frozen_string_literal: true

RSpec.describe Lain::Session do
  subject(:session) { described_class.new }

  describe "the read-set" do
    it "records a read and answers read? true for it, false for paths never read" do
      session.record_read("/tmp/app.rb")

      expect(session.read?("/tmp/app.rb")).to be(true)
      expect(session.read?("/tmp/other.rb")).to be(false)
    end

    # Path identity is pinned: two spellings of the same file must not defeat
    # the read-set, or an edit-before-read contract would be trivially bypassed.
    it "matches across spellings of the same path (expand_path normalizes both ends)" do
      Dir.chdir("/tmp") do
        session.record_read("./app.rb")

        expect(session.read?("app.rb")).to be(true)
        expect(session.read?("/tmp/app.rb")).to be(true)
      end
    end

    it "matches when the recorded spelling is bare and the query is dotted" do
      Dir.chdir("/tmp") do
        session.record_read("app.rb")

        expect(session.read?("./app.rb")).to be(true)
      end
    end
  end

  describe "#reminders" do
    it "is empty before any todo_write lands" do
      expect(session.reminders).to eq([])
    end
  end

  describe "#write_todos" do
    def todo(content, status) = Struct.new(:content, :status).new(content, status)

    it "renders the whole list as ONE reminder string (Manifest#to_reminder's precedent)" do
      session.write_todos([todo("write the spec", "in_progress"), todo("ship it", "pending")])

      expect(session.reminders).to eq(["Current todo list:\n- [in_progress] write the spec\n- [pending] ship it"])
    end

    it "replaces the whole list on a later call rather than merging" do
      session.write_todos([todo("a", "pending")])
      session.write_todos([todo("b", "completed")])

      expect(session.reminders).to eq(["Current todo list:\n- [completed] b"])
    end

    it "goes back to no reminder when the new list is empty" do
      session.write_todos([todo("a", "pending")])
      session.write_todos([])

      expect(session.reminders).to eq([])
    end
  end

  describe "#reminders with a memory source" do
    def todo(content, status) = Struct.new(:content, :status).new(content, status)

    def item(id, description)
      Lain::Memory::Item.new(id:, description:, body: "body of #{id}")
    end

    let(:recorder) { Lain::Memory::Recorder.new }

    subject(:session) { described_class.new(memory: recorder) }

    it "adds nothing while the index is empty" do
      expect(session.reminders).to eq([])
    end

    # AC5: composition is deterministic -- two reads with no writes between
    # them are byte-identical, each block appears exactly once, and the todo
    # block precedes the manifest block.
    it "composes todos then manifest deterministically, each block exactly once" do
      recorder.write(item("aspirin-dosing", "Aspirin dosing bounds for adults"))
      session.write_todos([todo("check interactions", "pending")])

      first = session.reminders
      second = session.reminders

      expect(first).to eq(second)
      expect(first.size).to eq(2)
      expect(first.first).to start_with("Current todo list:")
      expect(first.last).to include("aspirin-dosing | Aspirin dosing bounds for adults")
      expect(first.count { |block| block.include?("Current todo list:") }).to eq(1)
      expect(first.count { |block| block.include?("aspirin-dosing |") }).to eq(1)
    end

    # Ruling (a): #reminders runs on EVERY render, so the manifest block is
    # memoized keyed by the recorder's index root -- the content address is
    # the invalidation key. Same root, same String OBJECT.
    it "memoizes the rendered manifest block until the index root moves" do
      recorder.write(item("aspirin-dosing", "Aspirin dosing bounds for adults"))

      expect(session.reminders.last).to be(session.reminders.last)

      recorder.write(item("warfarin-interactions", "Warfarin interaction list"))
      expect(session.reminders.last)
        .to include("aspirin-dosing | Aspirin dosing bounds for adults")
        .and include("warfarin-interactions | Warfarin interaction list")
    end

    # Ruling (b): the block is labeled at the SESSION layer, naming
    # memory_read as the way to open an id; Manifest#to_reminder stays bare.
    it "labels the manifest block, naming memory_read as the way to open an id" do
      recorder.write(item("aspirin-dosing", "Aspirin dosing bounds for adults"))

      expect(session.reminders.last.lines.first).to include("memory_read")
    end
  end

  describe Lain::Session::Null do
    subject(:null) { described_class.instance }

    it "satisfies the Session duck without raising: record_read is a no-op, read? is false" do
      expect { null.record_read("/tmp/app.rb") }.not_to raise_error
      expect(null.read?("/tmp/app.rb")).to be(false)
    end

    it "keeps write_todos a no-op that never raises" do
      expect { null.write_todos([Struct.new(:content, :status).new("a", "pending")]) }.not_to raise_error
      expect(null.reminders).to eq([])
    end

    it "has no reminders" do
      expect(null.reminders).to eq([])
    end

    it "is a shared, frozen instance" do
      expect(null).to be_deeply_frozen
      expect(described_class.instance).to be(null)
    end
  end

  # T16: the decorator that journals a real Session's reads/todos while
  # leaving Session itself with no journal in sight (every example above this
  # block constructs a plain Session and never mentions one).
  describe Lain::Session::Journaled do
    def todo(content, status) = Struct.new(:content, :status).new(content, status)

    let(:inner) { Lain::Session.new }
    let(:journal) { [] }

    subject(:journaled) { described_class.new(session: inner, journal:) }

    def of_type(type) = journal.select { |record| record.journal_type == type }

    it "forwards record_read/read? to the wrapped Session, unchanged behavior" do
      journaled.record_read("/tmp/app.rb")

      expect(journaled.read?("/tmp/app.rb")).to be(true)
      expect(inner.read?("/tmp/app.rb")).to be(true)
    end

    it "journals a SessionRead the FIRST time a path is read, with the expand_path-normalized path" do
      Dir.chdir("/tmp") { journaled.record_read("./app.rb") }

      reads = of_type("session_read")
      expect(reads.size).to eq(1)
      expect(reads.first.path).to eq("/tmp/app.rb")
    end

    it "journals nothing on a re-read of the same path (any spelling) -- no chatty per-iteration lines" do
      journaled.record_read("/tmp/app.rb")
      journaled.record_read("/tmp/app.rb")
      Dir.chdir("/tmp") { journaled.record_read("app.rb") }

      expect(of_type("session_read").size).to eq(1)
    end

    it "journals a fresh SessionRead for a genuinely different path" do
      journaled.record_read("/tmp/app.rb")
      journaled.record_read("/tmp/other.rb")

      expect(of_type("session_read").map(&:path)).to contain_exactly("/tmp/app.rb", "/tmp/other.rb")
    end

    # The record the decorator emits carries a construction contract of its
    # own (the validate-then-freeze convention): a pathless read record could
    # never replay, so it must fail loudly at construction, not at load.
    it "pins SessionRead's guard: a nil path raises at construction" do
      expect { Lain::Telemetry::SessionRead.new(path: nil) }
        .to raise_error(ArgumentError, "path must name the file read, got nil")
    end

    it "journals every write_todos call as a whole-list TodoSnapshot, forwarding to the wrapped Session too" do
      journaled.write_todos([todo("a", "pending")])
      journaled.write_todos([todo("b", "completed")])

      snapshots = of_type("todo_snapshot")
      expect(snapshots.size).to eq(2)
      expect(snapshots.first.todos).to eq([{ "content" => "a", "status" => "pending" }])
      expect(snapshots.last.todos).to eq([{ "content" => "b", "status" => "completed" }])
      expect(inner.reminders).to eq(["Current todo list:\n- [completed] b"])
    end

    it "reflects the wrapped Session's reminders" do
      journaled.write_todos([todo("a", "pending")])

      expect(journaled.reminders).to eq(inner.reminders)
    end
  end
end
