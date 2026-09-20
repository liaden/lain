# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# The project's one durable memory store, and the view a session opens on it.
# Driven against a real directory throughout: the file IS the subject, and a
# doubled filesystem would pin nothing about append-only-ness or the version a
# load answers.
RSpec.describe Lain::Memory::ProjectStore do
  subject(:store) { described_class.new(project_dir:) }

  around do |example|
    Dir.mktmpdir("lain-memory-store") do |dir|
      @home = dir
      example.run
    end
  end

  let(:project_dir) do
    Lain::ProjectDir.new(root: @home, paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @home, "HOME" => @home }))
  end

  def item(id, body = "body of #{id}")
    Lain::Memory::Item.new(id:, description: "about #{id}", body:)
  end

  def lines = File.readlines(store.path, chomp: true).reject(&:empty?)

  def paths_at(root) = Lain::Paths.new(env: { "XDG_STATE_HOME" => root, "HOME" => root })

  # An exclusive holder on a second descriptor: flock is per open-file
  # description, so this is the same contention a sibling process makes.
  def holding
    FileUtils.mkdir_p(File.dirname(store.path))
    File.open(File.join(File.dirname(store.path), described_class::LOCK), File::RDWR | File::CREAT, 0o600) do |held|
      held.flock(File::LOCK_EX)
      # A real holder names itself in the lock file, which is what a waiter
      # that outlasts its patience reads back.
      held.write("pid=#{Process.pid} command=rspec\n")
      held.flush
      @held = held
      yield
    end
  end

  # Starts the write, waits for the block to observe whatever it is watching
  # for, then releases the holder so the write can land.
  def writing(waiting_store, written)
    thread = Thread.new { waiting_store.append(written) }
    yield
    @held.flock(File::LOCK_UN)
    thread.join
  end

  describe "#path" do
    it "resolves under the state home, keyed to the project, and creates nothing" do
      expect(store.path).to start_with(File.join(@home, "lain", "memory"))
      expect(File.exist?(store.path)).to be(false)
    end
  end

  describe "#load" do
    it "answers the empty version for a project nothing ever wrote in" do
      expect(store.load).to eq(described_class.empty)
      expect(store.load.items).to be_empty
    end

    it "answers the items in store order" do
      store.append(item("first"))
      store.append(item("second"))

      expect(store.load.items.map(&:id)).to eq(%w[first second])
    end

    it "moves the version with every new entry, and only with a new one" do
      first = store.append(item("a")).version
      again = store.append(item("a")).version
      second = store.append(item("b")).version

      expect(again).to eq(first)
      expect(second).not_to eq(first)
    end

    it "refuses a line whose content no longer addresses its recorded digest" do
      store.append(item("a"))
      store.append(item("b"))
      edited = JSON.generate(JSON.parse(lines.first).merge("body" => "tampered"))
      File.write(store.path, "#{edited}\n#{lines.last}\n")

      expect { store.load }.to raise_error(described_class::Corrupt, /has been edited/)
    end

    # THE SHAPE A CRASH REALLY MAKES: a fragment with NO trailing newline, since
    # that byte is the one the writer never reached. The Journal's readers skip
    # what does not parse, and a project whose only copy of its memory is
    # unreadable forever is a far worse answer than one entry lost.
    it "skips a torn last line rather than making the project's memory unreadable" do
      store.append(item("kept", "durable"))
      File.write(store.path, %({"id":"half","desc), mode: "a")

      expect(store.load.items.map(&:id)).to eq(["kept"])
    end

    # Appending straight after an unterminated fragment would merge the two into
    # one physical line that neither reads back, losing BOTH -- the fragment and
    # the record that was written successfully.
    it "pays the newline a crash owed, so the next append does not merge with the fragment" do
      store.append(item("kept", "durable"))
      File.write(store.path, %({"id":"half","desc), mode: "a")
      store.append(item("later", "b"))

      expect(store.load.items.map(&:id)).to eq(%w[kept later])
      expect(lines.size).to eq(3)
    end

    it "adds no terminator when the file already ends in one" do
      store.append(item("kept", "durable"))
      store.append(item("later", "b"))

      expect(File.read(store.path)).not_to include("\n\n")
    end
  end

  describe "#append" do
    it "is append-only on disk, and folds last-write-wins on the way out" do
      store.append(item("dosage", "v1"))
      store.append(item("dosage", "v2"))

      expect(lines.size).to eq(2)
      expect(store.load.items.map(&:body)).to eq(["v2"])
    end

    it "writes nothing when this id's head already holds exactly this content" do
      3.times { store.append(item("a")) }

      expect(lines.size).to eq(1)
    end

    # A caller told its item was stored, over bytes that are not a whole record,
    # is the one failure the store-first ordering in Recorder#write exists to
    # prevent -- so an append that cannot be made safe is loud, and the view
    # does not move.
    it "raises rather than report success when the filesystem takes only part of the record" do
      partial = instance_double(File, write: 1, fsync: nil)
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(store.path, anything, anything).and_yield(partial)

      expect { store.append(item("a")) }.to raise_error(described_class::Unwritten, /not stored/)
    end

    it "raises, and leaves the view where it was, when the record cannot be appended at all" do
      view = store.view
      FileUtils.mkdir_p(store.path)

      expect { view.write(item("a")) }.to raise_error(SystemCallError)
      expect(view.index).to be_empty
    end

    # The dedup is judged against the FOLD, never against the whole file: a
    # model correcting a memory back to what it said before has moved the head
    # twice, and a set would swallow the second move and leave every future
    # chat rendering the body this one abandoned.
    it "records a revert to a body the id held before, and resolves to it" do
      live = store.view
      live.write(item("x", "one"))
      live.write(item("x", "two"))
      live.write(item("x", "one"))

      expect(lines.size).to eq(3)
      expect(store.load.items.map(&:body)).to eq(["one"])
      expect(live.fetch("x").body).to eq("one")
    end

    # Polled, not blocked: a blocking flock would stall the reactor for as long
    # as another chat in the same project held it.
    it "waits for another holder's lock rather than blocking on it" do
      waits = 0
      polled = described_class.new(project_dir:, sleeper: ->(_seconds) { waits += 1 })

      holding { writing(polled, item("a")) { sleep(0.01) until waits.positive? } }

      expect(waits).to be_positive
      expect(store.load.items.map(&:id)).to eq(["a"])
    end

    # A holder that HANGS -- stopped, wedged, paused under a debugger -- never
    # releases, where a dead one's flock goes with it. ParentLock grew patience
    # for exactly that case, and a wait nobody is told about is a chat that
    # looks frozen for no stated reason.
    it "names the holder once a wait outlasts its patience, and keeps waiting" do
      told = []
      patient = described_class.new(project_dir:, patience: 0.1, interval: 0.01,
                                    sleeper: ->(seconds) { sleep(seconds) }, notice: told.method(:<<))

      holding { writing(patient, item("a")) { sleep(0.01) while told.empty? } }

      expect(told.size).to eq(1)
      expect(told.first).to include("pid=#{Process.pid}", store.path)
      expect(store.load.items.map(&:id)).to eq(["a"])
    end

    # Four processes, not four threads: flock is what separates them, and a
    # same-process double would prove nothing about it.
    it "loses no write when several processes append at once", :seam do
      root = @home
      siblings = (1..4).map do |worker|
        fork do
          sibling = described_class.new(project_dir: Lain::ProjectDir.new(root:, paths: paths_at(root)))
          5.times { |n| sibling.append(Lain::Memory::Item.new(id: "p#{worker}-#{n}", description: "d", body: "b")) }
          exit!(0)
        end
      end
      siblings.each { |pid| Process.waitpid(pid) }

      expect(store.load.items.size).to eq(20)
    end
  end

  # A read that landed mid-append saw a partial line, and on the chat path that
  # is `lain chat` refusing to start in a project another chat is writing a
  # memory in. The shared lock is what makes the window unreachable; the
  # skipped torn line above is what covers a crash, which no lock can.
  describe "a read while another process writes" do
    it "waits for the writer rather than reading a half-written line" do
      store.append(item("seed"))
      waits = 0
      polled = described_class.new(project_dir:, sleeper: ->(_seconds) { waits += 1 })
      read = nil

      holding do
        reader = Thread.new { read = polled.load }
        sleep(0.01) until waits.positive?
        @held.flock(File::LOCK_UN)
        reader.join
      end

      expect(waits).to be_positive
      expect(read.items.map(&:id)).to eq(["seed"])
    end

    # Every read a sibling's whole write burst overlaps, against bodies at the
    # memory_write ceiling, which is what makes one append large enough to be
    # caught mid-flight.
    it "never answers Corrupt while a sibling process appends", :seam do
      store.append(item("seed", "x" * 16_384))
      root = @home
      writer = fork do
        busy = described_class.new(project_dir: Lain::ProjectDir.new(root:, paths: paths_at(root)))
        40.times { |n| busy.append(Lain::Memory::Item.new(id: "w#{n}", description: "d", body: "y" * 16_384)) }
        exit!(0)
      end
      reads = reads_until(writer)

      expect(reads.count { |read| read == :corrupt }).to be_zero
      expect(reads).not_to be_empty
    end

    def reads_until(pid)
      Enumerator.produce { Process.waitpid(pid, Process::WNOHANG).nil? ? read_once : nil }
                .take_while { |outcome| !outcome.nil? }.to_a
    end

    def read_once
      store.load
      :read
    rescue described_class::Corrupt
      :corrupt
    end
  end

  # The VIEW: what one session sees, which is a snapshot of the store plus its
  # own writes -- never a live read of what other chats are doing.
  describe "#view" do
    it "opens on the store head, so an earlier chat's writes are in the manifest" do
      store.append(item("db-conventions"))

      expect(store.view.index.to_h.keys).to eq(["db-conventions"])
    end

    it "sends a write through to the store as well as to the view" do
      view = store.view
      view.write(item("fresh"))

      expect(store.load.items.map(&:id)).to eq(["fresh"])
      expect(view.fetch("fresh").body).to eq("body of fresh")
    end

    it "does not pick up another view's write made after it opened" do
      first = store.view
      store.view.write(item("other"))

      expect(first.index).to be_empty
      expect(first.root).to be_nil
    end

    it "roots identically to the replay of the load it opened on" do
      store.append(item("a"))
      store.append(item("b"))

      expect(store.view.root).to eq(store.load.index.root)
    end
  end

  describe "#resumed" do
    it "re-opens the recorded view, and not what other chats wrote since" do
      recorded = Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty.write(item("recorded")))
      store.append(item("other"))

      expect(store.resumed(recorded).index.to_h.keys).to eq(["recorded"])
    end

    it "roots the re-opened view where a replay of its own memory_loaded would" do
      recorded = Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty.write(item("a")).write(item("b")))
      resumed = store.resumed(recorded)

      expect(resumed.root).to eq(resumed.loaded.index.root)
    end

    it "still writes through to the store" do
      resumed = store.resumed(Lain::Memory::Recorder.new)
      resumed.write(item("late"))

      expect(store.load.items.map(&:id)).to eq(["late"])
    end
  end

  describe "#newer_than" do
    it "counts the entries a recorded view does not hold" do
      view = store.view
      store.append(item("a"))
      store.append(item("b"))

      expect(store.newer_than(view.loaded)).to eq(2)
    end

    it "counts nothing for a view that holds them all" do
      store.append(item("a"))

      expect(store.newer_than(store.load)).to be_zero
    end
  end

  describe "the Null store" do
    it "answers the empty version and keeps nothing" do
      null = Lain::Memory::ProjectStore::Null
      null.view.write(item("a"))

      expect(null.load).to eq(described_class.empty)
      expect(null.path).to be_nil
      expect(null.newer_than(described_class.empty)).to be_zero
    end
  end

  describe "a Loaded" do
    it "addresses its items, so two loads of the same items agree" do
      loaded = Lain::Memory::ProjectStore::Loaded

      expect(loaded.of([item("a")]).version).to eq(loaded.of([item("a")]).version)
    end

    it "folds into an Index in store order" do
      loaded = Lain::Memory::ProjectStore::Loaded.of([item("a"), item("b")])

      expect(loaded.index.to_h.keys).to contain_exactly("a", "b")
    end
  end
end
