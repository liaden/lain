# frozen_string_literal: true

require "fileutils"
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

  # The read-set distinguishes a WHOLE read from a partial one. A model that
  # saw only part of a file and then writes it clobbers the lines it never
  # saw, so `read?` answers true only once the lines read cover the file and
  # `partially_read?` names the other case -- letting a refusal say WHY rather
  # than claim the file was never read.
  describe "read completeness" do
    let(:version) { Lain::Session::FileIdentity.new(device: 1, inode: 2, size: 3, mtime: 4) }

    def read(path, lines, identity: version) = session.record_read(path, lines:, identity:)

    it "treats a read with no span as a read of the whole file" do
      session.record_read("/tmp/app.rb")

      expect(session.read?("/tmp/app.rb")).to be(true)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
    end

    it "records a window that stopped short as read-but-not-complete" do
      read("/tmp/app.rb", 1..10)

      expect(session.read?("/tmp/app.rb")).to be(false)
      expect(session.partially_read?("/tmp/app.rb")).to be(true)
    end

    it "distinguishes a partial read from no read at all" do
      read("/tmp/partial.rb", 1..10)

      expect(session.partially_read?("/tmp/partial.rb")).to be(true)
      expect(session.partially_read?("/tmp/never.rb")).to be(false)
      expect(session.read?("/tmp/never.rb")).to be(false)
    end

    it "upgrades a partial read when the same version is later read whole" do
      read("/tmp/app.rb", 1..10)
      read("/tmp/app.rb", 1..)

      expect(session.read?("/tmp/app.rb")).to be(true)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
    end

    # The monotonicity property the parallel-safe tools depend on: nothing is
    # removed, so two sibling fibers reading the same file cannot race a whole
    # read back down to a partial one. An implementation that stores the answer
    # as a plain overwrite fails exactly here.
    it "never downgrades a complete read when the same path is later read partially" do
      read("/tmp/app.rb", 1..)
      read("/tmp/app.rb", 1..10)

      expect(session.read?("/tmp/app.rb")).to be(true)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
    end

    describe "windows that add up" do
      it "counts two windows that meet end to end as a whole read" do
        read("/tmp/app.rb", 1..450)
        read("/tmp/app.rb", 451..)

        expect(session.read?("/tmp/app.rb")).to be(true)
      end

      it "counts them in either order, and overlapping" do
        read("/tmp/app.rb", 400..)
        read("/tmp/app.rb", 1..500)

        expect(session.read?("/tmp/app.rb")).to be(true)
      end

      it "leaves a gap between windows partial" do
        read("/tmp/app.rb", 1..10)
        read("/tmp/app.rb", 12..)

        expect(session.read?("/tmp/app.rb")).to be(false)
        expect(session.partially_read?("/tmp/app.rb")).to be(true)
      end

      it "leaves windows that never reach the end of the file partial" do
        read("/tmp/app.rb", 1..10)
        read("/tmp/app.rb", 11..20)

        expect(session.read?("/tmp/app.rb")).to be(false)
      end

      it "does not add up windows over two versions of the file" do
        read("/tmp/app.rb", 1..450)
        read("/tmp/app.rb", 451.., identity: version.with(size: 99))

        expect(session.read?("/tmp/app.rb")).to be(false)
        expect(session.partially_read?("/tmp/app.rb")).to be(true)
      end
    end

    it "carries completeness across spellings, as the read-set carries membership" do
      Dir.chdir("/tmp") do
        read("./app.rb", 1..10)

        expect(session.partially_read?("app.rb")).to be(true)

        read("app.rb", 11..)

        expect(session.read?("./app.rb")).to be(true)
      end
    end

    # The write boundary must be as strict as the Replay boundary, or the two
    # disagree in the unsafe direction: a span read loosely is more of the file
    # than the model saw. The refusal has to land before anything is recorded,
    # or a caller that rescues is left holding live state MORE permissive than
    # what replays.
    it "refuses a span that names no lines rather than reading it loosely" do
      [1...10, 0..10, 10..5, "1..10", nil, [1, 10], (1.0..), ("a".."z")].each do |bogus|
        expect { read("/tmp/app.rb", bogus) }
          .to raise_error(ArgumentError, /lines must be a Range of line numbers/), "accepted #{bogus.inspect}"
      end
    end

    it "refuses a call id or a head that is not a String" do
      expect { session.record_read("/tmp/app.rb", identity: version, tool_use_id: 1) }
        .to raise_error(ArgumentError, /tool_use_id must be a String or nil/)
      expect { session.record_read("/tmp/app.rb", identity: version, tool_use_id: "tu_1", head: :h) }
        .to raise_error(ArgumentError, /head must be a String or nil/)
    end

    it "records NOTHING when it refuses -- the check precedes the mutation" do
      expect { read("/tmp/app.rb", 1...10) }.to raise_error(ArgumentError)

      expect(session.read?("/tmp/app.rb")).to be(false)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
      expect(session.reads).to eq([])
    end

    it "lists a partially read path in #reads -- it was read, just not wholly" do
      read("/tmp/partial.rb", 1..10)

      expect(session.reads).to eq(["/tmp/partial.rb"])
      expect(session.read?("/tmp/partial.rb")).to be(false)
    end

    it "names a version by what a stat says, and one version for a path with nothing there" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "a.rb")
        File.write(path, "one\n")
        stat = File.stat(path)

        expect(Lain::Session::FileIdentity.of(path))
          .to have_attributes(device: stat.dev, inode: stat.ino, size: 4,
                              mtime: (stat.mtime.tv_sec * 1_000_000_000) + stat.mtime.tv_nsec)
        expect(Lain::Session::FileIdentity.of(File.join(dir, "missing.rb"))).to eq(Lain::Session::FileIdentity::ABSENT)
      end
    end
  end

  # A read counts only while the turn that delivered it is on the chain the
  # question is asked about. The chain moves -- a rewind, a fork -- and the
  # read-set never forgets anything, so what changes is which reads count.
  describe "a read counted against the chain" do
    let(:store) { Lain::Store.new }
    let(:root) { Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }]) }
    let(:version) { Lain::Session::FileIdentity.new(device: 1, inode: 2, size: 3, mtime: 4) }

    def calls(*ids) = ids.map { |id| { "type" => "tool_use", "id" => id, "name" => "read_file", "input" => {} } }

    def results(*ids, is_error: false)
      ids.map { |id| { "type" => "tool_result", "tool_use_id" => id, "content" => "bytes", "is_error" => is_error } }
    end

    # One tool round the way ToolDelivery runs it: the round opens on the
    # assistant turn's chain, the reads land, and the result turn delivers them.
    def round(timeline, id, lines: Lain::Session::WHOLE_FILE, path: "/tmp/app.rb", is_error: false)
      asked = timeline.commit(role: :assistant, content: calls(id))
      session.on_chain(asked)
      session.record_read(path, lines:, identity: version, tool_use_id: id)
      delivered = asked.commit(role: :user, content: results(id, is_error:))
      session.record_delivery(digest: delivered.head_digest, parent: asked.head_digest, content: delivered.head.content)
      delivered
    end

    it "counts a read whose delivering turn is on the chain" do
      after = round(root, "tu_1")
      session.on_chain(after.commit(role: :assistant, content: calls("tu_2")))

      expect(session.read?("/tmp/app.rb")).to be(true)
    end

    it "stops counting it once the chain is rewound past that turn, and never forgets it" do
      after = round(root, "tu_1")
      session.on_chain(after.rewind(2).commit(role: :assistant, content: calls("tu_2")))

      expect(session.read?("/tmp/app.rb")).to be(false)
      expect(session.partially_read?("/tmp/app.rb")).to be(false)
      expect(session.reads).to eq(["/tmp/app.rb"])
    end

    # Asked at every stop, so the per-head cache is walked away from the turn
    # and back to it: a cache that never reset would pass a question asked only
    # at the end.
    it "counts it again when the chain comes back to that turn" do
      after = round(root, "tu_1")
      session.on_chain(root)
      expect(session.read?("/tmp/app.rb")).to be(false)

      session.on_chain(after)
      expect(session.read?("/tmp/app.rb")).to be(true)
    end

    # The round a delivery binds is named by the head it opened on as well as
    # the call id: a turn answering the same id from another head -- a repair
    # of a torn round, a sibling branch -- binds nothing of this round.
    it "binds a delivery only to the reads of the round that opened on its parent" do
      asked = root.commit(role: :assistant, content: calls("ollama-tool-0"))
      session.on_chain(asked)
      session.record_read("/tmp/app.rb", identity: version, tool_use_id: "ollama-tool-0")
      elsewhere = root.commit(role: :assistant, content: [{ "type" => "text", "text" => "a sibling" }])
      stranger = elsewhere.commit(role: :user, content: results("ollama-tool-0"))

      session.record_delivery(digest: stranger.head_digest, parent: elsewhere.head_digest,
                              content: stranger.head.content)
      session.on_chain(stranger)

      expect(session.read?("/tmp/app.rb")).to be(false)
    end

    it "leaves the window still on the chain partial when the other one is rewound away" do
      top = round(root, "tu_1", lines: 1..450)
      bottom = round(top.commit(role: :assistant, content: [{ "type" => "text", "text" => "more" }]), "tu_2",
                     lines: 451..)
      session.on_chain(bottom)

      expect(session.read?("/tmp/app.rb")).to be(true)

      session.on_chain(top)

      expect(session.read?("/tmp/app.rb")).to be(false)
      expect(session.partially_read?("/tmp/app.rb")).to be(true)
    end

    it "counts a read in the round that made it, before any turn delivers it" do
      session.on_chain(root.commit(role: :assistant, content: calls("tu_1")))
      session.record_read("/tmp/app.rb", identity: version, tool_use_id: "tu_1")

      expect(session.read?("/tmp/app.rb")).to be(true)
    end

    it "never counts a read whose result reached the model as an error" do
      after = round(root, "tu_1", is_error: true)
      session.on_chain(after)

      expect(session.read?("/tmp/app.rb")).to be(false)
    end

    it "withholds a read its round never delivered once the next round opens" do
      session.on_chain(root.commit(role: :assistant, content: calls("tu_1")))
      session.record_read("/tmp/app.rb", identity: version, tool_use_id: "tu_1")
      session.on_chain(root.commit(role: :assistant, content: calls("tu_2")))

      expect(session.read?("/tmp/app.rb")).to be(false)
    end

    # The one moment a replay cannot see: a round left open when the next one
    # opens. It is journaled as a marker naming the rounds, so a replay
    # withholds them at the same point; an ordinary run leaves nothing open.
    describe "journaling a withheld round" do
      subject(:session) { described_class.new(journal:) }

      let(:journal) { [] }

      def withheld = journal.grep(Lain::Telemetry::SessionReadWithheld)

      it "journals the rounds on_chain withholds, as [head, call id], carrying no path or bytes" do
        asked = root.commit(role: :assistant, content: calls("tu_1"))
        session.on_chain(asked)
        session.record_read("/tmp/app.rb", identity: version, tool_use_id: "tu_1")

        session.on_chain(asked)

        expect(withheld.map(&:to_journal)).to eq([{ "type" => "session_read_withheld",
                                                    "rounds" => [[asked.head_digest, "tu_1"]] }])
        expect(withheld).to all(satisfy { |record| Ractor.shareable?(record) })
      end

      it "journals nothing when every round delivered" do
        session.on_chain(round(root, "tu_1").commit(role: :assistant, content: calls("tu_2")))

        expect(withheld).to be_empty
      end

      it "withholds exactly the rounds a replay names, and no other" do
        asked = root.commit(role: :assistant, content: calls("tu_1", "tu_2"))
        session.on_chain(asked)
        session.record_read("/tmp/a.rb", identity: version, tool_use_id: "tu_1")
        session.record_read("/tmp/b.rb", identity: version, tool_use_id: "tu_2")

        session.withhold_rounds([[asked.head_digest, "tu_1"], [asked.head_digest, "tu_9"]])

        expect([session.read?("/tmp/a.rb"), session.read?("/tmp/b.rb")]).to eq([false, true])
        expect(withheld.map(&:rounds)).to eq([[[asked.head_digest, "tu_1"]]])
      end

      it "pins the marker's guard: a non-empty list of [head-or-nil, call id] pairs" do
        [nil, [], [["h"]], [[nil, nil]], [["h", 1]], "h", [[1, "tu_1"]]].each do |bogus|
          expect { Lain::Telemetry::SessionReadWithheld.new(rounds: bogus) }
            .to raise_error(ArgumentError, /rounds must be a non-empty list/), "accepted #{bogus.inspect}"
        end
      end
    end

    it "withholds every undelivered read when asked to, as a replay does at the end of its record" do
      session.on_chain(root.commit(role: :assistant, content: calls("tu_1")))
      session.record_read("/tmp/app.rb", identity: version, tool_use_id: "tu_1")

      session.withhold_undelivered

      expect(session.read?("/tmp/app.rb")).to be(false)
    end

    # Ollama numbers each response's calls from zero, so one id arrives in
    # round after round. A later delivery must bind only its own round's read.
    it "binds a call id a later round reuses to that round's read alone" do
      first = round(root, "ollama-tool-0", path: "/tmp/a.rb")
      second = round(first.commit(role: :assistant, content: [{ "type" => "text", "text" => "ok" }]),
                     "ollama-tool-0", path: "/tmp/b.rb")
      session.on_chain(second.rewind(3))

      expect(session.read?("/tmp/a.rb")).to be(true)
      expect(session.read?("/tmp/b.rb")).to be(false)
    end

    it "counts a read no call carried on every chain" do
      session.record_read("/tmp/app.rb", identity: version)
      session.on_chain(root)

      expect(session.read?("/tmp/app.rb")).to be(true)
    end

    it "keeps a masked path masked on every chain" do
      after = round(root, "tu_1")
      session.record_masked_read("/tmp/app.rb")
      session.on_chain(after.rewind(3))

      expect(session.masked_read?("/tmp/app.rb")).to be(true)
      expect(session.partially_read?("/tmp/app.rb")).to be(true)
    end

    # The chain is walked once per head, not once per question: a read/edit
    # loop asks on every call, and a long conversation is a long walk.
    it "walks the store once per head, and a grown head only back to the last one walked" do
      counting = Class.new(Lain::Store) do
        attr_reader :fetches

        def fetch(digest)
          @fetches = (@fetches || 0) + 1
          super
        end
      end.new
      line = (1..20).inject(Lain::Timeline.empty(store: counting)) do |chain, index|
        chain.commit(role: index.odd? ? :user : :assistant, content: [{ "type" => "text", "text" => index.to_s }])
      end
      after = round(line, "tu_1")
      grown = after.commit(role: :assistant, content: calls("tu_2"))
      session.on_chain(after)
      session.read?("/tmp/app.rb")

      expect { 5.times { session.read?("/tmp/app.rb") } }.not_to(change { counting.fetches })
      session.on_chain(grown)
      expect { session.read?("/tmp/app.rb") }.to change { counting.fetches }.by(2)
    end
  end

  # A masked read is the one partial read that arrives AFTER a complete
  # one. {Lain::Tools::ReadFile} records inside `#perform`, below the middleware
  # that decides to mask, so by the time masking is known the whole read is
  # already in the set -- and the set has no retraction, deliberately. So
  # masking is a THIRD add-only set rather than a downgrade of the second, and
  # every claim in "read completeness" above has to survive it untouched.
  describe "a masked read, which is a partial read the whole-read record precedes" do
    it "stops a path being editable even though it was recorded as read whole" do
      session.record_read("/tmp/.env")
      session.record_masked_read("/tmp/.env")

      expect(session.read?("/tmp/.env")).to be(false)
      expect(session.partially_read?("/tmp/.env")).to be(true)
    end

    it "names WHICH cause the partial read had, so a refusal can say re-read or ask for a release" do
      session.record_read("/tmp/.env")
      session.record_masked_read("/tmp/.env")
      session.record_read("/tmp/half.rb", lines: 1..10)

      expect(session.masked_read?("/tmp/.env")).to be(true)
      expect(session.masked_read?("/tmp/half.rb")).to be(false)
      expect(session.masked_read?("/tmp/never.rb")).to be(false)
    end

    # The residual, asserted rather than left to be discovered: over-strict, in
    # the direction this boundary is meant to fail in. Clearing it needs a
    # removal, which is the one thing the read-set refuses.
    it "keeps a masked path masked even after a later read releases everything" do
      session.record_masked_read("/tmp/.env")
      session.record_read("/tmp/.env")

      expect(session.read?("/tmp/.env")).to be(false)
    end

    it "records membership too, so a masked path is never mistaken for one never read" do
      session.record_masked_read("/tmp/.env")

      expect(session.reads).to eq(["/tmp/.env"])
      expect(session.partially_read?("/tmp/.env")).to be(true)
    end

    it "carries across spellings, as the rest of the read-set does" do
      Dir.mktmpdir do |dir|
        masked = described_class.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {}))
        masked.record_masked_read("./.env")

        expect(masked.masked_read?(".env")).to be(true)
        expect(masked.read?(File.join(dir, ".env"))).to be(false)
      end
    end

    # Reads must not learn about masking: a caller able to spell a span over a
    # masked path would be able to spell "this read hid nothing" over a read
    # that hid something.
    it "is not reachable through record_read's span" do
      session.record_read("/tmp/app.rb", lines: 1..10)

      expect(session.masked_read?("/tmp/app.rb")).to be(false)
    end

    it "reads back the same through the Null session, which records nothing" do
      expect(Lain::Session::Null.instance.record_masked_read("/tmp/.env")).to be(Lain::Session::Null.instance)
      expect(Lain::Session::Null.instance.masked_read?("/tmp/.env")).to be(false)
    end

    # A mask writes NO `session_read` line, deliberately: a replay folds that
    # record through `record_read`, which cannot reach the masked set -- so a
    # line here would replay to a read. `Telemetry::ReadRedacted`, written by
    # `Middleware::RedactSecretReads` into this same journal, is the record, and
    # `SessionRecord::Replay#redactions` is what folds it back.
    describe "with a journal attached" do
      subject(:journaled) { described_class.new(journal:) }

      let(:journal) { [] }

      it "reaches the masked set" do
        journaled.record_masked_read("/tmp/.env")

        expect(journaled.masked_read?("/tmp/.env")).to be(true)
        expect(journaled.read?("/tmp/.env")).to be(false)
      end

      it "writes no session_read line, which would replay as a read" do
        journaled.record_masked_read("/tmp/.env")

        expect(journal.grep(Lain::Telemetry::SessionRead)).to be_empty
      end
    end
  end

  # These drive the REAL tools rather than restating their preconditions,
  # so the assertion is about the contract `edit_file`/`write_file` actually
  # declare. The file's bytes are asserted too: a refusal that did not in fact
  # protect the contents would otherwise pass on `is_error` alone.
  describe "the edit contract and read completeness", :seam do
    # A refused precondition RAISES {Lain::Tool::ContractViolation}; it does
    # not return an error Result. So the attempt is handed over unevaluated and
    # each example expects its own shape. The file's bytes come back either
    # way: a refusal that did not in fact protect the contents would otherwise
    # pass on the exception alone.
    def edit_after(*spans)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "hello.txt")
        File.write(path, "hello world")
        session = described_class.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {}))
        spans.each { |lines| session.record_read(path, lines:) }
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
        edit = { path: "hello.txt", old_string: "hello", new_string: "goodbye" }

        yield -> { Lain::Tools::EditFile.new.call(edit, invocation) }, -> { File.read(path) }
      end
    end

    it "satisfies edit_file's precondition after a complete read" do
      edit_after(1..) do |attempt, contents|
        result = attempt.call
        expect(result.is_error).to be(false), -> { "edit_file refused: #{result.content}" }
        expect(contents.call).to eq("goodbye world")
      end
    end

    # Only the exception CLASS is pinned here; the wording is edit_file's own
    # spec's business.
    it "fails edit_file's precondition after a partial read, leaving the file untouched" do
      edit_after(2..) do |attempt, contents|
        expect { attempt.call }.to raise_error(Lain::Tool::ContractViolation)
        expect(contents.call).to eq("hello world")
      end
    end

    it "satisfies edit_file's precondition once a partial read is upgraded by a complete one" do
      edit_after(2.., 1..1) do |attempt, contents|
        result = attempt.call
        expect(result.is_error).to be(false), -> { "edit_file refused: #{result.content}" }
        expect(contents.call).to eq("goodbye world")
      end
    end

    it "keeps edit_file's precondition satisfied when a complete read is followed by a partial one" do
      edit_after(1.., 2..) do |attempt, contents|
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
        session.record_read(path, lines: 2..)
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)

        expect do
          Lain::Tools::WriteFile.new.call({ path: "existing.txt", content: "clobbered" }, invocation)
        end.to raise_error(Lain::Tool::ContractViolation)
        expect(File.read(path)).to eq("secret")
      end
    end
  end

  # The base a relative path resolves against is the SESSION's worker cwd,
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

    it "names the worker cwd a call made in this session resolves against" do
      expect(described_class.cwd_of(session)).to eq(cwd)
    end

    it "resolves a call made with no session from the process, as the Null session does" do
      expect(described_class.cwd_of(nil)).to eq(Dir.pwd)
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

  # The edit-before-read contract resolves through the same worker cwd, so
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

  # The edge a compaction source latches on: a LEVEL stays up until the next
  # write, so a reader polling it every render would see one completed step as
  # a completion on every turn until the model writes its list again.
  describe "#plan_step_completions" do
    def todo(content, status) = Struct.new(:content, :status).new(content, status)

    it "is zero before any todo_write lands" do
      expect(session.plan_step_completions).to eq(0)
    end

    it "counts each write that raised the completed count, once per write" do
      session.write_todos([todo("a", "completed"), todo("b", "pending")])
      session.write_todos([todo("a", "completed"), todo("b", "pending")])
      session.write_todos([todo("a", "completed"), todo("b", "completed")])

      expect(session.plan_step_completions).to eq(2)
    end

    it "does not count a write that lowered or held the completed count" do
      session.write_todos([todo("a", "completed")])
      session.write_todos([todo("a", "pending")])

      expect(session.plan_step_completions).to eq(1)
    end

    it "is the count the level agrees with on the write that raised it" do
      session.write_todos([todo("a", "completed")])

      expect([session.plan_step_completed?, session.plan_step_completions]).to eq([true, 1])
    end
  end

  # Policy state, not a derived head: the Timeline stays the lossless record,
  # and the cut rides here beside the pin-set for the pin-set's reason -- it is
  # journaled and replayed, so a resume renders the replacement a recorded
  # session rendered instead of re-asking for it.
  describe "the compaction cuts it records" do
    def cut(digest, parent: nil)
      Lain::Telemetry::CompactionCut.new(
        digest:, head: "#{digest}-head", strategy: "eager", kind: "advance", parent:, supersedes: [],
        plan_step_completions: 0,
        collapses: [{ "span" => ["blake3:root", digest], "content" => [{ "type" => "text", "text" => "s" }] }]
      )
    end

    it "holds none before a compaction commits" do
      expect(session.compaction_cuts).to eq([])
    end

    it "holds every cut in the order it was committed, frozen" do
      one = cut("blake3:one")
      session.record_compaction_cut(one).record_compaction_cut(cut("blake3:two", parent: one.address))

      expect(session.compaction_cuts.map(&:digest)).to eq(%w[blake3:one blake3:two])
      expect(session.compaction_cuts).to be_frozen
    end

    it "answers a recorded cut by its address, which is what a child's parent link names" do
      one = cut("blake3:one")
      session.record_compaction_cut(one)

      expect(session.compaction_cut(one.address)).to equal(one)
    end

    # A delta record is unreadable without its parent, so a truncated record
    # must fail where it is folded rather than render a seam with a hole in it.
    it "refuses a cut whose parent it does not hold" do
      expect { session.record_compaction_cut(cut("blake3:two", parent: cut("blake3:one").address)) }
        .to raise_error(Lain::Session::UnrecordedParent, /parent .* is not a cut this session recorded/)
      expect(session.compaction_cuts).to eq([])
    end

    it "journals each cut as it is recorded" do
      journal = []
      journaled = described_class.new(journal:)

      journaled.record_compaction_cut(cut("blake3:one"))

      expect(journal).to eq([cut("blake3:one")])
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

    # Composition is deterministic -- two reads with no writes between
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

  # A session's worker env is a slot a mode flip rebinds: plan scope moves
  # where the session's tools resolve and run, and leaving it moves them back.
  describe "#rescope" do
    around do |example|
      Dir.mktmpdir("lain-session-scope") do |dir|
        @base = File.realpath(dir)
        @home = Lain::WorkerEnv.new(cwd: File.join(@base, "project").tap { FileUtils.mkdir_p(_1) }, env: {})
        @spike = File.join(@base, "spike").tap { FileUtils.mkdir_p(_1) }
        example.run
      end
    end

    let(:scoped) { described_class.new(worker_env: @home) }

    def confined(reminder: "plan scope: writes land in the spike")
      Lain::Session::Confined.new(worker_env: Lain::WorkerEnv.new(cwd: @spike, env: {}, checkout: @spike), reminder:)
    end

    it "starts unconfined, its tools resolving where it was built" do
      expect(scoped.scope).to be(Lain::Session::Unconfined)
      expect(scoped.worker_env).to be(@home)
    end

    it "resolves and runs against the scope's environment once confined" do
      scope = confined
      scoped.rescope(scope)

      expect(scoped.worker_env).to be(scope.worker_env)
      expect(scoped.scope).to be(scope)
    end

    it "returns to the environment it was built with when the scope is lifted" do
      scoped.rescope(confined).rescope(Lain::Session::Unconfined)

      expect(scoped.worker_env).to be(@home)
    end

    # The model has to be told where it is, since nothing it writes in a spike
    # reaches the checkout.
    it "tells the model its scope among the reminders, after the rest" do
      scoped.write_todos([Struct.new(:content, :status).new("a", "pending")])
      scoped.rescope(confined(reminder: "in a spike"))

      expect(scoped.reminders).to eq(["Current todo list:\n- [pending] a", "in a spike"])
    end

    it "keeps no reminder of a scope that was lifted" do
      scoped.rescope(confined).rescope(Lain::Session::Unconfined)

      expect(scoped.reminders).to eq([])
    end

    it "takes a scope at construction, for a child that inherits its parent's" do
      scope = confined

      expect(described_class.new(worker_env: scope.worker_env, scope:).scope).to be(scope)
    end
  end

  describe Lain::Session::Confined do
    subject(:scope) do
      described_class.new(worker_env: Lain::WorkerEnv.new(cwd: @spike, env: {}, checkout: @spike), reminder: "r")
    end

    around do |example|
      Dir.mktmpdir("lain-session-confined") do |dir|
        @base = File.realpath(dir)
        @spike = File.join(@base, "spike").tap { FileUtils.mkdir_p(_1) }
        example.run
      end
    end

    it "holds a path under its root, existing or not" do
      expect(scope.holds?(File.join(@spike, "notes.md"))).to be(true)
      expect(scope.holds?(File.join(@spike, "new", "dir", "x"))).to be(true)
      expect(scope.holds?(@spike)).to be(true)
    end

    it "does not hold a path outside its root, nor a sibling sharing its prefix" do
      expect(scope.holds?(File.join(@base, "project", "a.rb"))).to be(false)
      expect(scope.holds?("#{@spike}-other/a.rb")).to be(false)
    end

    # The kernel follows a link the spike carries, so a path is judged where
    # it really lands.
    it "does not hold a path whose real location is outside, through a link inside" do
      File.symlink(@base, File.join(@spike, "out"))

      expect(scope.holds?(File.join(@spike, "out", "project", "a.rb"))).to be(false)
    end

    it "does not hold a dangling link, whose target could be made anywhere later" do
      File.symlink(File.join(@base, "nowhere"), File.join(@spike, "dangling"))

      expect(scope.holds?(File.join(@spike, "dangling"))).to be(false)
    end

    it "names its root by its real path" do
      linked = File.join(@base, "linked")
      File.symlink(@spike, linked)
      through = described_class.new(worker_env: Lain::WorkerEnv.new(cwd: linked, env: {}, checkout: linked),
                                    reminder: "r")

      expect(through.root).to eq(@spike)
    end

    # A child spawned under plan is lent the spike in place: a lease of its
    # own would be a second checkout the spike never reads.
    it "leaves a lease its caller already lent in place as it was" do
      lent = Lain::Isolation::Leases::InPlace.new(worker_env: Lain::WorkerEnv.new(cwd: @base, env: {}))

      expect(scope.lend(lent)).to be(lent)
    end

    it "lends its environment in place, in the lender's lane" do
      lane = Lain::Isolation::Leases::Lane.named("issue.x.1")
      lent = scope.lend(Lain::Isolation::Leases.new(lane:))

      expect(lent).to be_a(Lain::Isolation::Leases::InPlace)
      expect([lent.worker_env, lent.lane]).to eq([scope.worker_env, lane])
    end
  end

  describe Lain::Session::Unconfined do
    it "holds every path, reminds nothing, and lends the leases it is handed" do
      leases = Lain::Isolation::Leases.new

      expect(described_class.holds?("/anywhere")).to be(true)
      expect(described_class.reminders).to eq([])
      expect(described_class.lend(leases)).to be(leases)
    end
  end

  describe Lain::Session::Null do
    subject(:null) { described_class.instance }

    it "satisfies the Session duck without raising: record_read is a no-op, read? is false" do
      expect { null.record_read("/tmp/app.rb") }.not_to raise_error
      expect(null.read?("/tmp/app.rb")).to be(false)
      expect(null.reads).to eq([])
    end

    # The completeness duck too, so a tool holding a Null never has to
    # guard before asking. Records nothing, so it reports NEITHER read nor
    # partially read -- the "no read at all" answer, for every path.
    it "keeps the completeness duck a no-op: a partial read records nothing either" do
      expect { null.record_read("/tmp/app.rb", lines: 1..10, tool_use_id: "tu_1") }.not_to raise_error
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

    it "is confined to no scope" do
      expect(null.scope).to be(Lain::Session::Unconfined)
    end

    it "records no compaction cut and counts no completed plan step" do
      cut = Lain::Telemetry::CompactionCut.new(digest: "blake3:one", head: "blake3:one", strategy: "eager",
                                               kind: "advance", parent: nil, supersedes: [], plan_step_completions: 0,
                                               collapses: [{ "span" => %w[blake3:one blake3:one], "content" => [] }])

      expect(null.record_compaction_cut(cut)).to be(null)
      expect(null.compaction_cuts).to eq([])
      expect(null.plan_step_completions).to eq(0)
    end

    it "is a shared, frozen instance" do
      expect(null).to be_deeply_frozen
      expect(described_class.instance).to be(null)
    end

    # One frozen instance cannot capture a directory that moves under it,
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

  # Journaling is Session's own, with `journal:` defaulting to the Null
  # channel -- which is why every example above this block constructs a plain
  # Session, never mentions a journal, and records nothing.
  describe "journaling the run-state into the session record" do
    def todo(content, status) = Struct.new(:content, :status).new(content, status)

    subject(:journaled) { described_class.new(journal:, **env) }

    let(:env) { {} }
    let(:journal) { [] }

    def of_type(type) = journal.select { |record| record.journal_type == type }

    # A read is recorded once and journaled once, however many times the model
    # asks for the same file -- the read/edit loop's whole point.
    it "records a re-read once and journals it once" do
      journaled.record_read("/tmp/app.rb")
      journaled.record_read("/tmp/app.rb")

      expect(journaled.read?("/tmp/app.rb")).to be(true)
      expect(of_type("session_read").size).to eq(1)
    end

    # The Null journal is the default, so a Session built with no journal at
    # all still tracks everything it tracked before journaling was its job.
    it "tracks reads with no journal at all, writing nowhere" do
      plain = described_class.new

      plain.record_read("/tmp/app.rb")

      expect(plain.read?("/tmp/app.rb")).to be(true)
      expect(plain.reads).to eq(["/tmp/app.rb"])
    end

    it "keeps the write-set journal-free (persistence is the snapshot's, not the record's)" do
      journaled.record_write("/tmp/app.rb")

      expect(journaled.written?("/tmp/app.rb")).to be(true)
      expect(journaled.writes).to eq(["/tmp/app.rb"])
      expect(journal).to be_empty
    end

    it "journals a session_pin when a digest is pinned" do
      journaled.record_pin("blake3:aaaa1111")

      expect(journaled.pinned?("blake3:aaaa1111")).to be(true)
      expect(of_type("session_pin").map(&:digest)).to eq(["blake3:aaaa1111"])
    end

    # A journal-less Session takes one -- the resumed path, where replay folds
    # the old record in before the new journal exists.
    it "takes a journal after construction, and then records into it" do
      plain = described_class.new

      expect(plain.journals_into(journal)).to be(plain)
      plain.record_read("/tmp/app.rb")

      expect(of_type("session_read").map(&:path)).to eq(["/tmp/app.rb"])
    end

    # Refused rather than documented: a swap mid-run splits one run's record
    # across two destinations and neither half says so.
    it "refuses a second journal over one it already holds" do
      expect { journaled.journals_into([]) }
        .to raise_error(ArgumentError, /journals into one destination for the whole run/)
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
    context "when the session's worker cwd is /tmp" do
      let(:env) { { worker_env: Lain::WorkerEnv.new(cwd: "/tmp", env: {}) } }

      it "journals nothing on a re-read of the same path (any spelling) -- no chatty per-iteration lines" do
        journaled.record_read("/tmp/app.rb")
        journaled.record_read("app.rb")
        journaled.record_read("./app.rb")

        expect(of_type("session_read").size).to eq(1)
      end
    end

    # The journal line must name the string the READ-SET holds, resolved
    # against the WORKER's cwd and never the process's -- otherwise the Journal
    # (the experiment record) names a different file than #read? answers for.
    context "when the session's worker cwd is not the process directory" do
      let(:cwd) { File.join(Dir.tmpdir, "lain-session-journal") }
      let(:env) { { worker_env: Lain::WorkerEnv.new(cwd:, env: {}) } }

      # Asserted as BYTE-identity, not as `read?(recorded)`: `read?`
      # re-normalizes its argument, so it would answer true for any spelling
      # that merely resolves to the same file, and a line journaling a
      # DIFFERENT string than the read-set holds would still pass. The read-set
      # has its own `#reads` window, so this compares against the very set
      # under discussion rather than borrowing the write-set's mirror.
      it "journals the very string the read-set holds, not merely a spelling of it" do
        journaled.record_read("notes.md")

        recorded = of_type("session_read").map(&:path)
        expect(recorded).to eq([File.join(cwd, "notes.md")])
        expect(recorded).to eq(journaled.reads)
      end
    end

    it "journals a fresh SessionRead for a genuinely different path" do
      journaled.record_read("/tmp/app.rb")
      journaled.record_read("/tmp/other.rb")

      expect(of_type("session_read").map(&:path)).to contain_exactly("/tmp/app.rb", "/tmp/other.rb")
    end

    # The record the Session emits carries a construction contract of its own
    # (the validate-then-freeze convention): a pathless read record could never
    # replay, so it must fail loudly at construction, not at load.
    def read_record(**overrides)
      Lain::Telemetry::SessionRead.new(path: "/tmp/a.rb", lines: [1, nil], tool_use_id: nil, head: nil,
                                       identity: Lain::Session::FileIdentity::ABSENT.to_h.transform_keys(&:to_s),
                                       **overrides)
    end

    it "pins SessionRead's guard: a nil path raises at construction" do
      expect { read_record(path: nil) }.to raise_error(ArgumentError, /path must name the file read, got nil/)
    end

    # `[]` and `{}` are in this list deliberately: an inclusion-style validator
    # reads an ARRAY as "every member must be allowed", which `[]` vacuously
    # is. A span read loosely replays as more of the file than the model saw.
    it "pins SessionRead's span guard: anything but [first, last-or-nil] from line 1 raises" do
      [[0, nil], [5, 4], [1], [], {}, nil, "1..", [1.0, nil], [1, "9"], [nil, nil]].each do |bogus|
        expect { read_record(lines: bogus) }
          .to raise_error(ArgumentError, /lines must be \[first, last\]/), "accepted #{bogus.inspect}"
      end
    end

    it "pins SessionRead's call guard: a call id and its round's head are each a String or nil" do
      expect { read_record(tool_use_id: 7) }.to raise_error(ArgumentError, /tool_use_id must be a String or nil/)
      expect { read_record(head: 7) }.to raise_error(ArgumentError, /head must be a String or nil/)
    end

    # A replay rebuilds the file version from these members, so a version it
    # could not rebuild is refused where it is written, not on a resume.
    it "pins SessionRead's version guard: exactly the FileIdentity members, each an Integer or nil" do
      whole = Lain::Session::FileIdentity::ABSENT.to_h.transform_keys(&:to_s)
      [{}, nil, whole.except("inode"), whole.merge("extra" => 1), whole.merge("size" => "3"),
       whole.transform_keys(&:to_sym)].each do |bogus|
        expect { read_record(identity: bogus) }
          .to raise_error(ArgumentError, /identity must carry exactly device, inode, mtime, size/),
              "accepted #{bogus.inspect}"
      end
    end

    it "journals the span, the file version and the call that carried the read" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "a.rb")
        File.write(path, "one\n")

        journaled.record_read(path, lines: 3..9, tool_use_id: "tu_1")

        expect(of_type("session_read").first.to_journal)
          .to include("path" => path, "lines" => [3, 9], "tool_use_id" => "tu_1", "head" => nil,
                      "identity" => Lain::Session::FileIdentity.of(path).to_h.transform_keys(&:to_s))
      end
    end

    # A line is journaled when a read adds lines to what was seen of that
    # version, not on every call. The dedupe that keeps a read/edit loop from
    # emitting one line per iteration has to survive windows, and each
    # surviving line has to say WHICH thing the model saw.
    describe "journaling what a read added" do
      it "journals one line, spanning the whole file, for a whole read" do
        journaled.record_read("/tmp/app.rb")

        expect(of_type("session_read").map { |r| [r.path, r.lines] }).to eq([["/tmp/app.rb", [1, nil]]])
      end

      it "journals one line, spanning the window, for a partial read" do
        journaled.record_read("/tmp/app.rb", lines: 1..10)

        expect(of_type("session_read").map { |r| [r.path, r.lines] }).to eq([["/tmp/app.rb", [1, 10]]])
      end

      it "journals nothing on a re-read of lines already seen" do
        3.times { journaled.record_read("/tmp/app.rb", lines: 1..10) }
        journaled.record_read("/tmp/app.rb", lines: 4..6)

        expect(of_type("session_read").size).to eq(1)
      end

      # A masked path's re-reads used to escape the dedupe, because completeness
      # was the transition and a mask suppressed it forever. Coverage ignores the
      # mask, so the redacted file a loop re-reads journals once like any other.
      it "journals a masked path's re-reads once, like any other path" do
        journaled.record_masked_read("/tmp/.env")
        4.times { journaled.record_read("/tmp/.env") }

        expect(of_type("session_read").size).to eq(1)
      end

      it "journals each window that adds lines, and the one that completes the file" do
        journaled.record_read("/tmp/app.rb", lines: 1..10)
        journaled.record_read("/tmp/app.rb", lines: 11..)

        expect(of_type("session_read").map(&:lines)).to eq([[1, 10], [11, nil]])
      end

      # The mirror of the monotonicity AC, in the record stream: a complete
      # read is never followed by a line that could replay as a downgrade.
      it "journals nothing when a complete read is followed by a partial one" do
        journaled.record_read("/tmp/app.rb")
        journaled.record_read("/tmp/app.rb", lines: 1..10)

        expect(of_type("session_read").map(&:lines)).to eq([[1, nil]])
      end

      it "journals a read of lines already seen once they are off the chain" do
        root = Lain::Timeline.empty.commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
        asked = root.commit(role: :assistant, content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "read_file",
                                                          "input" => {} }])
        journaled.on_chain(asked)
        journaled.record_read("/tmp/app.rb", tool_use_id: "tu_1")
        delivered = asked.commit(role: :user, content: [{ "type" => "tool_result", "tool_use_id" => "tu_1",
                                                          "content" => "x", "is_error" => false }])
        journaled.record_delivery(digest: delivered.head_digest, parent: asked.head_digest,
                                  content: delivered.head.content)
        journaled.on_chain(root)

        journaled.record_read("/tmp/app.rb", tool_use_id: "tu_2")

        expect(of_type("session_read").map { |record| [record.tool_use_id, record.head] })
          .to eq([["tu_1", asked.head_digest], ["tu_2", root.head_digest]])
      end
    end

    # The read-set's strict guard runs AHEAD of both the mutation and the
    # journal write, so a rescued caller cannot be left holding live state more
    # permissive than what replays.
    it "leaves neither the read-set nor the Journal touched when a span names no lines" do
      expect { journaled.record_read("/tmp/app.rb", lines: 0..) }.to raise_error(ArgumentError)

      expect(journaled.read?("/tmp/app.rb")).to be(false)
      expect(journaled.partially_read?("/tmp/app.rb")).to be(false)
      expect(of_type("session_read")).to be_empty
    end

    it "answers partially_read? and reads for a partial read" do
      journaled.record_read("/tmp/partial.rb", lines: 1..10)

      expect(journaled.partially_read?("/tmp/partial.rb")).to be(true)
      expect(journaled.read?("/tmp/partial.rb")).to be(false)
      expect(journaled.reads).to eq(["/tmp/partial.rb"])
    end

    it "journals every write_todos call as a whole-list TodoSnapshot, and holds the last list" do
      journaled.write_todos([todo("a", "pending")])
      journaled.write_todos([todo("b", "completed")])

      snapshots = of_type("todo_snapshot")
      expect(snapshots.size).to eq(2)
      expect(snapshots.first.todos).to eq([{ "content" => "a", "status" => "pending" }])
      expect(snapshots.last.todos).to eq([{ "content" => "b", "status" => "completed" }])
      expect(journaled.reminders).to eq(["Current todo list:\n- [completed] b"])
    end
  end
end
