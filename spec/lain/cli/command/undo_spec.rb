# frozen_string_literal: true

require "tmpdir"
require "mixlib/shellout"

RSpec.describe Lain::CLI::Command::Undo do
  around do |example|
    Dir.mktmpdir("lain-undo-root") do |root|
      Dir.mktmpdir("lain-undo-state") do |state|
        @root = File.realpath(root)
        @state = state
        example.run
      end
    end
  end

  attr_reader :root

  let(:store) { Lain::Store.new }
  let(:journal) { [] }
  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }) }
  let(:scope) { :shadow_git }
  let(:slot) { Lain::Agent::SnapshotSlot.new(root:, scope:, paths:) }

  before do
    @timeline = Lain::Timeline.empty(store:)
    @write_set = []
  end

  def in_root(name) = File.join(root, name)

  def write(name, bytes)
    FileUtils.mkdir_p(File.dirname(in_root(name)))
    File.binwrite(in_root(name), bytes)
  end

  def read(name) = File.binread(in_root(name)).force_encoding(Encoding::UTF_8)

  def exist?(name) = File.exist?(in_root(name))

  # One tool turn as the delivery runs it: prime, the writes (a tool's join the
  # write-set, a shell's do not), anything else the turn did, the tool-result
  # commit, the snapshot.
  def turn(tools: {}, shell: {})
    slot.prime
    tools.merge(shell).each { |name, bytes| write(name, bytes) }
    yield if block_given?
    @write_set |= tools.keys.map { |name| in_root(name) }
    @timeline = @timeline.commit(role: :user, content: [{ "type" => "text", "text" => "tool results" }])
    slot.write(timeline: @timeline, paths: @write_set)
    @timeline.head_digest
  end

  def env(dispatching: false, snapshots: slot, timeline: @timeline, **overrides)
    agent = instance_double(Lain::Agent, timeline:, dispatching?: dispatching)
    build_command_env(agent:, snapshots:, chronicle:, **overrides)
  end

  def undo(**) = described_class.new.call("", env(**))

  def skip_turn(**) = described_class.new.call("skip", env(**))

  def undone_records = journal.grep(described_class::WorkspaceUndone)

  # The user's own git, in the user's own repository -- never the shadow one --
  # scrubbed so a run under a git hook builds in the tmpdir it names.
  def user_git(*argv)
    Mixlib::ShellOut.new("git", "-c", "user.email=spec@lain.test", "-c", "user.name=lain spec", *argv,
                         cwd: root,
                         environment: Lain::Workspace::Snapshot::Scope::ShadowGit::GIT_CONTEXT_SCRUB)
                    .tap(&:run_command).stdout
  end

  it "is typed as /undo and says it leaves the conversation to /rewind" do
    expect(described_class.new.name).to eq("undo")
    expect(described_class.new.usage).to include("/rewind")
  end

  describe "under the default posture's shadow scope", :seam do
    def text(body) = Lain::Response.new(content: [{ "type" => "text", "text" => body }], stop_reason: :end_turn)

    # A real Agent, a real slot and real tools. Turn B writes nothing; turn C
    # reads a.rb, which the human wrote before the session, and overwrites it.
    def two_turn_agent
      a_rb = in_root("a.rb")
      responses = [text("nothing to change"), tool_response(["tu_1", "read_file", { "path" => a_rb }]),
                   tool_response(["tu_2", "write_file", { "path" => a_rb, "content" => "edited by C\n" }]),
                   text("done")]
      Lain::Agent.new(provider: Lain::Provider::Mock.new(responses:), snapshot_slot: slot,
                      toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::WriteFile.new]),
                      context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024))
    end

    it "restores what the last writing turn changed and leaves the conversation alone" do
      write("a.rb", "human v0\n")
      agent = two_turn_agent
      agent.ask("turn B")
      agent.ask("turn C")
      turn_c = slot.log.to_a.last.turn
      head = agent.timeline.head_digest

      described_class.new.call("", build_command_env(agent:, snapshots: slot, chronicle:))

      expect(read("a.rb")).to eq("human v0\n")
      expect(undone_records.map(&:turn)).to eq([turn_c])
      expect(agent.timeline.head_digest).to eq(head)
    end

    it "walks further back on a repeated undo, to before the session's first write" do
      turn(tools: { "a.rb" => "a v1\n" })
      turn(tools: { "a.rb" => "a v2\n" })

      undo
      expect(read("a.rb")).to eq("a v1\n")

      undo
      expect(exist?("a.rb")).to be(false)
    end

    it "gives a file bash edited its earlier bytes back, and leaves one the human made afterwards" do
      turn(shell: { "c.txt" => "c v1\n" })
      turn(tools: { "a.rb" => "a v1\n" })
      turn(shell: { "c.txt" => "c v2\n" })
      write("notes.md", "mine\n")

      undo

      expect(read("c.txt")).to eq("c v1\n")
      expect(read("a.rb")).to eq("a v1\n")
      expect(read("notes.md")).to eq("mine\n")
    end

    it "journals the undo, naming the turn it reverted and what moved" do
      turn_c = turn(tools: { "a.rb" => "a v1\n" })
      snapshot = slot.log.to_a.last.snapshot

      undo

      expect(undone_records.map(&:to_h)).to eq([{ turn: turn_c, snapshot:, written: [], deleted: ["a.rb"] }])
    end

    it "refuses over a file changed since the turn, and the turn stays undoable" do
      turn(tools: { "a.rb" => "a v1\n" })
      write("a.rb", "edited by hand\n")

      expect { undo }.to raise_error(described_class::Refusal, /a\.rb/)
      expect(read("a.rb")).to eq("edited by hand\n")

      write("a.rb", "a v1\n")
      undo
      expect(exist?("a.rb")).to be(false)
    end

    describe "what the turn's own trees know" do
      it "puts back what bash created and deleted, leaving the user's git status as it was" do
        write("keep.txt", "keep\n")
        write("old.txt", "old\n")
        user_git("init", "-q")
        user_git("add", "-A")
        user_git("commit", "-qm", "init")
        status = user_git("status", "--porcelain")
        turn(shell: { "new.txt" => "new\n" }) { File.delete(in_root("old.txt")) }

        undo

        expect(user_git("status", "--porcelain")).to eq(status)
      end

      it "undoes a turn that only deleted a file, first turn or later" do
        write("z.txt", "precious\n")
        turn(tools: { "a.rb" => "a1\n" })
        turn { File.delete(in_root("z.txt")) }

        undo
        expect(read("z.txt")).to eq("precious\n")
        expect(read("a.rb")).to eq("a1\n")

        undo
        expect(exist?("a.rb")).to be(false)
      end

      it "leaves a human's edit between turns alone, whether the next turn wrote or not" do
        write("h.txt", "original\n")
        turn(shell: { "made.txt" => "made\n" })
        write("h.txt", "HUMAN EDIT, keep me\n")
        write("notes.md", "the human's notes\n")
        turn(shell: { "y.txt" => "y\n" })
        turn { :read_only }

        undo
        undo

        expect([exist?("y.txt"), exist?("made.txt")]).to eq([false, false])
        expect([read("h.txt"), read("notes.md")]).to eq(["HUMAN EDIT, keep me\n", "the human's notes\n"])
      end

      # The next turn stages its own before-tree, so an undone change a later
      # turn makes again is that turn's, and undoing it goes back one turn.
      it "measures the turn after an undo from where the undo left disk" do
        write("a.txt", "0\n")
        turn(shell: { "a.txt" => "1\n" })
        turn(shell: { "a.txt" => "2\n" })
        undo
        turn(shell: { "a.txt" => "2\n" })

        undo

        expect(read("a.txt")).to eq("1\n")
      end

      it "puts a directory back where the turn left a file, and a file where it left a directory" do
        write("d/f.txt", "inner\n")
        write("e", "i was a file\n")
        turn do
          FileUtils.rm_r(in_root("d"))
          write("d", "flat\n")
          File.delete(in_root("e"))
          write("e/g", "g\n")
        end

        undo

        expect([read("d/f.txt"), read("e")]).to eq(["inner\n", "i was a file\n"])
      end

      it "puts the executable bit back, alone and with the bytes" do
        write("run.sh", "echo hi\n")
        File.chmod(0o644, in_root("run.sh"))
        write("tool.sh", "v0\n")
        File.chmod(0o755, in_root("tool.sh"))
        turn do
          File.chmod(0o755, in_root("run.sh"))
          File.delete(in_root("tool.sh"))
          write("tool.sh", "v1\n")
        end

        undo

        expect(File.stat(in_root("run.sh")).mode & 0o111).to eq(0)
        expect([read("tool.sh"), File.executable?(in_root("tool.sh"))]).to eq(["v0\n", true])
      end

      # The name that was deleted under the old design, because its lookup
      # never matched: git's bytes, never made UTF-8, against a UTF-8 key.
      it "puts a non-ASCII file's earlier bytes back rather than deleting it" do
        write("café.txt", "the human's file\n")
        turn(tools: { "café.txt" => "tool\n" })

        undo

        expect(read("café.txt")).to eq("the human's file\n")
      end

      it "undoes a shadow turn taken after a flip from the write-set scope" do
        write("a.rb", "a0\n")
        ws_slot = Lain::Agent::SnapshotSlot.new(root:, scope: :write_set, paths:)
        settle = lambda do |text|
          @timeline = @timeline.commit(role: :user, content: [{ "type" => "text", "text" => text }])
          ws_slot.write(timeline: @timeline, paths: [in_root("a.rb")])
        end
        ws_slot.prime
        write("a.rb", "a1\n")
        settle.call("1")
        ws_slot.rebind(:shadow_git)
        ws_slot.prime
        write("b.txt", "b\n")
        settle.call("2")

        undo(snapshots: ws_slot)

        expect(exist?("b.txt")).to be(false)
        expect(read("a.rb")).to eq("a1\n")
      end

      it "puts back the state before the turn after flipping away and back" do
        write("c.txt", "c0\n")
        turn(shell: { "c.txt" => "1\n" })
        slot.rebind(:write_set)
        turn(shell: { "c.txt" => "2\n" })
        slot.rebind(:shadow_git)
        turn(shell: { "c.txt" => "3\n" })

        undo

        expect(read("c.txt")).to eq("2\n")
      end

      # Two chats on one project share the shadow store, never a turn pair: a
      # chat whose turn began after the other's settled cannot revert it.
      it "never reverts another chat's file written before its own turn began" do
        other = Lain::Agent::SnapshotSlot.new(root:, scope: :shadow_git, paths:)
        other.prime
        write("from-A.txt", "A's work\n")
        other_timeline = Lain::Timeline.empty(store: Lain::Store.new)
                                       .commit(role: :user, content: [{ "type" => "text", "text" => "a" }])
        other.write(timeline: other_timeline, paths: [in_root("from-A.txt")])
        turn(tools: { "from-B.txt" => "B's work\n" })

        undo

        expect([exist?("from-B.txt"), read("from-A.txt")]).to eq([false, "A's work\n"])
      end

      # The limit the shadow scope's note declares: another chat's write
      # inside this turn's tool window is, as far as the turn's trees can tell,
      # this turn's change -- so the undo removes it, and names it doing so.
      it "names another chat's file written during its turn among what it deleted" do
        other = Lain::Agent::SnapshotSlot.new(root:, scope: :shadow_git, paths:)
        slot.prime
        other.prime
        write("from-A.txt", "A's work\n")
        other.write(timeline: Lain::Timeline.empty(store: Lain::Store.new)
                                            .commit(role: :user, content: [{ "type" => "text", "text" => "a" }]),
                    paths: [in_root("from-A.txt")])
        write("from-B.txt", "B's work\n")
        @timeline = @timeline.commit(role: :user, content: [{ "type" => "text", "text" => "b" }])
        slot.write(timeline: @timeline, paths: [])

        expect(undo).to eq("undid the only undoable file-changing turn: deleted from-A.txt, from-B.txt")
      end
    end

    # A refused undo must not wedge every later one: it names each blocking
    # path and why, and `/undo skip` drops that turn so the next undo reaches
    # the one before.
    describe "a refusal, and the way past it" do
      it "names each blocking path with its reason and what to do, and /undo skip gets past it" do
        turn(shell: { "one.txt" => "one\n" })
        turn(shell: { "a.txt" => "a\n" })
        write("a.txt", "human\n")

        expect { undo }.to raise_error(described_class::Refusal) do |refusal|
          expect(refusal.message).to include("a.txt was changed since that turn", "by hand", "/undo skip")
        end
        expect(skip_turn).to include("skipped the latest of 2 undoable file-changing turns without restoring anything")
        undo

        expect([read("a.txt"), exist?("one.txt")]).to eq(["human\n", false])
      end

      it "journals a skip, naming the turn it dropped" do
        turn_a = turn(shell: { "a.txt" => "a\n" })

        skip_turn

        expect(journal.grep(described_class::WorkspaceUndoSkipped).map(&:turn)).to eq([turn_a])
        expect(read("a.txt")).to eq("a\n")
      end

      it "refuses a symlink the turn planted, and never touches what it points at" do
        outside = File.join(@state, "outside.txt").tap { |path| File.write(path, "outside\n") }
        turn { File.symlink(outside, in_root("link")) }

        expect { undo }.to raise_error(described_class::Refusal, /link is a symlink/)
        expect([File.symlink?(in_root("link")), File.read(outside)]).to eq([true, "outside\n"])
      end

      it "refuses a tool write outside the project root, by name" do
        project = in_root("project").tap { |dir| FileUtils.mkdir_p(dir) }
        inner = Lain::Agent::SnapshotSlot.new(root: project, scope: :shadow_git, paths:)
        inner.prime
        write("escape.txt", "x\n")
        @timeline = @timeline.commit(role: :user, content: [{ "type" => "text", "text" => "escape" }])
        inner.write(timeline: @timeline, paths: [in_root("escape.txt")])

        expect { undo(snapshots: inner) }
          .to raise_error(described_class::Refusal, %r{\.\./escape\.txt is outside the project root})
      end

      it "refuses a tool edit to a .gitignore'd file, by name" do
        write(".gitignore", "*.log\n")
        write("app.log", "log v0\n")
        turn(tools: { "app.log" => "log by tool\n" })

        expect { undo }.to raise_error(described_class::Refusal, /app\.log is \.gitignore'd/)
        expect(read("app.log")).to eq("log by tool\n")
      end
    end

    # A count that included turns already undone read as "2 of 3" with only
    # two left to undo. The reply counts what is still undoable.
    it "names the turn among the turns still undoable, never by a digest" do
      turn(shell: { "a.txt" => "a\n" })
      turn(shell: { "b.txt" => "b\n" })
      turn(shell: { "c.txt" => "c\n" })

      first = undo
      turn(shell: { "d.txt" => "d\n" })
      second = undo
      undo
      last = undo

      expect(first).to eq("undid the latest of 3 undoable file-changing turns: deleted c.txt")
      expect(second).to eq("undid the latest of 3 undoable file-changing turns: deleted d.txt")
      expect(last).to eq("undid the only undoable file-changing turn: deleted a.txt")
      expect([first, second, last].join).not_to include("blake3")
    end
  end

  it "says there is nothing to skip either" do
    expect(skip_turn).to eq(described_class::NOTHING)
  end

  it "refuses an argument it does not know, naming the ones it does" do
    expect { described_class.new.call("again", env) }.to raise_error(described_class::Refusal, %r{/undo skip})
  end

  it "says there is nothing to undo, and journals nothing" do
    expect(undo).to eq(described_class::NOTHING)
    expect(journal).to be_empty
  end

  context "with the write-set scope" do
    let(:scope) { :write_set }

    it "says only lain-written files were restored, and leaves what a shell made" do
      turn(tools: { "a.rb" => "a v1\n" })
      turn(tools: { "a.rb" => "a v2\n" }, shell: { "c.txt" => "made by bash\n" })

      reply = undo

      expect(reply).to include(described_class::WRITE_SET_ONLY)
      expect(read("a.rb")).to eq("a v1\n")
      expect(read("c.txt")).to eq("made by bash\n")
    end

    # A first-time write's earlier state was never recorded: it may have been a
    # human's file, so guessing "absent" could delete their work.
    it "refuses by name when nothing recorded a path's state before the turn, moving nothing" do
      turn(tools: { "a.rb" => "a v1\n" })

      expect { undo }.to raise_error(described_class::Refusal, /a\.rb/)
      expect(read("a.rb")).to eq("a v1\n")
      expect(slot.log.count).to eq(1)
      expect(journal).to be_empty
    end

    it "measures the turn after an undo from the state the undo put back" do
      turn(tools: { "a.rb" => "0\n" })
      turn(tools: { "a.rb" => "1\n" })
      turn(tools: { "a.rb" => "2\n" })
      undo
      turn(tools: { "a.rb" => "2\n" })

      undo

      expect(read("a.rb")).to eq("1\n")
    end
  end

  describe "while something may still be writing" do
    let(:scope) { :write_set }

    before do
      turn(tools: { "a.rb" => "a v1\n" })
      turn(tools: { "a.rb" => "a v2\n" })
    end

    it "refuses while a turn is in flight, since a parked tool call may yet write" do
      expect { undo(dispatching: true) }.to raise_error(described_class::Refusal, /in flight/)
      expect(read("a.rb")).to eq("a v2\n")
    end

    it "refuses while a supervised worker is live, naming it" do
      worker = instance_double(Lain::Supervisor::Registration, state: :running, role: "coder", worker_id: "coder-1")
      supervisor = instance_double(Lain::Supervisor, each: [worker].each)

      expect { undo(supervisor:) }.to raise_error(described_class::Refusal, /coder-1/)
      expect(read("a.rb")).to eq("a v2\n")
    end
  end
end
