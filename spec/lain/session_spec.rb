# frozen_string_literal: true

require "tmpdir"

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

  # T7: the base a relative path resolves against is the SESSION's worker cwd,
  # not the process's. Under isolation the two differ, so a Dir.pwd-relative
  # record names a file the session never read.
  describe "path identity under a worker cwd that is not the process directory" do
    subject(:session) { described_class.new(worker_env: Lain::WorkerEnv.new(cwd:, env: {})) }

    let(:cwd) { File.join(Dir.tmpdir, "lain-t7-repo", "sub") }

    it "resolves a relative read against the worker cwd" do
      session.record_read("notes.md")

      expect(session.read?(File.join(cwd, "notes.md"))).to be(true)
      expect(session.read?(File.expand_path("notes.md", Dir.pwd))).to be(false)
    end

    it "honors an absolute path as given" do
      session.record_read("/etc/hosts")

      expect(session.read?("/etc/hosts")).to be(true)
    end

    it "resolves the write-set against the same cwd" do
      session.record_write("notes.md")

      expect(session.writes).to eq([File.join(cwd, "notes.md")])
    end

    it "takes the base as an explicit argument, so the class method has one too" do
      expect(described_class.normalize_path("notes.md", cwd:)).to eq(File.join(cwd, "notes.md"))
      expect(described_class.normalize_path("/etc/hosts", cwd:)).to eq("/etc/hosts")
    end

    # The read-set resolves through WorkerEnv's rule rather than owning a
    # second copy of it, so the two cannot drift. Pinned as an equivalence
    # across the spellings that would distinguish them: re-inline an
    # expand_path here and a change to WorkerEnv#resolve stops reaching the
    # read-set, which is what this catches.
    it "resolves exactly as WorkerEnv#resolve does, spelling for spelling" do
      worker_env = Lain::WorkerEnv.new(cwd:, env: {})
      spellings = [nil, "", "x.rb", "./x.rb", "../x.rb", "/abs/x.rb", "a//b/./c"]

      through_session = spellings.to_h { |spelling| [spelling, described_class.normalize_path(spelling, cwd:)] }

      expect(through_session).to eq(spellings.to_h { |spelling| [spelling, worker_env.resolve(spelling)] })
    end

    it "ignores a Dir.chdir under it -- the session's cwd is the base, the process's is not" do
      Dir.chdir(Dir.tmpdir) { session.record_read("notes.md") }

      expect(session.read?(File.join(cwd, "notes.md"))).to be(true)
    end
  end

  # T7: the edit-before-read contract resolves through the same worker cwd, so
  # the spelling the model happens to send cannot defeat it.
  describe "the edit contract across spellings", :seam do
    it "satisfies edit_file's precondition for a relative path read absolutely" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hello.txt")
        File.write(path, "hello world")
        session = described_class.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {}))
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)

        read = Lain::Tools::ReadFile.new.call({ path: }, invocation)
        edit = Lain::Tools::EditFile.new.call(
          { path: "hello.txt", old_string: "hello", new_string: "goodbye" }, invocation
        )

        # The refusal text is carried into the failure message on purpose: a
        # bare `is_error: false` reports "expected false, got true" and throws
        # away the one string that says WHY the contract went unmet.
        expect(read.is_error).to be(false), -> { "read_file refused: #{read.content}" }
        expect(edit.is_error).to be(false), -> { "edit_file refused: #{edit.content}" }
        expect(File.read(path)).to eq("goodbye world")
      end
    end
  end

  # The write-set mirrors the read-set's shape on purpose: same normalization,
  # same accumulate-for-the-run lifetime. It is what scopes the workspace
  # snapshot (Lain::Workspace::Snapshot) -- write-set only, the documented gap.
  describe "the write-set" do
    it "records a write and answers written? true for it, false for paths never written" do
      session.record_write("/tmp/app.rb")

      expect(session.written?("/tmp/app.rb")).to be(true)
      expect(session.written?("/tmp/other.rb")).to be(false)
    end

    it "matches across spellings of the same path (expand_path normalizes both ends)" do
      Dir.chdir("/tmp") do
        session.record_write("./app.rb")

        expect(session.written?("app.rb")).to be(true)
        expect(session.written?("/tmp/app.rb")).to be(true)
      end
    end

    it "stays independent of the read-set: a write is not a read, a read is not a write" do
      session.record_write("/tmp/written.rb")
      session.record_read("/tmp/read.rb")

      expect(session.read?("/tmp/written.rb")).to be(false)
      expect(session.written?("/tmp/read.rb")).to be(false)
    end

    it "exposes #writes as the sorted, normalized, frozen paths -- deterministic snapshot input" do
      session.record_write("/tmp/b.rb")
      session.record_write("/tmp/./a.rb")
      session.record_write("/tmp/b.rb")

      expect(session.writes).to eq(["/tmp/a.rb", "/tmp/b.rb"])
      expect(session.writes).to be_frozen
    end

    it "has an empty write-set before any write lands" do
      expect(session.writes).to eq([])
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

    subject(:session) { described_class.new(memory: recorder) }

    let(:recorder) { Lain::Memory::Recorder.new }

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

    it "keeps the write-set duck a no-op: record_write records nothing, writes stays empty" do
      expect { null.record_write("/tmp/app.rb") }.not_to raise_error
      expect(null.written?("/tmp/app.rb")).to be(false)
      expect(null.writes).to eq([])
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

    # T7: one frozen instance cannot capture a directory that moves under it,
    # so its worker_env is recomputed per call and a bare tool still resolves
    # against the LIVE process directory.
    it "keeps tracking the process directory across a Dir.chdir" do
      here = Lain::Session.normalize_path("app.rb", cwd: null.worker_env.cwd)
      there = Dir.chdir(Dir.tmpdir) do
        Lain::Session.normalize_path("app.rb", cwd: null.worker_env.cwd)
      end

      expect(there).to eq(File.join(Dir.chdir(Dir.tmpdir) { Dir.pwd }, "app.rb"))
      expect(there).not_to eq(here)
    end
  end

  # T16: the decorator that journals a real Session's reads/todos while
  # leaving Session itself with no journal in sight (every example above this
  # block constructs a plain Session and never mentions one).
  describe Lain::Session::Journaled do
    def todo(content, status) = Struct.new(:content, :status).new(content, status)

    subject(:journaled) { described_class.new(session: inner, journal:) }

    let(:inner) { Lain::Session.new }
    let(:journal) { [] }

    def of_type(type) = journal.select { |record| record.journal_type == type }

    it "forwards record_read/read? to the wrapped Session, unchanged behavior" do
      journaled.record_read("/tmp/app.rb")

      expect(journaled.read?("/tmp/app.rb")).to be(true)
      expect(inner.read?("/tmp/app.rb")).to be(true)
    end

    it "forwards the write-set to the wrapped Session, journaling nothing (persistence is a separate ticket)" do
      journaled.record_write("/tmp/app.rb")

      expect(journaled.written?("/tmp/app.rb")).to be(true)
      expect(inner.written?("/tmp/app.rb")).to be(true)
      expect(journaled.writes).to eq(["/tmp/app.rb"])
    end

    it "journals a SessionRead the FIRST time a path is read, with the expand_path-normalized path" do
      Dir.chdir("/tmp") { journaled.record_read("./app.rb") }

      reads = of_type("session_read")
      expect(reads.size).to eq(1)
      expect(reads.first.path).to eq("/tmp/app.rb")
    end

    # The wrapped session's cwd is pinned rather than inherited from the
    # process, so "any spelling" can mean what it says: absolute, bare
    # relative and dotted relative all reach the same file.
    context "when the wrapped session's worker cwd is /tmp" do
      let(:inner) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/tmp", env: {})) }

      it "journals nothing on a re-read of the same path (any spelling) -- no chatty per-iteration lines" do
        journaled.record_read("/tmp/app.rb")
        journaled.record_read("app.rb")
        journaled.record_read("./app.rb")

        expect(of_type("session_read").size).to eq(1)
      end
    end

    # T7: the decorator must journal the string the READ-SET holds. It has no
    # cwd of its own, so it takes the wrapped session's -- otherwise the
    # Journal (the experiment record) names a different file than #read? does.
    context "when the wrapped session's worker cwd is not the process directory" do
      let(:cwd) { File.join(Dir.tmpdir, "lain-t7-journal") }
      let(:inner) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: {})) }

      # Asserted as BYTE-identity, not as `read?(recorded)`: `read?`
      # re-normalizes its argument, so it would answer true for any spelling
      # that merely resolves to the same file, and a decorator journaling a
      # DIFFERENT string than the read-set holds would still pass. `#writes` is
      # a public window onto the same {Session#normalize}, so comparing against
      # it costs nothing and closes that gap.
      it "journals the very string the read-set holds, not merely a spelling of it" do
        journaled.record_read("notes.md")

        recorded = of_type("session_read").map(&:path)
        expect(recorded).to eq([File.join(cwd, "notes.md")])
        expect(recorded).to eq(inner.record_write("notes.md").writes)
      end
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
