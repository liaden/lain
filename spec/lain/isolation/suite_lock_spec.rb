# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::SuiteLock, :seam do
  around do |example|
    Dir.mktmpdir("lain-suite-lock") do |home|
      @state_home = File.realpath(home)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home, "HOME" => @state_home }) }
  let(:path) { File.join(paths.state_home, "locks", "suite.lock") }

  # The child leaves through exit! so this suite's exit hooks never run in it.
  def interval_in_child
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      described_class.for(paths:).hold do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep 0.3
        writer.write(Marshal.dump([started, Process.clock_gettime(Process::CLOCK_MONOTONIC)]))
      end
      writer.close
    ensure
      exit!(0)
    end
    writer.close
    [pid, reader]
  end

  it "keeps two processes' held runs from overlapping" do
    first_pid, first = interval_in_child
    second_pid, second = interval_in_child
    spans = [first, second].map { |io| Marshal.load(io.read) } # rubocop:disable Security/MarshalLoad
    [first_pid, second_pid].each { |pid| Process.wait(pid) }

    early, late = spans.sort
    expect(late.first).to be >= early.last
  end

  it "creates the lock file under the state home on demand, naming no holder after the release" do
    expect(File.exist?(path)).to be(false)

    lock = described_class.for(paths:)
    during = lock.hold { lock.holder }

    expect(during).to include("pid=#{Process.pid}")
    expect([File.exist?(path), lock.holder]).to eq([true, ""])
  end

  it "raises Paths::Unwritable when the state home cannot be a directory" do
    File.write(File.join(@state_home, "lain"), "in the way")

    expect { described_class.for(paths:) }.to raise_error(Lain::Paths::Unwritable)
  end

  describe ".holding" do
    let(:env) { {} }

    it "starts the block only after the first holder releases, telling the waiter who holds it" do
      release = Queue.new
      held = Queue.new
      FileUtils.mkdir_p(File.dirname(path))
      holder_lock = Lain::FileLock.new(path, label: "the suite lock")
      holder = Thread.new { holder_lock.hold { (held << true) && release.pop } }
      held.pop
      told = []
      order = []
      waiter = Thread.new do
        described_class.holding(paths:, env:, patience: 0.1, notice: told.method(:<<)) { order << :ran }
      end

      wait_until(timeout: 2, reason: "the waiter to say who holds the lock") { !told.empty? }
      order << :released
      release << true
      holder.join
      waiter.join

      expect([order, told.size, told.first]).to match([%i[released ran], 1, /\Awaiting on pid=#{Process.pid} /])
    end

    context "when the environment says a parent already holds the lock" do
      let(:env) { { "LAIN_SUITE_LOCK_HELD" => "1" } }

      it "runs the block at once without taking the lock" do
        ran = described_class.for(paths:).hold { described_class.holding(paths:, env:) { :ran } }

        expect(ran).to eq(:ran)
      end
    end

    it "returns the block's value" do
      expect(described_class.holding(paths:, env:) { :value }).to eq(:value)
    end
  end
end
