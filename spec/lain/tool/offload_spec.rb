# frozen_string_literal: true

require "async"
require "tmpdir"

RSpec.describe Lain::Tool::Offload do
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def rescued
    yield
  rescue ArgumentError
    nil
  end

  # The work cannot finish until the sibling has ticked, so finishing proves the
  # sibling ran; the deadline only turns a held reactor into a failure, not a hang.
  def sibling_ticks_during(needed: 5, patience: 10)
    ticks = Thread::Queue.new
    Sync do |task|
      ticker = task.async do
        loop do
          ticks << true
          task.sleep(0.01)
        end
      end
      outcome = described_class.call { yield(-> { ticks.size >= needed }, monotonic + patience) }
      ticker.stop
      outcome
    end
  end

  it "answers what the work returns" do
    expect(described_class.call { 6 * 7 }).to eq(42)
  end

  it "re-raises the work's own error, with its class and message" do
    expect { described_class.call { raise Errno::EACCES, "/tmp/secret" } }
      .to raise_error(Errno::EACCES, %r{/tmp/secret})
  end

  it "does not report the work's error on stderr on the way past" do
    expect { rescued { described_class.call { raise ArgumentError, "quiet" } } }.not_to output.to_stderr
  end

  it "keeps a sibling fiber running while the work holds its thread" do
    Dir.mktmpdir("lain-offload") do |dir|
      File.write(File.join(dir, "a.txt"), "a")

      ran = sibling_ticks_during do |ticked, deadline|
        Dir.glob(File.join(dir, "**", "*")) until ticked.call || monotonic > deadline
        ticked.call
      end

      expect(ran).to be(true)
    end
  end

  # Matching lines is Ruby holding the lock between threads, which a thread
  # hands over only at the end of its time slice.
  it "keeps a sibling fiber running while the work never gives up the lock between threads" do
    ran = sibling_ticks_during do |ticked, deadline|
      nil until ticked.call || monotonic > deadline
      ticked.call
    end

    expect(ran).to be(true)
  end

  it "kills the work's thread when the task waiting on it is stopped" do
    started = Thread::Queue.new
    Sync do |task|
      waiter = task.async do
        described_class.call do
          started << Thread.current
          sleep 30
        end
      end
      worker = started.pop
      waiter.stop

      expect(worker.join(1)).to eq(worker)
      expect(worker).not_to be_alive
    end
  end
end
