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

    # The read-set's own window, so a claim about what it holds can be asserted
    # against IT rather than borrowed from the write-set's mirror.
    it "exposes #reads as the sorted, normalized, frozen paths" do
      session.record_read("/tmp/b.rb")
      session.record_read("/tmp/./a.rb")
      session.record_read("/tmp/b.rb")

      expect(session.reads).to eq(["/tmp/a.rb", "/tmp/b.rb"])
      expect(session.reads).to be_frozen
    end
  end

  # T22: the read-set distinguishes a WHOLE read from a partial one. A model
  # that saw only `<redacted:1>` and then writes the file clobbers every secret
  # in it, so `read?` answers true only for a complete read and
  # `partially_read?` names the other case -- letting a refusal say WHY rather
  # than claim the file was never read.
  describe "read completeness" do
    it "treats a read with no completeness argument as complete" do
      session.record_read("/tmp/app.rb")

      expect(session.read?("/tmp/app.rb")).to be(true)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
    end

    it "records a partial read as read-but-not-complete" do
      session.record_read("/tmp/app.rb", complete: false)

      expect(session.read?("/tmp/app.rb")).to be(false)
      expect(session.partially_read?("/tmp/app.rb")).to be(true)
    end

    it "distinguishes a partial read from no read at all" do
      session.record_read("/tmp/partial.rb", complete: false)

      expect(session.partially_read?("/tmp/partial.rb")).to be(true)
      expect(session.read?("/tmp/partial.rb")).to be(false)

      expect(session.partially_read?("/tmp/never.rb")).to be(false)
      expect(session.read?("/tmp/never.rb")).to be(false)
    end

    it "upgrades a partial read when the same path is later read complete" do
      session.record_read("/tmp/app.rb", complete: false)
      session.record_read("/tmp/app.rb")

      expect(session.read?("/tmp/app.rb")).to be(true)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
    end

    # The monotonicity property the parallel-safe tools depend on: completeness
    # is add-only, so two sibling fibers reading the same file cannot race a
    # complete read back down to a partial one. An implementation that stores
    # the bit as a plain overwrite fails exactly here.
    it "never downgrades a complete read when the same path is later read partially" do
      session.record_read("/tmp/app.rb")
      session.record_read("/tmp/app.rb", complete: false)

      expect(session.read?("/tmp/app.rb")).to be(true)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
    end

    it "carries completeness across spellings, as the read-set carries membership" do
      Dir.chdir("/tmp") do
        session.record_read("./app.rb", complete: false)

        expect(session.partially_read?("app.rb")).to be(true)

        session.record_read("app.rb")

        expect(session.read?("./app.rb")).to be(true)
      end
    end

    # PANEL FINDING (fix 1). The write boundary trusted TRUTHINESS while the
    # Replay boundary demanded a strict boolean, so the two disagreed in the
    # unsafe direction: `complete: "false"` recorded a COMPLETE read. The
    # refusal has to land before either Set is touched, or a caller that
    # rescues is left holding live state MORE permissive than what replays --
    # inverting the one-way property the whole design rests on.
    it "refuses a non-boolean completeness rather than reading it for truthiness" do
      ["false", "true", 0, 1, nil, "", :yes, [], {}].each do |bogus|
        expect { session.record_read("/tmp/app.rb", complete: bogus) }
          .to raise_error(ArgumentError, /complete must be true or false/), "accepted #{bogus.inspect}"
      end
    end

    it "records NOTHING when it refuses a non-boolean -- the check precedes both mutations" do
      expect { session.record_read("/tmp/app.rb", complete: "false") }.to raise_error(ArgumentError)

      expect(session.read?("/tmp/app.rb")).to be(false)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
      expect(session.reads).to eq([])
    end

    it "lists a partially read path in #reads -- it was read, just not wholly" do
      session.record_read("/tmp/partial.rb", complete: false)

      expect(session.reads).to eq(["/tmp/partial.rb"])
      expect(session.read?("/tmp/partial.rb")).to be(false)
    end
  end

  # T22 drives the REAL tools here rather than restating their preconditions,
  # so the assertion is about the contract `edit_file`/`write_file` actually
  # declare. The file's bytes are asserted too: a refusal that did not in fact
  # protect the contents would otherwise pass on `is_error` alone.
  describe "the edit contract and read completeness", :seam do
    # A refused precondition RAISES {Lain::Tool::ContractViolation}; it does
    # not return an error Result. So the attempt is handed over unevaluated and
    # each example expects its own shape. The file's bytes come back either
    # way: a refusal that did not in fact protect the contents would otherwise
    # pass on the exception alone.
    def edit_after(*completions)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hello.txt")
        File.write(path, "hello world")
        session = described_class.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {}))
        completions.each { |complete| session.record_read(path, complete:) }
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
        edit = { path: "hello.txt", old_string: "hello", new_string: "goodbye" }

        yield -> { Lain::Tools::EditFile.new.call(edit, invocation) }, -> { File.read(path) }
      end
    end

    it "satisfies edit_file's precondition after a complete read" do
      edit_after(true) do |attempt, contents|
        result = attempt.call
        expect(result.is_error).to be(false), -> { "edit_file refused: #{result.content}" }
        expect(contents.call).to eq("goodbye world")
      end
    end

    # Only the exception CLASS is pinned, not its wording: the current message
    # still says "never read", which is the thing `partially_read?` exists to
    # let a refusal stop claiming. Sharpening it belongs with the middleware
    # that knows the read was redacted (T15), not here.
    it "fails edit_file's precondition after a partial read, leaving the file untouched" do
      edit_after(false) do |attempt, contents|
        expect { attempt.call }.to raise_error(Lain::Tool::ContractViolation)
        expect(contents.call).to eq("hello world")
      end
    end

    it "satisfies edit_file's precondition once a partial read is upgraded by a complete one" do
      edit_after(false, true) do |attempt, contents|
        result = attempt.call
        expect(result.is_error).to be(false), -> { "edit_file refused: #{result.content}" }
        expect(contents.call).to eq("goodbye world")
      end
    end

    it "keeps edit_file's precondition satisfied when a complete read is followed by a partial one" do
      edit_after(true, false) do |attempt, contents|
        result = attempt.call
        expect(result.is_error).to be(false), -> { "edit_file refused: #{result.content}" }
        expect(contents.call).to eq("goodbye world")
      end
    end

    # write_file's contract is NARROWER than edit_file's: it allows a create
    # over a path that does not exist, which no read could ever have covered.
    # Completeness must not accidentally block that.
    it "still lets write_file create a path that was never read" do
      Dir.mktmpdir do |dir|
        session = described_class.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {}))
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)

        result = Lain::Tools::WriteFile.new.call({ path: "new.txt", content: "hi" }, invocation)

        expect(result.is_error).to be(false), -> { "write_file refused: #{result.content}" }
        expect(File.read(File.join(dir, "new.txt"))).to eq("hi")
      end
    end

    # The case this card exists for: the model saw a redacted rendering, so an
    # overwrite would clobber the secrets it never actually read.
    it "refuses write_file's overwrite of a file seen only partially" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "existing.txt")
        File.write(path, "secret")
        session = described_class.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {}))
        session.record_read(path, complete: false)
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)

        expect do
          Lain::Tools::WriteFile.new.call({ path: "existing.txt", content: "clobbered" }, invocation)
        end.to raise_error(Lain::Tool::ContractViolation)
        expect(File.read(path)).to eq("secret")
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

    # normalize_path's `to_s` claims to cover "the Symbol and nil spellings a
    # Set query may arrive in", but nil and "" both already resolve to cwd
    # through WorkerEnv#resolve itself -- a SYMBOL is the only input that
    # discriminates. It cannot join the equivalence example above, because that
    # compares against `worker_env.resolve` RAW and File.expand_path(:sym, cwd)
    # is a TypeError; supplying the coercion is the whole point of the clause.
    it "coerces a Symbol spelling, the only input its to_s actually covers" do
      expect(described_class.normalize_path(:notes, cwd:)).to eq(File.join(cwd, "notes"))
      expect { Lain::WorkerEnv.new(cwd:, env: {}).resolve(:notes) }.to raise_error(TypeError)
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
      expect(null.reads).to eq([])
    end

    # T22: the completeness duck too, so a tool holding a Null never has to
    # guard before asking. Records nothing, so it reports NEITHER read nor
    # partially read -- the "no read at all" answer, for every path.
    it "keeps the completeness duck a no-op: a partial read records nothing either" do
      expect { null.record_read("/tmp/app.rb", complete: false) }.not_to raise_error
      expect(null.read?("/tmp/app.rb")).to be(false)
      expect(null.partially_read?("/tmp/app.rb")).to be(false)
      expect(null.reads).to eq([])
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
      # DIFFERENT string than the read-set holds would still pass. T22 gave the
      # read-set its own `#reads` window, so this compares against the very set
      # under discussion rather than borrowing the write-set's mirror.
      it "journals the very string the read-set holds, not merely a spelling of it" do
        journaled.record_read("notes.md")

        recorded = of_type("session_read").map(&:path)
        expect(recorded).to eq([File.join(cwd, "notes.md")])
        expect(recorded).to eq(inner.reads)
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
      expect { Lain::Telemetry::SessionRead.new(path: nil, complete: true) }
        .to raise_error(ArgumentError, "path must name the file read, got nil")
    end

    # `complete` follows SessionPin's `pinned` precedent exactly: a STRICT
    # boolean, never `presence:`, which would silently reject `false` -- and
    # `false` is the redacted read this field exists to express.
    # PANEL FINDING (fix 3): `[]` and `{}` are in this list deliberately.
    # ActiveModel's InclusionValidator reads an ARRAY value as "every member
    # must be in the set", and `[].all?` is vacuously true -- so an `inclusion:`
    # validator accepted `complete: []` and journaled `"complete":[]` while its
    # docstring claimed strict-boolean. The guard is an explicit check now.
    it "pins SessionRead's completeness guard: a non-boolean raises at construction" do
      ["false", "true", 0, 1, nil, "", :yes, [], {}, [true]].each do |bogus|
        expect { Lain::Telemetry::SessionRead.new(path: "/tmp/a.rb", complete: bogus) }
          .to raise_error(ArgumentError, /complete must be true or false/), "accepted #{bogus.inspect}"
      end
    end

    it "accepts complete: false without tripping the guard" do
      expect(Lain::Telemetry::SessionRead.new(path: "/tmp/a.rb", complete: false).complete).to be(false)
    end

    # T22: the decorator journals a read-set STATE TRANSITION, not a call. The
    # dedupe that keeps a read/edit loop from emitting one line per iteration
    # has to survive the completeness bit, and each surviving line has to say
    # WHICH thing the model saw.
    describe "journaling read completeness" do
      it "journals one line, flagged complete, for a whole read" do
        journaled.record_read("/tmp/app.rb")

        expect(of_type("session_read").map { |r| [r.path, r.complete] }).to eq([["/tmp/app.rb", true]])
      end

      it "journals one line, flagged incomplete, for a partial read" do
        journaled.record_read("/tmp/app.rb", complete: false)

        expect(of_type("session_read").map { |r| [r.path, r.complete] }).to eq([["/tmp/app.rb", false]])
      end

      # The flood this dedupe exists to prevent, in its new form: a loop
      # re-reading the same REDACTED file must not journal per iteration.
      it "journals nothing on a re-read at the same completeness" do
        3.times { journaled.record_read("/tmp/app.rb", complete: false) }

        expect(of_type("session_read").size).to eq(1)
      end

      # Two lines is correct here, and is the one case that legitimately emits
      # a second: the model genuinely saw two different things.
      it "journals a second line when a partial read is upgraded to a complete one" do
        journaled.record_read("/tmp/app.rb", complete: false)
        journaled.record_read("/tmp/app.rb")

        expect(of_type("session_read").map(&:complete)).to eq([false, true])
      end

      # The mirror of the monotonicity AC, in the record stream: a complete
      # read is never followed by a line that could replay as a downgrade.
      it "journals nothing when a complete read is followed by a partial one" do
        journaled.record_read("/tmp/app.rb")
        journaled.record_read("/tmp/app.rb", complete: false)

        expect(of_type("session_read").map(&:complete)).to eq([true])
      end
    end

    # PANEL FINDING (fix 1), at the layer where it actually bit: the record
    # guard DID raise, but only after the wrapped Session had already mutated,
    # leaving a complete read in the set and nothing in the Journal -- live
    # state strictly more permissive than replayed state. The refusal now
    # happens inside the wrapped Session, so neither layer moves.
    it "leaves neither the read-set nor the Journal touched when completeness is a non-boolean" do
      expect { journaled.record_read("/tmp/app.rb", complete: "false") }.to raise_error(ArgumentError)

      expect(inner.read?("/tmp/app.rb")).to be(false)
      expect(inner.partially_read?("/tmp/app.rb")).to be(false)
      expect(of_type("session_read")).to be_empty
    end

    it "forwards partially_read? and reads to the wrapped Session" do
      journaled.record_read("/tmp/partial.rb", complete: false)

      expect(journaled.partially_read?("/tmp/partial.rb")).to be(true)
      expect(journaled.read?("/tmp/partial.rb")).to be(false)
      expect(journaled.reads).to eq(["/tmp/partial.rb"])
      expect(inner.partially_read?("/tmp/partial.rb")).to be(true)
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
