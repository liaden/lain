# frozen_string_literal: true

require "tmpdir"

# One path's cross-process flock, driven against a real file and a real second process.
RSpec.describe Lain::FileLock, :seam do
  around do |example|
    Dir.mktmpdir("lain-file-lock") do |dir|
      @path = File.join(dir, "x.lock")
      example.run
    end
  end

  def free?
    File.open(@path, File::RDWR | File::CREAT) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) == 0 }
  end

  # The child leaves through exit! so this suite's exit hooks never run in it.
  def held_elsewhere
    ready, held = IO.pipe
    release, go = IO.pipe
    pid = fork do
      [ready, go].each(&:close)
      described_class.new(@path).hold { held.write("held") && held.flush && release.read(1) }
    ensure
      exit!(0)
    end
    [held, release].each(&:close)
    raise "the other process never took the lock" unless ready.read(4) == "held"

    yield pid
  ensure
    go&.close
    Process.wait(pid) if pid
  end

  it "refuses a lock path that is a directory by name, without running the block" do
    FileUtils.mkdir_p(@path)
    ran = false

    expect { described_class.new(@path).hold { ran = true } }
      .to raise_error(Lain::Paths::Unwritable, /#{Regexp.escape(@path)}/)
    expect(ran).to be(false)
  end

  it "refuses an unopenable path by name from try as well" do
    FileUtils.mkdir_p(@path)

    expect do
      described_class.new(@path).try do
        :never
      end
    end.to raise_error(Lain::Paths::Unwritable, /#{Regexp.escape(@path)}/)
  end

  it "holds the flock for the block, answers its value, and clears the holder after" do
    lock = described_class.new(@path)
    during = lock.hold { [free?, lock.holder] }

    expect(during.first).to be(false)
    expect(during.last).to include("pid=#{Process.pid}")
    expect([lock.hold { :done }, free?, lock.holder]).to eq([:done, true, ""])
  end

  it "waits for another process, tells the notice once naming the holder, then runs after the release" do
    notices = []
    patient = described_class.new(@path, interval: 0.01, patience: 0.05)
    holder = nil
    waiting = nil

    held_elsewhere do |pid|
      holder = pid
      waiting = Thread.new { patient.hold(notice: ->(text) { notices << text }) { :entered } }
      deadline = Time.now + 5
      sleep(0.01) until notices.any? || Time.now > deadline
      expect(waiting).to be_alive
    end

    expect(waiting.value).to eq(:entered)
    expect(notices.size).to eq(1)
    expect(notices.first).to include("pid=#{holder}")
  end

  describe "reclaim" do
    def killed_holder
      ready, held = IO.pipe
      pid = fork do
        ready.close
        described_class.new(@path).hold do |note|
          note.call("verify=4242")
          held.write("held") && held.flush && sleep
        end
      ensure
        exit!(0)
      end
      held.close
      raise "the other process never took the lock" unless ready.read(4) == "held"

      Process.kill(:KILL, pid)
      Process.wait(pid)
      pid
    end

    it "hands a holder killed with SIGKILL's line, with its note, to whoever takes the lock next" do
      reclaimed = []
      dead = killed_holder

      during = described_class.new(@path).hold(reclaim: ->(line) { reclaimed << line }) { File.read(@path) }

      expect(reclaimed.size).to eq(1)
      expect(reclaimed.first).to match(/\Apid=#{dead} command=.* verify=4242\z/)
      expect(during).to match(/\Apid=#{Process.pid} command=[^\n]*\n\z/)
      expect(during).not_to include("verify=4242")
    end

    it "calls nothing after a holder released normally" do
      lock = described_class.new(@path)
      lock.hold { |note| note.call("verify=1") }
      reclaimed = []

      lock.hold(reclaim: ->(line) { reclaimed << line }) { :entered }

      expect(reclaimed).to be_empty
    end

    it "hands reclaim only the first line when a kill left an older line's tail behind it" do
      File.write(@path, "pid=2 command=short\nverify_pgid=99 tail\n")
      reclaimed = []

      described_class.new(@path).hold(reclaim: ->(line) { reclaimed << line }) { :entered }

      expect(reclaimed).to eq(["pid=2 command=short"])
    end

    it "keeps the dead holder's line for the next taker when reclaim raises" do
      File.write(@path, "pid=1 command=dead\n")
      ran = false

      expect { described_class.new(@path).hold(reclaim: ->(_line) { raise "kill failed" }) { ran = true } }
        .to raise_error(RuntimeError, "kill failed")
      expect([ran, File.read(@path)]).to eq([false, "pid=1 command=dead\n"])
    end

    it "reads a dead holder's non-ASCII line under a US-ASCII locale" do
      File.binwrite(@path, "pid=1 command=lain land /home/café\n")
      reclaimed = []
      external = Encoding.default_external
      silently { Encoding.default_external = Encoding::US_ASCII }

      described_class.new(@path).hold(reclaim: ->(line) { reclaimed << line }) { :entered }

      expect(reclaimed).to eq(["pid=1 command=lain land /home/café"])
    ensure
      silently { Encoding.default_external = external }
    end

    it "calls no reclaim under a shared hold, and still yields a callable note" do
      File.write(@path, "pid=1 command=dead\n")
      reclaimed = []

      noted = described_class.new(@path, mode: File::LOCK_SH)
                             .hold(reclaim: ->(line) { reclaimed << line }) { |note| note.call("verify=1") }

      expect([noted, reclaimed, File.read(@path)]).to eq([nil, [], "pid=1 command=dead\n"])
    end
  end

  def silently
    verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = verbose
  end

  it "never shows a reader an empty holder line while a holder notes" do
    lock = described_class.new(@path)
    reader = described_class.new(@path)
    seen = []
    lock.hold do |note|
      watcher = Thread.new { 2_000.times { seen << reader.holder } }
      note.call("i=0") while watcher.alive?
    end

    expect(seen).not_to include("")
  end

  it "appends a note to the holder line while the lock is held" do
    lock = described_class.new(@path)

    during = lock.hold do |note|
      note.call("verify=7")
      lock.holder
    end

    expect(during).to match(/\Apid=#{Process.pid} command=.* verify=7\z/)
  end

  it "polls through its sleeper rather than blocking the thread" do
    slept = []
    File.open(@path, File::RDWR | File::CREAT) do |blocker|
      blocker.flock(File::LOCK_EX)
      lock = described_class.new(@path, sleeper: ->(seconds) { (slept << seconds) && blocker.flock(File::LOCK_UN) })

      expect(lock.hold { :entered }).to eq(:entered)
    end
    expect(slept.size).to eq(1)
  end

  describe "#try" do
    it "runs the block and answers true when free" do
      ran = false

      expect(described_class.new(@path).try { ran = true }).to be(true)
      expect([ran, free?]).to eq([true, true])
    end

    it "answers true when the block answers nil" do
      expect(described_class.new(@path).try { nil }).to be(true)
    end

    it "answers false at once, running nothing, when another process holds it" do
      ran = false
      answer = nil

      held_elsewhere { answer = described_class.new(@path).try { ran = true } }

      expect([answer, ran]).to eq([false, false])
    end
  end

  it "leaves the holder file untouched under a shared hold" do
    File.write(@path, "pid=1 command=other\n")

    during = described_class.new(@path, mode: File::LOCK_SH).hold { File.read(@path) }

    expect([during, File.read(@path)]).to eq(["pid=1 command=other\n"] * 2)
  end

  it "words the notice with its label" do
    notices = []
    labelled = described_class.new(@path, interval: 0.01, patience: 0.01, label: "the thing")

    held_elsewhere do
      waiting = Thread.new { labelled.hold(notice: ->(text) { notices << text }) { :entered } }
      sleep(0.01) until notices.any?
      expect(notices.first).to match(/\Awaiting on pid=\d+ .* for the thing \(#{Regexp.escape(@path)}\)\z/)
      waiting.kill
    end
  end

  it "reads the holder as empty when the file does not exist" do
    expect(described_class.new(@path).holder).to eq("")
  end

  it "refuses to read a holder it may not read, naming the file" do
    File.write(@path, "pid=1\n")
    File.chmod(0o000, @path)

    expect { described_class.new(@path).holder }.to raise_error(described_class::Unreadable, /#{Regexp.escape(@path)}/)
  ensure
    File.chmod(0o600, @path)
  end

  it "refuses a lock file it may read but not write, naming it, without taking the lock" do
    File.write(@path, "")
    File.chmod(0o400, @path)

    expect { described_class.new(@path).writable! }
      .to raise_error(described_class::Unreadable, /#{Regexp.escape(@path)}/)
  ensure
    File.chmod(0o600, @path)
  end

  it "accepts a lock file that is absent or writable" do
    expect(described_class.new(@path).writable!).to be_nil
    File.write(@path, "")
    expect(described_class.new(@path).writable!).to be_nil
  end
end
