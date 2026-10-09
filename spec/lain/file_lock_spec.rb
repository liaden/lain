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
end
